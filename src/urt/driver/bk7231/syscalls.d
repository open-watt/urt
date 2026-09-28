module urt.driver.bk7231.syscalls;

@nogc nothrow:

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
extern(C) void _exit(int)
{
    import urt.driver.reset : ResetMark, reset_record_mark, system_reset;
    reset_record_mark(ResetMark.crashed);
    system_reset();
}
extern(C) int _kill(int, int) { return -1; }
extern(C) int _getpid() { return 1; }
extern(C) int usleep(uint) { return 0; }

extern(C) void __register_frame_info(const void*, void*) {}
extern(C) size_t _Unwind_GetIPInfo(void*, int*) { return 0; }
extern(C) void _Unwind_SetGR(void*, int, size_t) {}
extern(C) void _Unwind_SetIP(void*, size_t) {}

extern(C) void _d_eh_resume_unwind(void*) {}
