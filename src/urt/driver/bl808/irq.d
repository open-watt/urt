module urt.driver.bl808.irq;

import core.volatile;

public import urt.driver.riscv.csr : irq_disable, irq_enable, wait_for_interrupt;

nothrow @nogc:

enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = true;
enum bool has_global_irq_state = true;
enum bool has_smp = false;

enum uint irq_max = 80;


package(urt.driver):

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
