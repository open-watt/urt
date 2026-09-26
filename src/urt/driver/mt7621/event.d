// MT7621 link backend. There is no trigger matrix, and the NMI vectors into RouterBOOT's flash, so
// only the interrupt tier exists: GPIO edges dispatch through the GPIO block's GIC line.
module urt.driver.mt7621.event;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.driver.event;
import urt.driver.gpio : GpioInterruptTrigger, gpio_output_set;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum uint num_links = 8;
enum bool has_reflex = false;

bool can_route(EventKind, TaskKind) pure
    => false;

Result link_hw_open(uint slot, EventSource event, Task task, LinkTier minimum, out bool hardware)
{
    import urt.driver.mt7621.gpio : line_irq_open, link_owner, num_gpio;

    hardware = false;
    if (minimum > LinkTier.interrupt || event.chip != 0 || task.chip != 0 || task.kind == TaskKind.counter_reload)
        return InternalResult.unsupported;
    if (atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return InternalResult.already_exists;

    GpioInterruptTrigger trigger;
    switch (event.kind)
    {
        case EventKind.gpio_rising:  trigger = GpioInterruptTrigger.rising;  break;
        case EventKind.gpio_falling: trigger = GpioInterruptTrigger.falling; break;
        case EventKind.gpio_change:  trigger = GpioInterruptTrigger.change;  break;
        default:
            return InternalResult.unsupported;
    }
    if (event.index >= num_gpio || ((task.kind == TaskKind.gpio_set || task.kind == TaskKind.gpio_clear) && task.index >= num_gpio))
        return InternalResult.invalid_parameter;

    _slots[slot].event = event;
    _slots[slot].task = task;
    atomicStore!(MemoryOrder.release)(_slots[slot].active, true);
    Result result = line_irq_open(event.index, trigger, cast(ubyte)(link_owner | slot));
    if (!result)
        atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
    return result;
}

void link_hw_close(uint slot)
{
    import urt.driver.mt7621.gpio : line_irq_close;
    if (!atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return;
    line_irq_close(_slots[slot].event.index);
    atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
}

bool link_fire(uint slot)
{
    if (slot >= num_links || !atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return false;
    ref task = _slots[slot].task;
    switch (task.kind)
    {
        case TaskKind.isr:
            return task.callback(task.context, LinkContext.interrupt);
        case TaskKind.gpio_set:
        case TaskKind.gpio_clear:
            gpio_output_set(task.index, task.kind == TaskKind.gpio_set);
            return false;
        default:
            return false;
    }
}


private:

struct LinkSlot
{
    EventSource event;
    Task task;
    shared bool active;
}

__gshared LinkSlot[num_links] _slots;

