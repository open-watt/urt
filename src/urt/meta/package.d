module urt.meta;

import urt.traits : is_callable, is_enum, EnumType, Unqual;

nothrow @nogc:

alias Alias(alias a) = a;
alias Alias(T) = T;

alias AliasSeq(TList...) = TList;

template Iota(ptrdiff_t start, ptrdiff_t end)
{
    static assert(start <= end, "start must be less than or equal to end");
    alias Iota = AliasSeq!();
    static foreach (i; start .. end)
        Iota = AliasSeq!(Iota, i);
}
alias Iota(size_t end) = Iota!(0, end);

auto make_delegate(Fun)(Fun fun) pure
    if (is_callable!Fun)
{
    import urt.traits : is_function_pointer, ReturnType, Parameters;

    static if (is_function_pointer!fun)
    {
        struct Hack
        {
            static if (is(Fun : R function(Args) pure nothrow @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure nothrow @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) pure nothrow @nogc)&this)(args);
            else static if (is(Fun : R function(Args) nothrow @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) nothrow @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) nothrow @nogc)&this)(args);
            else static if (is(Fun : R function(Args) pure @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) pure @nogc)&this)(args);
            else static if (is(Fun : R function(Args) pure nothrow, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure nothrow => (cast(ReturnType!Fun function(Parameters!Fun args) pure nothrow)&this)(args);
            else static if (is(Fun : R function(Args) pure, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure => (cast(ReturnType!Fun function(Parameters!Fun args) pure)&this)(args);
            else static if (is(Fun : R function(Args) nothrow, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) nothrow => (cast(ReturnType!Fun function(Parameters!Fun args) nothrow)&this)(args);
            else static if (is(Fun : R function(Args) @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) @nogc)&this)(args);
            else static if (is(Fun : R function(Args), R, Args...))
                ReturnType!Fun call(Parameters!Fun args) => (cast(ReturnType!Fun function(Parameters!Fun args))&this)(args);
        }
        Hack hack;
        auto dg = &hack.call;
        dg.ptr = fun;
        return dg;
    }
    else static if (is(Fun == delegate))
        return fun;
    else
        static assert(false, "Unsupported type for make_delegate");
}

ulong bit_mask(size_t bits) pure
{
    return (1UL << bits) - 1;
}

template bit_mask(size_t bits, bool signed = false)
{
    static assert(bits <= 64, "bit_mask only supports up to 64 bits");
    static if (bits == 64)
        enum IntForWidth!(64, signed) bit_mask = ~0UL;
    else
        enum IntForWidth!(bits, signed) bit_mask = (1UL << bits) - 1;
}

template IntForWidth(size_t bits, bool signed = false)
{
    static if (bits <= 8 && !signed)
        alias IntForWidth = ubyte;
    else static if (bits <= 8 && signed)
        alias IntForWidth = byte;
    else static if (bits <= 16 && !signed)
        alias IntForWidth = ushort;
    else static if (bits <= 16 && signed)
        alias IntForWidth = short;
    else static if (bits <= 32 && !signed)
        alias IntForWidth = uint;
    else static if (bits <= 32 && signed)
        alias IntForWidth = int;
    else static if (bits <= 64 && !signed)
        alias IntForWidth = ulong;
    else static if (bits <= 64 && signed)
        alias IntForWidth = long;
}

alias TypeForOp(string op, U) = typeof(mixin(op ~ "U()"));
alias TypeForOp(string op, A, B) = typeof(mixin("A()" ~ op ~ "B()"));

template STATIC_MAP(alias fun, args...)
{
    alias STATIC_MAP = AliasSeq!();
    static foreach (arg; args)
        STATIC_MAP = AliasSeq!(STATIC_MAP, fun!arg);
}

template STATIC_UNROLL(alias array)
{
    static if (is(typeof(array) : T[], T))
    {
        alias STATIC_UNROLL = AliasSeq!();
        static foreach (i; 0 .. array.length)
            STATIC_UNROLL = AliasSeq!(STATIC_UNROLL, array[i]);
    }
    else
        static assert(false, "STATIC_UNROLL requires an array");
}

template STATIC_FILTER(alias filter, args...)
{
    alias STATIC_FILTER = AliasSeq!();
    static foreach (arg; args)
        static if (filter!arg)
            STATIC_FILTER = AliasSeq!(STATIC_FILTER, arg);
}

template static_index_of(args...)
    if (args.length >= 1)
{
    enum static_index_of = {
        static foreach (idx, arg; args[1 .. $])
            static if (is_same!(args[0], arg))
                // `if (__ctfe)` is redundant here but avoids the "Unreachable code" warning.
                if (__ctfe) return idx;
        return -1;
    }();
}

template INTERLEAVE_SEPARATOR(alias sep, Args...)
{
    alias INTERLEAVE_SEPARATOR = AliasSeq!();
    static foreach (i, A; Args)
        static if (i > 0)
            INTERLEAVE_SEPARATOR = AliasSeq!(INTERLEAVE_SEPARATOR, sep, A);
        else
            INTERLEAVE_SEPARATOR = AliasSeq!(A);
}


const(E)* enum_from_key(E)(const(char)[] key) pure
    if (is_enum!E)
    => enum_info!E.value_for(key);

const(char)[] enum_key_from_value(E)(EnumType!E value) pure
    if (is_enum!E)
    => enum_info!E.key_for(value);

const(char)[] enum_key_by_decl_index(E)(size_t value) pure
    if (is_enum!E)
    => enum_info!E.key_by_decl_index(value);

struct VoidEnumInfo
{
    import urt.algorithm : binary_search;
    import urt.string;
nothrow @nogc:

    // keys and values are sorted for binary search
    ushort count;
    ushort stride;
    uint type_hash;

    const(char)[] key_for(const void* value, int function(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(_values[0 .. count*stride], stride, value, pred);
        if (i < count)
            return get_key(_lookup_tables[count + i]);
        return null;
    }

    const(char)[] key_for(const void* value, int delegate(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(_values[0 .. count*stride], stride, value, pred);
        if (i < count)
            return get_key(_lookup_tables[count + i]);
        return null;
    }

    const(char)[] key_by_decl_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_key(_lookup_tables[count*2 + i]);
    }

    const(void)* value_for(const(char)[] key) const pure
    {
        size_t i = binary_search!key_compare(_keys[0 .. count], key, _string_buffer);
        if (i == count)
            return null;
        i = _lookup_tables[i];
        return _values + i*stride;
    }

    bool contains(const(char)[] key) const pure
    {
        size_t i = binary_search!key_compare(_keys[0 .. count], key, _string_buffer);
        return i < count;
    }

private:
    const void* _values;
    const ushort* _keys;
    const char* _string_buffer;

    // these tables map between indices of keys and values
    const ubyte* _lookup_tables;

    this(ubyte count, ushort stride, uint type_hash, inout void* values, inout ushort* keys, inout char* strings, inout ubyte* lookup) inout pure
    {
        this.count = count;
        this.stride = stride;
        this.type_hash = type_hash;
        this._keys = keys;
        this._values = values;
        this._string_buffer = strings;
        this._lookup_tables = lookup;
    }

    const(char)[] get_key(size_t i) const pure
    {
        const(char)* s = _string_buffer + _keys[i];
        return s[0 .. s.key_length];
    }
}

template EnumInfo(E)
{
    alias UE = Unqual!E;

    static if (is(UE == void))
        alias EnumInfo = VoidEnumInfo;
    else
    {
        struct EnumInfo
        {
            import urt.algorithm : binary_search;
        nothrow @nogc:

            static assert (EnumInfo.sizeof == EnumInfo.sizeof, "Template EnumInfo must not add any members!");

            static if (is(UE T == enum))
                alias V = T;
            else
                static assert(false, E.string ~ " is not an enum type!");

            // keys and values are sorted for binary search
            union {
                VoidEnumInfo _base;
                struct {
                    ubyte[VoidEnumInfo._values.offsetof] _pad;
                    const UE* _values; // shadows the _values in _base with a typed version
                }
            }
            alias _base this;

            inout(VoidEnumInfo*) make_void() inout pure
                => &_base;

            this(ubyte count, uint type_hash, inout UE* values, inout ushort* keys, inout char* strings, inout ubyte* lookup) inout pure
            {
                _base = inout(VoidEnumInfo)(count, UE.sizeof, type_hash, values, keys, strings, lookup);
            }

            const(UE)[] values() const pure
                => _values[0 .. count];

            const(char)[] key_for(V value) const pure
            {
                size_t i = binary_search(values[0 .. count], value);
                if (i < count)
                    return get_key(_lookup_tables[count + i]);
                return null;
            }

            const(char)[] key_by_decl_index(size_t i) const pure
                => _base.key_by_decl_index(i);

            const(UE)* value_for(const(char)[] key) const pure
            {
                size_t i = binary_search!key_compare(_keys[0 .. count], key, _string_buffer);
                if (i == count)
                    return null;
                return _values + _lookup_tables[i];
            }

            bool contains(const(char)[] key) const pure
                => _base.contains(key);
        }
    }
}

template enum_info(E)
    if (is(Unqual!E == enum))
{
    alias UE = Unqual!E;

    enum ubyte num_items = enum_members.length;
    static assert(num_items <= ubyte.max, "Too many enum items!");

    __gshared immutable enum_info = immutable(EnumInfo!UE)(
        num_items,
        fnv1a(cast(ubyte[])UE.stringof),
        _values.ptr,
        _keys.ptr,
        _strings.ptr,
        _lookup.ptr
    );

private:
    import urt.algorithm : binary_search, compare, qsort;
    import urt.hash : fnv1a;
    import urt.string.uni : uni_compare;

    // keys and values are sorted for binary search
    __gshared immutable UE[num_items] _values = [ STATIC_MAP!(GetValue, iota) ];

    // keys are stored as offsets info the string buffer
    __gshared immutable ushort[num_items] _keys = () {
        ushort[num_items] key_offsets;
        size_t offset = 2;
        foreach (i; 0 .. num_items)
        {
            const(char)[] key = by_key[i].k;
            key_offsets[i] = cast(ushort)offset;
            offset += 2 + key.length;
            if (key.length & 1)
                offset += 1; // align to 2 bytes
        }
        return key_offsets;
    }();

    // build the string buffer
    __gshared immutable char[total_strings] _strings = () {
        char[total_strings] str_data;
        char* ptr = str_data.ptr;
        foreach (i; 0 .. num_items)
        {
            const(char)[] key = by_key[i].k;
            version (LittleEndian)
            {
                *ptr++ = key.length & 0xFF;
                *ptr++ = (key.length >> 8) & 0xFF;
            }
            else
            {
                *ptr++ = (key.length >> 8) & 0xFF;
                *ptr++ = key.length & 0xFF;
            }
            ptr[0 .. key.length] = key[];
            ptr += key.length;
            if (key.length & 1)
                *ptr++ = 0; // align to 2 bytes
        }
        return str_data;
    }();

    // these tables map between indices of keys and values
    __gshared immutable ubyte[num_items * 3] _lookup = [ STATIC_MAP!(GetKeyRedirect, iota),
                                                         STATIC_MAP!(GetValRedirect, iota),
                                                         STATIC_MAP!(GetKeyOrig, iota) ];

    // a whole bunch of nonsense to build the tables...
    struct KI
    {
        string k;
        ubyte i;
    }
    struct VI
    {
        UE v;
        ubyte i;
    }

    alias iota = Iota!(enum_members.length);
    enum enum_members = __traits(allMembers, E);
    enum by_key = (){ KI[num_items] r = [ STATIC_MAP!(MakeKI, iota) ]; r.qsort!((ref a, ref b) => uni_compare(a.k, b.k)); return r; }();
    enum by_value = (){ VI[num_items] r = [ STATIC_MAP!(MakeVI, iota) ]; r.qsort!((ref a, ref b) => compare(a.v, b.v)); return r; }();
    enum inv_key = (){ KI[num_items] bk = by_key; ubyte[num_items] r; foreach (ubyte i, ref ki; bk) r[ki.i] = i; return r; }();
    enum inv_val = (){ VI[num_items] bv = by_value; ubyte[num_items] r; foreach (ubyte i, ref vi; bv) r[vi.i] = i; return r; }();

    // calculate the total size of the string buffer
    enum total_strings = () {
        size_t total = 0;
        static foreach (k; enum_members)
            total += 2 + k.length + (k.length & 1);
        return total;
    }();

    enum MakeKI(ushort i) = KI(trim_key!(enum_members[i]), i);
    enum MakeVI(ushort i) = VI(__traits(getMember, E, enum_members[i]), i);
    enum GetValue(size_t i) = by_value[i].v;
    enum GetKeyRedirect(size_t i) = inv_val[by_key[i].i];
    enum GetValRedirect(size_t i) = inv_key[by_value[i].i];
    enum GetKeyOrig(size_t i) = inv_key[i];
}

VoidEnumInfo* make_enum_info(T)(const(char)[] name, const(char)[][] keys, T[] values)
{
    import urt.algorithm;
    import urt.hash : fnv1a;
    import urt.mem.allocator;
    import urt.string;
    import urt.string.uni;
    import urt.util;

    assert(keys.length == values.length, "keys and values must have the same length");
    assert(keys.length <= ubyte.max, "Too many enum items!");

    size_t count = keys.length;

    struct VI(T)
    {
        T v;
        ubyte i;
    }

    // first we'll sort the keys and values for binary searching
    // we need to associate their original indices for the lookup tables
    auto ksort = tempAllocator().allocArray!(VI!(const(char)[]))(count);
    auto vsort = tempAllocator().allocArray!(VI!T)(count);
    foreach (i; 0 .. count)
    {
        ksort[i] = VI!(const(char)[])(keys[i], cast(ubyte)i);
        vsort[i] = VI!T(values[i], cast(ubyte)i);
    }
    ksort.qsort!((ref a, ref b) => uni_compare(a.v, b.v));
    vsort.qsort!((ref a, ref b) => compare(a.v, b.v));

    // build the reverse lookup tables
    ubyte[] inv_k = tempAllocator().allocArray!ubyte(count);
    ubyte[] inv_v = tempAllocator().allocArray!ubyte(count);
    foreach (i, ref ki; ksort)
        inv_k[ki.i] = cast(ubyte)i;
    foreach (i, ref vi; vsort)
        inv_v[vi.i] = cast(ubyte)i;

    // count the string memory
    size_t total_string;
    foreach (i; 0 .. count)
        total_string += 2 + keys[i].length + (keys[i].length & 1);

    // calculate the total size
    size_t total_size = VoidEnumInfo.sizeof + T.sizeof*count;
    total_size += (total_size & 1) + ushort.sizeof*count + count*3;
    total_size += (total_size & 1) + total_string;

    // allocate a buffer and assign all the sub-buffers
    void[] info = defaultAllocator().alloc(total_size);
    VoidEnumInfo* result = cast(VoidEnumInfo*)info.ptr;
    T* value_ptr = cast(T*)&result[1];
    char* str_data = cast(char*)&value_ptr[count];
    if (cast(size_t)str_data & 1)
        *str_data++ = 0; // align to 2 bytes
    ushort* key_ptr = cast(ushort*)str_data;
    ubyte* lookup = cast(ubyte*)&key_ptr[count];
    str_data = cast(char*)&lookup[count*3];
    if (cast(size_t)str_data & 1)
        *str_data++ = 0; // align to 2 bytes
    char* str_ptr = str_data + 2;

    // populate the enum info data
    foreach (i; 0 .. count)
    {
        value_ptr[i] = vsort[i].v;

        // write the string data and store the key offset
        const(char)[] key = ksort[i].v;
        key_ptr[i] = cast(ushort)(str_ptr - str_data);
        writeString(str_ptr, key);
        if (key.length & 1)
            (str_ptr++)[key.length] = 0; // align to 2 bytes
        str_ptr += 2 + key.length;

        lookup[i] = inv_v[ksort[i].i];
        lookup[count + i] = inv_k[vsort[i].i];
        lookup[count*2 + i] = inv_k[i];
    }

    // build and return the object
    return new(*result) VoidEnumInfo(cast(ubyte)keys.length, cast(ushort)T.sizeof, fnv1a(cast(ubyte[])name), value_ptr, key_ptr, str_data, lookup);
}

private:

import urt.string : trim;
enum trim_key(string key) = key.trim!(c => c == '_');

template is_same(alias a, alias b)
{
    static if (!is(typeof(&a && &b)) // at least one is an rvalue
               && __traits(compiles, { enum is_same = a == b; })) // c-t comparable
        enum is_same = a == b;
    else
        enum is_same = __traits(isSame, a, b);
}
// TODO: remove after https://github.com/dlang/dmd/pull/11320 and https://issues.dlang.org/show_bug.cgi?id=21889 are fixed
template is_same(A, B)
{
    enum is_same = is(A == B);
}

ushort key_length(const(char)* key) pure
{
    if (__ctfe)
    {
        version (LittleEndian)
            return key[-2] | cast(ushort)(key[-1] << 8);
        else
            return key[-1] | cast(ushort)(key[-2] << 8);
    }
    else
        return *cast(ushort*)(key - 2);
}

int key_compare(ushort a, const(char)[] b, const(char)* strings) pure
{
    import urt.string.uni : uni_compare;
    const(char)* s = strings + a;
    return uni_compare(s[0 .. s.key_length], b);
}
