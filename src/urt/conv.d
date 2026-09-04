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

long parse_int_with_exponent(const(char)[] str, out int exponent, size_t* bytes_taken = null, uint base = 10, bool* truncated = null) pure
{
    const(char)* s = str.ptr, e = s + str.length, p = s;
    uint neg = parse_sign(p, e);
    ulong value = p[0 .. e - p].parse_uint_with_exponent(exponent, bytes_taken, base, truncated);
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

ulong parse_uint_with_exponent(const(char)[] str, out int exponent, size_t* bytes_taken = null, uint base = 10, bool* truncated = null) pure
{
    debug assert(base > 1 && base <= 36, "Invalid base");

    const(char)* s = str.ptr;
    const(char)* e = s + str.length;

    ulong value = 0;
    int exp = 0;
    uint digits = 0;
    uint zero_seq = 0;
    uint dropped = 0;
    char c = void;

    for (; s < e; ++s)
    {
        c = *s;

        if (c == '.')
        {
            if (s == str.ptr)
                goto done;
            ++s;
            exp = zero_seq + dropped;
            goto parse_decimal;
        }
        else if (c == '0')
        {
            ++zero_seq;
            continue;
        }

        uint digit = get_digit(c);
        if (digit >= base)
            break;

        // 18 significant digits keeps the mantissa clear of overflow; the rest scale the exponent
        if (digits && digits + zero_seq + 1 > 18)
        {
            dropped += 1 + zero_seq;
            zero_seq = 0;
            if (truncated)
                *truncated = true;
            continue;
        }

        if (digits)
        {
            for (uint i = 0; i <= zero_seq; ++i)
                value = value * base;
            digits += zero_seq;
        }
        value += digit;
        digits += 1;
        zero_seq = 0;
    }

    // number has no decimal point, tail zeroes are positive exp
    if (!digits)
        goto nothing;

    exp = zero_seq + dropped;
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
        if (digit >= base)
            break;

        if (digits && digits + zero_seq + 1 > 18)
        {
            zero_seq = 0;
            if (truncated)
                *truncated = true;
            continue;
        }

        if (digits)
        {
            for (uint i = 0; i <= zero_seq; ++i)
                value = value * base;
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
    // check for exponent part
    if (s + 1 < e && ((*s | 0x20) == 'e'))
    {
        c = s[1];
        bool exp_neg = c == '-';
        if (exp_neg || c == '+')
        {
            if (s + 2 >= e || !s[2].is_numeric)
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
            exp_value = exp_value * 10 + digit;
        }
        exp += exp_neg ? -exp_value : exp_value;
    }

done:
    exponent = exp;
    if (bytes_taken)
        *bytes_taken = s - str.ptr;
    return value;

nothing:
    exp = 0;
    goto done;
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


// on error or not-a-number, result will be nan and bytes_taken will contain 0
double parse_float(const(char)[] str, size_t* bytes_taken = null, uint base = 10) pure
{
    import urt.math : pow;

    {
        import urt.array : beginsWith;

        bool neg = str.length > 0 && str[0] == '-';
        const(char)[] body_ = neg || (str.length > 0 && str[0] == '+') ? str[1 .. $] : str;
        if (body_.beginsWith("nan"))
        {
            if (bytes_taken)
                *bytes_taken = str.length - body_.length + 3;
            return double.nan;
        }
        if (body_.beginsWith("inf"))
        {
            if (bytes_taken)
                *bytes_taken = str.length - body_.length + 3;
            return neg ? -double.infinity : double.infinity;
        }
    }

    int e;
    size_t taken;
    bool truncated;
    long mantissa = str.parse_int_with_exponent(e, &taken, base, &truncated);
    if (bytes_taken)
        *bytes_taken = taken;
    if (taken == 0)
        return double.nan;

    if (base == 10)
    {
        // one exactly-representable multiply/divide is correctly rounded; covers the whole
        // range shortest-form output produces for values of sane magnitude
        static immutable double[23] pow10 = [
            1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
            1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 ];
        ulong m = mantissa < 0 ? cast(ulong)-mantissa : cast(ulong)mantissa;
        if (m < (1uL << 53))
        {
            if (e >= 0 && e <= 22)
                return mantissa * pow10[e];
            if (e < 0 && e >= -22)
                return mantissa / pow10[-e];
        }

        // Dekker splitting needs strict double rounding, which CTFE doesn't promise
        if (!__ctfe)
        {
            bool certain;
            double r = decimal_to_double(m, e, truncated, certain);
            if (mantissa < 0)
                r = -r;
            if (certain)
                return r;

            version (Tiny) {} else
            {
                // the uncertifiable residue: within ~2^-90 of a rounding boundary, magnitude
                // edges, or >18 significant digits. The CRT resolves it (as gcvt does for
                // format_float); Tiny accepts the last ulp instead of newlib's dtoa machinery.
                import urt.internal.stdc.stdlib : strtod;

                char[64] tmp = void;
                size_t len = taken < tmp.length - 1 ? taken : tmp.length - 1;
                tmp[0 .. len] = str[0 .. len];
                tmp[len] = '\0';

                char* end;
                double sr = strtod(tmp.ptr, &end);
                if (end > tmp.ptr)
                    return sr;
            }
            return r;
        }
    }

    if (__ctfe)
        return mantissa * double(base)^^e;
    else
        return mantissa * pow(double(base), e);
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

    // exact decimal -> binary; the compiler's own literals are the oracle
    assert(parse_float("123.456") == 123.456);
    assert(parse_float("0.3333333333333333") == 0.3333333333333333);
    assert(parse_float("3.141592653589793") == 3.141592653589793);
    assert(parse_float("1.7976931348623157e308") == 1.7976931348623157e308);
    assert(parse_float("1e308") == 1e308);
    assert(parse_float("2.5e-100") == 2.5e-100);
    assert(parse_float("1e309") == double.infinity);
    assert(parse_float("-1e400") == -double.infinity);
    assert(parse_float("1e-400") == 0);
    assert(parse_float("nan") is double.nan);
    assert(parse_float("-inf") == -double.infinity);

    version (Tiny) {} else
    {
        // subnormals and truncated mantissas resolve through the fallback
        assert(parse_float("2.2250738585072011e-308") == 2.2250738585072011e-308);
        assert(parse_float("4.9406564584124654e-324") == 4.9406564584124654e-324);
        assert(parse_float("123456789012345678901234567890") == 123456789012345678901234567890.0);

        // every double must round-trip through 17 significant digits
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

// shortest text which parses back to the exact same value
ptrdiff_t format_float_shortest(F)(F value, char[] buffer) pure
    if (is(F == double) || is(F == float))
    => format_shortest_impl(value, buffer, is(F == float) ? 9 : 17, is(F == float));

private ptrdiff_t format_shortest_impl(double value, char[] buffer, uint max_digits, bool as_float) pure
{
    if (value != value)
        return copy_shortest("nan", buffer);
    if (value == double.infinity)
        return copy_shortest("inf", buffer);
    if (value == -double.infinity)
        return copy_shortest("-inf", buffer);

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
        if (taken == n && (as_float ? cast(float)r == cast(float)value : r == value))
            return copy_shortest(tmp[0 .. n], buffer);

        // a parser without correct rounding at this magnitude (Tiny) can't verify any
        // candidate; emit full precision rather than fail
        if (digits == max_digits)
            return copy_shortest(tmp[0 .. n], buffer);
    }
    return -2;
}

private ptrdiff_t copy_shortest(const(char)[] text, char[] buffer) pure
{
    if (text.length > buffer.length)
        return -1;
    buffer[0 .. text.length] = text[];
    return text.length;
}

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
        assert(cast(F)r == v || (r != r && v != v));
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

    // -0.0 deliberately normalises to "0" (format_float policy)
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

struct DD { double hi; double lo; }

DD dd_mul(DD a, DD b) pure
{
    enum double splitter = 134217729.0; // 2^27 + 1

    double ca = splitter * a.hi;
    double ahi = ca - (ca - a.hi);
    double alo = a.hi - ahi;
    double cb = splitter * b.hi;
    double bhi = cb - (cb - b.hi);
    double blo = b.hi - bhi;

    double p = a.hi * b.hi;
    double err = ((ahi*bhi - p) + ahi*blo + alo*bhi) + alo*blo;
    err += a.hi*b.lo + a.lo*b.hi;

    double s = p + err;
    return DD(s, err - (s - p));
}

// 10^(2^k) as exact hi/lo double pairs
static immutable DD[9] dd_pow10_pos = [
    DD(0x1.4p+3, 0.0), DD(0x1.9p+6, 0.0), DD(0x1.388p+13, 0.0), DD(0x1.7d784p+26, 0.0),
    DD(0x1.1c37937e08p+53, 0.0), DD(0x1.3b8b5b5056e17p+106, -0x1.3107fp+52),
    DD(0x1.84f03e93ff9f5p+212, -0x1.2ac340948e389p+157),
    DD(0x1.27748f9301d32p+425, -0x1.901cc86649e4ap+371),
    DD(0x1.54fdd7f73bf3cp+850, -0x1.7222446fe467p+795) ];
static immutable DD[9] dd_pow10_neg = [
    DD(0x1.999999999999ap-4, -0x1.999999999999ap-58),
    DD(0x1.47ae147ae147bp-7, -0x1.eb851eb851eb8p-63),
    DD(0x1.a36e2eb1c432dp-14, -0x1.6a161e4f765fep-68),
    DD(0x1.5798ee2308c3ap-27, -0x1.03023df2d4c94p-82),
    DD(0x1.cd2b297d889bcp-54, 0x1.5b4c2ebe68799p-109),
    DD(0x1.9f623d5a8a733p-107, -0x1.a2cc10f3892d4p-161),
    DD(0x1.50ffd44f4a73dp-213, 0x1.a53f2398d747bp-268),
    DD(0x1.bba08cf8c979dp-426, -0x1.afa9c1a60497dp-480),
    DD(0x1.8062864ac6f43p-851, 0x1.39fa911155ffp-906) ];

// ~106-bit m*10^e; certain reports that the double rounding is proven correct, which holds
// for everything except values within ~2^-90 of a rounding boundary and the magnitude edges
double decimal_to_double(ulong m, int e, bool truncated, out bool certain) pure
{
    if (m == 0)
    {
        certain = true;
        return 0.0;
    }
    if (e > 308)
    {
        certain = true;
        return double.infinity;
    }
    if (e < -360)
    {
        certain = true;
        return 0.0;
    }

    double hi = m;
    DD acc = DD(hi, cast(double)cast(long)(m - cast(ulong)hi));
    uint ae = e < 0 ? cast(uint)-e : cast(uint)e;
    foreach (k; 0 .. 9)
    {
        if (ae & (1u << k))
            acc = dd_mul(acc, e < 0 ? dd_pow10_neg[k] : dd_pow10_pos[k]);
    }

    double mag = acc.hi < 0 ? -acc.hi : acc.hi;
    if (acc.lo != acc.lo || !(mag < double.infinity) || mag < 0x1p-1000)
    {
        certain = false;
        return acc.hi + (acc.lo == acc.lo ? acc.lo : 0.0);
    }

    double err = 0x1p-90 * mag;
    certain = !truncated && (acc.hi + (acc.lo - err)) == (acc.hi + (acc.lo + err));
    return acc.hi + acc.lo;
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
