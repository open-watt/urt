module urt.driver.mt7621.ethernet;

import urt.driver.ethernet : EthernetConfig, EthLinkCallback, EthLinkEvent, EthLinkInfo, EthReadyCallback, EthRxCallback, EthRxInfo, EthSpeed;
import urt.driver.mt7621 : mmio_read, mmio_write, sysctl_base;
import urt.system : sleep;
import urt.time : msecs;

nothrow @nogc:

// GE1 fronts the MT7530: frames to and from the CPU port carry the MediaTek special tag, which this
// driver adds and strips in software so callers see plain frames plus a front-port number. GE2 is one port on an
// RGMII PHY, the AR8033 whose fibre side faces the SFP cage on the hEX S; that side is 1000BASE-X only.
enum uint num_ethernet = 2;
enum bool has_eth_timestamp = false;
enum bool has_eth_gigabit = true;
enum bool has_eth_pin_select = false;
enum bool has_eth_tx_checksum = false;

enum uint num_front_ports = 5;

const(char)[] eth_hw_name(uint mac)
    => mac == 0 ? "ge1" : "ge2";

uint eth_hw_ports(uint mac)
    => mac == 0 ? num_front_ports : 1;

// Runs from sys_init, before any interface opens, so early output can already leave the box.
void fe_init()
{
    version (RouterBoot)
        import urt.driver.routerboot : board_mac;
    else
        static bool board_mac(ref ubyte[6])
            => false;
    if (!board_mac(_base_mac))
    {
        immutable adrh = mmio_read(fe_base + gdma1_mac_adrh);
        immutable adrl = mmio_read(fe_base + gdma1_mac_adrl);
        _base_mac = [cast(ubyte)(adrh >> 8), cast(ubyte)adrh, cast(ubyte)(adrl >> 24), cast(ubyte)(adrl >> 16),
                     cast(ubyte)(adrl >> 8), cast(ubyte)adrl];
    }

    import urt.driver.mt7621 : sysctl_base, sysc_rstctrl;
    enum uint rst_eth_fe_ppe0 = (1 << 23) | (1 << 6) | (1u << 31);
    mmio_write(sysctl_base + sysc_rstctrl, mmio_read(sysctl_base + sysc_rstctrl) | rst_eth_fe_ppe0);
    sleep(1.msecs);
    mmio_write(sysctl_base + sysc_rstctrl, mmio_read(sysctl_base + sysc_rstctrl) & ~rst_eth_fe_ppe0);
    sleep(10.msecs);

    mmio_write(fe_base + gmac0_mcr, mcr_fixed_1g);
    mmio_write(fe_base + gmac1_mcr, mcr_fixed_1g & ~mcr_force_link);
    mmio_write(fe_base + gdma1_fwd_cfg, (mmio_read(fe_base + gdma1_fwd_cfg) & 0xFFFF_0000) | gdma_special_tag | gdma_strip_crc);
    mmio_write(fe_base + gdma2_fwd_cfg, (mmio_read(fe_base + gdma2_fwd_cfg) & 0xFFFF_0000) | gdma_strip_crc);
    mmio_write(sysctl_base + sysc_syscfg1, mmio_read(sysctl_base + sysc_syscfg1) & ~syscfg1_ge2_mode);
    mmio_write(sysctl_base + sysc_gpio_mode, mmio_read(sysctl_base + sysc_gpio_mode) & ~gpio_mode_rgmii2);
    mmio_write(fe_base + cdmq_ig_ctrl, mmio_read(fe_base + cdmq_ig_ctrl) | cdm_stag_en);
    // The receive side neither parses nor untags the special tag: both are one switch for every GDMA,
    // and would take GE2's real 802.1Q headers with GE1's tag. Linux does the same with a MAC off the switch.
    mmio_write(fe_base + cdmp_ig_ctrl, mmio_read(fe_base + cdmp_ig_ctrl) & ~cdm_stag_en);
    mmio_write(fe_base + cdmp_eg_ctrl, 0);

    import urt.mem.alloc : alloc, MemFlags;
    void[] dma = alloc(dma_bytes, 32, MemFlags.dma);
    if (dma is null)
        return;
    immutable base = cast(uint)dma.ptr;
    uint* fq = cast(uint*)uncached(base + fq_ring_off);
    _tx = cast(uint*)uncached(base + tx_ring_off);
    _rx = cast(uint*)uncached(base + rx_ring_off);
    _tx_buf = cast(ubyte*)uncached(base + tx_buf_off);
    _rx_buf = cast(ubyte*)uncached(base + rx_buf_off);
    _tx_phys = phys(base + tx_ring_off);

    immutable fq_phys = phys(base + fq_ring_off);
    immutable fq_buf_phys = phys(base + fq_buf_off);
    foreach (i; 0 .. fq_count)
    {
        fq[i * 4 + 0] = fq_buf_phys + i * fq_page;
        fq[i * 4 + 1] = fq_phys + (i + 1) * 16;
        fq[i * 4 + 2] = fq_page << 16;
        fq[i * 4 + 3] = 0;
    }
    mmio_write(fe_base + qdma_fq_head, fq_phys);
    mmio_write(fe_base + qdma_fq_tail, fq_phys + (fq_count - 1) * 16);
    mmio_write(fe_base + qdma_fq_count, (fq_count << 16) | fq_count);
    mmio_write(fe_base + qdma_fq_blen, fq_page << 16);

    foreach (i; 0 .. tx_count)
    {
        _tx[i * 4 + 0] = 0;
        _tx[i * 4 + 1] = tx_desc_phys((i + 1) % tx_count);
        _tx[i * 4 + 2] = txd3_ls0 | txd3_owner_cpu;
        _tx[i * 4 + 3] = 0;
    }
    _tx_next = 0;
    mmio_write(fe_base + qdma_ctx_ptr, tx_desc_phys(0));
    mmio_write(fe_base + qdma_dtx_ptr, tx_desc_phys(0));
    mmio_write(fe_base + qdma_crx_ptr, tx_desc_phys(tx_count - 1));
    mmio_write(fe_base + qdma_drx_ptr, tx_desc_phys(tx_count - 1));
    mmio_write(fe_base + qdma_qtx_cfg, (qdma_res_thres << 8) | qdma_res_thres);
    mmio_write(fe_base + qdma_qtx_sch, qtx_sch_leaky_bucket_en | qtx_sch_leaky_bucket_size | qtx_sch_min_rate_en | (1 << 20) | (4 << 16));
    mmio_write(fe_base + qdma_tx_sch_rate, qdma_tx_sch_max_wfq | (qdma_tx_sch_max_wfq << 16));
    mmio_write(fe_base + qdma_fc_th, fc_thres_drop_mode | fc_thres_drop_en | fc_thres_min);
    mmio_write(fe_base + qdma_hred, 0);
    mmio_write(fe_base + qdma_glo_cfg, dma_tx_en | dma_tx_bt_32dwords | dma_ndp_co_pro | dma_tx_wb_ddone);

    immutable rx_buf_phys = phys(base + rx_buf_off);
    foreach (i; 0 .. rx_count)
    {
        _rx[i * 4 + 0] = rx_buf_phys + i * rx_buf_size;
        _rx[i * 4 + 1] = rx_buf_size << 16;
        _rx[i * 4 + 2] = 0;
        _rx[i * 4 + 3] = 0;
    }
    _rx_calc = rx_count - 1;
    mmio_write(fe_base + pdma_rx_ptr, phys(base + rx_ring_off));
    mmio_write(fe_base + pdma_rx_cnt, rx_count);
    mmio_write(fe_base + pdma_rst_idx, pdma_rst_drx_idx0);
    mmio_write(fe_base + pdma_rx_crx, _rx_calc);
    mmio_write(fe_base + pdma_irq_mask, 0);
    mmio_write(fe_base + pdma_glo_cfg, dma_rx_en | dma_rx_bt_32dwords | dma_multi_en);

    _ready = switch_init();
}

bool eth_hw_open(uint mac, uint port, ref const EthernetConfig cfg, EthRxCallback rx, EthLinkCallback link, void* context)
{
    if (!_ready)
        return false;
    immutable slot = mac == 0 ? port : ge2_slot;
    if (mac == 1)
    {
        if (cfg.phy_address < 0 || cfg.phy_address > 31)
            return false;
        _ge2_phy = cast(ubyte)cfg.phy_address;
    }
    if (!port_enable(slot, true))
        return false;
    _ports[slot] = Port(rx, link, context);
    if (_enabled == 1u << slot)
    {
        import urt.driver.mt7621.irq : irq_set_enable, irq_set_handler;
        irq_set_handler(fe_irq, &fe_irq_handler);
        irq_set_enable(fe_irq);
        mmio_write(fe_base + pdma_irq_status, pdma_rx_done_int0);
        mmio_write(fe_base + pdma_irq_mask, pdma_rx_done_int0);
    }
    return true;
}

// A port the switch would not isolate stays open, so the close is retried rather than reported done.
bool eth_hw_close(uint mac, uint port)
{
    immutable slot = mac == 0 ? port : ge2_slot;
    if (!port_enable(slot, false))
        return false;
    _ports[slot] = Port.init;
    if (_enabled == 0)
    {
        import urt.driver.mt7621.irq : irq_clear_enable;
        mmio_write(fe_base + pdma_irq_mask, 0);
        irq_clear_enable(fe_irq);
    }
    return true;
}

bool eth_hw_tx(uint mac, uint port, const(ubyte)[] frame, bool insert_checksum)
    => mac == 0 ? fe_tx_tagged(frame, 1u << port) : fe_tx(frame);

bool eth_hw_checksum_insertable(uint mac, uint port, const(ubyte)[] frame)
    => false;

// Front port n takes the base address plus n and GE2 follows the front ports, as RouterOS numbers etherN and sfp1.
bool eth_hw_get_hardware_address(uint mac, uint port, ref ubyte[6] address)
{
    if (_base_mac == typeof(_base_mac).init)
        return false;
    address = _base_mac;
    immutable low = (address[3] << 16 | address[4] << 8 | address[5]) + (mac == 0 ? port : num_front_ports);
    address[3] = cast(ubyte)(low >> 16);
    address[4] = cast(ubyte)(low >> 8);
    address[5] = cast(ubyte)low;
    return true;
}

// Frames from the CPU carry their own source address, and GDMA1 forwards every frame to the CPU.
bool eth_hw_set_address(uint mac, uint port, ref const ubyte[6] address)
    => true;

bool eth_hw_set_promiscuous(uint mac, uint port, bool enable)
    => true;

bool eth_hw_get_link(uint mac, uint port, ref EthLinkInfo info)
{
    if (mac == 1)
    {
        info.speed = EthSpeed.s1000m;
        return phy_link(info.full_duplex);
    }
    uint pmsr;
    if (!sw_read(mt7530_pmsr(port), pmsr) || !(pmsr & pmsr_link))
        return false;
    info.speed = (pmsr & pmsr_speed_1000) ? EthSpeed.s1000m : (pmsr & pmsr_speed_100) ? EthSpeed.s100m : EthSpeed.s10m;
    info.full_duplex = (pmsr & pmsr_duplex) != 0;
    return true;
}

bool eth_hw_set_link_mode(uint mac, uint port, bool autonegotiate, EthSpeed speed, bool full_duplex)
    => false;

void eth_hw_set_ready_callback(EthReadyCallback cb)
{
    _ready_callback = cb;
}

bool eth_hw_service(uint mac, size_t budget)
{
    size_t n;
    while (n < budget)
    {
        immutable i = (_rx_calc + 1) % rx_count;
        uint* d = _rx + i * 4;
        immutable d2 = d[1];
        if (!(d2 & rxd2_ddone))
            break;
        uint slot;
        ubyte[] frame = rx_frame(_rx_buf + i * rx_buf_size, (d2 >> 16) & 0x3FFF, (d[3] >> 19) & 7, slot);
        if (frame is null)
            ++_rx_drops;
        else if (_ports[slot].rx is null)
            ++_ports[slot].drops;
        else
        {
            EthRxInfo info;
            _ports[slot].rx(_ports[slot].context, frame, info);
        }
        d[1] = rx_buf_size << 16;
        _rx_calc = i;
        ++n;
    }
    if (n)
        mmio_write(fe_base + pdma_rx_crx, _rx_calc);

    import urt.driver.mt7621.timer : mtime_freq_hz, mtime_read;
    immutable now = mtime_read();
    if (now - _links_polled >= mtime_freq_hz)
    {
        _links_polled = now;
        poll_links();
    }

    if (n == budget)
        return true;
    // Ack first: a frame completing after the ring check below would otherwise lose its interrupt.
    mmio_write(fe_base + pdma_irq_status, pdma_rx_done_int0);
    if (_rx[(_rx_calc + 1) % rx_count * 4 + 1] & rxd2_ddone)
        return true;
    mmio_write(fe_base + pdma_irq_mask, pdma_rx_done_int0);
    return false;
}

uint eth_hw_take_rx_drops(uint mac, uint port)
{
    immutable slot = mac == 0 ? port : ge2_slot;
    immutable dropped = _ports[slot].drops;
    _ports[slot].drops = 0;
    return dropped;
}

bool fe_tx_tagged(const(ubyte)[] frame, uint port_mask)
{
    ubyte* f = tx_slot(frame.length + 4);
    if (f is null)
        return false;
    f[0 .. 12] = frame[0 .. 12];
    uint len;
    immutable ethertype = (frame[12] << 8) | frame[13];
    if (ethertype == 0x8100 || ethertype == 0x88A8)
    {
        // The tag replaces the TPID of an 802.1Q or 802.1ad header, which keeps its TCI.
        f[12] = ethertype == 0x8100 ? tag_tpid_8100 : tag_tpid_88a8;
        f[13] = cast(ubyte)port_mask;
        f[14 .. frame.length] = frame[14 .. $];
        len = cast(uint)frame.length;
    }
    else
    {
        f[12] = tag_untagged;
        f[13] = cast(ubyte)port_mask;
        f[14] = 0;
        f[15] = 0;
        f[16 .. frame.length + 4] = frame[12 .. $];
        len = cast(uint)frame.length + 4;
    }
    for (; len < 64; ++len)
        f[len] = 0;
    return tx_submit(len, txd4_fport_gdm1);
}

bool fe_tx(const(ubyte)[] frame)
{
    ubyte* f = tx_slot(frame.length);
    if (f is null)
        return false;
    f[0 .. frame.length] = frame[];
    uint len = cast(uint)frame.length;
    for (; len < 60; ++len)
        f[len] = 0;
    return tx_submit(len, txd4_fport_gdm2);
}

bool mdio_read(uint phy, uint reg, out ushort value)
{
    uint v;
    if (!mdio(phy_iac_read, phy, reg, 0, v))
        return false;
    value = cast(ushort)v;
    return true;
}

bool mdio_write(uint phy, uint reg, ushort value)
{
    uint unused;
    return mdio(phy_iac_write, phy, reg, value, unused);
}


private:

enum uint fe_base = 0xBE10_0000;
enum uint fe_irq  = 3;

enum uint gdma1_fwd_cfg   = 0x500;
enum uint gdma1_mac_adrl  = 0x508;
enum uint gdma1_mac_adrh  = 0x50C;
enum uint gdma2_fwd_cfg   = 0x1500;
enum uint cdmp_ig_ctrl    = 0x400;
enum uint cdmp_eg_ctrl    = 0x404;
enum uint cdmq_ig_ctrl    = 0x1400;
enum uint gmac0_mcr       = 0x1_0100;
enum uint gmac1_mcr       = 0x1_0200;
enum uint phy_iac         = 0x1_0004;

enum uint gdma_special_tag = 1 << 24;
enum uint gdma_strip_crc   = 1 << 16;
enum uint cdm_stag_en      = 1 << 0;
enum uint mcr_fixed_1g     = 0x0105_E33B;   // max RX 1536, forced 1G full duplex with pause, TX/RX on
enum uint mcr_force_dpx    = 1 << 1;
enum uint mcr_force_link   = 1 << 0;

enum uint sysc_syscfg1      = 0x14;
enum uint syscfg1_ge2_mode  = 3 << 14;      // 0 is RGMII
enum uint sysc_gpio_mode    = 0x60;
enum uint gpio_mode_rgmii2  = 1 << 15;

enum uint pdma_rx_ptr     = 0x900;
enum uint pdma_rx_cnt     = 0x904;
enum uint pdma_rx_crx     = 0x908;
enum uint pdma_glo_cfg    = 0xA04;
enum uint pdma_rst_idx    = 0xA08;
enum uint pdma_irq_status = 0xA20;
enum uint pdma_irq_mask   = 0xA28;
enum uint pdma_rst_drx_idx0 = 1 << 16;
enum uint pdma_rx_done_int0 = 1 << 16;

enum uint qdma_qtx_cfg     = 0x1800;
enum uint qdma_qtx_sch     = 0x1804;
enum uint qdma_glo_cfg     = 0x1A04;
enum uint qdma_fc_th       = 0x1A10;
enum uint qdma_tx_sch_rate = 0x1A14;
enum uint qdma_hred        = 0x1A44;
enum uint qdma_ctx_ptr     = 0x1B00;
enum uint qdma_dtx_ptr     = 0x1B04;
enum uint qdma_crx_ptr     = 0x1B10;
enum uint qdma_drx_ptr     = 0x1B14;
enum uint qdma_fq_head     = 0x1B20;
enum uint qdma_fq_tail     = 0x1B24;
enum uint qdma_fq_count    = 0x1B28;
enum uint qdma_fq_blen     = 0x1B2C;

enum uint dma_tx_en          = 1 << 0;
enum uint dma_rx_en          = 1 << 2;
enum uint dma_tx_bt_32dwords = 3 << 4;
enum uint dma_tx_wb_ddone    = 1 << 6;
enum uint dma_ndp_co_pro     = 1 << 10;
enum uint dma_multi_en       = 1 << 10;
enum uint dma_rx_bt_32dwords = 3 << 11;

enum uint qdma_res_thres            = 4;
enum uint qtx_sch_leaky_bucket_en   = 1 << 30;
enum uint qtx_sch_leaky_bucket_size = 3 << 28;
enum uint qtx_sch_min_rate_en       = 1 << 27;
enum uint qdma_tx_sch_max_wfq       = 1 << 15;
enum uint fc_thres_drop_mode        = 1 << 20;
enum uint fc_thres_drop_en          = 7 << 16;
enum uint fc_thres_min              = 0x4444;

enum uint txd3_owner_cpu  = 1u << 31;
enum uint txd3_ls0        = 1 << 30;
enum uint txd3_swc        = 1 << 14;
enum uint txd4_fport_gdm1 = 1 << 25;
enum uint txd4_fport_gdm2 = 2 << 25;
enum uint rxd2_ddone      = 1u << 31;

enum ubyte tag_untagged  = 0;
enum ubyte tag_tpid_8100 = 1;
enum ubyte tag_tpid_88a8 = 2;

enum uint fq_count    = 64;
enum uint fq_page     = 2048;
enum uint tx_count    = 16;
enum uint tx_buf_size = 1536;
enum uint rx_count    = 128;
enum uint rx_buf_size = 1536;

enum uint fq_ring_off = 0x0_0000;
enum uint tx_ring_off = 0x0_0400;
enum uint rx_ring_off = 0x0_0800;
enum uint tx_buf_off  = 0x0_1000;
enum uint rx_buf_off  = 0x0_8000;
enum uint fq_buf_off  = 0x3_8000;
static assert(tx_ring_off >= fq_count * 16 && rx_ring_off >= tx_ring_off + tx_count * 16);
static assert(tx_buf_off >= rx_ring_off + rx_count * 16 && rx_buf_off >= tx_buf_off + tx_count * tx_buf_size);
static assert(fq_buf_off >= rx_buf_off + rx_count * rx_buf_size);
enum uint dma_bytes = fq_buf_off + fq_count * fq_page;

enum uint cpu_port         = 6;
enum uint mt7530_mdio_addr = 0x1F;
enum uint mt7530_mfc       = 0x10;
enum uint mfc_flood_cpu    = (1 << cpu_port) << 24 | (1 << cpu_port) << 16 | (1 << cpu_port) << 8;
enum uint pcr_matrix_mask  = 0xFF << 16;
enum uint pcr_fallback     = 1;
enum uint psc_sa_dis       = 1 << 4;
enum uint pvc_spec_tag     = 1 << 5;
enum uint pvc_eg_tag_mask  = 7 << 8;
enum uint pvc_eg_consistent = 1 << 8;
enum uint ppbv_vid_mask    = 0xFFF;
enum uint pmsr_link        = 1 << 0;
enum uint pmsr_duplex      = 1 << 1;
enum uint pmsr_speed_100   = 1 << 2;
enum uint pmsr_speed_1000  = 1 << 3;

enum uint tx_release_polls = 1_000_000;

enum uint phy_iac_access = 1u << 31;
enum uint phy_iac_start  = 1 << 16;
enum uint phy_iac_write  = 1 << 18;
enum uint phy_iac_read   = 2 << 18;

// The front ports of GE1 take slots 0..4 and GE2 the slot after them.
enum uint ge2_slot = num_front_ports;

struct Port
{
    EthRxCallback rx;
    EthLinkCallback link;
    void* context;
    uint drops;
}

// The AR8033's fibre side: 1000BASE-X to RGMII, its registers on the fibre page, RX clock delay in the PHY.
enum uint phy_bmcr       = 0;
enum uint phy_bmsr       = 1;
enum uint phy_anar       = 4;
enum uint phy_lpa        = 5;
enum uint phy_debug_addr = 0x1D;
enum uint phy_debug_data = 0x1E;
enum uint phy_chip_cfg   = 0x1F;

enum ushort bmcr_aneg         = 1 << 12;
enum ushort bmcr_power_down   = 1 << 11;
enum ushort bmcr_restart_aneg = 1 << 9;
enum ushort bmsr_aneg_done    = 1 << 5;
enum ushort bmsr_link         = 1 << 2;
enum ushort bx_full_duplex    = 1 << 5;
enum ushort bx_pause          = 1 << 7;
enum ushort ccr_copper_page   = 1 << 15;
enum ushort ccr_mode_mask     = 0xF;
enum ushort ccr_bx1000_rgmii_50 = 2;
enum ushort ccr_bx1000_rgmii_75 = 3;
enum ushort dbg0_rx_clk_delay = 1 << 15;
enum ushort dbg5_tx_clk_delay = 1 << 8;

__gshared ubyte[6] _base_mac;
__gshared bool _ready;
__gshared uint* _tx;
__gshared uint* _rx;
__gshared ubyte* _tx_buf;
__gshared ubyte* _rx_buf;
__gshared uint _tx_phys;
__gshared uint _tx_next;
__gshared uint _rx_calc;
__gshared uint _enabled;
__gshared uint _link_up;
__gshared uint _rx_drops;   // TODO: frames the tag attributes to no port land here and are reported nowhere.
__gshared ulong _links_polled;
__gshared Port[num_front_ports + 1] _ports;
__gshared ubyte _ge2_phy;
__gshared EthReadyCallback _ready_callback;

uint phys(uint kseg0)
    => kseg0 & 0x1FFF_FFFF;

uint uncached(uint kseg0)
    => phys(kseg0) | 0xA000_0000;

uint tx_desc_phys(uint i)
    => _tx_phys + i * 16;

uint pcr_matrix(uint ports)
    => ports << 16;

uint mt7530_pcr(uint p)
    => 0x2004 + p * 0x100;

uint mt7530_psc(uint p)
    => 0x200C + p * 0x100;

uint mt7530_pvc(uint p)
    => 0x2010 + p * 0x100;

uint mt7530_ppbv1(uint p)
    => 0x2014 + p * 0x100;

uint mt7530_pmsr(uint p)
    => 0x3008 + p * 0x100;

// rxd4 names the GDMA a frame came in through. A GE1 frame carries the switch's special tag where
// its TPID would be: an indicator byte, the source port, then the TCI when the frame was tagged.
ubyte[] rx_frame(ubyte* f, uint len, uint gdma, out uint slot)
{
    if (gdma == 2)
    {
        slot = ge2_slot;
        return len < 14 ? null : f[0 .. len];
    }
    if (gdma != 1 || len < 18 || f[12] > tag_tpid_88a8 || (f[13] & 7) >= num_front_ports)
        return null;
    slot = f[13] & 7;
    if (f[12] == tag_untagged)
    {
        immutable ubyte[12] addresses = f[0 .. 12];
        f[4 .. 16] = addresses;
        return f[4 .. len];
    }
    f[12] = f[12] == tag_tpid_8100 ? 0x81 : 0x88;
    f[13] = f[12] == 0x81 ? 0x00 : 0xA8;
    return f[0 .. len];
}

// The frame engine owns the transmit ring; one frame is in flight at a time.
ubyte* tx_slot(size_t bytes)
{
    if (!_ready || bytes < 14 || bytes > tx_buf_size || !tx_released(tx_desc_phys((_tx_next + tx_count - 1) % tx_count)))
        return null;
    return _tx_buf + _tx_next * tx_buf_size;
}

bool tx_submit(uint len, uint fport)
{
    immutable i = _tx_next;
    uint* d = _tx + i * 4;
    d[0] = phys(cast(uint)(_tx_buf + i * tx_buf_size));
    d[3] = fport;
    asm nothrow @nogc { "sync" ::: "memory"; }
    d[2] = txd3_swc | (len << 16) | txd3_ls0;
    asm nothrow @nogc { "sync" ::: "memory"; }
    _tx_next = (i + 1) % tx_count;
    mmio_write(fe_base + qdma_ctx_ptr, tx_desc_phys(_tx_next));
    return tx_released(tx_desc_phys(i));
}

bool port_enable(uint slot, bool enable)
{
    if (slot == ge2_slot ? !(enable ? phy_open() : phy_close()) : !switch_port_enable(slot, enable))
        return false;
    immutable bit = 1u << slot;
    _enabled = enable ? _enabled | bit : _enabled & ~bit;
    if (!enable && (_link_up & bit))
        set_link(slot, false, true);
    return true;
}

bool switch_port_enable(uint port, bool enable)
{
    uint pcr;
    return sw_read(mt7530_pcr(port), pcr) && sw_write(mt7530_pcr(port), (pcr & ~pcr_matrix_mask) | (enable ? pcr_matrix(1 << cpu_port) : 0));
}

// GE2's MAC is forced to what its PHY negotiated; the switch ports' link lives in the MT7530.
void set_link(uint slot, bool up, bool full_duplex)
{
    immutable bit = 1u << slot;
    _link_up = up ? _link_up | bit : _link_up & ~bit;
    if (slot == ge2_slot)
        mmio_write(fe_base + gmac1_mcr, (mcr_fixed_1g & ~(mcr_force_link | mcr_force_dpx)) | (up ? mcr_force_link : 0) | (full_duplex ? mcr_force_dpx : 0));
    if (_ports[slot].link !is null)
        _ports[slot].link(_ports[slot].context, up ? EthLinkEvent.up : EthLinkEvent.down);
}

bool phy_open()
{
    ushort ccr;
    if (!mdio_read(_ge2_phy, phy_chip_cfg, ccr))
        return false;
    if ((ccr & ccr_mode_mask) != ccr_bx1000_rgmii_50 && (ccr & ccr_mode_mask) != ccr_bx1000_rgmii_75)
        ccr = (ccr & ~ccr_mode_mask) | ccr_bx1000_rgmii_50;
    return mdio_write(_ge2_phy, phy_chip_cfg, ccr & ~ccr_copper_page) &&
           phy_debug_modify(0, dbg0_rx_clk_delay, 0) && phy_debug_modify(5, 0, dbg5_tx_clk_delay) &&
           mdio_write(_ge2_phy, phy_anar, bx_full_duplex | bx_pause) &&
           mdio_write(_ge2_phy, phy_bmcr, bmcr_aneg | bmcr_restart_aneg);
}

bool phy_close()
    => mdio_write(_ge2_phy, phy_bmcr, bmcr_power_down);

bool phy_debug_modify(ushort reg, ushort set, ushort clear)
{
    ushort v;
    return mdio_write(_ge2_phy, phy_debug_addr, reg) && mdio_read(_ge2_phy, phy_debug_data, v) &&
           mdio_write(_ge2_phy, phy_debug_addr, reg) && mdio_write(_ge2_phy, phy_debug_data, (v & ~clear) | set);
}

// BMSR's link bit latches low, so the second read is the live state; a link is up once negotiation has resolved it.
bool phy_link(out bool full_duplex)
{
    ushort bmsr, lpa;
    if (!mdio_read(_ge2_phy, phy_bmsr, bmsr) || !mdio_read(_ge2_phy, phy_bmsr, bmsr))
        return false;
    if ((bmsr & (bmsr_link | bmsr_aneg_done)) != (bmsr_link | bmsr_aneg_done) || !mdio_read(_ge2_phy, phy_lpa, lpa))
        return false;
    full_duplex = (lpa & bx_full_duplex) != 0;
    return true;
}

// Front ports start isolated: no forwarding and no learning until a port is opened.
bool switch_init()
{
    if (!sw_write(mt7530_pvc(cpu_port), pvc_spec_tag | pvc_eg_consistent) ||
        !sw_modify(mt7530_mfc, 0, mfc_flood_cpu) ||
        !sw_write(mt7530_pcr(cpu_port), pcr_matrix((1 << num_front_ports) - 1) | pcr_fallback))
        return false;
    foreach (p; 0 .. num_front_ports)
    {
        if (!sw_modify(mt7530_pcr(p), pcr_matrix_mask, 0) || !sw_modify(mt7530_psc(p), 0, psc_sa_dis) ||
            !sw_modify(mt7530_ppbv1(p), ppbv_vid_mask, 0) || !sw_modify(mt7530_pvc(p), pvc_eg_tag_mask, pvc_eg_consistent))
            return false;
    }
    return true;
}

// TODO: the switch and PHY interrupts, instead of polling once a second.
void poll_links()
{
    foreach (p; 0 .. num_front_ports)
    {
        immutable bit = 1u << p;
        if (!(_enabled & bit))
            continue;
        uint pmsr;
        if (!sw_read(mt7530_pmsr(p), pmsr))
            continue;
        immutable up = (pmsr & pmsr_link) != 0;
        if (up != ((_link_up & bit) != 0))
            set_link(p, up, true);
    }
    if (_enabled & (1u << ge2_slot))
    {
        bool full_duplex;
        immutable up = phy_link(full_duplex);
        if (up != ((_link_up & (1u << ge2_slot)) != 0))
            set_link(ge2_slot, up, full_duplex);
    }
}

void fe_irq_handler(uint)
{
    mmio_write(fe_base + pdma_irq_mask, 0);
    mmio_write(fe_base + pdma_irq_status, pdma_rx_done_int0);
    if (_ready_callback !is null)
        _ready_callback();
}

bool mdio(uint cmd, uint phy, uint reg, uint data, out uint value)
{
    mmio_write(fe_base + phy_iac, phy_iac_access | phy_iac_start | cmd | (reg << 25) | (phy << 20) | data);
    foreach (k; 0 .. 100_000)
    {
        immutable v = mmio_read(fe_base + phy_iac);
        if (!(v & phy_iac_access))
        {
            value = v & 0xFFFF;
            return true;
        }
    }
    return false;
}

bool sw_read(uint reg, out uint value)
{
    uint lo, hi, unused;
    if (!mdio(phy_iac_write, mt7530_mdio_addr, 0x1F, (reg >> 6) & 0x3FF, unused) ||
        !mdio(phy_iac_read, mt7530_mdio_addr, (reg >> 2) & 0xF, 0, lo) ||
        !mdio(phy_iac_read, mt7530_mdio_addr, 0x10, 0, hi))
        return false;
    value = (hi << 16) | lo;
    return true;
}

bool sw_write(uint reg, uint value)
{
    uint unused;
    return mdio(phy_iac_write, mt7530_mdio_addr, 0x1F, (reg >> 6) & 0x3FF, unused) &&
           mdio(phy_iac_write, mt7530_mdio_addr, (reg >> 2) & 0xF, value & 0xFFFF, unused) &&
           mdio(phy_iac_write, mt7530_mdio_addr, 0x10, value >> 16, unused);
}

bool sw_modify(uint reg, uint clear, uint set)
{
    uint value;
    return sw_read(reg, value) && sw_write(reg, (value & ~clear) | set);
}

// Waits for the frame engine to release up to `desc` and hands it back; one frame is in flight at a time.
// TODO: reclaim asynchronously from the release ring instead of waiting per frame.
bool tx_released(uint desc)
{
    foreach (k; 0 .. tx_release_polls)
    {
        if (mmio_read(fe_base + qdma_drx_ptr) == desc)
        {
            mmio_write(fe_base + qdma_crx_ptr, desc);
            return true;
        }
    }
    return false;
}
