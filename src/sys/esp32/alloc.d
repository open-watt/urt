module sys.esp32.alloc;

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
    void* p = heap_caps_aligned_alloc(alignment, size, _esp_caps[flags]);
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

enum CAP_DMA      = 1 << 2;
enum CAP_INTERNAL = 1 << 11;
enum CAP_DEFAULT  = 1 << 12;
enum CAP_SPIRAM   = 1 << 17;
enum CAP_RTCRAM   = 1 << 10;

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
