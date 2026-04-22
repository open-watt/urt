/// Espressif (ESP-IDF + FreeRTOS) exception driver.
///
/// Stack-trace capture uses libgcc's `_Unwind_Backtrace` (pulled in
/// by the ESP-IDF toolchain). No on-device symbol resolution -
/// decode addresses offline with `xtensa-esp32-elf-addr2line` /
/// `riscv32-esp-elf-addr2line`.
module sys.esp32.exception;

version (Espressif):

import urt.internal.exception : Resolved;

nothrow @nogc:


// --- libgcc unwind bindings ------------------------------------------

private alias _Unwind_Trace_Fn = extern(C) int function(void* ctx, void* data) nothrow @nogc;
extern(C) private int    _Unwind_Backtrace(_Unwind_Trace_Fn, void*) nothrow @nogc;
extern(C) private size_t _Unwind_GetIP(void*) nothrow @nogc;


// --- Driver interface ------------------------------------------------

// Capture the caller's call stack. First entry = return address of
// the function that called the public `capture_trace` wrapper.
size_t _capture_trace(void*[] addrs) @trusted
{
    if (addrs.length == 0)
        return 0;

    struct State
    {
        void*[] out_addrs;
        size_t count;
        ubyte skip;
    }

    extern(C) static int callback(void* ctx, void* data) nothrow @nogc
    {
        auto s = cast(State*) data;
        if (s.skip > 0) { --s.skip; return 0; }
        if (s.count >= s.out_addrs.length) return 1;
        auto ip = _Unwind_GetIP(ctx);
        if (!ip) return 1;
        s.out_addrs[s.count++] = cast(void*) ip;
        return 0;
    }

    // Skip 2 frames: _Unwind_Backtrace's direct caller (_capture_trace
    // itself) + the public wrapper in urt.internal.exception.
    State state = State(addrs, 0, 2);
    _Unwind_Backtrace(&callback, &state);
    return state.count;
}

// Return the return address of the `skip`-th frame above the public
// `caller_address` wrapper's caller.
void* _caller_address(uint skip) @trusted
{
    void*[32] buf = void;
    const n = _capture_trace(buf[]);
    // When _capture_trace is reached via _caller_address, _Unwind already
    // skipped 2 (itself + wrapper) - but those skips were sized for the
    // direct-call path. From _caller_address the buffer layout is:
    //   buf[0] = PC inside _caller_address  (an extra intermediate)
    //   buf[1] = PC inside USER
    //   buf[2] = PC inside USER's caller     ← skip=0 wants this
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
