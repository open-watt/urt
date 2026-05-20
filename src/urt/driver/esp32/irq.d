// ESP32 interrupt controller driver
//
// ESP-IDF manages interrupts via esp_intr_alloc(). Direct vector table
// access is discouraged since FreeRTOS owns it. Global disable/enable
// uses FreeRTOS critical section primitives.
module urt.driver.esp32.irq;

nothrow @nogc:


enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_clic = false;
enum bool has_per_irq_control = false; // TODO: wire up esp_intr_alloc
enum bool has_irq_priority = false;    // TODO: wire up esp_intr_alloc priority flags
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics = false;

// FreeRTOS critical sections are recursive (portENTER nests with a per-mux
// counter), so the return value is not a meaningful "prior global IRQ" bit
// the way it is on bare-metal. Callers must pair enter/exit, and IrqGuard
// does -- we always claim "was enabled" so the guard unconditionally exits.
enum bool has_global_irq_state = false;
enum uint irq_max = 32;

bool irq_disable()
{
    ow_irq_disable();
    return true;
}

bool irq_enable()
{
    ow_irq_enable(0);
    return true;
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

extern(C) nothrow @nogc
{
    uint ow_irq_disable();
    void ow_irq_enable(uint prev);
    void ow_irq_wait();
}
