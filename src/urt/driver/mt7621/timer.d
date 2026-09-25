module urt.driver.mt7621.timer;

import urt.driver.mt7621.irq : gic_read, gic_write, gic_vl_smask, gic_vl_compare;

nothrow @nogc:

// The GIC's shared 64-bit counter runs at the CPU clock, which is only known at runtime; mtime is scaled to 1 MHz.
enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = true;
enum bool has_oneshot_timer = true;

alias TimerCallback = void function() @nogc nothrow;

void counter_init(uint counter_hz)
{
    // TODO: a fixed-point rate; the integer truncation drifts at any clock that is not a whole MHz.
    _ticks_per_us = counter_hz / 1_000_000;
    gic_write(gic_sh_config, gic_read(gic_sh_config) & ~gic_config_countstop);
    compare_write(ulong.max);
    gic_write(gic_vl_smask, gic_vl_compare);
}

ulong mtime_read()
{
    immutable us = counter_read() / _ticks_per_us;
    import urt.driver.mt7621 : probe_heartbeat;
    probe_heartbeat(us);
    return us;
}

void timer_set_periodic(uint period_us, TimerCallback cb)
{
    _interval = period_us;
    _callback = cb;
    _deadline = mtime_read() + period_us;
    mtimecmp_write_oneshot(_deadline);
}

void timer_stop()
{
    _callback = null;
    _interval = 0;
    compare_write(ulong.max);
}

// The compare matches only when the counter reaches it, so a deadline already passed moves just ahead of the counter.
void mtimecmp_write_oneshot(ulong deadline_us)
{
    if (deadline_us == ulong.max)
    {
        compare_write(ulong.max);
        return;
    }
    ulong ticks = deadline_us * _ticks_per_us;
    for (;;)
    {
        compare_write(ticks);
        immutable now = counter_read();
        if (now < ticks)
            return;
        ticks = now + _ticks_per_us;
    }
}

// Writing the compare register is what clears the GIC's pending compare interrupt.
void timer_compare_irq()
{
    compare_write(ulong.max);
    if (_interval)
    {
        immutable now = mtime_read();
        _deadline += _interval;
        if (_deadline <= now)
            _deadline = now + _interval;
        mtimecmp_write_oneshot(_deadline);
    }
    if (_callback !is null)
        _callback();
}


private:

enum uint gic_sh_config        = 0x0000;
enum uint gic_sh_counter_lo    = 0x0010;
enum uint gic_sh_counter_hi    = 0x0014;
enum uint gic_vl_compare_lo    = 0x80A0;
enum uint gic_vl_compare_hi    = 0x80A4;
enum uint gic_config_countstop = 1 << 28;

__gshared uint _ticks_per_us = 880;
__gshared uint _interval;
__gshared ulong _deadline;
__gshared TimerCallback _callback;

ulong counter_read()
{
    uint hi, lo;
    do
    {
        hi = gic_read(gic_sh_counter_hi);
        lo = gic_read(gic_sh_counter_lo);
    }
    while (hi != gic_read(gic_sh_counter_hi));
    return (ulong(hi) << 32) | lo;
}

void compare_write(ulong ticks)
{
    gic_write(gic_vl_compare_hi, 0xFFFF_FFFF);
    gic_write(gic_vl_compare_lo, cast(uint)ticks);
    gic_write(gic_vl_compare_hi, cast(uint)(ticks >> 32));
}


unittest // the compare interrupt is delivered through the vector, with the interrupted frame intact
{
    import core.volatile : volatileLoad;
    import urt.driver.mt7621.irq : irq_enable, irq_disable;

    __gshared uint fires;
    fires = 0;
    static void tick() @nogc nothrow { ++fires; }

    ubyte[256] canary;
    foreach (i, ref b; canary)
        b = cast(ubyte)((i * 0x9Eu) ^ 0xA5u);

    immutable prior = irq_enable();
    timer_set_periodic(2_000, &tick);
    immutable start = mtime_read();
    while (volatileLoad(&fires) < 5 && mtime_read() - start < 200_000)
    {}
    timer_stop();
    if (!prior)
        irq_disable();

    assert(volatileLoad(&fires) >= 5, "periodic compare interrupt not delivered");
    foreach (i, b; canary)
        assert(b == cast(ubyte)((i * 0x9Eu) ^ 0xA5u), "stack clobbered across the interrupt vector");
}

unittest // a deadline already passed still fires, so a late one-shot cannot be lost
{
    import core.volatile : volatileLoad;
    import urt.driver.mt7621.irq : irq_enable, irq_disable;

    __gshared uint fires;
    fires = 0;
    static void tick() @nogc nothrow { ++fires; }

    immutable prior = irq_enable();
    _interval = 0;
    _callback = &tick;
    mtimecmp_write_oneshot(mtime_read() - 1000);
    immutable start = mtime_read();
    while (volatileLoad(&fires) == 0 && mtime_read() - start < 20_000)
    {}
    timer_stop();
    if (!prior)
        irq_disable();
    assert(volatileLoad(&fires) == 1, "a compare deadline in the past did not fire");
}
