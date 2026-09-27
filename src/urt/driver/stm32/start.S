/* STM32 (ARM Cortex-M4/M7) startup, shared by the F4, F7 and H7 families.
 * The assembler receives -mcpu from the Makefile, so no .cpu directive here.
 */

    .syntax unified
    .thumb

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
    .word   0
    .word   0
    .word   0
    .word   0
    .word   SVCall_Handler
    .word   DebugMon_Handler
    .word   0
    .word   PendSV_Handler
    .word   SysTick_Handler

    /* 150 covers H7; F4 has 82 and F7 98. Every peripheral vector routes to _nvic_dispatch,
     * which recovers the IRQ from IPSR and calls the handler registered via irq_set_handler. */
    .rept 150
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
    bl      copy_words

    ldr     r0, =_data_start
    ldr     r1, =_data_load
    ldr     r2, =_data_end
    bl      copy_words

    ldr     r0, =_tdata_start
    ldr     r1, =_tdata_load
    ldr     r2, =_tdata_end
    bl      copy_words

    ldr     r0, =_ramfunc_start
    ldr     r1, =_ramfunc_load
    ldr     r2, =_ramfunc_end
    bl      copy_words

    ldr     r0, =_tbss_start
    ldr     r2, =_tbss_end
    bl      zero_words

    ldr     r0, =_bss_start
    ldr     r2, =_bss_end
    bl      zero_words

    /* CP10 + CP11 full access */
    ldr     r0, =0xE000ED88
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

/* r0 = dst, r1 = src, r2 = dst end; word aligned. Clobbers r0, r1, r3. */
    .thumb_func
    .type   copy_words, %function
copy_words:
    b       2f
1:  ldr     r3, [r1], #4
    str     r3, [r0], #4
2:  cmp     r0, r2
    blo     1b
    bx      lr
    .size copy_words, . - copy_words

/* r0 = dst, r2 = dst end; word aligned. Clobbers r0, r3. */
    .thumb_func
    .type   zero_words, %function
zero_words:
    movs    r3, #0
    b       2f
1:  str     r3, [r0], #4
2:  cmp     r0, r2
    blo     1b
    bx      lr
    .size zero_words, . - zero_words

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
    bx      lr

/* Single-threaded bare metal: one static TLS block. */
    .global __aeabi_read_tp
    .type   __aeabi_read_tp, %function
    .thumb_func
__aeabi_read_tp:
    ldr     r0, =_tls_base
    bx      lr
    .size   __aeabi_read_tp, . - __aeabi_read_tp
