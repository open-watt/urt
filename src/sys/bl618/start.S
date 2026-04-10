/* BL618 (T-Head E907 RV32IMAFC) startup
 *
 * Single-core startup — no M0 handshake needed (unlike BL808).
 *
 * Boot flow:
 *   1. CPU setup    — disable IRQ, enable extensions, FPU, trap vectors
 *   2. Core regs    — gp, tp, sp
 *   3. Section init — .got, .tdata, .tbss, .bss, .data
 *   4. Caches       — I-cache enable
 *   5. Interrupts   — dispatch table, enable MIE+MEIE
 *   6. D runtime    — sys_init, .init_array, main
 *
 * T-Head custom CSR numbers:
 *   mxstatus = 0x7C0   (T-Head ISA extension enable)
 *   mhcr     = 0x7C1   (hardware cache control)
 *   mhint    = 0x7C5   (performance hints)
 *
 * TODO: Verify CSR values and peripheral base addresses against
 *       actual BL618 hardware.  Based on BL616 reference manual.
 */
#define CSR_MXSTATUS 0x7C0
#define CSR_MHCR     0x7C1
#define CSR_MHINT    0x7C5

    .section .text.entry, "ax"
    .global _start
    .type   _start, @function
    .align 2

_start:
    /* ── 1. CPU setup ─────────────────────────────────────────────── */

    /* Disable interrupts */
    csrc    mstatus, 0x0008     /* MIE */

    /* Enable T-Head ISA extensions (THEADISAEE + MM) */
    li      t0, (1 << 22) | (1 << 15)
    csrs    CSR_MXSTATUS, t0

    /* Enable FPU (FS = Initial) — E907 has single-precision FPU */
    li      t0, (1 << 13)
    csrs    mstatus, t0

    /* Set trap vector table (vectored mode) */
    la      t0, __vectors
    ori     t0, t0, 1
    csrw    mtvec, t0

    /* ── 2. Core registers ────────────────────────────────────────── */

    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      tp, _tdata_start
    la      sp, _stack_top

    /* ── 3. Section init ──────────────────────────────────────────── */

    /* Copy .got from flash (LMA) to DTCM (VMA) */
    la      a0, _got_start
    la      a1, _got_load
    la      a2, _got_end
    bgeu    a0, a2, .Lgot_done
.Lgot_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Lgot_copy
.Lgot_done:

    /* Copy .tdata from flash to DTCM */
    la      a0, _tdata_start
    la      a1, _tdata_load
    la      a2, _tdata_end
    bgeu    a0, a2, .Ltdata_done
.Ltdata_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Ltdata_copy
.Ltdata_done:

    /* Zero .tbss */
    la      a0, _tbss_start
    la      a2, _tbss_end
    bgeu    a0, a2, .Ltbss_done
.Ltbss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Ltbss_zero
.Ltbss_done:

    /* Copy .data from flash to OCRAM */
    la      a0, _data_start
    la      a1, _data_load
    la      a2, _data_end
    bgeu    a0, a2, .Ldata_done
.Ldata_copy:
    lw      t0, 0(a1)
    sw      t0, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, 4
    bltu    a0, a2, .Ldata_copy
.Ldata_done:

    /* Zero .bss */
    la      a0, _bss_start
    la      a2, _bss_end
    bgeu    a0, a2, .Lbss_done
.Lbss_zero:
    sw      zero, 0(a0)
    addi    a0, a0, 4
    bltu    a0, a2, .Lbss_zero
.Lbss_done:

    /* ── 4. Caches ────────────────────────────────────────────────── */

    /* Enable I-cache */
    li      t0, (1 << 0)        /* IE: I-cache enable */
    csrs    CSR_MHCR, t0

    /* ── 5. Interrupts ────────────────────────────────────────────── */

    /* Clear CLIC/PLIC pending — TODO: verify PLIC base for BL618 */

    /* Enable machine external interrupts */
    li      t0, (1 << 11)       /* MEIE */
    csrs    mie, t0
    /* Enable global interrupts */
    csrs    mstatus, 0x0008     /* MIE */

    /* ── 6. D runtime ─────────────────────────────────────────────── */

    call    sys_init

    /* Run .init_array (D module constructors, etc.) */
    la      s0, __init_array_start
    la      s1, __init_array_end
    bgeu    s0, s1, .Linit_done
.Linit_loop:
    lw      t0, 0(s0)
    jalr    t0
    addi    s0, s0, 4
    bltu    s0, s1, .Linit_loop
.Linit_done:

    /* Enter main — should never return */
    call    main

    /* If main returns, spin */
.Lhalt:
    wfi
    j       .Lhalt

    .size _start, . - _start

/* ── Interrupt vector table ───────────────────────────────────────── */
    .section .text, "ax"
    .global __vectors
    .type   __vectors, @function
    .align 8

__vectors:
    j       _trap_handler       /* 0: exception / sync trap */
    .align 2
    j       _trap_handler       /* 1: supervisor SW */
    .align 2
    j       _trap_handler       /* 2: reserved */
    .align 2
    j       _trap_handler       /* 3: machine SW */
    .align 2
    j       _trap_handler       /* 4: reserved */
    .align 2
    j       _trap_handler       /* 5: supervisor timer */
    .align 2
    j       _trap_handler       /* 6: reserved */
    .align 2
    j       _trap_handler       /* 7: machine timer */
    .align 2
    j       _trap_handler       /* 8: reserved */
    .align 2
    j       _trap_handler       /* 9: supervisor external */
    .align 2
    j       _trap_handler       /* 10: reserved */
    .align 2
    j       _irq_handler        /* 11: machine external */
    .align 2

/* ── Default trap handler ─────────────────────────────────────────── */
    .global _trap_handler
    .weak   _trap_handler
    .type   _trap_handler, @function
_trap_handler:
    /* TODO: save context, call crash handler */
    j       _trap_handler

/* ── External IRQ handler ─────────────────────────────────────────── */
    .global _irq_handler
    .weak   _irq_handler
    .type   _irq_handler, @function
_irq_handler:
    /* TODO: PLIC claim/complete dispatch — wire to sys.bl618.irq */
    j       _irq_handler
