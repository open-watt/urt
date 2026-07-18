module urt.typereg;

// One record per registered type. Identity is the NAME; type_id is a process-local
// accelerator - never persisted, never wired.

import urt.attribute : fast_data;
import urt.conv;
import urt.endian : can_reverse_endian, reverse_endian;
import urt.hash : fnv1a;
import urt.internal.traits : hasIndirections;
import urt.lifetime;
import urt.string.format : FormatArg, formatValue;
import urt.traits : is_trivial, Unqual;
import urt.variant : ValidUserType, Variant;

nothrow @nogc:


struct TypeDetails
{
    const(char)[] name;
    uint type_id;
    uint super_type_id;
    ushort size;
    ubyte alignment;
    bool embedded;          // registrar's contract: type_id is 16-bit folded and Variant may store inline
                            // (not derivable from size/align: registry-native ids are unfolded hashes)
    bool pod;
    void function(void* src, void* dst, bool move) nothrow @nogc copy_emplace;
    void function(void* val) nothrow @nogc destroy;
    ptrdiff_t function(void* val, char[] buffer, bool do_format, const(char)[] format_spec, const(FormatArg)[] format_args) nothrow @nogc stringify;
    int function(const void* a, const void* b, int type) pure nothrow @nogc cmp;
    ptrdiff_t function(void* val, void[] buffer, bool do_serialise) nothrow @nogc serialise;
    bool function(void* val, ref Variant var, bool to_variant) nothrow @nogc variant;   // null = structural boxing (type_id + payload)
    void function(const(void)* src, void* dst) nothrow @nogc byte_reverse;              // src == dest is allowed
}

bool binary_representable(ref const TypeDetails td) pure
    => td.pod || td.serialise !is null;

// aggregates name themselves with `enum type_name = "..."`; these appear in schema and containers
template type_name_of(T)
{
    static if (is(typeof(T.type_name) : const(char)[]))
        enum type_name_of = T.type_name;
    else
        enum type_name_of = T.stringof;
}

@fast_data __gshared TypeDetails[32] g_type_details;
@fast_data __gshared ushort g_num_type_details = 0;

typeof(g_type_details)* type_details() => &g_type_details;
ushort num_type_details() => g_num_type_details;

ushort register_type_record(TypeDetails td)
{
    assert(g_num_type_details < g_type_details.length, "Too many user types!");
    g_type_details[g_num_type_details] = td;
    return g_num_type_details++;
}

ref immutable(TypeDetails) find_type_details(uint type_id) pure
{
    auto tds = (cast(immutable(typeof(g_type_details)*) function() pure nothrow @nogc)&type_details)();
    ushort count = (cast(ushort function() pure nothrow @nogc)&num_type_details)();
    foreach (i, ref td; (*tds)[0 .. count])
    {
        if (td.type_id == type_id)
            return td;
    }
    assert(false, "TypeDetails not found!");
}

immutable(TypeDetails)* find_type_by_name(const(char)[] name) pure
{
    auto tds = (cast(immutable(typeof(g_type_details)*) function() pure nothrow @nogc)&type_details)();
    ushort count = (cast(ushort function() pure nothrow @nogc)&num_type_details)();
    foreach (ref td; (*tds)[0 .. count])
    {
        if (td.name == name)
            return &td;
    }
    return null;
}

ref immutable(TypeDetails) get_type_details(uint index) pure
{
    auto tds = (cast(immutable(typeof(g_type_details)*) function() pure nothrow @nogc)&type_details)();
    debug assert(index < g_num_type_details);
    return (*tds)[index];
}

template register_type(T, string type_name = type_name_of!T)
{
    shared static this()
    {
        register_type_record(TypeRecordFor!(T, fnv1a(cast(const(ubyte)[])type_name), 0, false, type_name));
    }
    alias register_type = void;
}

template TypeRecordFor(T, uint type_id, uint super_type_id, bool embedded, string type_name = type_name_of!T)
    if (is(Unqual!T == T) && (is(T == struct) || is(T == class)))
{
    static if (!is(T == class))
    {
        static void move_emplace_impl(void* src, void* dst, bool move) nothrow @nogc
        {
            if (move)
                moveEmplace(*cast(T*)src, *cast(T*)dst);
            else
            {
                static if (is_trivial!T)
                    *cast(T*)dst = *cast(T*)src;
                else static if (__traits(compiles, new(*cast(T*)dst) T(*cast(T*)src)))
                    new(*cast(T*)dst) T(*cast(T*)src);
                else
                    assert(false, "Can't copy " ~ T.stringof);
            }
        }
        enum move_emplace = &move_emplace_impl;
    }
    else
        enum move_emplace = null;

    static if (!is_trivial!T && is(typeof(destroy!(false, T))))
    {
        static void destroy_impl(void* val) nothrow @nogc
        {
            destroy!false(*cast(T*)val);
        }
        enum destroy_fun = &destroy_impl;
    }
    else
        enum destroy_fun = null;

    static ptrdiff_t stringify(void* val, char[] buffer, bool do_format, const(char)[] format_spec, const(FormatArg)[] format_args) nothrow @nogc
    {
        if (do_format)
        {
            static if (__traits(compiles, { formatValue(*cast(const T*)val, buffer, format_spec, format_args); }))
                return formatValue(*cast(const T*)val, buffer, format_spec, format_args);
            else
                return -1;
        }
        else
        {
            static if (is(typeof(parse!T)))
                return buffer.parse!T(*cast(T*)val);
            else
                return -1;
        }
    }

    int compare(const void* pa, const void* pb, int type) pure nothrow @nogc
    {
        ref const T a = *cast(const T*)pa;
        ref const T b = *cast(const T*)pb;
        switch (type)
        {
            case 0:
                static if (is(T == class) || is(T == U*, U) || is(T == V[], V))
                {
                    if (pa is pb)
                        return 0;
                }
                static if (__traits(compiles, { a.opCmp(b); }))
                    return a.opCmp(b);
                else static if (__traits(compiles, { b.opCmp(a); }))
                    return -b.opCmp(a);
                else static if (is(T == class))
                {
                    ptrdiff_t r = cast(ptrdiff_t)pa - cast(ptrdiff_t)pb;
                    return r < 0 ? -1 : r > 0 ? 1 : 0;
                }
                else
                    assert(false, "No comparison!"); // TODO: hash or stringify the values and order that way?
            case 1:
                static if (is(T == class) || is(T == U*, U) || is(T == V[], V))
                {
                    if (pa is pb)
                        return 1;
                }
                static if (__traits(compiles, { a.opEquals(b); }))
                    return a.opEquals(b);
                else static if (__traits(compiles, { b.opEquals(a); }))
                    return b.opEquals(a);
                else static if (!is(T == class) && !is(T == U*, U) && !is(T == V[], V))
                    return a == b ? 1 : 0;
                else
                    return 0;
            case 2:
                return pa is pb ? 1 : 0;
            default:
                assert(false);
        }
    }

    enum pod = !is(T == class) && is_trivial!T && !hasIndirections!T;

    static if (__traits(hasMember, T, "serialise") && __traits(hasMember, T, "deserialise"))
    {
        static ptrdiff_t serialise_impl(void* val, void[] buffer, bool do_serialise) nothrow @nogc
            => do_serialise ? (cast(const(T)*)val).serialise(buffer)
                            : (cast(T*)val).deserialise(buffer);
        enum ser_fun = &serialise_impl;
    }
    else
        enum ser_fun = null;

    static if (__traits(hasMember, T, "to_variant") && __traits(hasMember, T, "from_variant"))
    {
        static bool variant_impl(void* val, ref Variant var, bool to_variant) nothrow @nogc
        {
            if (to_variant)
            {
                var = (cast(const(T)*)val).to_variant();
                return true;
            }
            return T.from_variant(var, *cast(T*)val);
        }
        enum var_fun = &variant_impl;
    }
    // the guard must not instantiate Variant machinery: records are built from inside
    // Variant's own ctor, and an eager compiles-check on it collapses under the cycle
    else static if (!is(T == class) && ValidUserType!T && !hasIndirections!T &&
                    __traits(compiles, (ref T a, ref T b) nothrow @nogc { b = a; }))
    {
        static bool variant_default(void* val, ref Variant var, bool to_variant) nothrow @nogc
        {
            if (to_variant)
            {
                var = Variant(*cast(T*)val);
                return true;
            }
            if (!var.isUser!T)
                return false;
            *cast(T*)val = var.asUser!T;
            return true;
        }
        enum var_fun = &variant_default;
    }
    else
        enum var_fun = null;

    static if (pod && ser_fun is null && can_reverse_endian!T)
    {
        static void byte_swap_impl(const(void)* src, void* dst) nothrow @nogc
        {
            reverse_endian(*cast(const(T)*)src, *cast(T*)dst);
        }
        enum swap_fun = &byte_swap_impl;
    }
    else
        enum swap_fun = null;

    enum TypeRecordFor = TypeDetails(type_name, type_id, super_type_id, T.sizeof, T.alignof,
                                     embedded, pod, move_emplace, destroy_fun, &stringify, &compare,
                                     ser_fun, var_fun, swap_fun);
}


unittest
{
    static struct Vec2 { int x, y; }
    static struct Boxed { int* p; }

    enum r = TypeRecordFor!(Vec2, fnv1a(cast(const(ubyte)[])"vec2"), 0, false, "vec2");
    static assert(r.pod && r.size == 8 && r.name == "vec2");
    static assert(!TypeRecordFor!(Boxed, 1, 0, false).pod);

    ushort i = register_type_record(r);
    assert(&get_type_details(i) is &find_type_details(r.type_id));
    assert(find_type_by_name("vec2") !is null);
    assert(find_type_by_name("vec2").size == 8);
    assert(find_type_by_name("no-such-type") is null);

    // memcpy-is-canonical for pods: no serialise handler, no destructor, trivial copy
    assert(r.serialise is null && r.destroy is null);
    assert(binary_representable(r));

    // a non-pod without a serialise pair has no binary form; declaring the pair restores it
    // and a `type_name` member names the type without registration-site strings
    static struct Blob
    {
    nothrow @nogc:
        enum type_name = "blob";
        int* data;
        ptrdiff_t serialise(void[] buffer) const { return 0; }
        ptrdiff_t deserialise(const(void)[] buffer) { return 0; }
    }
    enum b = TypeRecordFor!(Blob, 2, 0, false);
    static assert(b.name == "blob");
    static assert(!b.pod && b.serialise !is null);
    assert(binary_representable(b));
    assert(!binary_representable(TypeRecordFor!(Boxed, 1, 0, false)));

    // byte_reverse: synthesised member-recursive flip for pods; encoding owners get null
    static assert(r.byte_reverse !is null);
    static assert(b.byte_reverse is null);                                   // serialise pair owns encoding
    static assert(TypeRecordFor!(Boxed, 1, 0, false).byte_reverse is null);  // not a pod
    Vec2 v2 = Vec2(0x01020304, 0x0A0B0C0D);
    r.byte_reverse(&v2, &v2);
    assert(v2.x == 0x04030201 && v2.y == 0x0D0C0B0A);
    Vec2 v2out;
    r.byte_reverse(&v2, &v2out);
    assert(v2out == Vec2(0x01020304, 0x0A0B0C0D));

    // variant marshal override: boxed surface differs from payload
    static struct Ident
    {
    nothrow @nogc:
        uint id;
        Variant to_variant() const
            => Variant(long(id));
        static bool from_variant(ref const Variant v, out Ident result)
        {
            if (!v.isNumber)
                return false;
            result.id = cast(uint)v.asLong;
            return true;
        }
    }
    enum idr = TypeRecordFor!(Ident, 3, 0, false, "ident");
    static assert(idr.variant !is null);

    // no override: a synthesised structural marshal boxes the payload as itself
    static assert(r.variant !is null);
    Vec2 vv = Vec2(3, 4);
    Variant vb;
    assert(r.variant(&vv, vb, true));
    assert(vb.isUser!Vec2);
    Vec2 vback;
    assert(r.variant(&vback, vb, false) && vback == vv);

    Ident src = Ident(42);
    Variant boxed;
    assert(idr.variant(&src, boxed, true));
    assert(boxed.isNumber && boxed.asLong == 42);
    Ident back;
    assert(idr.variant(&back, boxed, false));
    assert(back.id == 42);
}
