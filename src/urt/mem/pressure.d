module urt.mem.pressure;

import urt.atomic;

nothrow @nogc:

enum MaxUsagePools = 4;

void note_pool_usage(size_t pool, size_t used)
{
    atomicStore!(MemoryOrder.relaxed)(_watermarks[pool].current, used);
    _watermarks[pool].note(used);
}

// One sampler per pool. Concurrent updates can fall on either side of a sample boundary.
void sample_pool_usage(size_t pool, out size_t low, out size_t high)
{
    _watermarks[pool].sample(low, high);
}

void account_pool_usage(size_t bytes, bool freed)
{
    size_t delta = freed ? 0 - bytes : bytes;
    _watermarks[0].note(atomicFetchAdd!(MemoryOrder.relaxed)(_watermarks[0].current, delta) + delta);
}

private:

__gshared Watermark[MaxUsagePools] _watermarks;

struct Watermark
{
    nothrow @nogc:
    shared size_t current;
    shared size_t low = size_t.max;
    shared size_t high;

    void note(size_t used)
    {
        size_t old = atomicLoad!(MemoryOrder.relaxed)(low);
        while (used < old && !cas(&low, old, used))
            old = atomicLoad!(MemoryOrder.relaxed)(low);
        old = atomicLoad!(MemoryOrder.relaxed)(high);
        while (used > old && !cas(&high, old, used))
            old = atomicLoad!(MemoryOrder.relaxed)(high);
    }

    void sample(out size_t minimum, out size_t maximum)
    {
        size_t used = atomicLoad!(MemoryOrder.relaxed)(current);
        minimum = atomicExchange!(MemoryOrder.relaxed)(&low, used);
        maximum = atomicExchange!(MemoryOrder.relaxed)(&high, used);
        if (minimum > maximum)
            minimum = maximum = used;
    }
}

unittest
{
    Watermark w;
    size_t low, high;
    w.sample(low, high);
    assert(low == 0 && high == 0);
    foreach (used; [1000, 5000, 2000])
    {
        w.current = used;
        w.note(used);
    }
    w.sample(low, high);
    assert(low == 0 && high == 5000);
    w.sample(low, high);
    assert(low == 2000 && high == 2000);
    w.current = 2500;
    w.note(2500);
    w.sample(low, high);
    assert(low == 2000 && high == 2500);
}
