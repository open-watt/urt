/// BL808 D0 core platform package
///
/// Provides sys_init() as the single entry point for all
/// hardware initialization. Call from main() before anything else.
module urt.driver.bl808;

public import urt.driver.bl808.uart;
public import urt.driver.bl808.irq;
public import urt.driver.bl808.timer;
public import urt.driver.bl808.xram;
public import urt.driver.bl808.ipc;

@nogc nothrow:

private extern(C) void __register_frame_info(const void*, void*);
private extern(C) extern const ubyte __eh_frame_start;
private ubyte[48] __eh_frame_object;  // pre-allocated storage for libgcc

/// Initialize all D0 core hardware.
/// Call once at the top of main() before any other OpenWatt code.
///
/// Order matters:
///   1. UART — so we have debug output for everything after
///   2. IRQ table — already done by start.S (_init_interrupts)
///   3. Timer — periodic tick for main loop
///   4. IPC — XRAM ring buffers to M0
extern(C) void sys_init()
{
    // Register .eh_frame with libgcc's unwinder so that DWARF exception
    // handling works (required for fibre abort, etc.).
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    // UART0 is already initialized by M0 before D0 boots.
    // Just confirm we're alive.
    uart0_hw_puts("BL808 D0: sys_init\n");

    // Timer: set up 20Hz tick (50ms) for the main loop
    // TODO: wire this to Application.run() instead of a stub
    timer_set_periodic(50_000, &tick_stub);

    // IPC: initialize XRAM ring buffers
    ipc_init();

    uart0_hw_puts("BL808 D0: ready\n");
}

private void tick_stub() @nogc nothrow
{
    // placeholder — will drive urt.time / Application frame tick
}
