/// BL618 newlib/picolibc syscall stubs
///
/// Minimal stubs to satisfy picolibc's syscall requirements.
/// Same pattern as BL808 — most are no-ops for baremetal.
module sys.bl618.syscalls;

@nogc nothrow:

private extern(C) extern __gshared {
    pragma(mangle, "__heap_start") void* _heap_start_ptr;
    pragma(mangle, "__heap_end") void* _heap_end_ptr;
}

private __gshared void* _heap_ptr;

extern(C) void* _sbrk(ptrdiff_t incr)
{
    if (_heap_ptr is null)
        _heap_ptr = cast(void*)&_heap_start_ptr;

    void* prev = _heap_ptr;
    void* next = _heap_ptr + incr;

    if (next > cast(void*)&_heap_end_ptr)
        return cast(void*)-1;

    _heap_ptr = next;
    return prev;
}

extern(C) int _write(int fd, const void* buf, size_t count)
{
    import sys.bl618.uart : uart0_hw_puts;
    if (fd == 1 || fd == 2)
        uart0_hw_puts((cast(const(char)*) buf)[0 .. count]);
    return cast(int) count;
}

extern(C) int _read(int, void*, size_t) { return 0; }
extern(C) int _close(int) { return -1; }
extern(C) int _lseek(int, int, int) { return 0; }
extern(C) int _fstat(int, void*) { return 0; }
extern(C) int _isatty(int) { return 1; }
extern(C) void _exit(int) { while (true) {} }
extern(C) int _kill(int, int) { return -1; }
extern(C) int _getpid() { return 1; }
