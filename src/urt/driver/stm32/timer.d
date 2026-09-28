// mtime is TIM5 prescaled to 1 MHz, its update interrupt carrying the upper 32 bits. Channel 1 is the
// compare the timer frontend schedules on.
module urt.driver.stm32.timer;

import urt.driver.irq : irq_handler_set;
import urt.driver.stm32 : apb1_timer_hz, clock_enable, rcc_apb1enr, reg_read, reg_write;
import urt.driver.stm32.irq : irq_disable, irq_enable, irq_set_enable;

@nogc nothrow:

enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_compare = true;

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
    irq_handler_set(tim5_irq, &tim5_isr);
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

// The compare holds only the low word, so it stays armed through the earlier wraps that match it.
// A compare written at or behind the counter would wait out a whole wrap; raise it in software instead.
void timer_compare_arm(ulong deadline)
{
    bool was_enabled = irq_disable();
    if (deadline == ulong.max)
        reg_write(tim5_dier, reg_read(tim5_dier) & ~dier_cc1ie);
    else
    {
        _deadline = deadline;
        reg_write(tim5_ccr1, cast(uint)deadline);
        reg_write(tim5_sr, ~sr_cc1if);
        reg_write(tim5_dier, reg_read(tim5_dier) | dier_cc1ie);
        if (mtime_read() >= deadline)
            reg_write(tim5_egr, egr_cc1g);
    }
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

enum uint dier_uie   = 1 << 0;
enum uint dier_cc1ie = 1 << 1;
enum uint sr_uif     = 1 << 0;
enum uint sr_cc1if   = 1 << 1;
enum uint egr_cc1g   = 1 << 1;

static assert(apb1_timer_hz % mtime_freq_hz == 0);

__gshared uint _mtime_hi;
__gshared ulong _deadline;

// Status flags clear on a written 0 and ignore a written 1, so only the handled ones clear.
void tim5_isr(uint)
{
    import urt.driver.timer : timer_compare_fired;

    immutable pending = reg_read(tim5_sr) & reg_read(tim5_dier) & (sr_uif | sr_cc1if);
    reg_write(tim5_sr, ~pending);
    if (pending & sr_uif)
        ++_mtime_hi;
    if ((pending & sr_cc1if) && mtime_read() >= _deadline)
        timer_compare_fired();
}
