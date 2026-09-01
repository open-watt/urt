// Free-running peripheral counter with a programmable alarm, allocated by
// port number. Distinct from urt.driver.timer, which owns the system
// timebase; counters are for realtime sequencing (sample scheduling,
// edge-relative delays). Alarm delivery is not a portable callback API;
// alarms are consumed as events by whoever wires the backend's sink.
//
// Function bodies live in <soc>/counter.d. Each backend exports:
//   Result counter_hw_open(uint port, ref const CounterConfig);
//   Result counter_hw_arm(uint port, ulong ticks, bool periodic);
//   void counter_hw_reload(uint port);
//   void counter_hw_rearm(uint port, ulong ticks);
//   ulong counter_hw_read(uint port);
//   void counter_hw_close(uint port);
module urt.driver.counter;

import urt.attribute : critical;
import urt.result : InternalResult, Result;

version (Espressif)
    public import urt.driver.esp32.counter;
else
    enum uint num_counters = 0;

nothrow @nogc:


struct CounterConfig
{
    uint resolution_hz = 1_000_000;
}

struct Counter
{
    ubyte port = ubyte.max;
}

bool is_open(ref const Counter counter)
{
    return counter.port != ubyte.max;
}

Result counter_open(ref Counter counter, ubyte port, ref const CounterConfig config)
{
    static if (num_counters == 0)
        return InternalResult.unsupported;
    else
    {
        if (counter.is_open)
            return InternalResult.already_exists;
        if (port >= num_counters || config.resolution_hz == 0)
            return InternalResult.invalid_parameter;
        Result result = counter_hw_open(port, config);
        if (!result)
            return result;
        counter.port = port;
        return Result.success;
    }
}

// Open on any free port, scanning downward so fixed low-port claims stay clear.
Result counter_acquire(ref Counter counter, ref const CounterConfig config)
{
    static if (num_counters == 0)
        return InternalResult.unsupported;
    else
    {
        if (counter.is_open)
            return InternalResult.already_exists;
        foreach_reverse (port; 0 .. num_counters)
        {
            if (counter_open(counter, cast(ubyte)port, config))
                return Result.success;
        }
        return InternalResult.failed;
    }
}

// Alarm after ticks counts from zero. Periodic alarms self-rearm; a one-shot
// alarm fires once and is rearmed by reload().
Result counter_arm(ref Counter counter, ulong ticks, bool periodic)
{
    static if (num_counters == 0)
        return InternalResult.unsupported;
    else
    {
        if (!counter.is_open || ticks == 0)
            return InternalResult.invalid_parameter;
        return counter_hw_arm(counter.port, ticks, periodic);
    }
}

// Zero the count and rearm the armed alarm. Safe from interrupt context.
@critical void counter_reload(ref Counter counter)
{
    static if (num_counters != 0)
    {
        if (counter.is_open)
            counter_hw_reload(counter.port);
    }
}

// Replace the alarm tick count, zero the count, and rearm. Safe from interrupt context.
@critical void counter_rearm(ref Counter counter, ulong ticks)
{
    static if (num_counters != 0)
    {
        if (counter.is_open && ticks)
            counter_hw_rearm(counter.port, ticks);
    }
}

@critical ulong counter_read(ref Counter counter)
{
    static if (num_counters == 0)
        return 0;
    else
        return counter.is_open ? counter_hw_read(counter.port) : 0;
}

void counter_close(ref Counter counter)
{
    static if (num_counters != 0)
    {
        if (counter.is_open)
            counter_hw_close(counter.port);
    }
    counter = Counter();
}
