// BL618 / BL808 M0 (E907) timer driver
//
// T-Head E907 (RV32IMAFC) has standard RISC-V mtime/mtimecmp exposed via the
// CORET block at 0xE0004000 (NOT the CLIC region at 0xE0800000 -- the two
// are separate peripherals on E907). MTIMECMP is at offset 0x000, MTIME at
// 0x7FFC. mtime divides the core clock: the BL618 keeps boot2's 1 MHz, and the BL808 M0 runs at the
// rate it shares with D0.
//
// The compare raises CLIC line 7, which urt.driver.bl618.irq dispatches straight to the timer frontend.
module urt.driver.bl618.timer;

import urt.driver.bl618.irq : timer_irq;
import urt.driver.irq : irq_line_enable;
import urt.driver.riscv.clint : mtimecmp_write;

public import urt.driver.riscv.csr : mtime_read;

@nogc nothrow:

version (BL808_M0)
{
    import urt.driver.bl_common.clock : mtime_hz;
    enum uint mtime_freq_hz = mtime_hz;
}
else
    enum uint mtime_freq_hz = 1_000_000;
enum bool has_mtime = true;
enum bool has_rtc = false;
enum bool has_mcycle = false;
enum bool has_timer_compare = true;

void timer_compare_arm(ulong deadline)
{
    mtimecmp_write(mtimecmp, deadline);
    irq_line_enable(timer_irq);
}


private:

// T-Head E907 CORET: mtimecmp sits at the base, apart from the CLIC.
enum size_t mtimecmp = 0xE000_4000;
