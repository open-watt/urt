module urt.mem.pagepool_tiny;

version (Tiny)
{
import urt.atomic;
import urt.mem.alloc;
import urt.mem.freelist : FreeStack;
import urt.mem.page;
import urt.mem.reclaim;
import urt.sync.critical;

nothrow @nogc:


enum ubyte page_category_heap = 0xFF;

// tag word: [heap block size >> 3 : rest][refcount : 8][category : 7][heap : 1]
enum size_t page_tag_heap = 0x01;
enum size_t page_tag_category_shift = 1;
enum size_t page_tag_category_mask = 0x7F;
enum size_t page_tag_refcount_shift = 8;
enum size_t page_tag_refcount_mask = 0xFF;
enum size_t page_tag_size_shift = 16;
enum size_t page_tag_one_ref = size_t(1) << page_tag_refcount_shift;

version (PagePoolDiagnostics)
{
    struct PagePoolStats
    {
        uint pages_in_use;
        uint pages_free;
        uint high_water;
        uint alloc_count;
        uint fail_count;
    }
}

// The prealloc counts are the floor of the reserve an ISR can count on.
template PagePool(
    size_t small_capacity, ushort small_max_pages, ushort small_prealloc_pages,
    size_t large_capacity, ushort large_max_pages, ushort large_prealloc_pages)
{
    static assert(small_capacity > 0 && small_capacity < large_capacity);
    static assert(large_capacity <= ushort.max);
    static assert(small_max_pages > 0 && small_prealloc_pages <= small_max_pages);
    static assert(large_max_pages > 0 && large_prealloc_pages <= large_max_pages);

    bool page_pool_init()
    {
        {
            auto guard = _lock.acquire();
            if (_initialised)
                return false;
            _initialised = true;
        }

        if (!register_reclaimer(&page_pool_trim, 200, true))
        {
            auto guard = _lock.acquire();
            _initialised = false;
            return false;
        }
        page_pool_maintenance(&maintain);

        preallocate(0, small_prealloc_pages);
        preallocate(1, large_prealloc_pages);
        return true;
    }

    // Thread context; grows the pool, and falls back to the heap.
    Page* page_alloc(size_t bytes, size_t alignment = default_alignment, size_t headroom = 0, size_t tailroom = 0)
        => new_page(true, bytes, alignment, headroom, tailroom);

    // Any context, ISRs included; takes a free page or fails, and a pool running low grows on the next page_pool_wake().
    Page* page_alloc_isr(size_t bytes, size_t alignment = default_alignment, size_t headroom = 0, size_t tailroom = 0)
        => new_page(false, bytes, alignment, headroom, tailroom);

    Page* page_adopt(void[] block, size_t bytes, size_t alignment = default_alignment, size_t headroom = 0, size_t tailroom = 0)
    {
        assert(_initialised, "Page pool not initialised!");
        if (block.length <= allocation_header_size || (cast(size_t)block.ptr & 7) != 0)
            return null;
        if ((block.length & 7) != 0 || block.length > max_heap_block)
            return null;

        size_t storage_capacity = block.length - allocation_header_size;
        Page* page = cast(Page*)(block.ptr + allocation_header_size);
        if (!page_initialise(page, storage_capacity, bytes, alignment, headroom, tailroom))
            return null;

        AllocationHeader* header = cast(AllocationHeader*)block.ptr;
        header.tag = heap_tag(block.length);
        header.next = null;
        record_jumbo_alloc();
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
        size_t refs = tag_refcount(atomicFetchAdd(tag_of(page), page_tag_one_ref));
        assert(refs != 0 && refs < page_tag_refcount_mask);
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
        => tag_refcount(atomicLoad(tag_of(cast(Page*)page))) == 1;

    ubyte page_category(const Page* page)
    {
        size_t tag = header_of(page).tag;
        if (tag & page_tag_heap)
            return page_category_heap;
        return tag_category(tag);
    }

    size_t page_payload_size(ubyte category)
    {
        assert(category < 2);
        return category == 0 ? small_capacity : large_capacity;
    }

    uint page_pool_num_categories()
        => 2;

    // Raises or lowers the free pages kept for ISRs, as a user that allocates from one comes and goes; raising it tops
    // the category up on the next page_pool_wake().
    void page_pool_reserve(ubyte category, int pages)
    {
        assert(category < 2);
        atomicFetchAdd(_reserve[category], cast(uint)pages);
        if (pages > 0)
            request_refill(category);
    }

    // Frees the free pages below each category's prealloc floor.
    ReclaimResult page_pool_trim(size_t bytes_needed = size_t.max)
    {
        foreach (ubyte category; 0 .. 2)
        {
            uint taken;
            void* cut = _free[category].take_beyond(reserve(category), taken);
            if (!cut)
                continue;
            {
                auto guard = _lock.acquire();
                _allocated_pages[category] -= taken;
            }
            immutable size_t size = page_size(category);
            while (cut)
            {
                void* link = cut;
                cut = *cast(void**)link;
                urt.mem.alloc.free((cast(void*)header_of_link(link))[0 .. size]);
            }
            return ReclaimResult.more;
        }
        return ReclaimResult.exhausted;
    }

    void page_pool_deinit()
    {
        if (!_initialised)
            return;
        unregister_reclaimer(&page_pool_trim);
        page_pool_maintenance(null);
        free_deferred();

        foreach (ubyte category; 0 .. 2)
        {
            assert(_allocated_pages[category] == _free[category].length, "Page pool deinit with pages in use!");
            immutable size_t size = page_size(category);
            void* link = _free[category].take_all();
            while (link)
            {
                void* next = *cast(void**)link;
                urt.mem.alloc.free((cast(void*)header_of_link(link))[0 .. size]);
                link = next;
            }
            _allocated_pages[category] = 0;
            atomicStore(_refill[category], false);
            atomicStore(_reserve[category], 0u);
        }

        version (PagePoolDiagnostics)
        {
            _category_diagnostics = CategoryDiagnostics.init;
            _jumbo_diagnostics = JumboDiagnostics.init;
        }
        _initialised = false;
    }

    version (PagePoolDiagnostics)
    {
        PagePoolStats page_pool_stats(ubyte category)
        {
            PagePoolStats result;
            if (category == page_category_heap)
            {
                result.pages_in_use = atomicLoad(_jumbo_diagnostics.pages_in_use);
                result.high_water = atomicLoad(_jumbo_diagnostics.high_water);
                result.alloc_count = atomicLoad(_jumbo_diagnostics.alloc_count);
                result.fail_count = atomicLoad(_jumbo_diagnostics.fail_count);
                return result;
            }

            assert(category < 2);
            result.pages_free = _free[category].length;
            result.pages_in_use = _allocated_pages[category] - result.pages_free;
            result.high_water = atomicLoad(_category_diagnostics[category].high_water);
            result.alloc_count = atomicLoad(_category_diagnostics[category].alloc_count);
            result.fail_count = atomicLoad(_category_diagnostics[category].fail_count);
            return result;
        }
    }


    private:

    struct AllocationHeader
    {
        size_t tag;
        AllocationHeader* next;     // a free page links its category's stack through this word
    }
    enum allocation_header_size = (AllocationHeader.sizeof + 7) & ~cast(size_t)7;
    enum link_offset = AllocationHeader.next.offsetof;
    static assert(link_offset + (void*).sizeof == allocation_header_size);
    enum size_t max_heap_block = (size_t.max >> page_tag_size_shift) << 3;

    size_t heap_tag(size_t block_size)
        => (block_size >> 3) << page_tag_size_shift | page_tag_one_ref | page_tag_heap;

    size_t heap_block_size(size_t tag)
        => (tag >> page_tag_size_shift) << 3;

    size_t tag_refcount(size_t tag)
        => (tag >> page_tag_refcount_shift) & page_tag_refcount_mask;

    ubyte tag_category(size_t tag)
        => cast(ubyte)((tag >> page_tag_category_shift) & page_tag_category_mask);

    version (PagePoolDiagnostics)
    {
        struct CategoryDiagnostics
        {
            shared uint high_water;
            shared uint alloc_count;
            shared uint fail_count;
        }

        struct JumboDiagnostics
        {
            shared uint pages_in_use;
            shared uint high_water;
            shared uint alloc_count;
            shared uint fail_count;
        }

        __gshared CategoryDiagnostics[2] _category_diagnostics;
        __gshared JumboDiagnostics _jumbo_diagnostics;
    }

    __gshared Critical _lock;       // page counts
    __gshared FreeStack!true[2] _free;
    __gshared FreeStack!true _deferred;     // heap pages released in an ISR
    __gshared ushort[2] _allocated_pages;
    __gshared shared(bool)[2] _refill;
    __gshared shared(uint)[2] _reserve;
    __gshared bool _initialised;

    size_t page_size(ubyte category)
        => allocation_header_size + ((page_payload_size(category) + 7) & ~cast(size_t)7);

    ushort max_pages(ubyte category)
        => category == 0 ? small_max_pages : large_max_pages;

    ushort prealloc_pages(ubyte category)
        => category == 0 ? small_prealloc_pages : large_prealloc_pages;

    uint reserve(ubyte category)
        => prealloc_pages(category) + atomicLoad(_reserve[category]);

    AllocationHeader* header_of(const(void)* payload)
        => cast(AllocationHeader*)(payload - allocation_header_size);

    ref shared(size_t) tag_of(Page* page)
        => *cast(shared(size_t)*)&header_of(page).tag;

    void* link_of(AllocationHeader* header)
        => cast(void*)header + link_offset;

    AllocationHeader* header_of_link(void* link)
        => cast(AllocationHeader*)(link - link_offset);

    Page* new_page(bool grow, size_t bytes, size_t alignment, size_t headroom, size_t tailroom)
    {
        assert(_initialised, "Page pool not initialised!");
        size_t required = page_required_capacity(bytes, alignment, headroom, tailroom);
        if (required > ushort.max)
            return null;

        void[] storage;
        if (required <= small_capacity)
            storage = alloc_pooled(0, required, grow);
        else if (required <= large_capacity)
            storage = alloc_pooled(1, required, grow);
        else if (grow)
            storage = alloc_heap_page(required);
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

    void[] alloc_heap_page(size_t bytes)
    {
        if (bytes > max_heap_block - allocation_header_size - 7)
        {
            record_jumbo_failure();
            return null;
        }
        size_t block_size = (allocation_header_size + bytes + 7) & ~cast(size_t)7;
        void[] mem = alloc(block_size, 8, MemFlags.dma);
        if (!mem.ptr)
        {
            record_jumbo_failure();
            return null;
        }

        AllocationHeader* header = cast(AllocationHeader*)mem.ptr;
        header.tag = heap_tag(block_size);
        header.next = null;
        record_jumbo_alloc();
        return (mem.ptr + allocation_header_size)[0 .. bytes];
    }

    void release(Page* page, bool defer)
    {
        size_t refs = tag_refcount(atomicFetchSub(tag_of(page), page_tag_one_ref));
        assert(refs != 0, "page_release on a free page");
        if (refs != 1)
            return;
        AllocationHeader* header = header_of(page);
        if (defer && (header.tag & page_tag_heap))
        {
            _deferred.push(link_of(header));
            page_pool_signal();
            return;
        }
        free_payload(page);
        page_freed();
    }

    void free_payload(void* payload)
    {
        AllocationHeader* header = header_of(payload);
        size_t tag = header.tag;
        if (tag & page_tag_heap)
        {
            free_heap(header);
            return;
        }

        ubyte category = tag_category(tag);
        assert(category < 2);
        header.tag = 0;
        _free[category].push(link_of(header));
    }

    void free_heap(AllocationHeader* header)
    {
        record_jumbo_free();
        urt.mem.alloc.free((cast(void*)header)[0 .. heap_block_size(header.tag)]);
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

    void preallocate(ubyte category, ushort count)
    {
        foreach (_; 0 .. count)
        {
            AllocationHeader* page = allocate_page(category);
            if (!page)
                break;
            _free[category].push(link_of(page));
        }
    }

    AllocationHeader* allocate_page(ubyte category)
    {
        {
            auto guard = _lock.acquire();
            if (_allocated_pages[category] >= max_pages(category))
                return null;
            ++_allocated_pages[category];
        }

        void[] mem = alloc(page_size(category), 8, MemFlags.dma);
        if (mem.ptr)
            return cast(AllocationHeader*)mem.ptr;

        auto guard = _lock.acquire();
        --_allocated_pages[category];
        return null;
    }

    void[] alloc_pooled(ubyte category, size_t required, bool grow)
    {
        AllocationHeader* page;
        if (void* link = _free[category].pop())
            page = header_of_link(link);
        else if (grow)
            page = allocate_page(category);
        if (page ? _free[category].length < reserve(category) : !grow)
            request_refill(category);
        if (!page)
        {
            record_failure(category);
            return grow ? alloc_heap_page(required) : null;
        }

        page.tag = cast(size_t)category << page_tag_category_shift | page_tag_one_ref;
        page.next = null;
        record_alloc(category);
        return (cast(void*)page + allocation_header_size)[0 .. page_payload_size(category)];
    }

    void request_refill(ubyte category)
    {
        if (!atomicExchange(&_refill[category], true))
            page_pool_signal();
    }

    // page_pool_wake() runs this on the main thread.
    void maintain()
    {
        free_deferred();
        foreach (ubyte category; 0 .. 2)
        {
            if (!atomicExchange(&_refill[category], false))
                continue;
            immutable uint want = reserve(category) ? reserve(category) : 1;
            while (_free[category].length < want)
            {
                AllocationHeader* page = allocate_page(category);
                if (!page)
                    break;
                _free[category].push(link_of(page));
            }
        }
    }

    void record_alloc(ubyte category)
    {
        version (PagePoolDiagnostics)
        {
            CategoryDiagnostics* diagnostics = &_category_diagnostics[category];
            atomicFetchAdd(diagnostics.alloc_count, 1);
            uint in_use = _allocated_pages[category] - _free[category].length;
            uint seen = atomicLoad(diagnostics.high_water);
            while (in_use > seen && !cas(&diagnostics.high_water, seen, in_use))
                seen = atomicLoad(diagnostics.high_water);
        }
    }

    void record_failure(ubyte category)
    {
        version (PagePoolDiagnostics)
            atomicFetchAdd(_category_diagnostics[category].fail_count, 1);
    }

    void record_jumbo_alloc()
    {
        version (PagePoolDiagnostics)
        {
            atomicFetchAdd(_jumbo_diagnostics.alloc_count, 1);
            uint in_use = atomicFetchAdd(_jumbo_diagnostics.pages_in_use, 1) + 1;
            uint seen = atomicLoad(_jumbo_diagnostics.high_water);
            while (in_use > seen && !cas(&_jumbo_diagnostics.high_water, seen, in_use))
                seen = atomicLoad(_jumbo_diagnostics.high_water);
        }
    }

    void record_jumbo_failure()
    {
        version (PagePoolDiagnostics)
            atomicFetchAdd(_jumbo_diagnostics.fail_count, 1);
    }

    void record_jumbo_free()
    {
        version (PagePoolDiagnostics)
            atomicFetchSub(_jumbo_diagnostics.pages_in_use, 1);
    }
}


void page_pool_tiny_test()()
{
    alias TestPool = PagePool!(56, 8, 4, 248, 4, 0);

    __gshared uint signals;
    static void hook() nothrow @nogc { ++signals; }
    page_pool_wake_hook(&hook);
    scope (exit) page_pool_wake_hook(null);

    TestPool.page_pool_deinit();
    assert(TestPool.page_pool_init());
    assert(!TestPool.page_pool_init());
    assert(TestPool.page_payload_size(0) == 56);
    assert(TestPool.page_payload_size(1) == 248);

    Page* page = TestPool.page_alloc(32);
    assert(page.length == 32 && (cast(size_t)page.data.ptr & 7) == 0);
    assert(TestPool.page_category(page) == 0);
    TestPool.page_free(page);
    assert(TestPool._free[0].length == 4);

    Page*[8] pages;
    foreach (ref allocated; pages)
    {
        allocated = TestPool.page_alloc(32);
        assert(allocated !is null);
    }
    Page* overflow = TestPool.page_alloc(32);
    assert(TestPool.page_category(overflow) == page_category_heap);
    TestPool.page_free(overflow);
    foreach (ref allocated; pages)
        TestPool.page_free(allocated);

    Page* keep = TestPool.page_alloc(32);
    while (TestPool.page_pool_trim() == ReclaimResult.more) {}
    assert(TestPool._allocated_pages[0] == 5);
    assert(TestPool._free[0].length == 4);
    TestPool.page_free(keep);

    // an allocation that may not grow fails at once, and the wake grows what it found empty
    page_pool_wake();
    signals = 0;
    foreach (ref allocated; pages[0 .. 6])
        allocated = TestPool.page_alloc_isr(32);
    assert(pages[5] is null && signals == 1 && TestPool._allocated_pages[0] == 5);
    assert(TestPool.page_alloc_isr(100) is null && TestPool.page_alloc_isr(1000) is null, "no growth, and never the heap");
    page_pool_wake();
    assert(TestPool._free[0].length == 3 && TestPool._allocated_pages[0] == 8);
    pages[5] = TestPool.page_alloc_isr(32);
    assert(pages[5] !is null);
    TestPool.page_pool_reserve(0, 2);
    page_pool_wake();
    assert(TestPool._free[0].length == 2 && TestPool._allocated_pages[0] == 8, "the reserve grows up to the cap");
    TestPool.page_pool_reserve(0, -2);
    foreach (allocated; pages[0 .. 6])
        TestPool.page_free(allocated);
    while (TestPool.page_pool_trim() == ReclaimResult.more) {}

    Page* medium = TestPool.page_alloc(100);
    assert(medium.length == 100 && TestPool.page_category(medium) == 1);
    Page* jumbo = TestPool.page_alloc(1000);
    assert(jumbo.length == 1000);
    assert((cast(size_t)jumbo.data.ptr & 7) == 0);
    assert(TestPool.page_category(jumbo) == page_category_heap);
    TestPool.page_free(jumbo);
    TestPool.page_free(medium);

    // an ISR's release of a heap page waits for the wake
    Page* late = TestPool.page_alloc(1000);
    page_pool_wake();
    signals = 0;
    TestPool.page_release_isr(late);
    assert(signals == 1 && TestPool._deferred.length == 1);
    page_pool_wake();
    assert(TestPool._deferred.length == 0);

    Page* reserved = TestPool.page_alloc(1000, size_t.sizeof, 3, 64);
    assert(reserved.headroom >= 3 && reserved.tailroom >= 64);
    TestPool.page_free(reserved);

    foreach (bytes; [32, 1000])
    {
        Page* shared_page = TestPool.page_alloc(bytes);
        ubyte category = TestPool.page_category(shared_page);
        assert(TestPool.page_unique(shared_page));
        assert(TestPool.page_share(shared_page) is shared_page);
        assert(!TestPool.page_unique(shared_page));
        TestPool.page_release(shared_page);
        assert(TestPool.page_unique(shared_page) && TestPool.page_category(shared_page) == category);
        TestPool.page_release(shared_page);
    }
    assert(TestPool._free[0].length == TestPool._allocated_pages[0]);

    version (PagePoolDiagnostics)
    {
        PagePoolStats stats = TestPool.page_pool_stats(0);
        assert(stats.high_water == 8 && stats.fail_count == 2);
        assert(TestPool.page_pool_stats(page_category_heap).alloc_count == 4);
    }

    import urt.mem.reclaim : reclaim_memory;
    reclaim_memory(1);

    page_pool_wake();
    TestPool.page_pool_deinit();
    assert(TestPool.page_pool_init());
    TestPool.page_pool_deinit();

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
    assert(!TestPool.page_pool_init());
    foreach (handler; fillers)
        assert(unregister_reclaimer(handler));
    assert(TestPool.page_pool_init());
    TestPool.page_pool_deinit();
}
}
