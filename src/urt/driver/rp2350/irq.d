// RP2350 interrupt controller: the Cortex-M33 NVIC, 52 peripheral interrupts (IRQ 0-51).
module urt.driver.rp2350.irq;

public import urt.driver.cortex_m.nvic;

@nogc nothrow:

enum bool has_per_irq_control = true;
enum bool has_irq_priority = true;
enum bool has_wait_for_interrupt = true;
enum bool has_global_irq_state = true;
enum bool has_smp = false;
enum uint irq_max = 52;

// SPAREIRQ_IRQ_0 and _1: no peripheral drives them.
enum uint[2] test_irq_lines = [46, 47];
