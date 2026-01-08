module urt.string;

import urt.string.uni;
import urt.traits : is_some_char;

public import urt.string.ascii;
public import urt.string.string;
public import urt.string.tailstring;

// seful string operations defined elsewhere
public import urt.array : empty, popFront, popBack, takeFront, takeBack;
public import urt.mem : strlen, wcslen;
public import urt.mem.temp : tstringz, twstringz;

nothrow @nogc:


size_t strlen_s(const(char)[] s) pure
{
    size_t len = 0;
    while (len < s.length && s[len] != '\0')
        ++len;
    return len;
}

ptrdiff_t cmp(bool case_insensitive = false, T, U)(const(T)[] a, const(U)[] b) pure
{
    static if (case_insensitive)
        return uni_compare_i(a, b);
    else
    {
        static if (is(T == U))
        {
            if (a.length != b.length)
                return a.length - b.length;
        }
        return uni_compare(a, b);
    }
}

ptrdiff_t icmp(T, U)(const(T)[] a, const(U)[] b) pure
    => cmp!true(a, b);

bool eq(const(char)[] a, const(char)[] b) pure
    => cmp(a, b) == 0;

bool ieq(const(char)[] a, const(char)[] b) pure
    => cmp!true(a, b) == 0;

size_t findFirst(bool case_insensitive = false, T, U)(const(T)[] s, const U c)
    if (is_some_char!T && is_some_char!U)
{
    static if (is(U == char))
        assert(c <= 0x7F, "Invalid UTF character");
    else static if (is(U == wchar))
        assert(c < 0xD800 || c >= 0xE000, "Invalid UTF character");

    // TODO: what if `c` is 'ß'? do we find "ss" in case-insensitive mode?
    //       and if `c` is 's', do we match 'ß'?

    static if (case_insensitive)
        const U lc = cast(U)c.uni_case_fold();
    else
        alias lc = c;

    size_t i = 0;
    while (i < s.length)
    {
        static if (U.sizeof <= T.sizeof)
        {
            enum l = 1;
            dchar d = s[i];
        }
        else
        {
            size_t l;
            dchar d = next_dchar(s[i..$], l);
        }
        static if (case_insensitive)
        {
            static if (is(U == char))
            {
                // only fold the ascii characters, since lc is known to be ascii
                if (uint(d - 'A') < 26)
                    d |= 0x20;
            }
            else
                d = d.uni_case_fold();
        }
        if (d == lc)
            break;
        i += l;
    }
    return i;
}

size_t find_first_i(T, U)(const(T)[] s, U c)
    if (is_some_char!T && is_some_char!U)
    => findFirst!true(s, c);

size_t findLast(bool case_insensitive = false, T, U)(const(T)[] s, const U c)
    if (is_some_char!T && is_some_char!U)
{
    static assert(case_insensitive == false, "TODO");

    static if (is(U == char))
        assert(c <= 0x7F, "Invalid unicode character");
    else static if (is(U == wchar))
        assert(c >= 0xD800 && c < 0xE000, "Invalid unicode character");

    ptrdiff_t last = s.length-1;
    while (last >= 0)
    {
        static if (U.sizeof <= T.sizeof)
        {
            if (s[last] == c)
                return cast(size_t)last;
        }
        else
        {
            // this is tricky, because we need to seek backwards to the start of surrogate sequences
            assert(false, "TODO");
        }
    }
    return s.length;
}

size_t find_last_i(T, U)(const(T)[] s, U c)
    if (is_some_char!T && is_some_char!U)
    => findLast!true(s, c);

size_t findFirst(bool case_insensitive = false, T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
{
    if (t.length == 0)
        return 0;

    // fast-path for one-length tokens
    size_t l = t.uni_seq_len();
    if (l == t.length)
    {
        dchar c = t.next_dchar(l);
        if (c < 0x80)
            return findFirst!case_insensitive(s, cast(char)c);
        if (c < 0x10000)
            return findFirst!case_insensitive(s, cast(wchar)c);
        return findFirst!case_insensitive(s, c);
    }

    size_t offset = 0;
    while (offset < s.length)
    {

        static if (case_insensitive)
            int c = uni_compare_i(s[offset .. $], t);
        else
            int c = uni_compare(s[offset .. $], t);
        if (c == int.max || c == 0)
            return offset;
        if (c == int.min)
            return s.length;
        offset += s[offset .. $].uni_seq_len();
    }
    return s.length;
}

size_t find_first_i(T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
    => findFirst!true(s, t);

size_t findLast(bool case_insensitive = false, T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
{
    // this is tricky, because we need to seek backwards to the start of surrogate sequences
    assert(false, "TODO");
}

size_t find_last_i(T, U)(const(T)[] s, const(U)[] t)
    if (is_some_char!T && is_some_char!U)
    => findLast!true(s, t);

bool contains(bool case_insensitive = false, T, U)(const(T)[] s, U c, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
{
    size_t i = findFirst!case_insensitive(s, c);
    if (i == s.length)
        return false;
    if (offset)
        *offset = i;
    return true;
}

bool contains(bool case_insensitive = false, T, U)(const(T)[] s, const(U)[] t, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
{
    size_t i = findFirst!case_insensitive(s, t);
    if (i == s.length)
        return false;
    if (offset)
        *offset = i;
    return true;
}

bool contains_i(T, U)(const(T)[] s, U c, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
    => contains!true(s, c, offset);

bool contains_i(T, U)(const(T)[] s, const(U)[] t, size_t *offset = null)
    if (is_some_char!T && is_some_char!U)
    => contains!true(s, t, offset);

bool startsWith(const(char)[] s, const(char)[] prefix) pure
{
    if (s.length < prefix.length)
        return false;
    return cmp(s[0 .. prefix.length], prefix) == 0;
}

bool endsWith(const(char)[] s, const(char)[] suffix) pure
{
    if (s.length < suffix.length)
        return false;
    return cmp(s[$ - suffix.length .. $], suffix) == 0;
}

inout(char)[] trim(bool Front = true, bool Back = true)(inout(char)[] s) pure
{
    size_t first = 0, last = s.length;
    static if (Front)
    {
        while (first < s.length && is_whitespace(s.ptr[first]))
            ++first;
    }
    static if (Back)
    {
        while (last > first && is_whitespace(s.ptr[last - 1]))
            --last;
    }
    return s.ptr[first .. last];
}

alias trimFront = trim!(true, false);

alias trimBack = trim!(false, true);

inout(char)[] trimComment(char Delimiter)(inout(char)[] s) pure
{
    size_t i = 0;
    for (; i < s.length; ++i)
    {
        if (s[i] == Delimiter)
            break;
    }
    while(i > 0 && (s[i-1] == ' ' || s[i-1] == '\t'))
        --i;
    return s[0 .. i];
}

inout(char)[] takeLine(ref inout(char)[] s) pure
{
    for (size_t i = 0; i < s.length; ++i)
    {
        if (s[i] == '\n')
        {
            inout(char)[] t = s[0 .. i];
            s = s[i + 1 .. $];
            return t;
        }
        else if (s.length > i+1 && s[i] == '\r' && s[i+1] == '\n')
        {
            inout(char)[] t = s[0 .. i];
            s = s[i + 2 .. $];
            return t;
        }
    }
    inout(char)[] t = s;
    s = s[$ .. $];
    return t;
}

inout(char)[] split(char Separator, bool HandleQuotes = true)(ref inout(char)[] s) pure
{
    static if (HandleQuotes)
        int inQuotes = 0;
    else
        enum inQuotes = false;

    size_t i = 0;
    for (; i < s.length; ++i)
    {
        if (s[i] == Separator && !inQuotes)
            break;

        static if (HandleQuotes)
        {
            if (s[i] == '"' && !(inQuotes & 0x6))
                inQuotes = 1 - inQuotes;
            else if (s[i] == '\'' && !(inQuotes & 0x5))
                inQuotes = 2 - inQuotes;
            else if (s[i] == '`' && !(inQuotes & 0x3))
                inQuotes = 4 - inQuotes;
        }
    }
    inout(char)[] t = s[0 .. i].trimBack;
    s = i < s.length ? s[i+1 .. $].trimFront : null;
    return t;
}

inout(char)[] split(Separator...)(ref inout(char)[] s, out char sep) pure
{
    sep = '\0';
    int inQuotes = 0;
    size_t i = 0;
    loop: for (; i < s.length; ++i)
    {
        static foreach (S; Separator)
        {
            static assert(is(typeof(S) == char), "Only single character separators supported");
            if (s[i] == S && !inQuotes)
            {
                sep = s[i];
                break loop;
            }
        }
        if (s[i] == '"' && !(inQuotes & 0x6))
            inQuotes = 1 - inQuotes;
        else if (s[i] == '\'' && !(inQuotes & 0x5))
            inQuotes = 2 - inQuotes;
        else if (s[i] == '`' && !(inQuotes & 0x3))
            inQuotes = 4 - inQuotes;
    }
    inout(char)[] t = s[0 .. i].trimBack;
    s = i < s.length ? s[i+1 .. $].trimFront : null;
    return t;
}

char[] unQuote(const(char)[] s, char[] buffer) pure
{
    // TODO: should this scan and match quotes rather than assuming there are no rogue closing quotes in the middle of the string?
    if (s.empty)
        return null;
    if (s[0] == '"' && s[$-1] == '"' || s[0] == '\'' && s[$-1] == '\'')
    {
        if (s is buffer)
            return buffer[1 .. $-1].unEscape;
        return s[1 .. $-1].unEscape(buffer);
    }
    bool quote = s[0] == '`' && s[$-1] == '`';
    if (s is buffer)
        return quote ? buffer[1 .. $-1] : buffer;
    s = quote ? s[1 .. $-1] : s;
    buffer[0 .. s.length] = s[];
    return buffer;
}

char[] unQuote(char[] s) pure
{
    return unQuote(s, s);
}

char[] unQuote(const(char)[] s)
{
    import urt.mem.temp : talloc;
    return unQuote(s, cast(char[])talloc(s.length));
}

char[] unEscape(inout(char)[] s, char[] buffer) pure
{
    if (s.empty)
        return null;

    bool same = s is buffer;

    size_t len = 0;
    for (size_t i = 0; i < s.length; ++i)
    {
        if (s[i] == '\\')
        {
            if (s.length > ++i)
            {
                switch (s[i])
                {
                    case '0':   buffer[len++] = '\0';   break;
                    case 'n':   buffer[len++] = '\n';   break;
                    case 'r':   buffer[len++] = '\r';   break;
                    case 't':   buffer[len++] = '\t';   break;
//                    case '\\':  buffer[len++] = '\\';   break;
//                    case '\'':  buffer[len++] = '\'';   break;
                    default:    buffer[len++] = s[i];
                }
            }
        }
        else if (!same || len < i)
            buffer[len++] = s[i];
    }
    return buffer[0..len];
}

char[] unEscape(char[] s) pure
{
    return unEscape(s, s);
}


char[] toHexString(const(void[]) data, char[] buffer, uint group = 0, uint secondaryGroup = 0, const(char)[] seps = " -") pure
{
    import urt.util : is_power_of_2;
    assert(group.is_power_of_2);
    assert(secondaryGroup.is_power_of_2);
    assert((secondaryGroup == 0 && seps.length > 0) || seps.length > 1, "Secondary grouping requires additional separator");

    if (data.length == 0)
        return buffer[0..0];

    size_t len = data.length*2;
    if (group)
        len += (data.length-1) / group;
    if (len > buffer.length)
        return null;

    auto src = cast(const(ubyte)[])data;

    size_t mask = group - 1;
    size_t secondMask = secondaryGroup - 1;

    size_t offset = 0;
    for (size_t i = 0; true; )
    {
        buffer[offset++] = hex_digits[src[i] >> 4];
        buffer[offset++] = hex_digits[src[i] & 0xF];

        bool sep = (i & mask) == mask;
        if (++i == data.length)
            return buffer[0 .. offset];
        if (sep)
            buffer[offset++] = ((i & secondMask) == 0 ? seps[1] : seps[0]);
    }
}

char[] toHexString(const(ubyte[]) data, uint group = 0, uint secondaryGroup = 0, const(char)[] seps = " -")
{
    import urt.mem.temp;

    size_t len = data.length*2;
    if (group && len > 0)
        len += (data.length-1) / group;
    return data.toHexString(cast(char[])talloc(len), group, secondaryGroup, seps);
}

unittest
{
    ubyte[8] data = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF];
    assert(data.toHexString(0) == "0123456789ABCDEF");
    assert(data.toHexString(1) == "01 23 45 67 89 AB CD EF");
    assert(data.toHexString(2) == "0123 4567 89AB CDEF");
    assert(data.toHexString(4) == "01234567 89ABCDEF");
    assert(data.toHexString(8) == "0123456789ABCDEF");
    assert(data.toHexString(2, 4, "_ ") == "0123_4567 89AB_CDEF");
}


bool wildcard_match(const(char)[] wildcard, const(char)[] value, bool value_wildcard = false) pure
{
    const(char)* a = wildcard.ptr, ae = a + wildcard.length, b = value.ptr, be = b + value.length;
    const(char)* star_a = null, star_b = null;

    while (a < ae && b < be)
    {
        char ca_orig = *a, cb_orig = *b;
        char ca = ca_orig, cb = cb_orig;

        // handle escape
        if (ca == '\\' && a + 1 < ae)
            ca = *++a;
        if (value_wildcard && cb == '\\' && b + 1 < be)
            cb = *++b;

        // handle wildcards
        if (ca_orig == '*')
        {
            star_a = ++a;
            star_b = b;
            continue;
        }
        if (value_wildcard && cb_orig == '*')
        {
            star_b = ++b;
            star_a = a;
            continue;
        }

        // compare next char
        if (ca_orig == '?' || (value_wildcard && cb_orig == '?') || ca == cb)
        {
            ++a;
            ++b;
            continue;
        }

        // backtrack: expand previous * match
        if (!star_a)
            return false;
        a = star_a;
        b = ++star_b;
    }

    // skip past tail wildcards
    while (a < ae && *a == '*')
        ++a;
    if (value_wildcard)
    {
        while (b < be && *b == '*')
            ++b;
    }

    // check for match
    if (a == ae && (b == be || star_a !is null))
        return true;
    if (value_wildcard && b == be && star_b !is null)
        return true;
    return false;
}


unittest
{
    // test findFirst
    assert("hello".findFirst('e') == 1);
    assert("hello".findFirst('a') == 5);
    assert("hello".findFirst("e") == 1);
    assert("hello".findFirst("ll") == 2);
    assert("hello".findFirst("lo") == 3);
    assert("hello".findFirst("la") == 5);
    assert("hello".findFirst("low") == 5);
    assert("héllo".findFirst('é') == 1);
    assert("héllo"w.findFirst('é') == 1);
    assert("héllo".findFirst("éll") == 1);
    assert("héllo".findFirst('a') == 6);
    assert("héllo".findFirst("la") == 6);
    assert("hello".find_first_i('E') == 1);
    assert("HELLO".find_first_i("e") == 1);
    assert("hello".find_first_i("LL") == 2);
    assert("héllo".find_first_i('É') == 1);
    assert("HÉLLO".find_first_i("é") == 1);
    assert("HÉLLO".find_first_i("éll") == 1);

    assert("HÉLLO".contains('É'));
    assert(!"HÉLLO".contains('A'));
    assert("HÉLLO".contains_i("éll"));

    // test wildcard_match
    assert(wildcard_match("hello", "hello"));
    assert(!wildcard_match("hello", "world"));
    assert(wildcard_match("h*o", "hello"));
    assert(wildcard_match("h*", "hello"));
    assert(wildcard_match("*o", "hello"));
    assert(wildcard_match("*", "hello"));
    assert(wildcard_match("h?llo", "hello"));
    assert(!wildcard_match("h?llo", "hllo"));
    assert(wildcard_match("h??lo", "hello"));
    assert(!wildcard_match("a*b", "axxxc"));

    // multiple wildcards
    assert(wildcard_match("*l*o", "hello"));
    assert(wildcard_match("h*l*o", "hello"));
    assert(wildcard_match("h*l*", "hello"));
    assert(wildcard_match("*e*l*", "hello"));
    assert(wildcard_match("*h*e*l*l*o*", "hello"));

    // wildcards with sequences in between
    assert(wildcard_match("h*ll*", "hello"));
    assert(wildcard_match("*el*", "hello"));
    assert(wildcard_match("h*el*o", "hello"));
    assert(!wildcard_match("h*el*x", "hello"));
    assert(wildcard_match("*lo", "hello"));
    assert(!wildcard_match("*lx", "hello"));

    // mixed wildcards and single matches
    assert(wildcard_match("h?*o", "hello"));
    assert(wildcard_match("h*?o", "hello"));
    assert(wildcard_match("?e*o", "hello"));
    assert(wildcard_match("h?ll?", "hello"));
    assert(!wildcard_match("h?ll?", "hllo"));

    // overlapping wildcards
    assert(wildcard_match("**hello", "hello"));
    assert(wildcard_match("hello**", "hello"));
    assert(wildcard_match("h**o", "hello"));
    assert(wildcard_match("*?*", "hello"));
    assert(wildcard_match("?*?", "hello"));
    assert(!wildcard_match("?*?", "x"));
    assert(wildcard_match("?*?", "xx"));

    // escape sequences
    assert(wildcard_match("\\*", "*"));
    assert(wildcard_match("\\?", "?"));
    assert(wildcard_match("\\\\", "\\"));
    assert(!wildcard_match("\\*", "a"));
    assert(wildcard_match("h\\*o", "h*o"));
    assert(!wildcard_match("h\\*o", "hello"));
    assert(wildcard_match("\\*\\?\\\\", "*?\\"));
    assert(wildcard_match("a\\*b*c", "a*bxyzc"));
    assert(wildcard_match("*\\**", "hello*world"));

    // edge cases
    assert(wildcard_match("", ""));
    assert(!wildcard_match("", "a"));
    assert(wildcard_match("*", ""));
    assert(wildcard_match("**", ""));
    assert(!wildcard_match("?", ""));
    assert(wildcard_match("a*b*c", "abc"));
    assert(wildcard_match("a*b*c", "aXbYc"));
    assert(wildcard_match("a*b*c", "aXXbYYc"));

    // value_wildcard tests - bidirectional matching
    assert(wildcard_match("hello", "h*o", true));
    assert(wildcard_match("h*o", "hello", true));
    assert(wildcard_match("h?llo", "he?lo", true));
    assert(wildcard_match("h\\*o", "h\\*o", true));
    assert(wildcard_match("test*", "*test", true));

    // both sides have wildcards
    assert(wildcard_match("h*o", "h*o", true));
    assert(wildcard_match("*hello*", "*world*", true));
    assert(wildcard_match("a*b*c", "a*b*c", true));
    assert(wildcard_match("*", "*", true));
    assert(wildcard_match("?", "?", true));

    // complex interplay - wildcards matching wildcards
    assert(wildcard_match("a*c", "a?c", true));
    assert(wildcard_match("a?c", "a*c", true));
    assert(wildcard_match("*abc", "?abc", true));
    assert(wildcard_match("abc*", "abc?", true));

    // multiple wildcards on both sides
    assert(wildcard_match("a*b*c", "a?b?c", true));
    assert(wildcard_match("*a*b*", "?a?b?", true));
    assert(wildcard_match("a**b", "a*b", true));
    assert(wildcard_match("a*b", "a**b", true));

    // wildcards at different positions
    assert(wildcard_match("*test", "test*", true));
    assert(wildcard_match("test*end", "*end", true));
    assert(wildcard_match("*middle*", "start*", true));

    // edge cases with value_wildcard
    assert(wildcard_match("", "", true));
    assert(wildcard_match("*", "", true));
    assert(wildcard_match("", "*", true));
    assert(wildcard_match("**", "*", true));
    assert(wildcard_match("*", "**", true));
}
