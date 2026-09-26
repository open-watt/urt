/// Bare-metal exception/crash driver.
///
/// Provides the stack-trace driver interface for bare-metal targets
/// (BK7231, BL618, BL808, RP2350, STM32, ...). No symbol resolution is
/// available on-device - addresses are printed raw; decode offline with
/// `addr2line -e <elf> <addr>`.
///
/// Requires the compiler to keep the frame pointer live
/// (`-frame-pointer=all` on LDC). Without it the fp chain is garbage.
module urt.driver.baremetal.exception;

version (BareMetal):

import urt.attribute : noinline;
import urt.internal.exception : Resolved;

nothrow @nogc:

// Linker symbols bounding the valid stack range. Used by the fp-chain
// walker to stop dereferencing junk. Each bare-metal linker script in
// this tree defines both. _stack_low is the bottom of the stack reservation
// (not _bss_end -- on M0 the stack is in OCRAM while .bss is in PSRAM, so
// the two no longer share a region).
//
// These are absolute linker symbols with no storage -- only their addresses
// matter. Declaring as `char` (size 1, never read) and using `&sym` is the
// correct C/D pattern; declaring as `void*` would tell the compiler to
// dereference 4/8 bytes at the symbol's address (i.e. read past stack top).
extern(C) extern __gshared char _stack_top;
extern(C) extern __gshared char _stack_low;


// --- Shared fp-chain walker -------------------------------------------

// RV32/RV64/AArch64 aim fp above the saved pair; 32-bit ARM aims it at the
// saved-fp slot itself (push {.., r7, lr}; add r7, sp, #N).
version (ARM)
    private enum int fp_ra = 1, fp_prev = 0;
else
    private enum int fp_ra = -1, fp_prev = -2;

/// Walk the frame-pointer chain starting at `fp`, writing return addresses
/// into `out_addrs`. Returns the number of frames captured.
size_t walk_fp_chain(size_t fp, void*[] out_addrs) @trusted
{
    if (out_addrs.length == 0)
        return 0;

    const stack_hi = cast(size_t) &_stack_top;
    const stack_lo = cast(size_t) &_stack_low;

    enum reach_lo = (fp_prev < fp_ra ? fp_prev : fp_ra) * ptrdiff_t(size_t.sizeof);
    enum reach_hi = ((fp_prev > fp_ra ? fp_prev : fp_ra) + 1) * ptrdiff_t(size_t.sizeof);

    size_t n = 0;
    while (n < out_addrs.length)
    {
        const access_lo = fp + reach_lo;
        const access_hi = fp + reach_hi;
        if (access_lo < stack_lo || access_hi > stack_hi || access_lo > access_hi || (fp & (size_t.sizeof - 1)) != 0)
            break;

        const ret_addr = (cast(size_t*)fp)[fp_ra];
        const prev_fp  = (cast(size_t*)fp)[fp_prev];

        if (ret_addr == 0)
            break;

        out_addrs[n++] = cast(void*) ret_addr;

        if (prev_fp == 0 || prev_fp <= fp)
            break;
        fp = prev_fp;
    }
    return n;
}


// --- Read own frame pointer -------------------------------------------

private size_t read_fp() @trusted
{
    size_t fp;
    version (RISCV64)
        asm nothrow @nogc @trusted { "mv %0, s0" : "=r"(fp); }
    else version (RISCV32)
        asm nothrow @nogc @trusted { "mv %0, s0" : "=r"(fp); }
    else version (AArch64)
        asm nothrow @nogc @trusted { "mov %0, x29" : "=r"(fp); }
    else version (ARM_Thumb)
        asm nothrow @nogc @trusted { "mov %0, r7" : "=r"(fp); }
    else version (ARM)
        asm nothrow @nogc @trusted { "mov %0, r11" : "=r"(fp); }
    else version (Xtensa)
        asm nothrow @nogc @trusted { "mov %0, a7" : "=r"(fp); } // Xtensa: a7 with -mno-serialize-volatile
    else
        fp = 0; // unknown arch - capture returns empty
    return fp;
}


// --- MIPS prologue unwinder -------------------------------------------
//
// LLVM's MIPS frames keep ra at a size-dependent offset with no fp chain, so frames are read from each
// function's prologue, as Linux's get_frame_info does: `addiu sp, sp, -N` then `sw ra, off(sp)`.

version (MIPS32)
{
    extern(C) extern __gshared char _text_start;
    extern(C) extern __gshared char _text_end;

    private struct MipsFrame
    {
        size_t start;
        size_t size;
        ptrdiff_t ra_off;
    }

    private bool is_frame_alloc(uint insn)
        => (insn & 0xFFFF_8000) == 0x27BD_8000;

    private bool mips_frame_from(size_t prologue, ref MipsFrame f) @trusted
    {
        const insn = *cast(const(uint)*)prologue;
        f.start = prologue;
        f.size = -cast(ptrdiff_t)cast(short)(insn & 0xFFFF);
        foreach (i; 1 .. 32)
        {
            const next = *cast(const(uint)*)(prologue + i * 4);
            if ((next & 0xFFFF_0000) == 0xAFBF_0000)
            {
                f.ra_off = cast(short)(next & 0xFFFF);
                return true;
            }
        }
        return false;
    }

    private bool mips_frame_containing(size_t pc, ref MipsFrame f) @trusted
    {
        const lo = cast(size_t)&_text_start;
        if (pc < lo || pc >= cast(size_t)&_text_end || (pc & 3))
            return false;
        for (size_t p = pc; p >= lo && pc - p < 256 * 1024; p -= 4)
        {
            if (is_frame_alloc(*cast(const(uint)*)p))
                return mips_frame_from(p, f);
        }
        return false;
    }

    // Emits return addresses from the frame of `wrapper` (inclusive or not) upward, after `skip` of them.
    @noinline
    private size_t mips_unwind(void*[] out_addrs, size_t wrapper, bool include_wrapper, uint skip) @trusted
    {
        if (out_addrs.length == 0)
            return 0;

        size_t sp = void;
        asm nothrow @nogc @trusted { "move %0, $sp" : "=r"(sp); }

        MipsFrame f;
        const self = cast(size_t)&mips_unwind;
        bool found;
        foreach (i; 0 .. 8)
        {
            if (is_frame_alloc(*cast(const(uint)*)(self + i * 4)))
            {
                found = mips_frame_from(self + i * 4, f);
                break;
            }
        }
        if (!found)
            return 0;

        const stack_hi = cast(size_t)&_stack_top;
        const stack_lo = cast(size_t)&_stack_low;
        size_t n;
        bool emitting;
        foreach (depth; 0 .. 64)
        {
            if (sp < stack_lo || sp + f.size > stack_hi || f.ra_off < 0 || f.ra_off >= f.size)
                break;
            const ra = *cast(const(size_t)*)(sp + f.ra_off);
            const is_wrapper = f.start == wrapper;
            if (is_wrapper && include_wrapper)
                emitting = true;
            if (emitting)
            {
                if (skip)
                    --skip;
                else
                {
                    out_addrs[n++] = cast(void*)ra;
                    if (n == out_addrs.length)
                        break;
                }
            }
            if (is_wrapper)
                emitting = true;
            sp += f.size;
            if (!mips_frame_containing(ra - 8, f))
                break;
        }
        return n;
    }
}


// --- Driver interface -------------------------------------------------
//
// All three primitives assume they are called through a one-level public
// wrapper in urt.internal.exception (kept non-inlined via pragma(inline,
// false)). The wrapper's frame is accounted for in the skip counts.

/// Capture the caller's call stack. First entry = return address of
/// the function that called the public `capture_trace` wrapper.
@noinline
size_t _capture_trace(void*[] addrs) @trusted
{
    version (MIPS32)
    {
        import urt.internal.exception : capture_trace;
        return mips_unwind(addrs, cast(size_t)&capture_trace, true, 0);
    }
    else
    {
        // LLVM elides _capture_trace's prologue and reads s0 before saving it,
        // so read_fp() returns the CALLER's fp -- not our own. With LTO/tail-call
        // chains (eh_capture_here -> capture_trace -> _capture_trace all tail-
        // calling), this collapses to whichever frame is the topmost non-tail-
        // called caller. Walk from there directly; the old "step up once"
        // overshot whenever the wrapper chain tail-called.
        auto fp = read_fp();
        if (fp == 0)
            return 0;
        return walk_fp_chain(fp, addrs);
    }
}

/// Return the return address of the `skip`-th frame above the public
/// `caller_address` wrapper's caller.
@noinline
void* _caller_address(uint skip) @trusted
{
    version (MIPS32)
    {
        import urt.internal.exception : caller_address;
        void*[1] buf = void;
        return mips_unwind(buf[], cast(size_t)&caller_address, false, skip) ? buf[0] : null;
    }
    else
    {
        // Same elision/tail-call pattern as _capture_trace: read_fp() returns
        // the topmost non-tail-called caller's fp. With LLVM tail-calling the
        // public capture_address wrapper, that is USER's fp directly. So
        //   buf[0] = USER's saved ra = inside USER's caller   ← skip=0 wants this
        //   buf[1] = caller's caller                          ← skip=1
        auto fp = read_fp();
        if (fp == 0)
            return null;

        void*[32] buf = void;
        const need = skip + 1;
        if (need > buf.length)
            return null;
        const got = walk_fp_chain(fp, buf[0 .. need]);
        if (got < need)
            return null;
        return buf[skip];
    }
}

/// On bare-metal we have no on-device symbol table. Always returns
/// false; decode the address offline with `addr2line`.
bool _resolve_address(void* addr, out Resolved r) @trusted
{
    return false;
}

/// No on-device symbols - caller should treat `results[]` as empty.
bool _resolve_batch(const(void*)[] addrs, Resolved[] results) @trusted
{
    return false;
}
