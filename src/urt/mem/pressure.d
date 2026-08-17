module urt.mem.pressure;

import urt.atomic;

nothrow @nogc:


// Per-pool interval watermarks. Every alloc and free nudges its pool's pair, and a sampler reads
// the pair and re-arms both to the pool's latest usage. An interval therefore reports the
// extremes reached between two samples rather than the level at the sample instant, which is
// what makes a transient spike or a creeping floor visible to a reader sampling once a second.
// One sampler per pool: a second reader steals the first's interval. Note and sample race only
// against each other's precision, and a lost update costs one sample of resolution, which is not
// worth a CAS loop on the allocation path.

enum MaxUsagePools = 4;

void note_pool_usage(size_t pool, size_t used)
{
    Watermark* w = &_watermarks[pool];
    atomicStore(w.current, used);
    if (used < atomicLoad(w.low))
        atomicStore(w.low, used);
    if (used > atomicLoad(w.high))
        atomicStore(w.high, used);
}

void sample_pool_usage(size_t pool, out size_t low, out size_t high)
{
    Watermark* w = &_watermarks[pool];
    size_t current = atomicLoad(w.current);
    low = atomicLoad(w.low);
    high = atomicLoad(w.high);
    atomicStore(w.low, current);
    atomicStore(w.high, current);
    if (low > high)     // untouched since the last sample, or never tracked at all
        low = high = current;
}

// Allocators that cannot say which pool a block came from feed the whole heap through here as
// pool 0. The running total lives here because on those platforms nothing else is counting it.
void account_pool_alloc(size_t bytes)
{
    note_pool_usage(0, atomicFetchAdd(_untracked_used, bytes) + bytes);
}

void account_pool_free(size_t bytes)
{
    note_pool_usage(0, atomicFetchSub(_untracked_used, bytes) - bytes);
}


private:

struct Watermark
{
    shared size_t current;
    shared size_t low = size_t.max;
    shared size_t high;
}

__gshared Watermark[MaxUsagePools] _watermarks;
shared size_t _untracked_used;


unittest
{
    // pools 2 and 3 are above what any allocator tracks, so nothing else can drift them
    size_t low, high;
    note_pool_usage(3, 1000);
    note_pool_usage(3, 5000);
    note_pool_usage(3, 2000);
    sample_pool_usage(3, low, high);
    assert(low == 1000 && high == 5000);

    // an interval with nothing in it collapses onto the last level rather than reporting the
    // previous window again
    sample_pool_usage(3, low, high);
    assert(low == 2000 && high == 2000);

    note_pool_usage(3, 2500);
    sample_pool_usage(3, low, high);
    assert(low == 2000 && high == 2500);

    // a pool the allocator never notes reads as zero, not as the arming sentinel
    sample_pool_usage(2, low, high);
    assert(low == 0 && high == 0);
}
