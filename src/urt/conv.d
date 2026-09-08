module urt.conv;

import urt.meta;
import urt.string;
public import urt.string.format : toString;

nothrow @nogc:

// Workaround for LLVM bug: riscv-isel hangs when stores into a stack buffer
// and memcmp on that buffer are visible in the same function with
// +unaligned-scalar-mem. Preventing inlining keeps them in separate functions.
// See: https://github.com/llvm/llvm-project/issues/XXXXX
pragma(inline, false) private bool streq(const(char)[] a, const(char)[] b) pure
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i])
            return false;
    return true;
}

// on error or not-a-number cases, bytes_taken will contain 0

long parse_int(const(char)[] str, size_t* bytes_taken = null, uint base = 10) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    uint neg = parse_sign(p, e);
    ulong value = p[0 .. e - p].parse_uint(bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += p - s;
    return neg ? -long(value) : long(value);
}

long parse_int_with_base(const(char)[] str, size_t* bytes_taken = null) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    uint neg = parse_sign(p, e);
    uint base = parse_base_prefix(p, e);
    ulong i = p[0 .. e - p].parse_uint(bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += p - s;
    return neg ? -long(i) : long(i);
}

long parse_int_with_exponent(const(char)[] str, out int exponent, size_t* bytes_taken = null, uint base = 10) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    uint neg = parse_sign(p, e);
    ulong value = p[0 .. e - p].parse_uint_with_exponent(exponent, bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += p - s;
    return neg ? -long(value) : long(value);
}

long parse_int_with_exponent_and_base(const(char)[] str, out int exponent, out uint base, size_t* bytes_taken = null) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    uint neg = parse_sign(p, e);
    base = parse_base_prefix(p, e);
    ulong value = p[0 .. e - p].parse_uint_with_exponent(exponent, bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += p - s;
    return neg ? -long(value) : long(value);
}

ulong parse_uint(const(char)[] str, size_t* bytes_taken = null, uint base = 10) pure
{
    debug assert(base > 1 && base <= 36, "Invalid base");

    ulong value = 0;

    const(char)* s = str.ptr;
    const(char)* e = s + str.length;

    if (base <= 10)
    {
        for (; s < e; ++s)
        {
            uint digit = *s - '0';
            if (digit >= base)
                break;
            value = value*base + digit;
        }
    }
    else
    {
        for (; s < e; ++s)
        {
            uint digit = get_digit(*s);
            if (digit >= base)
                break;
            value = value*base + digit;
        }
    }

    if (bytes_taken)
        *bytes_taken = s - str.ptr;
    return value;
}

ulong parse_uint_with_base(const(char)[] str, size_t* bytes_taken = null) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    uint base = parse_base_prefix(p, e);
    ulong i = p[0 .. e - p].parse_uint(bytes_taken, base);
    if (bytes_taken && *bytes_taken != 0)
        *bytes_taken += p - s;
    return i;
}

ulong parse_uint_with_exponent(const(char)[] str, out int exponent, size_t* bytes_taken = null, uint base = 10) pure
{
    bool truncated;
    return parse_scaled_uint(str, exponent, bytes_taken, base, ulong.max, truncated);
}

ulong parse_uint_with_exponent_and_base(const(char)[] str, out int exponent, out uint base, size_t* bytes_taken = null) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    base = parse_base_prefix(p, e);
    ulong value = p[0 .. e - p].parse_uint_with_exponent(exponent, bytes_taken, base);
    if (value && *bytes_taken != 0)
        *bytes_taken += p - s;
    return value;
}

unittest
{
    size_t taken;
    assert(parse_uint("123") == 123);
    assert(parse_int("+123.456") == 123);
    assert(parse_int("-123.456", null, 10) == -123);
    assert(parse_int("11001", null, 2) == 25);
    assert(parse_int("123abc", &taken, 10) == 123 && taken == 3);
    assert(parse_int("!!!", &taken, 10) == 0 && taken == 0);
    assert(parse_int("-!!!", &taken, 10) == 0 && taken == 0);
    assert(parse_int("Wow", &taken, 36) == 42368 && taken == 3);
    assert(parse_uint_with_base("0x100", &taken) == 0x100 && taken == 5);
    assert(parse_int_with_base("-0x100", &taken) == -0x100 && taken == 6);

    int e;
    assert("0001023000".parse_uint_with_exponent(e, &taken, 10) == 1023 && e == 3 && taken == 10);
    assert("0.0012003000".parse_uint_with_exponent(e, &taken, 10) == 12003 && e == -7 && taken == 12);
    assert("00010.23000".parse_uint_with_exponent(e, &taken, 10) == 1023 && e == -2 && taken == 11);
    assert("00012300.0".parse_uint_with_exponent(e, &taken, 10) == 123 && e == 2 && taken == 10);
    assert("00100.00230".parse_uint_with_exponent(e, &taken, 10) == 1000023 && e == -4 && taken == 11);
    assert("0.0".parse_uint_with_exponent(e, &taken, 10) == 0 && e == 0 && taken == 3);
    assert(".01".parse_uint_with_exponent(e, &taken, 10) == 0 && e == 0 && taken == 0);
    assert("10e2".parse_uint_with_exponent(e, &taken, 10) == 1 && e == 3 && taken == 4);
    assert("0.01E+2".parse_uint_with_exponent(e, &taken, 10) == 1 && e == 0 && taken == 7);
    assert("0.01E".parse_uint_with_exponent(e, &taken, 10) == 1 && e == -2 && taken == 4);
    assert("0.01Ex".parse_uint_with_exponent(e, &taken, 10) == 1 && e == -2 && taken == 4);
    assert("0.01E-".parse_uint_with_exponent(e, &taken, 10) == 1 && e == -2 && taken == 4);
    assert("0.01E-x".parse_uint_with_exponent(e, &taken, 10) == 1 && e == -2 && taken == 4);
    assert("18446744073709551615".parse_uint_with_exponent(e, &taken) == ulong.max && e == 0 && taken == 20);
    assert("FFFFFFFFFFFFFFFF".parse_uint_with_exponent(e, &taken, 16) == ulong.max && e == 0 && taken == 16);
    assert("100000000000000000000001".parse_uint_with_exponent(e, &taken) == 10_000_000_000_000_000_000UL && e == 4 && taken == 24);
    assert("18446744073709551616".parse_uint_with_exponent(e, &taken) == 1844674407370955161UL && e == 1 && taken == 20);
    assert("18446744073709551616.25.3".parse_uint_with_exponent(e, &taken) == 1844674407370955161UL && e == 1 && taken == 23);
    assert("18446744073709551615.9e-2".parse_uint_with_exponent(e, &taken) == ulong.max && e == -2 && taken == 25);
    assert("1.8446744073709551616".parse_uint_with_exponent(e, &taken) == 1844674407370955161UL && e == -18 && taken == 21);
    assert("1.8446744073709551616.3".parse_uint_with_exponent(e, &taken) == 1844674407370955161UL && e == -18 && taken == 21);
    assert("1e10".parse_uint_with_exponent(e, &taken, 16) == 481 && e == 1 && taken == 4);
    assert("1e+10".parse_uint_with_exponent(e, &taken, 16) == 1 && e == 10 && taken == 5);
    assert("1E-10".parse_uint_with_exponent(e, &taken, 16) == 1 && e == -10 && taken == 5);
    assert("1.e+2".parse_uint_with_exponent(e, &taken, 16) == 1 && e == 2 && taken == 5);
    assert("1e+".parse_uint_with_exponent(e, &taken, 16) == 30 && e == 0 && taken == 2);
    assert("1e-x".parse_uint_with_exponent(e, &taken, 16) == 30 && e == 0 && taken == 2);
    assert("1e10".parse_uint_with_exponent(e, &taken, 2) == 1 && e == 10 && taken == 4);
    foreach (base; 15 .. 37)
    {
        assert("1e1".parse_uint_with_exponent(e, &taken, base) == base * base + 14 * base + 1 && e == 0 && taken == 3);
        assert("1e+10".parse_uint_with_exponent(e, &taken, base) == 1 && e == 10 && taken == 5);
        assert("1e-10".parse_uint_with_exponent(e, &taken, base) == 1 && e == -10 && taken == 5);
    }
    assert(parse_float("1e+2", null, 16) == 256);
    assert(parse_float("1e-2", null, 16) == 1.0 / 256);
    static assert(parse_float("123.5") == 123.5);
    static assert(parse_float("1e400") == double.infinity);

}

int parse_int_fast(ref const(char)[] text, out bool success) pure
{
    if (!text.length)
        return 0;

    const(char)* s = text.ptr;
    const char* e = s + text.length;

    bool neg = false;
    if (*s == '-')
    {
        neg = true;
        goto skip;
    }
    if (*s == '+')
    {
    skip:
        if (text.length == 1)
            return 0;
        ++s;
    }
    uint i = *s - '0';
    if (i > 9)
        return 0;

    uint max = int.max + neg;

    while (true)
    {
        if (++s == e)
            break;
        uint c = *s - '0';
        if (c > 9)
            break;
        if (i > int.max / 10) // check for overflow
            return 0; // should we take the number from the text stream though?
        i = i*10 + c;
        if (i > max) // check for overflow
            return 0; // should we take the number from the text stream though?
    }
    text = s[0 .. e - s];
    success = true;
    return neg ? -cast(int)i : cast(int)i;
}

unittest
{
    bool success;
    const(char)[] text = "123";
    assert(parse_int_fast(text, success) == 123 && success == true && text.empty);
    text = "-2147483648abc";
    assert(parse_int_fast(text, success) == -2147483648 && success == true && text.length == 3);
    text = "2147483648";
    assert(parse_int_fast(text, success) == 0 && success == false);
    text = "-2147483649";
    assert(parse_int_fast(text, success) == 0 && success == false);
    text = "2147483650";
    assert(parse_int_fast(text, success) == 0 && success == false);
}


double parse_float(const(char)[] str, size_t* bytes_taken = null, uint base = 10) pure
{
    import urt.array : beginsWith;

    bool negative = str.length && str[0] == '-';
    size_t sign = negative || (str.length && str[0] == '+');
    const(char)[] text = str[sign .. $];
    if (base == 10 && (text.beginsWith("nan") || text.beginsWith("inf")))
    {
        if (bytes_taken)
            *bytes_taken = sign + 3;
        return text[0] == 'n' ? double.nan : negative ? -double.infinity : double.infinity;
    }

    version (Tiny) enum ulong decimal_limit = 9_999_999_999_999_999;
    else enum ulong decimal_limit = ulong.max;

    int exponent;
    size_t taken;
    bool truncated;
    ulong mantissa = parse_scaled_uint(text, exponent, &taken, base, base == 10 ? decimal_limit : ulong.max, truncated);
    if (bytes_taken)
        *bytes_taken = taken ? taken + sign : 0;
    if (!taken)
        return double.nan;

    double value = mantissa;
    if (base == 10)
    {
        version (X86) enum bool fast = false;
        else enum bool fast = true;
        if (fast && !truncated && mantissa < (1uL << 53) && exponent >= -22 && exponent <= 22)
            value = exponent < 0 ? value / decimal_powers[-exponent] : value * decimal_powers[exponent];
        else
        {
            version (Tiny) {} else
            {
                if (!__ctfe)
                {
                    import urt.internal.stdc.stdlib : strtod;

                    char[32] buffer = void;
                    size_t length = format_uint(mantissa, buffer);
                    buffer[length++] = 'e';
                    length += format_int(exponent, buffer[length .. $]);
                    buffer[length] = 0;
                    value = strtod(buffer.ptr, null);
                    return negative ? -value : value;
                }
            }
            value = scale_float(value, exponent, base);
        }
    }
    else
        value = scale_float(value, exponent, base);
    return negative ? -value : value;
}

unittest
{
    static bool fcmp(double a, double b) pure
    {
        import urt.math;
        return fabs(a - b) < 10e-23;
    }

    size_t taken;
    assert(fcmp(parse_float("123.456"), 123.456));
    assert(fcmp(parse_float("+123.456"), 123.456));
    assert(fcmp(parse_float("-123.456.789"), -123.456));
    assert(fcmp(parse_float("-123.456e10"), -1.23456e+12));
    assert(fcmp(parse_float("1101.11", &taken, 2), 13.75) && taken == 7);
    assert(parse_float("xyz", &taken) is double.nan && taken == 0);

    assert(parse_float("123.456") == 123.456);
    version (Tiny)
    {
        assert(parse_float("0.3333333333333333") > 0.33333333333332);
        assert(parse_float("3.141592653589793") > 3.14159265358978);
        double maximum = parse_float("1.7976931348623157e308");
        assert(maximum <= double.max && maximum > 1.79769313486230e308);
    }
    else
    {
        assert(parse_float("0.3333333333333333") is 0.3333333333333333);
        assert(parse_float("3.141592653589793") is 3.141592653589793);
        assert(parse_float("1.7976931348623157e308") is 1.7976931348623157e308);
        assert(parse_float("1e308") is 1e308);
        assert(parse_float("2.5e-100") is 2.5e-100);
    }
    assert(parse_float("1e309") == double.infinity);
    assert(parse_float("-1e400") == -double.infinity);
    assert(parse_float("1e-400") == 0);
    assert(parse_float("1.0000000000000000011") == 1);
    assert(parse_float("10000000000000000011") == 1e19);
    assert(parse_float("1111111111111111111", null, 2) == 524287);
    assert(parse_float("9e308") == double.infinity);
    assert(parse_float("123456789012345678e300") == double.infinity);
    assert(parse_float("1e4294967296") == double.infinity);
    assert(parse_float("1e-4294967296") == 0);
    assert(parse_float("0e400", &taken) == 0 && taken == 5);
    assert(parse_float("-0") is -0.0);
    assert(parse_float("000000000000000000000000000000000000000000000000000000000000000000000000000001.25") == 1.25);
    assert(parse_float("10000000000000000000000000000000000000000000000000000000000000000000000000000000e-79") == 1);
    assert(parse_float("nan") is double.nan);
    assert(parse_float("-inf") == -double.infinity);

    version (Tiny)
    {
        ulong seed = 123456789;
        char[32] buffer;
        foreach (i; 0 .. 1000)
        {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            ulong bits = seed & 0x7fff_ffff_ffff_ffff;
            if (bits >= 0x7ff0_0000_0000_0000)
                continue;
            double value = *cast(double*)&bits;
            ptrdiff_t n = format_float(value, buffer, ".17");
            assert(n > 0);
            double parsed = parse_float(buffer[0 .. n]);
            ulong got = *cast(ulong*)&parsed;
            assert((got > bits ? got - bits : bits - got) <= 32);
        }
    }
    else
    {
        assert(parse_float("2.2250738585072011e-308") == double.min_normal * (1 - double.epsilon));
        assert(parse_float("4.9406564584124654e-324") == double.min_normal * double.epsilon);
        assert(parse_float("123456789012345678901234567890") == 123456789012345678901234567890.0);

        import urt.rand : rand;
        char[32] fbuf;
        foreach (i; 0 .. 10_000)
        {
            ulong bits = (ulong(rand()) << 32) | rand();
            double v = *cast(double*)&bits;
            if (v != v || v == double.infinity || v == -double.infinity)
                continue;
            ptrdiff_t n = format_float(v, fbuf, ".17");
            assert(n > 0);
            double r = parse_float(fbuf[0 .. n]);
            assert(*cast(ulong*)&r == bits || (v == 0 && r == 0));
        }
    }
}


ptrdiff_t parse(T)(const char[] text, out T result)
{
    import urt.array : beginsWith;
    import urt.traits;

    alias UT = Unqual!T;

    static if (is(UT == bool))
    {
        if (text.beginsWith("true"))
        {
            result = true;
            return 4;
        }
        result = false;
        if (text.beginsWith("false"))
            return 5;
        return -1;
    }
    else static if (is_some_int!T)
    {
        size_t taken;
        static if (is_signed_int!T)
            long r = text.parse_int(&taken);
        else
            ulong r = text.parse_uint(&taken);
        if (!taken)
            return -1;
        if (r >= T.min && r <= T.max)
        {
            result = cast(T)r;
            return taken;
        }
        return -2;
    }
    else static if (is_some_float!T)
    {
        size_t taken;
        double f = text.parse_float(&taken);
        if (!taken)
            return -1;
        result = cast(T)f;
        return taken;
    }
    else static if (is_enum!T)
    {
        static assert(false, "TODO: do we want to parse from enum keys?");
        // case-sensitive?
    }
    else static if (is(T == struct) && __traits(compiles, { result.fromString(text); }))
    {
        return result.fromString(text);
    }
    else
        static assert(false, "Cannot parse " ~ T.stringof ~ " from string");
}

unittest
{
    {
        bool r;
        assert("true".parse(r) == 4 && r == true);
        assert("false".parse(r) == 5 && r == false);
        assert("wow".parse(r) == -1);
    }
    {
        int r;
        assert("-10".parse(r) == 3 && r == -10);
    }
    {
        ubyte r;
        assert("10".parse(r) == 2 && r == 10);
        assert("-10".parse(r) == -1);
        assert("257".parse(r) == -2);
    }
    {
        float r;
        assert("10".parse(r) == 2 && r == 10.0f);
        assert("-2.5".parse(r) == 4 && r == -2.5f);
    }
    {
        import urt.inet;
        IPAddr r;
        assert("10.0.0.1".parse(r) == 8 && r == IPAddr(10,0,0,1));
    }
}


ptrdiff_t format_int(long value, char[] buffer, uint base = 10, uint width = 0, char fill = ' ', bool show_sign = false) pure
{
    const bool neg = value < 0;
    show_sign |= neg;

    if (buffer.ptr && buffer.length < show_sign)
        return -1;

    ulong i = neg ? -value : value;

    ptrdiff_t r = format_uint(i, buffer.ptr ? buffer.ptr[(width == 0 ? show_sign : 0) .. buffer.length] : null, base, width, fill);
    if (r < 0 || !show_sign)
        return r;

    if (buffer.ptr)
    {
        char sgn = neg ? '-' : '+';

        if (width == 0)
        {
            buffer.ptr[0] = sgn;
            return r + 1;
        }
        if (buffer.ptr[0] == '0')
        {
            // this handles cases where the number was padded with leading zeroes
            // it should format as: "-000123" instead of "   -123"
            buffer.ptr[0] = sgn;
            return r;
        }
        if (buffer.ptr[0] == fill)
        {
            // we don't need to shift it left...
            size_t sgn_offset = 0;
            while (buffer.ptr[sgn_offset + 1] == fill)
                ++sgn_offset;
            buffer.ptr[sgn_offset] = sgn;
            return r;
        }

        // we need to shift the number right...
        // TODO: this is a bad case; maybe we should have reserved space in the first place?
        if (buffer.length < r + 1)
            return -1;
        for (size_t j = r; j > 0; --j)
            buffer.ptr[j] = buffer.ptr[j - 1];
        buffer.ptr[0] = sgn;
        return r + 1;
    }

    // determine if the formatted number would have padding, because the sign character will consume padding bytes
    if (r == width && i < base^^cast(uint)(width - 1))
        return r;
    return r + 1;
}

ptrdiff_t format_uint(ulong value, char[] buffer, uint base = 10, uint width = 0, char fill = ' ') pure
{
    import urt.util : max;

    assert(base >= 2 && base <= 36, "Invalid base");

    ulong i = value;
    uint num_len = 0;
    char[64] t = void;
    if (i == 0)
    {
        if (buffer.length > 0)
            t.ptr[0] = '0';
        num_len = 1;
    }
    else
    {
        // TODO: if this is a hot function, the if's could be hoisted outside the loop.
        //       there are 8 permutations...
        //       also, some platforms might prefer a lookup table than `d < 10 ? ... : ...`
        for (; i != 0; i /= base)
        {
            if (buffer.ptr)
            {
                int d = cast(int)(i % base);
                t.ptr[num_len] = cast(char)((d < 10 ? '0' : 'A' - 10) + d);
            }
            ++num_len;
        }
    }

    uint len = max(num_len, width);
    uint padding = width > num_len ? width - num_len : 0;

    if (buffer.ptr)
    {
        if (buffer.length < len)
            return -1;

        size_t offset = 0;
        while (padding--)
            buffer.ptr[offset++] = fill;
        for (uint j = num_len; j > 0; )
            buffer.ptr[offset++] = t[--j];
    }
    return len;
}

unittest
{
    char[64] buffer;
    assert(format_int(0, null) == 1);
    assert(format_int(14, null) == 2);
    assert(format_int(14, null, 16) == 1);
    assert(format_int(-14, null) == 3);
    assert(format_int(-14, null, 16) == 2);
    assert(format_int(-14, null, 16, 3, '0') == 3);
    assert(format_int(-123, null, 10, 6) == 6);
    assert(format_int(-123, null, 10, 3) == 4);
    assert(format_int(-123, null, 10, 2) == 4);

    size_t len = format_int(0, buffer);
    assert(streq(buffer[0 .. len], "0"));
    len = format_int(14, buffer);
    assert(streq(buffer[0 .. len], "14"));
    len = format_int(14, buffer, 2);
    assert(streq(buffer[0 .. len], "1110"));
    len = format_int(14, buffer, 8, 3);
    assert(streq(buffer[0 .. len], " 16"));
    len = format_int(14, buffer, 16, 4, '0');
    assert(streq(buffer[0 .. len], "000E"));
    len = format_int(-14, buffer, 16, 3, '0');
    assert(streq(buffer[0 .. len], "-0E"));
    len = format_int(12345, buffer, 10, 3);
    assert(streq(buffer[0 .. len], "12345"));
    len = format_int(-123, buffer, 10, 6);
    assert(streq(buffer[0 .. len], "  -123"));
}


ptrdiff_t format_float(double value, char[] buffer, const(char)[] format = null) pure
{
    // TODO: implement natively so this can run at CTFE.

    import urt.string.format : concat;

    char[64] result = void;

    // parse format; precision is '.10' => 10 digits
    int digits = 6;
    size_t dot = format.findFirst('.');
    if (dot < format.length)
        digits = cast(int)parse_uint(format[dot + 1 .. $]);

    if (value == 0)
        value = 0; // normalise -0.0 so we never render a signed zero as "-0"

    version (Windows)
    {
        import urt.internal.stdc.stdlib : _gcvt_s;
        int err = _gcvt_s(result.ptr, result.length, value, digits);
        if (err != 0)
            return -2;
    }
    else
    {
        import urt.internal.stdc.stdlib : gcvt;
        if (gcvt(value, digits, result.ptr) is null)
            return -2;
    }
    size_t len = result.ptr.strlen();
    if (result[len - 1] == '.')
        --len; // trim trailing '.' if no digits follow it
    else
    {
        // normalise output - gcvt may emit something like "5.e-003"
        // strip lone '.', strip leading zeroes, result: 5e-3
        foreach (i; 1 .. len)
        {
            if (result[i] != 'e' && result[i] != 'E')
                continue;

            size_t e = i;
            if (result[e - 1] == '.')
            {
                foreach (j; e .. len)
                    result[j - 1] = result[j];
                --len;
                --e;
            }

            size_t exp_d = e + 1;
            if (exp_d < len && (result[exp_d] == '+' || result[exp_d] == '-'))
                ++exp_d;
            size_t zeros = 0;
            while (exp_d + zeros + 1 < len && result[exp_d + zeros] == '0')
                ++zeros;
            if (zeros)
            {
                foreach (j; exp_d + zeros .. len)
                    result[j - zeros] = result[j];
                len -= zeros;
            }
            break;
        }
    }
    if (buffer.ptr)
    {
        if (len > buffer.length)
            return -1;
        buffer[0 .. len] = result[0 .. len];
    }
    return len;
}

ptrdiff_t format_float_shortest(F)(F value, char[] buffer) pure
    if (is(F == double) || is(F == float))
    => format_shortest_impl(value, buffer, is(F == float) ? 9 : 17, is(F == float));


unittest
{
    char[64] t;

    static void check_shortest(F)(F v, const(char)[] expect = null)
    {
        char[64] b;
        ptrdiff_t n = format_float_shortest(v, b);
        assert(n > 0);
        if (expect)
            assert(b[0 .. n] == expect);
        size_t taken;
        double r = parse_float(b[0 .. n], &taken);
        assert(taken == n);
        version (Tiny)
        {
            import urt.math : fabs;
            double tolerance = is(F == float) ? 1e-6 : 1e-13;
            assert(r == v || (r != r && v != v) || fabs(r / v - 1) < tolerance);
        }
        else
            assert(cast(F)r is v || (r != r && v != v));
    }
    check_shortest(0.0, "0");
    check_shortest(1.5, "1.5");
    check_shortest(0.1, "0.1");
    check_shortest(1.0 / 3.0);
    check_shortest(3.14159265358979);
    check_shortest(1e30);
    check_shortest(-2.5e-10);
    check_shortest(double.max);
    check_shortest(0.1f, "0.1");
    check_shortest(float.max);
    check_shortest(double.nan);
    check_shortest(-double.infinity);

    assert(format_float_shortest(1.5, null) == 3);
    assert(format_float_shortest(double.nan, null) == 3);
    assert(format_float_shortest(1.5, t[0 .. 2]) == -1);
    assert(format_float_shortest(-0.0, t) == 1 && t[0] == '0');
}

unittest
{
    import urt.io;
    char[64] buf;
    auto len = format_float(0.0, buf);
    assert(buf[0..len] == "0");
    len = format_float(1.0, buf);
    assert(buf[0..len] == "1");
    len = format_float(-1.0, buf);
    assert(buf[0..len] == "-1");
    len = format_float(3.14159, buf);
    assert(buf[0..len] == "3.14159");
    len = format_float(3.14159, buf, ".3");
    assert(buf[0..len] == "3.14");
    len = format_float(1.5, buf);
    assert(buf[0..len] == "1.5");
    len = format_float(1e6, buf);
    assert(buf[0..len] == "1e+6");
    len = format_float(1e6, buf, ".7");
    assert(buf[0..len] == "1000000");
    len = format_float(0.001, buf);
    assert(buf[0..len] == "0.001" || buf[0..len] == "1e-3"); // i don't know why it emits e-3 :/
    len = format_float(-0.0, buf);
    assert(buf[0..len] == "0"); // signed zero is normalised, never "-0"
}


template to(T)
{
    import urt.traits;

    static if (is(T == long))
    {
        long to(const(char)[] str)
        {
            uint base = parse_base_prefix(str);
            size_t taken;
            long r = parse_int(str, &taken, base);
            assert(taken == str.length, "String is not numeric");
            return r;
        }
    }
    else static if (is(T == double))
    {
        double to(const(char)[] str)
        {
            uint base = parse_base_prefix(str);
            size_t taken;
            double r = parse_float(str, &taken, base);
            assert(taken == str.length, "String is not numeric");
            return r;
        }
    }
    else static if (is_some_int!T) // call-through for other int types; reduce instantiation bloat
    {
        T to(const(char)[] str)
            => cast(T)to!long(str);
    }
    else static if (is_some_float!T) // call-through for other float types; reduce instantiation bloat
    {
        T to(const(char)[] str)
            => cast(T)to!double(str);
    }
    else static if (is(T == struct) || is(T == class))
    {
        // if aggregates have a fromString() function, we can use it to parse the string...
        static assert(is(typeof(&(T.init).fromString) == bool delegate(const(char)[], ulong*) nothrow @nogc), "Aggregate requires 'fromString' member");

        T to(const(char)[] str)
        {
            T r;
            ptrdiff_t taken = r.fromString(str);
            assert(taken == str.length, "Failed to parse string as " ~ T.stringof);
            return r;
        }
    }
    else static if (is(T : const(char)[]))
    {
        const(char)[] to(ref T)
        {
            static assert(false, "TODO");
        }
    }
}


private:

ptrdiff_t format_shortest_impl(double value, char[] buffer, uint max_digits, bool as_float) pure
{
    if (value != value)
        return copy_shortest("nan", buffer);
    if (value == double.infinity)
        return copy_shortest("inf", buffer);
    if (value == -double.infinity)
        return copy_shortest("-inf", buffer);

    version (Tiny)
    {
        const(char)[] precision = as_float ? ".8" : ".16";
        if (value > 1e308 || value < -1e308)
            precision = ".17";
        return format_float(value, buffer, precision);
    }
    else
    {
        char[4] spec = void;
        char[64] tmp = void;
        foreach (uint digits; 1 .. max_digits + 1)
        {
            spec[0] = '.';
            ptrdiff_t sl = 1 + format_uint(digits, spec[1 .. $]);
            ptrdiff_t n = format_float(value, tmp, spec[0 .. sl]);
            if (n <= 0)
                return n;

            size_t taken;
            double r = parse_float(tmp[0 .. n], &taken);
            if (taken == n && (as_float ? cast(float)r is cast(float)value : r is value))
                return copy_shortest(tmp[0 .. n], buffer);

            if (digits == max_digits)
                return copy_shortest(tmp[0 .. n], buffer);
        }
        return -2;
    }
}

ptrdiff_t copy_shortest(const(char)[] text, char[] buffer) pure
{
    if (buffer.ptr)
    {
        if (text.length > buffer.length)
            return -1;
        buffer[0 .. text.length] = text[];
    }
    return text.length;
}

immutable double[23] decimal_powers = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
];

ulong parse_scaled_uint(const(char)[] str, out int exponent, size_t* bytes_taken, uint base, ulong limit, out bool truncated) pure
{
    debug assert(base > 1 && base <= 36, "Invalid base");

    const(char)* s = str.ptr;
    const(char)* e = s + str.length;

    ulong value = 0;
    int exp = 0;
    uint digits = 0;
    uint zero_seq = 0;
    char c = void;
    ulong cutoff = limit / base;
    uint last_digit = cast(uint)(limit % base);
    bool fractional = void;

    for (; s < e; ++s)
    {
        c = *s;

        if (c == '.')
        {
            if (s == str.ptr)
                goto done;
            ++s;
            exp = zero_seq;
            goto parse_decimal;
        }
        else if (c == '0')
        {
            ++zero_seq;
            continue;
        }

        uint digit = get_digit(c);
        if (digit >= base || (digit == 14 && e - s > 2 && (s[1] == '+' || s[1] == '-') && s[2].is_numeric))
            break;

        if (digits)
        {
            for (uint i = 0; i <= zero_seq; ++i)
            {
                if (value > cutoff || (value == cutoff && i == zero_seq && digit > last_digit))
                {
                    exp = cast(int)(zero_seq - i + 1);
                    fractional = false;
                    goto discard_digits;
                }
                value = value * base;
            }
            digits += zero_seq;
        }
        value += digit;
        digits += 1;
        zero_seq = 0;
    }

    if (!digits)
        goto nothing;

    exp = zero_seq;
    goto check_exp;

parse_decimal:
    for (; s < e; ++s)
    {
        c = *s;

        if (c == '0')
        {
            ++zero_seq;
            continue;
        }

        uint digit = get_digit(c);
        if (digit >= base || (digit == 14 && e - s > 2 && (s[1] == '+' || s[1] == '-') && s[2].is_numeric))
            break;

        if (digits)
        {
            for (uint i = 0; i <= zero_seq; ++i)
            {
                if (value > cutoff || (value == cutoff && i == zero_seq && digit > last_digit))
                {
                    exp -= i;
                    fractional = true;
                    goto discard_digits;
                }
                value = value * base;
            }
            digits += zero_seq;
        }
        value += digit;
        digits += 1;
        exp -= 1 + zero_seq;
        zero_seq = 0;
    }
    if (!digits)
        goto nothing;

check_exp:
    if (s > str.ptr && e - s > 1 && ((*s | 0x20) == 'e'))
    {
        c = s[1];
        bool exp_neg = c == '-';
        if (exp_neg || c == '+')
        {
            if (e - s <= 2 || !s[2].is_numeric)
                goto done;
            s += 2;
        }
        else
        {
            if (!c.is_numeric)
                goto done;
            ++s;
        }

        int exp_value = 0;
        for (; s < e; ++s)
        {
            uint digit = *s - '0';
            if (digit > 9)
                break;
            if (exp_value < 1_000_000)
                exp_value = exp_value * 10 + digit;
        }
        exp += exp_neg ? -exp_value : exp_value;
    }

done:
    exponent = value ? exp : 0;
    if (bytes_taken)
        *bytes_taken = s - str.ptr;
    return value;

nothing:
    exp = 0;
    goto check_exp;

discard_digits:
    truncated = true;
    for (++s; s < e; ++s)
    {
        c = *s;
        if (c == '.' && !fractional)
        {
            fractional = true;
            continue;
        }
        uint digit = get_digit(c);
        if (digit >= base || (digit == 14 && e - s > 2 && (s[1] == '+' || s[1] == '-') && s[2].is_numeric))
            break;
        if (!fractional)
            ++exp;
    }
    goto check_exp;
}

double scale_float(double value, int exponent, uint base) pure
{
    if (value == 0)
        return value;
    if (exponent > (base == 10 ? 308 : 1100))
        return double.infinity;
    if (exponent < (base == 10 ? -350 : -1200))
        return 0;
    uint step = base == 10 ? 22 : 1;
    double factor = base == 10 ? decimal_powers[22] : base;
    while (exponent >= cast(int)step)
    {
        value *= factor;
        exponent -= step;
    }
    while (exponent <= -cast(int)step)
    {
        value /= factor;
        exponent += step;
    }
    if (exponent > 0)
        value *= decimal_powers[exponent];
    else if (exponent < 0)
        value /= decimal_powers[-exponent];
    return value > double.max ? double.infinity : value;
}

// valid result is 0 .. 35; result is garbage outside that bound
uint get_digit(char c) pure
{
    uint zero_base = c - '0';
    if (zero_base < 10)
        return zero_base;
    uint a_base = (c | 0x20) - 'a';
    return 10 + (a_base & 0xFF);
}

uint parse_base_prefix(ref const(char)* str, const(char)* end) pure
{
    uint base = 10;
    if (str + 2 <= end && str[0] == '0')
    {
        if (str[1] == 'x')
            base = 16, str += 2;
        else if (str[1] == 'b')
            base = 2, str += 2;
        else if (str[1] == 'o')
            base = 8, str += 2;
    }
    return base;
}

uint parse_sign(ref const(char)* str, const(char)* end) pure
{
    if (str == end)
        return 0;
    // NOTE: ascii is '+' = 43, '-' = 45
    uint neg = *str - '+';
    if (neg > 2 || neg == 1)
        return 0;
    ++str;
    return neg; // neg is 0 (+) or 2 (-)
}


/+
size_t format_struct(T)(ref T value, char[] buffer) nothrow @nogc
{
    import urt.string.format;

    static assert(is(T == struct), "T must be some struct");

    alias args = value.tupleof;
//    alias args = AliasSeq!(value.tupleof);
//    alias args = INTERLEAVE_SEPARATOR!(", ", value.tupleof);
//    pragma(msg, args);
    return concat(buffer, args).length;
}

unittest
{
    import router.iface;

    Packet p;

    char[1024] buffer;
    size_t len = format_struct(p, buffer);
    assert(buffer[0 .. len] == "Packet()");

}
+/
