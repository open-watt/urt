// BL618 / BL808 M0 (E907) timer driver
//
// T-Head E907 (RV32IMAFC) has standard RISC-V mtime/mtimecmp exposed via the
// CORET block at 0xE0004000 (NOT the CLIC region at 0xE0800000 -- the two
// are separate peripherals on E907). MTIMECMP is at offset 0x000, MTIME at
// 0x7FFC. mtime runs at 1 MHz from the AON clock.
//
// The compare raises CLIC line 7, which urt.driver.bl618.irq dispatches straight to the timer frontend.
module urt.driver.bl618.timer;

import core.volatile;
import urt.driver.bl618.irq : irq_set_enable, timer_irq;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_compare = true;

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

// The compare is level-sensitive, so a deadline already passed raises at once.
void timer_compare_arm(ulong deadline)
{
    auto lo = cast(uint*)cast(size_t)MTIMECMP_LO;
    auto hi = cast(uint*)cast(size_t)MTIMECMP_HI;

    // Park high at 0xFFFFFFFF before touching low, so a stale low doesn't
    // briefly match an old high and fire a spurious IRQ.
    volatileStore(hi, 0xFFFF_FFFF);
    volatileStore(lo, cast(uint)(deadline & 0xFFFF_FFFF));
    volatileStore(hi, cast(uint)(deadline >> 32));
    irq_set_enable(timer_irq);
}


private:

// T-Head E907 CORET (mtime / mtimecmp). Separate peripheral from CLIC.
enum uint CORET_BASE  = 0xE000_4000;
enum uint MTIMECMP_LO = CORET_BASE + 0x0000;
enum uint MTIMECMP_HI = CORET_BASE + 0x0004;
