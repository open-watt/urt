// 1004Kc L1 data cache and the CM-attached L2; DMA on MT7621 is not coherent with either.
module urt.driver.mt7621.cache;

nothrow @nogc:

enum size_t cache_line = 32;

enum uint kseg1_bit = 0x2000_0000;

void* uncached_alias(void* p) => cast(void*)(cast(size_t)p | kseg1_bit);
void* cached_alias(void* p) => cast(void*)(cast(size_t)p & ~kseg1_bit);
bool is_uncached(const void* p) => (cast(size_t)p & 0xE000_0000) == 0xA000_0000;

void dcache_writeback_invalidate(const(void)* p, size_t len)
{
    for (size_t a = cast(size_t)p & ~(cache_line - 1), end = cast(size_t)p + len; a < end; a += cache_line)
        asm nothrow @nogc { ".set push; .set noat; .set mips32r2; cache 0x15, 0(%0); cache 0x17, 0(%0); .set pop" :: "r"(a) : "memory"; }
    asm nothrow @nogc { "sync" ::: "memory"; }
}


unittest
{
    uint config1, config2;
    asm nothrow @nogc { ".set push; .set noat; mfc0 %0, $16, 1; .set pop" : "=r"(config1); }
    asm nothrow @nogc { ".set push; .set noat; mfc0 %0, $16, 2; .set pop" : "=r"(config2); }
    assert(2u << ((config1 >> 10) & 7) == cache_line, "L1 D line size");
    immutable sl = (config2 >> 4) & 0xF;
    assert(sl == 0 || 2u << sl == cache_line, "L2 line size");
}
