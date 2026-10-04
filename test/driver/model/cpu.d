// The interrupt controller and CPU a backend runs on: global masking, per-line enables, and delivery of
// every enabled line whose peripheral asserts it, whenever interrupts come back on.
module model.cpu;

import urt.driver.irq : irq_dispatch;

nothrow @nogc:

enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = false;
enum bool has_global_irq_state = true;
enum bool has_smp = false;
enum uint irq_max = 160;

// Which lines a peripheral model asserts; set by the chip fixture.
__gshared bool function(uint line) nothrow @nogc asserted;

__gshared bool irq_on = true;
__gshared bool[irq_max] line_on;
__gshared uint storms;

bool irq_disable()
{
    immutable prev = irq_on;
    irq_on = false;
    return prev;
}

bool irq_enable()
{
    immutable prev = irq_on;
    irq_on = true;
    deliver();
    return prev;
}

bool irq_set_enable(uint line)
{
    immutable prev = line_on[line];
    line_on[line] = true;
    deliver();
    return prev;
}

bool irq_clear_enable(uint line)
{
    immutable prev = line_on[line];
    line_on[line] = false;
    return prev;
}

// A level-triggered line still asserted after its handler ran this many times is a storm.
void deliver()
{
    if (!irq_on || !asserted)
        return;
    irq_on = false;
    foreach (round; 0 .. 64)
    {
        bool any;
        foreach (line; 0 .. irq_max)
        {
            if (line_on[line] && asserted(line))
            {
                irq_dispatch(line);
                any = true;
            }
        }
        if (!any)
        {
            irq_on = true;
            return;
        }
    }
    ++storms;
    irq_on = true;
}
