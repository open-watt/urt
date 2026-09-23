module urt.driver.rp2350.timer;

import core.volatile;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;  // TIMER0 runs at 1MHz (microsecond counter)
enum bool has_mtime = true;
enum bool has_rtc = true;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_oneshot_timer = false;

// RP2350 TIMER0: 64-bit free-running microsecond counter at 0x400B_0000
// Always enabled, always 1MHz. Read TIMELR first (latches TIMEHR).
private enum uint TIMER0_BASE = 0x400B_0000;
private enum uint TIMEHR      = TIMER0_BASE + 0x08;  // Time read high (latched on TIMELR read)
private enum uint TIMELR      = TIMER0_BASE + 0x0C;  // Time read low (triggers latch)

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

// SysTick registers (ARM standard, part of the System Control Block)
private enum uint SYST_CSR = 0xE000_E010;
private enum uint SYST_RVR = 0xE000_E014;
private enum uint SYST_CVR = 0xE000_E018;

private enum uint CSR_ENABLE    = 1 << 0;
private enum uint CSR_TICKINT   = 1 << 1;
private enum uint CSR_CLKSOURCE = 1 << 2;

alias TimerCallback = void function() @nogc nothrow;

private __gshared TimerCallback tick_callback;

void timer_init(uint reload_value)
{
    volatileStore(cast(uint*)(cast(size_t)SYST_RVR), reload_value & 0x00FFFFFF);
    volatileStore(cast(uint*)(cast(size_t)SYST_CVR), 0);
    volatileStore(cast(uint*)(cast(size_t)SYST_CSR), CSR_ENABLE | CSR_TICKINT | CSR_CLKSOURCE);
}

void timer_hw_init()
{
    // sys_init configures TIMER0 before runtime initialization.
}

// Read 64-bit monotonic microsecond counter.
// Must read TIMELR first -- this latches TIMEHR atomically.
ulong mtime_read()
{
    uint lo = volatileLoad(cast(uint*)(cast(size_t)TIMELR));
    uint hi = volatileLoad(cast(uint*)(cast(size_t)TIMEHR));
    return (cast(ulong)hi << 32) | lo;
}

void timer_set_periodic(uint period_ticks, TimerCallback cb)
{
    tick_callback = cb;
    // Use SysTick for periodic interrupts.
    // period_ticks is in timer ticks (microseconds at 1MHz).
    // SysTick runs from processor clock -- assume 150MHz after PLL init.
    // Convert: systick_reload = period_us * 150
    uint reload = period_ticks * 150;
    if (reload > 0x00FF_FFFF)
        reload = 0x00FF_FFFF;  // SysTick is 24-bit
    volatileStore(cast(uint*)(cast(size_t)SYST_RVR), reload);
    volatileStore(cast(uint*)(cast(size_t)SYST_CVR), 0);
    volatileStore(cast(uint*)(cast(size_t)SYST_CSR), CSR_ENABLE | CSR_TICKINT | CSR_CLKSOURCE);
}

extern(C) void SysTick_Handler() @nogc nothrow
{
    if (tick_callback !is null)
        tick_callback();
}
