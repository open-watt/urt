// RP2350 GPIO0-47 through SIO. The pad and IO_BANK0 routing is urt.driver.rp2350.gpio_route.
module urt.driver.rp2350.gpio;

import urt.driver.gpio : DriveMode, Pull;
import urt.driver.rp2350 : gpio_route, mmio_read, mmio_write, pads_bank0_base, reset_io_bank0, reset_pads_bank0, unreset_wait;

nothrow @nogc:

enum uint num_gpio = 48;
enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = false;
enum bool has_gpio_sampler = false;

uint gpio_count()
    => num_gpio;

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(mode == DriveMode.push_pull, "rp2350 gpio: no open-drain");
    claim(pin, false);
    gpio_output_set(pin, initial);
    mmio_write(sio_base + bank(sio_oe_set, pin), bit(pin));
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    claim(pin, true);
    mmio_write(sio_base + bank(sio_oe_clr, pin), bit(pin));
    gpio_set_pull(pin, pull);
}

void gpio_output_set(uint pin, bool value)
{
    mmio_write(sio_base + bank(value ? sio_out_set : sio_out_clr, pin), bit(pin));
}

void gpio_output_toggle(uint pin)
{
    mmio_write(sio_base + bank(sio_out_xor, pin), bit(pin));
}

bool gpio_input_read(uint pin)
    => (mmio_read(sio_base + bank(sio_in, pin)) & bit(pin)) != 0;

void gpio_set_pull(uint pin, Pull pull)
{
    enum uint pad_pde = 1 << 2;
    enum uint pad_pue = 1 << 3;
    immutable ulong pad = pads_bank0_base + 0x04 + pin * 4;
    uint p = mmio_read(pad) & ~(pad_pue | pad_pde);
    if (pull == Pull.up)
        p |= pad_pue;
    else if (pull == Pull.down)
        p |= pad_pde;
    mmio_write(pad, p);
}

void gpio_release(uint pin)
{
    mmio_write(sio_base + bank(sio_oe_clr, pin), bit(pin));
    gpio_route(pin, funcsel_null, false);
}


private:

enum ulong sio_base = 0xD000_0000;

// each register's twin for GPIO32-47 is the word above it
enum uint sio_in      = 0x04;
enum uint sio_out_set = 0x18;
enum uint sio_out_clr = 0x20;
enum uint sio_out_xor = 0x28;
enum uint sio_oe_set  = 0x38;
enum uint sio_oe_clr  = 0x40;

enum uint funcsel_sio  = 5;
enum uint funcsel_null = 0x1F;

uint bank(uint reg, uint pin)
    => reg + (pin >> 5) * 4;

uint bit(uint pin)
    => 1u << (pin & 31);

void claim(uint pin, bool input)
{
    assert(pin < num_gpio, "rp2350 gpio: no such line");
    unreset_wait(reset_io_bank0 | reset_pads_bank0);
    gpio_route(pin, funcsel_sio, input);
}
