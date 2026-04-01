module urt.mem.alloc;

import urt.mem;

nothrow @nogc:


void[] alloc(size_t size) pure
{
    // TODO: pure malloc is meant to copy and restore errno around the call, because that's user-accessible state...

    // TODO: we might pin the length to a debug table somewhere...
    return malloc(size)[0 .. size];
}

void[] realloc(void[] mem, size_t newSize) pure
{
    // TODO: we might pin the length to a debug table somewhere...
    return urt.mem.realloc(mem.ptr, newSize)[0 .. newSize];
}

void free(void[] mem) pure
{
    // maybe check the length passed to free matches the alloc?
    // ... or you know, just don't do that.
    urt.mem.free(mem.ptr);
}

void[] alloc_aligned(size_t size, size_t alignment) pure
{
    import urt.util : align_down, is_power_of_2, max;

    alignment = max(alignment, (void*).sizeof);
    assert(is_power_of_2(alignment), "Alignment must be a power of two!");

    version (Windows)
    {
        void* mem = _aligned_malloc(size, alignment);
        return mem ? mem[0 .. size] : null;
    }
    else version (Posix)
    {
        import urt.internal.sys.posix;
        void* mem;
        return posix_memalign(&mem, alignment, size) ? null : mem[0 .. size];
    }
    else version (FreeStanding)
    {
        size_t header_size = (void*).sizeof + alignment;
        size_t total = header_size + size;

        void* mem = malloc(total);
        if (mem is null)
            return null;

        size_t ptr = cast(size_t)mem;
        size_t allocptr = align_down(ptr + header_size, alignment);
        (cast(void**)allocptr)[-1] = mem;

        return (cast(void*)allocptr)[0 .. size];
    }
    else
        assert(false, "Unsupported platform");
}

void[] realloc_aligned(void[] mem, size_t newSize, size_t alignment) pure
{
    import urt.util : is_power_of_2, min, max;

    alignment = max(alignment, (void*).sizeof);
    assert(is_power_of_2(alignment), "Alignment must be a power of two!");

    void[] newAlloc = newSize > 0 ? alloc_aligned(newSize, alignment) : null;
    if (newAlloc !is null && mem !is null)
    {
        size_t toCopy = min(mem.length, newSize);
        newAlloc[0 .. toCopy] = mem[0 .. toCopy];
    }
    free_aligned(mem);
    return newAlloc;
}

void free_aligned(void[] mem) pure
{
    if (mem.ptr is null)
        return;
    version (Windows)
        _aligned_free(mem.ptr);
    else version (Posix)
        urt.mem.free(mem.ptr);
    else version (FreeStanding)
    {
        void* p = (cast(void**)mem.ptr)[-1];
        urt.mem.free(p);
    }
    else
        assert(false, "Unsupported platform");
}

// NOTE: This function is only compatible with alloc_aligned!
void[] expand(void[] mem, size_t newSize) pure
{
    if (mem.ptr is null)
        return null;
    if (newSize <= memsize(mem.ptr))
        return mem.ptr[0 .. newSize];
    return null;
}

// NOTE: This function is only compatible with alloc_aligned!
size_t memsize(void* ptr) pure
{
    if (ptr is null)
        return 0;
    version (Windows)
        return _aligned_msize(ptr);
    else version (Posix)
        return malloc_usable_size(ptr);
    else version (FreeStanding)
    {
        void* mem = (cast(void**)ptr)[-1];
        size_t offset = cast(size_t)ptr - cast(size_t)mem;
        return malloc_usable_size(mem) - offset;
    }
    else
        assert(false, "Unsupported platform");
}


unittest
{
    void[] mem = alloc_aligned(16, 8);
    assert(mem !is null);
    size_t s = memsize(mem.ptr);
    assert(s >= 16);
    mem = expand(mem, 8);
    assert(mem !is null);
    mem = expand(mem, 16);
    assert(mem !is null);
    free_aligned(mem);
}


version (Windows)
{
    extern(C) void* _aligned_malloc(size_t size, size_t alignment) pure;
    extern(C) void _aligned_free(void* memblock) pure;
    extern(C) size_t _aligned_msize(void* memblock) pure;
}

version (Posix)
{
    extern(C) size_t malloc_usable_size(void *__ptr) pure;
}
else version (FreeStanding)
{
    extern(C) size_t malloc_usable_size(void *__ptr) pure;
}
