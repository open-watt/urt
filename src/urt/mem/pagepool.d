module urt.mem.pagepool;

public import urt.mem.page;

version (Tiny) {} else
    version = PagePoolDiagnostics;

version (Tiny)
{
    import urt.mem.pagepool_tiny;

    alias Pool = PagePool!(336, 64, 4, 1616, 32, 2);

    alias page_pool_init     = Pool.page_pool_init;
    alias page_alloc         = Pool.page_alloc;
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


enum max_page_categories = 4;
enum ubyte page_category_heap = 0xFF;

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
    ulong[8] size_histogram;
}


bool page_pool_init()
{
    static immutable PageCategoryConfig[2] defaults = [
        { page_size:  352, pages_per_slab: 8, max_slabs: 8, prealloc_slabs: 1 },
        { page_size: 1632, pages_per_slab: 4, max_slabs: 8, prealloc_slabs: 1 },
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
            assert(cfg.page_size % 16 == 0 && cfg.page_size > allocation_header_size + Page.sizeof);
            assert(cfg.page_size - allocation_header_size <= ushort.max);
            assert(cfg.pages_per_slab > 0 && cfg.pages_per_slab <= ubyte.max + 1 && cfg.max_slabs > 0);
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

Page* page_alloc(size_t bytes, size_t alignment = size_t.sizeof, size_t headroom = 0, size_t tailroom = 0)
{
    size_t required = page_required_capacity(bytes, alignment, headroom, tailroom);
    if (required > ushort.max)
        return null;
    void[] storage = alloc_payload(required);
    if (!storage.ptr)
        return null;
    Page* page = cast(Page*)storage.ptr;
    if (!page_initialise(page, storage.length, bytes, alignment, headroom, tailroom))
    {
        free_payload(page);
        return null;
    }
    return page;
}

Page* page_adopt(void[] block, size_t bytes, size_t alignment = size_t.sizeof, size_t headroom = 0, size_t tailroom = 0)
{
    if (block.length <= allocation_header_size || (cast(size_t)block.ptr & 15) != 0)
        return null;
    size_t storage_capacity = block.length - allocation_header_size;
    Page* page = cast(Page*)(block.ptr + allocation_header_size);
    if (!page_initialise(page, storage_capacity, bytes, alignment, headroom, tailroom))
        return null;

    AllocationHeader* h = cast(AllocationHeader*)block.ptr;
    static if (size_t.sizeof == 8)
        h.slab_offset = cast(uint)block.length;
    h.allocation = cast(ushort)storage_capacity;
    h.refcount = 0;
    h.next = cast(AllocationHeader*)page_flag_heap;

    {
        auto guard = _lock.acquire();
        ++_jumbo_stats.alloc_count;
        ++_jumbo_stats.size_histogram[histogram_bucket(bytes)];
        if (++_jumbo_stats.pages_in_use > _jumbo_stats.high_water)
            _jumbo_stats.high_water = _jumbo_stats.pages_in_use;
    }
    return page;
}

void page_free(Page* page)
{
    assert(page);
    free_payload(page);
}

ubyte page_category(const Page* page)
{
    AllocationHeader* h = header_of(page);
    return is_heap(h) ? page_category_heap : allocation_category(h);
}

size_t page_payload_size(ubyte category)
{
    assert(category < _num_categories);
    return _categories[category].cfg.page_size - allocation_header_size;
}

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

struct AllocationHeader
{
    ushort refcount;
    ushort allocation;
    static if (size_t.sizeof == 8)
        uint slab_offset;
    AllocationHeader* next;
}

struct SlabHeader
{
    SlabHeader* next;
    AllocationHeader* free_list;
    ushort free_count;
    ushort page_count;
}
enum slab_header_size = (SlabHeader.sizeof + 15) & ~15;
enum allocation_header_size = AllocationHeader.sizeof;
enum size_t page_flag_heap = page_next_flags;
static assert(allocation_header_size == (size_t.sizeof == 4 ? 8 : 16));
static assert(AllocationHeader.next.offsetof + (void*).sizeof == allocation_header_size);

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

void[] alloc_category(ubyte category)
{
    assert(category < _num_categories);
    Category* c = &_categories[category];

    for (;;)
    {
        {
            auto guard = _lock.acquire();

            SlabHeader* best;
            for (SlabHeader* s = c.slabs; s; s = s.next)
            {
                if (s.free_count != 0 && (!best || s.free_count < best.free_count))
                    best = s;
            }
            if (best)
            {
                AllocationHeader* p = best.free_list;
                best.free_list = p.next;
                --best.free_count;
                p.next = null;
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

void[] alloc_payload(size_t bytes)
{
    ubyte cat = ubyte.max;
    uint num_categories;
    {
        auto guard = _lock.acquire();
        num_categories = _num_categories;
        foreach (i; 0 .. _num_categories)
        {
            if (bytes <= _categories[i].cfg.page_size - allocation_header_size)
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
            void[] r = alloc_category(cast(ubyte)i);
            if (r)
                return r;
        }
    }

    size_t block_size = allocation_header_size + bytes;
    void[] mem = alloc(block_size, 16);
    if (!mem.ptr)
    {
        auto guard = _lock.acquire();
        ++_jumbo_stats.fail_count;
        return null;
    }
    AllocationHeader* h = cast(AllocationHeader*)mem.ptr;
    static if (size_t.sizeof == 8)
        h.slab_offset = cast(uint)block_size;
    h.allocation = cast(ushort)bytes;
    h.refcount = 0;
    h.next = cast(AllocationHeader*)page_flag_heap;

    {
        auto guard = _lock.acquire();
        ++_jumbo_stats.alloc_count;
        ++_jumbo_stats.size_histogram[histogram_bucket(bytes)];
        if (++_jumbo_stats.pages_in_use > _jumbo_stats.high_water)
            _jumbo_stats.high_water = _jumbo_stats.pages_in_use;
    }
    return (mem.ptr + allocation_header_size)[0 .. bytes];
}

void free_payload(void* payload)
{
    AllocationHeader* h = header_of(payload);
    if (is_heap(h))
    {
        static if (size_t.sizeof == 8)
            size_t block_size = h.slab_offset;
        else
            size_t block_size = allocation_header_size + h.allocation;
        {
            auto guard = _lock.acquire();
            --_jumbo_stats.pages_in_use;
        }
        free((cast(void*)h)[0 .. block_size]);
        return;
    }

    ubyte category = allocation_category(h);
    assert(category < _num_categories);
    Category* c = &_categories[category];
    SlabHeader* slab = slab_for(h);

    auto guard = _lock.acquire();
    h.next = slab.free_list;
    slab.free_list = h;
    ++slab.free_count;
    --c.stats.pages_in_use;
    ++c.stats.pages_free;
}

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

AllocationHeader* header_of(const(void)* payload)
    => cast(AllocationHeader*)(payload - allocation_header_size);

bool is_heap(const AllocationHeader* h)
    => (cast(size_t)h.next & page_flag_heap) != 0;

ubyte allocation_category(const AllocationHeader* h)
    => cast(ubyte)h.allocation;

ubyte allocation_page_index(const AllocationHeader* h)
    => h.allocation >> 8;

SlabHeader* slab_for(AllocationHeader* h)
{
    static if (size_t.sizeof == 8)
        return cast(SlabHeader*)(cast(void*)h - h.slab_offset);
    else
        return cast(SlabHeader*)(cast(void*)h - slab_header_size
            - allocation_page_index(h) * _categories[allocation_category(h)].cfg.page_size);
}

void[] payload_of(AllocationHeader* h, uint page_size)
    => (cast(void*)h + allocation_header_size)[0 .. page_size - allocation_header_size];

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

    AllocationHeader* prev = null;
    ubyte category = cast(ubyte)(c - _categories.ptr);
    foreach_reverse (i; 0 .. c.cfg.pages_per_slab)
    {
        size_t offset = slab_header_size + i * c.cfg.page_size;
        AllocationHeader* p = cast(AllocationHeader*)(mem.ptr + offset);
        static if (size_t.sizeof == 8)
            p.slab_offset = cast(uint)offset;
        p.allocation = cast(ushort)(category | i << 8);
        p.refcount = 0;
        p.next = prev;
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

    page_pool_deinit();

    assert(page_pool_init(test_cfg));
    assert(!page_pool_init(test_cfg));
    assert(page_pool_num_categories() == 2);
    assert(page_payload_size(0) == 64 - allocation_header_size);

    PagePoolStats s = page_pool_stats(0);
    assert(s.slab_count == 1 && s.pages_free == 4 && s.pages_in_use == 0);

    void[] a = alloc_category(0);
    assert(a.length == 64 - allocation_header_size);
    assert(allocation_category(header_of(a.ptr)) == 0);
    s = page_pool_stats(0);
    assert(s.pages_in_use == 1 && s.alloc_count == 1 && s.high_water == 1);
    free_payload(a.ptr);
    s = page_pool_stats(0);
    assert(s.pages_in_use == 0 && s.pages_free == 4);

    void[][8] pages;
    foreach (i; 0 .. 8)
    {
        pages[i] = alloc_category(0);
        assert(pages[i] !is null);
    }
    assert(alloc_category(0) is null);
    s = page_pool_stats(0);
    assert(s.slab_count == 2 && s.fail_count == 1 && s.high_water == 8);

    foreach (i; 0 .. 8)
        free_payload(pages[i].ptr);
    void[] keep = alloc_category(0);
    foreach (i; 0 .. 3)
    {
        void[] p = alloc_category(0);
        assert(slab_for(header_of(p.ptr)) is slab_for(header_of(keep.ptr)));
        pages[i] = p;
    }
    void[] other = alloc_category(0);
    assert(slab_for(header_of(other.ptr)) !is slab_for(header_of(keep.ptr)));
    foreach (i; 0 .. 3)
        free_payload(pages[i].ptr);
    free_payload(other.ptr);

    assert(page_pool_trim(slab_header_size + 64 * 4) == ReclaimResult.exhausted);
    s = page_pool_stats(0);
    assert(s.slab_count == 1 && s.pages_in_use == 1);
    free_payload(keep.ptr);

    Page* small = page_alloc(32);
    assert(small.length == 32 && page_category(small) == 0);
    Page* mid = page_alloc(100);
    assert(page_category(mid) == 1);
    Page* jumbo = page_alloc(1000);
    assert(jumbo.length == 1000 && page_category(jumbo) == page_category_heap);
    Page* jumbo_next = page_alloc(8);
    jumbo.next = jumbo_next;
    assert(jumbo.next is jumbo_next && page_category(jumbo) == page_category_heap);
    jumbo.capacity = 8;
    PagePoolStats js = page_pool_stats(page_category_heap);
    assert(js.pages_in_use == 1 && js.alloc_count == 1);
    page_free(jumbo);
    page_free(jumbo_next);
    js = page_pool_stats(page_category_heap);
    assert(js.pages_in_use == 0);
    page_free(mid);
    page_free(small);

    Page* linked = page_alloc(8);
    Page* aligned = page_alloc(17, 64, 3, 5);
    assert(linked && aligned);
    assert((cast(size_t)aligned.data.ptr & 63) == 0);
    assert(aligned.headroom >= 3 && aligned.tailroom >= 5);
    aligned.next = linked;
    assert(aligned.next is linked);
    aligned.next = null;
    page_free(aligned);
    page_free(linked);

    Page* reserved = page_alloc(1000, size_t.sizeof, 0, 64);
    assert(reserved.tailroom >= 64);
    page_free(reserved);

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
