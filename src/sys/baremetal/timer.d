module sys.baremetal.timer;

import urt.time : Duration, dur;

version (BL808_M0)
    public import sys.bl618.timer;
else version (BL808)
    public import sys.bl808.timer;
else version (BL618)
    public import sys.bl618.timer;
else version (Beken)
    public import sys.bk7231.timer;
else version (RP2350)
    public import sys.rp2350.timer;
else version (STM32)
    public import sys.stm32.timer;
else version (Espressif)
    public import sys.esp32.timer;
else
{
    enum uint mtime_freq_hz = 0;
    enum bool has_mtime = false;
    enum bool has_rtc = false;
    enum bool has_mcycle = false;
    enum bool has_timer_stop = false;
    enum bool has_wfi_sleep = false;
}

nothrow @nogc:


alias TimerCallback = void function() nothrow @nogc;

// ════════════════════════════════════════════════════════════════════
// Driver API
// ════════════════════════════════════════════════════════════════════

// Lifecycle

void timer_init()
{
    if (_init_refcount++ == 0)
    {
        version (Beken)
            timer_hw_init();
    }
}

void timer_deinit()
{
    assert(_init_refcount > 0);
    if (--_init_refcount == 0)
    {
        static if (has_timer_stop)
            periodic_stop();
        static if (has_rtc)
            rtc_stop();
        // TODO: disable timer IRQs at the interrupt controller level
    }
}

// Monotonic clock

// Read the monotonic tick counter. Units are platform-specific;
// use mtime_freq_hz to convert to real time.
static if (has_mtime)
    alias monotonic_read = mtime_read;
else
{
    ulong monotonic_read()
    {
        assert(false, "monotonic_read not available");
    }
}

// Read CPU cycle counter (for profiling, NOT timekeeping).
// Stops during WFI, rate changes with clock scaling.
static if (has_mcycle)
    alias cycle_read = mcycle_read;
else
{
    ulong cycle_read()
    {
        assert(false, "cycle_read not available");
    }
}

// Periodic tick

// Set up a periodic timer interrupt at the given interval.
void periodic_set(Duration interval, TimerCallback cb)
{
    static if (has_mtime)
    {
        ulong ticks = interval.as!"nsecs" * mtime_freq_hz / 1_000_000_000;
        timer_set_periodic(cast(uint)ticks, cb);
    }
    else
        assert(false, "TODO: periodic_set not available");
}

// Stop the periodic timer.
void periodic_stop()
{
    static if (has_timer_stop)
        timer_stop();
    else
        assert(false, "TODO: periodic_stop not available");
}

// One-shot wakeup

// Schedule a one-shot interrupt at the given absolute tick value.
// Used by sleep() to wake from WFI.
void oneshot_set(ulong tick_value)
{
    static if (has_wfi_sleep)
        mtimecmp_write_oneshot(tick_value);
    else
        assert(false, "TODO: oneshot_set not available");
}

// RTC (battery-backed real-time counter)

// Enable the RTC counter. Does not reset it.
void rtc_start()
{
    static if (has_rtc)
        rtc_enable();
    else
        assert(false, "TODO: rtc_start not available");
}

// Disable and reset the RTC counter to zero.
void rtc_stop()
{
    static if (has_rtc)
        rtc_reset();
    else
        assert(false, "TODO: rtc_stop not available");
}

// Read the RTC tick counter.
static if (has_rtc)
    alias rtc_now = rtc_read;
else
{
    ulong rtc_now()
    {
        assert(false, "TODO: rtc_now not available");
    }
}

// Access persistent state in battery-retained RAM.
static if (has_rtc)
{
    HbnPersist* persistent_state()
    {
        return hbn_persist();
    }
}


// ════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════

unittest
{
    // Capabilities are consistent
    static assert(mtime_freq_hz > 0 || !has_mtime);

    timer_init();

    // Monotonic clock
    static if (has_mtime)
    {
        ulong t1 = monotonic_read();
        ulong t2 = monotonic_read();
        assert(t2 >= t1);
    }

    // Cycle counter
    static if (has_mcycle)
    {
        ulong c1 = cycle_read();
        ulong c2 = cycle_read();
        assert(c2 > c1);
    }

    // One-shot wakeup
    static if (has_wfi_sleep)
    {
        // Set a oneshot far in the future, then cancel by setting to max.
        // This verifies the register write doesn't crash.
        ulong now = monotonic_read();
        oneshot_set(now + mtime_freq_hz); // 1 second from now
        oneshot_set(ulong.max);           // cancel
    }

    // Periodic set/stop (only test on platforms that support stop,
    // otherwise we can't clean up)
    static if (has_mtime && has_timer_stop)
    {
        __gshared bool tick_fired = false;
        periodic_set(dur!"msecs"(50), () { tick_fired = true; });
        periodic_stop();
        // We can't easily test that the callback fires without
        // waiting + running the interrupt, but at least verify
        // set/stop don't crash.
    }

    // RTC
    static if (has_rtc)
    {
        rtc_start();
        ulong r1 = rtc_now();
        ulong r2 = rtc_now();
        assert(r2 >= r1);

        auto p = persistent_state();
        assert(p !is null);
    }

    timer_deinit();
}


private:

__gshared ubyte _init_refcount;
