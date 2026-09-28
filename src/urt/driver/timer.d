// Unified timer driver
//
// A backend with a hardware compare (has_timer_compare) exports timer_compare_arm(deadline), which raises the
// timer interrupt once mtime reaches the deadline, at once if it already has, and disarms on ulong.max. Its
// interrupt calls timer_compare_fired(). This module schedules the periodic tick, the one-shot and wakes on that compare.
// A backend without one may provide its own timer_set_periodic.
module urt.driver.timer;

import urt.driver.irq : has_wait_for_interrupt, irq_critical, irq_global_enable, irq_global_set, irq_wait;
import urt.time : Duration, dur;

version (BL808_M0)
    public import urt.driver.bl618.timer;
else version (BL808)
    public import urt.driver.bl808.timer;
else version (BL618)
    public import urt.driver.bl618.timer;
else version (Beken)
    public import urt.driver.bk7231.timer;
else version (RP2350)
    public import urt.driver.rp2350.timer;
else version (MT7621)
    public import urt.driver.mt7621.timer;
else version (STM32)
    public import urt.driver.stm32.timer;
else version (Espressif)
    public import urt.driver.esp32.timer;
else
{
    enum uint mtime_freq_hz = 0;
    enum bool has_mtime = false;
    enum bool has_rtc = false;
    enum bool has_mcycle = false;
    enum bool has_timer_compare = false;
}

nothrow @nogc:


alias TimerCallback = void function() nothrow @nogc;

enum bool has_periodic_timer = has_timer_compare || __traits(compiles, timer_set_periodic(ulong.init, TimerCallback.init));

// ====================================================================
// Driver API
// ====================================================================

// Periodic tick

// Call cb every interval, from interrupt context. A late tick keeps the phase; ticks missed outright are dropped.
static if (has_periodic_timer)
{
    void periodic_set(Duration interval, TimerCallback cb)
    {
        static if (has_timer_compare)
        {
            auto guard = irq_critical();
            _schedule.period = interval.ticks;
            _schedule.tick = cb;
            _schedule.next_tick = mtime_read() + _schedule.period;
            rearm();
        }
        else
            timer_set_periodic(interval.ticks, cb);
    }
}

static if (has_timer_compare)
{
    void periodic_stop()
    {
        auto guard = irq_critical();
        _schedule.period = 0;
        _schedule.tick = null;
        rearm();
    }
}

// Waiting

// Poll done() once per pass until it holds (true) or mtime reaches deadline (false). done() runs with interrupts
// masked. A pass halts where the platform can wake on the deadline and it is further off than spin_margin, and
// spins otherwise. ulong.max waits without a deadline.
static if (has_mtime)
{
    bool timer_wait(alias done)(ulong deadline)
    {
        static if (has_timer_compare && has_wait_for_interrupt)
            return wait_until!(done, mtime_read, timer_wake_at, irq_wait, irq_critical)(deadline, spin_margin);
        else
            return wait_until!(done, mtime_read, (ulong) {}, () {}, no_guard)(deadline, ulong.max);
    }

    enum ulong spin_margin = mtime_freq_hz / 50_000;
}

// One-shot

static if (has_timer_compare)
{
    // Call cb once, from interrupt context, when mtime reaches deadline; one already passed fires at once.
    // Replaces any one-shot still pending.
    void oneshot_set(ulong deadline, TimerCallback cb)
    {
        auto guard = irq_critical();
        _schedule.oneshot_deadline = deadline;
        _schedule.oneshot = cb;
        rearm();
    }

    void oneshot_cancel()
    {
        oneshot_set(ulong.max, null);
    }

    // Take a timer interrupt once mtime reaches deadline. An earlier wake already armed stands, so a waiter
    // may wake early and must re-arm.
    void timer_wake_at(ulong deadline)
    {
        auto guard = irq_critical();
        if (deadline < _schedule.wake)
        {
            _schedule.wake = deadline;
            rearm();
        }
    }

    // Called by the backend's compare interrupt.
    void timer_compare_fired()
    {
        TimerCallback tick, shot;
        _schedule.fire(mtime_read(), tick, shot);
        rearm();
        if (tick)
            tick();
        if (shot)
            shot();
    }
}

// The epoch the RTC counter is measured from, in retained memory beside the counter itself.
static if (has_rtc)
{
    version (Bouffalo)
    {
        alias RtcPersist = HbnPersist;
        RtcPersist* persistent_state() => hbn_persist();
    }
    else
    {
        struct RtcPersist
        {
            enum uint magic_value = 0x4F57_4254; // "OWBT" (OpenWatt Boot Time)

            uint magic;
            long utc_offset; // RTC ticks from the counter's epoch to the Unix epoch
        }

        import urt.attribute : persist, used;
        @persist @used __gshared RtcPersist _rtc_persist;

        RtcPersist* persistent_state() => &_rtc_persist;
    }
}


unittest
{
    static assert(mtime_freq_hz > 0 || !has_mtime, "has_mtime requires a known mtime frequency");
    static assert(!has_mcycle || has_mtime, "mcycle without mtime makes no sense in this codebase");
    static assert(!has_timer_compare || has_mtime, "a compare needs an mtime to compare against");
    static assert(!has_periodic_timer || has_mtime);

    static if (has_mtime)
    {{
        ulong start = mtime_read();
        assert(mtime_read() >= start, "mtime went backwards");
        ulong observed = start;
        foreach (_; 0 .. 1_000_000)
        {
            observed = mtime_read();
            if (observed > start)
                break;
        }
        assert(observed > start, "mtime did not advance within 1M reads");
    }}

    static if (has_mcycle)
    {{
        ulong start = mcycle_read();
        ulong observed = start;
        foreach (_; 0 .. 10_000)
        {
            observed = mcycle_read();
            if (observed > start)
                break;
        }
        assert(observed > start, "cycle counter is stuck");
    }}

    static if (has_rtc)
    {{
        rtc_enable();
        ulong r = rtc_read();
        assert(rtc_read() >= r, "the RTC went backwards");
    }}

    {
        static void a() {}
        static void b() {}
        TimerCallback tick, shot;

        Schedule s;
        s.period = 10;
        s.next_tick = 10;
        s.tick = &a;
        s.fire(35, tick, shot);
        assert(tick is &a && s.next_tick == 40, "a late tick lost its phase");
        s.fire(40, tick, shot);
        assert(tick is &a && s.next_tick == 50);
        s.fire(45, tick, shot);
        assert(tick is null && s.next_tick == 50, "a tick fired before its deadline");

        s = Schedule();
        s.oneshot_deadline = 100;
        s.oneshot = &b;
        s.wake = 200;
        assert(s.deadline() == 100);
        s.fire(100, tick, shot);
        assert(shot is &b && s.oneshot is null && s.wake == 200, "a wait disturbed the pending one-shot");
        assert(s.deadline() == 200);
        s.fire(200, tick, shot);
        assert(shot is null && s.wake == ulong.max && s.deadline() == ulong.max);

        s = Schedule();
        s.wake = 50;
        s.oneshot_deadline = 100;
        s.oneshot = &b;
        s.fire(50, tick, shot);
        assert(shot is null && s.oneshot is &b && s.deadline() == 100, "a wake consumed the one-shot");
    }

    {
        __gshared Schedule s;
        __gshared ulong clock;
        static ulong now() => clock;
        static void wake_at(ulong deadline)
        {
            if (deadline < s.wake)
                s.wake = deadline;
        }
        static void wait()
        {
            immutable deadline = s.deadline();
            assert(deadline != ulong.max, "halted with no wake armed");
            clock = deadline;
            TimerCallback tick, shot;
            s.fire(clock, tick, shot);
        }

        __gshared uint polls;
        static bool never() { ++polls; return false; }
        static bool third() => ++polls == 3;

        s = Schedule();
        s.wake = 50;
        clock = 0;
        assert(!wait_until!(never, now, wake_at, wait, no_guard)(100, 0) && clock == 100, "an earlier wake cut the wait short");

        static void step() { ++clock; }
        clock = polls = 0;
        assert(wait_until!(third, now, wake_at, step, no_guard)(100, 0) && polls == 3 && clock == 2, "done was polled past its success");

        // DMD's 32-bit PIC codegen clobbers the address it increments through in `return clock++`.
        static ulong ticking()
        {
            immutable t = clock;
            ++clock;
            return t;
        }
        static void no_halt() { assert(false, "halted within the spin margin"); }
        clock = 0;
        assert(!wait_until!(never, ticking, wake_at, no_halt, no_guard)(10, 20) && clock == 11);
    }

    static if (has_timer_compare)
    {
        import core.volatile : volatileLoad;

        __gshared uint ticks, shots;
        static void on_tick() { ++ticks; }
        static void on_shot() { ++shots; }
        enum ulong ms = mtime_freq_hz / 1000;
        static void wait(ulong duration)
        {
            immutable start = mtime_read();
            while (mtime_read() - start < duration)
            {}
        }

        ulong prior_period = _schedule.period;
        TimerCallback prior_tick = _schedule.tick;
        immutable was_global = irq_global_enable();
        scope (exit)
        {
            oneshot_cancel();
            if (prior_tick)
                periodic_set(Duration(prior_period), prior_tick);
            else
                periodic_stop();
            irq_global_set(was_global);
        }

        {
            // A trap that writes outside its saved frame clobbers the interrupted one.
            ubyte[256] canary;
            foreach (i, ref b; canary)
                b = cast(ubyte)((i * 0x9Eu) ^ 0xA5u);

            ticks = 0;
            periodic_set(dur!"usecs"(200), &on_tick);
            wait(2 * ms);
            periodic_stop();
            immutable fired = volatileLoad(&ticks);
            assert(fired >= 5, "the periodic tick fired too few times");
            foreach (i, b; canary)
                assert(b == cast(ubyte)((i * 0x9Eu) ^ 0xA5u), "stack clobbered across the timer interrupt");

            wait(ms);
            assert(volatileLoad(&ticks) == fired, "the periodic tick fired after periodic_stop");
        }

        static if (has_wait_for_interrupt)
        {{
            // The wait loop's check and halt are atomic only if a halt with interrupts masked ends on a pending one.
            auto guard = irq_critical();
            immutable start = mtime_read();
            timer_wake_at(start + ms);
            irq_wait();
            assert(mtime_read() - start < 20 * ms, "a masked halt did not end on the pending wake");
        }}

        {
            shots = 0;
            oneshot_set(mtime_read() + ms, &on_shot);
            wait(5 * ms);
            assert(volatileLoad(&shots) == 1, "the one-shot did not fire exactly once");

            oneshot_set(mtime_read() - ms, &on_shot);
            wait(ms);
            assert(volatileLoad(&shots) == 2, "a one-shot deadline already passed did not fire");

            oneshot_set(mtime_read() + ms, &on_shot);
            oneshot_cancel();
            wait(2 * ms);
            assert(volatileLoad(&shots) == 2, "a cancelled one-shot fired");

            oneshot_set(mtime_read() + 2 * ms, &on_shot);
            timer_wake_at(mtime_read() + ms);
            timer_wake_at(mtime_read() + 3 * ms);
            wait(4 * ms);
            assert(volatileLoad(&shots) == 3, "a wake displaced the pending one-shot");
        }

        {
            ticks = shots = 0;
            periodic_set(dur!"usecs"(500), &on_tick);
            oneshot_set(mtime_read() + 2 * ms, &on_shot);
            wait(5 * ms);
            periodic_stop();
            assert(volatileLoad(&shots) == 1, "the one-shot was lost under a running periodic tick");
            assert(volatileLoad(&ticks) >= 5, "the one-shot disturbed the periodic tick");
        }
    }
}


private:

struct Schedule
{
nothrow @nogc:
    ulong period;
    ulong next_tick;
    ulong oneshot_deadline = ulong.max;
    ulong wake = ulong.max;
    TimerCallback tick;
    TimerCallback oneshot;

    ulong deadline() const
    {
        ulong d = period != 0 ? next_tick : ulong.max;
        if (oneshot_deadline < d)
            d = oneshot_deadline;
        return wake < d ? wake : d;
    }

    // Retires everything due at now and hands back the callbacks to run.
    void fire(ulong now, out TimerCallback tick_cb, out TimerCallback oneshot_cb)
    {
        if (period != 0 && now >= next_tick)
        {
            next_tick += period;
            if (next_tick <= now)
                next_tick += ((now - next_tick) / period + 1) * period;
            tick_cb = tick;
        }
        if (now >= oneshot_deadline)
        {
            oneshot_cb = oneshot;
            oneshot_deadline = ulong.max;
            oneshot = null;
        }
        if (now >= wake)
            wake = ulong.max;
    }
}

// Each pass checks and halts with interrupts masked: one landing after the check stays pending and ends the halt, then
// runs as the pass unmasks. An earlier wake empties the slot when it fires, so the wake is re-armed every pass.
bool wait_until(alias done, alias now, alias wake_at, alias halt, alias critical)(ulong deadline, ulong margin)
{
    for (;;)
    {
        auto guard = critical();
        if (done())
            return true;
        immutable t = now();
        if (t >= deadline)
            return false;
        if (deadline - t > margin)
        {
            wake_at(deadline);
            halt();
        }
    }
}

struct NoGuard {}
NoGuard no_guard() => NoGuard();

static if (has_timer_compare)
{
    __gshared Schedule _schedule;

    void rearm()
    {
        timer_compare_arm(_schedule.deadline());
    }
}
