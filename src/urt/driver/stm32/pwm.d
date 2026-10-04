// STM32 PWM on TIM2, TIM3 and TIM4 on APB1 and the advanced TIM1 and TIM8 on APB2, four compare channels each;
// TIM5 is the timer layer's. A port is timer * 4 + channel, and the channels of a timer share its prescaler
// and period. TIM2 counts 32 bits, the others 16.
module urt.driver.stm32.pwm;

import urt.driver.gpio : GpioLine;
import urt.driver.pwm : PwmConfig;
import urt.driver.stm32 : apb1_timer_hz, apb2_timer_hz, clock_enable, rcc_apb1enr, rcc_apb2enr, reg_rmw, reg_write;
import urt.driver.stm32.gpio : gpio_release, gpio_set_function, num_gpio;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_hw_pwm = num_timers * 4;

bool pwm_hw_reaches(uint port, GpioLine line)
{
    if (line.chip != 0 || line.line >= num_gpio || port >= num_hw_pwm)
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

// A full duty needs a compare above the auto-reload, so the period stops one short of the counter's range.
Result pwm_hw_open(uint port, ref const PwmConfig config)
{
    immutable uint t = port >> 2;
    ushort psc;
    if (!pwm_hw_reaches(port, config.output) || config.period == 0 || config.period - 1 > max_arr[t] ||
        !prescaler(timer_clock[t], config.frequency, config.period, psc))
        return InternalResult.invalid_parameter;

    immutable uint arr = config.period - 1;
    Timer* tm = &_timers[t];
    if (tm.users && (tm.arr != arr || tm.psc != psc))
        return InternalResult.failed;

    immutable ulong base = timer_base[t];
    immutable uint ch = port & 3;
    immutable ulong ccmr = base + (ch < 2 ? ccmr1 : ccmr2);
    immutable uint shift = (ch & 1) * 8;
    if (!tm.users)
    {
        clock_enable(clock_reg[t], clock_bit[t]);
        reg_write(base + cr1, 0);
        reg_write(base + pscr, psc);
        reg_write(base + arrr, arr);
    }
    // the compare loads directly while the channel's preload is off, so the first period already has its duty
    reg_rmw(ccmr, 0xFFu << shift, ocm_pwm1 << shift);
    reg_write(base + ccr + ch * 4, config.initial_duty);
    reg_rmw(ccmr, 0, ocpe << shift);
    reg_rmw(base + ccer, 0xFu << ch * 4, (ccer_e | (config.inverted ? ccer_p : 0)) << ch * 4);
    if (!tm.users)
    {
        if (advanced[t])
            reg_write(base + bdtr, bdtr_moe);
        reg_write(base + egr, egr_ug);
        reg_write(base + cr1, cr1_arpe | cr1_cen);
        tm.arr = arr;
        tm.psc = psc;
    }
    ++tm.users;
    gpio_set_function(config.output.line, af[t]);
    _lines[port] = cast(ubyte)config.output.line;
    return Result.success;
}

Result pwm_hw_set_duty(uint port, uint duty)
{
    reg_write(timer_base[port >> 2] + ccr + (port & 3) * 4, duty);
    return Result.success;
}

// Several pins reach a channel, so the pin goes back to analog rather than carrying the next user's waveform, and
// the channel's compare and preload are cleared so its next tenant starts from nothing.
void pwm_hw_close(uint port)
{
    immutable uint t = port >> 2;
    immutable ulong base = timer_base[t];
    immutable uint ch = port & 3;
    reg_rmw(base + ccer, 0xFu << ch * 4, 0);
    reg_rmw(base + (ch < 2 ? ccmr1 : ccmr2), 0xFFu << (ch & 1) * 8, 0);
    reg_write(base + ccr + ch * 4, 0);
    gpio_release(_lines[port]);
    if (--_timers[t].users == 0)
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
enum uint bdtr  = 0x44;

enum uint cr1_cen  = 1 << 0;
enum uint cr1_arpe = 1 << 7;
enum uint egr_ug   = 1 << 0;
enum uint ocpe     = 1 << 3;
enum uint ocm_pwm1 = 6 << 4;
enum uint ccer_e   = 1 << 0;
enum uint ccer_p   = 1 << 1;
enum uint bdtr_moe = 1 << 15;

enum ubyte none = 0xFF;
enum uint num_timers = 5;

// TIM2, TIM3, TIM4, TIM1, TIM8
static immutable ulong[num_timers] timer_base = [ 0x4000_0000, 0x4000_0400, 0x4000_0800, 0x4001_0000, 0x4001_0400 ];
static immutable ubyte[num_timers] clock_reg = [ rcc_apb1enr, rcc_apb1enr, rcc_apb1enr, rcc_apb2enr, rcc_apb2enr ];
static immutable ubyte[num_timers] clock_bit = [ 0, 1, 2, 0, 1 ];
static immutable uint[num_timers] timer_clock = [ apb1_timer_hz, apb1_timer_hz, apb1_timer_hz, apb2_timer_hz, apb2_timer_hz ];
static immutable uint[num_timers] max_arr = [ uint.max - 1, 0xFFFE, 0xFFFE, 0xFFFE, 0xFFFE ];
static immutable bool[num_timers] advanced = [ false, false, false, true, true ];
static immutable ubyte[num_timers] af = [ 1, 2, 2, 1, 3 ];

// the routing F4, F7 and H7 share, as port * 16 + pin
static immutable ubyte[3][num_hw_pwm] pins = [
    [  0,  5, 15 ], [  1, 19, none ], [  2, 26, none ], [  3, 27, none ],     // TIM2: PA0 PA5 PA15, PA1 PB3, PA2 PB10, PA3 PB11
    [  6, 20, 38 ], [  7, 21, 39 ],   [ 16, 40, none ], [ 17, 41, none ],     // TIM3: PA6 PB4 PC6, PA7 PB5 PC7, PB0 PC8, PB1 PC9
    [ 22, 60, none ], [ 23, 61, none ], [ 24, 62, none ], [ 25, 63, none ], // TIM4: PB6 PD12, PB7 PD13, PB8 PD14, PB9 PD15
    [  8, 73, none ], [  9, 75, none ], [ 10, 77, none ], [ 11, 78, none ], // TIM1: PA8 PE9, PA9 PE11, PA10 PE13, PA11 PE14
    [ 38, none, none ], [ 39, none, none ], [ 40, none, none ], [ 41, none, none ], // TIM8: PC6, PC7, PC8, PC9
];

struct Timer
{
    uint arr;
    ushort psc;
    ubyte users;
}

__gshared Timer[num_timers] _timers;
__gshared ubyte[num_hw_pwm] _lines;

// the timer clock over frequency * period, rounded, as the 16-bit prescaler less one; a frequency the clock
// cannot count to is refused rather than run slow
bool prescaler(uint clock, uint frequency, uint period, out ushort psc) pure
{
    immutable ulong ticks = ulong(frequency) * period;
    if (!ticks || ticks > clock)
        return false;
    immutable ulong div = (clock + ticks / 2) / ticks;
    if (div > 0x10000)
        return false;
    psc = cast(ushort)(div - 1);
    return true;
}


unittest
{
    assert(pwm_hw_reaches(1, GpioLine(0, 1)), "PA1 is TIM2_CH2");
    assert(pwm_hw_reaches(8, GpioLine(0, 60)), "PD12 is TIM4_CH1");
    assert(pwm_hw_reaches(12, GpioLine(0, 8)), "PA8 is TIM1_CH1");
    assert(pwm_hw_reaches(19, GpioLine(0, 41)), "PC9 is TIM8_CH4");
    assert(!pwm_hw_reaches(0, GpioLine(0, 1)), "PA1 is not TIM2_CH1");
    assert(!pwm_hw_reaches(3, GpioLine(0, none)), "a padded slot reaches nothing");
    assert(!pwm_hw_reaches(3, GpioLine(0, 255)), "nor does line 255");
    assert(pwm_hw_shares(4, 7) && !pwm_hw_shares(3, 4), "TIM3 owns ports 4 to 7");

    ushort psc;
    assert(prescaler(200_000_000, 4000, 256, psc) && psc == 194, "200 MHz over 4 kHz * 256 rounds to 195");
    assert(!prescaler(200_000_000, 1, 256, psc), "1 Hz at period 256 needs a prescaler beyond 16 bits");
    assert(!prescaler(200_000_000, 0, 256, psc), "no frequency is no prescaler");
    assert(!prescaler(200_000_000, 1_000_000, 256, psc), "256 MHz of counting is beyond a 200 MHz clock");
}
