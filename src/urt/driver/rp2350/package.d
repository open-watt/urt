module urt.driver.rp2350;

public import urt.driver.rp2350.uart;
public import urt.driver.rp2350.irq;
public import urt.driver.rp2350.timer;

import urt.driver.uart : UartConfig;
import core.volatile;

@nogc nothrow:

enum ulong resets_base      = 0x40020000;
enum ulong clocks_base      = 0x40010000;
enum ulong xosc_base        = 0x40048000;
enum ulong pll_sys_base     = 0x40050000;
enum ulong io_bank0_base    = 0x40028000;
enum ulong pads_bank0_base  = 0x40038000;
enum ulong ticks_base       = 0x40108000;

enum uint xosc_hz     = 12_000_000;
enum uint clk_sys_hz  = 150_000_000;
enum uint clk_peri_hz = clk_sys_hz;

enum ulong reg_alias_clr    = 0x00003000;

enum ulong resets_reset     = 0x00;
enum ulong resets_done      = 0x08;

enum uint reset_uart0       = 1 << 26;
enum uint reset_uart1       = 1 << 27;
enum uint reset_io_bank0    = 1 << 6;
enum uint reset_pads_bank0  = 1 << 9;
enum uint reset_pll_sys     = 1 << 14;
enum uint reset_trng        = 1 << 25;

void unreset_wait(uint bits)
{
    mmio_write(resets_base + resets_reset + reg_alias_clr, bits);
    while ((mmio_read(resets_base + resets_done) & bits) != bits)
    {}
}

void gpio_route_uart(uint gpio, uint funcsel, bool input)
{
    enum uint pad_ie  = 1 << 6;
    enum uint pad_od  = 1 << 7;
    enum uint pad_iso = 1 << 8;

    immutable ulong pad  = pads_bank0_base + 0x04 + gpio * 4;
    immutable ulong ctrl = io_bank0_base + 0x04 + gpio * 8;

    // ISO is set out of reset and gates the pad until it is cleared.
    uint p = mmio_read(pad) & ~(pad_iso | pad_od | pad_ie);
    if (input)
        p |= pad_ie;
    mmio_write(pad, p);
    mmio_write(ctrl, funcsel);
}

extern(C) void sys_init()
{
    clocks_init();
    uart_hw_init(console_uart, UartConfig.init);
    uart0_hw_puts("RP2350: sys_init\r\n");

    __register_frame_info(&__eh_frame_start, &__eh_frame_object);
    ticks_init();
    timer_init(clk_sys_hz / 20 - 1);

    uart0_hw_puts("RP2350: ready\r\n");
}

private:

extern(C) void __register_frame_info(const void*, void*);
extern(C) extern const ubyte __eh_frame_start;
align(8) ubyte[48] __eh_frame_object;

void mmio_write(ulong addr, uint val)
{
    volatileStore(cast(uint*)addr, val);
}

uint mmio_read(ulong addr)
{
    return volatileLoad(cast(uint*)addr);
}

void pll_sys_init()
{
    enum uint refdiv   = 1;
    enum uint fbdiv    = 125;
    enum uint postdiv1 = 5;
    enum uint postdiv2 = 2;

    enum uint vco_hz = xosc_hz / refdiv * fbdiv;
    static assert(vco_hz >= 750_000_000 && vco_hz <= 1_600_000_000, "PLL VCO out of range");
    static assert(vco_hz / (postdiv1 * postdiv2) == clk_sys_hz, "PLL postdivs do not yield clk_sys_hz");

    enum ulong pll_cs    = pll_sys_base + 0x00;
    enum ulong pll_pwr   = pll_sys_base + 0x04;
    enum ulong pll_fbdiv = pll_sys_base + 0x08;
    enum ulong pll_prim  = pll_sys_base + 0x0C;

    unreset_wait(reset_pll_sys);

    mmio_write(pll_cs, refdiv);
    mmio_write(pll_fbdiv, fbdiv);
    mmio_write(pll_pwr + reg_alias_clr, 0x21);      // PD | VCOPD
    while (!(mmio_read(pll_cs) & 0x8000_0000))
    {}
    mmio_write(pll_prim, (postdiv1 << 16) | (postdiv2 << 12));
    mmio_write(pll_pwr + reg_alias_clr, 0x08);      // POSTDIVPD
}

void clocks_init()
{
    enum ulong xosc_ctrl    = xosc_base + 0x00;
    enum ulong xosc_status  = xosc_base + 0x04;
    enum ulong xosc_startup = xosc_base + 0x0C;

    mmio_write(xosc_startup, (xosc_hz / 1000 + 128) / 256);
    mmio_write(xosc_ctrl, 0xAA0 | (0xFAB << 12));   // FREQ_RANGE 1_15MHZ, ENABLE
    while (!(mmio_read(xosc_status) & 0x8000_0000))
    {}

    enum ulong clk_ref_ctrl      = clocks_base + 0x30;
    enum ulong clk_ref_div       = clocks_base + 0x34;
    enum ulong clk_ref_selected  = clocks_base + 0x38;
    enum ulong clk_sys_ctrl      = clocks_base + 0x3C;
    enum ulong clk_sys_selected  = clocks_base + 0x44;
    enum ulong clk_peri_ctrl     = clocks_base + 0x48;

    mmio_write(clk_ref_ctrl, 2);                    // src = XOSC
    while (!(mmio_read(clk_ref_selected) & (1 << 2)))
    {}
    mmio_write(clk_ref_div, 1 << 16);

    pll_sys_init();

    // clk_sys has a glitchless mux: park on clk_ref before retargeting aux.
    mmio_write(clk_sys_ctrl, 0);
    while (!(mmio_read(clk_sys_selected) & 1))
    {}
    mmio_write(clk_sys_ctrl, 1);                    // auxsrc = PLL_SYS, src = aux
    while (!(mmio_read(clk_sys_selected) & (1 << 1)))
    {}

    mmio_write(clk_peri_ctrl, 0);
    mmio_write(clk_peri_ctrl, 1 << 11);             // ENABLE, auxsrc = clk_sys
}

void ticks_init()
{
    enum ulong ticks_timer0_ctrl   = ticks_base + 0x18;
    enum ulong ticks_timer0_cycles = ticks_base + 0x1C;

    mmio_write(ticks_timer0_ctrl, 0);
    mmio_write(ticks_timer0_cycles, xosc_hz / 1_000_000);
    mmio_write(ticks_timer0_ctrl, 1);
}
