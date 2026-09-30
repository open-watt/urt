// RP2350 link backend. The interrupt tier only: a GPIO edge enables its pin's edge bits in IO_BANK0's core 0
// interrupt set, and IO_IRQ_BANK0 fires the link of each pin whose edge latched.
module urt.driver.rp2350.event;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.driver.event;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_enable;
import urt.driver.rp2350 : io_bank0_base, mmio_read, mmio_write, pad_input_enable;
import urt.driver.rp2350.gpio : gpio_output_set, num_gpio;
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
    if (event.kind != EventKind.gpio_rising && event.kind != EventKind.gpio_falling && event.kind != EventKind.gpio_change)
        return InternalResult.unsupported;
    if (event.index >= num_gpio || ((task.kind == TaskKind.gpio_set || task.kind == TaskKind.gpio_clear) && task.index >= num_gpio))
        return InternalResult.invalid_parameter;

    // a callback may open or close a link from the ISR
    auto guard = irq_critical();
    if (atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return InternalResult.already_exists;
    if (_pin_slot[event.index] != no_slot)
        return InternalResult.failed;

    _slots[slot].event = event;
    _slots[slot].task = task;
    ++_slots[slot].generation;
    atomicStore!(MemoryOrder.release)(_slots[slot].active, true);
    _pin_slot[event.index] = cast(ubyte)slot;

    pad_input_enable(event.index);
    immutable uint edges = (event.kind != EventKind.gpio_rising ? edge_low : 0) | (event.kind != EventKind.gpio_falling ? edge_high : 0);
    immutable uint shift = (event.index & 7) * 4;
    mmio_write(io_bank0_base + intr + reg_of(event.index), (edge_low | edge_high) << shift);
    mmio_write(io_bank0_base + proc0_inte + reg_of(event.index) + alias_set, edges << shift);
    irq_handler_set(io_irq_bank0, &bank0_isr);
    irq_line_enable(io_irq_bank0);
    return Result.success;
}

// The NVIC line serves every pin, so it stays enabled; a pin with no enable bits never raises it.
void link_hw_close(uint slot)
{
    auto guard = irq_critical();
    if (!atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return;
    immutable uint pin = _slots[slot].event.index;
    immutable uint shift = (pin & 7) * 4;
    mmio_write(io_bank0_base + proc0_inte + reg_of(pin) + alias_clr, (edge_low | edge_high) << shift);
    mmio_write(io_bank0_base + intr + reg_of(pin), (edge_low | edge_high) << shift);
    _pin_slot[pin] = no_slot;
    atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
}


private:

enum uint io_irq_bank0 = 21;

enum uint intr       = 0x230;
enum uint proc0_inte = 0x248;
enum uint proc0_ints = 0x278;
enum uint alias_set  = 0x2000;
enum uint alias_clr  = 0x3000;
enum uint edge_low   = 1 << 2;
enum uint edge_high  = 1 << 3;
enum ubyte no_slot   = 0xFF;

struct LinkSlot
{
    EventSource event;
    Task task;
    shared bool active;
    ubyte generation;
}

__gshared LinkSlot[num_links] _slots;
__gshared ubyte[num_gpio] _pin_slot = no_slot;

// Eight pins a register, four bits a pin.
uint reg_of(uint pin) pure
    => (pin >> 3) * 4;

void bank0_isr(uint)
{
    import urt.internal.bitop : bsf;

    foreach (r; 0 .. (num_gpio + 7) / 8)
    {
        uint pending;
        Owner[8] owner = void;
        {
            // an edge belongs to the link that owned its pin when it was taken, not to one opened since
            auto guard = irq_critical();
            pending = mmio_read(io_bank0_base + proc0_ints + r * 4) & 0xCCCC_CCCC;
            mmio_write(io_bank0_base + intr + r * 4, pending);
            for (uint p = pending; p; p &= ~(0xFu << bsf(p) / 4 * 4))
                owner[bsf(p) / 4] = owner_of(_pin_slot[r * 8 + bsf(p) / 4]);
        }
        while (pending)
        {
            immutable uint i = bsf(pending) / 4;
            pending &= ~(0xFu << i * 4);
            fire(owner[i]);
        }
    }
}

struct Owner
{
    ubyte slot;
    ubyte generation;
}

Owner owner_of(ubyte slot)
    => Owner(slot, slot != no_slot ? _slots[slot].generation : 0);

// held through the task, so a higher-priority interrupt cannot replace the link between the check and the call
void fire(Owner owner)
{
    auto guard = irq_critical();
    if (owner.slot == no_slot || !atomicLoad!(MemoryOrder.acquire)(_slots[owner.slot].active) || _slots[owner.slot].generation != owner.generation)
        return;
    immutable uint slot = owner.slot;
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
