module urt.driver.bk7231.alloc;

version (BK7231N) import urt.attribute : fast_data;
import urt.mem.alloc : MemFlags;
version (BK7231N) import urt.sync.critical : Critical;

nothrow @nogc:

enum has_realloc = false;
enum has_expand = false;
version (BK7231N) enum has_memsize = true;
else enum has_memsize = false;
enum has_exec = false;
enum has_retain = false;
version (BK7231N) enum has_memflags = true;
else enum has_memflags = false;
version (BK7231N) enum account_usable_size = true;

void[] _alloc(size_t size, size_t alignment, MemFlags flags) pure
{
    version (BK7231N)
    {
        alias AllocFn = void[] function(size_t, size_t, MemFlags) pure nothrow @nogc;
        return (cast(AllocFn)&alloc_impl)(size, alignment, flags);
    }
    else
        return picolibc_alloc(size, alignment);
}

void _free(void* ptr) pure
{
    version (BK7231N)
    {
        alias FreeFn = void function(void*) pure nothrow @nogc;
        (cast(FreeFn)&free_impl)(ptr);
    }
    else
        picolibc_free(ptr);
}

version (BK7231N) size_t _memsize(void* ptr) pure
{
    alias MemsizeFn = size_t function(void*) pure nothrow @nogc;
    return (cast(MemsizeFn)&memsize_impl)(ptr);
}

void _alloc_failure(size_t size, size_t, MemFlags) pure
{
    alias ReportFn = void function(size_t) pure nothrow @nogc;
    (cast(ReportFn)&report_oom)(size);
}

void[] fast_alloc(size_t size, size_t alignment = size_t.sizeof)
{
    version (BK7231N)
    {
        auto guard = _lock.acquire();
        initialise();
        void* ptr = allocate(_fast, size, alignment);
        return ptr ? ptr[0 .. size] : null;
    }
    else
        return null;
}

void fast_free(void* ptr)
{
    version (BK7231N)
    {
        auto guard = _lock.acquire();
        tlsf_free(_fast.tlsf, ptr);
    }
}

void fast_heap_stats(out size_t total, out size_t used, out size_t largest_free)
{
    version (BK7231N)
        heap_stats(_fast, total, used, largest_free);
    else
        total = used = largest_free = 0;
}

void sram_heap_stats(out size_t total, out size_t used, out size_t largest_free)
{
    version (BK7231N)
        heap_stats(_sram, total, used, largest_free);
    else
        picolibc_heap_stats(total, used, largest_free);
}

version (BK7231N)
{
    extern(C) void* malloc(size_t size)
    {
        return sram_alloc(size, size_t.sizeof);
    }

    extern(C) void free(void* ptr)
    {
        if (ptr)
            sram_free(ptr);
    }

    extern(C) void* calloc(size_t count, size_t size)
    {
        if (size && count > size_t.max / size)
            return null;
        size_t total = count * size;
        void* ptr = sram_alloc(total, size_t.sizeof);
        if (ptr)
            (cast(ubyte*)ptr)[0 .. total] = 0;
        return ptr;
    }

    extern(C) void* realloc(void* ptr, size_t size)
    {
        if (!ptr)
            return malloc(size);
        if (!size)
        {
            free(ptr);
            return null;
        }

        auto guard = _lock.acquire();
        initialise();
        return tlsf_realloc(_sram.tlsf, ptr, size);
    }

    pragma(mangle, "__malloc_malloc")
    extern(C) void* malloc_internal(size_t size)
    {
        return malloc(size);
    }

    pragma(mangle, "__malloc_free")
    extern(C) void free_internal(void* ptr)
    {
        free(ptr);
    }

    extern(C) void* _malloc_r(void*, size_t size)
    {
        return malloc(size);
    }

    extern(C) void _free_r(void*, void* ptr)
    {
        free(ptr);
    }

    extern(C) void* _calloc_r(void*, size_t count, size_t size)
    {
        return calloc(count, size);
    }

    extern(C) void* _realloc_r(void*, void* ptr, size_t size)
    {
        return realloc(ptr, size);
    }
}

private:

version (BK7231N)
{
    enum size_t tlsf_control_bytes = 3200;

    alias tlsf_t = void*;
    alias pool_t = void*;
    alias tlsf_walker = extern(C) void function(void*, size_t, int, void*) nothrow @nogc;

    struct Pool
    {
        tlsf_t tlsf;
        pool_t pool;
    }

    struct HeapStats
    {
        size_t total;
        size_t used;
        size_t largest_free;
    }

    __gshared Pool _fast;
    __gshared Pool _sram;
    @fast_data align(16) __gshared ubyte[tlsf_control_bytes][2] _control;
    __gshared Critical _lock;
    __gshared bool _initialised;

    extern(C) extern const ubyte _fast_heap_start, _fast_heap_end;
    extern(C) extern const ubyte __heap_start, __heap_end;

    extern(C)
    {
        tlsf_t tlsf_create(void* mem);
        pool_t tlsf_add_pool(tlsf_t tlsf, void* mem, size_t bytes);
        size_t tlsf_size();
        void* tlsf_memalign(tlsf_t tlsf, size_t alignment, size_t bytes);
        void* tlsf_realloc(tlsf_t tlsf, void* ptr, size_t bytes);
        void tlsf_free(tlsf_t tlsf, void* ptr);
        size_t tlsf_block_size(void* ptr);
        void tlsf_walk_pool(pool_t pool, tlsf_walker walker, void* context);
    }

    void[] alloc_impl(size_t size, size_t alignment, MemFlags flags)
    {
        auto guard = _lock.acquire();
        initialise();

        void* ptr;
        if (!(flags & MemFlags.dma))
            ptr = allocate(_fast, size, alignment);
        if (!ptr)
            ptr = allocate(_sram, size, alignment);
        return ptr ? ptr[0 .. size] : null;
    }

    void free_impl(void* ptr)
    {
        auto guard = _lock.acquire();
        tlsf_free(owner(ptr).tlsf, ptr);
    }

    size_t memsize_impl(void* ptr)
    {
        auto guard = _lock.acquire();
        return tlsf_block_size(ptr);
    }

    Pool* owner(const(void)* ptr)
        => ptr < &_fast_heap_end ? &_fast : &_sram;

    void* sram_alloc(size_t size, size_t alignment)
    {
        auto guard = _lock.acquire();
        initialise();
        return allocate(_sram, size, alignment);
    }

    void sram_free(void* ptr)
    {
        auto guard = _lock.acquire();
        tlsf_free(_sram.tlsf, ptr);
    }

    void* allocate(ref Pool pool, size_t size, size_t alignment)
        => pool.tlsf ? tlsf_memalign(pool.tlsf, alignment, size) : null;

    void initialise()
    {
        if (_initialised)
            return;
        _initialised = true;
        initialise_pool(_fast, _control[0], &_fast_heap_start, &_fast_heap_end);
        initialise_pool(_sram, _control[1], &__heap_start, &__heap_end);
    }

    void initialise_pool(ref Pool pool, ref ubyte[tlsf_control_bytes] control, const(void)* start, const(void)* end)
    {
        size_t size = cast(size_t)end - cast(size_t)start;
        if (!size)
            return;
        assert(tlsf_size() <= control.length);
        pool.tlsf = tlsf_create(control.ptr);
        pool.pool = tlsf_add_pool(pool.tlsf, cast(void*)start, size);
    }

    void heap_stats(ref Pool pool, out size_t total, out size_t used, out size_t largest_free)
    {
        auto guard = _lock.acquire();
        initialise();

        HeapStats stats;
        tlsf_walk_pool(pool.pool, &walk_pool, &stats);
        total = stats.total;
        used = stats.used;
        largest_free = stats.largest_free;
    }

    extern(C) void walk_pool(void*, size_t size, int used, void* context)
    {
        HeapStats* stats = cast(HeapStats*)context;
        stats.total += size;
        if (used)
            stats.used += size;
        else if (size > stats.largest_free)
            stats.largest_free = size;
    }
}
else
{
    extern(C) extern const ubyte __heap_start, __heap_end;

    extern(C) void* malloc(size_t size) pure;
    extern(C) void free(void* ptr) pure;
    extern(C) void* sbrk(ptrdiff_t increment) pure;

    void[] picolibc_alloc(size_t size, size_t alignment) pure
    {
        import urt.util : align_down;

        size_t header_size = (void*).sizeof + alignment;
        void* allocation = malloc(header_size + size);
        if (!allocation)
            return null;

        size_t address = align_down(cast(size_t)allocation + header_size, alignment);
        (cast(void**)address)[-1] = allocation;
        return (cast(void*)address)[0 .. size];
    }

    void picolibc_free(void* ptr) pure
    {
        free((cast(void**)ptr)[-1]);
    }

    void picolibc_heap_stats(out size_t total, out size_t used, out size_t largest_free)
    {
        size_t start = cast(size_t)&__heap_start;
        total = cast(size_t)&__heap_end - start;
        void* current = sbrk(0);
        used = current > cast(void*)start ? cast(size_t)current - start : 0;
        largest_free = total - used;
    }
}

void report_oom(size_t size)
{
    import urt.driver.bk7231.uart : uart0_hw_puts;

    char[16] buf = void;
    size_t total, used, largest;
    uart0_hw_puts("\r\nOOM: alloc ");
    uart0_hw_puts(hex(buf, size));
    fast_heap_stats(total, used, largest);
    uart0_hw_puts(" DTCM ");
    uart0_hw_puts(hex(buf, used));
    uart0_hw_puts("/");
    uart0_hw_puts(hex(buf, total));
    sram_heap_stats(total, used, largest);
    uart0_hw_puts(" SRAM ");
    uart0_hw_puts(hex(buf, used));
    uart0_hw_puts("/");
    uart0_hw_puts(hex(buf, total));
    uart0_hw_puts(" sp ");
    uart0_hw_puts(hex(buf, cast(size_t)&buf[0]));
    uart0_hw_puts("\r\n");
}

const(char)[] hex(return ref char[16] buf, size_t value)
{
    size_t i = buf.length;
    do
    {
        buf[--i] = "0123456789abcdef"[value & 15];
        value >>= 4;
    }
    while (value);
    return buf[i .. $];
}
