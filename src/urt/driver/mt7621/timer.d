module urt.driver.mt7621.timer;

import urt.driver.mt7621.irq : gic_read, gic_write, gic_vl_pend, gic_vl_smask, gic_vl_compare, irq_disable, irq_enable;

nothrow @nogc:

// The GIC's shared 64-bit counter runs at the CPU clock. A board that fixes the clock builds with CPU_HZ and mtime is
// the counter itself; otherwise the clock is measured at boot and mtime is nanoseconds.
enum bool fixed_clock = __traits(compiles, import("cpu_hz"));
static if (fixed_clock)
{
    import urt.conv : parse_uint;
    enum uint mtime_freq_hz = cast(uint)parse_uint(import("cpu_hz"));
}
else
    enum uint mtime_freq_hz = 1_000_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_compare = true;

void counter_init(uint counter_hz)
{
    static if (!fixed_clock)
    {
        _ns_per_tick = (ulong(mtime_freq_hz) << 32) / counter_hz;
        _ticks_per_ns_whole = (1UL << 32) / _ns_per_tick;
        ulong r = (1UL << 32) % _ns_per_tick;
        foreach (_; 0 .. 4)
        {
            r <<= 16;
            _ticks_per_ns_frac = _ticks_per_ns_frac << 16 | r / _ns_per_tick;
            r %= _ns_per_tick;
        }
    }
    gic_write(gic_sh_config, gic_read(gic_sh_config) & ~gic_config_countstop);
    compare_write(ulong.max);
    gic_write(gic_vl_smask, gic_vl_compare);
}

ulong mtime_read()
{
    static if (fixed_clock)
        return counter_read();
    else
        return mul_shr32(counter_read(), _ns_per_tick);
}

// The compare matches only when the counter reaches it, so a deadline already passed moves just ahead of the counter.
// A match after the write is left pending for the handler; retrying then would deliver it twice.
void timer_compare_arm(ulong deadline)
{
    if (deadline == ulong.max)
    {
        compare_write(ulong.max);
        return;
    }
    immutable prior = irq_disable();
    ulong ticks = ticks_at(deadline);
    for (ulong step = 1;; step <<= 1)
    {
        compare_write(ticks);
        immutable now = counter_read();
        if (now < ticks || (gic_read(gic_vl_pend) & gic_vl_compare))
            break;
        ticks = now + step;
    }
    if (prior)
        irq_enable();
}

// Writing the compare register is what clears the GIC's pending compare interrupt.
void timer_compare_irq()
{
    import urt.driver.timer : timer_compare_fired;

    compare_write(ulong.max);
    timer_compare_fired();
}


private:

enum uint gic_sh_config        = 0x0000;
enum uint gic_sh_counter_lo    = 0x0010;
enum uint gic_sh_counter_hi    = 0x0014;
enum uint gic_vl_compare_lo    = 0x80A0;
enum uint gic_vl_compare_hi    = 0x80A4;
enum uint gic_config_countstop = 1 << 28;

static if (!fixed_clock)
{
    __gshared ulong _ns_per_tick;
    __gshared ulong _ticks_per_ns_whole;
    __gshared ulong _ticks_per_ns_frac;

    // Exactly floor(a * m / 2^32), for results that fit 64 bits.
    ulong mul_shr32(ulong a, ulong m)
    {
        immutable ulong al = cast(uint)a, ah = a >> 32;
        return ah * m + al * (m >> 32) + ((al * cast(uint)m) >> 32);
    }
}

ulong counter_read()
{
    uint hi = void, lo = void;
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

// The first counter value whose mtime reaches ns, so a compare never fires early; the reciprocal lands at most two short.
ulong ticks_at(ulong ns)
{
    static if (fixed_clock)
        return ns;
    else
    {
        import urt.math : mul64to128;

        ulong t = ns * _ticks_per_ns_whole + mul64to128(ns, _ticks_per_ns_frac)[1];
        while (mul_shr32(t, _ns_per_tick) < ns)
            ++t;
        return t;
    }
}


unittest
{
    import urt.driver.mt7621 : cpu_hz;

    static if (fixed_clock)
        assert(cpu_hz == mtime_freq_hz, "the board's CPU_HZ is not the CPU clock");
    else
    {
        immutable second = mul_shr32(cpu_hz, _ns_per_tick);
        assert(second == mtime_freq_hz || second == mtime_freq_hz - 1, "one second of counter ticks is not one second of mtime");

        static immutable ulong[6] deadlines = [0, 1, 999, 1_000_000_007, 86_400_000_000_123, 31_536_000_000_000_000];
        foreach (d; deadlines)
        {
            immutable t = ticks_at(d);
            assert(mul_shr32(t, _ns_per_tick) >= d && (t == 0 || mul_shr32(t - 1, _ns_per_tick) < d), "ticks_at is not the inverse of mtime");
        }
    }
}
