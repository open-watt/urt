module urt.mem.alloc;

import urt.mem;

nothrow @nogc:


enum MemFlags : ubyte
{
    none     = 0,

    fast     = 1,   // internal SRAM, lowest latency
    slow     = 2,   // external PSRAM, bulk storage
    fastest  = 3,   // TCM / tightly-coupled, single cycle

    dma      = 0x4, // DMA-accessible
}

MemFlags mem_speed(MemFlags flags) pure => cast(MemFlags)(flags & 3);
bool mem_is_dma(MemFlags flags) pure => (flags & MemFlags.dma) != 0;


void[] alloc(size_t size, MemFlags flags = MemFlags.none) pure
    => alloc(size, size_t.sizeof, flags);

void[] alloc(size_t size, size_t alignment, MemFlags flags = MemFlags.none) pure
{
    import urt.util : is_power_of_2;

    assert(is_power_of_2(alignment), "Alignment must be a power of two!");

    return _alloc(size, alignment, flags);
}

void[] realloc(void[] mem, size_t new_size, size_t alignment = 8, MemFlags flags = MemFlags.none) pure
{
    import urt.util : min;

    if (new_size == 0)
    {
        free(mem);
        return null;
    }
    if (mem.ptr is null)
        return alloc(new_size, alignment, flags);

    static if (has_realloc)
        return _realloc(mem, new_size, alignment, flags);
    else
    {
        void[] new_mem = alloc(new_size, alignment, flags);
        if (new_mem.ptr !is null)
        {
            size_t copy = min(mem.length, new_size);
            new_mem[0 .. copy] = mem[0 .. copy];
        }
        free(mem);
        return new_mem;
    }
}

void free(void[] mem) pure
{
    if (mem.ptr is null)
        return;
    _free(mem.ptr);
}

void[] expand(void[] mem, size_t new_size) pure
{
    if (mem.ptr is null)
        return null;
    static if (has_expand)
        return _expand(mem, new_size);
    else static if (has_memsize)
    {
        if (new_size <= _memsize(mem.ptr))
            return mem.ptr[0 .. new_size];
        return null;
    }
    else
        assert(false, "unsupported");
}

size_t memsize(void* ptr) pure
{
    if (ptr is null)
        return 0;
    static if (has_memsize)
        return _memsize(ptr);
    else
        assert(false, "unsupported");
}

void[] alloc_exec(size_t size) pure
{
    static if (has_exec)
        return _alloc_exec(size);
    else
        return null;
}

void free_exec(void[] mem) pure
{
    static if (has_exec)
    {
        if (mem.ptr !is null)
            _free_exec(mem);
    }
}

void[] alloc_retain(size_t size) pure
{
    static if (has_retain)
        return _alloc_retain(size);
    else
        return null;
}

void free_retain(void[] mem) pure
{
    static if (has_retain)
    {
        if (mem.ptr !is null)
            _free_retain(mem);
    }
}


// pointer tagging utilities -- for containers to store flags in low 3 bits
// of 8-byte aligned pointers. the allocator itself returns clean pointers.
T* tag(T)(T* ptr, MemFlags flags) pure
    => cast(T*)(cast(size_t)ptr | flags);

T* untag(T)(T* ptr) pure
    => cast(T*)(cast(size_t)ptr & ~cast(size_t)0x7);

MemFlags get_flags(void* ptr) pure
    => cast(MemFlags)(cast(size_t)ptr & 0x7);


version (Espressif)
    public import sys.esp32.alloc;
else version (BL808_M0)
    public import sys.bl618.alloc;
else version (BL808)
    public import sys.bl808.alloc;
else version (BL618)
    public import sys.bl618.alloc;
else version (RP2350)
    public import sys.rp2350.alloc;
else version (BK7231N)
    public import sys.bk7231.alloc;
else version (BK7231T)
    public import sys.bk7231.alloc;
else version (STM32F4)
    public import sys.stm32.alloc;
else version (STM32F7)
    public import sys.stm32.alloc;
else version (Windows)
    public import sys.windows.alloc;
else version (Posix)
    public import sys.posix.alloc;
else
    static assert(false, "No alloc driver for this platform");


unittest
{
    // basic alloc/free
    void[] mem = alloc(32, 8);
    assert(mem !is null);
    assert((cast(size_t)mem.ptr & 0x7) == 0); // 8-byte aligned
    assert(mem.length == 32);
    free(mem);

    // alloc with flags (on desktop, flags are ignored but API works)
    mem = alloc(64, 8, MemFlags.fast);
    assert(mem !is null);
    size_t s = memsize(mem.ptr);
    assert(s >= 64);
    free(mem);

    // realloc preserves data
    mem = alloc(16, 8);
    (cast(ubyte*)mem.ptr)[0 .. 16] = 0xAB;
    mem = realloc(mem, 64);
    assert(mem !is null);
    assert((cast(ubyte*)mem.ptr)[0] == 0xAB);
    free(mem);

    // expand
    mem = alloc(16, 8);
    void[] expanded = expand(mem, 8);
    if (expanded !is null)
        assert(expanded.ptr is mem.ptr);
    free(mem);

    // pointer tagging utilities
    void* p = mem.ptr;
    enum test_flags = cast(MemFlags)(MemFlags.fast | MemFlags.dma);
    void* tagged = tag(p, test_flags);
    assert(get_flags(tagged) == test_flags);
    assert(untag(tagged) is p);
}
