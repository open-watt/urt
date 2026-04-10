/* BK7231N (ARM968E-S, ARMv5TE) startup
 *
 * Boot flow:
 *   1. Beken bootloader validates image, jumps to Reset_Handler
 *   2. Reset_Handler runs:
 *      a. Set up stack pointer
 *      b. Copy .got from flash to SRAM
 *      c. Copy .data from flash to SRAM
 *      d. Copy .tdata from flash to SRAM
 *      e. Zero .bss
 *      f. Call sys_init (platform init)
 *      g. Run .init_array (D module constructors)
 *      h. Call main
 *
 * ARM968E-S has no vector table relocation (no VTOR). Exception vectors live
 * at 0x00000000 (or 0xFFFF0000 if high-vectors enabled). The Beken bootloader
 * owns the vector table; we install handlers via the SDK's IRQ registration API.
 */

    .arm
    .cpu    arm968e-s
    .fpu    softvfp

    .section .text, "ax"
    .global Reset_Handler
    .type   Reset_Handler, %function
Reset_Handler:

    /* -- Disable IRQs during init -- */
    mrs     r0, cpsr
    orr     r0, r0, #0xC0          /* set I+F bits */
    msr     cpsr_c, r0

    /* -- Set up stack -- */
    ldr     sp, =_stack_top

    /* -- Copy .got from flash (LMA) to SRAM (VMA) -- */
    ldr     r0, =_got_start
    ldr     r1, =_got_load
    ldr     r2, =_got_end
    cmp     r0, r1
    beq     .Lgot_done
    b       .Lgot_check
.Lgot_copy:
    ldr     r3, [r1], #4
    str     r3, [r0], #4
.Lgot_check:
    cmp     r0, r2
    blo     .Lgot_copy
.Lgot_done:

    /* -- Copy .data from flash to SRAM -- */
    ldr     r0, =_data_start
    ldr     r1, =_data_load
    ldr     r2, =_data_end
    b       .Ldata_check
.Ldata_copy:
    ldr     r3, [r1], #4
    str     r3, [r0], #4
.Ldata_check:
    cmp     r0, r2
    blo     .Ldata_copy

    /* -- Copy .tdata from flash to SRAM -- */
    ldr     r0, =_tdata_start
    ldr     r1, =_tdata_load
    ldr     r2, =_tdata_end
    b       .Ltdata_check
.Ltdata_copy:
    ldr     r3, [r1], #4
    str     r3, [r0], #4
.Ltdata_check:
    cmp     r0, r2
    blo     .Ltdata_copy

    /* -- Zero .bss -- */
    ldr     r0, =_bss_start
    ldr     r2, =_bss_end
    mov     r3, #0
    b       .Lbss_check
.Lbss_zero:
    str     r3, [r0], #4
.Lbss_check:
    cmp     r0, r2
    blo     .Lbss_zero

    /* -- Platform init -- */
    bl      sys_init

    /* -- Run .init_array (D module constructors) -- */
    ldr     r4, =__init_array_start
    ldr     r5, =__init_array_end
    b       .Linit_check
.Linit_loop:
    ldr     r0, [r4], #4
    mov     lr, pc
    bx      r0
.Linit_check:
    cmp     r4, r5
    blo     .Linit_loop

    /* -- Enter main (should never return) -- */
    bl      main

.Lhalt:
    b       .Lhalt

    .size Reset_Handler, . - Reset_Handler
