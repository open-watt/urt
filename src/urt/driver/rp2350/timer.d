module urt.driver.rp2350.timer;

import core.volatile;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_enable;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;  // TIMER0 counts microseconds from the TICKS block
enum bool has_mtime = true;
enum bool has_rtc = true;
enum bool has_mcycle = false;
enum bool has_timer_compare = true;

void mtime_init()
{
    irq_handler_set(timer0_irq_0, &alarm_isr);
    volatileStore(cast(uint*)TIMER_INTE, alarm0);
    irq_line_enable(timer0_irq_0);
}

// The raw halves are re-read across a carry; the latched pair would be split by an interrupt that reads the time.
ulong mtime_read()
{
    uint hi = void, lo = void;
    do
    {
        hi = volatileLoad(cast(uint*)TIMER_TIMERAWH);
        lo = volatileLoad(cast(uint*)TIMER_TIMERAWL);
    }
    while (hi != volatileLoad(cast(uint*)TIMER_TIMERAWH));
    return (ulong(hi) << 32) | lo;
}

// ALARM0 matches only the counter's low word and disarms when it does, so the interrupt re-arms it
// until the whole deadline is reached. A deadline already passed would wait out a wrap; force it.
void timer_compare_arm(ulong deadline)
{
    auto guard = irq_critical();
    _deadline = deadline;
    if (deadline == ulong.max)
    {
        volatileStore(cast(uint*)TIMER_ARMED, alarm0);
        volatileStore(cast(uint*)TIMER_INTF, 0);
        return;
    }
    volatileStore(cast(uint*)TIMER_ALARM0, cast(uint)deadline);
    if (mtime_read() >= deadline)
        volatileStore(cast(uint*)TIMER_INTF, alarm0);
}

// POWMAN's always-on timer counts milliseconds and keeps running across a reset; it stops only
// when the always-on domain loses power. Writes to POWMAN need the password in the top half.
private enum uint POWMAN_BASE       = 0x4010_0000;
private enum uint POWMAN_READ_UPPER = POWMAN_BASE + 0x70;
private enum uint POWMAN_READ_LOWER = POWMAN_BASE + 0x74;
private enum uint POWMAN_TIMER      = POWMAN_BASE + 0x88;
private enum uint POWMAN_PASSWORD   = 0x5AFE_0000;
private enum uint TIMER_RUN         = 1 << 1;
private enum uint TIMER_USE_LPOSC   = 1 << 8;
private enum uint TIMER_USING_LPOSC = 1 << 17;

enum uint rtc_freq_hz = 1000;

void rtc_enable()
{
    uint timer = volatileLoad(cast(uint*)POWMAN_TIMER);
    if (timer & TIMER_RUN)
        return;
    if (!(timer & TIMER_USING_LPOSC))
        volatileStore(cast(uint*)POWMAN_TIMER, POWMAN_PASSWORD | (timer & 0xFFFF) | TIMER_USE_LPOSC);
    volatileStore(cast(uint*)POWMAN_TIMER, POWMAN_PASSWORD | (volatileLoad(cast(uint*)POWMAN_TIMER) & 0xFFFF) | TIMER_RUN);
}

void rtc_reset()
{
    volatileStore(cast(uint*)POWMAN_TIMER, POWMAN_PASSWORD | (volatileLoad(cast(uint*)POWMAN_TIMER) & 0xFFFF & ~TIMER_RUN));
}

// The halves tick independently, so re-read until the upper half agrees with itself.
ulong rtc_read()
{
    for (;;)
    {
        uint hi = volatileLoad(cast(uint*)POWMAN_READ_UPPER);
        uint lo = volatileLoad(cast(uint*)POWMAN_READ_LOWER);
        if (hi == volatileLoad(cast(uint*)POWMAN_READ_UPPER))
            return (ulong(hi) << 32) | lo;
    }
}

private:

enum uint TIMER0_BASE    = 0x400B_0000;
enum uint TIMER_ALARM0   = TIMER0_BASE + 0x10;
enum uint TIMER_ARMED    = TIMER0_BASE + 0x20;
enum uint TIMER_TIMERAWH = TIMER0_BASE + 0x24;
enum uint TIMER_TIMERAWL = TIMER0_BASE + 0x28;
enum uint TIMER_INTR     = TIMER0_BASE + 0x3C;
enum uint TIMER_INTE     = TIMER0_BASE + 0x40;
enum uint TIMER_INTF     = TIMER0_BASE + 0x44;
enum uint alarm0         = 1 << 0;
enum uint timer0_irq_0   = 0;

__gshared ulong _deadline = ulong.max;

void alarm_isr(uint)
{
    import urt.driver.timer : timer_compare_fired;

    volatileStore(cast(uint*)TIMER_INTF, 0);
    volatileStore(cast(uint*)TIMER_INTR, alarm0);
    if (mtime_read() >= _deadline)
        timer_compare_fired();
    else
        timer_compare_arm(_deadline);
}
