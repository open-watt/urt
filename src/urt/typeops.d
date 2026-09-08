module urt.typeops;

import urt.conv;
import urt.meta.enuminfo;
import urt.traits;

nothrow @nogc:


enum is_builtin(T) = is(Unqual!T == bool) || is_some_int!T || is(Unqual!T == float) || is(Unqual!T == double) || is_enum!T || is(T : const(char)[]);

enum has_to_text(T) = __traits(compiles, (ref const T v, char[] b) nothrow @nogc { ptrdiff_t r = v.toString(b, null, null); }) || __traits(compiles, (ref const T v, char[] b) nothrow @nogc { ptrdiff_t r = v.toString(b); });

enum has_from_text(T) = __traits(compiles, (ref T v, const(char)[] s) nothrow @nogc { ptrdiff_t r = v.fromString(s); });

enum text_round_trip(T) = (is_builtin!T && (!is(T : const(char)[]) || is(T == const(char)[]))) || (has_to_text!T && has_from_text!T);

ptrdiff_t to_text(T)(auto ref const T value, char[] buffer)
{
    alias U = Unqual!T;

    static if (is(U == bool))
        return copy_text(value ? "true" : "false", buffer);
    else static if (is_enum!U)
    {
        static if (is_bitfield_enum!U)
        {
            auto info = enum_info!U.make_void();
            return info.format_flags(cast(long)value, buffer);
        }
        else
        {
            const(char)[] key = enum_key_from_value!U(value);
            if (key)
                return copy_text(key, buffer);
            return to_text(cast(EnumType!U)value, buffer);
        }
    }
    else static if (is_signed_int!U)
        return format_int(value, buffer);
    else static if (is_unsigned_int!U)
        return format_uint(value, buffer);
    else static if (is(U == float) || is(U == double))
        return format_float_shortest(U(value), buffer);
    else static if (is(T : const(char)[]))
        return copy_text(value, buffer);
    else
    {
        static assert(has_to_text!T && has_from_text!T, T.stringof ~ " needs both toString and fromString to survive a text wire");
        static if (__traits(compiles, value.toString(buffer, null, null)))
            return value.toString(buffer, null, null);
        else
            return value.toString(buffer);
    }
}

ptrdiff_t from_text(T)(const(char)[] text, out T result)
{
    alias U = Unqual!T;

    static if (is_enum!U)
    {
        static if (is_bitfield_enum!U)
        {
            auto info = enum_info!U.make_void();
            bool ok;
            long r = info.parse_flags(text, ok);
            if (!ok)
                return -1;
            result = cast(T)r;
            return text.length;
        }
        else
        {
            if (const(U)* v = enum_from_key!U(text))
            {
                result = *v;
                return text.length;
            }
            EnumType!U numeric;
            ptrdiff_t taken = from_text(text, numeric);
            if (taken >= 0)
                result = cast(T)numeric;
            return taken;
        }
    }
    else static if (is(T : const(char)[]) && !is(U == bool))
    {
        static assert(is(T == const(char)[]), "Text decoding borrows a const character slice");
        result = text;
        return text.length;
    }
    else
    {
        static if (!is_builtin!U)
            static assert(has_to_text!T && has_from_text!T, T.stringof ~ " needs both toString and fromString to survive a text wire");
        ptrdiff_t taken = parse!T(text, result);
        return taken >= 0 && taken != text.length ? -1 : taken;
    }
}

private:

ptrdiff_t copy_text(const(char)[] text, char[] buffer)
{
    if (buffer.ptr)
    {
        if (text.length > buffer.length)
            return -1;
        buffer[0 .. text.length] = text[];
    }
    return text.length;
}


unittest
{
    static assert(!text_round_trip!real);
    static assert(!text_round_trip!string);
    static assert(!text_round_trip!(char[]));
    static assert(text_round_trip!(const(char)[]));
    char[64] buf;

    assert(to_text(true, buf) == 4 && buf[0 .. 4] == "true");
    bool b;
    assert(from_text("false", b) == 5 && b == false);

    assert(to_text(-1234, buf) == 5 && buf[0 .. 5] == "-1234");
    assert(to_text(ulong.max, buf) == 20);
    int i;
    assert(from_text("-42", i) == 3 && i == -42);
    assert(from_text("42junk", i) < 0);
    assert(to_text("hello", null) == 5);
    ubyte u8;
    assert(from_text("257", u8) < 0);

    static void check_float(F)(F v, const(char)[] expect = null)
    {
        char[64] t;
        ptrdiff_t n = to_text(v, t);
        assert(n > 0);
        if (expect)
            assert(t[0 .. n] == expect);
        F r;
        assert(from_text(t[0 .. n], r) == n);
        version (Tiny)
        {
            import urt.math : fabs;
            assert(r == v || (r != r && v != v) || fabs(r / v - 1) < 1e-6);
        }
        else
            assert(r == v || (r != r && v != v));
    }
    check_float(0.1, "0.1");
    check_float(3.14159265358979);
    check_float(0.1f, "0.1");
    check_float(double.nan);

    enum Plain { first, second }
    assert(to_text(Plain.second, buf) == 6 && buf[0 .. 6] == "second");
    Plain p;
    assert(from_text("first", p) == 5 && p == Plain.first);
    assert(from_text("bogus", p) < 0);
    ptrdiff_t unnamed = to_text(cast(Plain)42, buf);
    assert(from_text(buf[0 .. unnamed], p) == unnamed && p == cast(Plain)42);

    @bitfield enum Flags : ubyte { a = 1, b = 2, c = 4 }
    ptrdiff_t n = to_text(cast(Flags)3, buf);
    assert(n > 0);
    Flags f;
    assert(from_text(buf[0 .. n], f) == n && f == cast(Flags)3);

    assert(to_text("hello", buf) == 5 && buf[0 .. 5] == "hello");
    const(char)[] s;
    assert(from_text("world", s) == 5 && s == "world");

    static struct Stamp
    {
    nothrow @nogc:
        int v;
        ptrdiff_t toString(char[] buffer) const
            => format_int(v, buffer);
        ptrdiff_t fromString(const(char)[] s)
            => s.parse!int(v);
    }
    static assert(text_round_trip!Stamp);
    Stamp st = Stamp(42);
    assert(to_text(st, buf) == 2 && buf[0 .. 2] == "42");
    Stamp st2;
    assert(from_text("77", st2) == 2 && st2.v == 77);

    static struct Half
    {
    nothrow @nogc:
        int v;
        ptrdiff_t toString(char[] buffer) const
            => format_int(v, buffer);
    }
    static assert(!text_round_trip!Half);
    static assert(!__traits(compiles, { char[8] t; to_text(Half(1), t); }));
}
