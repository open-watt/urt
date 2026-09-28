module urt.driver.bl808.irq;

import core.volatile;

nothrow @nogc:

enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = true;
enum bool has_global_irq_state = true;
enum bool has_smp = false;

enum uint irq_max = 80;


// ================================================================
// CPU interrupt control
// ================================================================

// Disable interrupt delivery. Returns previous state.
bool irq_disable()
{
    ulong prev;
    asm nothrow @nogc { "csrrci %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

// Enable interrupt delivery. Returns previous state.
bool irq_enable()
{
    ulong prev;
    asm nothrow @nogc { "csrrsi %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

// Halt CPU until an interrupt is pending. Near-zero power.
void wait_for_interrupt()
{
    asm nothrow @nogc { "wfi"; }
}


// ================================================================
// PLIC lines
// ================================================================

// Enable an individual PLIC IRQ (set priority > 0 and enable bit)
bool irq_set_enable(uint irq)
{
    auto prio = cast(uint*)(plic_base + irq * 4);
    volatileStore(prio, 1);
    auto en = cast(uint*)(plic_enable + (irq / 32) * 4);
    uint mask = 1U << (irq % 32);
    uint prev = volatileLoad(en);
    volatileStore(en, prev | mask);
    return (prev & mask) != 0;
}

// Disable an individual PLIC IRQ. Returns previous state.
bool irq_clear_enable(uint irq)
{
    auto en = cast(uint*)(plic_enable + (irq / 32) * 4);
    uint mask = 1U << (irq % 32);
    uint prev = volatileLoad(en);
    volatileStore(en, prev & ~mask);
    return (prev & mask) != 0;
}

// PLIC bring-up. C906/D0 boots with the PLIC already in a usable state from
// the boot ROM, so for now this is a stub that satisfies the sys_init
// contract. When we start exposing per-IRQ priorities we'll move that setup
// here (cleared priorities, enable mask zeroed) -- mirrors the CLIC's
// irq_init in bl618/irq.d.
extern(C) void irq_init() {}

// Called from start.S _trap_mext with the claimed id, which it returns for the completion write.
extern(C) uint _irq_dispatch(uint irq)
{
    import urt.driver.irq : irq_dispatch;

    irq_dispatch(irq);
    return irq;
}


private:

enum ulong plic_base   = 0xE000_0000;
enum ulong plic_enable = 0xE000_2000;
