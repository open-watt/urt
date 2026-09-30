// RP2350 PWM: twelve slices of two channels. A port is slice * 2 + channel, and each GPIO reaches
// exactly one. The two channels of a slice share its counter, so they must agree on period and clock.
module urt.driver.rp2350.pwm;

import urt.driver.gpio : GpioLine;
import urt.driver.pwm : PwmConfig;
import urt.driver.rp2350 : clk_sys_hz, gpio_route, mmio_read, mmio_write, reset_io_bank0, reset_pads_bank0, reset_pwm, unreset_wait;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_hw_pwm = 24;

bool pwm_hw_reaches(uint port, GpioLine line)
    => line.chip == 0 && line.line < 48 && port == port_of(line.line);

bool pwm_hw_shares(uint a, uint b)
    => a >> 1 == b >> 1;

// A full duty needs a compare above the wrap, so the period stops one short of the 16-bit counter.
Result pwm_hw_open(uint port, ref const PwmConfig config)
{
    ushort div;
    if (!pwm_hw_reaches(port, config.output) || config.period > 0xFFFF || !clock_divider(config.frequency, config.period, div))
        return InternalResult.invalid_parameter;

    immutable ushort top = cast(ushort)(config.period - 1);
    Slice* s = &_slices[port >> 1];
    if (s.users && (s.top != top || s.div != div))
        return InternalResult.failed;

    if (!s.users)
    {
        unreset_wait(reset_pwm | reset_io_bank0 | reset_pads_bank0);
        mmio_write(reg(port, csr), 0);
        mmio_write(reg(port, divr), div);
        mmio_write(reg(port, topr), top);
        mmio_write(reg(port, ctr), 0);
        s.top = top;
        s.div = div;
    }
    ++s.users;
    set_cc(port, config.initial_duty);
    immutable uint invert = (port & 1) ? csr_b_inv : csr_a_inv;
    uint c = mmio_read(reg(port, csr)) & ~invert;
    mmio_write(reg(port, csr), c | (config.inverted ? invert : 0) | csr_en);
    gpio_route(config.output.line, funcsel_pwm, false);
    return Result.success;
}

Result pwm_hw_set_duty(uint port, uint duty)
{
    set_cc(port, duty);
    return Result.success;
}

void pwm_hw_close(uint port)
{
    set_cc(port, 0);
    Slice* s = &_slices[port >> 1];
    if (--s.users == 0)
        mmio_write(reg(port, csr), 0);
}


private:

enum ulong pwm_base = 0x400A_8000;
enum uint slice_stride = 0x14;
enum uint csr  = 0x00;
enum uint divr = 0x04;
enum uint ctr  = 0x08;
enum uint cc   = 0x0C;
enum uint topr = 0x10;
enum uint csr_en    = 1 << 0;
enum uint csr_a_inv = 1 << 2;
enum uint csr_b_inv = 1 << 3;
enum uint funcsel_pwm = 4;

struct Slice
{
    ushort top;
    ushort div;
    ubyte users;
}

__gshared Slice[12] _slices;

uint port_of(uint gpio)
    => (gpio < 32 ? (gpio >> 1) & 7 : 8 + ((gpio >> 1) & 3)) * 2 + (gpio & 1);

ulong reg(uint port, uint offset)
    => pwm_base + (port >> 1) * slice_stride + offset;

// clk_sys over frequency * period as the 8.4 divider, which runs from 1 to 255 15/16
bool clock_divider(uint frequency, uint period, out ushort div) pure
{
    immutable ulong divider = ulong(clk_sys_hz) * 16 / (ulong(frequency) * period);
    if (divider < 16 || divider > 0xFFF)
        return false;
    div = cast(ushort)divider;
    return true;
}

// a compare above top holds the output high all period
void set_cc(uint port, uint duty)
{
    immutable uint shift = (port & 1) * 16;
    uint c = mmio_read(reg(port, cc)) & ~(0xFFFFu << shift);
    mmio_write(reg(port, cc), c | (duty << shift));
}


unittest
{
    assert(port_of(25) == 9, "GPIO25 is slice 4 channel B");
    assert(port_of(0) == 0 && port_of(16) == 0, "GPIO16 shares slice 0 channel A with GPIO0");
    assert(port_of(32) == 16 && port_of(47) == 23, "GPIO32-47 are slices 8-11");

    ushort div;
    assert(clock_divider(4000, 256, div) && div == 2343, "4 kHz at period 256 is a divider of 146.4375");
    assert(!clock_divider(1000, 256, div), "1 kHz at period 256 needs a divider above 255");
    assert(!clock_divider(1, 256, div), "1 Hz at period 256 is beyond the divider");
    assert(!clock_divider(2_000_000, 256, div), "2 MHz at period 256 needs a divider below one");
}
