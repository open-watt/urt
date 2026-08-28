module urt.mem.pagepool;

version (Tiny) {} else
    version = PagePoolDiagnostics;

version (Tiny)
{
    import urt.mem.pagepool_tiny;

    alias Pool = PagePool!(320, 64, 4, 1600, 32, 2);

    alias page_pool_init     = Pool.page_pool_init;
    alias page_alloc_for     = Pool.page_alloc_for;
    alias page_adopt         = Pool.page_adopt;
    alias page_free          = Pool.page_free;
    alias page_category      = Pool.page_category;
    alias page_payload_size  = Pool.page_payload_size;
    alias page_pool_trim     = Pool.page_pool_trim;
    alias page_pool_deinit   = Pool.page_pool_deinit;

    unittest
    {
        page_pool_tiny_test!()();
    }
}
else
{

import urt.mem.alloc;
import urt.mem.reclaim;
import urt.sync.critical;

nothrow @nogc:


// Bucketed page pool: fixed-size pages in a few size categories, carved from slabs.
// Allocation prefers the most-occupied slab so lightly-used slabs drain to fully-idle
// and can be returned to the heap; the pool registers itself as a memory reclaimer.
// Requests beyond the largest category get a heap-backed page with the same header,
// so page_free() is uniform. Pop/push run under a Critical; slab allocation and
// release always happen outside it.

enum max_page_categories = 4;
enum ubyte page_category_heap = 0xFF;

struct PageHeader
{
    PageHeader* next;       // freelist link; reserved as a chain link for in-use pages
    uint slab_offset;       // pool page: bytes back to the SlabHeader; heap-backed: total block size
    ubyte category;
    ubyte flags;
    ushort refcount;        // reserved; pages are single-owner for now
}
enum page_header_size = (PageHeader.sizeof + 15) & ~15;

enum ubyte page_flag_heap = 0x01;

struct PageCategoryConfig
{
    uint page_size;         // total bytes per page, including header; multiple of 16
    ushort pages_per_slab;
    ushort max_slabs;       // hard cap; allocation past this fails
    ushort prealloc_slabs;  // floor kept resident through trim
}

struct PagePoolStats
{
    uint pages_in_use;
    uint pages_free;
    uint slab_count;
    uint high_water;        // peak pages_in_use
    ulong alloc_count;
    ulong fail_count;
    ulong[8] size_histogram;    // page_alloc_for() requests: <=64, <=128, ... <=4096, larger
}


// Categories must be given in ascending page_size order. Idempotent; returns false if
// the pool is already initialised or its reclaimer cannot be registered.
bool page_pool_init()
{
    static immutable PageCategoryConfig[2] defaults = [
        { page_size:  320 + page_header_size, pages_per_slab: 8, max_slabs: 8, prealloc_slabs: 1 },
        { page_size: 1600 + page_header_size, pages_per_slab: 4, max_slabs: 8, prealloc_slabs: 1 },
    ];
    return page_pool_init(defaults[]);
}

bool page_pool_init(const(PageCategoryConfig)[] categories)
{
    assert(categories.length > 0 && categories.length <= max_page_categories);

    {
        auto guard = _lock.acquire();
        if (_num_categories != 0)
            return false;

        foreach (i, ref cfg; categories)
        {
            assert(cfg.page_size % 16 == 0 && cfg.page_size > page_header_size);
            assert(cfg.pages_per_slab > 0 && cfg.max_slabs > 0);
            assert(cfg.prealloc_slabs <= cfg.max_slabs);
            assert(i == 0 || cfg.page_size > categories[i - 1].page_size);
            _categories[i].cfg = cfg;
        }
        _num_categories = cast(uint)categories.length;
    }

    if (!register_reclaimer(&trim_handler, 200, true))
    {
        auto guard = _lock.acquire();
        foreach (ref c; _categories[0 .. _num_categories])
            c = Category();
        _num_categories = 0;
        return false;
    }

    foreach (i; 0 .. categories.length)
    {
        foreach (s; 0 .. categories[i].prealloc_slabs)
        {
            if (!add_slab(&_categories[i]))
                break;
        }
    }

    return true;
}

void[] page_alloc(ubyte category)
{
    assert(category < _num_categories);
    Category* c = &_categories[category];

    for (;;)
    {
        {
            auto guard = _lock.acquire();

            SlabHeader* best = null;
            for (SlabHeader* s = c.slabs; s; s = s.next)
            {
                if (s.free_count != 0 && (!best || s.free_count < best.free_count))
                    best = s;
            }
            if (best)
            {
                PageHeader* p = best.free_list;
                best.free_list = p.next;
                --best.free_count;
                p.next = null;
                p.flags = 0;
                p.refcount = 0;

                ++c.stats.alloc_count;
                --c.stats.pages_free;
                if (++c.stats.pages_in_use > c.stats.high_water)
                    c.stats.high_water = c.stats.pages_in_use;
                return payload_of(p, c.cfg.page_size);
            }
            if (c.stats.slab_count >= c.cfg.max_slabs)
            {
                ++c.stats.fail_count;
                return null;
            }
        }

        if (!add_slab(c))
        {
            auto guard = _lock.acquire();
            ++c.stats.fail_count;
            return null;
        }
    }
}

// Smallest category whose payload fits `bytes`; beyond the largest, a heap-backed
// page. A capped-out category escalates to the next (still cap-bounded); an in-range
// request never falls through to the heap, so the caps stay meaningful under flood.
void[] page_alloc_for(size_t bytes)
{
    ubyte cat = ubyte.max;
    uint num_categories;
    {
        auto guard = _lock.acquire();
        num_categories = _num_categories;
        foreach (i; 0 .. _num_categories)
        {
            if (bytes <= _categories[i].cfg.page_size - page_header_size)
            {
                cat = cast(ubyte)i;
                ++_categories[i].stats.size_histogram[histogram_bucket(bytes)];
                break;
            }
        }
    }
    if (cat != ubyte.max)
    {
        foreach (i; cat .. num_categories)
        {
            void[] r = page_alloc(cast(ubyte)i);
            if (r)
                return r[0 .. bytes];
        }
        // capped out; the heap carries the overflow below
    }

    size_t block_size = page_header_size + bytes;
    void[] mem = alloc(block_size, 16);
    if (!mem.ptr)
    {
        auto guard = _lock.acquire();
        ++_jumbo_stats.fail_count;
        return null;
    }
    PageHeader* h = cast(PageHeader*)mem.ptr;
    h.next = null;
    h.slab_offset = cast(uint)block_size;
    h.category = page_category_heap;
    h.flags = page_flag_heap;
    h.refcount = 0;

    {
        auto guard = _lock.acquire();
        ++_jumbo_stats.alloc_count;
        ++_jumbo_stats.size_histogram[histogram_bucket(bytes)];
        if (++_jumbo_stats.pages_in_use > _jumbo_stats.high_water)
            _jumbo_stats.high_water = _jumbo_stats.pages_in_use;
    }
    return (mem.ptr + page_header_size)[0 .. bytes];
}

// The returned slice is the only handle; the caller reserves page_header_size ahead of it.
void[] page_adopt(void[] block)
{
    if (block.length <= page_header_size || (cast(size_t)block.ptr & 15) != 0)
        return null;

    PageHeader* h = cast(PageHeader*)block.ptr;
    h.next = null;
    h.slab_offset = cast(uint)block.length;
    h.category = page_category_heap;
    h.flags = page_flag_heap;
    h.refcount = 0;

    const size_t payload = block.length - page_header_size;
    {
        auto guard = _lock.acquire();
        ++_jumbo_stats.alloc_count;
        ++_jumbo_stats.size_histogram[histogram_bucket(payload)];
        if (++_jumbo_stats.pages_in_use > _jumbo_stats.high_water)
            _jumbo_stats.high_water = _jumbo_stats.pages_in_use;
    }
    return (block.ptr + page_header_size)[0 .. payload];
}

void page_free(void* payload)
{
    PageHeader* h = header_of(payload);
    if (h.flags & page_flag_heap)
    {
        size_t block_size = h.slab_offset;
        {
            auto guard = _lock.acquire();
            --_jumbo_stats.pages_in_use;
        }
        free((cast(void*)h)[0 .. block_size]);
        return;
    }

    assert(h.category < _num_categories);
    Category* c = &_categories[h.category];
    SlabHeader* slab = cast(SlabHeader*)(cast(void*)h - h.slab_offset);

    auto guard = _lock.acquire();
    h.next = slab.free_list;
    slab.free_list = h;
    ++slab.free_count;
    --c.stats.pages_in_use;
    ++c.stats.pages_free;
}

ubyte page_category(const(void)* payload)
    => header_of(payload).category;

size_t page_payload_size(ubyte category)
{
    assert(category < _num_categories);
    return _categories[category].cfg.page_size - page_header_size;
}

// Release one fully-idle slab above its category's prealloc floor back to the heap.
ReclaimResult page_pool_trim(size_t bytes_needed = size_t.max)
{
    foreach (i; 0 .. _num_categories)
    {
        Category* c = &_categories[i];
        SlabHeader* release;
        bool more;

        {
            auto guard = _lock.acquire();
            SlabHeader** link = &c.slabs;
            while (*link)
            {
                SlabHeader* s = *link;
                if (s.free_count == s.page_count && c.stats.slab_count > c.cfg.prealloc_slabs)
                {
                    *link = s.next;
                    --c.stats.slab_count;
                    c.stats.pages_free -= s.page_count;
                    release = s;
                    more = has_reclaimable_slab_locked();
                    break;
                }
                link = &s.next;
            }
        }

        if (release)
        {
            free((cast(void*)release)[0 .. slab_bytes(c.cfg)]);
            return more ? ReclaimResult.more : ReclaimResult.exhausted;
        }
    }
    return ReclaimResult.exhausted;
}

PagePoolStats page_pool_stats(ubyte category)
{
    auto guard = _lock.acquire();
    if (category == page_category_heap)
        return _jumbo_stats;
    assert(category < _num_categories);
    return _categories[category].stats;
}

uint page_pool_num_categories()
    => _num_categories;

// Releases all slabs and returns the pool to its uninitialised state. No page may be
// in use. Primarily for tests and orderly shutdown.
void page_pool_deinit()
{
    if (_num_categories == 0)
        return;
    unregister_reclaimer(&trim_handler);
    foreach (i; 0 .. _num_categories)
    {
        Category* c = &_categories[i];
        assert(c.stats.pages_in_use == 0, "Page pool deinit with pages in use!");
        SlabHeader* s = c.slabs;
        while (s)
        {
            SlabHeader* n = s.next;
            free((cast(void*)s)[0 .. slab_bytes(c.cfg)]);
            s = n;
        }
        *c = Category();
    }
    _num_categories = 0;
    _jumbo_stats = PagePoolStats();
}


private:

struct SlabHeader
{
    SlabHeader* next;
    PageHeader* free_list;
    ushort free_count;
    ushort page_count;
}
enum slab_header_size = (SlabHeader.sizeof + 15) & ~15;

struct Category
{
    SlabHeader* slabs;
    PageCategoryConfig cfg;
    PagePoolStats stats;
}

__gshared Critical _lock;
__gshared Category[max_page_categories] _categories;
__gshared uint _num_categories;
__gshared PagePoolStats _jumbo_stats;

bool has_reclaimable_slab_locked()
{
    foreach (ref c; _categories[0 .. _num_categories])
    {
        if (c.stats.slab_count > c.cfg.prealloc_slabs)
        {
            SlabHeader* s = c.slabs;
            while (s)
            {
                if (s.free_count == s.page_count)
                    return true;
                s = s.next;
            }
        }
    }
    return false;
}

size_t slab_bytes(ref const PageCategoryConfig cfg)
    => slab_header_size + cfg.page_size * cfg.pages_per_slab;

PageHeader* header_of(const(void)* payload)
    => cast(PageHeader*)(payload - page_header_size);

void[] payload_of(PageHeader* h, uint page_size)
    => (cast(void*)h + page_header_size)[0 .. page_size - page_header_size];

size_t histogram_bucket(size_t bytes)
{
    size_t bucket = 0;
    size_t threshold = 64;
    while (bytes > threshold && bucket < 7)
    {
        threshold <<= 1;
        ++bucket;
    }
    return bucket;
}

// Allocates and carves a slab OUTSIDE the pool lock, then links it in; if a concurrent
// refill won the race to the cap, the extra slab is released (again outside the lock).
bool add_slab(Category* c)
{
    size_t bytes = slab_bytes(c.cfg);
    void[] mem = alloc(bytes, 16);
    if (!mem.ptr)
        return false;

    SlabHeader* slab = cast(SlabHeader*)mem.ptr;
    slab.next = null;
    slab.page_count = c.cfg.pages_per_slab;
    slab.free_count = c.cfg.pages_per_slab;

    PageHeader* prev = null;
    ubyte category = cast(ubyte)(c - _categories.ptr);
    foreach_reverse (i; 0 .. c.cfg.pages_per_slab)
    {
        uint offset = cast(uint)(slab_header_size + i * c.cfg.page_size);
        PageHeader* p = cast(PageHeader*)(mem.ptr + offset);
        p.next = prev;
        p.slab_offset = offset;
        p.category = category;
        p.flags = 0;
        p.refcount = 0;
        prev = p;
    }
    slab.free_list = prev;

    {
        auto guard = _lock.acquire();
        if (c.stats.slab_count < c.cfg.max_slabs)
        {
            slab.next = c.slabs;
            c.slabs = slab;
            ++c.stats.slab_count;
            c.stats.pages_free += slab.page_count;
            return true;
        }
    }
    free(mem);
    return true;    // the cap was reached by someone else; a page is available
}

ReclaimResult trim_handler(size_t bytes_needed)
    => page_pool_trim(bytes_needed);


unittest
{
    static immutable PageCategoryConfig[2] test_cfg = [
        PageCategoryConfig(64, 4, 2, 1),
        PageCategoryConfig(256, 2, 2, 0),
    ];

    static void* slab_of(void* payload)
    {
        PageHeader* h = header_of(payload);
        return cast(void*)h - h.slab_offset;
    }

    // another module's test may have lazily initialised the pool already; start clean
    // (deinit asserts nothing is still in use, which doubles as a leak check)
    page_pool_deinit();

    assert(page_pool_init(test_cfg));
    assert(!page_pool_init(test_cfg));
    assert(page_pool_num_categories() == 2);
    assert(page_payload_size(0) == 64 - page_header_size);

    // prealloc: category 0 has one resident slab
    PagePoolStats s = page_pool_stats(0);
    assert(s.slab_count == 1 && s.pages_free == 4 && s.pages_in_use == 0);

    // round-trip + category lookup
    void[] a = page_alloc(0);
    assert(a.length == 64 - page_header_size);
    assert(page_category(a.ptr) == 0);
    s = page_pool_stats(0);
    assert(s.pages_in_use == 1 && s.alloc_count == 1 && s.high_water == 1);
    page_free(a.ptr);
    s = page_pool_stats(0);
    assert(s.pages_in_use == 0 && s.pages_free == 4);

    // exhaustion: 2 slabs * 4 pages, then fail
    void[][8] pages;
    foreach (i; 0 .. 8)
    {
        pages[i] = page_alloc(0);
        assert(pages[i] !is null);
    }
    assert(page_alloc(0) is null);
    s = page_pool_stats(0);
    assert(s.slab_count == 2 && s.fail_count == 1 && s.high_water == 8);

    // packing: with both slabs idle, sequential allocs must all land in the same slab
    // (first alloc breaks the tie, the partially-used slab is then preferred)
    foreach (i; 0 .. 8)
        page_free(pages[i].ptr);
    void[] keep = page_alloc(0);
    foreach (i; 0 .. 3)
    {
        void[] p = page_alloc(0);
        assert(slab_of(p.ptr) is slab_of(keep.ptr));
        pages[i] = p;
    }
    void[] other = page_alloc(0);
    assert(slab_of(other.ptr) !is slab_of(keep.ptr));
    foreach (i; 0 .. 3)
        page_free(pages[i].ptr);
    page_free(other.ptr);

    // trim: the now fully-idle slab (above the prealloc floor of 1) gets released;
    // the slab holding `keep` survives
    assert(page_pool_trim(slab_header_size + 64 * 4) == ReclaimResult.exhausted);
    s = page_pool_stats(0);
    assert(s.slab_count == 1 && s.pages_in_use == 1);
    page_free(keep.ptr);

    // size-class selection + jumbo
    void[] small = page_alloc_for(32);
    assert(small.length == 32 && page_category(small.ptr) == 0);
    void[] mid = page_alloc_for(100);
    assert(page_category(mid.ptr) == 1);
    void[] jumbo = page_alloc_for(1000);
    assert(jumbo.length == 1000 && page_category(jumbo.ptr) == page_category_heap);
    PagePoolStats js = page_pool_stats(page_category_heap);
    assert(js.pages_in_use == 1 && js.alloc_count == 1);
    page_free(jumbo.ptr);
    js = page_pool_stats(page_category_heap);
    assert(js.pages_in_use == 0);
    page_free(mid.ptr);
    page_free(small.ptr);

    // reclaimer is registered: an explicit walk trims the pool (nothing idle now
    // above floors, so this just proves the plumbing runs)
    import urt.mem.reclaim : reclaim_memory;
    reclaim_memory(1);

    page_pool_deinit();
    assert(page_pool_num_categories() == 0);
    assert(page_pool_init(test_cfg));
    page_pool_deinit();

    static ReclaimResult fill_reclaimer(size_t id)(size_t)
        => ReclaimResult.exhausted;

    ReclaimFunction[8] fillers = [
        &fill_reclaimer!0, &fill_reclaimer!1,
        &fill_reclaimer!2, &fill_reclaimer!3,
        &fill_reclaimer!4, &fill_reclaimer!5,
        &fill_reclaimer!6, &fill_reclaimer!7,
    ];
    foreach (handler; fillers)
        assert(register_reclaimer(handler, 1, true));
    assert(!page_pool_init(test_cfg));
    assert(page_pool_num_categories() == 0);
    foreach (handler; fillers)
        assert(unregister_reclaimer(handler));
    assert(page_pool_init(test_cfg));
    page_pool_deinit();
}
}
