/**
 * Allocation tracking for leak detection.
 *
 * Enabled with `version = AllocTracking;`. When enabled, the central
 * allocator (`urt.mem.alloc`) calls into this module on every
 * alloc/realloc/free to record the caller's stack trace in a fixed-size
 * open-addressed hash table keyed on pointer.
 *
 * The table uses static `__gshared` storage (no allocation of its own,
 * which would recurse) and is NOT thread-safe.
 *
 * Typical workflow:
 *   1. Boot the system, let all startup/immortal allocations settle.
 *   2. Call `alloc_mark_baseline()` (via the console command
 *      `/system/alloc/mark`).
 *   3. After running for a while, call `alloc_print_leaks(min_age, sink)`
 *      to see allocations made after the baseline that have been alive
 *      for at least `min_age`, grouped by call site.
 */
module urt.mem.tracking;

version (AllocTracking):

import urt.time : MonoTime, getTime, Duration;
import urt.internal.exception : capture_trace, resolve_address, resolve_batch, Resolved;

nothrow @nogc:


// Tuning

// Number of stack frames captured per allocation.
enum trace_depth = 6;

// Maximum live allocations tracked.
// ~80 bytes per entry on 64-bit: 16384 * 80 = 1.25 MiB.
enum track_capacity = 16384;
static assert((track_capacity & (track_capacity - 1)) == 0, "track_capacity must be a power of two");

// Load factor ceiling (num/den). Linear probing degrades past ~70%.
enum track_max_load_num = 7;
enum track_max_load_den = 10;

// Max unique call sites shown in a grouped leak dump.
enum max_groups = 256;


// Entry / storage

struct Entry
{
    void*               ptr;    // null = empty, (void*)1 = tombstone
    uint                size;
    uint                serial;
    MonoTime            time;
    void*[trace_depth]  pcs;
}

__gshared Entry[track_capacity]   _table;
__gshared uint                    _live_count;
__gshared uint                    _serial_counter;
__gshared uint                    _baseline_serial;
__gshared ulong                   _tracked_bytes;
__gshared bool                    _table_full_warned;


// Tracking API -- called by urt.mem.alloc hooks

void track_alloc(void* ptr, size_t size)
{
    if (ptr is null)
        return;

    // Refuse inserts past the load factor -- linear probing gets pathological.
    if (_live_count * track_max_load_den >= track_capacity * track_max_load_num)
    {
        warn_table_full();
        return;
    }

    size_t slot = find_insert(ptr);
    if (slot == size_t.max)
    {
        warn_table_full();
        return;
    }

    bool was_live = _table[slot].ptr !is null && _table[slot].ptr !is tombstone;
    if (was_live)
        _tracked_bytes -= _table[slot].size;
    else
        _live_count++;

    _table[slot].ptr = ptr;
    _table[slot].size = cast(uint) size;
    _table[slot].serial = ++_serial_counter;
    _table[slot].time = getTime();
    _table[slot].pcs[] = null;
    capture_trace(_table[slot].pcs[]);

    _tracked_bytes += size;
}

void untrack_alloc(void* ptr)
{
    if (ptr is null)
        return;
    size_t slot = find(ptr);
    if (slot == size_t.max)
        return;
    _tracked_bytes -= _table[slot].size;
    _table[slot].ptr = tombstone;
    _table[slot].size = 0;
    _live_count--;
}

void track_realloc(void* old_ptr, void* new_ptr, size_t new_size)
{
    if (old_ptr is new_ptr)
    {
        if (new_ptr is null)
            return;
        size_t slot = find(new_ptr);
        if (slot != size_t.max)
        {
            _tracked_bytes = _tracked_bytes - _table[slot].size + new_size;
            _table[slot].size = cast(uint) new_size;
            // Keep original serial/time/trace -- the allocation's identity hasn't changed.
        }
        else
            track_alloc(new_ptr, new_size);
        return;
    }
    untrack_alloc(old_ptr);
    track_alloc(new_ptr, new_size);
}


// Baseline / stats

void alloc_mark_baseline()
{
    _baseline_serial = _serial_counter;
}

uint alloc_baseline() => _baseline_serial;

void alloc_stats(out uint live_count, out ulong live_bytes, out uint capacity, out uint total_serial)
{
    live_count = _live_count;
    live_bytes = _tracked_bytes;
    capacity = track_capacity;
    total_serial = _serial_counter;
}


// Report helpers

// Return the first frame in `pcs` whose resolved symbol is NOT a known
// allocator wrapper. Falls back to the last non-null frame if every
// frame resolves to a wrapper.
void* top_user_pc(const(void*)[] pcs)
{
    void* fallback = null;
    foreach (addr; pcs)
    {
        if (addr is null)
            continue;
        fallback = cast(void*) addr;

        Resolved r;
        if (!resolve_address(cast(void*) addr, r))
            return cast(void*) addr;  // unresolved -> assume user code
        if (!is_wrapper_name(r.name))
            return cast(void*) addr;
    }
    return fallback;
}

alias Sink = void delegate(const(char)[]) nothrow @nogc;

// Sink-based stats dump. One sink call per line, no trailing newline.
void alloc_print_stats(scope Sink sink)
{
    import urt.mem.temp : tformat;

    sink(tformat("Live allocations: {0}", _live_count));
    sink(tformat("Live bytes:       {0}", _tracked_bytes));
    sink(tformat("Table capacity:   {0}", cast(uint) track_capacity));
    sink(tformat("Total allocs:     {0} (serial)", _serial_counter));
    sink(tformat("Baseline:         {0}", _baseline_serial));
    if (_table_full_warned)
        sink("WARNING: tracking table has overflowed at least once -- some allocations untracked");
}

// Grouped leak dump. Shows allocations with `serial > baseline` that
// have been alive at least `min_age`, grouped by top-user PC.
void alloc_print_leaks(Duration min_age, scope Sink sink)
{
    print_candidates(_baseline_serial, min_age, "Leak candidates", sink);
}

// Grouped dump of every currently-live allocation, ignoring baseline
// and age. Intended for shutdown/exit leak reports -- at shutdown
// anything still alive is effectively a leak.
void alloc_print_live(scope Sink sink)
{
    print_candidates(0, Duration.init, "Live allocations", sink);
}

private void print_candidates(uint min_serial, Duration min_age, string kind, scope Sink sink)
{
    import urt.mem.temp : tformat;

    struct Site
    {
        void*       pc;
        uint        count;
        ulong       bytes;
        MonoTime    oldest;
    }

    Site[max_groups] groups = void;
    size_t ngroups = 0;
    Site overflow;
    overflow.pc = null;
    overflow.count = 0;
    overflow.bytes = 0;

    MonoTime now = getTime();

    uint total_count = 0;
    ulong total_bytes = 0;

    foreach (ref e; _table)
    {
        if (e.ptr is null || e.ptr is tombstone)
            continue;
        if (e.serial <= min_serial)
            continue;
        if (now - e.time < min_age)
            continue;

        void* top = top_user_pc(e.pcs[]);

        size_t g = size_t.max;
        foreach (i; 0 .. ngroups)
            if (groups[i].pc is top) { g = i; break; }

        Site* s;
        if (g == size_t.max)
        {
            if (ngroups < max_groups)
            {
                groups[ngroups].pc = top;
                groups[ngroups].count = 0;
                groups[ngroups].bytes = 0;
                groups[ngroups].oldest = e.time;
                s = &groups[ngroups];
                ngroups++;
            }
            else
                s = &overflow;
        }
        else
            s = &groups[g];

        s.count++;
        s.bytes += e.size;
        if (e.time < s.oldest || s.oldest == MonoTime())
            s.oldest = e.time;

        total_count++;
        total_bytes += e.size;
    }

    if (total_count == 0)
    {
        sink(tformat("{0}: none (min serial {1}, min age {2})", kind, min_serial, min_age));
        return;
    }

    // Sort by bytes descending -- insertion sort, ngroups is small.
    foreach (i; 1 .. ngroups)
    {
        Site tmp = groups[i];
        size_t j = i;
        while (j > 0 && groups[j - 1].bytes < tmp.bytes)
        {
            groups[j] = groups[j - 1];
            --j;
        }
        groups[j] = tmp;
    }

    sink(tformat("{0}: {1} allocations, {2} bytes, {3} unique sites",
                 kind, total_count, total_bytes,
                 cast(uint) ngroups + (overflow.count > 0 ? 1 : 0)));
    sink("");

    // One batched resolve for all unique sites - on POSIX this folds
    // what was N full DWARF .debug_line scans into a single scan.
    void*[max_groups] addrs = void;
    Resolved[max_groups] resolved;
    foreach (i; 0 .. ngroups)
        addrs[i] = groups[i].pc;
    resolve_batch(addrs[0 .. ngroups], resolved[0 .. ngroups]);

    foreach (i; 0 .. ngroups)
    {
        Site s = groups[i];
        Duration age = now - s.oldest;
        const r = &resolved[i];

        sink(tformat("  {0} allocs, {1} bytes, oldest {2}", s.count, s.bytes, age));
        if (r.file.length > 0 && r.line > 0)
            sink(tformat("    {0}({1}): {2}", r.file, r.line, r.name));
        else if (r.name.length > 0)
            sink(tformat("    {0}", r.name));
        else
            sink(tformat("    0x{0:016x}", cast(size_t) s.pc));
    }

    if (overflow.count > 0)
    {
        Duration age = now - overflow.oldest;
        sink(tformat("  [overflow] {0} allocs, {1} bytes, oldest {2} (from > {3} unique sites)",
                     overflow.count, overflow.bytes, age, cast(uint) max_groups));
    }
}


private:

enum void* tombstone = cast(void*) 1;

// Prefixes of symbol names considered "allocator plumbing" and skipped
// when computing the top user frame. Extend as needed.
immutable string[] WRAPPER_PREFIXES = [
    "urt.mem.",
    "urt.internal.exception.",  // capture_trace itself lives here
    "_d_new",
    "_d_alloc",
    "_d_array",
    "_D3urt3mem",
];

bool is_wrapper_name(const(char)[] name)
{
    foreach (p; WRAPPER_PREFIXES)
    {
        if (name.length >= p.length && name[0 .. p.length] == p)
            return true;
    }
    return false;
}

void warn_table_full()
{
    if (_table_full_warned)
        return;
    _table_full_warned = true;

    import urt.io : writeln_err;
    writeln_err("urt.mem.tracking: allocation table at capacity -- subsequent allocs untracked! Increase track_capacity in urt.mem.tracking.");
}


// Hash table primitives

size_t hash_ptr(void* p) pure
{
    size_t x = cast(size_t) p >> 3;
    return cast(size_t)(cast(ulong) x * 0x9E3779B97F4A7C15UL);
}

size_t find(void* ptr)
{
    enum mask = cast(size_t)(track_capacity - 1);
    size_t i = hash_ptr(ptr) & mask;
    foreach (_; 0 .. track_capacity)
    {
        void* p = _table[i].ptr;
        if (p is null)
            return size_t.max;
        if (p is ptr)
            return i;
        i = (i + 1) & mask;
    }
    return size_t.max;
}

size_t find_insert(void* ptr)
{
    enum mask = cast(size_t)(track_capacity - 1);
    size_t i = hash_ptr(ptr) & mask;
    size_t first_tomb = size_t.max;
    foreach (_; 0 .. track_capacity)
    {
        void* p = _table[i].ptr;
        if (p is null)
            return first_tomb != size_t.max ? first_tomb : i;
        if (p is tombstone)
        {
            if (first_tomb == size_t.max)
                first_tomb = i;
        }
        else if (p is ptr)
            return i;
        i = (i + 1) & mask;
    }
    return first_tomb;
}
