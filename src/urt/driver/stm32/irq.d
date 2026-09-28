// STM32 interrupt controller: the Cortex-M4/M7 NVIC.
// Peripheral interrupts: F4 82, F7 98, H7 150.
module urt.driver.stm32.irq;

public import urt.driver.cortex_m.nvic;

@nogc nothrow:

enum bool has_per_irq_control = true;
enum bool has_irq_priority = true;
enum bool has_wait_for_interrupt = true;
enum bool has_global_irq_state = true;
enum bool has_smp = false;

version (STM32H7)
    enum uint irq_max = 150;
else version (STM32F7)
    enum uint irq_max = 98;
else
    enum uint irq_max = 82;
