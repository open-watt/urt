module urt.array;

import urt.mem;
import urt.traits : is_some_char;

nothrow @nogc:


enum Alloc_T { Value }
alias Alloc = Alloc_T.Value;
enum Concat_T { Value }
alias Concat = Concat_T.Value;
enum Reserve_T { Value }
alias Reserve = Reserve_T.Value;


bool beginsWith(T, U)(const(T)[] arr, U[] rh) pure
    => rh.length <= arr.length && arr[0 .. rh.length] == rh[];

bool endsWith(T, U)(const(T)[] arr, U[] rh) pure
    => rh.length <= arr.length && arr[$ - rh.length .. $] == rh[];

//Slice<T> take(ptrdiff_t n)
//Slice<T> drop(ptrdiff_t n)

bool empty(T)(const T[] arr) pure
{
    return arr.length == 0;
}

bool empty(T, K)(ref const T[K] arr) pure
{
    return arr.length == 0;
}

ref inout(T) popFront(T)(ref inout(T)[] arr) pure
{
    debug assert(arr.length > 0);
    arr = arr.ptr[1..arr.length];
    return arr.ptr[-1];
}

ref inout(T) popBack(T)(ref inout(T)[] arr) pure
{
    debug assert(arr.length > 0);
    arr = arr.ptr[0..arr.length - 1];
    return arr.ptr[arr.length];
}

inout(T)[] takeFront(T)(ref inout(T)[] arr, size_t count) pure
{
    debug assert(count <= arr.length);
    inout(T)[] t = arr.ptr[0 .. count];
    arr = arr.ptr[count .. arr.length];
    return t;
}

ref inout(T)[N] takeFront(size_t N, T)(ref inout(T)[] arr) pure
{
    debug assert(N <= arr.length);
    inout(T)* t = arr.ptr;
    arr = arr.ptr[N .. arr.length];
    return t[0..N];
}

inout(T)[] takeBack(T)(ref inout(T)[] arr, size_t count) pure
{
    debug assert(count <= arr.length);
    inout(T)[] t = arr.ptr[arr.length - count .. arr.length];
    arr = arr.ptr[0 .. arr.length - count];
    return t;
}

ref inout(T)[N] takeBack(size_t N, T)(ref inout(T)[] arr) pure
{
    debug assert(N <= arr.length);
    inout(T)* t = arr.ptr + arr.length - N;
    arr = arr.ptr[0 .. arr.length - N];
    return t[0..N];
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findFirst(T, U)(const(T)[] arr, auto ref const U el)
    if (!is_some_char!T)
{
    size_t i = 0;
    while (i < arr.length && !arr[i].elCmp(el))
        ++i;
    return i;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findLast(T, U)(const(T)[] arr, auto ref const U el)
    if (!is_some_char!T)
{
    ptrdiff_t last = arr.length-1;
    while (last >= 0 && !arr[last].elCmp(el))
        --last;
    return last < 0 ? arr.length : last;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findFirst(T, U)(const(T)[] arr, U[] seq)
    if (!is_some_char!T)
{
    if (seq.length == 0)
        return 0;
    if (arr.length < seq.length)
        return arr.length;
    size_t i = 0;
    for (; i <= arr.length - seq.length; ++i)
    {
        if (arr[i .. i + seq.length] == seq[])
            return i;
    }
    return arr.length;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findLast(T, U)(const(T)[] arr, U[] seq)
    if (!is_some_char!T)
{
    if (seq.length == 0)
        return arr.length;
    if (arr.length < seq.length)
        return arr.length;
    ptrdiff_t i = arr.length - seq.length;
    for (; i >= 0; --i)
    {
        if (arr[i .. i + seq.length] == seq[])
            return i;
    }
    return arr.length;
}

size_t findFirst(T)(const(T)[] arr, bool delegate(ref const T) nothrow @nogc pred)
    if (!is_some_char!T)
{
    size_t i = 0;
    while (i < arr.length && !pred(arr[i]))
        ++i;
    return i;
}

bool contains(T, U)(const(T)[] arr, auto ref const U el, size_t *index = null)
    if (!is_some_char!T)
{
    size_t i = findFirst(arr, el);
    if (i == arr.length)
        return false;
    if (index)
        *index = i;
    return true;
}

bool contains(T, U)(const(T)[] arr, U[] seq, size_t *index = null)
    if (!is_some_char!T)
{
    size_t i = findFirst(arr, seq);
    if (i == arr.length)
        return false;
    if (index)
        *index = i;
    return true;
}

bool contains(T)(const(T)[] arr, bool delegate(ref const T) nothrow @nogc pred, size_t *index = null)
    if (!is_some_char!T)
{
    size_t i = findFirst(arr, pred);
    if (i == arr.length)
        return false;
    if (index)
        *index = i;
    return true;
}

ptrdiff_t indexOfElement(T, U)(const(T)[] arr, const(U)* el)
{
    if (el < arr.ptr || el >= arr.ptr + arr.length)
        return -1;
    return el - arr.ptr;
}

inout(T)* search(T)(inout(T)[] arr, bool delegate(ref const T) nothrow @nogc pred)
{
    foreach (ref e; arr)
    {
        if (pred(e))
            return &e;
    }
    return null;
}

U[] copyTo(T, U)(T[] arr, U[] dest)
{
    assert(dest.length >= arr.length);
    dest[0 .. arr.length] = arr[];
    return dest[0 .. arr.length];
}

T[] duplicate(T)(const T[] src, NoGCAllocator allocator) nothrow @nogc
{
    T[] r = cast(T[])allocator.alloc(src.length * T.sizeof);
    r[] = src[];
    return r;
}


// Array introduces static-sized and/or stack-based ownership. this is useful anywhere that fixed-length arrays are appropriate
// Array will fail-over to an allocated buffer if the contents exceed the fixed size
struct Array(T, size_t EmbedCount = 0)
{
    static assert(EmbedCount == 0, "Not without move semantics!");

    // constructors

    // TODO: DELETE POSTBLIT!
    this(this)
    {
        T[] t = this[];

        ptr = null;
        _length = 0;
        this = t[];
    }

    this(ref typeof(this) val)
    {
        this(val[]);
    }
    this(size_t EC)(ref Array!(T, EC) val)
        if (EC != EmbedCount)
    {
        this(val[]);
    }

    this(typeof(null)) {}

    this(U)(scope U[] arr...)
        if (is(U : T))
    {
        debug assert(arr.length <= uint.max);
        reserve(arr.length);
        for (uint i = 0; i < arr.length; ++i)
            emplace!T(&ptr[i], arr.ptr[i]);
        _length = cast(uint)arr.length;
    }

    this(U, size_t N)(ref U[N] arr)
        if (is(U : T))
    {
        this(arr[]);
    }

    this(Alloc_T, size_t count)
    {
        resize(count);
    }

    this(Reserve_T, size_t count)
    {
        reserve(count);
    }

    this(Things...)(Concat_T, auto ref Things things)
    {
        concat(forward!things);
    }

    ~this()
    {
        clear();
        if (hasAllocation())
            free(ptr);
    }

nothrow @nogc:

    // assignment

    void opAssign(ref typeof(this) val)
    {
        opAssign(val[]);
    }
    void opAssign(size_t EC)(ref Array!(T, EC) val)
        if (EC != EmbedCount)
    {
        opAssign(val[]);
    }

    void opAssign(typeof(null))
    {
        clear();
    }

    void opAssign(U)(U[] arr)
        if (is(U : T))
    {
        // TODO: WHAT IF arr IS A SLICE OF THIS?!!?

        debug assert(arr.length <= uint.max);
        clear();
        reserve(arr.length);
        for (uint i = 0; i < arr.length; ++i)
            emplace!T(&ptr[i], arr.ptr[i]);
        _length = cast(uint)arr.length;
    }

    void opAssign(U, size_t N)(U[N] arr)
        if (is(U : T))
    {
        opAssign(arr[]);
    }

    // manipulation
    ref Array!(T, EmbedCount) concat(Things...)(auto ref Things things)
    {
        reserve(_length + things.length);
        static foreach (i; 0 .. things.length)
        {
            static if (is(T == class) || is(T == interface))
                ptr[_length++] = things[i];
            else
                emplace!T(&ptr[_length++], forward!(things[i]));
        }
        return this;
    }

    bool empty() const
        => _length == 0;
    size_t length() const
        => _length;

    ref inout(T) front() inout
    {
        debug assert(_length > 0, "Range error");
        return ptr[0];
    }
    ref inout(T) back() inout
    {
        debug assert(_length > 0, "Range error");
        return ptr[_length - 1];
    }

    ref T pushFront()
    {
        static if (is(T == class) || is(T == interface))
            return pushFront(null);
        else
            return pushFront(T.init);
    }
    ref T pushFront(U)(auto ref U item)
        if (is(U : T))
    {
        static if (is(T == class) || is(T == interface))
        {
            reserve(_length + 1);
            for (uint i = _length++; i > 0; --i)
                ptr[i] = ptr[i-1];
            return (ptr[0] = item);
        }
        else
        {
            reserve(_length + 1);
            for (uint i = _length++; i > 0; --i)
            {
                moveEmplace!T(ptr[i-1], ptr[i]);
                destroy!false(ptr[i-1]);
            }
            return *emplace!T(&ptr[0], forward!item);
        }
    }

    ref T pushBack()
    {
        static if (is(T == class) || is(T == interface))
            return pushBack(null);
        else
            return pushBack(T.init);
    }
    ref T pushBack(U)(auto ref U item)
        if (is(U : T))
    {
        reserve(_length + 1);
        static if (is(T == class) || is(T == interface))
            return (ptr[_length++] = item);
        else
            return *emplace!T(&ptr[_length++], forward!item);
    }

    ref T emplaceFront(Args...)(auto ref Args args)
        if (!is(T == class) && !is(T == interface))
    {
        reserve(_length + 1);
        for (uint i = _length++; i > 0; --i)
        {
            moveEmplace(ptr[i-1], ptr[i]);
            destroy!false(ptr[i-1]);
        }
        retirn *emplace!T(&ptr[0], forward!args);
    }

    ref T emplaceBack(Args...)(auto ref Args args)
        if (!is(T == class) && !is(T == interface))
    {
        reserve(_length + 1);
        return *emplace!T(&ptr[_length++], forward!args);
    }

    T popFront()
    {
        debug assert(_length > 0);

        // TODO: this should be removed and uses replaced with a queue container
        static if (is(T == class) || is(T == interface))
        {
            T copy = ptr[0];
            for (uint i = 1; i < _length; ++i)
                ptr[i-1] = ptr[i];
            ptr[--_length] = null;
            return copy;
        }
        else
        {
            T copy = ptr[0].move;
            for (uint i = 1; i < _length; ++i)
            {
                destroy!false(ptr[i-1]);
                moveEmplace(ptr[i], ptr[i-1]);
            }
            destroy!false(ptr[--_length]);
            return copy;
        }
    }

    T popBack()
    {
        debug assert(_length > 0);

        static if (is(T == class) || is(T == interface))
        {
            T copy = ptr[--_length];
            ptr[_length] = null;
            return copy;
        }
        else
        {
            T copy = ptr[--_length].move;
            destroy!false(ptr[_length]);
            return copy;
        }
    }

    Array!T takeFront(size_t count)
    {
        assert(false, "TODO");
    }

    Array!(T, N) takeFront(size_t N)()
    {
        assert(false, "TODO");
    }

    Array!T takeBack(size_t count)
    {
        assert(false, "TODO");
    }

    Array!(T, N) takeBack(size_t N)()
    {
        assert(false, "TODO");
    }

    void remove(size_t i)
    {
        debug assert(i < _length);

        static if (is(T == class) || is(T == interface))
        {
            ptr[i .. _length - 1] = ptr[i + 1 .. _length];
            ptr[--_length] = null;
        }
        else
        {
            destroy!false(ptr[i]);
            for (size_t j = i + 1; j < _length; ++j)
            {
                moveEmplace(ptr[j], ptr[j-1]);
                destroy!false(ptr[j]);
            }
            --_length;
        }
    }

    void remove(size_t i, size_t count)
    {
        debug assert(i + count <= _length);

        static if (is(T == class) || is(T == interface))
        {
            ptr[i .. _length - count] = ptr[i + count .. _length];
            ptr[_length - count .. _length] = null;
            _length -= cast(uint)count;
        }
        else
        {
            for (size_t j = i; j < i + count; ++j)
                destroy!false(ptr[j]);
            for (size_t j = i + count; j < _length; ++j)
            {
                moveEmplace(ptr[j], ptr[j - count]);
                destroy!false(ptr[j]);
            }
        }
        _length -= cast(uint)count;
    }


    void remove(const(T)* pItem)                    { remove(ptr[0 .. _length].indexOfElement(pItem)); }
    void removeFirst(U)(ref const U item)           { remove(ptr[0 .. _length].findFirst(item)); }

    void removeSwapLast(size_t i)
    {
        assert(i < _length, "Range error");
        static if (is(T == class) || is(T == interface))
        {
            ptr[i] = ptr[--_length];
            ptr[_length] = null;
        }
        else
        {
            destroy!false(ptr[i]);
            emplace!T(&ptr[i], ptr[--_length].move);
            destroy!false(ptr[_length]);
        }
    }

    void removeSwapLast(const(T)* pItem)            { removeSwapLast(ptr[0 .. _length].indexOfElement(pItem)); }
    void removeFirstSwapLast(U)(ref const U item)   { removeSwapLast(ptr[0 .. _length].findFirst(item)); }

    void sort(alias pred = void)()
    {
        import urt.algorithm : qsort;
        qsort!(pred)(ptr[0.._length]);
    }

    inout(void)[] getBuffer() inout
    {
        static if (EmbedCount > 0)
            return ptr ? ptr[0 .. allocCount()] : embed[];
        else
            return ptr ? ptr[0 .. allocCount()] : null;
    }

    bool opCast(T : bool)() const pure
        => _length != 0;

    size_t opDollar() const pure
        => _length;

    // full slice: arr[]
    inout(T)[] opIndex() inout pure
        => ptr[0 .. _length];

    void opIndexAssign(U)(U[] rh)
    {
        debug assert(rh.length == _length, "Range error");
        ptr[0 .. _length] = rh[];
    }

    // array indexing: arr[i]
    ref inout(T) opIndex(size_t i) inout pure
    {
        debug assert(i < _length, "Range error");
        return ptr[i];
    }

    // array slicing: arr[x .. y]
    inout(T)[] opIndex(size_t[2] i) inout pure
        => ptr[i[0] .. i[1]];

    void opIndexAssign(U)(U[] rh, size_t[2] i)
    {
        debug assert(i[1] <= _length && i[1] - i[0] == rh.length, "Range error");
        ptr[i[0] .. i[1]] = rh[];
    }

    size_t[2] opSlice(size_t dim : 0)(size_t x, size_t y) const pure
    {
        debug assert(y <= _length, "Range error");
        return [x, y];
    }

    void opOpAssign(string op : "~", U)(auto ref U el)
        if (is(U : T))
    {
        pushBack(forward!el);
    }

    void opOpAssign(string op : "~", U)(U[] arr)
        if (is(U : T))
    {
        reserve(_length + arr.length);
        foreach (ref e; arr)
            pushBack(e);
    }

    void reserve(size_t count)
    {
        if (count > allocCount())
        {
            debug assert(count <= uint.max, "Exceed maximum size");
            T* newArray = allocate(cast(uint)count);

            // TODO: POD should memcpy... (including class)

            static if (is(T == class) || is(T == interface))
            {
                for (uint i = 0; i < _length; ++i)
                    newArray[i] = ptr[i];
            }
            else
            {
                for (uint i = 0; i < _length; ++i)
                {
                    moveEmplace(ptr[i], newArray[i]);
                    destroy!false(ptr[i]);
                }
            }

            if (hasAllocation())
                free(ptr);

            ptr = newArray;
        }
    }

    void alloc(size_t count)
    {
        assert(false);
    }

    void resize(size_t count)
    {
        if (count == _length)
            return;

        if (count < _length)
        {
            static if (is(T == class) || is(T == interface))
            {
                for (ptrdiff_t i = _length - 1; i >= count; --i)
                    ptr[i] = null;
            }
            else
            {
                for (ptrdiff_t i = _length - 1; i >= count; --i)
                    destroy!false(ptr[i]);
            }
            _length = cast(uint)count;
        }
        else
        {
            reserve(count);
            static if (is(T == class) || is(T == interface))
            {
                foreach (i; _length .. count)
                    ptr[i] = null;
            }
            else
            {
                foreach (i; _length .. count)
                    emplace!T(&ptr[i]);
            }
            _length = cast(uint)count;
        }
    }

    void clear()
    {
        static if (!is(T == class) && !is(T == interface))
            for (uint i = 0; i < _length; ++i)
                destroy!false(ptr[i]);
        _length = 0;
    }

    import urt.string.format : FormatArg, formatValue;
    ptrdiff_t toString()(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        static if (is(T == class) || is(T == interface))
            assert(false, "TODO: class toString is not @nogc!");
        else
            return formatValue(ptr[0 .. _length], buffer, format, formatArgs);
    }

    ptrdiff_t fromString()(const(char)[] s)
    {
        assert(false, "TODO");
    }

private:
    T* ptr;
    uint _length;

    static if (EmbedCount > 0)
        T[EmbedCount] embed = void;

    bool hasAllocation() const pure
    {
        static if (EmbedCount > 0)
            return ptr && ptr != embed.ptr;
        else
            return ptr !is null;
    }
    uint allocCount() const pure
        => hasAllocation() ? (cast(uint*)ptr)[-1] : EmbedCount;

    T* allocate(uint count)
    {
        enum AllocAlignment = T.alignof < 4 ? 4 : T.alignof;
        enum AllocPrefixBytes = T.sizeof < 4 ? 4 : T.sizeof;

        void[] mem = defaultAllocator().alloc(AllocPrefixBytes + T.sizeof * count, AllocAlignment);
        T* array = cast(T*)(mem.ptr + AllocPrefixBytes);
        (cast(uint*)array)[-1] = count;
        return array;
    }
    void free(T* ptr)
    {
        enum AllocPrefixBytes = T.sizeof < 4 ? 4 : T.sizeof;

        defaultAllocator().free((cast(void*)ptr - AllocPrefixBytes)[0 .. AllocPrefixBytes + T.sizeof * allocCount()]);
    }

    pragma(inline, true)
    static uint numToAlloc(uint i) pure
    {
        // TODO: i'm sure we can imagine a better heuristic...
        return i > 16 ? i * 2 : 16;
    }

    auto __debugExpanded() const pure => ptr[0 .. _length];
}

// SharedArray is a ref-counted array which can be distributed
struct SharedArray(T)
{
    // TODO: DELETE POSTBLIT!
    this(this)
    {
        if (ptr)
            incRef();
    }

    this(typeof(null)) {}

    this(ref typeof(this) val)
    {
        ptr = val.ptr;
        _length = val._length;
        if (ptr)
            incRef();
    }

    this(U)(U[] arr)
        if (is(U : T))
    {
        this = arr[];
    }

    this(U, size_t N)(ref U[N] arr)
        if (is(U : T))
    {
        this = arr[];
    }

    ~this()
    {
        clear();
    }

nothrow @nogc:

    void opAssign(typeof(null))
    {
        clear();
    }

    void opAssign(ref typeof(this) val)
    {
        clear();

        ptr = val.ptr;
        _length = val._length;
        if (ptr)
            incRef();
    }

    void opAssign(U)(U[] arr)
        if (is(U : T))
    {
        debug assert(arr.length <= uint.max);
        uint len = cast(uint)arr.length;

        clear();

        _length = len;
        if (len > 0)
        {
            ptr = allocate(len);
            for (uint i = 0; i < len; ++i)
                emplace!T(&ptr[i], arr.ptr[i]);
        }
        else
            ptr = null;
    }

    void opAssign(U, size_t N)(U[N] arr)
        if (is(U : T))
    {
        this = arr[];
    }

    bool empty() const
        => _length == 0;
    size_t length() const
        => _length;

    ref inout(T) front() inout
    {
        debug assert(_length > 0, "Range error");
        return ptr[0];
    }
    ref inout(T) back() inout
    {
        debug assert(_length > 0, "Range error");
        return ptr[_length - 1];
    }

//    inout(void)[] getBuffer() inout
//    {
//        static if (EmbedCount > 0)
//            return ptr ? ptr[0 .. allocCount()] : embed[];
//        else
//            return ptr ? ptr[0 .. allocCount()] : null;
//    }

    bool opCast(T : bool)() const
        => _length != 0;

    size_t opDollar() const
        => _length;

    // full slice: arr[]
    inout(T)[] opIndex() inout
        => ptr[0 .. _length];

    // array indexing: arr[i]
    ref inout(T) opIndex(size_t i) inout
    {
        debug assert(i < _length, "Range error");
        return ptr[i];
    }

    // array slicing: arr[x .. y]
    inout(T)[] opIndex(uint[2] i) inout
        => ptr[i[0] .. i[1]];

    uint[2] opSlice(size_t dim : 0)(size_t x, size_t y)
    {
        debug assert(y <= _length, "Range error");
        return [cast(uint)x, cast(uint)y];
    }

    void clear()
    {
        static if (!is(T == class) && !is(T == interface))
            for (uint i = 0; i < _length; ++i)
                ptr[i].destroy!false();

        if (ptr)
            decRef();
        ptr = null;
        _length = 0;
    }

private:
    T* ptr;
    uint _length;

    void incRef()
    {
        ++(cast(uint*)ptr)[-1];
    }

    void decRef()
    {
        uint* rc = cast(uint*)ptr - 1;
        if (*rc == 0)
            free();
        else
            --*rc;
    }

    T* allocate(uint count)
    {
        enum AllocAlignment = T.alignof < uint.alignof ? uint.alignof : T.alignof;

        void[] mem = defaultAllocator().alloc(AllocAlignment + T.sizeof * count, AllocAlignment);
        T* array = cast(T*)(mem.ptr + AllocPrefixBytes);
        (cast(uint*)array)[-1] = 0;
        return array;
    }
    void free()
    {
        enum AllocAlignment = T.alignof < uint.alignof ? uint.alignof : T.alignof;

        defaultAllocator().free((cast(void*)ptr - AllocAlignment)[0 .. AllocAlignment + T.sizeof * allocCount()]);
    }
}


private:

pragma(inline, true)
bool elCmp(T)(const T a, const T b)
    if (is(T == class) || is(T == interface))
{
    return a is b;
}

pragma(inline, true)
bool elCmp(T)(const T a, const T b)
    if (is(T == U[], U))
{
    return a[] == b[];
}

pragma(inline, true)
bool elCmp(T)(auto ref const T a, auto ref const T b)
    if (!is(T == class) && !is(T == interface) && !is(T == U[], U))
{
    return a == b;
}
