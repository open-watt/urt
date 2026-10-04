// STM32 link backend. There is no trigger matrix a link can use, so only the interrupt tier exists: a GPIO
// edge arms the EXTI line of its pin number, and each line takes its pin from one port at a time.
module urt.driver.stm32.event;

import urt.driver.event;
import urt.driver.event_core : EventLinks, LinkOwner, gpio_link_check, no_link;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_enable;
import urt.driver.stm32 : clock_enable, reg_read, reg_rmw, reg_write;
import urt.driver.stm32.gpio : gpio_input_if_analog, gpio_output_set, num_gpio;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum uint num_links = 8;
enum bool has_reflex = false;

bool can_route(EventKind, TaskKind) pure
    => false;

Result link_hw_open(uint slot, EventSource event, Task task, LinkTier minimum, out bool hardware)
{
    hardware = false;
    Result result = gpio_link_check(event, task, minimum, num_gpio);
    if (!result)
        return result;

    immutable uint line = event.index & 15;
    // a callback may open or close a link from the ISR, and the EXTI and SYSCFG registers are shared
    auto guard = irq_critical();
    if (_links.active(slot))
        return InternalResult.already_exists;
    if (_line_slot[line] != no_link)
        return InternalResult.failed;

    gpio_input_if_analog(event.index);
    _links.claim(slot, event, task);
    _line_slot[line] = cast(ubyte)slot;

    clock_enable(syscfg_enr, syscfg_bit);
    immutable uint shift = (line & 3) * 4;
    reg_rmw(syscfg_base + exticr + (line >> 2) * 4, 0xFu << shift, (event.index >> 4) << shift);
    immutable uint bit = 1u << line;
    reg_rmw(exti_base + rtsr, bit, event.kind != EventKind.gpio_falling ? bit : 0);
    reg_rmw(exti_base + ftsr, bit, event.kind != EventKind.gpio_rising ? bit : 0);
    reg_write(exti_base + pr, bit);
    reg_rmw(exti_base + imr, 0, bit);
    irq_handler_set(line_irq[line], &exti_isr);
    irq_line_enable(line_irq[line]);
    return result;
}

// The NVIC line stays enabled, since lines 5-9 and 10-15 share one; a masked EXTI line never pends.
void link_hw_close(uint slot)
{
    auto guard = irq_critical();
    if (!_links.active(slot))
        return;
    immutable uint line = _links.pin(slot) & 15;
    immutable uint bit = 1u << line;
    reg_rmw(exti_base + imr, bit, 0);
    reg_rmw(exti_base + rtsr, bit, 0);
    reg_rmw(exti_base + ftsr, bit, 0);
    reg_write(exti_base + pr, bit);
    _line_slot[line] = no_link;
    _links.release(slot);
}


private:

version (STM32H7)
{
    enum ulong exti_base = 0x5800_0000;
    enum uint rtsr = 0x00;
    enum uint ftsr = 0x04;
    enum uint imr  = 0x80;
    enum uint pr   = 0x88;
    enum ulong syscfg_base = 0x5800_0400;
    enum uint syscfg_enr = 0xF4;
    enum uint syscfg_bit = 1;
}
else
{
    enum ulong exti_base = 0x4001_3C00;
    enum uint imr  = 0x00;
    enum uint rtsr = 0x08;
    enum uint ftsr = 0x0C;
    enum uint pr   = 0x14;
    enum ulong syscfg_base = 0x4001_3800;
    enum uint syscfg_enr = 0x44;
    enum uint syscfg_bit = 14;
}
enum uint exticr = 0x08;

static immutable ubyte[16] line_irq = [ 6, 7, 8, 9, 10, 23, 23, 23, 23, 23, 40, 40, 40, 40, 40, 40 ];

__gshared EventLinks!(num_links, gpio_output_set) _links;
__gshared ubyte[16] _line_slot = no_link;

// Every EXTI vector lands here: a shared one serves several lines, so the pending mask says which fired.
void exti_isr(uint)
{
    import urt.internal.bitop : bsf;

    uint pending;
    LinkOwner[16] owner = void;
    {
        // an edge belongs to the link that owned its line when it was taken, not to one opened since
        auto guard = irq_critical();
        pending = reg_read(exti_base + pr) & reg_read(exti_base + imr) & 0xFFFF;
        reg_write(exti_base + pr, pending);
        for (uint p = pending; p; p &= p - 1)
            owner[bsf(p)] = _links.owner(_line_slot[bsf(p)]);
    }
    while (pending)
    {
        immutable uint line = bsf(pending);
        pending &= pending - 1;
        _links.fire(owner[line]);
    }
}
