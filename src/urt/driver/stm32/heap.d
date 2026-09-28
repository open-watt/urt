// Default allocations take system SRAM (AXI on H7) and MemFlags.fastest the rest of CCM or DTCM.
// F4/F7 serve dma from system SRAM; H7 keeps its uncached SRAM1-3 for dma alone.
module urt.driver.stm32.heap;

import urt.driver.baremetal.heap : HeapRegion;
import urt.mem.alloc : MemFlags;

@nogc nothrow:

// Matches TLSF_FL_INDEX_MAX=20 with TLSF's default SL_INDEX_COUNT_LOG2=5 and 8-byte alignment.
enum size_t tlsf_control_bytes = 1744;
enum MemFlags c_heap_flags = MemFlags.none;

version (STM32H7)
{
    enum ubyte core = 0, bulk = 1, dma = 2;

    static immutable HeapRegion[3] heap_regions = [
        HeapRegion(&__core_heap_start, &__core_heap_end, "DTCM"),
        HeapRegion(&__bulk_heap_start, &__bulk_heap_end, "AXI"),
        HeapRegion(&__dma_heap_start, &__dma_heap_end, "SRAM"),
    ];
    static immutable ubyte[8] pool_by_flags = [bulk, bulk, bulk, core, dma, dma, dma, dma];

    private extern(C) extern immutable(ubyte) __dma_heap_start, __dma_heap_end;
}
else
{
    enum ubyte core = 0, bulk = 1;

    version (STM32F4) private enum core_name = "CCM";
    else              private enum core_name = "DTCM";

    static immutable HeapRegion[2] heap_regions = [
        HeapRegion(&__core_heap_start, &__core_heap_end, core_name),
        HeapRegion(&__bulk_heap_start, &__bulk_heap_end, "SRAM"),
    ];
    static immutable ubyte[8] pool_by_flags = [bulk, bulk, bulk, core, bulk, bulk, bulk, bulk];
}

private extern(C) extern immutable(ubyte) __core_heap_start, __core_heap_end;
private extern(C) extern immutable(ubyte) __bulk_heap_start, __bulk_heap_end;
