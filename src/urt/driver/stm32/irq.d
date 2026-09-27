// STM32 interrupt controller driver
//
// Cortex-M4/M7 use the standard ARM NVIC (Nested Vectored Interrupt Controller).
// Peripheral interrupts: F4 82, F7 98, H7 150.
module urt.driver.stm32.irq;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = true;
enum bool has_clic = false;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = true;
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics = false;
enum bool has_global_irq_state = true;
enum bool has_smp = false;

version (STM32H7)
    enum uint irq_max = 150;
else version (STM32F7)
    enum uint irq_max = 98;
else
    enum uint irq_max = 82;

import core.volatile;

// NVIC registers (ARM standard)
private enum ulong NVIC_ISER0 = 0xE000E100;
private enum ulong NVIC_ICER0 = 0xE000E180;
private enum ulong NVIC_ISPR0 = 0xE000E200;
private enum ulong NVIC_ICPR0 = 0xE000E280;
private enum ulong NVIC_IPR0  = 0xE000E400;

// Cortex-M PRIMASK: bit 0 set means interrupts masked. Read it before
// mutating so callers (including IrqGuard) can restore prior state.
bool irq_disable()
{
    uint primask;
    asm @nogc nothrow
    {
        `
        mrs   %0, primask
        cpsid i
        `
        : "=r" (primask);
    }
    return (primask & 1) == 0;
}

bool irq_enable()
{
    uint primask;
    asm @nogc nothrow
    {
        `
        mrs   %0, primask
        cpsie i
        `
        : "=r" (primask);
    }
    return (primask & 1) == 0;
}

// Any interrupt serviced since the last wait ends this one at once, so a wake that lands between
// a waiter's check and here is never slept through. Masked, a pending interrupt still ends wfi.
void wait_for_interrupt()
{
    bool was_enabled = irq_disable();
    if (!_woke)
    {
        asm @nogc nothrow { "dsb sy" ::: "memory"; }
        asm @nogc nothrow { "wfi" ::: "memory"; }
    }
    _woke = false;
    if (was_enabled)
        irq_enable();
}

enum IrqClass : uint
{
    timer,
}

// The timer class is TIM5's line, which also carries mtime's upper word, so it stays enabled.
bool enable_irq(IrqClass)
{
    import urt.driver.stm32.timer : tim5_irq;
    return irq_set_enable(tim5_irq);
}

bool disable_irq(IrqClass)
{
    import urt.driver.stm32.timer : tim5_irq;
    return irq_clear_enable(tim5_irq);
}

bool irq_set_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    auto iser = cast(uint*)(NVIC_ISER0 + reg * 4);
    bool prev = (volatileLoad(iser) & (1u << bit)) != 0;
    volatileStore(iser, 1u << bit);
    return prev;
}

bool irq_clear_enable(uint irq_num)
{
    immutable reg = irq_num / 32;
    immutable bit = irq_num % 32;
    // NVIC mirrors enable state in ISER; reading ISER tells us prior bit
    // regardless of which window (ISER vs ICER) we use to mutate it.
    auto iser = cast(uint*)(NVIC_ISER0 + reg * 4);
    bool prev = (volatileLoad(iser) & (1u << bit)) != 0;
    volatileStore(cast(uint*)(NVIC_ICER0 + reg * 4), 1u << bit);
    return prev;
}

// Set priority for a peripheral IRQ (0 = highest, 255 = lowest)
// STM32F4/F7 implement 4 priority bits (top 4 of 8)
void irq_set_priority(uint irq_num, ubyte priority)
{
    volatileStore(cast(ubyte*)(NVIC_IPR0 + irq_num), priority);
}


// Handler registration

alias IrqHandler = void function(uint irq) @nogc nothrow;

__gshared IrqHandler[irq_max] _handlers;
private __gshared bool _woke;

// Install a handler for a peripheral IRQ (0..irq_max-1). Returns the previous.
// The flash vector table routes every peripheral vector at _nvic_dispatch,
// which recovers the active IRQ from IPSR and calls the registered handler.
IrqHandler irq_set_handler(uint irq, IrqHandler handler)
{
    if (irq >= irq_max)
        return null;
    IrqHandler prev = _handlers[irq];
    _handlers[irq] = handler;
    return prev;
}

// Common entry for every peripheral vector. A plain AAPCS function is a valid
// Cortex-M exception handler: on entry the core has stacked the caller context
// and set lr to EXC_RETURN, so the normal function return triggers exception
// return. IPSR holds the active exception number; peripheral IRQ n is exception
// n + 16.
extern(C) void _nvic_dispatch()
{
    uint ipsr;
    asm @nogc nothrow { "mrs %0, ipsr" : "=r" (ipsr); }
    uint irq = ipsr - 16;
    if (irq < irq_max)
    {
        IrqHandler h = _handlers[irq];
        if (h !is null)
            h(irq);
    }
    _woke = true;
}
