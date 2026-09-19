// ESP32 interrupt controller driver
//
// ESP-IDF manages interrupts via esp_intr_alloc(). Direct vector table
// access is discouraged since FreeRTOS owns it. Global disable/enable is
// the kernel critical section, entered through the C shim so the
// preprocessor picks the form for the kernel and core count in use.
module urt.driver.esp32.irq;

nothrow @nogc:


enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_clic = false;
enum bool has_per_irq_control = false; // TODO: wire up esp_intr_alloc
enum bool has_irq_priority = false;    // TODO: wire up esp_intr_alloc priority flags
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics = false;

// The kernel critical section nests on its own count, so the return value
// is not a prior global IRQ bit the way it is on bare metal. Callers must
// pair enter/exit, and IrqGuard does: "was enabled" makes it always exit.
enum bool has_global_irq_state = false;
enum bool has_smp = false;
enum uint irq_max = 32;

bool irq_disable()
{
    return ow_irq_disable();
}

bool irq_enable()
{
    return ow_irq_enable();
}

bool irq_set_enable(uint irq)
{
    assert(false, "TODO: use esp_intr_alloc");
}

bool irq_clear_enable(uint irq)
{
    assert(false, "TODO: use esp_intr_free");
}

void irq_set_priority(uint irq, ubyte priority)
{
    assert(false, "TODO: use esp_intr_set_in_iram / priority flags");
}

void wait_for_interrupt()
{
    ow_irq_wait();
}


private:

extern(C) bool ow_irq_disable() nothrow @nogc;
extern(C) bool ow_irq_enable() nothrow @nogc;
extern(C) void ow_irq_wait() nothrow @nogc;
