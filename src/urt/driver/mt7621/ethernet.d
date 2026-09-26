module urt.driver.mt7621.ethernet;

import urt.driver.ethernet : EthernetConfig, EthLinkCallback, EthLinkEvent, EthLinkInfo, EthReadyCallback, EthRxCallback, EthRxInfo, EthSpeed;
import urt.driver.mt7621 : mmio_read, mmio_write;
import urt.system : sleep;
import urt.time : msecs;

nothrow @nogc:

// GE1 fronts the MT7530: frames to and from the CPU port carry the MediaTek special tag, which this
// driver adds and strips so callers see plain frames plus a front-port number. GE2 is not driven yet.
enum uint num_ethernet = 1;
enum bool has_eth_timestamp = false;
enum bool has_eth_gigabit = true;
enum bool has_eth_pin_select = false;
enum bool has_eth_tx_checksum = false;

enum uint num_front_ports = 5;

const(char)[] eth_hw_name(uint mac)
    => "ge1";

uint eth_hw_ports(uint mac)
    => num_front_ports;

// Runs from sys_init, before any interface opens, so early output can already leave the box.
void fe_init()
{
    immutable adrh = mmio_read(fe_base + gdma1_mac_adrh);
    immutable adrl = mmio_read(fe_base + gdma1_mac_adrl);
    _base_mac = [cast(ubyte)(adrh >> 8), cast(ubyte)adrh, cast(ubyte)(adrl >> 24), cast(ubyte)(adrl >> 16),
                 cast(ubyte)(adrl >> 8), cast(ubyte)adrl];

    import urt.driver.mt7621 : sysctl_base, sysc_rstctrl;
    enum uint rst_eth_fe_ppe0 = (1 << 23) | (1 << 6) | (1u << 31);
    mmio_write(sysctl_base + sysc_rstctrl, mmio_read(sysctl_base + sysc_rstctrl) | rst_eth_fe_ppe0);
    sleep(1.msecs);
    mmio_write(sysctl_base + sysc_rstctrl, mmio_read(sysctl_base + sysc_rstctrl) & ~rst_eth_fe_ppe0);
    sleep(10.msecs);

    mmio_write(fe_base + gmac0_mcr, mcr_fixed_1g);
    mmio_write(fe_base + gdma1_fwd_cfg, (mmio_read(fe_base + gdma1_fwd_cfg) & 0xFFFF_0000) | gdma_special_tag | gdma_strip_crc);
    mmio_write(fe_base + cdmq_ig_ctrl, mmio_read(fe_base + cdmq_ig_ctrl) | cdm_stag_en);
    mmio_write(fe_base + cdmp_ig_ctrl, mmio_read(fe_base + cdmp_ig_ctrl) | cdm_stag_en);
    mmio_write(fe_base + cdmp_eg_ctrl, 1);

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
    if (!_ready || !port_enable(port, true))
        return false;
    _ports[port] = Port(rx, link, context);
    if (_enabled == 1u << port)
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
    if (!port_enable(port, false))
        return false;
    _ports[port] = Port.init;
    if (_enabled == 0)
    {
        import urt.driver.mt7621.irq : irq_clear_enable;
        mmio_write(fe_base + pdma_irq_mask, 0);
        irq_clear_enable(fe_irq);
    }
    return true;
}

bool eth_hw_tx(uint mac, uint port, const(ubyte)[] frame, bool insert_checksum)
    => fe_tx_tagged(frame, 1u << port);

bool eth_hw_checksum_insertable(uint mac, uint port, const(ubyte)[] frame)
    => false;

// Front port n takes the base address plus n, as RouterOS numbers etherN.
bool eth_hw_get_hardware_address(uint mac, uint port, ref ubyte[6] address)
{
    if (_base_mac == typeof(_base_mac).init)
        return false;
    address = _base_mac;
    immutable low = (address[3] << 16 | address[4] << 8 | address[5]) + port;
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
        immutable len = (d2 >> 16) & 0x3FFF;
        // The frame engine untags the special tag itself, leaving the source port in rxd3.
        immutable source = (d[2] >> 16) & 7;
        if (len < 14 || !(d2 & rxd2_vtag) || source >= num_front_ports)
            ++_rx_drops;
        else if (_ports[source].rx is null)
            ++_ports[source].drops;
        else
        {
            EthRxInfo info;
            _ports[source].rx(_ports[source].context, (_rx_buf + i * rx_buf_size)[0 .. len], info);
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
        poll_switch_links();
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
    immutable dropped = _ports[port].drops;
    _ports[port].drops = 0;
    return dropped;
}

bool fe_tx_tagged(const(ubyte)[] frame, uint port_mask)
{
    if (!_ready || frame.length < 14 || frame.length + 4 > tx_buf_size)
        return false;
    if (!tx_released(tx_desc_phys((_tx_next + tx_count - 1) % tx_count)))
        return false;

    immutable i = _tx_next;
    ubyte* f = _tx_buf + i * tx_buf_size;
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

    uint* d = _tx + i * 4;
    d[0] = phys(cast(uint)f);
    d[3] = txd4_fport_gdm1;
    asm nothrow @nogc { "sync" ::: "memory"; }
    d[2] = txd3_swc | (len << 16) | txd3_ls0;
    asm nothrow @nogc { "sync" ::: "memory"; }
    _tx_next = (i + 1) % tx_count;
    mmio_write(fe_base + qdma_ctx_ptr, tx_desc_phys(_tx_next));
    return tx_released(tx_desc_phys(i));
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
enum uint cdmp_ig_ctrl    = 0x400;
enum uint cdmp_eg_ctrl    = 0x404;
enum uint cdmq_ig_ctrl    = 0x1400;
enum uint gmac0_mcr       = 0x1_0100;
enum uint phy_iac         = 0x1_0004;

enum uint gdma_special_tag = 1 << 24;
enum uint gdma_strip_crc   = 1 << 16;
enum uint cdm_stag_en      = 1 << 0;
enum uint mcr_fixed_1g     = 0x0105_E33B;   // max RX 1536, forced 1G full duplex with pause, TX/RX on

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
enum uint rxd2_ddone      = 1u << 31;
enum uint rxd2_vtag       = 1 << 15;

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

struct Port
{
    EthRxCallback rx;
    EthLinkCallback link;
    void* context;
    uint drops;
}

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
__gshared Port[num_front_ports] _ports;
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

bool port_enable(uint port, bool enable)
{
    uint pcr;
    if (!sw_read(mt7530_pcr(port), pcr) || !sw_write(mt7530_pcr(port), (pcr & ~pcr_matrix_mask) | (enable ? pcr_matrix(1 << cpu_port) : 0)))
        return false;
    immutable bit = 1u << port;
    _enabled = enable ? _enabled | bit : _enabled & ~bit;
    if (!enable && (_link_up & bit))
    {
        _link_up &= ~bit;
        if (_ports[port].link !is null)
            _ports[port].link(_ports[port].context, EthLinkEvent.down);
    }
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

// TODO: the switch interrupt, instead of polling once a second.
void poll_switch_links()
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
        if (up == ((_link_up & bit) != 0))
            continue;
        _link_up = up ? _link_up | bit : _link_up & ~bit;
        if (_ports[p].link !is null)
            _ports[p].link(_ports[p].context, up ? EthLinkEvent.up : EthLinkEvent.down);
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
