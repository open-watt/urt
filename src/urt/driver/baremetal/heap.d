// Each platform's topology supplies heap_regions, pool_by_flags, tlsf_control_bytes and
// c_heap_flags, and optionally report_oom; C's malloc family is overridden onto the same pools.
module urt.driver.baremetal.heap;

version (Bouffalo)     { static import urt.driver.bl_common.heap; alias topology = urt.driver.bl_common.heap; version = TlsfHeap; }
else version (BK7231N) { static import urt.driver.bk7231.heap; alias topology = urt.driver.bk7231.heap; version = TlsfHeap; }

version (TlsfHeap):

import urt.attribute : fast_data;
import urt.mem.alloc : MemFlags, default_alignment;
import urt.sync.critical : Critical;

enum size_t num_pools = topology.heap_regions.length;
private alias tlsf_control_bytes = topology.tlsf_control_bytes;
private alias c_heap_flags = topology.c_heap_flags;
private alias heap_regions = topology.heap_regions;
private alias pool_by_flags = topology.pool_by_flags;
static assert(MemFlags.max < pool_by_flags.length, "pool_by_flags is indexed by the whole MemFlags");

@nogc nothrow:

enum size_t min_alignment = 8;

enum has_realloc  = true;
enum has_expand   = false;
enum has_memsize  = true;
enum has_exec     = false;
enum has_retain   = false;
enum has_memflags = true;
enum account_usable_size = true;

struct HeapRegion
{
    immutable(ubyte)* start;
    immutable(ubyte)* end;
    immutable(char)* name;
}

struct PoolStats
{
    immutable(char)* name;
    size_t total;
    size_t used;
    size_t peak_used;
    size_t largest_free;
}

void[] _alloc(size_t size, size_t alignment, MemFlags flags) pure
{
    alias Fn = void[] function(size_t, size_t, MemFlags) pure nothrow @nogc;
    return (cast(Fn)&alloc_impl)(size, alignment, flags);
}

void[] _realloc(void[] mem, size_t new_size, size_t alignment, MemFlags flags) pure
{
    alias Fn = void[] function(void[], size_t, size_t, MemFlags) pure nothrow @nogc;
    return (cast(Fn)&realloc_impl)(mem, new_size, alignment, flags);
}

void _free(void* ptr) pure
{
    alias Fn = void function(void*) pure nothrow @nogc;
    (cast(Fn)&free_impl)(ptr);
}

size_t _memsize(void* ptr) pure
{
    alias Fn = size_t function(void*) pure nothrow @nogc;
    return (cast(Fn)&memsize_impl)(ptr);
}

void _alloc_failure(size_t size, size_t alignment, MemFlags flags) pure
{
    alias Fn = void function(size_t, size_t, MemFlags) pure nothrow @nogc;
    static if (__traits(hasMember, topology, "report_oom"))
        (cast(Fn)&topology.report_oom)(size, alignment, flags);
    else
        (cast(Fn)&log_oom)(size, alignment, flags);
}

// Walks the pool's blocks: for sysinfo, not hot paths.
void query_pool_stats(size_t idx, out PoolStats stats)
{
    auto guard = _heap_lock.acquire();
    init_pools();
    Pool* p = &_pools[idx];
    stats.name = p.name;
    stats.total = p.size;
    stats.used = p.used;
    stats.peak_used = p.peak_used;
    if (p.tlsf)
        tlsf_walk_pool(p.pool, &walker_max_free, &stats.largest_free);
}

extern(C) void* malloc(size_t size)
{
    return alloc_impl(size, default_alignment, c_heap_flags).ptr;
}

extern(C) void free(void* ptr)
{
    if (ptr)
        free_impl(ptr);
}

extern(C) void* calloc(size_t count, size_t size)
{
    if (size && count > size_t.max / size)
        return null;
    size_t total = count * size;
    void* p = alloc_impl(total, default_alignment, c_heap_flags).ptr;
    if (p)
        (cast(ubyte*)p)[0 .. total] = 0;
    return p;
}

extern(C) void* realloc(void* ptr, size_t size)
{
    return realloc_impl(ptr ? ptr[0 .. memsize_impl(ptr)] : null, size, default_alignment, c_heap_flags).ptr;
}

pragma(mangle, "__malloc_malloc")
extern(C) void* malloc_internal(size_t size) => malloc(size);

pragma(mangle, "__malloc_free")
extern(C) void free_internal(void* ptr) { free(ptr); }


private:

alias tlsf_t = void*;
alias pool_t = void*;
alias tlsf_walker = extern(C) void function(void* ptr, size_t size, int used, void* user) nothrow @nogc;

extern(C) tlsf_t tlsf_create(void* mem) pure;
extern(C) pool_t tlsf_add_pool(tlsf_t tlsf, void* mem, size_t bytes) pure;
extern(C) size_t tlsf_size() pure;
extern(C) size_t tlsf_pool_overhead() pure;
extern(C) void*  tlsf_memalign(tlsf_t tlsf, size_t alignment, size_t bytes) pure;
extern(C) void*  tlsf_realloc(tlsf_t tlsf, void* ptr, size_t size) pure;
extern(C) void   tlsf_free(tlsf_t tlsf, void* p) pure;
extern(C) size_t tlsf_block_size(void* p) pure;
extern(C) void   tlsf_walk_pool(pool_t pool, tlsf_walker walker, void* user) pure;

struct Pool
{
    void* base;
    size_t size;
    tlsf_t tlsf;
    pool_t pool;
    size_t used;
    size_t peak_used;
    immutable(char)* name;
}

// Control blocks sit in the fastest RAM whichever bank their pool manages.
@fast_data align(16) __gshared ubyte[tlsf_control_bytes][num_pools] _control;
@fast_data __gshared Pool[num_pools] _pools;
@fast_data __gshared bool _initialized;

// TLSF has no locking of its own, and C code enters through the malloc overrides from any
// context. Log calls stay outside the lock; they format strings.
@fast_data __gshared Critical _heap_lock;

void[] alloc_impl(size_t size, size_t alignment, MemFlags flags)
{
    void* p;
    bool failed_over;
    {
        auto guard = _heap_lock.acquire();
        init_pools();

        size_t primary = pool_by_flags[flags & 7];
        p = allocate(_pools[primary], size, alignment);
        if (!p && !(flags & MemFlags.dma))
        {
            foreach (i, ref pool; _pools)
            {
                if (i == primary)
                    continue;
                p = allocate(pool, size, alignment);
                if (p)
                {
                    failed_over = true;
                    break;
                }
            }
        }
    }

    if (failed_over)
        log_failover(size, alignment, flags);
    return p ? p[0 .. size] : null;
}

void[] realloc_impl(void[] mem, size_t new_size, size_t alignment, MemFlags flags)
{
    import urt.util : is_aligned;

    if (!mem.ptr)
        return alloc_impl(new_size, alignment, flags);
    if (!new_size)
    {
        free_impl(mem.ptr);
        return null;
    }

    {
        auto guard = _heap_lock.acquire();
        Pool* owner = pool_of(mem.ptr);
        if (!owner)
            return null;
        size_t old_block = tlsf_block_size(mem.ptr);
        if (!(flags & MemFlags.dma) || owner is &_pools[pool_by_flags[flags & 7]])
        {
            // tlsf_realloc keeps only TLSF's own alignment when it has to move the block.
            if (alignment <= min_alignment)
            {
                if (void* p = tlsf_realloc(owner.tlsf, mem.ptr, new_size))
                {
                    owner.used = owner.used - old_block + tlsf_block_size(p);
                    if (owner.used > owner.peak_used)
                        owner.peak_used = owner.used;
                    return p[0 .. new_size];
                }
            }
            else if (new_size <= old_block && is_aligned(mem.ptr, alignment))
                return mem.ptr[0 .. new_size];
        }
    }

    void[] moved = alloc_impl(new_size, alignment, flags);
    if (moved.ptr)
    {
        size_t keep = mem.length < new_size ? mem.length : new_size;
        moved[0 .. keep] = mem[0 .. keep];
        free_impl(mem.ptr);
    }
    return moved;
}

void free_impl(void* ptr)
{
    auto guard = _heap_lock.acquire();
    Pool* owner = pool_of(ptr);
    if (!owner)
        return;
    owner.used -= tlsf_block_size(ptr);
    tlsf_free(owner.tlsf, ptr);
}

size_t memsize_impl(void* ptr)
{
    auto guard = _heap_lock.acquire();
    return pool_of(ptr) ? tlsf_block_size(ptr) : 0;
}

void* allocate(ref Pool pool, size_t size, size_t alignment)
{
    if (!pool.tlsf)
        return null;
    void* p = tlsf_memalign(pool.tlsf, alignment, size);
    if (p)
    {
        pool.used += tlsf_block_size(p);
        if (pool.used > pool.peak_used)
            pool.peak_used = pool.used;
    }
    return p;
}

// A region too small to carry TLSF's pool overhead is left unmanaged.
void init_pools()
{
    if (_initialized)
        return;
    _initialized = true;

    assert(tlsf_size() <= tlsf_control_bytes, "TLSF control block larger than reserved");
    foreach (i, ref p; _pools)
    {
        p.base = cast(void*)heap_regions[i].start;
        p.size = heap_regions[i].end - heap_regions[i].start;
        p.name = heap_regions[i].name;
        if (p.size <= tlsf_pool_overhead())
            continue;
        p.tlsf = tlsf_create(_control[i].ptr);
        p.pool = tlsf_add_pool(p.tlsf, p.base, p.size);
    }
}

Pool* pool_of(void* ptr)
{
    size_t addr = cast(size_t)ptr;
    foreach (ref p; _pools)
    {
        if (p.tlsf && addr >= cast(size_t)p.base && addr < cast(size_t)p.base + p.size)
            return &p;
    }
    return null;
}

extern(C) void walker_max_free(void*, size_t size, int used, void* user)
{
    size_t* largest = cast(size_t*)user;
    if (!used && size > *largest)
        *largest = size;
}

void log_oom(size_t size, size_t alignment, MemFlags flags)
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope (exit) reentrant = false;

    import urt.log;
    log_error("heap.alloc", "OOM! - size=", size, " align=", alignment, " flags=", cast(int)flags);
}

void log_failover(size_t size, size_t alignment, MemFlags flags)
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope (exit) reentrant = false;

    import urt.log;
    log_debug("heap.alloc", "preferred pool full, fell back - size=", size, " align=", alignment, " flags=", cast(int)flags);
}


unittest
{
    import urt.mem.alloc : alloc, free, realloc;
    import urt.util : is_aligned;

    void[] m = alloc(64, 64);
    (cast(ubyte[])m)[] = 0x5A;
    void[] neighbour = alloc(64);
    m = realloc(m, 2048, 64);
    assert(m.ptr && is_aligned(m.ptr, 64), "a moving realloc lost the requested alignment");
    foreach (b; (cast(ubyte[])m)[0 .. 64])
        assert(b == 0x5A);
    free(m);
    free(neighbour);

    m = alloc(64, 8);
    (cast(ubyte[])m)[] = 0xA5;
    m = realloc(m, 32, 64);
    assert(m.ptr && is_aligned(m.ptr, 64), "a shrinking realloc kept a block short of the requested alignment");
    foreach (b; cast(ubyte[])m)
        assert(b == 0xA5);
    free(m);
}
