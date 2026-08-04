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

ulong counter_read(ref Counter counter)
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
