    .arm
    .cpu arm968e-s
    .fpu softvfp

    .equ MODE_FIQ, 0x11
    .equ MODE_IRQ, 0x12
    .equ MODE_SVC, 0x13
    .equ MODE_ABT, 0x17
    .equ MODE_UND, 0x1b
    .equ MODE_SYS, 0x1f
    .equ MODE_MASK, 0x1f

    .equ FIQ_STACK_SIZE, 0x7f0
    .equ IRQ_STACK_SIZE, 0xff0
    .equ SYS_STACK_SIZE, 0x3f0

    .equ COLOR_UNUSED, 0xaaaaaaaa
    .equ COLOR_IRQ, 0xcccccccc
    .equ COLOR_FIQ, 0xdddddddd
    .equ COLOR_SYS, 0xeeeeeeee

    .macro change_mode mode
    mrs     r0, cpsr
    bic     r0, r0, #MODE_MASK
    orr     r0, r0, #\mode
    msr     cpsr_c, r0
    .endm

    .macro set_stack base, size, color
    ldr     r0, =\base
    ldr     r1, =\size
    add     sp, r0, r1
    ldr     r2, =\color
1:
    cmp     r0, sp
    strlo   r2, [r0], #4
    blo     1b
    .endm

    .macro push_trap_frame
    sub     sp, sp, #72
    stmia   sp, {r0-r12}
    mov     r0, sp
    mrs     r6, spsr
    str     lr, [r0, #60]
    str     r6, [r0, #64]
    str     sp, [r0, #52]
    str     lr, [r0, #56]
    mrs     r6, cpsr
    str     r6, [r0, #68]
    .endm

    .macro save_mode_registers
    change_mode MODE_SYS
    ldr     r1, =0x00400044
    stmfd   r1!, {r8-r14}
    mrs     r0, cpsr
    stmfd   r1!, {r0}

    change_mode MODE_IRQ
    ldr     r1, =0x00400068
    stmfd   r1!, {r8-r14}
    mrs     r0, spsr
    stmfd   r1!, {r0}
    mrs     r0, cpsr
    stmfd   r1!, {r0}

    change_mode MODE_FIQ
    ldr     r1, =0x0040008c
    stmfd   r1!, {r8-r14}
    mrs     r0, spsr
    stmfd   r1!, {r0}
    mrs     r0, cpsr
    stmfd   r1!, {r0}

    change_mode MODE_ABT
    ldr     r1, =0x004000b0
    stmfd   r1!, {r8-r14}
    mrs     r0, spsr
    stmfd   r1!, {r0}
    mrs     r0, cpsr
    stmfd   r1!, {r0}

    change_mode MODE_UND
    ldr     r1, =0x004000d4
    stmfd   r1!, {r8-r14}
    mrs     r0, spsr
    stmfd   r1!, {r0}
    mrs     r0, cpsr
    stmfd   r1!, {r0}

    change_mode MODE_SVC
    ldr     r1, =0x004000f8
    stmfd   r1!, {r8-r14}
    mrs     r0, spsr
    stmfd   r1!, {r0}
    mrs     r0, cpsr
    stmfd   r1!, {r0}
    .endm

    .section .bss.stacks, "aw", %nobits
    .balign 8
fiq_stack_start:
    .space FIQ_STACK_SIZE

    .balign 8
irq_stack_start:
    .space IRQ_STACK_SIZE

    .balign 8
sys_stack_start:
    .space SYS_STACK_SIZE

    .text
    .code 32

    .global bk_init_mode_stacks
    .type bk_init_mode_stacks, %function
bk_init_mode_stacks:
    mov     r7, lr

    change_mode MODE_SYS
    set_stack sys_stack_start, SYS_STACK_SIZE, COLOR_SYS

    change_mode MODE_ABT
    set_stack _abt_stack_start, _abt_stack_size, COLOR_UNUSED

    change_mode MODE_UND
    set_stack _und_stack_start, _und_stack_size, COLOR_UNUSED

    change_mode MODE_IRQ
    set_stack irq_stack_start, IRQ_STACK_SIZE, COLOR_IRQ

    change_mode MODE_FIQ
    set_stack fiq_stack_start, FIQ_STACK_SIZE, COLOR_FIQ
    mov     r8, #0
    mov     r9, #0
    mov     r10, #0
    mov     r11, #0
    mov     r12, #0

    change_mode MODE_SVC
    bx      r7
    .size bk_init_mode_stacks, . - bk_init_mode_stacks

    .balign 32
    .global do_undefined
    .type do_undefined, %function
do_undefined:
    ldmfd   sp!, {r0-r1}
    push_trap_frame
    stmfd   sp!, {r0-r1}
    save_mode_registers
    change_mode MODE_UND
    ldmfd   sp!, {r0-r1}
    b       bk_trap_udef
    .size do_undefined, . - do_undefined

    .balign 32
    .global do_pabort
    .type do_pabort, %function
do_pabort:
    ldmfd   sp!, {r0-r1}
    push_trap_frame
    stmfd   sp!, {r0-r1}
    save_mode_registers
    change_mode MODE_ABT
    ldmfd   sp!, {r0-r1}
    b       bk_trap_pabt
    .size do_pabort, . - do_pabort

    .balign 32
    .global do_dabort
    .type do_dabort, %function
do_dabort:
    ldmfd   sp!, {r0-r1}
    push_trap_frame
    stmfd   sp!, {r0-r1}
    save_mode_registers
    change_mode MODE_ABT
    ldmfd   sp!, {r0-r1}
    b       bk_trap_dabt
    .size do_dabort, . - do_dabort

    .balign 32
    .global do_reserved
    .type do_reserved, %function
do_reserved:
    ldmfd   sp!, {r0-r1}
    push_trap_frame
    b       bk_trap_resv
    .size do_reserved, . - do_reserved

    .balign 32
    .global boot_undefined
    .type boot_undefined, %function
boot_undefined:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x0040000c
    ldr     r0, [r1]
    bx      r0
    .size boot_undefined, . - boot_undefined

    .balign 32
    .global boot_pabort
    .type boot_pabort, %function
boot_pabort:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x00400010
    ldr     r0, [r1]
    bx      r0
    .size boot_pabort, . - boot_pabort

    .balign 32
    .global boot_dabort
    .type boot_dabort, %function
boot_dabort:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x00400014
    ldr     r0, [r1]
    bx      r0
    .size boot_dabort, . - boot_dabort

    .balign 32
    .global boot_reserved
    .type boot_reserved, %function
boot_reserved:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x00400018
    ldr     r0, [r1]
    bx      r0
    .size boot_reserved, . - boot_reserved

    .balign 32
    .global do_swi
    .type do_swi, %function
do_swi:
    ldmfd   sp!, {r0-r1}
    b       vPortYieldProcessor
    .size do_swi, . - do_swi

    .balign 32
    .global boot_swi
    .type boot_swi, %function
boot_swi:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x00400008
    ldr     r0, [r1]
    bx      r0
    .size boot_swi, . - boot_swi

    .balign 32
    .global irq_handler
    .type irq_handler, %function
irq_handler:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x00400000
    ldr     r0, [r1]
    bx      r0
    .size irq_handler, . - irq_handler

    .balign 32
    .global fiq_handler
    .type fiq_handler, %function
fiq_handler:
    stmfd   sp!, {r0-r1}
    ldr     r1, =0x00400004
    ldr     r0, [r1]
    bx      r0
    .size fiq_handler, . - fiq_handler

    .balign 32
    .global do_irq
    .type do_irq, %function
do_irq:
    ldmfd   sp!, {r0-r1}
    sub     lr, lr, #4
    stmfd   sp!, {r0-r3, r12, lr}
    bl      intc_irq
    ldmfd   sp!, {r0-r3, r12, pc}^
    .size do_irq, . - do_irq

    .balign 32
    .global do_fiq
    .type do_fiq, %function
do_fiq:
    ldmfd   sp!, {r0-r1}
    sub     lr, lr, #4
    stmfd   sp!, {r0-r3, r12, lr}
    bl      intc_fiq
    ldmfd   sp!, {r0-r3, r12, pc}^
    .size do_fiq, . - do_fiq

    .code 32
    .global WFI
    .type WFI, %function
WFI:
    mov     r0, #0
    mcr     p15, 0, r0, c7, c0, 4
    mcr     p15, 0, r0, c15, c8, 2
    mcr     p15, 0, r0, c7, c10, 4
    bx      lr
    .size WFI, . - WFI
