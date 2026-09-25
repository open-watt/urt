module urt.driver.mt7621.alloc;

import urt.driver.mt7621.cache : cache_line, cached_alias, dcache_writeback_invalidate, is_uncached, uncached_alias;
import urt.mem.alloc : MemFlags, mem_is_dma;
import urt.sync.critical : Critical;

nothrow @nogc:

// One TLSF pool over [__heap_start, __heap_end), all of it DMA-reachable. DMA memory is the KSEG1
// alias of whole cache lines, dropped from the caches on allocation, so no cached write can land on it.
enum has_realloc  = true;
enum has_expand   = false;
enum has_memsize  = true;
enum has_exec     = false;
enum has_retain   = false;
enum has_memflags = true;
enum account_usable_size = true;
enum size_t min_alignment = 8;

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
    alias Fn = void function(size_t, size_t) pure nothrow @nogc;
    (cast(Fn)&log_oom)(size, alignment);
}

// The C allocator entry points are ours, so no libc allocator is ever pulled from the archive.
extern(C) void* malloc(size_t size)
    => alloc_impl(size, min_alignment, MemFlags.none).ptr;

extern(C) void free(void* ptr)
{
    if (ptr !is null)
        free_impl(ptr);
}

extern(C) void* calloc(size_t count, size_t size)
{
    if (size != 0 && count > size_t.max / size)
        return null;
    void[] m = alloc_impl(count * size, min_alignment, MemFlags.none);
    if (m.ptr !is null)
        (cast(ubyte[])m)[] = 0;
    return m.ptr;
}

extern(C) void* realloc(void* ptr, size_t size)
{
    if (ptr is null)
        return malloc(size);
    if (size == 0)
    {
        free_impl(ptr);
        return null;
    }
    return realloc_impl(ptr[0 .. memsize_impl(ptr)], size, min_alignment, MemFlags.none).ptr;
}

void heap_stats(out size_t total, out size_t used, out size_t peak, out size_t largest_free)
{
    auto guard = _lock.acquire();
    init_pool();
    total = _size;
    used = _used;
    peak = _peak;
    tlsf_walk_pool(_pool, &walker_max_free, &largest_free);
}


private:

alias tlsf_t = void*;
alias pool_t = void*;
alias tlsf_walker = extern(C) void function(void* ptr, size_t size, int used, void* user) nothrow @nogc;

extern(C) tlsf_t tlsf_create(void* mem);
extern(C) pool_t tlsf_add_pool(tlsf_t tlsf, void* mem, size_t bytes);
extern(C) size_t tlsf_size();
extern(C) void*  tlsf_memalign(tlsf_t tlsf, size_t alignment, size_t bytes);
extern(C) void*  tlsf_realloc(tlsf_t tlsf, void* ptr, size_t size);
extern(C) void   tlsf_free(tlsf_t tlsf, void* p);
extern(C) size_t tlsf_block_size(void* p);
extern(C) void   tlsf_walk_pool(pool_t pool, tlsf_walker walker, void* user);

enum size_t tlsf_control_bytes = 3200;

extern(C) extern __gshared char __heap_start;
extern(C) extern __gshared char __heap_end;

align(16) __gshared ubyte[tlsf_control_bytes] _control;
__gshared tlsf_t _tlsf;
__gshared pool_t _pool;
__gshared size_t _size;
__gshared size_t _used;
__gshared size_t _peak;
__gshared Critical _lock;

void init_pool()
{
    if (_tlsf)
        return;
    assert(tlsf_size() <= tlsf_control_bytes, "TLSF control structure larger than reserved");
    _size = cast(size_t)&__heap_end - cast(size_t)&__heap_start;
    _tlsf = tlsf_create(_control.ptr);
    _pool = tlsf_add_pool(_tlsf, &__heap_start, _size);
}

void account(ptrdiff_t delta)
{
    _used += delta;
    if (_used > _peak)
        _peak = _used;
}

void[] alloc_impl(size_t size, size_t alignment, MemFlags flags)
{
    immutable dma = mem_is_dma(flags);
    immutable bytes = dma ? (size + cache_line - 1) & ~(cache_line - 1) : size;
    auto guard = _lock.acquire();
    init_pool();
    void* p = tlsf_memalign(_tlsf, dma && alignment < cache_line ? cache_line : alignment, bytes);
    if (p is null)
        return null;
    account(tlsf_block_size(p));
    if (!dma)
        return p[0 .. size];
    dcache_writeback_invalidate(p, bytes);
    return uncached_alias(p)[0 .. size];
}

void[] realloc_impl(void[] mem, size_t new_size, size_t alignment, MemFlags flags)
{
    if (mem.ptr is null)
        return alloc_impl(new_size, alignment, flags);
    if (is_uncached(mem.ptr))
        flags |= MemFlags.dma;
    if (alignment > min_alignment || mem_is_dma(flags))
    {
        void[] fresh = alloc_impl(new_size, alignment, flags);
        if (fresh.ptr is null)
            return null;
        immutable keep = mem.length < new_size ? mem.length : new_size;
        fresh[0 .. keep] = mem[0 .. keep];
        free_impl(mem.ptr);
        return fresh;
    }
    auto guard = _lock.acquire();
    immutable old_block = tlsf_block_size(mem.ptr);
    void* p = tlsf_realloc(_tlsf, mem.ptr, new_size);
    if (p is null)
        return null;
    account(cast(ptrdiff_t)tlsf_block_size(p) - cast(ptrdiff_t)old_block);
    return p[0 .. new_size];
}

void free_impl(void* ptr)
{
    ptr = cached_alias(ptr);
    auto guard = _lock.acquire();
    account(-cast(ptrdiff_t)tlsf_block_size(ptr));
    tlsf_free(_tlsf, ptr);
}

size_t memsize_impl(void* ptr)
    => tlsf_block_size(cached_alias(ptr));

void log_oom(size_t size, size_t alignment)
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope (exit) reentrant = false;
    import urt.log;
    log_error("heap.alloc", "OOM! - size=", size, " align=", alignment);
}

extern(C) void walker_max_free(void* ptr, size_t size, int used, void* user)
{
    if (!used && size > *cast(size_t*)user)
        *cast(size_t*)user = size;
}


unittest
{
    import urt.mem.alloc : alloc, free, realloc;

    void[] a = alloc(40, MemFlags.dma);
    assert(is_uncached(a.ptr) && (cast(size_t)a.ptr & (cache_line - 1)) == 0);
    auto u = cast(ubyte[])a;
    auto c = (cast(ubyte*)cached_alias(a.ptr))[0 .. a.length];
    foreach (i, ref b; u)
        b = cast(ubyte)(i * 7 + 1);
    foreach (i, b; c)
        assert(b == cast(ubyte)(i * 7 + 1), "a stale cache line shadows DMA memory");

    a = realloc(a, 200);
    assert(is_uncached(a.ptr));
    foreach (i, b; (cast(ubyte[])a)[0 .. 40])
        assert(b == cast(ubyte)(i * 7 + 1));
    free(a);
}
