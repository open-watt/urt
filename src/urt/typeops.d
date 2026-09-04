module urt.typeops;

// The single text policy: one canonical encode/decode pair per type, existing together or not at all.
// Sits below Variant; Variant and typed property code both delegate here.

import urt.conv;
import urt.meta.enuminfo;
import urt.traits;

nothrow @nogc:


enum is_builtin(T) = is(Unqual!T == bool) || is_some_int!T || is_some_float!T ||
                     is_enum!T || is(T : const(char)[]);

template has_to_text(T)
{
    enum has_to_text = __traits(compiles, (ref const T v, char[] b) nothrow @nogc {
                           ptrdiff_t r = v.toString(b, null, null); }) ||
                       __traits(compiles, (ref const T v, char[] b) nothrow @nogc {
                           ptrdiff_t r = v.toString(b); });
}

template has_from_text(T)
{
    enum has_from_text = __traits(compiles, (ref T v, const(char)[] s) nothrow @nogc {
                             ptrdiff_t r = v.fromString(s); });
}

enum text_round_trip(T) = is_builtin!T || (has_to_text!T && has_from_text!T);

// writes the canonical text for value; returns length, or <0 on failure (-1: buffer too small)
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
            return format_int(cast(long)value, buffer);
        }
    }
    else static if (is_signed_int!U)
        return format_int(value, buffer);
    else static if (is_unsigned_int!U)
        return format_uint(value, buffer);
    else static if (is_some_float!U)
        return format_float_shortest(U(value), buffer);
    else static if (is(T : const(char)[]))
        return copy_text(value, buffer);
    else
    {
        static assert(has_to_text!T && has_from_text!T,
                      T.stringof ~ " needs both toString and fromString to survive a text wire");
        static if (__traits(compiles, value.toString(buffer, null, null)))
            return value.toString(buffer, null, null);
        else
            return value.toString(buffer);
    }
}

// parses the whole of text into result; returns characters taken, or <0 on failure
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
            return -1;
        }
    }
    else static if (is(T : const(char)[]) && !is(U == bool))
    {
        result = text;
        return text.length;
    }
    else
    {
        static if (!is_builtin!U)
            static assert(has_to_text!T && has_from_text!T,
                          T.stringof ~ " needs both toString and fromString to survive a text wire");
        return parse!T(text, result);
    }
}

private:

ptrdiff_t copy_text(const(char)[] text, char[] buffer)
{
    if (text.length > buffer.length)
        return -1;
    buffer[0 .. text.length] = text[];
    return text.length;
}


unittest
{
    char[64] buf;

    // bool
    assert(to_text(true, buf) == 4 && buf[0 .. 4] == "true");
    bool b;
    assert(from_text("false", b) == 5 && b == false);

    // integers
    assert(to_text(-1234, buf) == 5 && buf[0 .. 5] == "-1234");
    assert(to_text(ulong.max, buf) == 20);
    int i;
    assert(from_text("-42", i) == 3 && i == -42);
    ubyte u8;
    assert(from_text("257", u8) < 0);

    // floats round-trip exactly, and prefer the shortest text that does
    static void check_float(F)(F v, const(char)[] expect = null)
    {
        char[64] t;
        ptrdiff_t n = to_text(v, t);
        assert(n > 0);
        if (expect)
            assert(t[0 .. n] == expect);
        F r;
        assert(from_text(t[0 .. n], r) == n);
        assert(r == v || (r != r && v != v));
    }
    check_float(0.1, "0.1");
    check_float(3.14159265358979);
    check_float(0.1f, "0.1");
    check_float(double.nan);

    // enums
    enum Plain { first, second }
    assert(to_text(Plain.second, buf) == 6 && buf[0 .. 6] == "second");
    Plain p;
    assert(from_text("first", p) == 5 && p == Plain.first);
    assert(from_text("bogus", p) < 0);

    @bitfield enum Flags : ubyte { a = 1, b = 2, c = 4 }
    ptrdiff_t n = to_text(cast(Flags)3, buf);
    assert(n > 0);
    Flags f;
    assert(from_text(buf[0 .. n], f) == n && f == cast(Flags)3);

    // strings pass through
    assert(to_text("hello", buf) == 5 && buf[0 .. 5] == "hello");
    const(char)[] s;
    assert(from_text("world", s) == 5 && s == "world");

    // user types dispatch to their member pair
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
