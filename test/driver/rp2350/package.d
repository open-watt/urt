// The parts of the RP2350 platform package the UART, GPIO and event backends use.
module urt.driver.rp2350;

import core.volatile;

nothrow @nogc:

enum ulong resets_base      = 0x40020000;
enum ulong io_bank0_base    = 0x40028000;
enum ulong pads_bank0_base  = 0x40038000;

enum uint clk_peri_hz = 150_000_000;

enum ulong reg_alias_set    = 0x00002000;
enum ulong reg_alias_clr    = 0x00003000;
enum ulong resets_reset     = 0x00;
enum ulong resets_done      = 0x08;

enum uint reset_uart0       = 1 << 26;
enum uint reset_uart1       = 1 << 27;
enum uint reset_io_bank0    = 1 << 6;
enum uint reset_pads_bank0  = 1 << 9;

void unreset_wait(uint bits)
{
    mmio_write(resets_base + resets_reset + reg_alias_clr, bits);
    while ((mmio_read(resets_base + resets_done) & bits) != bits)
    {}
}

bool out_of_reset(uint bits)
    => (mmio_read(resets_base + resets_done) & bits) == bits;

void reset_pulse(uint bits)
{
    mmio_write(resets_base + resets_reset + reg_alias_set, bits);
    unreset_wait(bits);
}

void mmio_write(ulong addr, uint val)
{
    volatileStore(cast(uint*)addr, val);
}

uint mmio_read(ulong addr)
{
    return volatileLoad(cast(uint*)addr);
}

void pad_input_enable(uint gpio)
{
    enum uint pad_ie  = 1 << 6;
    enum uint pad_iso = 1 << 8;
    immutable ulong pad = pads_bank0_base + 0x04 + gpio * 4;
    mmio_write(pad, (mmio_read(pad) & ~pad_iso) | pad_ie);
}

void gpio_route(uint gpio, uint funcsel, bool input)
{
    enum uint pad_ie  = 1 << 6;
    enum uint pad_od  = 1 << 7;
    enum uint pad_iso = 1 << 8;

    immutable ulong pad  = pads_bank0_base + 0x04 + gpio * 4;
    immutable ulong ctrl = io_bank0_base + 0x04 + gpio * 8;
    uint p = mmio_read(pad) & ~(pad_iso | pad_od | pad_ie);
    if (input)
        p |= pad_ie;
    mmio_write(pad, p);
    mmio_write(ctrl, funcsel);
}
