/// BL618 timer driver
///
/// T-Head E907 (RV32IMAFC) has standard RISC-V mtime/mtimecmp.
/// mtime runs at 1MHz (same as BL808's C906).
///
/// TODO: Verify mtime frequency on actual BL618 hardware.
module sys.bl618.timer;

@nogc nothrow:

// ================================================================
// mtime frequency — 1MHz assumed (same as BL808)
// TODO: verify against BL616/BL618 clock tree
// ================================================================

enum uint mtime_freq_hz = 1_000_000;

// ================================================================
// Time reading
// ================================================================

/// Read the monotonic mtime counter via rdtime.
/// RV32: reads high/low halves with retry on rollover.
ulong mtime_read()
{
    // RV32 requires reading timeh:time atomically.
    // If timeh changes between reads, retry.
    uint hi1, lo, hi2;
    do
    {
        asm @nogc nothrow { "rdtimeh %0" : "=r" (hi1); }
        asm @nogc nothrow { "rdtime  %0" : "=r" (lo); }
        asm @nogc nothrow { "rdtimeh %0" : "=r" (hi2); }
    }
    while (hi1 != hi2);
    return (cast(ulong) hi1 << 32) | lo;
}

// ================================================================
// Periodic tick
// ================================================================

alias TimerCallback = void function() @nogc nothrow;

private __gshared TimerCallback tick_callback;
private __gshared uint tick_interval;

/// Set up a periodic timer interrupt.
/// Params:
///   period_us = period in microseconds (mtime ticks at 1MHz)
///   cb = callback to invoke on each tick
void timer_set_periodic(uint period_us, TimerCallback cb)
{
    tick_interval = period_us;
    tick_callback = cb;

    // TODO: write mtimecmp and enable timer interrupt
    // ulong now = mtime_read();
    // mtimecmp_write(now + tick_interval);
    // enable_irq(IrqClass.timer);
}
