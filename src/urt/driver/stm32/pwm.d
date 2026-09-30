// STM32 PWM on the general-purpose timers TIM2, TIM3 and TIM4, four compare channels each; TIM5 is the timer
// layer's. A port is timer * 4 + channel, and the channels of a timer share its prescaler and period.
module urt.driver.stm32.pwm;

import urt.driver.gpio : GpioLine;
import urt.driver.pwm : PwmConfig;
import urt.driver.stm32 : apb1_timer_hz, clock_enable, rcc_apb1enr, reg_rmw, reg_write;
import urt.driver.stm32.gpio : gpio_release, gpio_set_function;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_hw_pwm = 12;

bool pwm_hw_reaches(uint port, GpioLine line)
{
    if (line.chip != 0 || port >= num_hw_pwm)
        return false;
    foreach (pin; pins[port])
    {
        if (pin == line.line)
            return true;
    }
    return false;
}

bool pwm_hw_shares(uint a, uint b)
    => a >> 2 == b >> 2;

// A full duty needs a compare above the auto-reload, so the period stops one short of the 16-bit counter.
Result pwm_hw_open(uint port, ref const PwmConfig config)
{
    ushort psc;
    if (!pwm_hw_reaches(port, config.output) || config.period == 0 || config.period > 0xFFFF || !prescaler(config.frequency, config.period, psc))
        return InternalResult.invalid_parameter;

    immutable ushort arr = cast(ushort)(config.period - 1);
    Timer* t = &_timers[port >> 2];
    if (t.users && (t.arr != arr || t.psc != psc))
        return InternalResult.failed;

    immutable ulong base = timer_base[port >> 2];
    if (!t.users)
    {
        clock_enable(rcc_apb1enr, port >> 2);
        reg_write(base + cr1, 0);
        reg_write(base + pscr, psc);
        reg_write(base + arrr, arr);
        reg_write(base + egr, egr_ug);
        reg_write(base + cr1, cr1_arpe | cr1_cen);
        t.arr = arr;
        t.psc = psc;
    }
    ++t.users;

    immutable uint ch = port & 3;
    reg_write(base + ccr + ch * 4, config.initial_duty);
    reg_rmw(base + (ch < 2 ? ccmr1 : ccmr2), 0xFFu << (ch & 1) * 8, (ocm_pwm1 | ocpe) << (ch & 1) * 8);
    reg_rmw(base + ccer, 0xFu << ch * 4, (ccer_e | (config.inverted ? ccer_p : 0)) << ch * 4);
    gpio_set_function(config.output.line, af[port >> 2]);
    _lines[port] = cast(ubyte)config.output.line;
    return Result.success;
}

Result pwm_hw_set_duty(uint port, uint duty)
{
    reg_write(timer_base[port >> 2] + ccr + (port & 3) * 4, duty);
    return Result.success;
}

// Several pins reach a channel, so the pin goes back to analog rather than carrying the next user's waveform.
void pwm_hw_close(uint port)
{
    immutable ulong base = timer_base[port >> 2];
    reg_rmw(base + ccer, 0xFu << (port & 3) * 4, 0);
    gpio_release(_lines[port]);
    if (--_timers[port >> 2].users == 0)
        reg_write(base + cr1, 0);
}


private:

enum uint cr1   = 0x00;
enum uint egr   = 0x14;
enum uint ccmr1 = 0x18;
enum uint ccmr2 = 0x1C;
enum uint ccer  = 0x20;
enum uint pscr  = 0x28;
enum uint arrr  = 0x2C;
enum uint ccr   = 0x34;

enum uint cr1_cen  = 1 << 0;
enum uint cr1_arpe = 1 << 7;
enum uint egr_ug   = 1 << 0;
enum uint ocpe     = 1 << 3;
enum uint ocm_pwm1 = 6 << 4;
enum uint ccer_e   = 1 << 0;
enum uint ccer_p   = 1 << 1;

enum ubyte none = 0xFF;

static immutable ulong[3] timer_base = [ 0x4000_0000, 0x4000_0400, 0x4000_0800 ];
static immutable ubyte[3] af = [ 1, 2, 2 ];

// the routing F4, F7 and H7 share, as port * 16 + pin
static immutable ubyte[3][num_hw_pwm] pins = [
    [  0,  5, 15 ], [  1, 19, none ], [  2, 26, none ], [  3, 27, none ],     // TIM2: PA0 PA5 PA15, PA1 PB3, PA2 PB10, PA3 PB11
    [  6, 20, 38 ], [  7, 21, 39 ],   [ 16, 40, none ], [ 17, 41, none ],     // TIM3: PA6 PB4 PC6, PA7 PB5 PC7, PB0 PC8, PB1 PC9
    [ 22, 60, none ], [ 23, 61, none ], [ 24, 62, none ], [ 25, 63, none ], // TIM4: PB6 PD12, PB7 PD13, PB8 PD14, PB9 PD15
];

struct Timer
{
    ushort arr;
    ushort psc;
    ubyte users;
}

__gshared Timer[3] _timers;
__gshared ubyte[num_hw_pwm] _lines;

// the timer clock over frequency * period, rounded, as the 16-bit prescaler less one
bool prescaler(uint frequency, uint period, out ushort psc) pure
{
    immutable ulong ticks = ulong(frequency) * period;
    if (!ticks)
        return false;
    immutable ulong div = (apb1_timer_hz + ticks / 2) / ticks;
    if (div == 0 || div > 0x10000)
        return false;
    psc = cast(ushort)(div - 1);
    return true;
}


unittest
{
    assert(pwm_hw_reaches(1, GpioLine(0, 1)), "PA1 is TIM2_CH2");
    assert(pwm_hw_reaches(8, GpioLine(0, 60)), "PD12 is TIM4_CH1");
    assert(!pwm_hw_reaches(0, GpioLine(0, 1)), "PA1 is not TIM2_CH1");
    assert(!pwm_hw_reaches(3, GpioLine(0, none)), "a padded slot reaches nothing");
    assert(pwm_hw_shares(4, 7) && !pwm_hw_shares(3, 4), "TIM3 owns ports 4 to 7");

    ushort psc;
    version (STM32H7)
        assert(prescaler(4000, 256, psc) && psc == 194, "200 MHz over 4 kHz * 256 rounds to 195");
    assert(!prescaler(1, 256, psc), "1 Hz at period 256 needs a prescaler beyond 16 bits");
    assert(!prescaler(0, 256, psc), "no frequency is no prescaler");
}
