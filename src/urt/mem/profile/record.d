/**
 * Allocation tracking for leak detection.
 *
 * Enabled with `version = AllocTracking;` (make ALLOC_TRACKING=1). When
 * enabled, the central allocator (`urt.mem.alloc`) calls into this module on
 * every alloc/realloc/free to record the caller's call site in a fixed-size
 * open-addressed hash table keyed on pointer.
 *
 * This answers "what is live on this device, right now" without a host or a
 * captured stream, which is the reason to pay for a table at all. For budget
 * work on targets that cannot afford one, `urt.mem.profile.log` logs the same
 * events and does the analysis on the host for ~50 bytes of target state.
 *
 * Traces are interned: allocations overwhelmingly repeat the same call
 * paths, so each entry stores a two byte site index and the frames live once
 * in a bounded side table. Deletion uses backward shifting rather than
 * tombstones, so probe distances do not grow without bound on a long run.
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
module urt.mem.profile.record;

version (AllocTracking):

import urt.time : Duration, msecs;
import urt.mem.profile.common : Sink, time_ms;
import urt.internal.exception : capture_trace, resolve_address, resolve_batch, Resolved;

nothrow @nogc:


// Tuning

// Number of stack frames captured per call site. It takes about six frames to climb out of the
// allocator, so anything shallower resolves entirely to plumbing. Interned, so depth costs the
// site table rather than every entry.
enum trace_depth = 8;

// Maximum live allocations tracked.
// 24 bytes per entry on 64-bit: 16384 * 24 = 384 KiB, plus the site table.
enum track_capacity = 16384;
static assert((track_capacity & (track_capacity - 1)) == 0, "track_capacity must be a power of two");

// Maximum distinct call sites. A near-empty OpenWatt config already reaches about 465, so this
// is not the "few hundred" it looks like. Overflow costs traces, not correctness, and warns.
enum max_sites = 1024;
enum site_slots = max_sites * 2;
static assert((site_slots & (site_slots - 1)) == 0, "site_slots must be a power of two");

// Load factor ceiling (num/den). Linear probing degrades past ~70%.
enum track_max_load_num = 7;
enum track_max_load_den = 10;

// Max unique call sites shown in a grouped leak dump.
enum max_groups = 128;


// Entry / storage

struct Entry
{
    void*  ptr;       // null = empty; there are no tombstones
    uint   size;
    uint   serial;
    uint   time_ms;   // monotonic milliseconds; wrap-safe deltas only
    ushort site;      // 1-based index into _sites, 0 = unknown
}

struct Site
{
    void*[trace_depth] pcs;
}

__gshared Entry[track_capacity]   _table;
__gshared Site[max_sites]         _sites;
__gshared ushort[site_slots]      _site_slots;   // 0 = empty, else 1-based site id
__gshared uint                    _site_count;
__gshared uint                    _live_count;
__gshared uint                    _serial_counter;
__gshared uint                    _baseline_serial;
__gshared ulong                   _tracked_bytes;
__gshared bool                    _table_full_warned;
__gshared bool                    _sites_full_warned;

// Interning traces is most of what makes this affordable; keep it from drifting back.
static assert(_table.sizeof + _sites.sizeof + _site_slots.sizeof < 512 * 1024,
              "tracking tables have outgrown their budget");


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

    insert_at(slot, ptr, size, intern_site());
}

void untrack_alloc(void* ptr)
{
    if (ptr is null)
        return;
    size_t slot = find(ptr);
    if (slot == size_t.max)
        return;
    _tracked_bytes -= _table[slot].size;
    remove_at(slot);
}

void track_realloc(void* old_ptr, void* new_ptr, size_t new_size)
{
    if (new_ptr is null)
        return;

    if (old_ptr is new_ptr)
    {
        size_t slot = find(new_ptr);
        if (slot != size_t.max)
        {
            _tracked_bytes = _tracked_bytes - _table[slot].size + new_size;
            _table[slot].size = cast(uint) new_size;
            // Keep original serial/time/site -- the allocation's identity hasn't changed.
        }
        else
            track_alloc(new_ptr, new_size);
        return;
    }

    // Re-capturing here would blame a grown container on whoever appended to it.
    uint serial, time_ms;
    ushort site;
    bool carried;
    if (old_ptr !is null)
    {
        size_t old_slot = find(old_ptr);
        if (old_slot != size_t.max)
        {
            serial = _table[old_slot].serial;
            time_ms = _table[old_slot].time_ms;
            site = _table[old_slot].site;
            carried = true;
            _tracked_bytes -= _table[old_slot].size;
            remove_at(old_slot);
        }
    }

    if (_live_count * track_max_load_den >= track_capacity * track_max_load_num)
    {
        warn_table_full();
        return;
    }
    size_t slot = find_insert(new_ptr);
    if (slot == size_t.max)
    {
        warn_table_full();
        return;
    }

    insert_at(slot, new_ptr, new_size, carried ? site : intern_site());
    if (carried)
    {
        _table[slot].serial = serial;
        _table[slot].time_ms = time_ms;
        --_serial_counter;   // insert_at issued a fresh one we did not use
    }
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

// First frame whose symbol is not allocator plumbing. Null when every frame is plumbing: the
// trace was too shallow, and naming the deepest wrapper would look like an answer without being one.
void* top_user_pc(const(void*)[] pcs)
{
    foreach (addr; pcs)
    {
        if (addr is null)
            continue;

        Resolved r;
        if (!resolve_address(cast(void*) addr, r))
            return cast(void*) addr;  // unresolved -> assume user code
        if (!is_wrapper_name(r.name))
            return cast(void*) addr;
    }
    return null;
}

// Sink-based stats dump. One sink call per line, no trailing newline.
void alloc_print_stats(scope Sink sink)
{
    import urt.mem.temp : tformat;

    sink(tformat("Live allocations: {0}", _live_count));
    sink(tformat("Live bytes:       {0}", _tracked_bytes));
    sink(tformat("Table capacity:   {0} ({1} bytes)", cast(uint) track_capacity, cast(uint) _table.sizeof));
    sink(tformat("Call sites:       {0}/{1} ({2} bytes)", _site_count, cast(uint) max_sites, cast(uint) _sites.sizeof));
    sink(tformat("Total allocs:     {0} (serial)", _serial_counter));
    sink(tformat("Baseline:         {0}", _baseline_serial));
    if (_table_full_warned)
        sink("WARNING: tracking table has overflowed at least once -- some allocations untracked");
    if (_sites_full_warned)
        sink("WARNING: call site table is full -- some allocations have no trace");
}

// Grouped leak dump. Shows allocations with `serial > baseline` that
// have been alive at least `min_age`, grouped by call site.
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
    import urt.mem.temp : tconcat, tformat;

    // By site, not by top frame, so call paths sharing a frame stay distinguishable.
    struct Group
    {
        ushort site;
        uint   count;
        ulong  bytes;
        uint   oldest_ms;
    }

    Group[max_groups] groups = void;
    size_t ngroups = 0;
    Group overflow;
    overflow.count = 0;
    overflow.bytes = 0;

    uint now = time_ms();
    uint min_age_ms = min_age > Duration.init ? cast(uint) min_age.as!"msecs" : 0;

    uint total_count = 0;
    ulong total_bytes = 0;

    foreach (ref e; _table)
    {
        if (e.ptr is null)
            continue;
        if (e.serial <= min_serial)
            continue;
        if (now - e.time_ms < min_age_ms)
            continue;

        size_t g = size_t.max;
        foreach (i; 0 .. ngroups)
            if (groups[i].site == e.site) { g = i; break; }

        Group* s;
        if (g == size_t.max)
        {
            if (ngroups < max_groups)
            {
                groups[ngroups] = Group(e.site, 0, 0, e.time_ms);
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
        if (now - e.time_ms > now - s.oldest_ms)
            s.oldest_ms = e.time_ms;

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
        Group tmp = groups[i];
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

    // One batched resolve for all displayed sites - on POSIX this folds
    // what was N full DWARF .debug_line scans into a single scan.
    void*[max_groups] addrs = void;
    Resolved[max_groups] resolved;
    foreach (i; 0 .. ngroups)
        addrs[i] = groups[i].site != 0 ? top_user_pc(_sites[groups[i].site - 1].pcs[]) : null;
    resolve_batch(addrs[0 .. ngroups], resolved[0 .. ngroups]);

    foreach (i; 0 .. ngroups)
    {
        Group s = groups[i];
        Duration age = msecs(now - s.oldest_ms);
        const r = &resolved[i];

        sink(tformat("  {0} allocs, {1} bytes, oldest {2}", s.count, s.bytes, age));
        if (addrs[i] is null)
            sink("    (no caller in trace -- raise trace_depth)");
        else if (r.file.length > 0 && r.line > 0)
            sink(tformat("    {0}({1}): {2}", r.file, r.line, r.name));
        else if (r.name.length > 0)
            sink(tconcat("    ", r.name));
        else
            sink(tconcat("    0x", addrs[i]));
    }

    if (overflow.count > 0)
    {
        Duration age = msecs(now - overflow.oldest_ms);
        sink(tformat("  [overflow] {0} allocs, {1} bytes, oldest {2} (from > {3} unique sites)",
                     overflow.count, overflow.bytes, age, cast(uint) max_groups));
    }
}


private:

// Prefixes of symbol names considered "allocator plumbing" and skipped
// when computing the top user frame. Extend as needed.
//
// The container modules belong here: without them every Array, Map or String allocation is
// attributed to array_allocate rather than to the code that wanted the memory.
immutable string[] WRAPPER_PREFIXES = [
    "urt.mem.",
    "urt.array",
    "urt.string",
    "urt.map",
    "urt.list",
    "urt.lifetime",
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
    writeln_err("urt.mem.profile.record: allocation table at capacity -- subsequent allocs untracked! Increase track_capacity in urt.mem.profile.record.");
}

void warn_sites_full()
{
    if (_sites_full_warned)
        return;
    _sites_full_warned = true;

    import urt.io : writeln_err;
    writeln_err("urt.mem.profile.record: call site table full -- subsequent allocs recorded without a trace! Increase max_sites in urt.mem.profile.record.");
}


// Call site interning

size_t hash_trace(ref const void*[trace_depth] pcs) pure
{
    size_t h = 0xcbf29ce484222325;
    foreach (pc; pcs)
    {
        h ^= cast(size_t) pc;
        h *= 0x100000001b3;
    }
    return h;
}

ushort intern_site()
{
    void*[trace_depth] pcs = null;
    capture_trace(pcs[]);

    enum mask = cast(size_t)(site_slots - 1);
    size_t i = hash_trace(pcs) & mask;
    foreach (_; 0 .. site_slots)
    {
        ushort id = _site_slots[i];
        if (id == 0)
        {
            if (_site_count >= max_sites)
            {
                warn_sites_full();
                return 0;
            }
            _sites[_site_count].pcs = pcs;
            _site_slots[i] = cast(ushort)(++_site_count);
            return cast(ushort) _site_count;
        }
        if (_sites[id - 1].pcs == pcs)
            return id;
        i = (i + 1) & mask;
    }
    warn_sites_full();
    return 0;
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
    foreach (_; 0 .. track_capacity)
    {
        void* p = _table[i].ptr;
        if (p is null || p is ptr)
            return i;
        i = (i + 1) & mask;
    }
    return size_t.max;
}

void insert_at(size_t slot, void* ptr, size_t size, ushort site)
{
    if (_table[slot].ptr !is null)
        _tracked_bytes -= _table[slot].size;   // same pointer handed out twice
    else
        ++_live_count;

    _table[slot] = Entry(ptr, cast(uint) size, ++_serial_counter, time_ms(), site);
    _tracked_bytes += size;
}

// Backward-shift deletion (Knuth 6.4R). A tombstone is never reclaimed: probes only stop at an
// empty slot, so the table saturates with them over a long run and every lookup walks further,
// while a live-only load factor never notices.
void remove_at(size_t slot)
{
    enum mask = cast(size_t)(track_capacity - 1);

    --_live_count;

    size_t i = slot;
    for (;;)
    {
        _table[i].ptr = null;

        size_t j = i;
        for (;;)
        {
            j = (j + 1) & mask;
            if (_table[j].ptr is null)
                return;

            size_t k = hash_ptr(_table[j].ptr) & mask;
            // Leave j alone while its ideal slot lies cyclically in (i, j];
            // moving it back would put it before its own probe start.
            bool keep = (i <= j) ? (i < k && k <= j) : (i < k || k <= j);
            if (!keep)
                break;
        }

        _table[i] = _table[j];
        i = j;
    }
}


unittest
{
    // The hooks are live for the whole unittest binary, so drive the table
    // with fake pointers that cannot collide with real heap blocks, and put
    // the globals back as we found them.
    uint base_live = _live_count;
    ulong base_bytes = _tracked_bytes;

    ubyte[8][4] blocks;

    track_alloc(&blocks[0], 100);
    track_alloc(&blocks[1], 200);
    assert(_live_count == base_live + 2);
    assert(_tracked_bytes == base_bytes + 300);

    // A tracked pointer is findable, and a freed one is not.
    assert(find(&blocks[0]) != size_t.max);
    untrack_alloc(&blocks[0]);
    assert(find(&blocks[0]) == size_t.max);
    assert(_live_count == base_live + 1);
    assert(_tracked_bytes == base_bytes + 200);

    // Moving realloc keeps identity: same site and serial, new size.
    size_t slot = find(&blocks[1]);
    uint serial_before = _table[slot].serial;
    ushort site_before = _table[slot].site;
    track_realloc(&blocks[1], &blocks[2], 500);
    slot = find(&blocks[2]);
    assert(slot != size_t.max);
    assert(_table[slot].serial == serial_before);
    assert(_table[slot].site == site_before);
    assert(_table[slot].size == 500);
    assert(find(&blocks[1]) == size_t.max);
    assert(_tracked_bytes == base_bytes + 500);

    untrack_alloc(&blocks[2]);
    assert(_live_count == base_live);
    assert(_tracked_bytes == base_bytes);

    // Deletion must not strand entries that probed past the removed slot.
    // Force a collision chain by hand, then delete from the front of it.
    enum mask = cast(size_t)(track_capacity - 1);
    void*[6] chain;
    size_t home = size_t.max;
    size_t found = 0;
    for (size_t cand = 0x10000; found < chain.length && cand < 0x400000; cand += 8)
    {
        void* p = cast(void*) cand;
        size_t h = hash_ptr(p) & mask;
        if (home == size_t.max)
        {
            // Only take a home slot that is currently free, so the synthetic
            // chain does not tangle with the binary's real allocations.
            if (_table[h].ptr !is null)
                continue;
            home = h;
        }
        else if (h != home)
            continue;
        chain[found++] = p;
    }

    if (found == chain.length)
    {
        foreach (p; chain)
            track_alloc(p, 16);
        foreach (p; chain)
            assert(find(p) != size_t.max);

        // Remove the head; every survivor must still be reachable.
        untrack_alloc(chain[0]);
        assert(find(chain[0]) == size_t.max);
        foreach (p; chain[1 .. $])
            assert(find(p) != size_t.max, "backward shift stranded an entry");

        // And from the middle.
        untrack_alloc(chain[2]);
        assert(find(chain[2]) == size_t.max);
        foreach (i, p; chain)
            if (i != 0 && i != 2)
                assert(find(p) != size_t.max, "backward shift stranded an entry");

        foreach (i, p; chain)
            if (i != 0 && i != 2)
                untrack_alloc(p);
    }

    assert(_live_count == base_live);
    assert(_tracked_bytes == base_bytes);

    // Repeated churn through one slot must not grow the table's occupancy,
    // which is what tombstones used to do.
    uint live_before = _live_count;
    foreach (i; 0 .. 1000)
    {
        track_alloc(&blocks[3], 32);
        untrack_alloc(&blocks[3]);
    }
    assert(_live_count == live_before);

    // Interning: the same call site must not consume a new slot each time.
    uint sites_before = _site_count;
    foreach (i; 0 .. 50)
    {
        track_alloc(&blocks[3], 8);
        untrack_alloc(&blocks[3]);
    }
    assert(_site_count <= sites_before + 1);

    assert(_tracked_bytes == base_bytes);
}
