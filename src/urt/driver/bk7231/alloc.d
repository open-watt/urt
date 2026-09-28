module urt.driver.bk7231.alloc;

public import urt.driver.baremetal.heap;
import urt.driver.bk7231.heap : sram;

nothrow @nogc:

// The vendor SDK allocates through FreeRTOS's entry points.
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
