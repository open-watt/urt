// PWM on plain GPIO lines, driven from the periodic timer: each tick adds a channel's duty to its
// accumulator and holds the line active while that overflows the period, so the output is
// density-modulated at the tick rate. A duty of zero or the full period is a static level, and the
// timer runs only while some channel lies between. urt.driver.pwm allocates these channels; use that.
module urt.driver.soft_pwm;

import urt.driver.timer : has_timer_compare;

nothrow @nogc:

static if (has_timer_compare):

import urt.attribute : critical, isr_safe;
import urt.driver.gpio : gpio_output_init, gpio_output_set, gpio_release;
import urt.driver.irq : irq_critical;
import urt.driver.timer : periodic_set, periodic_stop;
import urt.time : dur;

enum uint num_soft_pwm = 8;
enum uint soft_pwm_tick_hz = 4000;
enum uint soft_pwm_max_period = 0x8000_0000;   // the accumulator holds up to twice the period

void soft_open(uint index, uint line, uint period, uint duty, bool inverted)
{
    gpio_output_init(line, inverted);
    auto guard = irq_critical();
    _channels[index] = Channel(line, period, 0, 0, false, false, inverted);
    set_duty(_channels[index], duty);
}

void soft_set_duty(uint index, uint duty)
{
    auto guard = irq_critical();
    set_duty(_channels[index], duty);
}

void soft_close(uint index)
{
    {
        auto guard = irq_critical();
        set_duty(_channels[index], 0);
    }
    gpio_release(_channels[index].line);
}


private:

struct Channel
{
    uint line;
    uint period;
    uint duty;
    uint accumulator;
    bool modulating;
    bool high;
    bool inverted;
}

__gshared Channel[num_soft_pwm] _channels;
__gshared ubyte _modulating;

// interrupts off
void set_duty(ref Channel c, uint duty)
{
    c.duty = duty;
    immutable modulating = duty != 0 && duty != c.period;
    if (modulating != c.modulating)
    {
        c.modulating = modulating;
        if (!modulating)
        {
            if (--_modulating == 0)
                periodic_stop();
        }
        else
        {
            c.accumulator = 0;
            if (_modulating++ == 0)
                periodic_set(dur!"usecs"(1_000_000 / soft_pwm_tick_hz), &tick);
        }
    }
    if (!modulating)
        drive(c, duty != 0);
}

@isr_safe @critical void tick()
{
    foreach (ref c; _channels)
    {
        if (c.modulating)
            drive(c, step(c));
    }
}

@isr_safe @critical void drive(ref Channel c, bool high)
{
    if (high == c.high)
        return;
    c.high = high;
    gpio_output_set(c.line, high != c.inverted);
}

bool step(ref Channel c) pure
{
    c.accumulator += c.duty;
    if (c.accumulator < c.period)
        return false;
    c.accumulator -= c.period;
    return true;
}

unittest
{
    Channel wide = Channel(0, soft_pwm_max_period, soft_pwm_max_period - 1, 0, true, false, false);
    uint active;
    foreach (_; 0 .. 1000)
        active += step(wide);
    assert(active == 999, "a near-full duty at the largest period overflowed the accumulator");

    static immutable uint[4] duties = [0, 1, 64, 256];
    foreach (duty; duties)
    {
        Channel c = Channel(0, 256, duty, 0, true, false, false);
        uint on, longest, run;
        foreach (_; 0 .. 256)
        {
            if (step(c))
            {
                ++on;
                run = 0;
            }
            else if (++run > longest)
                longest = run;
        }
        assert(on == duty, "the active ticks do not match the duty");
        assert(duty < 64 || longest <= 256 / duty, "the active ticks bunch up");
    }
}
