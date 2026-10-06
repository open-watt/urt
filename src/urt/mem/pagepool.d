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
    alias page_alloc_isr     = Pool.page_alloc_isr;
    alias page_adopt         = Pool.page_adopt;
    alias page_free          = Pool.page_free;
    alias page_share         = Pool.page_share;
    alias page_release       = Pool.page_release;
    alias page_release_isr   = Pool.page_release_isr;
    alias page_unique        = Pool.page_unique;
    alias page_category      = Pool.page_category;
    alias page_payload_size  = Pool.page_payload_size;
    alias page_pool_num_categories = Pool.page_pool_num_categories;
    alias page_pool_reserve  = Pool.page_pool_reserve;
    alias page_pool_trim     = Pool.page_pool_trim;
    alias page_pool_deinit   = Pool.page_pool_deinit;

    unittest
    {
        page_pool_tiny_test!()();
    }
}
else
{

import urt.atomic;
import urt.mem.alloc;
import urt.mem.freelist : FreeStack;
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
    ushort reserve_pages;   // free pages an ISR can count on; allocating below it asks the main thread to grow
}

struct PagePoolStats
{
    uint pages_in_use;
    uint pages_free;
    uint slab_count;
    uint high_water;        // peak pages_in_use
    uint alloc_count;
    uint fail_count;
    uint[8] size_histogram;
}


bool page_pool_init()
{
    static immutable PageCategoryConfig[2] defaults = [
        { page_size:  352, pages_per_slab: 8, max_slabs: 8, prealloc_slabs: 1, reserve_pages: 4 },
        { page_size: 1632, pages_per_slab: 4, max_slabs: 8, prealloc_slabs: 1, reserve_pages: 2 },
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
            atomicStore(_categories[i].reserve, uint(cfg.reserve_pages));
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
    page_pool_maintenance(&maintain);

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

// Thread context; grows the pool, and falls back to the heap past the largest category.
Page* page_alloc(size_t bytes, size_t alignment = default_alignment, size_t headroom = 0, size_t tailroom = 0)
    => new_page(true, bytes, alignment, headroom, tailroom);

// Any context, ISRs included; takes a free page or fails, and a pool running low grows on the next page_pool_wake().
Page* page_alloc_isr(size_t bytes, size_t alignment = default_alignment, size_t headroom = 0, size_t tailroom = 0)
    => new_page(false, bytes, alignment, headroom, tailroom);

Page* page_adopt(void[] block, size_t bytes, size_t alignment = default_alignment, size_t headroom = 0, size_t tailroom = 0)
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
    h.refcount = 1;
    h.next = cast(AllocationHeader*)page_flag_heap;

    atomicFetchAdd(_jumbo.size_histogram[histogram_bucket(bytes)], 1);
    count_alloc(_jumbo);
    return page;
}

// A page starts with one reference; page_free releases it and asserts it was the last.
void page_free(Page* page)
{
    debug assert(page_unique(page), "page_free on a shared page");
    page_release(page);
}

Page* page_share(Page* page)
{
    immutable ushort refs = atomicFetchAdd(refcount_of(page), cast(ushort)1);
    assert(refs != 0 && refs < ushort.max);
    return page;
}

void page_release(Page* page)
{
    release(page, false);
}

// Any context, ISRs included; a page from the heap is freed by the next page_pool_wake().
void page_release_isr(Page* page)
{
    release(page, true);
}

bool page_unique(const Page* page)
    => atomicLoad(refcount_of(cast(Page*)page)) == 1;

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

// Raises or lowers the free pages kept for ISRs, as a user that allocates from one comes and goes; raising it tops the
// category up on the next page_pool_wake().
void page_pool_reserve(ubyte category, int pages)
{
    assert(category < _num_categories);
    Category* c = &_categories[category];
    atomicFetchAdd(c.reserve, cast(uint)pages);
    if (pages > 0)
        request_refill(c);
}

// Takes the free pages below each category's reserve, releases a slab with none in use, and holds back the free pages
// of the lightest slab so the next passes can release it too. Pages it returns go back on top, so pages kept near the
// top come within reach as the stack turns over.
ReclaimResult page_pool_trim(size_t bytes_needed = size_t.max)
{
    if (atomicExchange(&_trimming, true))
        return ReclaimResult.exhausted;
    scope (exit) atomicStore(_trimming, false);

    foreach (i; 0 .. _num_categories)
    {
        Category* c = &_categories[i];
        if (c.slab_count <= c.cfg.prealloc_slabs)
            continue;

        uint taken;
        void* cut = c.free.take_beyond(atomicLoad(c.reserve), taken);
        for (void* link = cut; link; link = *cast(void**)link)
            ++slab_of(link).cut_count;

        SlabHeader* release;
        SlabHeader* lightest;
        for (SlabHeader* s = c.slabs; s; s = s.next)
        {
            if (s.cut_count + s.home_count == s.page_count)
            {
                if (!release || s is c.draining)
                    release = s;
            }
            else if (s.cut_count && (!lightest || s.cut_count + s.home_count > lightest.cut_count + lightest.home_count))
                lightest = s;
        }
        if (!release && !c.draining)
            c.draining = lightest;

        void* first;
        void* last;
        uint kept;
        while (cut)
        {
            void* link = cut;
            cut = *cast(void**)link;
            SlabHeader* s = slab_of(link);
            s.cut_count = 0;
            if (s is release)
                continue;
            if (s is c.draining)
            {
                *cast(void**)link = s.home;
                s.home = link;
                ++s.home_count;
                atomicFetchAdd(c.held, 1);
                continue;
            }
            *cast(void**)link = null;
            if (last)
                *cast(void**)last = link;
            else
                first = link;
            last = link;
            ++kept;
        }
        if (first)
            c.free.push_chain(first, last, kept);

        if (!release)
            continue;
        if (release is c.draining)
        {
            c.draining = null;
            atomicFetchSub(c.held, uint(release.home_count));
        }
        {
            auto guard = _lock.acquire();
            SlabHeader** link = &c.slabs;
            while (*link !is release)
                link = &(*link).next;
            *link = release.next;
            --c.slab_count;
        }
        free((cast(void*)release)[0 .. slab_bytes(c.cfg)]);
        return c.slab_count > c.cfg.prealloc_slabs ? ReclaimResult.more : ReclaimResult.exhausted;
    }
    return ReclaimResult.exhausted;
}

PagePoolStats page_pool_stats(ubyte category)
{
    PagePoolStats s;
    Counters* k;
    if (category == page_category_heap)
        k = &_jumbo;
    else
    {
        assert(category < _num_categories);
        Category* c = &_categories[category];
        k = &c.counters;
        s.pages_free = c.free.length + atomicLoad(c.held);
        s.slab_count = c.slab_count;
    }
    s.pages_in_use = atomicLoad(k.in_use);
    s.high_water = atomicLoad(k.high_water);
    s.alloc_count = atomicLoad(k.alloc_count);
    s.fail_count = atomicLoad(k.fail_count);
    foreach (i, ref bucket; s.size_histogram)
        bucket = atomicLoad(k.size_histogram[i]);
    return s;
}

uint page_pool_num_categories()
    => _num_categories;

void page_pool_deinit()
{
    if (_num_categories == 0)
        return;
    unregister_reclaimer(&trim_handler);
    page_pool_maintenance(null);
    free_deferred();
    foreach (i; 0 .. _num_categories)
    {
        Category* c = &_categories[i];
        assert(atomicLoad(c.counters.in_use) == 0, "Page pool deinit with pages in use!");
        c.free.take_all();
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
    _jumbo = Counters();
}


private:

struct AllocationHeader
{
    ushort refcount;
    ushort allocation;
    static if (size_t.sizeof == 8)
        uint slab_offset;
    AllocationHeader* next;     // a free page links its category's stack through this word
}

struct SlabHeader
{
    SlabHeader* next;
    void* home;                 // free pages held back while the slab drains
    ushort page_count;
    ushort home_count;
    ushort cut_count;
}
enum slab_header_size = (SlabHeader.sizeof + 15) & ~15;
enum allocation_header_size = AllocationHeader.sizeof;
enum link_offset = AllocationHeader.next.offsetof;
enum size_t page_flag_heap = page_next_flags;
static assert(allocation_header_size == (size_t.sizeof == 4 ? 8 : 16));
static assert(link_offset + (void*).sizeof == allocation_header_size);

struct Counters
{
    shared uint in_use;
    shared uint high_water;
    shared uint alloc_count;
    shared uint fail_count;
    shared uint[8] size_histogram;
}

struct Category
{
    FreeStack!true free;
    SlabHeader* slabs;
    SlabHeader* draining;       // the trim pass's alone
    PageCategoryConfig cfg;
    uint slab_count;
    shared uint reserve;
    shared uint held;
    shared bool refill;
    Counters counters;
}

__gshared Critical _lock;       // slab lists
__gshared Category[max_page_categories] _categories;
__gshared uint _num_categories;
__gshared Counters _jumbo;
__gshared FreeStack!true _deferred;     // heap pages released in an ISR
shared bool _trimming;

Page* new_page(bool grow, size_t bytes, size_t alignment, size_t headroom, size_t tailroom)
{
    size_t required = page_required_capacity(bytes, alignment, headroom, tailroom);
    if (required > ushort.max)
        return null;
    void[] storage = alloc_payload(required, grow);
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

void[] alloc_payload(size_t bytes, bool grow)
{
    foreach (i; 0 .. _num_categories)
    {
        if (bytes > _categories[i].cfg.page_size - allocation_header_size)
            continue;
        atomicFetchAdd(_categories[i].counters.size_histogram[histogram_bucket(bytes)], 1);
        foreach (j; i .. _num_categories)
        {
            void[] r = take_page(&_categories[j], grow);
            if (r.ptr)
                return r;
        }
        break;
    }
    if (!grow)
        return null;

    size_t block_size = allocation_header_size + bytes;
    void[] mem = alloc(block_size, 16, MemFlags.dma);
    if (!mem.ptr)
    {
        atomicFetchAdd(_jumbo.fail_count, 1);
        return null;
    }
    AllocationHeader* h = cast(AllocationHeader*)mem.ptr;
    static if (size_t.sizeof == 8)
        h.slab_offset = cast(uint)block_size;
    h.allocation = cast(ushort)bytes;
    h.refcount = 1;
    h.next = cast(AllocationHeader*)page_flag_heap;

    atomicFetchAdd(_jumbo.size_histogram[histogram_bucket(bytes)], 1);
    count_alloc(_jumbo);
    return (mem.ptr + allocation_header_size)[0 .. bytes];
}

void[] take_page(Category* c, bool grow)
{
    void* link = c.free.pop();
    if (!link && grow && (undrain(c) || add_slab(c)))
        link = c.free.pop();
    if (link ? c.free.length < atomicLoad(c.reserve) : !grow)
        request_refill(c);
    if (!link)
    {
        atomicFetchAdd(c.counters.fail_count, 1);
        return null;
    }
    AllocationHeader* h = header_of_link(link);
    h.refcount = 1;
    h.next = null;
    count_alloc(c.counters);
    return payload_of(h, c.cfg.page_size);
}

void release(Page* page, bool defer)
{
    immutable ushort refs = atomicFetchSub(refcount_of(page), cast(ushort)1);
    assert(refs != 0, "page_release on a free page");
    if (refs != 1)
        return;
    AllocationHeader* h = header_of(page);
    if (defer && is_heap(h))
    {
        _deferred.push(link_of(h));
        page_pool_signal();
        return;
    }
    free_payload(page);
    page_freed();
}

void free_payload(void* payload)
{
    AllocationHeader* h = header_of(payload);
    if (is_heap(h))
    {
        free_heap(h);
        return;
    }

    Category* c = &_categories[allocation_category(h)];
    h.refcount = 0;
    atomicFetchSub(c.counters.in_use, 1);
    c.free.push(link_of(h));
}

void free_heap(AllocationHeader* h)
{
    static if (size_t.sizeof == 8)
        size_t block_size = h.slab_offset;
    else
        size_t block_size = allocation_header_size + h.allocation;
    atomicFetchSub(_jumbo.in_use, 1);
    free((cast(void*)h)[0 .. block_size]);
}

void free_deferred()
{
    void* link = _deferred.take_all();
    if (!link)
        return;
    while (link)
    {
        void* next = *cast(void**)link;
        free_heap(header_of_link(link));
        link = next;
    }
    page_freed();
}

void count_alloc(ref Counters k)
{
    atomicFetchAdd(k.alloc_count, 1);
    immutable uint in_use = atomicFetchAdd(k.in_use, 1) + 1;
    uint seen = atomicLoad(k.high_water);
    while (in_use > seen && !cas(&k.high_water, seen, in_use))
        seen = atomicLoad(k.high_water);
}

void request_refill(Category* c)
{
    if (!atomicExchange(&c.refill, true))
        page_pool_signal();
}

// page_pool_wake() runs this on the main thread.
void maintain()
{
    free_deferred();
    foreach (ref c; _categories[0 .. _num_categories])
    {
        if (!atomicExchange(&c.refill, false))
            continue;
        immutable uint reserve = atomicLoad(c.reserve);
        immutable uint want = reserve ? reserve : 1;
        while (c.free.length < want && (undrain(&c) || add_slab(&c)))
        {
        }
    }
}

// Returns the draining slab's held pages to circulation, unless a trim pass owns them right now.
bool undrain(Category* c)
{
    if (!c.draining || atomicExchange(&_trimming, true))
        return false;
    scope (exit) atomicStore(_trimming, false);
    SlabHeader* s = c.draining;
    if (!s)
        return false;
    c.draining = null;
    if (!s.home_count)
        return false;
    void* last = s.home;
    while (*cast(void**)last)
        last = *cast(void**)last;
    c.free.push_chain(s.home, last, s.home_count);
    atomicFetchSub(c.held, uint(s.home_count));
    s.home = null;
    s.home_count = 0;
    return true;
}

bool add_slab(Category* c)
{
    if (c.slab_count >= c.cfg.max_slabs)
        return false;
    void[] mem = alloc(slab_bytes(c.cfg), 16, MemFlags.dma);
    if (!mem.ptr)
        return false;

    SlabHeader* slab = cast(SlabHeader*)mem.ptr;
    *slab = SlabHeader();
    slab.page_count = c.cfg.pages_per_slab;

    void* first;
    void* last;
    ubyte category = cast(ubyte)(c - _categories.ptr);
    foreach_reverse (i; 0 .. c.cfg.pages_per_slab)
    {
        size_t offset = slab_header_size + i * c.cfg.page_size;
        AllocationHeader* p = cast(AllocationHeader*)(mem.ptr + offset);
        static if (size_t.sizeof == 8)
            p.slab_offset = cast(uint)offset;
        p.allocation = cast(ushort)(category | i << 8);
        p.refcount = 0;
        p.next = cast(AllocationHeader*)first;
        first = link_of(p);
        if (!last)
            last = first;
    }

    {
        auto guard = _lock.acquire();
        if (c.slab_count >= c.cfg.max_slabs)
        {
            slab = null;
        }
        else
        {
            slab.next = c.slabs;
            c.slabs = slab;
            ++c.slab_count;
        }
    }
    if (!slab)
    {
        free(mem);
        return false;
    }
    c.free.push_chain(first, last, c.cfg.pages_per_slab);
    return true;
}

size_t slab_bytes(ref const PageCategoryConfig cfg)
    => slab_header_size + cfg.page_size * cfg.pages_per_slab;

AllocationHeader* header_of(const(void)* payload)
    => cast(AllocationHeader*)(payload - allocation_header_size);

ref shared(ushort) refcount_of(Page* page)
    => *cast(shared(ushort)*)&header_of(page).refcount;

void* link_of(AllocationHeader* h)
    => cast(void*)h + link_offset;

AllocationHeader* header_of_link(void* link)
    => cast(AllocationHeader*)(link - link_offset);

SlabHeader* slab_of(void* link)
    => slab_for(header_of_link(link));

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

ReclaimResult trim_handler(size_t bytes_needed)
    => page_pool_trim(bytes_needed);


unittest
{
    static immutable PageCategoryConfig[2] test_cfg = [
        PageCategoryConfig(64, 4, 3, 1),
        PageCategoryConfig(256, 2, 2, 0),
    ];
    Category* small = &_categories[0];

    __gshared uint signals;
    static void hook() nothrow @nogc { ++signals; }
    page_pool_wake_hook(&hook);
    scope (exit) page_pool_wake_hook(null);

    page_pool_deinit();

    assert(page_pool_init(test_cfg));
    assert(!page_pool_init(test_cfg));
    assert(page_pool_num_categories() == 2);
    assert(page_payload_size(0) == 64 - allocation_header_size);

    PagePoolStats s = page_pool_stats(0);
    assert(s.slab_count == 1 && s.pages_free == 4 && s.pages_in_use == 0);

    void[] a = take_page(small, true);
    assert(a.length == 64 - allocation_header_size);
    assert(allocation_category(header_of(a.ptr)) == 0);
    s = page_pool_stats(0);
    assert(s.pages_in_use == 1 && s.alloc_count == 1 && s.high_water == 1);
    free_payload(a.ptr);
    s = page_pool_stats(0);
    assert(s.pages_in_use == 0 && s.pages_free == 4);
    assert(take_page(small, true).ptr is a.ptr, "the page freed last goes out first");
    free_payload(a.ptr);

    // growth stops at the cap, and trim hands slabs back down to the floor
    void[][12] pages;
    foreach (ref p; pages)
    {
        p = take_page(small, true);
        assert(p.ptr !is null);
    }
    assert(take_page(small, true).ptr is null);
    s = page_pool_stats(0);
    assert(s.slab_count == 3 && s.fail_count == 1 && s.high_water == 12);
    foreach (p; pages)
        free_payload(p.ptr);
    while (page_pool_trim() == ReclaimResult.more) {}
    s = page_pool_stats(0);
    assert(s.slab_count == 1 && s.pages_free == 4 && s.pages_in_use == 0);

    // a slab with a page in use drains: its free pages are held back, and it goes once the last returns
    foreach (ref p; pages)
        p = take_page(small, true);
    SlabHeader* x = slab_for(header_of(pages[0].ptr));
    SlabHeader* y;
    void* keep_x = pages[0].ptr;
    void* keep_y;
    foreach (p; pages[1 .. $])
    {
        SlabHeader* ps = slab_for(header_of(p.ptr));
        if (ps !is x && !y)
        {
            y = ps;
            keep_y = p.ptr;
            continue;
        }
        free_payload(p.ptr);
    }
    assert(page_pool_trim() == ReclaimResult.more && small.slab_count == 2, "the empty slab goes first");
    assert(page_pool_trim() == ReclaimResult.exhausted && small.draining !is null, "then the lightest drains");
    SlabHeader* drained = small.draining;
    s = page_pool_stats(0);
    assert(atomicLoad(small.held) == 3 && s.pages_free == 6 && s.pages_in_use == 2);
    free_payload((drained is x ? keep_x : keep_y));
    assert(page_pool_trim() == ReclaimResult.exhausted && small.slab_count == 1 && !small.draining);
    assert(atomicLoad(small.held) == 0);
    free_payload((drained is x ? keep_y : keep_x));

    // a drain gives its pages back before the pool grows
    foreach (ref p; pages[0 .. 8])
        p = take_page(small, true);
    x = slab_for(header_of(pages[0].ptr));
    uint freed_x;
    foreach (p; pages[0 .. 8])
    {
        if (slab_for(header_of(p.ptr)) is x && freed_x < 3)
        {
            free_payload(p.ptr);
            ++freed_x;
        }
    }
    page_pool_trim();
    assert(small.draining is x && atomicLoad(small.held) == 3 && small.free.length == 0);
    void[] back = take_page(small, true);
    assert(slab_for(header_of(back.ptr)) is x && small.slab_count == 2 && !small.draining);
    assert(atomicLoad(small.held) == 0 && small.free.length == 2);
    free_payload(back.ptr);
    foreach (p; pages[0 .. 8])
    {
        if (atomicLoad(refcount_of(cast(Page*)p.ptr)) != 0)
            free_payload(p.ptr);
    }
    while (page_pool_trim() == ReclaimResult.more) {}

    // an allocation that may not grow fails at once, and the wake grows what it found empty
    foreach (ref p; pages[0 .. 4])
        p = take_page(small, true);
    page_pool_wake();
    signals = 0;
    assert(page_alloc_isr(8) is null && small.slab_count == 1 && signals == 1);
    page_pool_wake();
    Page* from_isr = page_alloc_isr(8);
    assert(from_isr && page_category(from_isr) == 0 && small.slab_count == 2);
    page_free(from_isr);
    foreach (p; pages[0 .. 4])
        free_payload(p.ptr);
    while (page_pool_trim() == ReclaimResult.more) {}
    page_pool_deinit();

    // dipping below the reserve signals once, and the wake tops it back up
    static immutable PageCategoryConfig[1] reserve_cfg = [ PageCategoryConfig(64, 4, 3, 1, 2) ];
    assert(page_pool_init(reserve_cfg));
    signals = 0;
    void[] r1 = take_page(small, true);
    void[] r2 = take_page(small, true);
    assert(signals == 0 && small.free.length == 2);
    void[] r3 = take_page(small, true);
    void[] r4 = take_page(small, false);
    assert(signals == 1 && small.free.length == 0);
    page_pool_wake();
    assert(small.free.length >= 2 && small.slab_count == 2);
    page_pool_reserve(0, 4);
    assert(signals == 2, "raising the reserve asks for a refill");
    page_pool_wake();
    assert(small.free.length >= 6 && small.slab_count == 3);
    page_pool_reserve(0, -4);
    free_payload(r1.ptr);
    free_payload(r2.ptr);
    free_payload(r3.ptr);
    free_payload(r4.ptr);
    page_pool_deinit();

    assert(page_pool_init(test_cfg));
    Page* tiny = page_alloc(32);
    assert(tiny.length == 32 && page_category(tiny) == 0);
    Page* mid = page_alloc(100);
    assert(page_category(mid) == 1);
    Page* jumbo = page_alloc(1000);
    assert(jumbo.length == 1000 && page_category(jumbo) == page_category_heap);
    assert(page_alloc_isr(1000) is null, "an ISR never reaches the heap");
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

    // an ISR's release of a heap page waits for the wake; a pooled page goes back at once
    Page* late = page_alloc(1000);
    Page* pooled = page_alloc(8);
    uint pooled_in_use = page_pool_stats(0).pages_in_use;
    signals = 0;
    page_release_isr(pooled);
    page_release_isr(late);
    assert(page_pool_stats(0).pages_in_use == pooled_in_use - 1);
    assert(page_pool_stats(page_category_heap).pages_in_use == 1 && signals == 1);
    page_pool_wake();
    assert(page_pool_stats(page_category_heap).pages_in_use == 0);
    page_free(mid);
    page_free(tiny);

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

    foreach (bytes; [8, 1000])
    {
        Page* shared_page = page_alloc(bytes);
        ubyte category = page_category(shared_page);
        uint in_use = page_pool_stats(category).pages_in_use;
        assert(page_unique(shared_page));
        assert(page_share(shared_page) is shared_page);
        assert(!page_unique(shared_page));
        page_release(shared_page);
        assert(page_unique(shared_page) && page_pool_stats(category).pages_in_use == in_use);
        page_release(shared_page);
        assert(page_pool_stats(category).pages_in_use == in_use - 1);
    }

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

version (BareMetal) {} else
unittest
{
    import urt.thread : thread_join, thread_spawn;

    static immutable PageCategoryConfig[1] cfg = [ PageCategoryConfig(64, 4, 8, 1) ];
    page_pool_deinit();
    assert(page_pool_init(cfg));

    static struct Churn
    {
    nothrow @nogc:
        uint failures;
        void run()
        {
            Page*[4] held;
            foreach (round; 0 .. 5000)
            {
                foreach (ref p; held)
                {
                    p = round & 1 ? page_alloc(16) : page_alloc_isr(16);
                    failures += p is null;
                }
                foreach (p; held)
                {
                    if (!p)
                        continue;
                    if (round & 2)
                        page_release_isr(p);
                    else
                        page_free(p);
                }
            }
        }
    }

    static struct Trimmer
    {
    nothrow @nogc:
        shared bool stop;
        uint passes;
        void run()
        {
            while (!atomicLoad(stop))
            {
                page_pool_trim();
                ++passes;
            }
        }
    }

    Trimmer trimmer;
    void* trim_thread = thread_spawn(&trimmer.run);
    assert(trim_thread, "spawn");
    Churn[3] churns;
    void*[3] threads;
    foreach (i, ref c; churns)
    {
        threads[i] = thread_spawn(&c.run);
        assert(threads[i], "spawn");
    }
    foreach (t; threads)
        thread_join(t);
    atomicStore(trimmer.stop, true);
    thread_join(trim_thread);
    assert(trimmer.passes > 0);

    PagePoolStats s = page_pool_stats(0);
    assert(s.pages_in_use == 0 && s.pages_free == s.slab_count * 4, "every page came back once");
    assert(s.alloc_count + s.fail_count == 3 * 5000 * 4);
    page_pool_wake();
    page_pool_deinit();
}
}
