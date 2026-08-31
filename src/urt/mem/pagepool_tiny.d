module urt.mem.pagepool_tiny;

version (Tiny)
{
import urt.mem.alloc;
import urt.mem.page;
import urt.mem.reclaim;
import urt.sync.critical;

nothrow @nogc:


enum ubyte page_category_heap = 0xFF;
enum size_t page_tag_heap = 0x01;
enum size_t page_tag_mask = 0x07;

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

        preallocate(0, small_prealloc_pages);
        preallocate(1, large_prealloc_pages);
        return true;
    }

    Page* page_alloc(size_t bytes, size_t alignment = size_t.sizeof, size_t headroom = 0, size_t tailroom = 0)
    {
        assert(_initialised, "Page pool not initialised!");
        size_t required = page_required_capacity(bytes, alignment, headroom, tailroom);
        if (required > ushort.max)
            return null;

        void[] storage;
        if (required <= small_capacity)
            storage = alloc_pooled(0, required);
        else if (required <= large_capacity)
            storage = alloc_pooled(1, required);
        else
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
        if (bytes > size_t.max - allocation_header_size - 7)
        {
            record_jumbo_failure();
            return null;
        }
        size_t block_size = (allocation_header_size + bytes + 7) & ~cast(size_t)7;
        void[] mem = alloc(block_size, 8);
        if (!mem.ptr)
        {
            record_jumbo_failure();
            return null;
        }

        AllocationHeader* header = cast(AllocationHeader*)mem.ptr;
        header.tag = block_size | page_tag_heap;
        header.next = null;
        record_jumbo_alloc();
        return (mem.ptr + allocation_header_size)[0 .. bytes];
    }

    Page* page_adopt(void[] block, size_t bytes, size_t alignment = size_t.sizeof,
                     size_t headroom = 0, size_t tailroom = 0)
    {
        assert(_initialised, "Page pool not initialised!");
        if (block.length <= allocation_header_size || (cast(size_t)block.ptr & 7) != 0)
            return null;
        if ((block.length & page_tag_mask) != 0)
            return null;    // the size shares its low bits with the tag

        size_t storage_capacity = block.length - allocation_header_size;
        Page* page = cast(Page*)(block.ptr + allocation_header_size);
        if (!page_initialise(page, storage_capacity, bytes, alignment, headroom, tailroom))
            return null;

        AllocationHeader* header = cast(AllocationHeader*)block.ptr;
        header.tag = block.length | page_tag_heap;
        header.next = null;
        record_jumbo_alloc();
        return page;
    }

    void page_free(Page* page)
    {
        assert(page);
        free_payload(page);
    }

    void free_payload(void* payload)
    {
        AllocationHeader* header = header_of(payload);
        size_t tag = header.tag;
        if (tag & page_tag_heap)
        {
            record_jumbo_free();
            size_t block_size = tag & ~page_tag_mask;
            urt.mem.alloc.free((cast(void*)header)[0 .. block_size]);
            return;
        }

        ubyte category = cast(ubyte)(tag >> 1);
        assert(category < 2);
        cache_page(category, header);
    }

    ubyte page_category(const Page* page)
    {
        size_t tag = header_of(page).tag;
        if (tag & page_tag_heap)
            return page_category_heap;
        return cast(ubyte)(tag >> 1);
    }

    size_t page_payload_size(ubyte category)
    {
        assert(category < 2);
        return category == 0 ? small_capacity : large_capacity;
    }

    ReclaimResult page_pool_trim(size_t bytes_needed = size_t.max)
    {
        foreach (category; 0 .. 2)
        {
            AllocationHeader* page;
            size_t size = page_size(cast(ubyte)category);
            ushort floor = prealloc_pages(cast(ubyte)category);
            bool more;
            {
                auto guard = _lock.acquire();
                if (_free_pages[category] > floor)
                {
                    page = _free_lists[category];
                    _free_lists[category] = page.next;
                    --_free_pages[category];
                    --_allocated_pages[category];
                    more = _free_pages[0] > prealloc_pages(0)
                        || _free_pages[1] > prealloc_pages(1);
                }
            }

            if (page)
            {
                urt.mem.alloc.free((cast(void*)page)[0 .. size]);
                return more ? ReclaimResult.more : ReclaimResult.exhausted;
            }
        }
        return ReclaimResult.exhausted;
    }

    void page_pool_deinit()
    {
        if (!_initialised)
            return;
        unregister_reclaimer(&page_pool_trim);

        foreach (category; 0 .. 2)
        {
            assert(_allocated_pages[category] == _free_pages[category],
                "Page pool deinit with pages in use!");
            size_t size = page_size(cast(ubyte)category);
            AllocationHeader* page = _free_lists[category];
            while (page)
            {
                AllocationHeader* next = page.next;
                urt.mem.alloc.free((cast(void*)page)[0 .. size]);
                page = next;
            }
            _free_lists[category] = null;
            _allocated_pages[category] = 0;
            _free_pages[category] = 0;
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
            auto guard = _lock.acquire();
            PagePoolStats result;
            if (category == page_category_heap)
            {
                result.pages_in_use = _jumbo_diagnostics.pages_in_use;
                result.high_water = _jumbo_diagnostics.high_water;
                result.alloc_count = _jumbo_diagnostics.alloc_count;
                result.fail_count = _jumbo_diagnostics.fail_count;
                return result;
            }

            assert(category < 2);
            result.pages_in_use = _allocated_pages[category] - _free_pages[category];
            result.pages_free = _free_pages[category];
            result.high_water = _category_diagnostics[category].high_water;
            result.alloc_count = _category_diagnostics[category].alloc_count;
            result.fail_count = _category_diagnostics[category].fail_count;
            return result;
        }
    }


    private:

    struct AllocationHeader
    {
        size_t tag;
        AllocationHeader* next;
    }
    enum allocation_header_size = (AllocationHeader.sizeof + 7) & ~cast(size_t)7;
    static assert(AllocationHeader.next.offsetof + (void*).sizeof == allocation_header_size);

    version (PagePoolDiagnostics)
    {
        struct CategoryDiagnostics
        {
            ushort high_water;
            uint alloc_count;
            uint fail_count;
        }

        struct JumboDiagnostics
        {
            ushort pages_in_use;
            ushort high_water;
            uint alloc_count;
            uint fail_count;
        }

        __gshared CategoryDiagnostics[2] _category_diagnostics;
        __gshared JumboDiagnostics _jumbo_diagnostics;
    }

    __gshared Critical _lock;
    __gshared AllocationHeader*[2] _free_lists;
    __gshared ushort[2] _allocated_pages;
    __gshared ushort[2] _free_pages;
    __gshared bool _initialised;

    size_t page_size(ubyte category)
        => allocation_header_size + ((page_payload_size(category) + 7) & ~cast(size_t)7);

    ushort max_pages(ubyte category)
        => category == 0 ? small_max_pages : large_max_pages;

    ushort prealloc_pages(ubyte category)
        => category == 0 ? small_prealloc_pages : large_prealloc_pages;

    AllocationHeader* header_of(const(void)* payload)
        => cast(AllocationHeader*)(payload - allocation_header_size);

    void preallocate(ubyte category, ushort count)
    {
        foreach (_; 0 .. count)
        {
            AllocationHeader* page = allocate_page(category);
            if (!page)
                break;
            cache_page(category, page);
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

        void[] mem = alloc(page_size(category), 8);
        if (mem.ptr)
            return cast(AllocationHeader*)mem.ptr;

        auto guard = _lock.acquire();
        --_allocated_pages[category];
        return null;
    }

    AllocationHeader* take_cached_page(ubyte category)
    {
        auto guard = _lock.acquire();
        AllocationHeader* page = _free_lists[category];
        if (page)
        {
            _free_lists[category] = page.next;
            --_free_pages[category];
        }
        return page;
    }

    void cache_page(ubyte category, AllocationHeader* page)
    {
        auto guard = _lock.acquire();
        page.next = _free_lists[category];
        _free_lists[category] = page;
        ++_free_pages[category];
    }

    void[] alloc_pooled(ubyte category, size_t required)
    {
        AllocationHeader* page = take_cached_page(category);
        if (!page)
            page = allocate_page(category);
        if (!page)
            page = take_cached_page(category);
        if (!page)
        {
            record_failure(category);
            return alloc_heap_page(required);
        }

        page.tag = cast(size_t)category << 1;
        page.next = null;
        record_alloc(category);
        return (cast(void*)page + allocation_header_size)[0 .. page_payload_size(category)];
    }

    void record_alloc(ubyte category)
    {
        version (PagePoolDiagnostics)
        {
            auto guard = _lock.acquire();
            CategoryDiagnostics* diagnostics = &_category_diagnostics[category];
            ++diagnostics.alloc_count;
            ushort in_use = cast(ushort)(_allocated_pages[category]
                - _free_pages[category]);
            if (in_use > diagnostics.high_water)
                diagnostics.high_water = in_use;
        }
    }

    void record_failure(ubyte category)
    {
        version (PagePoolDiagnostics)
        {
            auto guard = _lock.acquire();
            ++_category_diagnostics[category].fail_count;
        }
    }

    void record_jumbo_alloc()
    {
        version (PagePoolDiagnostics)
        {
            auto guard = _lock.acquire();
            ++_jumbo_diagnostics.alloc_count;
            if (++_jumbo_diagnostics.pages_in_use > _jumbo_diagnostics.high_water)
                _jumbo_diagnostics.high_water = _jumbo_diagnostics.pages_in_use;
        }
    }

    void record_jumbo_failure()
    {
        version (PagePoolDiagnostics)
        {
            auto guard = _lock.acquire();
            ++_jumbo_diagnostics.fail_count;
        }
    }

    void record_jumbo_free()
    {
        version (PagePoolDiagnostics)
        {
            auto guard = _lock.acquire();
            --_jumbo_diagnostics.pages_in_use;
        }
    }
}


void page_pool_tiny_test()()
{
    alias TestPool = PagePool!(56, 8, 4, 248, 4, 0);

    TestPool.page_pool_deinit();
    assert(TestPool.page_pool_init());
    assert(!TestPool.page_pool_init());
    assert(TestPool.page_payload_size(0) == 56);
    assert(TestPool.page_payload_size(1) == 248);

    Page* page = TestPool.page_alloc(32);
    assert(page.length == 32 && (cast(size_t)page.data.ptr & 7) == 0);
    assert(TestPool.page_category(page) == 0);
    TestPool.page_free(page);
    assert(TestPool._free_pages[0] == 4);

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
    assert(TestPool._free_pages[0] == 4);
    TestPool.page_free(keep);

    Page* medium = TestPool.page_alloc(100);
    assert(medium.length == 100 && TestPool.page_category(medium) == 1);
    Page* jumbo = TestPool.page_alloc(1000);
    assert(jumbo.length == 1000);
    assert((cast(size_t)jumbo.data.ptr & 7) == 0);
    assert(TestPool.page_category(jumbo) == page_category_heap);
    TestPool.page_free(jumbo);
    TestPool.page_free(medium);

    Page* reserved = TestPool.page_alloc(1000, size_t.sizeof, 3, 64);
    assert(reserved.headroom >= 3 && reserved.tailroom >= 64);
    TestPool.page_free(reserved);

    version (PagePoolDiagnostics)
    {
        PagePoolStats stats = TestPool.page_pool_stats(0);
        assert(stats.high_water == 8 && stats.fail_count == 1);
        assert(TestPool.page_pool_stats(page_category_heap).alloc_count == 3);
    }

    import urt.mem.reclaim : reclaim_memory;
    reclaim_memory(1);

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
