// MT7621 topology for urt.driver.baremetal.heap: DDR as one cached pool, and a window of it for dma.
module urt.driver.mt7621.heap;

import urt.driver.baremetal.heap : HeapRegion;
import urt.mem.alloc : MemFlags;

@nogc nothrow:

// tlsf_size() at the default FL_INDEX_MAX (30 on 32-bit) and SL_INDEX_COUNT_LOG2=5.
enum size_t tlsf_control_bytes = 3064;
enum MemFlags c_heap_flags = MemFlags.none;

enum ubyte ram = 0, dma = 1;

// =================================================================================================
//  DESIGN DECISION: DMA MEMORY IS ITS OWN FIXED-SIZE POOL, A DDR WINDOW SEEN ONLY THROUGH KSEG1.
// =================================================================================================
//
//  The frame engine is not coherent with the 1004Kc L1 or the L2. mt7621.ld reserves _dma_size at
//  the top of DDR and exports it only by its KSEG1 (uncached) address, so no cache line ever holds
//  any of it: dma blocks need no flush on allocation, no padding to whole cache lines, and no
//  pointer translation on free. dma_window_init() drops whatever the bootloader left cached over
//  the window before the first allocation touches it.
//
//  REJECTED: one pool, with dma handed out as the KSEG1 alias of a cache-line-rounded block that is
//  written back and invalidated on allocation. It needs no partition, but the shared heap core
//  would have to translate between the two aliases on every free, realloc and ownership lookup,
//  and every dma allocation pays for whole 32-byte lines.
//
//  TRADEOFF: THE WINDOW IS A HARD PARTITION. A dma allocation fails once the window is full, even
//  with DDR to spare, and ordinary allocations reach the window only when DDR is exhausted. Every
//  MemFlags.dma user lands here, including urt.mem.pagepool's packet slabs, so the pagepool's
//  pages are uncached on this platform. 4 MB against about 0.5 MB of demand when this was
//  written (frame engine rings and buffers, default pagepool caps). Grow _dma_size in mt7621.ld
//  if dma demand grows.
//
// =================================================================================================
static immutable HeapRegion[2] heap_regions = [
    HeapRegion(&__heap_start, &__heap_end, "RAM"),
    HeapRegion(&__dma_heap_start, &__dma_heap_end, "DMA"),
];

static immutable ubyte[8] pool_by_flags = [ram, ram, ram, ram, dma, dma, dma, dma];

// Runs before anything allocates: a dirty line written back later would land on live dma memory.
void dma_window_init()
{
    import urt.driver.mt7621.cache : cached_alias, dcache_writeback_invalidate;

    dcache_writeback_invalidate(cached_alias(cast(void*)&__dma_heap_start), &__dma_heap_end - &__dma_heap_start);
}


private:

extern(C) extern immutable(ubyte) __heap_start, __heap_end;
extern(C) extern immutable(ubyte) __dma_heap_start, __dma_heap_end;


unittest
{
    import urt.driver.mt7621.cache : is_uncached;
    import urt.mem.alloc : alloc, default_alignment, free, realloc;

    void[] a = alloc(40, MemFlags.dma);
    assert(is_uncached(a.ptr) && a.ptr >= &__dma_heap_start && a.ptr + a.length <= &__dma_heap_end);
    foreach (i, ref b; cast(ubyte[])a)
        b = cast(ubyte)(i * 7 + 1);

    a = realloc(a, 200, default_alignment, MemFlags.dma);
    assert(is_uncached(a.ptr));
    foreach (i, b; (cast(ubyte[])a)[0 .. 40])
        assert(b == cast(ubyte)(i * 7 + 1));
    free(a);
}
