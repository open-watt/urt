// RP2350 topology for urt.driver.baremetal.heap: one pool over the whole of SRAM.
module urt.driver.rp2350.heap;

import urt.driver.baremetal.heap : HeapRegion;
import urt.mem.alloc : MemFlags;

@nogc nothrow:

// Matches TLSF_FL_INDEX_MAX=20 with TLSF's default SL_INDEX_COUNT_LOG2=5 and 8-byte alignment.
enum size_t tlsf_control_bytes = 1744;
enum MemFlags c_heap_flags = MemFlags.none;

static immutable HeapRegion[1] heap_regions = [
    HeapRegion(&__heap_start, &__heap_end, "SRAM"),
];

// No data cache in front of SRAM, and every bus master reaches all of it: dma needs no pool of its own.
static immutable ubyte[8] pool_by_flags = [0, 0, 0, 0, 0, 0, 0, 0];

private extern(C) extern immutable(ubyte) __heap_start, __heap_end;
