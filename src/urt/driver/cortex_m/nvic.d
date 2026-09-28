// Cortex-M interrupt control: PRIMASK for global masking, the NVIC per line. A part's irq module
// re-exports this beside its line count.
module urt.driver.cortex_m.nvic;

import core.volatile;

@nogc nothrow:

package(urt.driver):

// PRIMASK bit 0 set means interrupts masked. Read it before mutating so callers (including
// IrqGuard) can restore prior state.
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

// A pending interrupt ends wfi even under PRIMASK.
void wait_for_interrupt()
{
    asm @nogc nothrow { "dsb sy" ::: "memory"; }
    asm @nogc nothrow { "wfi" ::: "memory"; }
}

bool irq_set_enable(uint irq)
{
    auto iser = cast(uint*)(NVIC_ISER0 + irq / 32 * 4);
    bool prev = (volatileLoad(iser) & (1u << (irq % 32))) != 0;
    volatileStore(iser, 1u << (irq % 32));
    return prev;
}

// ISER mirrors the enable state, whichever window changes it.
bool irq_clear_enable(uint irq)
{
    bool prev = (volatileLoad(cast(uint*)(NVIC_ISER0 + irq / 32 * 4)) & (1u << (irq % 32))) != 0;
    volatileStore(cast(uint*)(NVIC_ICER0 + irq / 32 * 4), 1u << (irq % 32));
    return prev;
}

// 0 is the most urgent; parts implement only the top bits of each byte.
void irq_set_priority(uint irq, ubyte priority)
{
    volatileStore(cast(ubyte*)(NVIC_IPR0 + irq), priority);
}

void irq_set_pending(uint irq)
{
    volatileStore(cast(uint*)(NVIC_ISPR0 + irq / 32 * 4), 1u << (irq % 32));
}

void irq_clear_pending(uint irq)
{
    volatileStore(cast(uint*)(NVIC_ICPR0 + irq / 32 * 4), 1u << (irq % 32));
}

// Common entry for every peripheral vector. A plain AAPCS function is a valid
// Cortex-M exception handler: on entry the core has stacked the caller context
// and set lr to EXC_RETURN, so the normal function return triggers exception
// return. IPSR holds the active exception number; peripheral IRQ n is exception
// n + 16.
extern(C) void _nvic_dispatch()
{
    import urt.driver.irq : irq_dispatch;

    uint ipsr;
    asm @nogc nothrow { "mrs %0, ipsr" : "=r" (ipsr); }
    irq_dispatch(ipsr - 16);
}


private:

enum size_t NVIC_ISER0 = 0xE000E100;
enum size_t NVIC_ICER0 = 0xE000E180;
enum size_t NVIC_ISPR0 = 0xE000E200;
enum size_t NVIC_ICPR0 = 0xE000E280;
enum size_t NVIC_IPR0  = 0xE000E400;
