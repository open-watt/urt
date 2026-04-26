/* STM32 (ARM Cortex-M4/M7) startup
 *
 * Shared between STM32F4xx and STM32F7xx. The assembler receives
 * -mcpu=cortex-m4 or -mcpu=cortex-m7 from the Makefile, so no
 * .cpu directive here.
 *
 * Boot flow:
 *   1. Cortex-M reads vector table from flash: initial SP + Reset_Handler
 *   2. Reset_Handler runs:
 *      a. Copy .got from flash to RAM
 *      b. Copy .data from flash to RAM
 *      c. Zero .bss
 *      d. Enable FPU (CP10 + CP11)
 *      e. Call sys_init (clock, GPIO, UART, cache)
 *      f. Run .init_array (D module constructors)
 *      g. Call main
 */

    .syntax unified
    .thumb

/* ================================================================
 * Vector table -- placed at start of FLASH
 * Cortex-M reads entry 0 as initial SP, entry 1 as Reset_Handler
 * ================================================================ */
    .section .vector_table, "a"
    .global __vector_table
    .type   __vector_table, %object
__vector_table:
    .word   _stack_top          /*  0: Initial stack pointer */
    .word   Reset_Handler       /*  1: Reset */
    .word   NMI_Handler         /*  2: NMI */
    .word   HardFault_Handler   /*  3: Hard fault */
    .word   MemManage_Handler   /*  4: MPU fault */
    .word   BusFault_Handler    /*  5: Bus fault */
    .word   UsageFault_Handler  /*  6: Usage fault */
    .word   0                   /*  7: Reserved */
    .word   0                   /*  8: Reserved */
    .word   0                   /*  9: Reserved */
    .word   0                   /* 10: Reserved */
    .word   SVCall_Handler      /* 11: SVCall */
    .word   DebugMon_Handler    /* 12: Debug monitor */
    .word   0                   /* 13: Reserved */
    .word   PendSV_Handler      /* 14: PendSV */
    .word   SysTick_Handler     /* 15: SysTick */

    /* IRQ 0-97 (98 entries covers both F4 82 and F7 98 IRQs) */
    .rept 98
    .word   Default_Handler
    .endr

    .size __vector_table, . - __vector_table

/* ================================================================
 * Reset handler
 * ================================================================ */
    .section .text, "ax"
    .global Reset_Handler
    .type   Reset_Handler, %function
    .thumb_func
Reset_Handler:

    /* -- Copy .got from flash (LMA) to RAM (VMA) -- */
    ldr     r0, =_got_start
    ldr     r1, =_got_load
    ldr     r2, =_got_end
    cmp     r0, r1
    beq     .Lgot_done
    b       .Lgot_check
.Lgot_copy:
    ldm     r1!, {r3}
    stm     r0!, {r3}
.Lgot_check:
    cmp     r0, r2
    blo     .Lgot_copy
.Lgot_done:

    /* -- Copy .data from flash to RAM -- */
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

    /* -- Zero .bss -- */
    ldr     r0, =_bss_start
    ldr     r2, =_bss_end
    movs    r3, #0
    b       .Lbss_check
.Lbss_zero:
    stm     r0!, {r3}
.Lbss_check:
    cmp     r0, r2
    blo     .Lbss_zero

    /* -- Enable FPU (CP10 + CP11 full access) -- */
    ldr     r0, =0xE000ED88     /* CPACR */
    ldr     r1, [r0]
    orr     r1, r1, #(0xF << 20)
    str     r1, [r0]
    dsb
    isb

    /* -- Platform init (clock, GPIO, UART, cache) -- */
    bl      sys_init

    /* -- Run .init_array (D module constructors) -- */
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

    /* -- Enter main (should never return) -- */
    bl      main

    /* If main returns, spin */
.Lhalt:
    wfi
    b       .Lhalt

    .size Reset_Handler, . - Reset_Handler

/* ================================================================
 * Default exception/interrupt handlers (weak, overridable)
 * ================================================================ */
    .thumb_func
    .weak   NMI_Handler
    .type   NMI_Handler, %function
NMI_Handler:
    b       .

    .thumb_func
    .weak   HardFault_Handler
    .type   HardFault_Handler, %function
HardFault_Handler:
    b       .

    .thumb_func
    .weak   MemManage_Handler
    .type   MemManage_Handler, %function
MemManage_Handler:
    b       .

    .thumb_func
    .weak   BusFault_Handler
    .type   BusFault_Handler, %function
BusFault_Handler:
    b       .

    .thumb_func
    .weak   UsageFault_Handler
    .type   UsageFault_Handler, %function
UsageFault_Handler:
    b       .

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

/* ================================================================
 * __aeabi_read_tp -- ARM EABI thread pointer for TLS access
 * Single-threaded bare-metal: return fixed pointer to .tdata
 * ================================================================ */
    .global __aeabi_read_tp
    .type   __aeabi_read_tp, %function
    .thumb_func
__aeabi_read_tp:
    ldr     r0, =_tdata_start
    bx      lr
    .size   __aeabi_read_tp, . - __aeabi_read_tp
