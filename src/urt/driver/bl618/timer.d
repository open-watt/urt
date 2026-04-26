// BL618 timer driver
//
// T-Head E907 (RV32IMAFC) has standard RISC-V mtime/mtimecmp.
// mtime runs at 1MHz (same as BL808's C906).
module urt.driver.bl618.timer;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_wfi_sleep = false;

// Read the monotonic mtime counter via rdtime.
// RV32: reads high/low halves with retry on rollover.
ulong mtime_read()
{
    uint hi1, lo, hi2;
    do
    {
        asm @nogc nothrow { "rdtimeh %0" : "=r" (hi1); }
        asm @nogc nothrow { "rdtime  %0" : "=r" (lo); }
        asm @nogc nothrow { "rdtimeh %0" : "=r" (hi2); }
    }
    while (hi1 != hi2);
    return (ulong(hi1) << 32) | lo;
}

alias TimerCallback = void function() @nogc nothrow;

private __gshared TimerCallback tick_callback;
private __gshared uint tick_interval;

void timer_set_periodic(uint period_us, TimerCallback cb)
{
    tick_interval = period_us;
    tick_callback = cb;
    assert(false, "TODO: write mtimecmp and enable timer interrupt");
}
