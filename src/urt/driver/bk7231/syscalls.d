module urt.driver.bk7231.syscalls;

@nogc nothrow:

version (BK7231T) extern(C) void* _sbrk(ptrdiff_t increment)
{
    if (!_heap_ptr)
        _heap_ptr = cast(void*)&__heap_start;

    void* previous = _heap_ptr;
    void* next = _heap_ptr + increment;
    if (next < cast(void*)&__heap_start || next > cast(void*)&__heap_end)
        return cast(void*)-1;

    _heap_ptr = next;
    return previous;
}

extern(C) int _write(int fd, const void* buf, size_t count)
{
    import urt.driver.bk7231.uart : uart0_hw_puts;
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
extern(C) int usleep(uint) { return 0; }

extern(C) void __register_frame_info(const void*, void*) {}
extern(C) size_t _Unwind_GetIPInfo(void*, int*) { return 0; }
extern(C) void _Unwind_SetGR(void*, int, size_t) {}
extern(C) void _Unwind_SetIP(void*, size_t) {}

extern(C) void _d_eh_resume_unwind(void*) {}

private:

version (BK7231T)
{
    extern(C) extern const ubyte __heap_start, __heap_end;
    __gshared void* _heap_ptr;
}
