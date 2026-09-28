// BK7231 topology for urt.driver.baremetal.heap: DTCM leftover (fast) on BK7231N, and SRAM (dma).
module urt.driver.bk7231.heap;

import urt.driver.baremetal.heap : HeapRegion, PoolStats, query_pool_stats;
import urt.mem.alloc : MemFlags;

@nogc nothrow:

// Matches TLSF_FL_INDEX_MAX=18, TLSF_SL_INDEX_COUNT_LOG2=4 from platforms.mk.
enum size_t tlsf_control_bytes = 912;

// Vendor C and FreeRTOS allocations stay out of DTCM, which the D side wants for hot data.
enum MemFlags c_heap_flags = MemFlags.dma;

version (BK7231N)
{
    enum ubyte dtcm = 0, sram = 1;

    static immutable HeapRegion[2] heap_regions = [
        HeapRegion(&_fast_heap_start, &_fast_heap_end, "DTCM"),
        HeapRegion(&__heap_start, &__heap_end, "SRAM"),
    ];

    static immutable ubyte[8] pool_by_flags = [dtcm, dtcm, dtcm, dtcm, sram, sram, sram, sram];

    private extern(C) extern immutable(ubyte) _fast_heap_start, _fast_heap_end;
}
else
{
    enum ubyte sram = 0;

    static immutable HeapRegion[1] heap_regions = [
        HeapRegion(&__heap_start, &__heap_end, "SRAM"),
    ];

    static immutable ubyte[8] pool_by_flags = [sram, sram, sram, sram, sram, sram, sram, sram];
}

// Straight to the UART: the logger may itself allocate.
void report_oom(size_t size, size_t, MemFlags)
{
    import urt.driver.bk7231.uart : uart0_hw_puts;
    import urt.string : c_string;

    char[16] buf = void;
    uart0_hw_puts("\r\nOOM: alloc ");
    uart0_hw_puts(hex(buf, size));
    foreach (i; 0 .. heap_regions.length)
    {
        PoolStats s;
        query_pool_stats(i, s);
        uart0_hw_puts(" ");
        uart0_hw_puts(s.name.c_string);
        uart0_hw_puts(" ");
        uart0_hw_puts(hex(buf, s.used));
        uart0_hw_puts("/");
        uart0_hw_puts(hex(buf, s.total));
    }
    uart0_hw_puts(" sp ");
    uart0_hw_puts(hex(buf, cast(size_t)&buf[0]));
    uart0_hw_puts("\r\n");
}


private:

extern(C) extern immutable(ubyte) __heap_start, __heap_end;

const(char)[] hex(return ref char[16] buf, size_t value)
{
    size_t i = buf.length;
    do
    {
        buf[--i] = "0123456789abcdef"[value & 15];
        value >>= 4;
    }
    while (value);
    return buf[i .. $];
}
