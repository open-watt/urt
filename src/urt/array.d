module urt.array;

import urt.lifetime : move, emplace, moveEmplace;
import urt.mem : memcpy, memmove, memset;
import urt.mem.alloc;
import urt.mem.allocator : NoGCAllocator;
import urt.traits : is_some_char, is_primitive, is_trivial, Unqual;

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
    while (i < arr.length && !arr[i].el_cmp(el))
        ++i;
    return i;
}

// TODO: I'd like it if these only had one arg (T) somehow...
size_t findLast(T, U)(const(T)[] arr, auto ref const U el)
    if (!is_some_char!T)
{
    ptrdiff_t last = arr.length-1;
    while (last >= 0 && !arr[last].el_cmp(el))
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

// TODO: use is_trivially_copy_constructible!
private enum copy_use_memcpy(T, U) = is_trivial!T && is(Unqual!T == U);
private enum copy_use_memcpy(T) = copy_use_memcpy!(T, T);
// TODO: use is_trivially_move_constructible!
private enum move_use_memcpy(T, U) = is_trivial!T && is(Unqual!T == U);
private enum move_use_memcpy(T) = move_use_memcpy!(T, T);
private enum is_byte_copy_type(T) = is(T == ubyte) || is(T == byte) || is(T == char) || is(T == void);
private enum byte_copy_compatible(T, U) = is_byte_copy_type!(Unqual!T) && is_byte_copy_type!U;

pragma(inline, true)
U[] copy_to(bool overlapping = false, T, U)(T[] arr, U[] dest)
    if (copy_use_memcpy!(T, U) || byte_copy_compatible!(T, U))
{
    alias UT = Unqual!T;
    enum same_type = is(UT == U);

    static assert (!overlapping || same_type, "overlapping copy must be same type");
    assert(dest.length >= arr.length);

    if (__ctfe)
    {
        static if (same_type)
        {
            if (arr.ptr < dest.ptr)
            {
                for (ptrdiff_t i = ptrdiff_t(arr.length) - 1; i >= 0; --i)
                    dest[i] = arr[i];
                return dest[0 .. arr.length];
            }
        }
        for (size_t i = 0; i < arr.length; ++i)
            dest[i] = arr[i];
    }
    else
        copy_bytes!overlapping(dest.ptr, arr.ptr, arr.length * T.sizeof);
    return dest[0 .. arr.length];
}

U[] copy_to(bool overlapping = false, bool move = false, T, U)(T[] arr, U[] dest)
    if (!copy_use_memcpy!(T, U) && !byte_copy_compatible!(T, U))
{
    alias UT = Unqual!T;
    enum same_type = is(UT == U);

    static assert (!overlapping || same_type, "overlapping copy must be same type");
    assert(dest.length >= arr.length);

    if (__ctfe)
    {
        static if (same_type)
        {
            if (arr.ptr < dest.ptr)
            {
                for (ptrdiff_t i = ptrdiff_t(arr.length) - 1; i >= 0; --i)
                    dest[i] = arr[i];
                return dest[0 .. arr.length];
            }
        }
        for (size_t i = 0; i < arr.length; ++i)
            dest[i] = arr[i];
    }
    else static if (move)
    {
        static if (overlapping)
        {
            if (arr.ptr < dest.ptr && dest.ptr < arr.ptr + arr.length)
            {
                for (ptrdiff_t i = ptrdiff_t(arr.length) - 1; i >= 0; --i)
                    .move(arr[i], dest[i]);
                return dest[0 .. arr.length];
            }
        }
        for (size_t i = 0; i < arr.length; ++i)
            .move(arr[i], dest[i]);
    }
    else
    {
        static if (overlapping)
        {
            if (arr.ptr < dest.ptr && dest.ptr < arr.ptr + arr.length)
            {
                for (ptrdiff_t i = ptrdiff_t(arr.length) - 1; i >= 0; --i)
                    dest[i] = arr[i];
                return dest[0 .. arr.length];
            }
        }
        else static if (same_type)
            dest[] = arr[];
        else for (size_t i = 0; i < arr.length; ++i)
            dest[i] = arr[i];
    }
    return dest[0 .. arr.length];
}
pragma(inline, true)
U[] move_to(bool overlapping = false, T, U)(T[] arr, U[] dest)
    if (move_use_memcpy!(T, U) || byte_copy_compatible!(T, U))
    => copy_to!overlapping(arr, dest);

U[] move_to(bool overlapping = false, T, U)(T[] arr, U[] dest)
    if (!move_use_memcpy!(T, U) && !byte_copy_compatible!(T, U))
    => copy_to!(overlapping, true)(arr, dest);

void emplace_all(bool move = false, T, U)(T[] arr, U[] dest)
{
    assert(!__ctfe, "emplace_all should not be called at compile time");

    static if (move && move_use_memcpy!(T, U))
        move_to(cast(Unqual!T[])arr, dest);
    else static if ((!move && copy_use_memcpy!(T, U)) || (is(T : U) && is_trivial!U))
        copy_to(cast(Unqual!T[])arr, dest);
    else static if (move)
    {
//        pragma(msg, "move-emplace: ", T, " --> ", U);
        for (size_t i = 0; i < arr.length; ++i)
            moveEmplace(arr[i], dest[i]);
    }
    else
    {
//        pragma(msg, "emplace: ", T, " --> ", U);
        for (size_t i = 0; i < arr.length; ++i)
            emplace!T(&dest[i], arr[i]);
    }
}
void move_emplace_all(T, U)(T[] arr, U[] dest)
    => emplace_all!(true, T, U)(arr, dest);

void destroy_all(bool initialize = true, T)(T[] arr)
{
    assert(!__ctfe, "destroy_all should not be called at compile time");

    static if (is_trivial!T)
    {
        static if (initialize)
            init_all(arr);
    }
    else
    {
        for (uint i = 0; i < arr.length; ++i)
            destroy!initialize(arr[i]);
    }
}

void init_all(T)(T[] arr)
{
    assert(!__ctfe, "init_all should not be called at compile time");

    static if (is_trivial!T)
    {
        static if (__traits(isZeroInit, T))
            memset(arr.ptr, 0, arr.length * T.sizeof);
        else
            arr[] = T.init;
    }
    else for (size_t i = 0; i < arr.length; ++i)
        emplace!T(&arr[i]);
}

T[] duplicate(T)(const T[] src, NoGCAllocator allocator = null) nothrow @nogc
{
    T[] r;
    if (allocator)
        r = cast(T[])allocator.alloc(src.length * T.sizeof);
    else
        r = cast(T[])alloc(src.length * T.sizeof);
    emplace_all(src, r);
    return r;
}

// Array introduces static-sized and/or stack-based ownership. this is useful anywhere that fixed-length arrays are appropriate
// Array will fail-over to an allocated buffer if the contents exceed the fixed size
struct Array(T, size_t EmbedCount = 0)
{
    static assert(EmbedCount == 0, "Not without move semantics!");

    alias This = typeof(this);

    T* ptr;

    // constructors

    // TODO: DELETE POSTBLIT!
    this(this)
    {
        T[] t = this[];

        ptr = null;
        _length = 0;
        this = t[];
    }

    this(ref This val)
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
        emplace_all(arr[], ptr[0..arr.length]);
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
        if (has_allocation())
        {
            enum prefix = T.sizeof < 4 ? 4 : T.sizeof;
            array_free(ptr, T.sizeof, prefix);
        }
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
        emplace_all(arr[], ptr[0 .. arr.length]);
        _length = cast(uint)arr.length;
    }

    void opAssign(U, size_t N)(U[N] arr)
        if (is(U : T))
    {
        opAssign(arr[]);
    }

    // manipulation
    static if (!is_some_char!T)
    {
        alias concat = append; // TODO: REMOVE THIS ALIAS, we phase out the old name...

        ref Array!(T, EmbedCount) append(Things...)(auto ref Things things)
        {
            size_t ext_len = 0;
            static foreach (i; 0 .. things.length)
            {
                static if (is(Things[i] == U[], U) && is(U : T))
                    ext_len += things[i].length;
                else static if (is(Things[i] == U[N], U, size_t N) && is(U : T))
                    ext_len += N;
                else static if (is(Things[i] : T))
                    ext_len += 1;
                else
                    static assert(false, "Invalid type for concat");
            }
            grow(_length + ext_len);
            static foreach (i; 0 .. things.length)
            {
                static if (is(Things[i] == V[], V) && is(V : T))
                {
                    emplace_all(things[i][], ptr[_length .. _length + things[i].length]);
                    _length += cast(uint)things[i].length;
                }
                else static if (is(Things[i] == V[M], V, size_t M) && is(V : T))
                {
                    emplace_all(things[i][], ptr[_length .. _length + M]);
                    _length += cast(uint)M;
                }
                else static if (is(Things[i] : T))
                {
                    static if (is_trivial!T)
                        ptr[_length++] = things[i];
                    else
                        emplace!T(&ptr[_length++], forward!(things[i]));
                }
            }
            return this;
        }
    }
    else
    {
        // char arrays are really just a string buffer, and so we'll expand the capability of concat to match what `MutableString` accepts...
        static assert(is(T == char), "TODO: wchar and dchar"); // needs buffer length counting helpers

        // TODO: string's have this function `concat` which clears the string first, and that's different than Array
        //       we need to tighten this up!
        ref Array!(T, EmbedCount) concat(Things...)(auto ref Things things)
        {
            pragma(inline, true);
            clear();
            return append(forward!things);
        }

        ref Array!(T, EmbedCount) append(Things...)(auto ref Things things)
        {
            import urt.string.format : ConcatArg, concat_impl, concat_mask, make_concat_args;
            ConcatArg[Things.length] args = void;
            make_concat_args(things, args.ptr);
            enum arg_mask = concat_mask!Things;
            size_t ext_len = concat_impl(null, 0, args.ptr, arg_mask).length;
            grow(_length + ext_len);
            concat_impl(ptr + _length, ext_len, args.ptr, arg_mask);
            _length += ext_len;
            return this;
        }

        ref Array!(T, EmbedCount) append_format(Things...)(const(char)[] format, auto ref Things args)
        {
            import urt.string.format : _format = format;

            size_t ext_len = _format(null, format, args).length;
            grow(_length + ext_len);
            _format(ptr[_length .. _length + ext_len], format, forward!args);
            _length += ext_len;
            return this;
        }
    }

    T[] extend(bool do_init = true)(size_t length)
    {
        assert(_length + length <= uint.max);

        size_t old_len = _length;
        grow(_length + length);
        static if (do_init)
            init_all(ptr[_length .. _length + length]);
        _length += cast(uint)length;
        return ptr[old_len .. _length];
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

    ref T pushFront()()
    {
        static if (is(T == class) || is(T == interface))
            return pushFront(null);
        else
            return pushFront(T.init);
    }
    ref T pushFront(U)(auto ref U item)
        if (is(U : T))
        => insert(0, forward!item);
    ref T emplaceFront(Args...)(auto ref Args args)
        if (!is(T == class) && !is(T == interface))
        => insertEmplace(0, forward!args);

    ref T pushBack()()
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
    ref T emplaceBack(Args...)(auto ref Args args)
        if (!is(T == class) && !is(T == interface))
    {
        reserve(_length + 1);
        return *emplace!T(&ptr[_length++], forward!args);
    }

    ref T insert(U)(size_t pos, auto ref U item)
        if (is(U : T))
    {
        assert(pos <= _length, "Insert position out of range");
        reserve(_length + 1);
        uint old_length = _length++;
        move_emplace_overlapping(ptr[pos .. old_length], ptr[pos + 1 .. old_length + 1]);
        static if (is(T == class) || is(T == interface))
            return (ptr[pos] = item);
        else
            return *emplace!T(&ptr[pos], forward!item);
    }

    ref T insertEmplace(Args...)(size_t pos, auto ref Args args)
        if (!is(T == class) && !is(T == interface))
    {
        assert(pos <= _length, "Insert position out of range");
        reserve(_length + 1);
        uint old_length = _length++;
        move_emplace_overlapping(ptr[pos .. old_length], ptr[pos + 1 .. old_length + 1]);
        return *emplace!T(&ptr[pos], forward!args);
    }

    T popFront()
    {
        debug assert(_length > 0, "Range error");
        T r = ptr[0].move;
        remove(0);
        return r;
    }

    T popBack()
    {
        debug assert(_length > 0, "Range error");
        T r = ptr[_length - 1].move;
        destroy!false(ptr[--_length]);
        return r;
    }

    Array!T takeFront()(size_t count)
    {
        auto r = Array!T(Reserve, count);
        move_emplace_all(ptr[0 .. count], r.ptr[0 .. count]);
        r._length = cast(uint)count;
        remove(0, count);
        return r;
    }

    Array!T takeBack()(size_t count)
    {
        auto r = Array!T(Reserve, count);
        move_emplace_all(ptr[_length - count .. _length], r.ptr[0 .. count]);
        r._length = cast(uint)count;
        remove(_length - count, count);
        return r;
    }

    void remove(size_t i, size_t count = 1)
    {
        debug assert(i + count <= _length, "Range error");
        if (i < _length - count)
            move_to!true(ptr[i + count .. _length], ptr[i .. _length - count]);
        destroy_all!false(ptr[_length - count .. length]);
        _length -= cast(uint)count;
    }
    void remove(const(T)* pItem)                    { remove(ptr[0 .. _length].indexOfElement(pItem)); }
    void removeFirst(U)(ref const U item)           { remove(ptr[0 .. _length].findFirst(item)); }

    void removeSwapLast(size_t i, size_t count = 1)
    {
        debug assert(i + count <= _length, "Range error");
        if (i < _length - count)
            move_to!true(ptr[_length - count .. _length], ptr[i .. i + count]);
        destroy_all!false(ptr[_length - count .. length]);
        _length -= cast(uint)count;
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
            return ptr ? ptr[0 .. alloc_count()] : embed[];
        else
            return ptr ? ptr[0 .. alloc_count()] : null;
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

    void opOpAssign(string op : "~", U)(auto ref U rh)
    {
        append(forward!rh);
    }

    void reserve(size_t count)
    {
        static if (is_trivial!T)
            pragma(inline, true);

        if (count <= alloc_count())
            return;
        debug assert(count <= uint.max, "Exceed maximum size");

        static if (is_trivial!T)
        {
            enum alignment = T.alignof < 4 ? 4 : T.alignof;
            enum prefix = T.sizeof < 4 ? 4 : T.sizeof;
            bool allocated = has_allocation();
            ptr = cast(T*)array_reserve_trivial(ptr, _length, cast(uint)count, T.sizeof, alignment, prefix, allocated);
        }
        else
        {
            enum alignment = T.alignof < 4 ? 4 : T.alignof;
            enum prefix = T.sizeof < 4 ? 4 : T.sizeof;

            T* new_array = cast(T*)array_allocate(cast(uint)count, T.sizeof, alignment, prefix);
            move_emplace_all(ptr[0 .. _length], new_array[0 .. _length]);
            destroy_all!false(ptr[0 .. _length]);
            if (has_allocation())
                array_free(ptr, T.sizeof, prefix);
            ptr = new_array;
        }
    }

    void resize(size_t count)
    {
        if (count == _length)
            return;
        if (count < _length)
        {
            destroy_all!false(ptr[count .. _length]);
            _length = cast(uint)count;
        }
        else
        {
            reserve(count);
            init_all(ptr[_length .. count]);
            _length = cast(uint)count;
        }
    }

    void clear()
    {
        destroy_all!false(ptr[0 .. _length]);
        _length = 0;
    }

    import urt.string.format : FormatArg, formatValue;
    ptrdiff_t toString()(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
        => formatValue(ptr[0 .. _length], buffer, format, formatArgs);

    ptrdiff_t fromString()(const(char)[] s)
    {
        assert(false, "TODO");
    }

private:
    uint _length;

    static if (EmbedCount > 0)
        T[EmbedCount] embed = void;

    bool has_allocation() const pure
    {
        static if (EmbedCount > 0)
            return ptr && ptr != embed.ptr;
        else
            return ptr !is null;
    }
    uint alloc_count() const pure
        => has_allocation() ? (cast(uint*)ptr)[-1] : EmbedCount;

    void grow(size_t target)
    {
        static if (is_trivial!T)
        {
            enum alignment = T.alignof < 4 ? 4 : T.alignof;
            enum prefix = T.sizeof < 4 ? 4 : T.sizeof;
            ptr = cast(T*)array_grow_trivial(ptr, _length, alloc_count(), target, T.sizeof, alignment, prefix, has_allocation());
        }
        else
        {
            size_t cap = alloc_count();
            size_t new_cap = array_growth(cap, target);
            if (new_cap != cap)
                reserve(new_cap);
        }
    }

    version (Windows)
    {
        auto __debugExpanded() const pure => ptr[0 .. _length];
    }
}

// SharedArray is a ref-counted array which can be distributed
struct SharedArray(T)
{
    // TODO: DELETE POSTBLIT!
    this(this)
    {
        if (ptr)
            inc_ref();
    }

    this(typeof(null)) {}

    this(ref typeof(this) val)
    {
        ptr = val.ptr;
        _length = val._length;
        if (ptr)
            inc_ref();
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

    void opAssign(ref typeof(this) val)
    {
        clear();

        ptr = val.ptr;
        _length = val._length;
        if (ptr)
            inc_ref();
    }

    void opAssign(U)(U[] arr)
        if (is(U : T))
    {
        debug assert(arr.length <= uint.max);
        _length = cast(uint)arr.length;

        clear();

        if (len > 0)
        {
            ptr = allocate(_length);
            emplace_all(arr[], ptr[0 .. _length]);
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
//            return ptr ? ptr[0 .. alloc_count()] : embed[];
//        else
//            return ptr ? ptr[0 .. alloc_count()] : null;
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
        destroy_all!false(ptr[0 .. _length]);
        if (ptr)
            dec_ref();
        ptr = null;
        _length = 0;
    }

private:
    T* ptr;
    uint _length;

    void inc_ref()
    {
        ++(cast(uint*)ptr)[-1];
    }

    void dec_ref()
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

        void[] mem = .alloc(AllocAlignment + T.sizeof * count, AllocAlignment);
        T* array = cast(T*)(mem.ptr + AllocPrefixBytes);
        (cast(uint*)array)[-1] = 0;
        return array;
    }
    void free()
    {
        enum AllocAlignment = T.alignof < uint.alignof ? uint.alignof : T.alignof;

        .free((cast(void*)ptr - AllocAlignment)[0 .. AllocAlignment + T.sizeof * alloc_count()]);
    }
}


private:

pragma(inline, false)
void copy_bytes(bool overlapping)(void* dest, const void* src, size_t bytes) pure
{
    static if (overlapping)
        memmove(dest, src, bytes);
    else
        memcpy(dest, src, bytes);
}

void move_emplace_overlapping(T)(T[] arr, T[] dest)
{
    assert(arr.length == dest.length && arr.ptr < dest.ptr);
    static if (is_trivial!T)
        move_to!true(arr, dest);
    else
    {
        for (ptrdiff_t i = ptrdiff_t(arr.length) - 1; i >= 0; --i)
        {
            moveEmplace!T(arr[i], dest[i]);
            destroy!false(arr[i]);
        }
    }
}

pragma(inline, false)
void* array_allocate(uint count, size_t element_size, size_t alignment, size_t prefix) pure
{
    void[] mem = .alloc(prefix + element_size * count, alignment);
    void* array = mem.ptr + prefix;
    (cast(uint*)array)[-1] = count;
    return array;
}

pragma(inline, false)
void array_free(void* ptr, size_t element_size, size_t prefix) pure
{
    uint count = (cast(uint*)ptr)[-1];
    .free((ptr - prefix)[0 .. prefix + element_size * count]);
}

pragma(inline, false)
void* array_reserve_trivial(void* ptr, uint length, uint count, size_t element_size, size_t alignment, size_t prefix, bool allocated) pure
{
    void* result = array_allocate(count, element_size, alignment, prefix);
    if (length)
        memcpy(result, ptr, length * element_size);
    if (allocated)
        array_free(ptr, element_size, prefix);
    return result;
}

pragma(inline, false)
size_t array_growth(size_t capacity, size_t target) pure
{
    if (target <= capacity)
        return capacity;
    assert(target <= uint.max && capacity < uint.max);
    size_t result = capacity * 2;
    if (result < target)
        result = target;
    if (result > uint.max)
        result = uint.max;
    return result;
}

pragma(inline, false)
void* array_grow_trivial(void* ptr, uint length, size_t capacity, size_t target, size_t element_size, size_t alignment, size_t prefix, bool allocated) pure
{
    size_t count = array_growth(capacity, target);
    if (count == capacity)
        return ptr;
    return array_reserve_trivial(ptr, length, cast(uint)count, element_size, alignment, prefix, allocated);
}

pragma(inline, true)
bool el_cmp(T)(const T a, const T b)
    if (is(T == class) || is(T == interface))
{
    return a is b;
}

pragma(inline, true)
bool el_cmp(T)(const T a, const T b)
    if (is(T == U[], U))
{
    return a[] == b[];
}

pragma(inline, true)
bool el_cmp(T)(auto ref const T a, auto ref const T b)
    if (!is(T == class) && !is(T == interface) && !is(T == U[], U))
{
    return a == b;
}

unittest
{
    int[4] overlapping = [1, 2, 3, 4];
    move_to!true(overlapping[0 .. 3], overlapping[1 .. 4]);
    assert(overlapping == [1, 1, 2, 3]);

    char[3] text = ['a', 'b', 'c'];
    ubyte[3] bytes;
    copy_to(text[], bytes[]);
    assert(bytes == [cast(ubyte)'a', cast(ubyte)'b', cast(ubyte)'c']);

    Array!int integers;
    integers.append(1, 2, 3, 4);
    integers.insert(1, 5);
    assert(integers[] == [1, 5, 2, 3, 4]);
    integers.remove(1, 2);
    assert(integers[] == [1, 3, 4]);
    integers.removeSwapLast(1);
    assert(integers[] == [1, 4]);

    static struct Item
    {
        int value;
        this(this) nothrow @nogc {}
        ~this() nothrow @nogc {}
    }

    Array!Item values;
    values.emplaceBack(1);
    values.emplaceBack(3);
    values.insertEmplace(1, 2);
    assert(values.length == 3 && values[0].value == 1 && values[1].value == 2 && values[2].value == 3);
    values.remove(1);
    assert(values.length == 2 && values[0].value == 1 && values[1].value == 3);
}
