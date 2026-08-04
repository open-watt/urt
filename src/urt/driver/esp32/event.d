// ESP32 link backend. Classic ESP32 has no trigger matrix (ETM arrives
// with C5/C6/H2/P4): interrupt-tier links lower to a maskable ISR,
// unmaskable reflexes are synthesized onto the NMI, and the autonomous
// tier cannot be satisfied. Slot state is published with an
// acquire/release flag so the dispatcher never observes a half-written
// task.
module urt.driver.esp32.event;

import urt.atomic : MemoryOrder, atomicExchange, atomicLoad, atomicStore;
import urt.attribute : critical, naked, used;
import urt.driver.gpio : gpio_output_set;
import urt.driver.event;
import urt.result : InternalResult, Result;

nothrow @nogc:


version (ESP32)
{
    enum uint num_links = 8;
    enum bool has_reflex = true;
}
else
{
    enum uint num_links = 0;
    enum bool has_reflex = false;
}

// No trigger matrix on any Xtensa or early RISC-V Espressif part; ETM arrives
// with C5/C6/H2/P4, whose backend will answer this per event/task pair.
bool can_route(EventKind, TaskKind) pure => false;

version (ESP32):

import urt.driver.esp32.counter : num_counters;

Result link_hw_open(uint slot, EventSource event, Task task, LinkTier minimum, out bool hardware)
{
    hardware = false;
    // Runtime opens lower to a maskable ISR; rungs above that are synthesized
    // and only reachable through a ReflexGraph declaration.
    if (minimum > LinkTier.interrupt)
        return InternalResult.unsupported;
    if (event.chip != 0 || task.chip != 0)
        return InternalResult.unsupported;
    if (_slots[slot].task.kind != TaskKind.none)
        return InternalResult.already_exists;

    // The event source is claimed exclusively. The gpio ISR service keeps one
    // handler per pin and a counter has one alarm sink, so a second link on the
    // same source would silently displace the first; refuse instead.
    foreach (i, ref s; _slots)
    {
        if (i == slot || !atomicLoad!(MemoryOrder.acquire)(s.active))
            continue;
        if (is_gpio_kind(s.event.kind) && is_gpio_kind(event.kind) && s.event.index == event.index)
            return InternalResult.already_exists;
    }
    if (event.kind == EventKind.counter_alarm && event.index < num_counters && _counter_slots[event.index] != ubyte.max)
        return InternalResult.already_exists;

    _slots[slot].event = event;
    _slots[slot].task = task;
    atomicStore!(MemoryOrder.release)(_slots[slot].active, true);

    final switch (event.kind)
    {
        case EventKind.gpio_rising:
        case EventKind.gpio_falling:
        case EventKind.gpio_change:
            if (ow_link_gpio_open(slot, event.index, cast(uint)(event.kind - EventKind.gpio_rising)) != 0)
                break;
            return Result.success;

        case EventKind.counter_alarm:
            if (event.index >= _counter_slots.length)
                break;
            _counter_slots[event.index] = cast(ubyte)slot;
            ow_counter_set_callback(event.index, &link_counter_alarm);
            return Result.success;

        case EventKind.none:
            break;
    }

    atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
    _slots[slot] = LinkSlot();
    return InternalResult.failed;
}

void link_hw_close(uint slot)
{
    EventSource event = _slots[slot].event;
    final switch (event.kind)
    {
        case EventKind.gpio_rising:
        case EventKind.gpio_falling:
        case EventKind.gpio_change:
            ow_link_gpio_close(slot, event.index);
            break;

        case EventKind.counter_alarm:
            ow_counter_set_callback(event.index, null);
            _counter_slots[event.index] = ubyte.max;
            break;

        case EventKind.none:
            break;
    }
    atomicStore!(MemoryOrder.release)(_slots[slot].active, false);
    _slots[slot] = LinkSlot();
}


// -- Reflex synthesis ----------------------------------------------------
//
// Reflexes on classic ESP32 lower to the true NMI: the GPIO NMI matrix
// source routed to CPU interrupt 14 (level 7, above every maskable level;
// rsil cannot defer it). xt_nmi is weak in the IDF vector table and the
// graph's synthesized handler overrides it; a second graph collides on the
// symbol and fails to link, which is the intended budget check for the
// chip's single NMI vector. The vector saves a0 to EXCSAVE_7; the handler
// saves its scratch to MISC0-2, touches no stack, and reads no mutable
// state beyond the status latch it must acknowledge (an unacknowledged
// edge would re-enter forever). Task masks are immediates baked into the
// code; the fired latch lives in DRAM, which is never cached on this part.

extern(C) shared uint ow_reflex_fired0;

extern(C) nothrow @nogc
{
    int ow_reflex_open(uint gpio, uint trigger);
    void ow_reflex_close(uint gpio);
}

mixin template ReflexBackend(reflexes...)
{
    import urt.attribute : reflex_critical = critical, reflex_naked = naked, reflex_used = used;

    static foreach (r; reflexes)
    {
        static assert(r.tier <= LinkTier.unmaskable,
                      "no trigger matrix on classic ESP32: an autonomous reflex cannot lower here; unmaskable rides the NMI");
        static assert(r.event.kind == EventKind.gpio_rising || r.event.kind == EventKind.gpio_falling ||
                      r.event.kind == EventKind.gpio_change, "reflex events on this backend are gpio edges");
        static assert(r.event.chip == 0 && r.event.index < 32, "reflex event pins are gpio0-31");
        static foreach (t; r.tasks)
        {
            static assert(t.kind == TaskKind.gpio_set || t.kind == TaskKind.gpio_clear,
                          "reflex tasks are immediate register writes: gpio set/clear (no isr, counter, or C calls at NMI level)");
            static assert(t.chip == 0 && t.index < 40, "reflex task pins are gpio0-39");
        }
    }

    // Handler synthesis is a CTFE-only immediately-invoked literal: literals
    // infer attributes, so the string building escapes the driver-wide @nogc,
    // which only constrains runtime code.
    private enum string _nmi_asm = () {
        enum uint OUT_W1TS = 0x3FF44008, OUT_W1TC = 0x3FF4400C;
        enum uint OUT1_W1TS = 0x3FF44014, OUT1_W1TC = 0x3FF44018;
        enum uint STATUS_W1TC = 0x3FF4404C, PCPU_NMI_INT = 0x3FF4406C;
        enum bool multi = reflexes.length > 1;

        string dec(uint value)
        {
            string s;
            do
            {
                char digit = '0' + value % 10;
                s = digit ~ s;
                value /= 10;
            }
            while (value);
            return s;
        }

        string write(uint reg, uint mask)
            => "movi a2, " ~ dec(reg) ~ "\nmovi a3, " ~ dec(mask) ~ "\ns32i a3, a2, 0\n";

        // Special-register moves as raw encodings: the fork's function-level
        // inline-asm parser rejects every feature-gated SR mnemonic (module
        // asm accepts them), so wsr/rsr are emitted as data. Byte layout is
        // t<<4, sr, opcode with wsr = 0x13 and rsr = 0x03, verified by
        // round-tripping through the GNU assembler.
        string sr_op(uint opcode, uint t, uint sr)
            => ".byte " ~ dec(t << 4) ~ ", " ~ dec(sr) ~ ", " ~ dec(opcode) ~ "\n";
        enum uint WSR = 0x13, RSR = 0x03;
        enum uint MISC0 = 244, MISC1 = 245, MISC2 = 246, EXCSAVE7 = 215;

        string s = ".literal_position\n"
                 ~ sr_op(WSR, 2, MISC0) ~ sr_op(WSR, 3, MISC1) ~ sr_op(WSR, 4, MISC2);
        uint all_events;
        static if (multi)
            s ~= "movi a2, " ~ dec(PCPU_NMI_INT) ~ "\nl32i a4, a2, 0\n";
        static foreach (r; reflexes)
        {{
            uint set0, clr0, set1, clr1;
            foreach (t; r.tasks)
            {
                if (t.index < 32)
                {
                    if (t.kind == TaskKind.gpio_set) set0 |= 1u << t.index;
                    else clr0 |= 1u << t.index;
                }
                else
                {
                    if (t.kind == TaskKind.gpio_set) set1 |= 1u << (t.index - 32);
                    else clr1 |= 1u << (t.index - 32);
                }
            }
            all_events |= 1u << r.event.index;
            static if (multi)
                s ~= "bbci a4, " ~ dec(r.event.index) ~ ", 1f\n";
            if (clr0) s ~= write(OUT_W1TC, clr0);
            if (set0) s ~= write(OUT_W1TS, set0);
            if (clr1) s ~= write(OUT1_W1TC, clr1);
            if (set1) s ~= write(OUT1_W1TS, set1);
            static if (multi)
                s ~= "1:\n";
        }}

        // Latch what fired for the main loop, then acknowledge the edge.
        s ~= "movi a2, ow_reflex_fired0\nl32i a3, a2, 0\n";
        static if (multi)
            s ~= "or a3, a3, a4\ns32i a3, a2, 0\n" ~
                 "movi a2, " ~ dec(STATUS_W1TC) ~ "\ns32i a4, a2, 0\n";
        else
            s ~= "movi a4, " ~ dec(all_events) ~ "\nor a3, a3, a4\ns32i a3, a2, 0\n" ~
                 "movi a2, " ~ dec(STATUS_W1TC) ~ "\nmovi a3, " ~ dec(all_events) ~ "\ns32i a3, a2, 0\n";
        s ~= "memw\n"
           ~ sr_op(RSR, 4, MISC2) ~ sr_op(RSR, 3, MISC1) ~ sr_op(RSR, 2, MISC0) ~ sr_op(RSR, 0, EXCSAVE7)
           ~ "rfi 7\n";
        return s;
    }();

    // pragma(mangle) rather than relying on extern(C): inside a template
    // instantiation extern(C) keeps D mangling, and the vector override
    // only works if the symbol is literally xt_nmi.
    pragma(mangle, "xt_nmi")
    @reflex_used @reflex_naked @reflex_critical extern(C) void xt_nmi()
    {
        import ldc.llvmasm : __asm;
        __asm(_nmi_asm, "");
    }

    Result open()
    {
        static foreach (r; reflexes)
        {
            if (ow_reflex_open(r.event.index, r.event.kind - EventKind.gpio_rising) != 0)
            {
                close();
                return InternalResult.failed;
            }
        }
        return Result.success;
    }

    void close()
    {
        static foreach (r; reflexes)
            ow_reflex_close(r.event.index);
    }

    uint fired()
    {
        import urt.atomic : atomicExchange;
        return atomicExchange(&ow_reflex_fired0, 0u);
    }
}


private:

bool is_gpio_kind(EventKind kind)
{
    return kind >= EventKind.gpio_rising && kind <= EventKind.gpio_change;
}

struct LinkSlot
{
    EventSource event;
    Task task;
    shared bool active;
}

__gshared LinkSlot[num_links] _slots;
__gshared ubyte[num_counters] _counter_slots = ubyte.max;

@critical extern(C) bool ow_link_fire(uint slot)
{
    if (slot >= num_links || !atomicLoad!(MemoryOrder.acquire)(_slots[slot].active))
        return false;
    Task* task = &_slots[slot].task;
    final switch (task.kind)
    {
        case TaskKind.isr:
            return task.callback(task.context, LinkContext.interrupt);
        case TaskKind.gpio_set:
            gpio_output_set(task.index, true);
            return false;
        case TaskKind.gpio_clear:
            gpio_output_set(task.index, false);
            return false;
        case TaskKind.counter_reload:
            ow_counter_reload(task.index);
            return false;
        case TaskKind.none:
            return false;
    }
}

@critical extern(C) bool link_counter_alarm(uint port)
{
    if (port >= _counter_slots.length)
        return false;
    ubyte slot = _counter_slots[port];
    return slot != ubyte.max ? ow_link_fire(slot) : false;
}

extern(C) nothrow @nogc
{
    int ow_link_gpio_open(uint slot, uint gpio, uint trigger);
    void ow_link_gpio_close(uint slot, uint gpio);
    void ow_counter_set_callback(uint port, bool function(uint port) nothrow @nogc callback);
    void ow_counter_reload(uint port);
}
