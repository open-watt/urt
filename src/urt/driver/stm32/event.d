// STM32 link backend. There is no trigger matrix a link can use, so only the interrupt tier exists: a GPIO
// edge arms the EXTI line of its pin number, and each line takes its pin from one port at a time.
module urt.driver.stm32.event;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.driver.event;
import urt.driver.irq : irq_handler_set, irq_line_enable;
import urt.driver.stm32 : clock_enable, reg_read, reg_rmw, reg_write;
import urt.driver.stm32.gpio : gpio_output_set, num_gpio;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum uint num_links = 8;
enum bool has_reflex = false;

bool can_route(EventKind, TaskKind) pure
    => false;

Result link_hw_open(uint slot, EventSource event, Task task, LinkTier minimum, out bool hardware)
{
    hardware = false;
    if (minimum > LinkTier.interrupt || event.chip != 0 || task.chip != 0 || task.kind == TaskKind.counter_reload)
        return InternalResult.unsupported;
    if (atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return InternalResult.already_exists;
    if (event.kind != EventKind.gpio_rising && event.kind != EventKind.gpio_falling && event.kind != EventKind.gpio_change)
        return InternalResult.unsupported;
    if (event.index >= num_gpio || ((task.kind == TaskKind.gpio_set || task.kind == TaskKind.gpio_clear) && task.index >= num_gpio))
        return InternalResult.invalid_parameter;

    immutable uint line = event.index & 15;
    if (_line_slot[line] != no_slot)
        return InternalResult.failed;

    _slots[slot].event = event;
    _slots[slot].task = task;
    atomicStore!(MemoryOrder.release)(_slots[slot].active, true);
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
    return Result.success;
}

// The NVIC line stays enabled, since lines 5-9 and 10-15 share one; a masked EXTI line never pends.
void link_hw_close(uint slot)
{
    if (!atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return;
    immutable uint line = _slots[slot].event.index & 15;
    immutable uint bit = 1u << line;
    reg_rmw(exti_base + imr, bit, 0);
    reg_rmw(exti_base + rtsr, bit, 0);
    reg_rmw(exti_base + ftsr, bit, 0);
    reg_write(exti_base + pr, bit);
    _line_slot[line] = no_slot;
    atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
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
enum ubyte no_slot = 0xFF;

static immutable ubyte[16] line_irq = [ 6, 7, 8, 9, 10, 23, 23, 23, 23, 23, 40, 40, 40, 40, 40, 40 ];

struct LinkSlot
{
    EventSource event;
    Task task;
    shared bool active;
}

__gshared LinkSlot[num_links] _slots;
__gshared ubyte[16] _line_slot = no_slot;

// Every EXTI vector lands here: a shared one serves several lines, so the pending mask says which fired.
void exti_isr(uint)
{
    import urt.internal.bitop : bsf;

    uint pending = reg_read(exti_base + pr) & reg_read(exti_base + imr) & 0xFFFF;
    reg_write(exti_base + pr, pending);
    while (pending)
    {
        immutable uint line = bsf(pending);
        pending &= pending - 1;
        immutable ubyte slot = _line_slot[line];
        if (slot != no_slot)
            fire(slot);
    }
}

void fire(uint slot)
{
    if (!atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return;
    ref task = _slots[slot].task;
    switch (task.kind)
    {
        case TaskKind.isr:
            task.callback(task.context, LinkContext.interrupt);
            break;
        case TaskKind.gpio_set:
        case TaskKind.gpio_clear:
            gpio_output_set(task.index, task.kind == TaskKind.gpio_set);
            break;
        default:
            break;
    }
}
