// BL808 M0 chip init and D0 launch
//
// m0_bringup() runs from start.S before sys_init: chip-wide power, clocks,
// PSRAM, L2 partition, then D0 launch. D0's own start.S spins ~80ms
// waiting for M0 to finish clock setup, so launching it here (well before
// M0's main() loop comes up) is safe -- both cores run in parallel from
// that point, and M0's XRAM rings are ready by the time D0 needs IPC.
module urt.driver.bl808_m0.start;

import core.volatile;
import urt.attribute : critical;
import urt.zip : uncompress;
import urt.driver.bl618.uart : uart0_early_init, uart0_hw_puts;
import urt.driver.bl_common.clock : d0_clock_hz, m0_clock_hz, mtime_hz;
import urt.driver.bl_common.xram : xram_reset;

@nogc nothrow:

// M1s Dock: UART0 -> BL702 USB-CDC bridge on GPIO14 (TX) / GPIO15 (RX).
// Confirmed from bl_iot_sdk/customer_app/bl808/bl808_demo_linux/main.c#L74.
private enum uint M0_CONSOLE_TX_PIN = 14;
private enum uint M0_CONSOLE_RX_PIN = 15;
private enum uint M0_CONSOLE_BAUD   = 2_000_000;

extern(C) void m0_bringup()
{
    mtime_config(MCU_E907_RTC, m0_clock_hz);
    xram_uncached();
    mm_domain_power_on();
    bl_cpupll_480m();
    mm_clk_config();
    mcu2ext_bus_threshold();
    uart_signal_mux();
    uart0_early_init(M0_CONSOLE_TX_PIN, M0_CONSOLE_RX_PIN, M0_CONSOLE_BAUD);
    uart0_hw_puts("\nBL808 M0: startup\n");
    wifi_em_carveout();
    psram_init();
    l2_sram_partition();
    launch_d0();
}

private void launch_d0()
{
    uint entry = d0_image_load();
    if (!entry)
    {
        uart0_hw_puts("BL808 M0: no valid D0 image, D0 stays halted\n");
        return;
    }
    d0_console_pins();
    mtime_config(MM_MISC_CPU_RTC, d0_clock_hz);
    d0_halt();
    mmio_write(MM_MISC_CPU0_BOOT, entry);
    xram_reset();
    dcache_clean_all();
    d0_release();
    mtime_zero();
}

private:

enum uint PDS_CTL2              = 0x2000_E010;
enum uint MM_CLK_CTRL_CPU       = 0x3000_7000;
enum uint MM_CLK_CTRL_PERI      = 0x3000_7010;
enum uint MCU_MISC_MCU_BUS_CFG1 = 0x2000_9004;
enum uint GLB_PARM_CFG0         = 0x2000_0510;
enum uint MM_MISC_VRAM_CTRL     = 0x3000_0050;
enum uint MM_MISC_CPU0_BOOT     = 0x3000_0000;
enum uint MM_GLB_SW_SYS_RESET   = 0x3000_7040;
enum uint MM_MISC_CPU_RTC       = 0x3000_0018;
enum uint MCU_E907_RTC          = 0x2000_9014;
enum uint GLB_GPIO_CFG0         = 0x2000_08C4;

struct D0Run
{
    uint dest;
    uint size;
}

extern(C) extern immutable(ubyte) _d0_image, _image_limit;

extern(C) void bl_psram_init();
extern(C) void bl_cpupll_480m();

pragma(inline, true) uint mmio_read(uint addr)
{
    return volatileLoad(cast(uint*)cast(size_t)addr);
}

pragma(inline, true) void mmio_write(uint addr, uint val)
{
    volatileStore(cast(uint*)cast(size_t)addr, val);
}

pragma(inline, true) void mmio_clear_bit(uint addr, uint bit)
{
    mmio_write(addr, mmio_read(addr) & ~(uint(1) << bit));
}

pragma(inline, true) void mmio_set_bit(uint addr, uint bit)
{
    mmio_write(addr, mmio_read(addr) | (uint(1) << bit));
}

pragma(inline, true) void mmio_set_field(uint addr, uint shift, uint mask, uint value)
{
    uint v = mmio_read(addr);
    v = (v & ~(mask << shift)) | ((value & mask) << shift);
    mmio_write(addr, v);
}

@critical pragma(inline, false) extern(C) void arch_delay_us(uint us)
{
    // The low 32 bits roll over every ~27 s; we only ever wait microseconds.
    uint start, now;
    asm @nogc nothrow { "rdtime %0" : "=r" (start); }
    do
    {
        asm @nogc nothrow { "rdtime %0" : "=r" (now); }
    }
    while ((now - start) < us * (mtime_hz / 1_000_000));
}

// Carve 64KB of WRAM as WiFi MAC "Embedded Memory" (EM). Vendor's libwifi.a
// was built expecting this split when BLE is compiled in, and at least one
// community Sipeed-fork SDK confirms WiFi-AP fails silently without it --
// beacons get queued into a buffer the RF DMA never reads. EM is LMAC's
// private DMA region; the CPU never touches it, so this does not collide
// with our linker layout. Done in m0_bringup before any other init so the
// SRAM controller settles before stack-heavy code runs.
//
// GLB_SRAM_CFG3 @ GLB_BASE + 0x60C, field GLB_EM_SEL [7:0]:
//   0x00 -> 160K WRAM + 0K EM (reset default; what crashed earlier was
//           NOT this; see below)
//   0xFF -> 96K WRAM + 64K EM (vendor wifi+ble default)
//
// Previously failed when written from chip_post_init -- by that point the
// stack is live and writing the register while CPU is mid-routine appears
// to glitch SRAM. Running here from m0_bringup, with only the early start.S
// stack in DTCM aliasing, is the same place vendor calls equivalent code
// from System_Init.
void wifi_em_carveout()
{
    enum uint GLB_SRAM_CFG3 = 0x2000_060C;
    mmio_set_field(GLB_SRAM_CFG3, 0, 0xFF, 0xFF);
}

void mcu2ext_bus_threshold()
{
    // Vendor bl_sys_reduce_mcu2ext(): MCU_MISC.MCU_BUS_CFG1
    // REG_X_WTHRE_MCU2EXT = 3.
    mmio_set_field(MCU_MISC_MCU_BUS_CFG1, 7, 0x3, 3);
}

// Boot leaves M0's D-cache on in write-back mode with a SYSMAP whose cacheable region starts at
// XRAM. Region 0 (strongly ordered: MMIO and uncached SRAM) is extended over XRAM so writes to
// the inter-core rings reach D0.
void xram_uncached()
{
    enum uint SYSMAPADDR0 = 0xEFFF_F000;
    mmio_write(SYSMAPADDR0, 0x4000_4000 >> 12);
    asm @nogc nothrow { "fence rw, rw"; }
}

// th.dcache.call, th.sync.s: D0 must see the image M0 wrote through its write-back cache. The
// T-Head cache instructions are outside the ISA LLVM targets for this core.
void dcache_clean_all()
{
    asm @nogc nothrow { ".word 0x0010000B"; ".word 0x0190000B" ::: "memory"; }
}

void mm_domain_power_on()
{
    // PDS_CTL2: ordered de-isolation/power-up sequence; bit 1 first, settle, then 5/17/13/9
    mmio_clear_bit(PDS_CTL2, 1);
    arch_delay_us(45);
    mmio_clear_bit(PDS_CTL2, 5);
    mmio_clear_bit(PDS_CTL2, 17);
    mmio_clear_bit(PDS_CTL2, 13);
    mmio_clear_bit(PDS_CTL2, 9);
}

void mm_clk_config()
{
    mmio_set_field(MM_CLK_CTRL_CPU, 10, 0x1, 1);   // XCLK_CLK_SEL    = XTAL
    mmio_set_field(MM_CLK_CTRL_CPU, 13, 0x3, 2);   // BCLK1X_SEL      = 160MHz PLL
    mmio_set_field(MM_CLK_CTRL_CPU, 11, 0x1, 1);   // CPU_ROOT_CLK    = PLL
    mmio_set_field(MM_CLK_CTRL_CPU,  8, 0x3, 2);   // CPU_CLK_SEL     = CPU PLL
    mmio_set_field(MM_CLK_CTRL_CPU,  4, 0x3, 2);   // UART_CLK_SEL    = XCLK
    mmio_set_field(MM_CLK_CTRL_CPU,  6, 0x1, 1);   // I2C_CLK_SEL     = XCLK
    mmio_set_field(MM_CLK_CTRL_PERI, 16, 0xF, 1);  // UART0 (D0's UART3): DIV_EN, DIV = 0
}

void uart_signal_mux()
{
    // UART_SWAP_SET: bit 3 = GPIO12-23 group, bit 5 = GPIO36-45 group
    mmio_set_bit(GLB_PARM_CFG0, 3);
    mmio_set_bit(GLB_PARM_CFG0, 5);
}

void psram_init()
{
    bl_psram_init();
}

void l2_sram_partition()
{
    uint v = mmio_read(MM_MISC_VRAM_CTRL);
    v |= uint(1) << 4;             // L2_SRAM_REL = 1 (64KB L2, 0KB VRAM)
    v &= ~(uint(0x3) << 1);        // PF_SRAM_REL = 0 (192KB PFH)
    v &= ~(uint(1) << 7);          // APU_SRAM_REL = 0 (128KB APU)
    v &= ~(uint(1) << 6);          // DSP2_SRAM_REL = 0 (64KB DSP2)
    mmio_write(MM_MISC_VRAM_CTRL, v);

    // commit bit must be a separate write after the partition fields settle
    mmio_set_bit(MM_MISC_VRAM_CTRL, 0);
}

// Payload from tools/bl808_image.py: entry, run count, the runs, then one raw-deflate stream per run.
uint d0_image_load()
{
    const(uint)* header = cast(const(uint)*)&_d0_image;
    const(ubyte)* limit = &_image_limit;
    uint entry = header[0];
    uint count = header[1];
    const(D0Run)* table = cast(const(D0Run)*)(header + 2);
    if (count == 0 || (limit - cast(const(ubyte)*)table) / D0Run.sizeof <= count)
        return 0;
    const(ubyte)* streams = cast(const(ubyte)*)(table + count);
    const(ubyte)[] src = streams[0 .. limit - streams];

    foreach (ref run; table[0 .. count])
    {
        size_t written, consumed;
        if (uncompress(src, (cast(void*)cast(size_t)run.dest)[0 .. run.size], written, &consumed).failed || written != run.size)
            return 0;
        src = src[consumed .. $];
    }
    return entry;
}

// M1s Dock: D0's UART3 reaches the BL702's second channel on GPIO16 (TX) / GPIO17 (RX).
// MM_UART is function 21; the pad's index picks the signal (16 = TXD, 17 = RXD).
void d0_console_pins()
{
    enum uint mm_uart_pad = (21 << 8) | (1 << 4) | (1 << 2) | (1 << 1) | (1 << 0);   // FUNC_SEL, PU, DRV=1, SMT, IE
    mmio_write(GLB_GPIO_CFG0 + 16 * 4, mm_uart_pad);
    mmio_write(GLB_GPIO_CFG0 + 17 * 4, mm_uart_pad);
}

// DIV [9:0] is the core clock's divisor less one; bit 30 holds the counter at zero, bit 31 enables it.
void mtime_config(uint reg, uint clock_hz)
{
    mmio_clear_bit(reg, 31);
    mmio_set_field(reg, 0, 0x3FF, clock_hz / mtime_hz - 1);
    mmio_set_bit(reg, 31);
}

// D0's counter only runs once D0 is released, and D0 reads no time before its start-up spin ends.
void mtime_zero()
{
    enum uint hold = 1 << 30;
    uint m0 = mmio_read(MCU_E907_RTC) & ~hold;
    uint d0 = mmio_read(MM_MISC_CPU_RTC) & ~hold;
    mmio_write(MCU_E907_RTC, m0 | hold);
    mmio_write(MM_MISC_CPU_RTC, d0 | hold);
    mmio_write(MM_MISC_CPU_RTC, d0);
    mmio_write(MCU_E907_RTC, m0);
}

void d0_halt()
{
    mmio_clear_bit(MM_CLK_CTRL_CPU, 12);            // MMCPU0_CLK_EN
    arch_delay_us(1);
    mmio_set_bit(MM_GLB_SW_SYS_RESET, 8);           // MMCPU0_RESET
}

void d0_release()
{
    mmio_set_bit(MM_CLK_CTRL_CPU, 12);
    arch_delay_us(1);
    mmio_clear_bit(MM_GLB_SW_SYS_RESET, 8);
}
