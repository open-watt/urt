// BL618 / BL808 M0 interrupt controller (T-Head E907 CLIC).
//
// The E907 has a Core Local Interrupt Controller at 0xE080_0000. Each IRQ has
// four bytes at CLICINT_BASE + irq*4: { IP, IE, ATTR, CTL }. Trap entry is
// dispatched via mtvt (CSR 0x307, standard CLIC) as a flat .word table of handler addresses,
// with mtvec in CLIC mode (mode 11) pointing at the exception/sync-trap
// handler. The per-IRQ stub _clic_dispatch (in start.S) uses T-Head ipush /
// ipop to push mepc/mcause/caller-saved GPRs across the handler call, which
// is what makes nesting safe (without it, the inner IRQ's mret would clobber
// the outer's mepc CSR; that bug bit us before).
//
// This module is shared by BL618 and BL808 M0 builds. The two parts have the
// same CLIC layout; per-board carve-outs live behind version(BL618) /
// version(BL808_M0) gates.
module urt.driver.bl618.irq;

import core.volatile;

public import urt.driver.riscv.csr : irq_disable, irq_enable, wait_for_interrupt;

@nogc nothrow:


// ====================================================================
// Capability flags (read by urt.driver.irq facade)
// ====================================================================

enum bool has_per_irq_control    = true;
enum bool has_irq_priority       = true;
enum bool has_wait_for_interrupt = true;
enum bool has_global_irq_state   = true;
enum bool has_smp                = false;

// E907 CLIC supports up to 4096 IRQ lines architecturally; both BL618 and
// BL808 M0 wire 16 standard + 64 peripheral = 80 sources. Sources above the
// SoC's wired count are valid CLIC registers but will never raise.
enum uint irq_max = 80;

// RISC-V machine timer cause; dispatched straight to the timer driver.
enum uint timer_irq = 7;

// Software writes to IP do not latch on BL808 M0's idle lines.
version (BL618)
    enum uint[2] test_irq_lines = [16, 17];


package(urt.driver):

// ====================================================================
// Per-IRQ control
// ====================================================================

// The T-Head CLIC will NOT deliver an IRQ whose CLICINTCTL priority is
// zero -- even with IE=1, SHV=1, IP=1, and mstatus.MIE set. Vendor's
// CPU_Interrupt_Enable in bl_iot_sdk's interrupt.c clamps the same way.
// We bump to the minimum-priority value (_clic_ctl_lsb); on E907 that's
// 0x10 because CLICINFO.CLICINTCTLBITS reports 4 (top 4 bits are RW
// priority, bottom 4 are RAO -- they read as 1 even after writing 0).
// So a "no priority" CTL reads as 0x0F, not 0x00. The check is
// `< _clic_ctl_lsb` (priority below minimum), not `== 0`.
bool irq_set_enable(uint irq)
{
    ubyte* ctl = clicint_byte(irq, ctl_offset);
    if (volatileLoad(ctl) < _clic_ctl_lsb)
        volatileStore(ctl, _clic_ctl_lsb);
    ubyte* ie = clicint_byte(irq, ie_offset);
    bool prev = (volatileLoad(ie) & 0x1) != 0;
    volatileStore(ie, ubyte(1));
    return prev;
}

bool irq_clear_enable(uint irq)
{
    ubyte* ie = clicint_byte(irq, ie_offset);
    bool prev = (volatileLoad(ie) & 0x1) != 0;
    volatileStore(ie, ubyte(0));
    return prev;
}

version (BL618)
{
    void irq_set_pending(uint irq)
    {
        volatileStore(clicint_byte(irq, ip_offset), ubyte(1));
    }
}

void irq_clear_pending(uint irq)
{
    volatileStore(clicint_byte(irq, ip_offset), ubyte(0));
}

// CTL is higher-is-more-urgent, and a level below the implemented LSB is never delivered.
void irq_set_priority(uint irq, ubyte priority)
{
    ubyte ctl = cast(ubyte)~priority;
    volatileStore(clicint_byte(irq, ctl_offset), ctl < _clic_ctl_lsb ? _clic_ctl_lsb : ctl);
}

// Set the trigger type for a peripheral IRQ. Default after clic_init is
// level-positive (0), which is what most peripherals need.
enum IrqTrigger : ubyte
{
    level_pos = 0b00,
    edge_pos  = 0b01,
    level_neg = 0b10,
    edge_neg  = 0b11,
}

void irq_set_trigger(uint irq, IrqTrigger trig)
{
    if (irq >= irq_max)
        return;
    ubyte* attr = clicint_byte(irq, attr_offset);
    ubyte v = volatileLoad(attr);
    v = cast(ubyte)((v & ~0b110) | ((cast(ubyte)trig & 0b11) << 1));
    volatileStore(attr, v);
}


// ====================================================================
// Initialization
// ====================================================================

// Bring the CLIC into a known state: one priority level, no preemption,
// every line disabled with level-positive trigger and SHV=1. Read CLICINFO
// to learn how many CLICINTCTL bits are implemented (E907 reports 4 -> only
// the top 4 bits of CTL are RW) and cache the minimum-priority value for
// irq_set_enable's auto-bump.
//
// Called from sys_init (bl_common/system.d) before mstatus.MIE is enabled.
// MUST run before any irq_set_enable / irq_set_priority on a fresh boot --
// otherwise stale CLIC state from a prior cycle could fire the moment MIE
// goes on, and the auto-bump would have no nlbits to shift against.
extern(C) void irq_init()
{
    // T-Head mexstatus.SPUSHEN | SPSWAPEN (bits 16-17 of CSR 0x7E1). Without
    // these, th.ipush / th.ipop in _clic_dispatch are a silent no-op and the
    // first IRQ wedges the chip. Vendor system_bl808.c sets the same bits.
    asm @nogc nothrow
    {
        `
        li      t0, 0x30000
        csrs    0x7E1, t0
        `
        : : : "t0";
    }

    // CLICCFG = 0: NLBIT=0 (single priority level, no preemption), NMBIT=0,
    // NVBIT=0. We want preemption off until callers explicitly opt in.
    volatileStore(cast(ubyte*)cast(size_t)clic_cfg, ubyte(0));

    // CLICINFO[24:21] = CLICINTCTLBITS = number of CTL bits implemented from
    // the top. E907 reports 4, so a CTL write of 1 (bit 0) stores 0 in the
    // RAZ/WI bottom bits -- the line would never deliver. Compute the
    // bottom-of-priority-field bit value so irq_set_enable can clamp to a
    // true nonzero priority. Mirrors vendor's csi_vic_set_prio() arithmetic.
    uint info = volatileLoad(cast(uint*)cast(size_t)clic_info);
    uint ctlbits = (info >> 21) & 0xF;
    if (ctlbits == 0 || ctlbits > 8)
        ctlbits = 4;  // E907 default; defensive fallback if CLICINFO is bogus
    _clic_ctl_lsb = cast(ubyte)(1u << (8 - ctlbits));

    foreach (uint i; 0 .. irq_max)
    {
        volatileStore(clicint_byte(i, ip_offset),   ubyte(0));
        volatileStore(clicint_byte(i, ie_offset),   ubyte(0));
        // SHV=1: hardware-vectored dispatch via mtvt[id] -> _clic_dispatch.
        // SHV=0 routes through mtvec.base, which is _trap_exception (wrong
        // path for interrupts -- it expects sync traps). TRIG=0 (level-pos)
        // matches the vendor default. Vendor system_bl808.c does the same.
        volatileStore(clicint_byte(i, attr_offset), ubyte(1));
        volatileStore(clicint_byte(i, ctl_offset),  ubyte(0));
    }
}


// ====================================================================
// Dispatch (called from _clic_dispatch in start.S)
// ====================================================================

extern(C) void _irq_dispatch(uint cause) @nogc nothrow
{
    import urt.driver.irq : irq_dispatch;
    import urt.driver.timer : timer_compare_fired;

    uint id = cause & 0x3FF;
    if (id == timer_irq)
        timer_compare_fired();
    else
        irq_dispatch(id);
}


private:

enum uint clic_base    = 0xE080_0000;
enum uint clic_cfg     = clic_base + 0x0000;  // 1 byte
enum uint clic_info    = clic_base + 0x0004;  // 4 bytes
enum uint clic_mth     = clic_base + 0x0008;  // 4 bytes (MINTTHRESH)
enum uint clicint_base = clic_base + 0x1000;  // 4 bytes per IRQ thereafter

enum uint ip_offset   = 0;
enum uint ie_offset   = 1;
enum uint attr_offset = 2;
enum uint ctl_offset  = 3;

ubyte* clicint_byte(uint irq, uint field)
{
    return cast(ubyte*)cast(size_t)(clicint_base + irq * 4 + field);
}

// Minimum-nonzero CLICINTCTL value -- cached by irq_init() from CLICINFO.
// Pre-init fallback of 0x10 covers the E907 (4 implemented bits) so a stray
// irq_set_enable before irq_init still bumps to a valid priority.
__gshared ubyte _clic_ctl_lsb = 0x10;

extern(C) extern __gshared uint[irq_max] __clic_vectors;
extern(C) extern void _clic_dispatch();


// Delivery, masking and routing are urt.driver.irq's contract tests; these prove the CLIC trap path is wired.
unittest
{
    {
        // mtvt=0x7D7 instead of the standard 0x307 cost two days; every IRQ vectored through address 0.
        uint mtvt_csr;
        asm @nogc nothrow { "csrr %0, 0x307" : "=r" (mtvt_csr); }
        assert(mtvt_csr == cast(uint)cast(size_t)&__clic_vectors[0], "mtvt CSR does not point at __clic_vectors");

        uint mtvec_csr;
        asm @nogc nothrow { "csrr %0, mtvec" : "=r" (mtvec_csr); }
        assert((mtvec_csr & 0x3) == 0x3, "mtvec MODE != 0b11 (CLIC)");

        uint mexstatus;
        asm @nogc nothrow { "csrr %0, 0x7E1" : "=r" (mexstatus); }
        assert((mexstatus & 0x30000) == 0x30000, "mexstatus.SPUSHEN|SPSWAPEN not set -- nested IRQs will corrupt mepc");

        uint expected = cast(uint)cast(size_t)&_clic_dispatch;
        foreach (uint i; 0 .. irq_max)
            assert(__clic_vectors[i] == expected, "__clic_vectors entry doesn't point at _clic_dispatch");
    }

    {
        import urt.driver.timer : mtime_read, oneshot_cancel, oneshot_set;

        __gshared uint magic;
        static void probe() { magic = 0xCAFE_F00D; }
        magic = 0;

        immutable was_global = irq_enable();
        oneshot_set(mtime_read() + 1_000, &probe);

        // Nothing at D level can hold a value in a specific caller-saved register across the trap.
        uint t0_after;
        asm @nogc nothrow
        {
            `
            li      t0, 0x12345678
            li      t4, 1000000
        1:
            lw      t1, %1
            li      t2, 0xCAFEF00D
            beq     t1, t2, 2f
            addi    t4, t4, -1
            bnez    t4, 1b
        2:
            mv      %0, t0
            `
            : "=r" (t0_after)
            : "m" (magic)
            : "t0", "t1", "t2", "t4", "memory";
        }
        oneshot_cancel();
        if (!was_global)
            irq_disable();

        assert(magic == 0xCAFE_F00D, "machine timer IRQ did not fire");
        assert(t0_after == 0x12345678, "caller-saved t0 clobbered across IRQ trap -- th.ipush/ipop not preserving GPRs");
    }
}
