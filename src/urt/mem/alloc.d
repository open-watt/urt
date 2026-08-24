module urt.mem.alloc;

import urt.mem;

version (Tiny) {} else
    version = MemoryThreats;

nothrow @nogc:


enum MemFlags : ubyte
{
    none     = 0,

    // Speed bits are placement *preferences*
    fast     = 1,   // prefer internal SRAM
    slow     = 2,   // prefer slow overflow memory
    fastest  = 3,   // prefer TCM (single-cycle), else internal SRAM

    dma      = 0x4, // DMA-accessible (hard requirement)
}

MemFlags mem_speed(MemFlags flags) pure => cast(MemFlags)(flags & 3);
bool mem_is_dma(MemFlags flags) pure => (flags & MemFlags.dma) != 0;


void[] alloc(size_t size, MemFlags flags = MemFlags.none) pure
    => alloc(size, size_t.sizeof, flags);

void[] alloc(size_t size, size_t alignment, MemFlags flags = MemFlags.none) pure
{
    import urt.util : is_power_of_2;

    assert(is_power_of_2(alignment), "Alignment must be a power of two!");

    void[] mem = _alloc(size, alignment, flags);
    if (mem.ptr is null && size > 0)
    {
        import urt.mem.reclaim : ReclaimRetry, reclaim_memory;
        ReallocRetry retry = ReallocRetry(&mem, null, size, alignment, flags);
        alias ReclaimFn = void function(size_t, ReclaimRetry, void*) pure nothrow @nogc;
        (cast(ReclaimFn) &reclaim_memory)(reclaim_size(size, alignment), &retry_realloc, &retry);
    }
    if (mem.ptr is null)
    {
        static if (__traits(compiles, _alloc_failure(size, alignment, flags)))
            _alloc_failure(size, alignment, flags);
    }
    version (MemoryThreats)
    {
        if (mem.ptr !is null)
        {
            import urt.mem.reclaim : account_alloc;
            alias AccountFn = void function(size_t) pure nothrow @nogc;
            (cast(AccountFn) &account_alloc)(accounted_size(mem.ptr, mem.length));
        }
    }
    version (AllocTracking)
    {
        import urt.mem.profile.record : track_alloc;
        if (mem.ptr !is null)
        {
            alias TrackFn = void function(void*, size_t) pure nothrow @nogc;
            (cast(TrackFn) &track_alloc)(mem.ptr, mem.length);
        }
    }
    version (AllocProfile)
    {
        import urt.mem.profile.log : profile_alloc;
        if (mem.ptr !is null)
        {
            alias ProfileFn = void function(void*, size_t) pure nothrow @nogc;
            (cast(ProfileFn) &profile_alloc)(mem.ptr, mem.length);
        }
    }
    return mem;
}

void[] realloc(void[] mem, size_t new_size, size_t alignment = 8, MemFlags flags = MemFlags.none) pure
{
    import urt.util : min;

    if (new_size == 0)
    {
        free(mem);
        return null;
    }
    if (mem.ptr is null)
        return alloc(new_size, alignment, flags);

    static if (has_realloc)
    {
        void* old_ptr = mem.ptr;
        size_t old_size = mem.length;
        version (MemoryThreats)
            size_t old_accounted_size = accounted_size(mem.ptr, mem.length);
        void[] new_mem = _realloc(mem, new_size, alignment, flags);
        if (new_mem.ptr is null)
        {
            import urt.mem.reclaim : ReclaimRetry, reclaim_memory;
            ReallocRetry retry = ReallocRetry(&new_mem, mem, new_size, alignment, flags);
            alias ReclaimFn = void function(size_t, ReclaimRetry, void*) pure nothrow @nogc;
            (cast(ReclaimFn) &reclaim_memory)(reclaim_size(new_size, alignment), &retry_realloc, &retry);
        }
        if (new_mem.ptr is null)
        {
            static if (__traits(compiles, _alloc_failure(new_size, alignment, flags)))
                _alloc_failure(new_size, alignment, flags);
        }
        version (MemoryThreats)
        {
            if (new_mem.ptr !is null)
            {
                import urt.mem.reclaim : account_alloc, account_free;
                alias AccountFn = void function(size_t) pure nothrow @nogc;
                size_t new_accounted_size = accounted_size(new_mem.ptr, new_mem.length);
                if (new_accounted_size > old_accounted_size)
                    (cast(AccountFn) &account_alloc)(new_accounted_size - old_accounted_size);
                else if (new_accounted_size < old_accounted_size)
                    (cast(AccountFn) &account_free)(old_accounted_size - new_accounted_size);
            }
        }
        version (AllocTracking)
        {
            import urt.mem.profile.record : track_realloc;
            if (new_mem.ptr !is null)
            {
                alias TrackFn = void function(void*, void*, size_t) pure nothrow @nogc;
                (cast(TrackFn) &track_realloc)(old_ptr, new_mem.ptr, new_mem.length);
            }
        }
        version (AllocProfile)
        {
            import urt.mem.profile.log : profile_realloc;
            if (new_mem.ptr !is null)
            {
                alias ProfileFn = void function(void*, void*, size_t, size_t) pure nothrow @nogc;
                (cast(ProfileFn) &profile_realloc)(old_ptr, new_mem.ptr, new_mem.length, old_size);
            }
        }
        return new_mem;
    }
    else
    {
        // Fallback path uses nested alloc/free, which are already hooked.
        void[] new_mem = alloc(new_size, alignment, flags);
        if (new_mem.ptr !is null)
        {
            size_t copy = min(mem.length, new_size);
            new_mem[0 .. copy] = mem[0 .. copy];
        }
        free(mem);
        return new_mem;
    }
}

private size_t reclaim_size(size_t size, size_t alignment) pure
{
    enum natural_alignment = size_t.sizeof;
    if (alignment <= natural_alignment)
        return size;
    size_t padding = alignment - natural_alignment;
    return size <= size_t.max - padding ? size + padding : size_t.max;
}

unittest
{
    assert(reclaim_size(100, size_t.sizeof) == 100);
    assert(reclaim_size(100, size_t.sizeof * 4) == 100 + size_t.sizeof * 3);
}

private struct ReallocRetry
{
    void[]* result;
    void[] mem;
    size_t new_size;
    size_t alignment;
    MemFlags flags;
}

private bool retry_realloc(void* context) pure
{
    ReallocRetry* retry = cast(ReallocRetry*)context;
    static if (has_realloc)
        *retry.result = _realloc(retry.mem, retry.new_size, retry.alignment, retry.flags);
    else
        *retry.result = _alloc(retry.new_size, retry.alignment, retry.flags);
    return (*retry.result).ptr !is null;
}

// a template so typed arrays don't silently bind here through T[] -> void[] and skip destruction
void free(T)(T[] mem) pure
    if (is(immutable T == immutable void))
{
    if (mem.ptr is null)
        return;
    version (MemoryThreats)
    {
        import urt.mem.reclaim : account_free;
        alias AccountFn = void function(size_t) pure nothrow @nogc;
        (cast(AccountFn) &account_free)(accounted_size(cast(void*)mem.ptr, mem.length));
    }
    version (AllocTracking)
    {
        import urt.mem.profile.record : untrack_alloc;
        alias UntrackFn = void function(void*) pure nothrow @nogc;
        (cast(UntrackFn) &untrack_alloc)(mem.ptr);
    }
    version (AllocProfile)
    {
        import urt.mem.profile.log : profile_free;
        alias ProfileFn = void function(void*, size_t) pure nothrow @nogc;
        (cast(ProfileFn) &profile_free)(mem.ptr, mem.length);
    }
    _free(cast(void*)mem.ptr);
}

T* alloc(T, Args...)(MemFlags flags, auto ref Args args)
    if (!is(T == class))
{
    T* item = cast(T*)alloc(T.sizeof, T.alignof, flags).ptr;
    if (item)
        item.emplace(forward!args);
    return item;
}

T* alloc(T, Args...)(auto ref Args args)
    if (!is(T == class) && (Args.length == 0 || !is(Args[0] == MemFlags)))
    => alloc!T(MemFlags.none, forward!args);

T alloc(T, Args...)(MemFlags flags, auto ref Args args)
    if (is(T == class))
{
    T item = cast(T)alloc(__traits(classInstanceSize, T), __traits(classInstanceAlignment, T), flags).ptr;
    if (item)
        item.emplace(forward!args);
    return item;
}

T alloc(T, Args...)(auto ref Args args)
    if (is(T == class) && (Args.length == 0 || !is(Args[0] == MemFlags)))
    => alloc!T(MemFlags.none, forward!args);

T[] alloc_array(T, Args...)(MemFlags flags, size_t count, auto ref Args args)
    if (!is(T == class))
{
    if (count == 0)
        return null;
    T[] items = cast(T[])alloc(T.sizeof * count, T.alignof, flags);
    if (items.ptr is null)
        return null;
    static if (Args.length == 0)
    {
        import urt.array : init_all;
        init_all(items);
    }
    else
    {
        for (size_t i = 0; i < count - 1; ++i)
            emplace(&items[i], args);
        emplace(&items[count - 1], forward!args);
    }
    return items;
}

T[] alloc_array(T)(MemFlags flags, size_t count)
    if (is(T == class))
{
    if (count == 0)
        return null;
    T[] items = cast(T[])alloc(T.sizeof * count, T.alignof, flags);
    if (items.ptr is null)
        return null;
    items[] = null;
    return items;
}

T[] alloc_array(T, N, Args...)(N count, auto ref Args args)
    if (is(N : size_t) && !is(N == MemFlags))
    => alloc_array!T(MemFlags.none, count, forward!args);

void free(T)(T* item)
    if (!is(T == class) && !is(immutable T == immutable void))
{
    if (item is null)
        return;
    destroy!false(*item);
    free((cast(void*)item)[0 .. T.sizeof]);
}

void free(T)(T item)
    if (is(T == class))
{
    if (item is null)
        return;
    // HACK: druntime can't destroy a @nogc class
    void function(T) nothrow destroy_fun = &destroy!(false, T);
    (cast(void function(T) nothrow @nogc)destroy_fun)(item);
    free((cast(void*)item)[0 .. __traits(classInstanceSize, T)]);
}

void free(T)(T[] items)
    if (!is(immutable T == immutable void))
{
    import urt.internal.traits : hasElaborateDestructor;
    import urt.traits : Unqual;

    static if (hasElaborateDestructor!T && is(T == Unqual!T))
    {
        foreach (ref i; items)
            destroy!false(i);
    }
    free(cast(void[])items);
}

void[] expand(void[] mem, size_t new_size) pure
{
    if (mem.ptr is null)
        return null;
    version (MemoryThreats)
        size_t old_accounted_size = accounted_size(mem.ptr, mem.length);
    static if (has_expand)
        void[] new_mem = _expand(mem, new_size);
    else static if (has_memsize)
    {
        void[] new_mem = null;
        if (new_size <= _memsize(mem.ptr))
            new_mem = mem.ptr[0 .. new_size];
    }
    else
    {
        void[] new_mem = null;
        assert(false, "unsupported");
    }
    version (MemoryThreats)
    {
        if (new_mem.ptr !is null)
        {
            import urt.mem.reclaim : account_alloc, account_free;
            alias AccountFn = void function(size_t) pure nothrow @nogc;
            size_t new_accounted_size = accounted_size(new_mem.ptr, new_mem.length);
            if (new_accounted_size > old_accounted_size)
                (cast(AccountFn) &account_alloc)(new_accounted_size - old_accounted_size);
            else if (new_accounted_size < old_accounted_size)
                (cast(AccountFn) &account_free)(old_accounted_size - new_accounted_size);
        }
    }
    version (AllocProfile)
    {
        import urt.mem.profile.log : profile_expand;
        if (new_mem.ptr !is null)
        {
            alias ProfileFn = void function(void*, size_t, size_t) pure nothrow @nogc;
            (cast(ProfileFn) &profile_expand)(new_mem.ptr, mem.length, new_mem.length);
        }
    }
    return new_mem;
}

size_t memsize(void* ptr) pure
{
    if (ptr is null)
        return 0;
    static if (has_memsize)
        return _memsize(ptr);
    else
        assert(false, "unsupported");
}

version (MemoryThreats)
{
    private size_t accounted_size(void* ptr, size_t requested) pure
    {
        static if (__traits(compiles, account_usable_size))
        {
            static if (account_usable_size)
                return _memsize(ptr);
            else
                return requested;
        }
        else
            return requested;
    }
}

void[] alloc_exec(size_t size) pure
{
    static if (has_exec)
        return _alloc_exec(size);
    else
        return null;
}

void free_exec(void[] mem) pure
{
    static if (has_exec)
    {
        if (mem.ptr !is null)
            _free_exec(mem);
    }
}

void[] alloc_retain(size_t size) pure
{
    static if (has_retain)
        return _alloc_retain(size);
    else
        return null;
}

void free_retain(void[] mem) pure
{
    static if (has_retain)
    {
        if (mem.ptr !is null)
            _free_retain(mem);
    }
}


// pointer tagging utilities -- for containers to store flags in low 3 bits
// of 8-byte aligned pointers. the allocator itself returns clean pointers.
T* tag(T)(T* ptr, MemFlags flags) pure
    => cast(T*)(cast(size_t)ptr | flags);

T* untag(T)(T* ptr) pure
    => cast(T*)(cast(size_t)ptr & ~cast(size_t)0x7);

MemFlags get_flags(void* ptr) pure
    => cast(MemFlags)(cast(size_t)ptr & 0x7);


version (Espressif)
    public import urt.driver.esp32.alloc;
else version (Bouffalo)
    public import urt.driver.bl_common.alloc;
else version (RP2350)
    public import urt.driver.rp2350.alloc;
else version (BK7231N)
    public import urt.driver.bk7231.alloc;
else version (BK7231T)
    public import urt.driver.bk7231.alloc;
else version (STM32F4)
    public import urt.driver.stm32.alloc;
else version (STM32F7)
    public import urt.driver.stm32.alloc;
else version (Windows)
    public import urt.driver.windows.alloc;
else version (Posix)
    public import urt.driver.posix.alloc;
else
    static assert(false, "No alloc driver for this platform");


unittest
{
    // basic alloc/free
    void[] mem = alloc(32, 8);
    assert(mem !is null);
    assert((cast(size_t)mem.ptr & 0x7) == 0); // 8-byte aligned
    assert(mem.length == 32);
    free(mem);

    // alloc with flags (on desktop, flags are ignored but API works)
    mem = alloc(64, 8, MemFlags.fast);
    assert(mem !is null);
    size_t s = memsize(mem.ptr);
    assert(s >= 64);
    free(mem);

    // realloc preserves data
    mem = alloc(16, 8);
    (cast(ubyte*)mem.ptr)[0 .. 16] = 0xAB;
    mem = realloc(mem, 64);
    assert(mem !is null);
    assert((cast(ubyte*)mem.ptr)[0] == 0xAB);
    free(mem);

    // expand
    mem = alloc(16, 8);
    void[] expanded = expand(mem, 8);
    if (expanded !is null)
        assert(expanded.ptr is mem.ptr);
    free(mem);

    // pointer tagging utilities
    void* p = mem.ptr;
    enum test_flags = cast(MemFlags)(MemFlags.fast | MemFlags.dma);
    void* tagged = tag(p, test_flags);
    assert(get_flags(tagged) == test_flags);
    assert(untag(tagged) is p);
}

unittest
{
    static int dtors;

    struct S
    {
    nothrow @nogc:
        int x;
        this(int arg) { x = arg; }
        ~this() { ++dtors; }
    }
    static class C
    {
    nothrow @nogc:
        int x;
        this(int arg) { x = arg; }
        ~this() { ++dtors; }
    }

    S* s = alloc!S(10);
    assert(s && s.x == 10);
    free(s);
    assert(dtors == 1);

    s = alloc!S(MemFlags.fastest, 20);
    assert(s && s.x == 20);
    free(s);
    assert(dtors == 2);

    C c = alloc!C(30);
    assert(c && c.x == 30);
    free(c);
    assert(dtors == 3);

    dtors = 0;
    S[] arr = alloc_array!S(4, 7);
    assert(arr.length == 4 && arr[0].x == 7 && arr[3].x == 7);
    free(arr);
    assert(dtors == 4);

    arr = alloc_array!S(MemFlags.slow, 2, 5);
    assert(arr.length == 2 && arr[1].x == 5);
    free(arr);
    assert(dtors == 6);

    ubyte[] buf = alloc_array!ubyte(MemFlags.fast, 64);
    assert(buf.length == 64);
    free(buf);

    C[] classes = alloc_array!C(MemFlags.none, 3);
    assert(classes.length == 3 && classes[0] is null);
    free(classes);
}
