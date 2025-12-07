module urt.meta;

import urt.traits : is_callable, is_enum, EnumType, Unqual;

pure nothrow @nogc:

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

auto make_delegate(Fun)(Fun fun)
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

ulong bit_mask(size_t bits)
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


const(E)* enum_from_key(E)(const(char)[] key)
    if (is_enum!E)
    => MakeEnumInfo!E.value_for(key);

const(char)[] enum_key_from_value(E)(EnumType!E value)
    if (is_enum!E)
    => MakeEnumInfo!E.key_for(value);

const(char)[] enum_key_by_decl_index(E)(size_t value)
    if (is_enum!E)
    => MakeEnumInfo!E.key_by_decl_index(value);

struct VoidEnumInfo
{
    import urt.algorithm : binary_search;
    import urt.string;
nothrow @nogc:

    // keys and values are sorted for binary search
    const String* keys;
    const void* values;
    ubyte count;
    ushort stride;
    uint type_hash;

    const(char)[] key_for(const void* value, int function(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(values[0 .. count*stride], stride, value, pred);
        if (i < count)
            return keys[_v2k_lookup[i]][];
        return null;
    }

    const(char)[] key_for(const void* value, int delegate(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(values[0 .. count*stride], stride, value, pred);
        if (i < count)
            return keys[_v2k_lookup[i]][];
        return null;
    }

    const(char)[] key_by_decl_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return keys[_decl_lookup[i]][];
    }

    const(void)* value_for(const(char)[] key) const pure
    {
        size_t i = binary_search(keys[0 .. count], key);
        if (i == count)
            return null;
        i = _k2v_lookup[i];
        return values + i*stride;
    }

    bool contains(const(char)[] key) const pure
    {
        size_t i = binary_search(keys[0 .. count], key);
        return i < count;
    }

private:
    // these tables map between indices of keys and values
    const ubyte* _k2v_lookup;
    const ubyte* _v2k_lookup;
    const ubyte* _decl_lookup;
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
            import urt.string;
        nothrow @nogc:

            static assert (EnumInfo.sizeof == EnumInfo.sizeof, "Template EnumInfo must not add any members!");

            static if (is(UE T == enum))
                alias V = T;
            else
                static assert(false, E.string ~ " is not an enum type!");

            // keys and values are sorted for binary search
            const String* keys;
            const UE* values;
            const ubyte count = __traits(allMembers, E).length;
            const ushort stride = E.sizeof;
            uint type_hash;

            ref inout(VoidEnumInfo) make_void() inout
                => *cast(inout VoidEnumInfo*)&this;

            const(char)[] key_for(V value) const pure
            {
                size_t i = binary_search(values[0 .. count], value);
                if (i < count)
                    return keys[_v2k_lookup[i]][];
                return null;
            }

            const(char)[] key_by_decl_index(size_t i) const pure
                => make_void().key_by_decl_index(i);

            const(UE)* value_for(const(char)[] key) const pure
            {
                size_t i = binary_search(keys[0 .. count], key);
                if (i == count)
                    return null;
                return values + _k2v_lookup[i];
            }

            bool contains(const(char)[] key) const pure
                => make_void().contains(key);

        private:
            // these tables map between indices of keys and values
            const ubyte* _k2v_lookup;
            const ubyte* _v2k_lookup;
            const ubyte* _decl_lookup;
        }

        // sanity check the typed one matches the untyped one
        static assert(EnumInfo.sizeof == VoidEnumInfo.sizeof);
        static assert(EnumInfo.keys.offsetof == VoidEnumInfo.keys.offsetof);
        static assert(EnumInfo.values.offsetof == VoidEnumInfo.values.offsetof);
        static assert(EnumInfo.count.offsetof == VoidEnumInfo.count.offsetof);
        static assert(EnumInfo.stride.offsetof == VoidEnumInfo.stride.offsetof);
        static assert(EnumInfo.type_hash.offsetof == VoidEnumInfo.type_hash.offsetof);
        static assert(EnumInfo._k2v_lookup.offsetof == VoidEnumInfo._k2v_lookup.offsetof);
        static assert(EnumInfo._v2k_lookup.offsetof == VoidEnumInfo._v2k_lookup.offsetof);
        static assert(EnumInfo._decl_lookup.offsetof == VoidEnumInfo._decl_lookup.offsetof);
    }
}


template MakeEnumInfo(E)
    if (is(Unqual!E == enum))
{
    alias UE = Unqual!E;

    enum ubyte NumItems = __traits(allMembers, E).length;
    static assert(NumItems <= ubyte.max, "Too many enum items!");

    __gshared immutable MakeEnumInfo = immutable(EnumInfo!UE)(
        _keys.ptr,
        _values.ptr,
        NumItems,
        E.sizeof,
        0,
        _lookup.ptr,
        _lookup.ptr + NumItems,
        _lookup.ptr + NumItems*2
    );

private:
    import urt.algorithm : binary_search, compare, qsort;
    import urt.string;
    import urt.string.uni : uni_compare;

    // keys and values are sorted for binary search
    __gshared immutable String[NumItems] _keys = [ STATIC_MAP!(GetKey, iota) ];
    __gshared immutable UE[NumItems] _values = [ STATIC_MAP!(GetValue, iota) ];

    // these tables map between indices of keys and values
    __gshared immutable ubyte[NumItems * 3] _lookup = [ STATIC_MAP!(GetKeyRedirect, iota),
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
    enum by_key = (){ KI[NumItems] r = [ STATIC_MAP!(MakeKI, iota) ]; r.qsort!((ref a, ref b) => uni_compare(a.k, b.k)); return r; }();
    enum by_value = (){ VI[NumItems] r = [ STATIC_MAP!(MakeVI, iota) ]; r.qsort!((ref a, ref b) => compare(a.v, b.v)); return r; }();
    enum inv_key = (){ KI[NumItems] bk = by_key; ubyte[NumItems] r; foreach (ubyte i, ref ki; bk) r[ki.i] = i; return r; }();
    enum inv_val = (){ VI[NumItems] bv = by_value; ubyte[NumItems] r; foreach (ubyte i, ref vi; bv) r[vi.i] = i; return r; }();

    enum MakeKI(ushort i) = KI(enum_members[i], i);
    enum MakeVI(ushort i) = VI(__traits(getMember, E, enum_members[i]), i);
    enum GetKey(size_t i) = StringLit!(by_key[i].k);
    enum GetValue(size_t i) = by_value[i].v;
    enum GetKeyRedirect(size_t i) = inv_val[by_key[i].i];
    enum GetValRedirect(size_t i) = inv_key[by_value[i].i];
    enum GetKeyOrig(size_t i) = inv_key[i];
}


private:

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
