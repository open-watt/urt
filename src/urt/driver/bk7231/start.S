    .arm
    .cpu arm968e-s
    .fpu softvfp

    /* The bootloader validates the signature at +0x100, but runtime vectors remain at 0x0. */
    .section .text.vectors, "ax"
    .global _image_vectors
_image_vectors:
    b       Reset_Handler
    ldr     pc, [pc, #20]
    ldr     pc, [pc, #20]
    ldr     pc, [pc, #20]
    ldr     pc, [pc, #20]
    ldr     pc, [pc, #20]
    ldr     pc, [pc, #20]
    ldr     pc, [pc, #20]
    .word   boot_undefined
    .word   boot_swi
    .word   boot_pabort
    .word   boot_dabort
    .word   boot_reserved
    .word   irq_handler
    .word   fiq_handler
    .word   0xdeadbeef

    b       .Lafter_signature
    .org    0x100
    .word   0x32374b42
    .word   0x00003133
.Lafter_signature:
    b       Reset_Handler

    .section .rodata.ram_image, "a"
    .global _ram_image_deflated
    .type _ram_image_deflated, %object
_ram_image_deflated:
    .byte   0
    .size _ram_image_deflated, 1

    .section .text.entry, "ax"
    .global Reset_Handler
    .type Reset_Handler, %function
Reset_Handler:
    mrs     r0, cpsr
    orr     r0, r0, #0xc0
    msr     cpsr_c, r0

    bl      bk_init_mode_stacks
    ldr     sp, =_stack_top

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

    ldr     r0, =_ram_image_deflated
    ldrb    r0, [r0]
    cmp     r0, #0
    beq     .Lram_copy
    cmp     r0, #1
    bne     .Lhalt
    bl      unpack_ram
    cmp     r0, #0
    beq     .Lhalt
    b       .Lram_done

.Lram_copy:
    ldr     r0, =_tdata_start
    ldr     r1, =_tdata_load
    ldr     r2, =_data_end
.Lram_copy_words:
    sub     r3, r2, r0
    cmp     r3, #4
    blo     .Lram_copy_bytes
    ldr     r3, [r1], #4
    str     r3, [r0], #4
    b       .Lram_copy_words
.Lram_copy_bytes:
    cmp     r0, r2
    beq     .Lram_done
    ldrb    r3, [r1], #1
    strb    r3, [r0], #1
    b       .Lram_copy_bytes
.Lram_done:

    ldr     r0, =_dtcm_data_start
    ldr     r2, =_dtcm_data_end
    mov     r3, #0
    b       .Ldtcm_check
.Ldtcm_zero:
    str     r3, [r0], #4
.Ldtcm_check:
    cmp     r0, r2
    blo     .Ldtcm_zero

    /* Its load address precedes .text, so .itcm.code remains outside the RAM image. */
    ldr     r0, =_itcmcode_ram_begin
    ldr     r1, =_itcmcode_flash_begin
    ldr     r2, =_itcmcode_ram_end
    b       .Litcm_check
.Litcm_copy:
    ldr     r3, [r1], #4
    str     r3, [r0], #4
.Litcm_check:
    cmp     r0, r2
    blo     .Litcm_copy

    ldr     r0, =_bss_start
    ldr     r2, =_bss_end
    mov     r3, #0
    b       .Lbss_check
.Lbss_zero:
    str     r3, [r0], #4
.Lbss_check:
    cmp     r0, r2
    blo     .Lbss_zero

    bl      sys_init

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

    bl      main

.Lhalt:
    b       .Lhalt
    .size Reset_Handler, . - Reset_Handler

    .global __aeabi_read_tp
    .type __aeabi_read_tp, %function
__aeabi_read_tp:
    ldr     r0, =_tdata_start
    bx      lr
    .size __aeabi_read_tp, . - __aeabi_read_tp
