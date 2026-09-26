// BK7231 heap: the raw OOM report both variants use, and the BK7231N topology for
// urt.driver.baremetal.heap: DTCM leftover (fast) and SRAM (dma).
module urt.driver.bk7231.heap;

import urt.mem.alloc : MemFlags;

@nogc nothrow:

// Straight to the UART: the logger may itself allocate.
void write_oom(size_t size, size_t dtcm_used, size_t dtcm_total, size_t sram_used, size_t sram_total)
{
    import urt.driver.bk7231.uart : uart0_hw_puts;

    char[16] buf = void;
    uart0_hw_puts("\r\nOOM: alloc ");
    uart0_hw_puts(hex(buf, size));
    uart0_hw_puts(" DTCM ");
    uart0_hw_puts(hex(buf, dtcm_used));
    uart0_hw_puts("/");
    uart0_hw_puts(hex(buf, dtcm_total));
    uart0_hw_puts(" SRAM ");
    uart0_hw_puts(hex(buf, sram_used));
    uart0_hw_puts("/");
    uart0_hw_puts(hex(buf, sram_total));
    uart0_hw_puts(" sp ");
    uart0_hw_puts(hex(buf, cast(size_t)&buf[0]));
    uart0_hw_puts("\r\n");
}

private const(char)[] hex(return ref char[16] buf, size_t value)
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

version (BK7231N):

import urt.driver.baremetal.heap : HeapRegion, PoolStats, query_pool_stats;

// Matches TLSF_FL_INDEX_MAX=18, TLSF_SL_INDEX_COUNT_LOG2=4 from platforms.mk.
enum size_t tlsf_control_bytes = 912;

// Vendor C and FreeRTOS allocations stay out of DTCM, which the D side wants for hot data.
enum MemFlags c_heap_flags = MemFlags.dma;

enum ubyte dtcm = 0, sram = 1;

static immutable HeapRegion[2] heap_regions = [
    HeapRegion(&_fast_heap_start, &_fast_heap_end, "DTCM"),
    HeapRegion(&__heap_start, &__heap_end, "SRAM"),
];

static immutable ubyte[8] pool_by_flags = [dtcm, dtcm, dtcm, dtcm, sram, sram, sram, sram];

void report_oom(size_t size, size_t, MemFlags)
{
    PoolStats d, s;
    query_pool_stats(dtcm, d);
    query_pool_stats(sram, s);
    write_oom(size, d.used, d.total, s.used, s.total);
}


private:

extern(C) extern immutable(ubyte) _fast_heap_start, _fast_heap_end;
extern(C) extern immutable(ubyte) __heap_start, __heap_end;
