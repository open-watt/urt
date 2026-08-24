    .arm
    .section .text, "ax"

    .extern vTaskSwitchContext
    .extern pxCurrentTCB
    .extern ulCriticalNesting

    .global vPortYieldProcessor
    .global vPortStartFirstTask

    .macro portSAVE_CONTEXT
    stmdb   sp!, {r0}
    stmdb   sp, {sp}^
    nop
    sub     sp, sp, #4
    ldmia   sp!, {r0}
    stmdb   r0!, {lr}
    mov     lr, r0
    ldmia   sp!, {r0}
    stmdb   lr, {r0-r14}^
    nop
    sub     lr, lr, #60
    mrs     r0, spsr
    stmdb   lr!, {r0}
    ldr     r0, =ulCriticalNesting
    ldr     r0, [r0]
    stmdb   lr!, {r0}
    ldr     r1, =pxCurrentTCB
    ldr     r0, [r1]
    str     lr, [r0]
    .endm

    .macro portRESTORE_CONTEXT
    ldr     r1, =pxCurrentTCB
    ldr     r0, [r1]
    ldr     lr, [r0]
    ldr     r0, =ulCriticalNesting
    ldmfd   lr!, {r1}
    str     r1, [r0]
    ldmfd   lr!, {r0}
    msr     spsr_cxsf, r0
    ldmfd   lr, {r0-r14}^
    nop
    ldr     lr, [lr, #+60]
    subs    pc, lr, #4
    .endm

    .type vPortStartFirstTask, %function
vPortStartFirstTask:
    portRESTORE_CONTEXT
    .size vPortStartFirstTask, . - vPortStartFirstTask

    .type vPortYieldProcessor, %function
vPortYieldProcessor:
    add     lr, lr, #4
    portSAVE_CONTEXT
    ldr     r0, =vTaskSwitchContext
    mov     lr, pc
    bx      r0
    portRESTORE_CONTEXT
    .size vPortYieldProcessor, . - vPortYieldProcessor
