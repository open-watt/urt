// The request checks, slot ownership and task dispatch every interrupt-tier link backend shares. An ISR that dispatches
// outside the critical section that took an edge fires the owner it recorded there, so a newer link never takes it.
module urt.driver.event_core;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.driver.event : EventKind, EventSource, LinkCallback, LinkContext, LinkTier, Task, TaskKind;
import urt.driver.gpio : GpioInterruptTrigger;
import urt.driver.irq : irq_critical;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum ubyte no_link = 0xFF;

struct LinkOwner
{
    ubyte slot = no_link;
    ubyte generation;
}

// GPIO edges into ISR or GPIO tasks, at the interrupt tier: all a backend without a trigger matrix can take.
Result gpio_link_check(EventSource event, Task task, LinkTier minimum, uint num_gpio) pure
{
    if (minimum > LinkTier.interrupt || event.chip != 0 || task.chip != 0 || task.kind == TaskKind.counter_reload)
        return InternalResult.unsupported;
    if (event.kind != EventKind.gpio_rising && event.kind != EventKind.gpio_falling && event.kind != EventKind.gpio_change)
        return InternalResult.unsupported;
    if (event.index >= num_gpio || event.index > ubyte.max)
        return InternalResult.invalid_parameter;
    if ((task.kind == TaskKind.gpio_set || task.kind == TaskKind.gpio_clear) && (task.index >= num_gpio || task.index > ubyte.max))
        return InternalResult.invalid_parameter;
    return Result.success;
}

// The pin trigger of a checked GPIO edge.
GpioInterruptTrigger gpio_link_trigger(EventKind kind) pure
{
    static immutable GpioInterruptTrigger[3] trigger = [ GpioInterruptTrigger.rising, GpioInterruptTrigger.falling, GpioInterruptTrigger.change ];
    static assert(EventKind.gpio_falling == EventKind.gpio_rising + 1 && EventKind.gpio_change == EventKind.gpio_rising + 2);
    return trigger[kind - EventKind.gpio_rising];
}

struct EventLinks(uint count, alias gpio_set)
{
nothrow @nogc:

    bool active(uint slot) const
        => atomicLoad!(MemoryOrder.acquire)(_slots[slot].active);

    uint pin(uint slot) const
        => _slots[slot].pin;

    // Caller holds interrupts off, and has checked the slot is free.
    void claim(uint slot, EventSource event, Task task)
    {
        _slots[slot].callback = task.callback;
        _slots[slot].context = task.context;
        _slots[slot].kind = task.kind;
        _slots[slot].target = cast(ubyte)task.index;
        _slots[slot].pin = cast(ubyte)event.index;
        ++_slots[slot].generation;
        atomicStore!(MemoryOrder.release)(_slots[slot].active, true);
    }

    // Caller holds interrupts off.
    void release(uint slot)
    {
        atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
    }

    LinkOwner owner(ubyte slot) const
        => LinkOwner(slot, slot != no_link ? _slots[slot].generation : 0);

    // held through the task, so a higher-priority interrupt cannot replace the link between the check and the call
    bool fire(LinkOwner owner)
    {
        auto guard = irq_critical();
        if (owner.slot == no_link || !active(owner.slot) || _slots[owner.slot].generation != owner.generation)
            return false;
        ref s = _slots[owner.slot];
        switch (s.kind)
        {
            case TaskKind.isr:
                return s.callback(s.context, LinkContext.interrupt);
            case TaskKind.gpio_set:
            case TaskKind.gpio_clear:
                gpio_set(s.target, s.kind == TaskKind.gpio_set);
                return false;
            default:
                return false;
        }
    }

private:
    // A GPIO task's pin is its target; an ISR task's callback and context are its own.
    struct LinkSlot
    {
        LinkCallback callback;
        void* context;
        TaskKind kind;
        ubyte target;
        ubyte pin;
        shared bool active;
        ubyte generation;
    }

    LinkSlot[count] _slots;
}


unittest
{
    static struct Model
    {
        static __gshared EventLinks!(2, set) links;
        static __gshared uint sets, isrs;
        static __gshared bool level;

    nothrow @nogc:
        static void set(uint pin, bool value)
        {
            assert(pin == 7);
            ++sets;
            level = value;
        }

        static bool isr(void* context, LinkContext where)
        {
            assert(context == &isrs && where == LinkContext.interrupt);
            ++isrs;
            return true;
        }
    }
    alias links = Model.links;

    auto edge = EventSource(EventKind.gpio_rising, 0, 3);
    auto set_task = Task(TaskKind.gpio_set, 0, 7);
    assert(gpio_link_check(edge, set_task, LinkTier.interrupt, 16), "a GPIO edge into a GPIO task is routable");
    assert(gpio_link_check(edge, set_task, LinkTier.unmaskable, 16) == InternalResult.unsupported, "nothing above the interrupt tier");
    assert(gpio_link_check(EventSource(EventKind.counter_alarm, 0, 0), set_task, LinkTier.interrupt, 16) == InternalResult.unsupported, "only GPIO edges");
    assert(gpio_link_check(edge, Task(TaskKind.counter_reload, 0, 0), LinkTier.interrupt, 16) == InternalResult.unsupported, "no counter tasks");
    assert(gpio_link_check(EventSource(EventKind.gpio_change, 1, 3), set_task, LinkTier.interrupt, 16) == InternalResult.unsupported, "chip 0 only");
    assert(gpio_link_check(EventSource(EventKind.gpio_falling, 0, 16), set_task, LinkTier.interrupt, 16) == InternalResult.invalid_parameter, "an event pin past the bank");
    assert(gpio_link_check(edge, Task(TaskKind.gpio_clear, 0, 16), LinkTier.interrupt, 16) == InternalResult.invalid_parameter, "a task pin past the bank");

    assert(!links.active(0) && !links.fire(LinkOwner()) && !links.fire(links.owner(no_link)), "no owner fires nothing");

    links.claim(0, edge, set_task);
    assert(links.active(0) && links.pin(0) == 3);
    auto taken = links.owner(0);
    assert(!links.fire(taken) && Model.sets == 1 && Model.level, "a GPIO task drives its pin");

    links.release(0);
    assert(!links.fire(taken) && Model.sets == 1, "a closed link does not fire");

    links.claim(0, edge, Task(TaskKind.isr, 0, 0, &Model.isr, &Model.isrs));
    assert(!links.fire(taken) && Model.isrs == 0, "an edge taken before a reopen does not reach the new link");
    assert(links.fire(links.owner(0)) && Model.isrs == 1, "an ISR task runs and its wake reaches the caller");
    links.release(0);
}
