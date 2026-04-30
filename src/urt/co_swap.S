// Hand-written co_swap for GDC AArch64.
//
// GCC's __attribute__((naked)) is not honored on aarch64 (it's listed in
// the GCC manual only for ARM, x86, AVR, etc.), so the D-side @naked /
// @attribute("naked") falls through to a normal function with a prologue
// that breaks the stack-handoff invariant. Provide an external .S so the
// AArch64 GDC build links to a real naked implementation.
//
// x86_64 still uses the @attribute("naked") inline-asm version in
// fibre.d -- that path is honored on x86_64 (objdump confirms no
// prologue) and can carry the .cfi_undefined directive that terminates
// stack-trace unwinding inside fibres.

#if defined(__aarch64__)

    .text
    .globl  co_swap
    .type   co_swap, %function
co_swap:
    // AAPCS64: x0 = newCtx, x1 = oldCtx.
    // Layout matches fibre.d AArch64 path: sp+lr at 0/8, x19..x28 paired
    // at 16..96, x29 at 96, q8..q15 (128-bit) at 112/144/176/208.
    .cfi_startproc
    .cfi_undefined x30
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
    .cfi_endproc
    .size   co_swap, .-co_swap

#endif

#if defined(__linux__)
    .section .note.GNU-stack,"",%progbits
#endif
