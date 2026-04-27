// Fiber context swap for GDC builds.
// Used in place of fibre.d's `@naked` D version because GDC's @naked is
// silently broken on x86_64 (emits a prologue) and unknown on aarch64.

#if defined(__x86_64__)

    .text
    .globl  co_swap
# if defined(__linux__) || defined(__FreeBSD__)
    .type   co_swap, @function
# endif
co_swap:
    // System V AMD64: rdi = newCtx, rsi = oldCtx.
    // p[0] = rsp, p[1] = rbp, p[2] = rbx, p[3..6] = r12..r15
    movq    %rsp,    (%rsi)
    movq    (%rdi),  %rsp
    popq    %rax
    movq    %rbp,  8(%rsi)
    movq    %rbx, 16(%rsi)
    movq    %r12, 24(%rsi)
    movq    %r13, 32(%rsi)
    movq    %r14, 40(%rsi)
    movq    %r15, 48(%rsi)
    movq     8(%rdi), %rbp
    movq    16(%rdi), %rbx
    movq    24(%rdi), %r12
    movq    32(%rdi), %r13
    movq    40(%rdi), %r14
    movq    48(%rdi), %r15
    jmp     *%rax
# if defined(__linux__) || defined(__FreeBSD__)
    .size   co_swap, .-co_swap
# endif

#elif defined(__aarch64__)

    .text
    .globl  co_swap
    .type   co_swap, %function
co_swap:
    // AAPCS64: x0 = newCtx, x1 = oldCtx.
    // Layout matches fibre.d AArch64 path: sp+lr at 0/8, x19..x28 paired
    // at 16..96, x29 at 96, q8..q15 (128-bit) at 112/144/176/208.
    mov     x16, sp
    stp     x16, x30, [x1]
    ldp     x16, x30, [x0]
    mov     sp,  x16
    stp     x19, x20, [x1, #16]
    stp     x21, x22, [x1, #32]
    stp     x23, x24, [x1, #48]
    stp     x25, x26, [x1, #64]
    stp     x27, x28, [x1, #80]
    str     x29,      [x1, #96]
    stp     q8,  q9,  [x1, #112]
    stp     q10, q11, [x1, #144]
    stp     q12, q13, [x1, #176]
    stp     q14, q15, [x1, #208]
    ldp     x19, x20, [x0, #16]
    ldp     x21, x22, [x0, #32]
    ldp     x23, x24, [x0, #48]
    ldp     x25, x26, [x0, #64]
    ldp     x27, x28, [x0, #80]
    ldr     x29,      [x0, #96]
    ldp     q8,  q9,  [x0, #112]
    ldp     q10, q11, [x0, #144]
    ldp     q12, q13, [x0, #176]
    ldp     q14, q15, [x0, #208]
    br      x30
    .size   co_swap, .-co_swap

#endif

#if defined(__linux__)
    .section .note.GNU-stack,"",%progbits
#endif
