// Unified baremetal interrupt controller driver
//
// Backends export the controller primitives; this module owns range checks, the per-line
// handler table and dispatch. A backend's trap path calls irq_dispatch() with the line number.
module urt.driver.irq;

version (BL808_M0)
    public import urt.driver.bl618.irq;
else version (BL808)
    public import urt.driver.bl808.irq;
else version (BL618)
    public import urt.driver.bl618.irq;
else version (Beken)
    public import urt.driver.bk7231.irq;
else version (RP2350)
    public import urt.driver.rp2350.irq;
else version (MT7621)
    public import urt.driver.mt7621.irq;
else version (STM32)
    public import urt.driver.stm32.irq;
else version (Espressif)
    public import urt.driver.esp32.irq;
else
{
    enum bool has_per_irq_control = false;
    enum bool has_irq_priority = false;
    enum bool has_wait_for_interrupt = false;
    enum bool has_global_irq_state = false;
    enum bool has_smp = false;
    enum uint irq_max = 0;
}

nothrow @nogc:

alias IrqHandler = void function(uint irq) nothrow @nogc;


// ====================================================================
// Driver API
// ====================================================================

// `irq_init()` -- platform driver brings the interrupt controller to a known
// state. Re-exported from the platform module via the public import above
// (signature: extern(C) void irq_init()). sys_init in bl_common/system.d
// calls this before any irq_line_enable and before irq_global_enable.

// Global interrupt control

// Disable all interrupt delivery. Returns previous state where the platform
// can report it (has_global_irq_state). FreeRTOS-style critical-section
// platforms always report "true" so IrqGuard pairs enter/exit cleanly.
bool irq_global_disable()
{
    static if (irq_max > 0)
        return irq_disable();
    else
        assert(false, "no IRQ controller");
}

// Enable all interrupt delivery. Returns previous state where the platform
// can report it; see irq_global_disable() for the FreeRTOS caveat.
bool irq_global_enable()
{
    static if (irq_max > 0)
        return irq_enable();
    else
        assert(false, "no IRQ controller");
}

// Set global interrupt state. Returns previous state.
bool irq_global_set(bool enabled)
{
    return enabled ? irq_global_enable() : irq_global_disable();
}

// RAII-style critical section guard; a host has no interrupts to hold off.
// Usage: auto guard = irq_critical();
struct IrqGuard
{
    private bool _prev;
    @disable this();
    @disable this(this);

    ~this() nothrow @nogc
    {
        static if (irq_max > 0)
            irq_global_set(_prev);
    }
}

IrqGuard irq_critical()
{
    IrqGuard g = void;
    static if (irq_max > 0)
        g._prev = irq_global_disable();
    return g;
}

// Per-IRQ control

// Enable a specific peripheral interrupt. Returns previous state; a line out of range reports off.
bool irq_line_enable(uint irq)
{
    static if (has_per_irq_control)
        return irq < irq_max && irq_set_enable(irq);
    else
        assert(false, "no per-IRQ control");
}

// Disable a specific peripheral interrupt. Returns previous state.
bool irq_line_disable(uint irq)
{
    static if (has_per_irq_control)
        return irq < irq_max && irq_clear_enable(irq);
    else
        assert(false, "no per-IRQ control");
}

// 0 is the most urgent, 255 the least; every level still delivers.
void irq_line_set_priority(uint irq, ubyte priority)
{
    static if (has_irq_priority)
    {
        if (irq < irq_max)
            irq_set_priority(irq, priority);
    }
    else
        assert(false, "no IRQ priority support");
}

// Raise a line from software, as if its source had fired. The pend holds until delivered or unpended.
static if (__traits(compiles, irq_set_pending(0u)))
{
    void irq_line_pend(uint irq)
    {
        if (irq < irq_max)
            irq_set_pending(irq);
    }
}

static if (__traits(compiles, irq_clear_pending(0u)))
{
    void irq_line_unpend(uint irq)
    {
        if (irq < irq_max)
            irq_clear_pending(irq);
    }
}

// Handler registration

// Install an interrupt handler. Returns the previous handler for chaining.
IrqHandler irq_handler_set(uint irq, IrqHandler handler)
{
    if (irq >= _handlers.length)
        return null;
    IrqHandler prev = _handlers[irq];
    _handlers[irq] = handler;
    static if (__traits(compiles, irq_hw_attach(irq)))
    {
        if (handler)
            irq_hw_attach(irq);
    }
    return prev;
}

// Called by the backend's trap path, in interrupt context.
void irq_dispatch(uint irq)
{
    if (irq >= _handlers.length)
        return;
    IrqHandler h = _handlers[irq];
    if (h !is null)
        h(irq);
}

// Power management

// Halt CPU until an interrupt fires. Near-zero power draw.
void irq_wait()
{
    static if (has_wait_for_interrupt)
        wait_for_interrupt();
    else
        assert(false, "WFI not available");
}


unittest
{
    static assert(!has_per_irq_control || irq_max > 0);
    static assert(!has_irq_priority || has_per_irq_control);

    static if (irq_max > 0 && has_global_irq_state)
    {
        {
            bool original = irq_global_disable();
            assert(!irq_global_disable(), "second disable must observe IRQs off");
            irq_global_enable();
            assert(irq_global_enable(), "second enable must observe IRQs on");
            irq_global_set(original);
        }

        {
            bool original = irq_global_enable();
            {
                auto guard = irq_critical();
                assert(!irq_global_disable(), "inside the guarded region, IRQs must remain off");
            }
            assert(irq_global_disable(), "guard must re-enable when entered with IRQs on");
            {
                auto guard = irq_critical();
            }
            assert(!irq_global_disable(), "guard must leave IRQs off when entered with IRQs off");
            irq_global_set(original);
        }
    }

    static if (irq_max > 0)
    {{
        // A counted critical section (ESP32 portMUX) asserts internally if nesting is mis-accounted.
        auto outer = irq_critical();
        {
            auto inner = irq_critical();
            {
                auto innermost = irq_critical();
            }
        }
    }}

    static if (has_per_irq_control)
    {
        enum uint slot = irq_max - 1;

        {
            irq_line_disable(slot);
            assert(!irq_line_enable(slot), "freshly cleared slot must report off");
            assert(irq_line_enable(slot), "re-enable must report on");
            assert(irq_line_disable(slot), "disable after enable must report on");
            assert(!irq_line_enable(slot), "re-enable after disable must report off");
            irq_line_disable(slot);
        }

        {
            enum uint bad = irq_max + 1024;
            assert(!irq_line_enable(bad) && !irq_line_disable(bad), "out-of-range must be reported as 'was off'");
            assert(irq_handler_set(bad, null) is null);
        }

        {
            static void a(uint) {}
            static void b(uint) {}

            IrqHandler prior = irq_handler_set(slot, &a);
            scope (exit) irq_handler_set(slot, prior);
            assert(irq_handler_set(slot, &b) is &a, "swap must surface the most recent install");
            assert(irq_handler_set(slot, null) is &b);
        }
    }

    // A backend nominates two lines no source drives as `test_irq_lines` for this to run on its hardware.
    static if (__traits(compiles, irq_line_pend(0u)) && __traits(compiles, test_irq_lines))
    {
        import core.volatile : volatileLoad;

        __gshared uint[2] calls;
        __gshared uint[2] seen;
        static void count(uint irq)
        {
            irq_line_unpend(irq);
            immutable i = irq == test_irq_lines[1];
            ++calls[i];
            seen[i] = irq;
        }
        static void settle()
        {
            foreach (_; 0 .. 100_000)
                volatileLoad(&calls[0]);
        }

        enum uint a = test_irq_lines[0], b = test_irq_lines[1];
        calls = 0;
        seen = ~0u;
        IrqHandler prior_a = irq_handler_set(a, &count);
        IrqHandler prior_b = irq_handler_set(b, &count);
        immutable was_global = irq_global_disable();
        immutable was_a = irq_line_enable(a);
        immutable was_b = irq_line_enable(b);
        scope (exit)
        {
            irq_global_disable();
            irq_line_unpend(a);
            irq_line_unpend(b);
            if (!was_a)
                irq_line_disable(a);
            if (!was_b)
                irq_line_disable(b);
            irq_handler_set(a, prior_a);
            irq_handler_set(b, prior_b);
            irq_global_set(was_global);
        }

        irq_global_enable();
        irq_line_pend(a);
        settle();
        assert(volatileLoad(&calls[0]) == 1 && calls[1] == 0 && seen[0] == a, "a pended line was not delivered once to its own handler");
        irq_line_pend(b);
        settle();
        assert(calls[0] == 1 && volatileLoad(&calls[1]) == 1 && seen[1] == b, "the second line did not route to its own handler");

        irq_line_disable(a);
        irq_line_pend(a);
        settle();
        assert(volatileLoad(&calls[0]) == 1, "a disabled line was delivered");
        irq_line_unpend(a);
        irq_line_enable(a);

        irq_global_disable();
        irq_line_pend(a);
        settle();
        assert(volatileLoad(&calls[0]) == 1, "a line was delivered with IRQs globally off");
        irq_line_unpend(a);

        static if (has_irq_priority)
        {
            irq_line_set_priority(a, 255);
            irq_global_enable();
            irq_line_pend(a);
            settle();
            assert(volatileLoad(&calls[0]) == 2, "the least urgent priority was not delivered");
        }
    }
}


private:

__gshared IrqHandler[has_per_irq_control ? irq_max : 0] _handlers;
