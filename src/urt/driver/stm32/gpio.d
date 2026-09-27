// STM32 GPIO. Every family shares the port register layout; only the port base and its clock
// gate move. Pins are numbered port * 16 + pin, so PA9 = 9 and PE3 = 67.
module urt.driver.stm32.gpio;

import urt.driver.gpio : DriveMode, Pull;
import urt.driver.stm32 : clock_enable, rcc_gpioenr, reg_read, reg_rmw, reg_write;

@nogc nothrow:

version (STM32F4)
    enum uint num_gpio = 9 * 16;        // PA..PI
else
    enum uint num_gpio = 11 * 16;       // PA..PK

enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = true;
enum bool has_pin_function_muxing = true;
enum bool has_gpio_sampler = false;

uint gpio_count() => num_gpio;

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    immutable base = port_open(pin);
    gpio_output_set(pin, initial);
    set_field(base + otyper, pin, 1, mode == DriveMode.open_drain);
    set_field(base + moder, pin, 2, mode_output);
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    immutable base = port_open(pin);
    set_field(base + pupdr, pin, 2, pull);
    set_field(base + moder, pin, 2, mode_input);
}

void gpio_output_set(uint pin, bool value)
{
    reg_write(port_base(pin) + bsrr, 1u << ((pin & 15) + (value ? 0 : 16)));
}

void gpio_output_toggle(uint pin)
{
    gpio_output_set(pin, !(reg_read(port_base(pin) + odr) & (1u << (pin & 15))));
}

bool gpio_input_read(uint pin) => (reg_read(port_base(pin) + idr) & (1u << (pin & 15))) != 0;

void gpio_set_pull(uint pin, Pull pull)
{
    set_field(port_base(pin) + pupdr, pin, 2, pull);
}

void gpio_release(uint pin)
{
    immutable base = port_base(pin);
    set_field(base + moder, pin, 2, mode_analog);
    set_field(base + pupdr, pin, 2, Pull.none);
}

// function_id is the alternate function number, AF0..AF15.
void gpio_set_function(uint pin, uint function_id, Pull pull = Pull.none, DriveMode mode = DriveMode.push_pull)
{
    assert(function_id < 16, "stm32 gpio: alternate function out of range");
    immutable base = port_open(pin);
    immutable ulong afr = base + ((pin & 15) < 8 ? afrl : afrh);
    reg_rmw(afr, 0xFu << ((pin & 7) * 4), function_id << ((pin & 7) * 4));
    set_field(base + otyper, pin, 1, mode == DriveMode.open_drain);
    set_field(base + ospeedr, pin, 2, 2);
    set_field(base + pupdr, pin, 2, pull);
    set_field(base + moder, pin, 2, mode_alternate);
}


private:

version (STM32H7)
    enum ulong gpio_base = 0x5802_0000;
else
    enum ulong gpio_base = 0x4002_0000;

enum uint moder   = 0x00;
enum uint otyper  = 0x04;
enum uint ospeedr = 0x08;
enum uint pupdr   = 0x0C;
enum uint idr     = 0x10;
enum uint odr     = 0x14;
enum uint bsrr    = 0x18;
enum uint afrl    = 0x20;
enum uint afrh    = 0x24;

enum uint mode_input     = 0;
enum uint mode_output    = 1;
enum uint mode_alternate = 2;
enum uint mode_analog    = 3;

ulong port_base(uint pin)
{
    assert(pin < num_gpio, "stm32 gpio: pin out of range");
    return gpio_base + (pin / 16) * 0x400;
}

ulong port_open(uint pin)
{
    immutable base = port_base(pin);
    clock_enable(rcc_gpioenr, pin / 16);
    return base;
}

void set_field(ulong reg, uint pin, uint width, uint value)
{
    immutable shift = (pin & 15) * width;
    immutable mask = ((1u << width) - 1) << shift;
    reg_rmw(reg, mask, value << shift);
}
