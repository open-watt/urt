module urt.driver.mt7621.syscalls;

@nogc nothrow:

extern(C) int _write(int fd, const void* buf, size_t count)
{
    import urt.driver.mt7621.uart : uart0_hw_puts;
    if (fd == 1 || fd == 2)
        uart0_hw_puts((cast(const(char)*)buf)[0 .. count]);
    return cast(int)count;
}

extern(C) int _read(int, void*, size_t) { return 0; }
extern(C) int _close(int) { return -1; }
extern(C) int _lseek(int, int, int) { return 0; }
extern(C) int _fstat(int, void*) { return 0; }
extern(C) int _isatty(int) { return 1; }
extern(C) void _exit(int status)
{
    import urt.driver.reset : ResetMark, reset_record_mark, system_reset;
    reset_record_mark(status == 0 ? ResetMark.deliberate : ResetMark.crashed);
    system_reset();
}
extern(C) int _kill(int, int) { return -1; }
extern(C) int _getpid() { return 1; }

extern(C) void __register_frame_info(const void*, void*) {}
extern(C) size_t _Unwind_GetIPInfo(void*, int*) { return 0; }
extern(C) void _Unwind_SetGR(void*, int, size_t) {}
extern(C) void _Unwind_SetIP(void*, size_t) {}

// LLVM's emulated TLS ABI; single-threaded, so each variable has exactly one instance.
struct EmutlsControl
{
    size_t size;
    size_t alignment;
    void* instance;
    const(void)* templ;
}

extern(C) void* __emutls_get_address(EmutlsControl* control)
{
    if (control.instance)
        return control.instance;
    import urt.mem.alloc : alloc;
    void[] mem = alloc(control.size, control.alignment < 8 ? 8 : control.alignment);
    if (mem is null)
        return null;
    if (control.templ)
        mem[] = control.templ[0 .. control.size];
    else
        (cast(ubyte[])mem)[] = 0;
    control.instance = mem.ptr;
    return mem.ptr;
}
