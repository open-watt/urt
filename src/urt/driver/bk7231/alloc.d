module urt.driver.bk7231.alloc;

import urt.mem.alloc : MemFlags;

nothrow @nogc:

version (BK7231N)
{
    public import urt.driver.baremetal.heap;
    import urt.driver.bk7231.heap : sram;

    // The vendor SDK allocates through FreeRTOS and newlib's reentrant entry points.
    extern(C) void* pvPortMalloc(size_t size) => malloc(size ? size : uint.sizeof);
    extern(C) void vPortFree(void* ptr) { free(ptr); }
    extern(C) void* pvPortRealloc(void* ptr, size_t size) => realloc(ptr, size);

    extern(C) size_t xPortGetFreeHeapSize()
    {
        PoolStats s;
        query_pool_stats(sram, s);
        return s.total - s.used;
    }

    extern(C) size_t xPortGetMinimumEverFreeHeapSize()
    {
        PoolStats s;
        query_pool_stats(sram, s);
        return s.total - s.peak_used;
    }

    extern(C) void* _malloc_r(void*, size_t size) => malloc(size);
    extern(C) void _free_r(void*, void* ptr) { free(ptr); }
    extern(C) void* _calloc_r(void*, size_t count, size_t size) => calloc(count, size);
    extern(C) void* _realloc_r(void*, void* ptr, size_t size) => realloc(ptr, size);
}
else
{
    import urt.sync.critical : Critical;

    enum size_t min_alignment = 8;

    enum has_realloc = false;
    enum has_expand = false;
    enum has_memsize = false;
    enum has_exec = false;
    enum has_retain = false;
    enum has_memflags = false;

    void[] _alloc(size_t size, size_t alignment, MemFlags) pure
    {
        alias AllocFn = void[] function(size_t, size_t) pure nothrow @nogc;
        return (cast(AllocFn)&picolibc_alloc_impl)(size, alignment);
    }

    void _free(void* ptr) pure
    {
        alias FreeFn = void function(void*) pure nothrow @nogc;
        (cast(FreeFn)&picolibc_free_impl)(ptr);
    }

    void _alloc_failure(size_t size, size_t, MemFlags) pure
    {
        alias ReportFn = void function(size_t) pure nothrow @nogc;
        (cast(ReportFn)&report_oom)(size);
    }

    void sram_heap_stats(out size_t total, out size_t used, out size_t peak_used, out size_t largest_free)
    {
        auto guard = _lock.acquire();
        size_t start = cast(size_t)&__heap_start;
        total = cast(size_t)&__heap_end - start;
        void* current = sbrk(0);
        used = current > cast(void*)start ? cast(size_t)current - start : 0;
        peak_used = used;
        largest_free = total - used;
    }

    extern(C) void* pvPortMalloc(size_t size)
    {
        auto guard = _lock.acquire();
        return malloc(size ? size : uint.sizeof);
    }

    extern(C) void vPortFree(void* ptr)
    {
        if (!ptr)
            return;
        auto guard = _lock.acquire();
        free(ptr);
    }

    extern(C) void* pvPortRealloc(void* ptr, size_t size)
    {
        if (!ptr)
            return pvPortMalloc(size);
        if (!size)
        {
            vPortFree(ptr);
            return null;
        }
        auto guard = _lock.acquire();
        return realloc(ptr, size);
    }

    extern(C) size_t xPortGetFreeHeapSize()
    {
        size_t total, used, peak, largest;
        sram_heap_stats(total, used, peak, largest);
        return total - used;
    }

    extern(C) size_t xPortGetMinimumEverFreeHeapSize()
    {
        size_t total, used, peak, largest;
        sram_heap_stats(total, used, peak, largest);
        return total - peak;
    }

    private:

    __gshared Critical _lock;

    extern(C) extern const ubyte __heap_start, __heap_end;

    extern(C) void* malloc(size_t size) pure;
    extern(C) void free(void* ptr) pure;
    extern(C) void* realloc(void* ptr, size_t size) pure;
    extern(C) void* sbrk(ptrdiff_t increment) pure;

    void[] picolibc_alloc_impl(size_t size, size_t alignment)
    {
        import urt.util : align_up, max;

        static if (min_alignment < (void*).sizeof)
        {
            if (alignment < (void*).sizeof)
                alignment = (void*).sizeof;
        }
        auto guard = _lock.acquire();
        void* allocation = malloc(max(alignment, min_alignment) + size);
        if (!allocation)
            return null;

        size_t address = align_up(cast(size_t)allocation + min_alignment, alignment);
        (cast(void**)address)[-1] = allocation;
        return (cast(void*)address)[0 .. size];
    }

    void picolibc_free_impl(void* ptr)
    {
        auto guard = _lock.acquire();
        free((cast(void**)ptr)[-1]);
    }

    void report_oom(size_t size)
    {
        import urt.driver.bk7231.heap : write_oom;

        size_t total, used, peak, largest;
        sram_heap_stats(total, used, peak, largest);
        write_oom(size, 0, 0, used, total);
    }
}
