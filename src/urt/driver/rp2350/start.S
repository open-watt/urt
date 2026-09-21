    .syntax unified
    .cpu    cortex-m33
    .fpu    fpv5-sp-d16
    .thumb

    .section .embedded_block, "a"
    .p2align 2
    .global __embedded_block
__embedded_block:
    .word   0xffffded3              /* PICOBIN_BLOCK_MARKER_START */
    .byte   0x42                    /* ITEM_1BS_IMAGE_TYPE */
    .byte   0x01                    /* one word */
    .hword  0x1021                  /* EXE | SECURITY_S | CPU_ARM | CHIP_RP2350 */
    .byte   0xff                    /* ITEM_2BS_LAST */
    .hword  (__embedded_block_end - __embedded_block - 16) / 4
    .byte   0
    .word   0                       /* single-block loop: next block is this one */
    .word   0xab123579              /* PICOBIN_BLOCK_MARKER_END */
__embedded_block_end:
    .size __embedded_block, . - __embedded_block

    .section .vector_table, "a"
    .global __vector_table
    .type   __vector_table, %object
__vector_table:
    .word   _stack_top
    .word   Reset_Handler
    .word   NMI_Handler
    .word   HardFault_Handler
    .word   MemManage_Handler
    .word   BusFault_Handler
    .word   UsageFault_Handler
    .word   SecureFault_Handler
    .word   0
    .word   0
    .word   0
    .word   SVCall_Handler
    .word   DebugMon_Handler
    .word   0
    .word   PendSV_Handler
    .word   SysTick_Handler

    .rept 52
    .word   _nvic_dispatch
    .endr

    .size __vector_table, . - __vector_table

    .section .text, "ax"
    .global Reset_Handler
    .type   Reset_Handler, %function
    .thumb_func
Reset_Handler:
    ldr     r0, =_got_start
    ldr     r1, =_got_load
    ldr     r2, =_got_end
    cmp     r0, r1              /* skip if VMA == LMA (not relocated) */
    beq     .Lgot_done
    b       .Lgot_check
.Lgot_copy:
    ldm     r1!, {r3}
    stm     r0!, {r3}
.Lgot_check:
    cmp     r0, r2
    blo     .Lgot_copy
.Lgot_done:

    ldr     r0, =_data_start
    ldr     r1, =_data_load
    ldr     r2, =_data_end
    b       .Ldata_check
.Ldata_copy:
    ldm     r1!, {r3}
    stm     r0!, {r3}
.Ldata_check:
    cmp     r0, r2
    blo     .Ldata_copy

    ldr     r0, =_tdata_start
    ldr     r1, =_tdata_load
    ldr     r2, =_tdata_end
    b       .Ltdata_check
.Ltdata_copy:
    ldm     r1!, {r3}
    stm     r0!, {r3}
.Ltdata_check:
    cmp     r0, r2
    blo     .Ltdata_copy

    ldr     r0, =_tbss_start
    ldr     r2, =_tbss_end
    movs    r3, #0
    b       .Ltbss_check
.Ltbss_zero:
    stm     r0!, {r3}
.Ltbss_check:
    cmp     r0, r2
    blo     .Ltbss_zero

    ldr     r0, =_bss_start
    ldr     r2, =_bss_end
    movs    r3, #0
    b       .Lbss_check
.Lbss_zero:
    stm     r0!, {r3}
.Lbss_check:
    cmp     r0, r2
    blo     .Lbss_zero

    ldr     r0, =0xE000ED88     /* CPACR */
    ldr     r1, [r0]
    orr     r1, r1, #(0xF << 20)
    str     r1, [r0]
    dsb
    isb

    bl      sys_init

    ldr     r4, =__init_array_start
    ldr     r5, =__init_array_end
    b       .Linit_check
.Linit_loop:
    ldr     r0, [r4]
    blx     r0
    adds    r4, r4, #4
.Linit_check:
    cmp     r4, r5
    blo     .Linit_loop

    movs    r0, #0
    movs    r1, #0
    mov     r7, r0
    bl      main

.Lhalt:
    wfi
    b       .Lhalt

    .size Reset_Handler, . - Reset_Handler

    .thumb_func
    .weak   NMI_Handler
    .type   NMI_Handler, %function
NMI_Handler:
    movs    r0, #2
    b       fault_entry

    .thumb_func
    .weak   HardFault_Handler
    .type   HardFault_Handler, %function
HardFault_Handler:
    movs    r0, #3
    b       fault_entry

    .thumb_func
    .weak   MemManage_Handler
    .type   MemManage_Handler, %function
MemManage_Handler:
    movs    r0, #4
    b       fault_entry

    .thumb_func
    .weak   BusFault_Handler
    .type   BusFault_Handler, %function
BusFault_Handler:
    movs    r0, #5
    b       fault_entry

    .thumb_func
    .weak   UsageFault_Handler
    .type   UsageFault_Handler, %function
UsageFault_Handler:
    movs    r0, #6
    b       fault_entry

    .thumb_func
    .weak   SecureFault_Handler
    .type   SecureFault_Handler, %function
SecureFault_Handler:
    movs    r0, #7
    b       fault_entry

/* EXC_RETURN bit 2 says which stack the core pushed the frame on. */
    .thumb_func
    .type   fault_entry, %function
fault_entry:
    tst     lr, #4
    ite     eq
    mrseq   r1, msp
    mrsne   r1, psp
    b       fault_report

    .thumb_func
    .weak   SVCall_Handler
    .type   SVCall_Handler, %function
SVCall_Handler:
    b       .

    .thumb_func
    .weak   DebugMon_Handler
    .type   DebugMon_Handler, %function
DebugMon_Handler:
    b       .

    .thumb_func
    .weak   PendSV_Handler
    .type   PendSV_Handler, %function
PendSV_Handler:
    b       .

    .thumb_func
    .weak   SysTick_Handler
    .type   SysTick_Handler, %function
SysTick_Handler:
    b       .

    .thumb_func
    .weak   Default_Handler
    .type   Default_Handler, %function
Default_Handler:
    b       .

    .global __aeabi_read_tp
    .type   __aeabi_read_tp, %function
    .thumb_func
__aeabi_read_tp:
    ldr     r0, =_tls_base
    bx      lr
    .size   __aeabi_read_tp, . - __aeabi_read_tp
