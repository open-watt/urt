    .set    noreorder
    .set    noat

/* EBase must be 4 KB aligned; the linker places this section first. */
    .section .vectors, "ax"
    .global __vectors
__vectors:
    .org    0x000                   /* TLB refill: kuseg access, e.g. a null dereference */
    b       exc_entry
    nop
    .org    0x100                   /* cache error */
    b       exc_entry
    nop
    .org    0x180                   /* general exception; ExcCode 0 is an interrupt */
    mfc0    $k0, $13
    andi    $k0, $k0, 0x7c
    beqz    $k0, irq_entry
    nop
    b       exc_entry
    nop
    .org    0x200                   /* interrupt, when Cause.IV is set */
    b       exc_entry
    nop

/* The o32 caller-saved set plus HI/LO; _irq_dispatch preserves the rest. */
irq_entry:
    addiu   $sp, $sp, -96
    sw      $at, 16($sp)
    sw      $v0, 20($sp)
    sw      $v1, 24($sp)
    sw      $a0, 28($sp)
    sw      $a1, 32($sp)
    sw      $a2, 36($sp)
    sw      $a3, 40($sp)
    sw      $t0, 44($sp)
    sw      $t1, 48($sp)
    sw      $t2, 52($sp)
    sw      $t3, 56($sp)
    sw      $t4, 60($sp)
    sw      $t5, 64($sp)
    sw      $t6, 68($sp)
    sw      $t7, 72($sp)
    sw      $t8, 76($sp)
    sw      $t9, 80($sp)
    sw      $ra, 84($sp)
    mfhi    $k0
    sw      $k0, 88($sp)
    mflo    $k0
    jal     _irq_dispatch
    sw      $k0, 92($sp)
    lw      $k0, 88($sp)
    mthi    $k0
    lw      $k0, 92($sp)
    mtlo    $k0
    lw      $at, 16($sp)
    lw      $v0, 20($sp)
    lw      $v1, 24($sp)
    lw      $a0, 28($sp)
    lw      $a1, 32($sp)
    lw      $a2, 36($sp)
    lw      $a3, 40($sp)
    lw      $t0, 44($sp)
    lw      $t1, 48($sp)
    lw      $t2, 52($sp)
    lw      $t3, 56($sp)
    lw      $t4, 60($sp)
    lw      $t5, 64($sp)
    lw      $t6, 68($sp)
    lw      $t7, 72($sp)
    lw      $t8, 76($sp)
    lw      $t9, 80($sp)
    lw      $ra, 84($sp)
    addiu   $sp, $sp, 96
    eret

/* Faults run on their own stack: the one that faulted may be the problem. */
exc_entry:
    mfc0    $a0, $13                /* Cause */
    mfc0    $a1, $14                /* EPC */
    mfc0    $a2, $8                 /* BadVAddr */
    move    $a3, $sp
    la      $sp, _exc_stack_top
    addiu   $sp, $sp, -24
    sw      $ra, 16($sp)
    la      $k0, fault_report
    jr      $k0
    nop

    .section .bss
    .align  4
_exc_stack:
    .space  4096
_exc_stack_top:

    .section .text.start, "ax"
    .global _start
    .type   _start, @function
_start:
    /* Kernel mode, EXL/ERL clear, interrupts masked, vectors from EBase rather than the ROM. */
    mfc0    $t0, $12
    li      $t1, ~0x0040ff1f        /* BEV | IM7..0 | KSU | ERL | EXL | IE */
    and     $t0, $t0, $t1
    mtc0    $t0, $12
    la      $t0, __vectors
    mtc0    $t0, $15, 1             /* EBase */
    ehb

    la      $sp, _stack_top
    la      $gp, _gp

    la      $t0, _bss_start
    la      $t1, _bss_end
1:  beq     $t0, $t1, 2f
    nop
    sw      $zero, 0($t0)
    b       1b
    addiu   $t0, $t0, 4
2:
    jal     sys_init
    nop

    la      $s0, __init_array_start
    la      $s1, __init_array_end
3:  beq     $s0, $s1, 4f
    nop
    lw      $t9, 0($s0)
    jalr    $t9
    addiu   $s0, $s0, 4
    b       3b
    nop
4:
    move    $a0, $zero
    jal     main
    move    $a1, $zero

    jal     _exit
    move    $a0, $v0

    .size   _start, . - _start
