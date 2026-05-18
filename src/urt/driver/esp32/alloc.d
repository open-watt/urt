module urt.driver.esp32.alloc;

import urt.mem.alloc : MemFlags;

nothrow @nogc:

enum has_realloc  = false;
enum has_expand   = false;
enum has_memsize  = true;
enum has_exec     = true;
enum has_retain   = true;
enum has_memflags = true;

void[] _alloc(size_t size, size_t alignment, MemFlags flags) pure
{
    uint primary = _esp_caps[flags];
    void* p = heap_caps_aligned_alloc(alignment, size, primary);
    if (p is null)
    {
        // Speed bits are a placement preference, not a requirement -- if the
        // preferred pool can't satisfy, retry against the default heap (which
        // covers all pools). DMA constraint must be preserved.
        uint speed = flags & 3;
        if (speed != 0)
        {
            uint fallback = (flags & MemFlags.dma) ? (CAP_DEFAULT | CAP_DMA) : CAP_DEFAULT;
            if (fallback != primary)
            {
                p = heap_caps_aligned_alloc(alignment, size, fallback);
                if (p !is null)
                {
                    alias LogFn = void function(size_t, size_t, MemFlags) pure nothrow @nogc;
                    (cast(LogFn) &log_alloc_failover)(size, alignment, flags);
                }
            }
        }
        if (p is null)
        {
            alias LogFn = void function(size_t, size_t, MemFlags) pure nothrow @nogc;
            (cast(LogFn) &log_alloc_oom)(size, alignment, flags);
        }
    }
    return p ? p[0 .. size] : null;
}

void _free(void* ptr) pure
{
    heap_caps_aligned_free(ptr);
}

size_t _memsize(void* ptr) pure
{
    return heap_caps_get_allocated_size(ptr);
}

void[] _alloc_exec(size_t size) pure
{
    void* p = heap_caps_aligned_alloc(8, size, CAP_INTERNAL);
    return p ? p[0 .. size] : null;
}

void _free_exec(void[] mem) pure
{
    heap_caps_aligned_free(mem.ptr);
}

void[] _alloc_retain(size_t size) pure
{
    void* p = heap_caps_aligned_alloc(8, size, CAP_RTCRAM);
    return p ? p[0 .. size] : null;
}

void _free_retain(void[] mem) pure
{
    heap_caps_aligned_free(mem.ptr);
}


private:

enum CAP_DMA      = 1 << 3;
enum CAP_SPIRAM   = 1 << 10;
enum CAP_INTERNAL = 1 << 11;
enum CAP_DEFAULT  = 1 << 12;
enum CAP_RTCRAM   = 1 << 15;

// MemFlags [2:0] → ESP-IDF heap_caps
//   [1:0] speed: 0=default, 1=fast, 2=slow, 3=fastest
//   [2]   dma
immutable uint[8] _esp_caps = [
    CAP_DEFAULT,                          // 0: default
    CAP_DEFAULT | CAP_INTERNAL,           // 1: fast
    CAP_DEFAULT | CAP_SPIRAM,             // 2: slow
    CAP_DEFAULT | CAP_INTERNAL,           // 3: fastest (no TCM on ESP32)
    CAP_DEFAULT | CAP_DMA,                // 4: dma
    CAP_DEFAULT | CAP_DMA | CAP_INTERNAL, // 5: dma+fast
    CAP_DEFAULT | CAP_DMA | CAP_SPIRAM,   // 6: dma+slow
    CAP_DEFAULT | CAP_DMA | CAP_INTERNAL, // 7: dma+fastest
];

extern(C) void* heap_caps_aligned_alloc(size_t alignment, size_t size, uint caps) pure;
extern(C) void heap_caps_aligned_free(void* ptr) pure;
extern(C) size_t heap_caps_get_allocated_size(void* ptr) pure;
extern(C) size_t heap_caps_get_free_size(uint caps) pure;
extern(C) size_t heap_caps_get_largest_free_block(uint caps) pure;

void log_alloc_oom(size_t size, size_t alignment, MemFlags flags) nothrow @nogc
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope(exit) reentrant = false;

    import urt.log;
    uint primary = _esp_caps[flags];
    log_error("heap.alloc", "OOM! - size=", size, " align=", alignment, " flags=", cast(int)flags,
              " free=", heap_caps_get_free_size(primary),
              " largest=", heap_caps_get_largest_free_block(primary),
              " default-free=", heap_caps_get_free_size(CAP_DEFAULT),
              " default-largest=", heap_caps_get_largest_free_block(CAP_DEFAULT));
}

void log_alloc_failover(size_t size, size_t alignment, MemFlags flags) nothrow @nogc
{
    __gshared bool reentrant;
    if (reentrant)
        return;
    reentrant = true;
    scope(exit) reentrant = false;

    import urt.log;
    uint primary = _esp_caps[flags];
    log_debug("heap.alloc", "preferred pool full, fail to default - size=", size, " align=", alignment, " flags=", cast(int)flags,
              " free=", heap_caps_get_free_size(primary),
              " largest=", heap_caps_get_largest_free_block(primary));
}
