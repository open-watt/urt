/// Espressif (ESP-IDF + FreeRTOS) exception driver.
///
/// Stack-trace capture uses ESP-IDF's own backtracer on Xtensa (the
/// window-ABI walker in esp_system) and libgcc's `_Unwind_Backtrace`
/// on the RISC-V parts. No on-device symbol resolution - decode
/// addresses offline with `xtensa-esp32-elf-addr2line` /
/// `riscv32-esp-elf-addr2line`.
module urt.driver.esp32.exception;

version (Espressif):

import urt.attribute : noinline;
import urt.internal.exception : Resolved;

nothrow @nogc:


version (Xtensa)
{
    // --- ESP-IDF window-ABI walker ---------------------------------------

    private struct esp_backtrace_frame_t
    {
        uint pc;
        uint sp;
        uint next_pc;
        const(void)* exc_frame;
    }

    extern(C) private void esp_backtrace_get_start(uint* pc, uint* sp, uint* next_pc) nothrow @nogc;
    extern(C) private bool esp_backtrace_get_next_frame(esp_backtrace_frame_t* frame) nothrow @nogc;

    // Top two bits of a return address are the window increment, not address bits.
    private uint process_stack_pc(uint pc)
    {
        if (pc & 0x80000000)
            pc = (pc & 0x3FFFFFFF) | 0x40000000;
        return pc - 3;
    }
}
else
{
    // --- libgcc unwind bindings ------------------------------------------

    private alias _Unwind_Trace_Fn = extern(C) int function(void* ctx, void* data) nothrow @nogc;
    extern(C) private int    _Unwind_Backtrace(_Unwind_Trace_Fn, void*) nothrow @nogc;
    extern(C) private size_t _Unwind_GetIP(void*) nothrow @nogc;
}


// --- Driver interface ------------------------------------------------

// Capture the caller's call stack. First entry = return address of
// the function that called the public `capture_trace` wrapper.
@noinline
size_t _capture_trace(void*[] addrs) @trusted
{
    if (addrs.length == 0)
        return 0;

    version (Xtensa)
    {
        // get_start reports the frame of its caller's caller, so from here pc is
        // already the public wrapper and next_pc the wrapper's caller.
        esp_backtrace_frame_t frame;
        esp_backtrace_get_start(&frame.pc, &frame.sp, &frame.next_pc);

        size_t count = 0;
        while (count < addrs.length && frame.next_pc != 0)
        {
            if (!esp_backtrace_get_next_frame(&frame))
                break;
            addrs[count++] = cast(void*) process_stack_pc(frame.pc);
        }
        return count;
    }
    else
    {
        struct State
        {
            void*[] out_addrs;
            size_t count;
            ubyte skip;
        }

        extern(C) static int callback(void* ctx, void* data) nothrow @nogc
        {
            auto s = cast(State*) data;
            if (s.skip > 0)
            {
                --s.skip;
                return 0;
            }
            if (s.count >= s.out_addrs.length)
                return 1;
            auto ip = _Unwind_GetIP(ctx);
            if (!ip)
                return 1;
            s.out_addrs[s.count++] = cast(void*) ip;
            return 0;
        }

        // Skip _capture_trace itself and the public wrapper.
        State state = State(addrs, 0, 2);
        _Unwind_Backtrace(&callback, &state);
        return state.count;
    }
}

// Return the return address of the `skip`-th frame above the public
// `caller_address` wrapper's caller.
void* _caller_address(uint skip) @trusted
{
    void*[32] buf = void;
    const n = _capture_trace(buf[]);
    // _caller_address is an extra frame between the wrapper and _capture_trace.
    const want = skip + 2;
    if (n <= want)
        return null;
    return buf[want];
}

// No on-device symbol table. Decode offline with addr2line.
bool _resolve_address(void* addr, out Resolved r) @trusted
{
    return false;
}

// No on-device symbols - caller should treat `results[]` as empty.
bool _resolve_batch(const(void*)[], Resolved[]) @trusted
{
    return false;
}
