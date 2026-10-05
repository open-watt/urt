// BL808 M0 link backend. There is no trigger matrix, so only the interrupt tier exists: GPIO edges
// dispatch through the GPIO block's CLIC line.
module urt.driver.bl808_m0.event;

import urt.driver.event;
import urt.driver.event_core : EventLinks, gpio_link_check, gpio_link_trigger;
import urt.driver.gpio : gpio_output_set;
import urt.driver.irq : irq_critical;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum uint num_links = 8;
enum bool has_reflex = false;

bool can_route(EventKind, TaskKind) pure
    => false;

Result link_hw_open(uint slot, EventSource event, Task task, LinkTier minimum, out bool hardware)
{
    import urt.driver.bl_common.gpio : line_irq_open, link_owner, num_gpio;

    hardware = false;
    Result result = gpio_link_check(event, task, minimum, num_gpio);
    if (!result)
        return result;

    // a callback may open or close a link from the ISR
    auto guard = irq_critical();
    if (_links.active(slot))
        return InternalResult.already_exists;
    result = line_irq_open(event.index, gpio_link_trigger(event.kind), cast(ubyte)(link_owner | slot));
    if (result)
        _links.claim(slot, event, task);
    return result;
}

void link_hw_close(uint slot)
{
    import urt.driver.bl_common.gpio : line_irq_close;

    auto guard = irq_critical();
    if (!_links.active(slot))
        return;
    line_irq_close(_links.pin(slot));
    _links.release(slot);
}

// The GPIO ISR calls this inside the critical section that took the edge, so the slot's owner is current.
bool link_fire(uint slot)
    => _links.fire(_links.owner(cast(ubyte)slot));

private:

__gshared EventLinks!(num_links, gpio_output_set) _links;
