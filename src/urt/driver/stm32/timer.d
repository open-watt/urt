// mtime is TIM5 prescaled to 1 MHz, its update interrupt carrying the upper 32 bits. Channel 1
// drives the periodic callback on a fixed phase; channel 2 is the one-shot deadline.
module urt.driver.stm32.timer;

import urt.driver.stm32 : apb1_timer_hz, clock_enable, rcc_apb1enr, reg_read, reg_write;
import urt.driver.stm32.irq : irq_disable, irq_enable, irq_set_enable, irq_set_handler;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_oneshot_timer = true;

alias TimerCallback = void function() @nogc nothrow;

enum uint tim5_irq = 50;

void mtime_init()
{
    clock_enable(rcc_apb1enr, 3);
    reg_write(tim5_cr1, 0);
    reg_write(tim5_psc, apb1_timer_hz / mtime_freq_hz - 1);
    reg_write(tim5_arr, uint.max);
    reg_write(tim5_egr, 1);             // latch PSC; raises UIF, cleared below
    reg_write(tim5_sr, 0);
    reg_write(tim5_dier, dier_uie);
    irq_set_handler(tim5_irq, &tim5_isr);
    irq_set_enable(tim5_irq);
    reg_write(tim5_cr1, 1);
}

// An update still pending means the counter wrapped after the last count of _mtime_hi.
ulong mtime_read()
{
    bool was_enabled = irq_disable();
    uint hi = _mtime_hi;
    uint lo = reg_read(tim5_cnt);
    if (reg_read(tim5_sr) & sr_uif)
    {
        lo = reg_read(tim5_cnt);
        ++hi;
    }
    if (was_enabled)
        irq_enable();
    return (ulong(hi) << 32) | lo;
}

// ulong.max disarms. The compare holds only the low word, so it stays armed through the earlier
// wraps that match it and disarms once the whole deadline is reached.
void mtimecmp_write_oneshot(ulong deadline)
{
    bool was_enabled = irq_disable();
    if (deadline == ulong.max)
        reg_write(tim5_dier, reg_read(tim5_dier) & ~dier_cc2ie);
    else
    {
        _deadline = deadline;
        reg_write(tim5_ccr2, cast(uint)deadline);
        reg_write(tim5_sr, ~sr_cc2if);
        reg_write(tim5_dier, reg_read(tim5_dier) | dier_cc2ie);
        if (mtime_read() >= deadline)
            reg_write(tim5_egr, egr_cc2g);
    }
    if (was_enabled)
        irq_enable();
}

void timer_set_periodic(ulong period_ticks, TimerCallback cb)
{
    assert(period_ticks > 0 && period_ticks <= uint.max / 2, "TIM5 compares within half a 32-bit wrap");
    bool was_enabled = irq_disable();
    _tick_callback = cb;
    _period = cast(uint)period_ticks;
    reg_write(tim5_sr, ~sr_cc1if);
    reg_write(tim5_dier, reg_read(tim5_dier) | dier_cc1ie);
    compare1_write(reg_read(tim5_cnt) + _period);
    if (was_enabled)
        irq_enable();
}


private:

enum ulong tim5_base = 0x4000_0C00;
enum ulong tim5_cr1  = tim5_base + 0x00;
enum ulong tim5_dier = tim5_base + 0x0C;
enum ulong tim5_sr   = tim5_base + 0x10;
enum ulong tim5_egr  = tim5_base + 0x14;
enum ulong tim5_cnt  = tim5_base + 0x24;
enum ulong tim5_psc  = tim5_base + 0x28;
enum ulong tim5_arr  = tim5_base + 0x2C;
enum ulong tim5_ccr1 = tim5_base + 0x34;
enum ulong tim5_ccr2 = tim5_base + 0x38;

enum uint dier_uie   = 1 << 0;
enum uint dier_cc1ie = 1 << 1;
enum uint dier_cc2ie = 1 << 2;
enum uint sr_uif     = 1 << 0;
enum uint sr_cc1if   = 1 << 1;
enum uint sr_cc2if   = 1 << 2;
enum uint egr_cc1g   = 1 << 1;
enum uint egr_cc2g   = 1 << 2;

static assert(apb1_timer_hz % mtime_freq_hz == 0);

__gshared uint _mtime_hi;
__gshared uint _period;
__gshared ulong _deadline;
__gshared TimerCallback _tick_callback;

bool reached(uint compare) => reg_read(tim5_cnt) - compare < 0x8000_0000;

// A compare only matches as the counter arrives at it, so one written at or behind the counter
// would wait out a whole wrap; raise it in software instead.
void compare1_write(uint compare)
{
    reg_write(tim5_ccr1, compare);
    if (reached(compare))
        reg_write(tim5_egr, egr_cc1g);
}

// Status flags clear on a written 0 and ignore a written 1, so only the handled ones clear.
void tim5_isr(uint)
{
    immutable pending = reg_read(tim5_sr) & reg_read(tim5_dier) & (sr_uif | sr_cc1if | sr_cc2if);
    reg_write(tim5_sr, ~pending);
    if (pending & sr_uif)
        ++_mtime_hi;
    if (pending & sr_cc1if)
    {
        // Ticks missed while service ran late are dropped; the next stays on the period's phase.
        uint next = reg_read(tim5_ccr1) + _period;
        if (reached(next))
            next += ((reg_read(tim5_cnt) - next) / _period + 1) * _period;
        compare1_write(next);
        if (_tick_callback !is null)
            _tick_callback();
    }
    if ((pending & sr_cc2if) && mtime_read() >= _deadline)
        reg_write(tim5_dier, reg_read(tim5_dier) & ~dier_cc2ie);
}
