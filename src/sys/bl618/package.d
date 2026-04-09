/// BL618 platform package (T-Head E907 RV32IMAFC)
///
/// Provides sys_init() as the single entry point for all
/// hardware initialization. Call from main() before anything else.
module sys.bl618;

public import sys.bl618.uart;
public import sys.bl618.irq;
public import sys.bl618.timer;

@nogc nothrow:

private extern(C) void __register_frame_info(const void*, void*);
private extern(C) extern const ubyte __eh_frame_start;
private ubyte[48] __eh_frame_object;  // pre-allocated storage for libgcc

/// Initialize BL618 hardware.
/// Call once at the top of main() before any other OpenWatt code.
///
/// Order matters:
///   1. UART — so we have debug output for everything after
///   2. IRQ table — already done by start.S (_init_interrupts)
///   3. Timer — periodic tick for main loop
extern(C) void sys_init()
{
    // Register .eh_frame with libgcc's unwinder so that DWARF exception
    // handling works (required for fibre abort, etc.).
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    uart0_hw_puts("BL618: sys_init\n");

    // Timer: set up 20Hz tick (50ms) for the main loop
    timer_set_periodic(50_000, &tick_stub);

    uart0_hw_puts("BL618: ready\n");
}

private void tick_stub() @nogc nothrow
{
    // placeholder — will drive urt.time / Application frame tick
}
