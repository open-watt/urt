// Holding peripherals still while a debugger halts the core, so a breakpoint neither trips the watchdog nor lets
// the timers run on. Where a part has no such control the call does nothing.
module urt.driver.debugger;

nothrow @nogc:


enum DebugFreeze : ubyte
{
    watchdog = 1 << 0,
    timers   = 1 << 1,
    all      = watchdog | timers,
}

void debug_freeze(DebugFreeze what)
{
    import core.volatile : volatileLoad, volatileStore;

    static void set(ulong reg, uint bits)
    {
        if (bits)
            volatileStore(cast(uint*)reg, volatileLoad(cast(uint*)reg) | bits);
    }

    version (STM32H7)
    {
        enum ulong dbgmcu = 0x5C00_1000;
        set(dbgmcu + 0x54, what & DebugFreeze.watchdog ? 1 << 18 : 0);          // APB4FZ1.DBG_IWDG1
        set(dbgmcu + 0x3C, what & DebugFreeze.timers ? 0b1111 : 0);             // APB1LFZ1: TIM2-5
        set(dbgmcu + 0x4C, what & DebugFreeze.timers ? 0b11 : 0);               // APB2FZ1: TIM1, TIM8
    }
    else version (STM32)
    {
        enum ulong dbgmcu = 0xE004_2000;
        set(dbgmcu + 0x08, (what & DebugFreeze.watchdog ? 1 << 12 : 0) |       // APB1_FZ: IWDG
                           (what & DebugFreeze.timers ? 0b1111 : 0));           // TIM2-5
        set(dbgmcu + 0x0C, what & DebugFreeze.timers ? 0b11 : 0);               // APB2_FZ: TIM1, TIM8
    }
    else version (RP2350)
    {
        set(0x400D_8000, what & DebugFreeze.watchdog ? 0b111 << 24 : 0);        // WATCHDOG CTRL: PAUSE_JTAG, _DBG0, _DBG1
        set(0x400B_002C, what & DebugFreeze.timers ? 0b110 : 0);                // TIMER0 DBGPAUSE: DBG0, DBG1
        set(0x400B_802C, what & DebugFreeze.timers ? 0b110 : 0);                // TIMER1 DBGPAUSE
    }
}
