// RP2350 link backend. The interrupt tier only: a GPIO edge enables its pin's edge bits in IO_BANK0's core 0
// interrupt set, and IO_IRQ_BANK0 fires the link of each pin whose edge latched.
module urt.driver.rp2350.event;

import urt.driver.event;
import urt.driver.event_core : EventLinks, LinkOwner, gpio_link_check, no_link;
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
    Result result = gpio_link_check(event, task, minimum, num_gpio);
    if (!result)
        return result;

    // a callback may open or close a link from the ISR
    auto guard = irq_critical();
    if (_links.active(slot))
        return InternalResult.already_exists;
    if (_pin_slot[event.index] != no_link)
        return InternalResult.failed;

    _links.claim(slot, event, task);
    _pin_slot[event.index] = cast(ubyte)slot;

    pad_input_enable(event.index);
    immutable uint edges = (event.kind != EventKind.gpio_rising ? edge_low : 0) | (event.kind != EventKind.gpio_falling ? edge_high : 0);
    immutable uint shift = (event.index & 7) * 4;
    mmio_write(io_bank0_base + intr + reg_of(event.index), (edge_low | edge_high) << shift);
    mmio_write(io_bank0_base + proc0_inte + reg_of(event.index) + alias_set, edges << shift);
    irq_handler_set(io_irq_bank0, &bank0_isr);
    irq_line_enable(io_irq_bank0);
    return result;
}

// The NVIC line serves every pin, so it stays enabled; a pin with no enable bits never raises it.
void link_hw_close(uint slot)
{
    auto guard = irq_critical();
    if (!_links.active(slot))
        return;
    immutable uint pin = _links.pin(slot);
    immutable uint shift = (pin & 7) * 4;
    mmio_write(io_bank0_base + proc0_inte + reg_of(pin) + alias_clr, (edge_low | edge_high) << shift);
    mmio_write(io_bank0_base + intr + reg_of(pin), (edge_low | edge_high) << shift);
    _pin_slot[pin] = no_link;
    _links.release(slot);
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

__gshared EventLinks!(num_links, gpio_output_set) _links;
__gshared ubyte[num_gpio] _pin_slot = no_link;

// Eight pins a register, four bits a pin.
uint reg_of(uint pin) pure
    => (pin >> 3) * 4;

void bank0_isr(uint)
{
    import urt.internal.bitop : bsf;

    foreach (r; 0 .. (num_gpio + 7) / 8)
    {
        uint pending;
        LinkOwner[8] owner = void;
        {
            // an edge belongs to the link that owned its pin when it was taken, not to one opened since
            auto guard = irq_critical();
            pending = mmio_read(io_bank0_base + proc0_ints + r * 4) & 0xCCCC_CCCC;
            mmio_write(io_bank0_base + intr + r * 4, pending);
            for (uint p = pending; p; p &= ~(0xFu << bsf(p) / 4 * 4))
                owner[bsf(p) / 4] = _links.owner(_pin_slot[r * 8 + bsf(p) / 4]);
        }
        while (pending)
        {
            immutable uint i = bsf(pending) / 4;
            pending &= ~(0xFu << i * 4);
            _links.fire(owner[i]);
        }
    }
}
