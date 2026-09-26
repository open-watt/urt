// STM32 newlib/picolibc syscall stubs
//
// Minimal stubs to satisfy picolibc's syscall requirements.
// Same pattern as RP2350 -- most are no-ops for baremetal.
module urt.driver.stm32.syscalls;

@nogc nothrow:

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
extern(C) void _exit(int)
{
    import urt.driver.reset : ResetMark, reset_record_mark, system_reset;
    reset_record_mark(ResetMark.crashed);
    system_reset();
}
extern(C) int _kill(int, int) { return -1; }
extern(C) int _getpid() { return 1; }

// DWARF unwinder stubs -- ARM Cortex-M uses EHABI, not DWARF.
extern(C) void __register_frame_info(const void*, void*) {}
extern(C) size_t _Unwind_GetIPInfo(void*, int*) { return 0; }
extern(C) void _Unwind_SetGR(void*, int, size_t) {}
extern(C) void _Unwind_SetIP(void*, size_t) {}
