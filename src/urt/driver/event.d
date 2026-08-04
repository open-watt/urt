// Peripheral event interconnect. Peripherals publish events and accept tasks; a
// link joins one event to one task, and every link states the minimum
// guarantee it needs from the LinkTier ladder:
//
//   interrupt   a maskable ISR performs the task. Fine for most links:
//               entry is prompt, and sampling a level (rather than an
//               edge or a slope) tolerates the jitter.
//   unmaskable  the task fires despite any critical section or wedged
//               scheduler: a true NMI, or better.
//   autonomous  the task fires without the CPU at all: a hardware
//               trigger matrix (ETM, DPPI, EVSYS).
//
// The backend lowers each link to the cheapest rung that satisfies its
// minimum, or refuses. Rungs above interrupt restrict the task
// vocabulary to immediate register writes: that is the contract the
// hardware fabric imposes, and the NMI rung is a stand-in for it, so
// both are expressed and checked the same way.
//
// Links whose minimum is interrupt are opened at runtime with link_open
// and may carry runtime state (isr_task contexts, pins from config).
// Links above that are declared in a ReflexGraph: their lowering is
// synthesized, so the graph needs the whole set with pins as
// compile-time constants (D also cannot pass function pointers as
// template values, which rules isr_task out of the graph regardless).
//
// isr_task sinks custom logic into the fabric. The handler runs in
// interrupt context and must be @isr_safe (and @critical for SRAM
// residency); it may trigger further tasks through critical-safe driver
// calls, and returns whether it woke a higher-priority task.
//
// The event source is claimed exclusively: one link (or one GpioInterrupt)
// per pin or counter, not both.
//
// Function bodies live in <soc>/event.d. Each backend exports:
//   Result link_hw_open(uint slot, EventSource, Task, LinkTier, out bool hardware);
//   void link_hw_close(uint slot);
module urt.driver.event;

import urt.driver.counter : Counter;
import urt.driver.gpio : GpioInterruptTrigger, GpioLine;
import urt.result : InternalResult, Result;

version (Espressif)
    public import urt.driver.esp32.event;
else
{
    enum uint num_links = 0;
    enum bool has_reflex = false;

    bool can_route(EventKind, TaskKind) pure nothrow @nogc => false;
}

nothrow @nogc:


enum LinkTier : ubyte
{
    interrupt,
    unmaskable,
    autonomous,
}

enum LinkContext : ubyte
{
    thread,
    interrupt,
}

alias LinkCallback = bool function(void* context, LinkContext where) nothrow @nogc;

enum EventKind : ubyte
{
    none,
    gpio_rising,
    gpio_falling,
    gpio_change,
    counter_alarm,
}

enum TaskKind : ubyte
{
    none,
    isr,
    gpio_set,
    gpio_clear,
    counter_reload,
}

struct EventSource
{
    EventKind kind;
    uint chip;              // gpio chip for gpio events, 0 otherwise
    uint index = uint.max;  // gpio line, or counter port
}

struct Task
{
    TaskKind kind;
    uint chip;
    uint index = uint.max;
    LinkCallback callback;
    void* context;      // isr tasks only; hardware routing carries no context
}

struct Link
{
    ubyte slot = ubyte.max;
    bool hardware;
}

// Level triggers are not events; high/low yield an invalid EventSource.
EventSource gpio_event(GpioLine line, GpioInterruptTrigger trigger)
{
    EventKind kind;
    final switch (trigger)
    {
        case GpioInterruptTrigger.rising:   kind = EventKind.gpio_rising;   break;
        case GpioInterruptTrigger.falling:  kind = EventKind.gpio_falling;  break;
        case GpioInterruptTrigger.change:   kind = EventKind.gpio_change;   break;
        case GpioInterruptTrigger.high:
        case GpioInterruptTrigger.low:      return EventSource();
    }
    return EventSource(kind, line.chip, line.line);
}

EventSource counter_event(ref const Counter counter)
{
    return EventSource(EventKind.counter_alarm, 0, counter.port);
}

Task gpio_task(GpioLine line, bool level)
{
    return Task(level ? TaskKind.gpio_set : TaskKind.gpio_clear, line.chip, line.line);
}

Task counter_task(ref const Counter counter)
{
    return Task(TaskKind.counter_reload, 0, counter.port);
}

Task isr_task(alias handler)(void* context = null)
    if (is(typeof(&handler) : LinkCallback))
{
    static assert(is_isr_safe!handler, "link ISR handlers must be marked @isr_safe (and @critical)");
    return Task(TaskKind.isr, 0, 0, &handler, context);
}

bool is_open(ref const Link link)
{
    return link.slot != ubyte.max;
}

bool is_hardware(ref const Link link)
{
    return link.hardware;
}

Result link_open(ref Link link, ubyte slot, EventSource event, Task task, LinkTier minimum = LinkTier.interrupt)
{
    static if (num_links == 0)
        return InternalResult.unsupported;
    else
    {
        if (link.is_open)
            return InternalResult.already_exists;
        if (slot >= num_links || event.kind == EventKind.none || event.index == uint.max ||
            task.kind == TaskKind.none || (task.kind == TaskKind.isr) != (task.callback !is null))
            return InternalResult.invalid_parameter;

        bool hardware;
        Result result = link_hw_open(slot, event, task, minimum, hardware);
        if (!result)
            return result;
        link.slot = slot;
        link.hardware = hardware;
        return Result.success;
    }
}

void link_close(ref Link link)
{
    static if (num_links != 0)
    {
        if (link.is_open)
            link_hw_close(link.slot);
    }
    link = Link();
}


// A reflex is a link whose minimum tier is above interrupt: it must act even
// when normal control flow cannot. Its tasks are restricted to immediate
// register writes and its fault domain is the executor's own resident code
// and literals. No stack, no locks, no C. The default minimum is unmaskable;
// pass LinkTier.autonomous to also refuse the NMI stand-in and demand the
// hardware fabric.
//
// The program's whole reflex set is declared in one ReflexGraph so the backend
// can synthesize a single vector handler for whatever lands on the NMI rung,
// disambiguating sources only when there is more than one. The graph provides:
//   Result open();   // claim sources and arm; call once from thread context
//   void close();
//   uint fired();    // read-and-clear latch of event pins observed to trip,
//                    // as a gpio bitmask; poll from the main loop
// One graph per program: a second instantiation collides on the vector symbol
// and fails to link.
template Reflex(EventSource ev, tasks_...)
{
    enum LinkTier tier = LinkTier.unmaskable;
    enum EventSource event = ev;
    enum Task[] tasks = [tasks_];
}

template Reflex(LinkTier minimum, EventSource ev, tasks_...)
{
    static assert(minimum > LinkTier.interrupt,
                  "interrupt-tier links carry runtime state; open them with link_open");
    enum LinkTier tier = minimum;
    enum EventSource event = ev;
    enum Task[] tasks = [tasks_];
}

template ReflexGraph(reflexes...)
    if (reflexes.length > 0)
{
    static if (!has_reflex)
    {
        Result open() { return InternalResult.unsupported; }
        void close() {}
        uint fired() { return 0; }
    }
    else
        mixin ReflexBackend!(reflexes);
}


unittest
{
    // can_route must be usable in a static assert; graph validation depends on it.
    static assert(!can_route(EventKind.none, TaskKind.none) || can_route(EventKind.none, TaskKind.none));

    // Level triggers are not edges, so they do not yield an event.
    assert(gpio_event(GpioLine(0, 4), GpioInterruptTrigger.high).kind == EventKind.none);
    assert(gpio_event(GpioLine(0, 4), GpioInterruptTrigger.rising).kind == EventKind.gpio_rising);
}


private:

enum bool is_isr_safe(alias f) = () {
    import urt.attribute : isr_safe;
    bool found;
    static foreach (attr; __traits(getAttributes, f))
        static if (__traits(isSame, attr, isr_safe))
            found = true;
    return found;
}();
