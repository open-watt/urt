module urt.driver.bl_common.heap;

import urt.driver.baremetal.heap : HeapRegion;
import urt.mem.alloc : MemFlags;

@nogc nothrow:

// tlsf_size() at the default FL_INDEX_MAX (30 on rv32, 32 on the rv64 D0) and SL_INDEX_COUNT_LOG2=5.
enum size_t tlsf_control_bytes = size_t.sizeof == 8 ? 6536 : 3064;
enum MemFlags c_heap_flags = MemFlags.none;

version (BL808_M0)
{
    enum ubyte dtcm = 0, ocram = 1, psram = 2;

    static immutable HeapRegion[3] heap_regions = [
        HeapRegion(&__dtcm_heap_start, &__dtcm_heap_end, "TCM"),
        HeapRegion(&__ocram_heap_start, &__ocram_heap_end, "SRAM"),
        HeapRegion(&__psram_heap_start, &__psram_heap_end, "PSRAM"),
    ];

    // DMA cannot reach DTCM (CPU-local bus) and PSRAM is not DMA-clean on the E907.
    static immutable ubyte[8] pool_by_flags = [psram, ocram, psram, dtcm, ocram, ocram, ocram, ocram];

    private extern(C) extern immutable(ubyte) __dtcm_heap_start, __dtcm_heap_end;
    private extern(C) extern immutable(ubyte) __ocram_heap_start, __ocram_heap_end;
    private extern(C) extern immutable(ubyte) __psram_heap_start, __psram_heap_end;
}
else version (BL808)
{
    enum ubyte sram = 0, psram = 1;

    static immutable HeapRegion[2] heap_regions = [
        HeapRegion(&__sram_heap_start, &__sram_heap_end, "SRAM"),
        HeapRegion(&__psram_heap_start, &__psram_heap_end, "PSRAM"),
    ];

    // D0 has no DTCM; SRAM is its fastest memory and DMA reaches it from the D0 bus matrix.
    static immutable ubyte[8] pool_by_flags = [psram, sram, psram, sram, sram, sram, sram, sram];

    private extern(C) extern immutable(ubyte) __sram_heap_start, __sram_heap_end;
    private extern(C) extern immutable(ubyte) __psram_heap_start, __psram_heap_end;
}
else version (BL618)
{
    enum ubyte ocram = 0, dma = 1;

    static immutable HeapRegion[2] heap_regions = [
        HeapRegion(&__ocram_heap_start, &__ocram_heap_end, "SRAM"),
        HeapRegion(&__dma_heap_start, &__dma_heap_end, "DMA"),
    ];

    // DMA comes from the non-cache alias; PSRAM is not a pool until bl_psram_init is wired.
    static immutable ubyte[8] pool_by_flags = [ocram, ocram, ocram, ocram, dma, dma, dma, dma];

    private extern(C) extern immutable(ubyte) __ocram_heap_start, __ocram_heap_end;
    private extern(C) extern immutable(ubyte) __dma_heap_start, __dma_heap_end;
}
