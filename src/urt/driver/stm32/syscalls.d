// STM32 newlib/picolibc syscall stubs
//
// Minimal stubs to satisfy picolibc's syscall requirements.
// Same pattern as RP2350 -- most are no-ops for baremetal.
module urt.driver.stm32.syscalls;

@nogc nothrow:

private extern(C) extern const void* __heap_start;
private extern(C) extern const void* __heap_end;

private __gshared void* _heap_ptr;

extern(C) void* _sbrk(ptrdiff_t incr)
{
    if (_heap_ptr is null)
        _heap_ptr = cast(void*)&__heap_start;

    void* prev = _heap_ptr;
    void* next = _heap_ptr + incr;

    if (next > cast(void*)&__heap_end)
        return cast(void*)-1;

    _heap_ptr = next;
    return prev;
}

extern(C) int _write(int fd, const void* buf, size_t count)
{
    import urt.driver.stm32.uart : uart0_hw_puts;
    if (fd == 1 || fd == 2)
        uart0_hw_puts((cast(const(char)*)buf)[0 .. count]);
    return cast(int)count;
}

extern(C) int _read(int, void*, size_t) { return 0; }
extern(C) int _close(int) { return -1; }
extern(C) int _lseek(int, int, int) { return 0; }
extern(C) int _fstat(int, void*) { return 0; }
extern(C) int _isatty(int) { return 1; }
extern(C) void _exit(int) { while (true) {} }
extern(C) int _kill(int, int) { return -1; }
extern(C) int _getpid() { return 1; }

// DWARF unwinder stubs -- ARM Cortex-M uses EHABI, not DWARF.
extern(C) void __register_frame_info(const void*, void*) {}
extern(C) size_t _Unwind_GetIPInfo(void*, int*) { return 0; }
extern(C) void _Unwind_SetGR(void*, int, size_t) {}
extern(C) void _Unwind_SetIP(void*, size_t) {}
