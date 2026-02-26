module urt.string.uni;

import urt.string.ascii : to_lower, to_upper;
import urt.traits : is_some_char;

pure nothrow @nogc:


size_t uni_seq_len(const(char)[] str)
{
    debug assert(str.length > 0);

    const(char)* s = str.ptr;
    if (s[0] < 0x80) // 1-byte sequence: 0xxxxxxx
        return 1;
    else if ((s[0] & 0xE0) == 0xC0) // 2-byte sequence: 110xxxxx 10xxxxxx
        return (str.length >= 2 && (s[1] & 0xC0) == 0x80) ? 2 : 1;
    else if ((s[0] & 0xF0) == 0xE0) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        return (str.length >= 3 && (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80) ? 3 :
               (str.length >= 2 && (s[1] & 0xC0) == 0x80) ? 2 : 1;
    else if ((s[0] & 0xF8) == 0xF0) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        return (str.length >= 4 && (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80 && (s[3] & 0xC0) == 0x80) ? 4 :
               (str.length >= 3 && (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80) ? 3 :
               (str.length >= 2 && (s[1] & 0xC0) == 0x80) ? 2 : 1;
    return 1; // Invalid UTF-8 sequence
}

size_t uni_seq_len(const(wchar)[] str)
{
    debug assert(str.length > 0);

    const(wchar)* s = str.ptr;
    if (s[0] >= 0xD800 && s[0] < 0xDC00 && str.length >= 2 && s[1] >= 0xDC00 && s[1] < 0xE000)
        return 2; // Surrogate pair: 110110xxxxxxxxxx 110111xxxxxxxxxx
    return 1;
}

pragma(inline, true)
size_t uni_seq_len(const(dchar)[] s)
    => 1;

size_t uni_strlen(C)(const(C)[] s)
    if (is_some_char!C)
{
    static if (is(C == dchar))
    {
        pragma(inline, true);
        return s.length;
    }
    else
    {
        size_t count = 0;
        while (s.length)
        {
            size_t l = s.uni_seq_len;
            s = s[l .. $];
            ++count;
        }
        return count;
    }
}

dchar next_dchar(const(char)[] s, out size_t seq_len)
{
    assert(s.length > 0);

    const(char)* p = s.ptr;
    if ((*p & 0x80) == 0) // 1-byte sequence: 0xxxxxxx
    {
        seq_len = 1;
        return *p;
    }
    else if ((*p & 0xE0) == 0xC0) // 2-byte sequence: 110xxxxx 10xxxxxx
    {
        if (s.length >= 2 && (p[1] & 0xC0) == 0x80)
        {
            seq_len = 2;
            return ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
        }
    }
    else if ((*p & 0xF0) == 0xE0) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
    {
        if (s.length >= 3 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80)
        {
            seq_len = 3;
            return ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
        }
        // check for seq_len == 2 error cases
        if (s.length >= 2 && (p[1] & 0xC0) == 0x80)
        {
            seq_len = 2;
            return 0xFFFD;
        }
    }
    else if ((*p & 0xF8) == 0xF0) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    {
        if (s.length >= 4 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 && (p[3] & 0xC0) == 0x80)
        {
            seq_len = 4;
            return ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F);
        }
        // check for seq_len == 2..3 error cases
        if (s.length >= 2 && (p[1] & 0xC0) == 0x80)
        {
            if (s.length == 2 || (p[2] & 0xC0) != 0x80)
                seq_len = 2;
            else
                seq_len = 3;
            return 0xFFFD;
        }
    }
    seq_len = 1;
    return 0xFFFD; // Invalid UTF-8 sequence
}

dchar next_dchar(const(wchar)[] s, out size_t seq_len)
{
    assert(s.length > 0);

    const(wchar)* p = s.ptr;
    if (p[0] < 0xD800 || p[0] >= 0xE000)
    {
        seq_len = 1;
        return p[0];
    }
    if (p[0] < 0xDC00 && s.length >= 2 && p[1] >= 0xDC00 && p[1] < 0xE000) // Surrogate pair: 110110xxxxxxxxxx 110111xxxxxxxxxx
    {
        seq_len = 2;
        return 0x10000 + ((p[0] - 0xD800) << 10) + (p[1] - 0xDC00);
    }
    seq_len = 1;
    return 0xFFFD; // Invalid UTF-16 sequence
}

pragma(inline, true)
dchar next_dchar(const(dchar)[] s, out size_t seq_len)
{
    assert(s.length > 0);
    seq_len = 1;
    return s[0];
}

size_t uni_convert(const(char)[] s, wchar[] buffer)
{
    const(char)* p = s.ptr;
    const(char)* pend = p + s.length;
    wchar* b = buffer.ptr;
    wchar* bend = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bend)
            return 0; // End of output buffer
        if ((*p & 0x80) == 0) // 1-byte sequence: 0xxxxxxx
            *b++ = *p++;
        else if ((*p & 0xE0) == 0xC0) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (p + 1 >= pend)
                return 0; // Unexpected end of input
            *b++ = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
            p += 2;
        }
        else if ((*p & 0xF0) == 0xE0) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
            if (p + 2 >= pend)
                return 0; // Unexpected end of input
            *b++ = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
            p += 3;
        }
        else if ((*p & 0xF8) == 0xF0) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        {
            if (p + 3 >= pend || b + 1 >= bend)
                return 0; // Unexpected end of input/output
            dchar codepoint = ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F);
            codepoint -= 0x10000;
            b[0] = 0xD800 | (codepoint >> 10);
            b[1] = 0xDC00 | (codepoint & 0x3FF);
            p += 4;
            b += 2;
        }
        else
            return 0; // Invalid UTF-8 sequence
    }
    return b - buffer.ptr;
}

size_t uni_convert(const(char)[] s, dchar[] buffer)
{
    const(char)* p = s.ptr;
    const(char)* pend = p + s.length;
    dchar* b = buffer.ptr;
    dchar* bend = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bend)
            return 0;
        if ((*p & 0x80) == 0) // 1-byte sequence: 0xxxxxxx
            *b++ = *p++;
        else if ((*p & 0xE0) == 0xC0) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (p + 1 >= pend)
                return 0; // Unexpected end of input.
            *b++ = ((*p++ & 0x1F) << 6) | (*p++ & 0x3F);
        }
        else if ((*p & 0xF0) == 0xE0) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
            if (p + 2 >= pend)
                return 0; // Unexpected end of input.
            *b++ = ((*p++ & 0x0F) << 12) | ((*p++ & 0x3F) << 6) | (*p++ & 0x3F);
        }
        else if ((*p & 0xF8) == 0xF0) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        {
            if (p + 3 >= pend)
                return 0; // Unexpected end of input.
            *b++ = ((*p++ & 0x07) << 18) | ((*p++ & 0x3F) << 12) | ((*p++ & 0x3F) << 6) | (*p++ & 0x3F);
        }
        else
            return 0; // Invalid UTF-8 sequence.
    }
    return b - buffer.ptr;
}

size_t uni_convert(const(wchar)[] s, char[] buffer)
{
    const(wchar)* p = s.ptr;
    const(wchar)* pend = p + s.length;
    char* b = buffer.ptr;
    char* bend = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bend)
            return 0; // End of output buffer
        if (p[0] >= 0xD800)
        {
            if (p[0] >= 0xE000)
                goto three_byte_seq;
            if (p + 1 >= pend)
                return 0; // Unexpected end of input
            if (p[0] < 0xDC00) // Surrogate pair: 110110xxxxxxxxxx 110111xxxxxxxxxx
            {
                if (b + 3 >= bend)
                    return 0; // End of output buffer
                dchar codepoint = 0x10000 + ((p[0] - 0xD800) << 10) + (p[1] - 0xDC00);
                b[0] = 0xF0 | (codepoint >> 18);
                b[1] = 0x80 | ((codepoint >> 12) & 0x3F);
                b[2] = 0x80 | ((codepoint >> 6) & 0x3F);
                b[3] = 0x80 | (codepoint & 0x3F);
                p += 2;
                b += 4;
                continue;
            }
            return 0; // Invalid UTF-16 sequence
        }
        if (*p < 0x80) // 1-byte sequence: 0xxxxxxx
            *b++ = cast(char)*p++;
        else if (*p < 0x800) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (b + 1 >= bend)
                return 0; // End of output buffer
            b[0] = 0xC0 | cast(char)(*p >> 6);
            b[1] = 0x80 | (*p++ & 0x3F);
            b += 2;
        }
        else // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
        three_byte_seq:
            if (b + 2 >= bend)
                return 0; // End of output buffer
            b[0] = 0xE0 | (*p >> 12);
            b[1] = 0x80 | ((*p >> 6) & 0x3F);
            b[2] = 0x80 | (*p++ & 0x3F);
            b += 3;
        }
    }
    return b - buffer.ptr;
}

size_t uni_convert(const(wchar)[] s, dchar[] buffer)
{
    const(wchar)* p = s.ptr;
    const(wchar)* pend = p + s.length;
    dchar* b = buffer.ptr;
    dchar* bend = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bend)
            return 0; // End of output buffer
        if ((p[0] >> 11) == 0x1B)
        {
            if (p + 1 >= pend)
                return 0; // Unexpected end of input
            if (p[0] < 0xDC00 && (p[1] >> 10) == 0x37) // Surrogate pair: 110110xxxxxxxxxx 110111xxxxxxxxxx
            {
                *b++ = 0x10000 + ((p[0] & 0x3FF) << 10 | (p[1] & 0x3FF));
                p += 2;
                continue;
            }
            return 0; // Invalid UTF-16 sequence
        }
        *b++ = *p++;
    }
    return b - buffer.ptr;
}

size_t uni_convert(const(dchar)[] s, char[] buffer)
{
    const(dchar)* p = s.ptr;
    const(dchar)* pend = p + s.length;
    char* b = buffer.ptr;
    char* bend = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bend)
            return 0; // End of output buffer
        if (*p < 0x80) // 1-byte sequence: 0xxxxxxx
            *b++ = cast(char)*p++;
        else if (*p < 0x800) // 2-byte sequence: 110xxxxx 10xxxxxx
        {
            if (b + 1 >= bend)
                return 0; // End of output buffer
            b[0] = 0xC0 | cast(char)(*p >> 6);
            b[1] = 0x80 | (*p++ & 0x3F);
            b += 2;
        }
        else if (*p < 0x10000) // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
        {
            if (b + 2 >= bend)
                return 0; // End of output buffer
            b[0] = 0xE0 | cast(char)(*p >> 12);
            b[1] = 0x80 | ((*p >> 6) & 0x3F);
            b[2] = 0x80 | (*p++ & 0x3F);
            b += 3;
        }
        else if (*p < 0x110000) // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        {
            if (b + 3 >= bend)
                return 0; // End of output buffer
            b[0] = 0xF0 | (*p >> 18);
            b[1] = 0x80 | ((*p >> 12) & 0x3F);
            b[2] = 0x80 | ((*p >> 6) & 0x3F);
            b[3] = 0x80 | (*p++ & 0x3F);
            b += 4;
        }
        else
            return 0; // Invalid UTF codepoint
    }
    return b - buffer.ptr;
}

size_t uni_convert(const(dchar)[] s, wchar[] buffer)
{
    const(dchar)* p = s.ptr;
    const(dchar)* pend = p + s.length;
    wchar* b = buffer.ptr;
    wchar* bend = buffer.ptr + buffer.length;

    while (p < pend)
    {
        if (b >= bend)
            return 0; // End of output buffer
        if (*p < 0x10000)
            *b++ = cast(wchar)*p++;
        else if (*p < 0x110000)
        {
            if (b + 1 >= bend)
                return 0; // End of output buffer
            dchar codepoint = *p++ - 0x10000;
            b[0] = 0xD800 | (codepoint >> 10);
            b[1] = 0xDC00 | (codepoint & 0x3FF);
            b += 2;
        }
        else
            return 0; // Invalid codepoint
    }
    return b - buffer.ptr;
}

char uni_to_lower(char c)
    => c.to_lower();

dchar uni_to_lower(dchar c)
{
    if (uint(c - 'A') < 26)
        return c | 0x20;

    // TODO: this is a deep rabbit-hole! (and the approach might not be perfect)

    if (c < 0xFF)
    {
        if (c >= 0xC0) // Latin-1 Supplement
            return g_to_lower_latin_1.ptr[c - 0xC0];
    }
    else if (c <= 0x556)
    {
        if (c >= 0x370)
        {
            if (c < 0x400) // Greek and Coptic
                return 0x300 | g_to_lower_greek.ptr[c - 0x370];
            else if (c < 0x460) // Cyrillic
            {
                if (c < 0x410)
                    return c + 0x50;
                else if (c < 0x430)
                    return c + 0x20;
            }
            else if (c < 0x530) // Cyrillic Supplement
            {
                if (c >= 0x482 && c < 0x48A) // exceptions
                    return c;
                return c | 1;
            }
            else if (c >= 0x531) // Armenian
                return c + 0x30;
        }
        else if (c < 0x180) // Latin Extended-A
            return (0x100 | g_to_lower_latin_extended_a.ptr[c - 0xFF]) - 1;
    }
    else if (c <= 0x1CB0) // Georgian
    {
        if (c >= 0x1C90)
            return c - 0x0BC0; // Mtavruli -> Mkhedruli
        else if (c >= 0x10A0 && c <= 0x10C5)
            return c + 0x1C60; // Asomtavruli -> Nuskhuri
    }
    else if (c >= 0x1E00)
    {
        if (c < 0x1F00) // Latin Extended Additional
        {
            if (c >= 0x1E96 && c < 0x1EA0) // exceptions
            {
                if (c == 0x1E9E) // 'ẞ' -> 'ß'
                    return 0xDF;
                return c;
            }
            return c | 1;
        }
        else if (c <= 0x1FFC) // Greek Extended
        {
            if (c < 0x1F70)
                return c & ~0x8;
            return 0x1F00 | g_to_lower_greek_extended.ptr[c - 0x1F70];
        }
        else if (c < 0x2CE4)
        {
            if (c >= 0x2C80) // Coptic
                return c | 1;
        }
    }
    return c;
}

char uni_to_upper(char c)
    => c.to_upper();

dchar uni_to_upper(dchar c)
{
    if (uint(c - 'a') < 26)
        return c ^ 0x20;

    // TODO: this is a deep rabbit-hole! (and the approach might not be perfect)

    if (c < 0xFF)
    {
        if (c == 0xDF) // 'ß' -> 'ẞ'
            return 0x1E9E;
        if (c >= 0xC0) // Latin-1 Supplement
            return g_to_upper_latin_1.ptr[c - 0xC0];
    }
    else if (c <= 0x586)
    {
        if (c >= 0x370)
        {
            if (c < 0x400) // Greek and Coptic
                return 0x300 | g_to_upper_greek.ptr[c - 0x370];
            else if (c < 0x460) // Cyrillic
            {
                if (c >= 0x450)
                    return c - 0x50;
                else if (c >= 0x430)
                    return c - 0x20;
            }
            else if (c < 0x530) // Cyrillic Supplement
            {
                if (c >= 0x482 && c < 0x48A) // exceptions
                    return c;
                return c & ~1;
            }
            else if (c >= 0x561) // Armenian
                return c - 0x30;
        }
        else if (c < 0x180) // Latin Extended-A
            return 0x100 | g_to_upper_latin_extended_a.ptr[c - 0xFF];
    }
    else if (c <= 0x10F0) // Georgian
    {
        if (c >= 0x10D0)
            return c + 0x0BC0; // Mkhedruli -> Mtavruli
    }
    else if (c >= 0x1E00)
    {
        if (c < 0x1F00) // Latin Extended Additional
        {
            if (c >= 0x1E96 && c < 0x1EA0) // exceptions
                return c;
            return c & ~1;
        }
        else if (c <= 0x1FFC) // Greek Extended
        {
            if (c < 0x1F70)
                return c | 0x8;
            return 0x1F00 | g_to_upper_greek_extended.ptr[c - 0x1F70];
        }
        else if (c < 0x2CE4)
        {
            if (c >= 0x2C80) // Coptic
                return c & ~1;
        }
        else if (c <= 0x2D25) // Georgian
        {
            if(c >= 0x2D00)
                return c - 0x1C60; // Nuskhuri -> Asomtavruli
        }
    }
    return c;
}

char uni_case_fold(char c)
    => c.to_lower();

dchar uni_case_fold(dchar c)
{
    // case-folding is stronger than to_lower, there may be many misc cases...
    if (c >= 0x3C2) // Greek has bonus case-folding...
    {
        if (c < 0x3FA)
            return 0x300 | g_case_fold_greek.ptr[c - 0x3C2];
    }
    else if (c == 'ſ') // TODO: pointless? it's in the spec...
        return 's';
    return uni_to_lower(c);
}

int uni_compare(T, U)(const(T)[] s1, const(U)[] s2)
    if (is_some_char!T && is_some_char!U)
{
    const(T)* p1 = s1.ptr;
    const(T)* p1end = p1 + s1.length;
    const(U)* p2 = s2.ptr;
    const(U)* p2end = p2 + s2.length;

    // TODO: this is crude and insufficient; doesn't handle compound diacritics, etc (needs a NFKC normalisation step)

    while (true)
    {
        // return int.min/max in the case that the strings are a sub-string of the other so the caller can detect this case
        if (p1 >= p1end)
            return p2 < p2end ? int.min : 0;
        if (p2 >= p2end)
            return int.max;

        dchar a = *p1, b = *p2;

        if (a < 0x80)
        {
            if (a != b)
                return int(a) - int(b);
            ++p1;
            p2 += b < 0x80 ? 1 : p2[0 .. p2end - p2].uni_seq_len;
        }
        else if (b < 0x80)
        {
            if (a != b)
                return int(a) - int(b);
            p1 += p1[0 .. p1end - p1].uni_seq_len;
            ++p2;
        }
        else
        {
            size_t al, bl;
            a = next_dchar(p1[0 .. p1end - p1], al);
            b = next_dchar(p2[0 .. p2end - p2], bl);
            if (a != b)
                return cast(int)a - cast(int)b;
            p1 += al;
            p2 += bl;
        }
    }
}

int uni_compare_i(T, U)(const(T)[] s1, const(U)[] s2)
    if (is_some_char!T && is_some_char!U)
{
    const(T)* p1 = s1.ptr;
    const(T)* p1end = p1 + s1.length;
    const(U)* p2 = s2.ptr;
    const(U)* p2end = p2 + s2.length;

    // TODO: this is crude and insufficient; doesn't handle compound diacritics, etc (needs a NFKC normalisation step)
    //       that said, it's also overkill for embedded use!

    size_t al, bl;
    while (p1 < p1end && p2 < p2end)
    {
        dchar a = *p1;
        dchar b = void;
        if (a < 0x80)
        {
            // ascii fast-path
            a = (cast(char)a).to_lower;
            b = *p2;
            if (uint(b - 'A') < 26)
                b |= 0x20;
            if (a != b)
            {
                if (b >= 0x80)
                {
                    // `b` is not ascii; break-out to the slow path...
                    al = 1;
                    goto uni_compare_load_b;
                }
                return cast(int)a - cast(int)b;
            }
            ++p1;
            ++p2;
        }
        else
        {
            a = next_dchar(p1[0 .. p1end - p1], al).uni_case_fold;
        uni_compare_load_b:
            b = next_dchar(p2[0 .. p2end - p2], bl).uni_case_fold;
        uni_compare_a_b:
            if (a != b)
            {
                // it is _SO UNFORTUNATE_ that the ONLY special-case letter in all of unicode is german 'ß' (0xDF)!!
                if (b == 0xDF)
                {
                    if (a != 's')
                        return cast(int)a - cast(int)'s';
                    if (++p1 == p1end)
                        return -1; // only one 's', so the a-side is a shorter string
                    a = next_dchar(p1[0 .. p1end - p1], al).uni_case_fold;
                    b = 's';
                    p2 += bl - 1;
                    bl = 1;
                    goto uni_compare_a_b;
                }
                else if (a == 0xDF)
                {
                    if (b != 's')
                        return cast(int)'s' - cast(int)b;
                    if (++p2 == p2end)
                        return 1; // only one 's', so the b-side is a shorter string
                    a = 's';
                    p1 += al - 1;
                    al = 1;
                    goto uni_compare_load_b;
                }
                return cast(int)a - cast(int)b;
            }
            p1 += al;
            p2 += bl;
        }
    }

    // return int.min/max in the case that the strings are a sub-string of the other so the caller can detect this case
    return (p1 < p1end) ? int.max : (p2 < p2end) ? int.min : 0;
}


private:

// this is a helper to crush character maps into single byte arrays...
ubyte[N] map_chars(size_t N)(ubyte function(wchar) pure nothrow @nogc translate, wchar[N] map)
{
    if (__ctfe)
    {
        ubyte[N] result;
        foreach (i; 0 .. N)
            result[i] = translate(map[i]);
        return result;
    }
    else
        assert(false, "Not for runtime!");
}

// lookup tables for case conversion
__gshared immutable g_to_lower_latin_1 = map_chars(c => cast(ubyte)c, to_lower_latin[0 .. 0x3F]);
__gshared immutable g_to_upper_latin_1 = map_chars(c => cast(ubyte)c, to_upper_latin[0 .. 0x3F]);
__gshared immutable g_to_lower_latin_extended_a = map_chars(c => cast(ubyte)(c + 1), to_lower_latin[0x3F .. 0xC0]); // calculate `(0x100 | table[n]) - 1` at runtime
__gshared immutable g_to_upper_latin_extended_a = map_chars(c => cast(ubyte)c, to_upper_latin[0x3F .. 0xC0]); // calculate `0x100 | table[n]` at runtime
__gshared immutable g_to_lower_greek = map_chars(c => cast(ubyte)c, to_lower_greek); // calculate `0x300 | table[n]` at runtime
__gshared immutable g_to_upper_greek = map_chars(c => cast(ubyte)c, to_upper_greek); // calculate `0x300 | table[n]` at runtime
__gshared immutable g_case_fold_greek = map_chars(c => cast(ubyte)c, case_fold_greek); // calculate `0x300 | table[n]` at runtime
__gshared immutable g_to_lower_greek_extended = map_chars(c => cast(ubyte)c, to_lower_greek_extended); // calculate `0x1F00 | table[n]` at runtime
__gshared immutable g_to_upper_greek_extended = map_chars(c => cast(ubyte)c, to_upper_greek_extended); // calculate `0x1F00 | table[n]` at runtime

// Latin-1 Supplement and Latin Extended-A
enum wchar[0x180 - 0xC0] to_lower_latin = [
    'à', 'á', 'â', 'ã', 'ä', 'å', 'æ', 'ç', 'è', 'é', 'ê', 'ë', 'ì', 'í', 'î', 'ï',
    'ð', 'ñ', 'ò', 'ó', 'ô', 'õ', 'ö', 0xD7,'ø', 'ù', 'ú', 'û', 'ü', 'ý', 'þ', 'ß',
    'à', 'á', 'â', 'ã', 'ä', 'å', 'æ', 'ç', 'è', 'é', 'ê', 'ë', 'ì', 'í', 'î', 'ï',
    'ð', 'ñ', 'ò', 'ó', 'ô', 'õ', 'ö', 0xF7,'ø', 'ù', 'ú', 'û', 'ü', 'ý', 'þ', 'ÿ',
    'ā', 'ā', 'ă', 'ă', 'ą', 'ą', 'ć', 'ć', 'ĉ', 'ĉ', 'ċ', 'ċ', 'č', 'č', 'ď', 'ď',
    'đ', 'đ', 'ē', 'ē', 'ĕ', 'ĕ', 'ė', 'ė', 'ę', 'ę', 'ě', 'ě', 'ĝ', 'ĝ', 'ğ', 'ğ',
    'ġ', 'ġ', 'ģ', 'ģ', 'ĥ', 'ĥ', 'ħ', 'ħ', 'ĩ', 'ĩ', 'ī', 'ī', 'ĭ', 'ĭ', 'į', 'į',
  0x130,0x131,'ĳ', 'ĳ', 'ĵ', 'ĵ', 'ķ', 'ķ',0x138,'ĺ', 'ĺ', 'ļ', 'ļ', 'ľ', 'ľ', 'ŀ',
    'ŀ', 'ł', 'ł', 'ń', 'ń', 'ņ', 'ņ', 'ň', 'ň',0x149,'ŋ', 'ŋ', 'ō', 'ō', 'ŏ', 'ŏ',
    'ő', 'ő', 'œ', 'œ', 'ŕ', 'ŕ', 'ŗ', 'ŗ', 'ř', 'ř', 'ś', 'ś', 'ŝ', 'ŝ', 'ş', 'ş',
    'š', 'š', 'ţ', 'ţ', 'ť', 'ť', 'ŧ', 'ŧ', 'ũ', 'ũ', 'ū', 'ū', 'ŭ', 'ŭ', 'ů', 'ů',
    'ű', 'ű', 'ų', 'ų', 'ŵ', 'ŵ', 'ŷ', 'ŷ', 'ÿ', 'ź', 'ź', 'ż', 'ż', 'ž', 'ž', 'ſ'
];

enum wchar[0x180 - 0xC0] to_upper_latin = [
    'À', 'Á', 'Â', 'Ã', 'Ä', 'Å', 'Æ', 'Ç', 'È', 'É', 'Ê', 'Ë', 'Ì', 'Í', 'Î', 'Ï',
    'Ð', 'Ñ', 'Ò', 'Ó', 'Ô', 'Õ', 'Ö', 0xD7,'Ø', 'Ù', 'Ú', 'Û', 'Ü', 'Ý', 'Þ', 'ẞ',
    'À', 'Á', 'Â', 'Ã', 'Ä', 'Å', 'Æ', 'Ç', 'È', 'É', 'Ê', 'Ë', 'Ì', 'Í', 'Î', 'Ï',
    'Ð', 'Ñ', 'Ò', 'Ó', 'Ô', 'Õ', 'Ö', 0xF7,'Ø', 'Ù', 'Ú', 'Û', 'Ü', 'Ý', 'Þ', 'Ÿ',
    'Ā', 'Ā', 'Ă', 'Ă', 'Ą', 'Ą', 'Ć', 'Ć', 'Ĉ', 'Ĉ', 'Ċ', 'Ċ', 'Č', 'Č', 'Ď', 'Ď',
    'Đ', 'Đ', 'Ē', 'Ē', 'Ĕ', 'Ĕ', 'Ė', 'Ė', 'Ę', 'Ę', 'Ě', 'Ě', 'Ĝ', 'Ĝ', 'Ğ', 'Ğ',
    'Ġ', 'Ġ', 'Ģ', 'Ģ', 'Ĥ', 'Ĥ', 'Ħ', 'Ħ', 'Ĩ', 'Ĩ', 'Ī', 'Ī', 'Ĭ', 'Ĭ', 'Į', 'Į',
  0x130,0x131,'Ĳ', 'Ĳ', 'Ĵ', 'Ĵ', 'Ķ', 'Ķ',0x138,'Ĺ', 'Ĺ', 'Ļ', 'Ļ', 'Ľ', 'Ľ', 'Ŀ',
    'Ŀ', 'Ł', 'Ł', 'Ń', 'Ń', 'Ņ', 'Ņ', 'Ň', 'Ň',0x149,'Ŋ', 'Ŋ', 'Ō', 'Ō', 'Ŏ', 'Ŏ',
    'Ő', 'Ő', 'Œ', 'Œ', 'Ŕ', 'Ŕ', 'Ŗ', 'Ŗ', 'Ř', 'Ř', 'Ś', 'Ś', 'Ŝ', 'Ŝ', 'Ş', 'Ş',
    'Š', 'Š', 'Ţ', 'Ţ', 'Ť', 'Ť', 'Ŧ', 'Ŧ', 'Ũ', 'Ũ', 'Ū', 'Ū', 'Ŭ', 'Ŭ', 'Ů', 'Ů',
    'Ű', 'Ű', 'Ų', 'Ų', 'Ŵ', 'Ŵ', 'Ŷ', 'Ŷ', 'Ÿ', 'Ź', 'Ź', 'Ż', 'Ż', 'Ž', 'Ž', 'S'
];

// Greek and Coptic
enum wchar[0x400 - 0x370] to_lower_greek = [
    'ͱ', 'ͱ', 'ͳ', 'ͳ',0x374,0x375,'ͷ','ͷ',0x378,0x379,0x37A,'ͻ','ͼ','ͽ',0x37E,'ϳ',
0x380,0x381,0x382,0x383,0x384,0x385,'ά',0x387,'έ','ή','ί',0x38B,'ό',0x38D,'ύ', 'ώ',
   0x390,'α', 'β', 'γ', 'δ', 'ε', 'ζ', 'η', 'θ', 'ι', 'κ', 'λ', 'μ', 'ν', 'ξ', 'ο',
    'π', 'ρ',0x3A2,'σ', 'τ', 'υ', 'φ', 'χ', 'ψ', 'ω', 'ϊ', 'ϋ', 'ά', 'έ', 'ή', 'ί',
   0x3B0,'α', 'β', 'γ', 'δ', 'ε', 'ζ', 'η', 'θ', 'ι', 'κ', 'λ', 'μ', 'ν', 'ξ', 'ο',
    'π', 'ρ', 'ς', 'σ', 'τ', 'υ', 'φ', 'χ', 'ψ', 'ω', 'ϊ', 'ϋ', 'ό', 'ύ', 'ώ', 'ϗ',
    'ϐ', 'ϑ', 'υ', 'ύ', 'ϋ', 'ϕ', 'ϖ', 'ϗ', 'ϙ', 'ϙ', 'ϛ', 'ϛ', 'ϝ', 'ϝ', 'ϟ', 'ϟ',
    'ϡ', 'ϡ', 'ϣ', 'ϣ', 'ϥ', 'ϥ', 'ϧ', 'ϧ', 'ϩ', 'ϩ', 'ϫ', 'ϫ', 'ϭ', 'ϭ', 'ϯ', 'ϯ',
    'ϰ', 'ϱ', 'ϲ', 'ϳ', 'θ', 'ϵ',0x3F6,'ϸ', 'ϸ', 'ϲ', 'ϻ', 'ϻ',0x3FC,'ͻ', 'ͼ', 'ͽ'
];

enum wchar[0x400 - 0x370] to_upper_greek = [
    'Ͱ', 'Ͱ', 'Ͳ', 'Ͳ',0x374,0x375,'Ͷ','Ͷ',0x378,0x379,0x37A,'Ͻ','Ͼ','Ͽ',0x37E,'Ϳ',
0x380,0x381,0x382,0x383,0x384,0x385,'Ά',0x387,'Έ','Ή','Ί',0x38B,'Ό',0x38D,'Ύ', 'Ώ',
   0x390,'Α', 'Β', 'Γ', 'Δ', 'Ε', 'Ζ', 'Η', 'Θ', 'Ι', 'Κ', 'Λ', 'Μ', 'Ν', 'Ξ', 'Ο',
    'Π', 'Ρ',0x3A2,'Σ', 'Τ', 'Υ', 'Φ', 'Χ', 'Ψ', 'Ω', 'Ϊ', 'Ϋ', 'Ά', 'Έ', 'Ή', 'Ί',
   0x3B0,'Α', 'Β', 'Γ', 'Δ', 'Ε', 'Ζ', 'Η', 'Θ', 'Ι', 'Κ', 'Λ', 'Μ', 'Ν', 'Ξ', 'Ο',
    'Π', 'Ρ', 'Σ', 'Σ', 'Τ', 'Υ', 'Φ', 'Χ', 'Ψ', 'Ω', 'Ϊ', 'Ϋ', 'Ό', 'Ύ', 'Ώ', 'Ϗ',
    'Β','Θ',0x3D2,0x3D3,0x3D4,'Φ','Π', 'Ϗ', 'Ϙ', 'Ϙ', 'Ϛ', 'Ϛ', 'Ϝ', 'Ϝ', 'Ϟ', 'Ϟ',
    'Ϡ', 'Ϡ', 'Ϣ', 'Ϣ', 'Ϥ', 'Ϥ', 'Ϧ', 'Ϧ', 'Ϩ', 'Ϩ', 'Ϫ', 'Ϫ', 'Ϭ', 'Ϭ', 'Ϯ', 'Ϯ',
    'Κ', 'Ρ', 'Ϲ', 'Ϳ', 'ϴ', 'Ε',0x3F6,'Ϸ', 'Ϸ', 'Ϲ', 'Ϻ', 'Ϻ',0x3FC,'Ͻ', 'Ͼ', 'Ͽ'
];

enum wchar[0x3FA - 0x3C2] case_fold_greek = [
              'σ', 'σ', 'τ', 'υ', 'φ', 'χ', 'ψ', 'ω', 'ϊ', 'ϋ', 'ό', 'ύ', 'ώ', 'ϗ',
    'β', 'θ', 'υ', 'ύ', 'ϋ', 'φ', 'π', 'ϗ', 'ϙ', 'ϙ', 'ϛ', 'ϛ', 'ϝ', 'ϝ', 'ϟ', 'ϟ',
    'ϡ', 'ϡ', 'ϣ', 'ϣ', 'ϥ', 'ϥ', 'ϧ', 'ϧ', 'ϩ', 'ϩ', 'ϫ', 'ϫ', 'ϭ', 'ϭ', 'ϯ', 'ϯ',
    'κ', 'ρ', 'σ', 'ϳ', 'θ', 'ε',0x3F6,'ϸ', 'ϸ', 'σ'
];

enum wchar[0x1FFD - 0x1F70] to_lower_greek_extended = [
    'ὰ', 'ά', 'ὲ',    'έ',   'ὴ',   'ή',   'ὶ',   'ί',   'ὸ', 'ό', 'ὺ', 'ύ', 'ὼ',   'ώ',  0x1F7E,0x1F7F,
    'ᾀ', 'ᾁ', 'ᾂ',    'ᾃ',   'ᾄ',   'ᾅ',   'ᾆ',   'ᾇ',   'ᾀ', 'ᾁ', 'ᾂ', 'ᾃ', 'ᾄ',   'ᾅ',   'ᾆ',   'ᾇ',
    'ᾐ', 'ᾑ', 'ᾒ',    'ᾓ',   'ᾔ',   'ᾕ',   'ᾖ',   'ᾗ',   'ᾐ', 'ᾑ', 'ᾒ', 'ᾓ', 'ᾔ',   'ᾕ',   'ᾖ',   'ᾗ',
    'ᾠ', 'ᾡ', 'ᾢ',    'ᾣ',   'ᾤ',   'ᾥ',   'ᾦ',   'ᾧ',   'ᾠ', 'ᾡ', 'ᾢ', 'ᾣ', 'ᾤ',   'ᾥ',   'ᾦ',   'ᾧ',
    'ᾰ', 'ᾱ', 'ᾲ',    'ᾳ',   'ᾴ',  0x1FB5, 'ᾶ',   'ᾷ',   'ᾰ', 'ᾱ', 'ὰ', 'ά', 'ᾳ',  0x1FBD,0x1FBE,0x1FBF,
0x1FC0,0x1FC1,'ῂ',    'ῃ',   'ῄ',  0x1FC5, 'ῆ',   'ῇ',   'ὲ', 'έ', 'ὴ', 'ή', 'ῃ',  0x1FCD,0x1FCE,0x1FCF,
    'ῐ', 'ῑ', 'ῒ',    'ΐ',  0x1FD4,0x1FD5, 'ῖ',   'ῗ',   'ῐ', 'ῑ', 'ὶ', 'ί',0x1FDC,0x1FDD,0x1FDE,0x1FDF,
    'ῠ', 'ῡ', 'ῢ',    'ΰ',   'ῤ',   'ῥ',   'ῦ',   'ῧ',   'ῠ', 'ῡ', 'ὺ', 'ύ', 'ῥ',  0x1FED,0x1FEE,0x1FEF,
0x1FF0,0x1FF1,'ῲ',    'ῳ',   'ῴ',  0x1FF5, 'ῶ',   'ῷ',   'ὸ', 'ό', 'ὼ', 'ώ', 'ῳ'
];

enum wchar[0x1FFD - 0x1F70] to_upper_greek_extended = [
    'Ὰ', 'Ά', 'Ὲ',    'Έ',   'Ὴ',   'Ή',   'Ὶ',   'Ί',   'Ὸ', 'Ό', 'Ὺ', 'Ύ', 'Ὼ',   'Ώ',  0x1F7E,0x1F7F,
    'ᾈ', 'ᾉ', 'ᾊ',    'ᾋ',   'ᾌ',   'ᾍ',   'ᾎ',   'ᾏ',   'ᾈ', 'ᾉ', 'ᾊ', 'ᾋ', 'ᾌ',   'ᾍ',   'ᾎ', 'ᾏ',
    'ᾘ', 'ᾙ', 'ᾚ',    'ᾛ',   'ᾜ',   'ᾝ',   'ᾞ',   'ᾟ',   'ᾘ', 'ᾙ', 'ᾚ', 'ᾛ', 'ᾜ',   'ᾝ',   'ᾞ', 'ᾟ',
    'ᾨ', 'ᾩ', 'ᾪ',    'ᾫ',   'ᾬ',   'ᾭ',   'ᾮ',   'ᾯ',   'ᾨ', 'ᾩ', 'ᾪ', 'ᾫ', 'ᾬ',   'ᾭ',   'ᾮ', 'ᾯ',
    'Ᾰ', 'Ᾱ', 0x1FB2, 'ᾼ',  0x1FB4,0x1FB5,0x1FB6,0x1FB7, 'Ᾰ', 'Ᾱ', 'Ὰ', 'Ά', 'ᾼ',  0x1FBD,0x1FBE,0x1FBF,
0x1FC0,0x1FC1,0x1FC2, 'ῌ',  0x1FC4,0x1FC5,0x1FC6,0x1FC7, 'Ὲ', 'Έ', 'Ὴ', 'Ή', 'ῌ',  0x1FCD,0x1FCE,0x1FCF,
    'Ῐ', 'Ῑ', 0x1FD2,0x1FD3,0x1FD4,0x1FD5,0x1FD6,0x1FD7, 'Ῐ', 'Ῑ', 'Ὶ', 'Ί',0x1FDC,0x1FDD,0x1FDE,0x1FDF,
    'Ῠ', 'Ῡ', 0x1FE2,0x1FE3,0x1FE4, 'Ῥ',  0x1FE6,0x1FE7, 'Ῠ', 'Ῡ', 'Ὺ', 'Ύ', 'Ῥ',  0x1FED,0x1FEE,0x1FEF,
0x1FF0,0x1FF1,0x1FF2, 'ῼ',  0x1FF4,0x1FF5,0x1FF6,0x1FF7, 'Ὸ', 'Ό', 'Ὼ', 'Ώ', 'ῼ'
];

// NOTE: Cyrillic is runtime calculable, no tables required!


unittest
{
    immutable ushort[5] surrogates = [ 0xD800, 0xD800, 0xDC00, 0xD800, 0x0020 ];

    // test uni_seq_len functions
    assert(uni_seq_len("Hello, World!") == 1);
    assert(uni_seq_len("ñowai!") == 2);
    assert(uni_seq_len("你好") == 3);
    assert(uni_seq_len("😊wow!") == 4);
    assert(uni_seq_len("\xFFHello") == 1);
    assert(uni_seq_len("\xC2") == 1);
    assert(uni_seq_len("\xC2Hello") == 1);
    assert(uni_seq_len("\xE2") == 1);
    assert(uni_seq_len("\xE2Hello") == 1);
    assert(uni_seq_len("\xE2\x82") == 2);
    assert(uni_seq_len("\xE2\x82Hello") == 2);
    assert(uni_seq_len("\xF0") == 1);
    assert(uni_seq_len("\xF0Hello") == 1);
    assert(uni_seq_len("\xF0\x9F") == 2);
    assert(uni_seq_len("\xF0\x9FHello") == 2);
    assert(uni_seq_len("\xF0\x9F\x98") == 3);
    assert(uni_seq_len("\xF0\x9F\x98Hello") == 3);
    assert(uni_seq_len("Hello, World!"w) == 1);
    assert(uni_seq_len("ñowai!"w) == 1);
    assert(uni_seq_len("你好"w) == 1);
    assert(uni_seq_len("😊wow!"w) == 2);
    assert(uni_seq_len(cast(wchar[])surrogates[0..1]) == 1);
    assert(uni_seq_len(cast(wchar[])surrogates[0..2]) == 1);
    assert(uni_seq_len(cast(wchar[])surrogates[2..3]) == 1);
    assert(uni_seq_len(cast(wchar[])surrogates[3..5]) == 1);
    assert(uni_seq_len("😊wow!"d) == 1);

    // test uni_strlen
    assert(uni_strlen("Hello, World!") == 13);
    assert(uni_strlen("ñowai!") == 6);
    assert(uni_strlen("你好") == 2);
    assert(uni_strlen("😊wow!") == 5);
    assert(uni_strlen("\xFFHello") == 6);
    assert(uni_strlen("\xC2") == 1);
    assert(uni_strlen("\xC2Hello") == 6);
    assert(uni_strlen("\xE2") == 1);
    assert(uni_strlen("\xE2Hello") == 6);
    assert(uni_strlen("\xE2\x82") == 1);
    assert(uni_strlen("\xE2\x82Hello") == 6);
    assert(uni_strlen("\xF0") == 1);
    assert(uni_strlen("\xF0Hello") == 6);
    assert(uni_strlen("\xF0\x9F") == 1);
    assert(uni_strlen("\xF0\x9FHello") == 6);
    assert(uni_strlen("\xF0\x9F\x98") == 1);
    assert(uni_strlen("\xF0\x9F\x98Hello") == 6);
    assert(uni_strlen("Hello, World!"w) == 13);
    assert(uni_strlen("ñowai!"w) == 6);
    assert(uni_strlen("你好"w) == 2);
    assert(uni_strlen("😊wow!"w) == 5);
    assert(uni_strlen(cast(wchar[])surrogates[0..1]) == 1);
    assert(uni_strlen(cast(wchar[])surrogates[0..2]) == 2);
    assert(uni_strlen(cast(wchar[])surrogates[2..3]) == 1);
    assert(uni_strlen(cast(wchar[])surrogates[3..5]) == 2);
    assert(uni_strlen("😊wow!"d) == 5);

    // test next_dchar functions
    size_t sl;
    assert(next_dchar("Hello, World!", sl) == 'H' && sl == 1);
    assert(next_dchar("ñowai!", sl) == 'ñ' && sl == 2);
    assert(next_dchar("你好", sl) == '你' && sl == 3);
    assert(next_dchar("😊wow!", sl) == '😊' && sl == 4);
    assert(next_dchar("\xFFHello", sl) == '�' && sl == 1);
    assert(next_dchar("\xC2", sl) == '�' && sl == 1);
    assert(next_dchar("\xC2Hello", sl) == '�' && sl == 1);
    assert(next_dchar("\xE2", sl) == '�' && sl == 1);
    assert(next_dchar("\xE2Hello", sl) == '�' && sl == 1);
    assert(next_dchar("\xE2\x82", sl) == '�' && sl == 2);
    assert(next_dchar("\xE2\x82Hello", sl) == '�' && sl == 2);
    assert(next_dchar("\xF0", sl) == '�' && sl == 1);
    assert(next_dchar("\xF0Hello", sl) == '�' && sl == 1);
    assert(next_dchar("\xF0\x9F", sl) == '�' && sl == 2);
    assert(next_dchar("\xF0\x9FHello", sl) == '�' && sl == 2);
    assert(next_dchar("\xF0\x9F\x98", sl) == '�' && sl == 3);
    assert(next_dchar("\xF0\x9F\x98Hello", sl) == '�' && sl == 3);
    assert(next_dchar("Hello, World!"w, sl) == 'H' && sl == 1);
    assert(next_dchar("ñowai!"w, sl) == 'ñ' && sl == 1);
    assert(next_dchar("你好"w, sl) == '你' && sl == 1);
    assert(next_dchar("😊wow!"w, sl) == '😊' && sl == 2);
    assert(next_dchar(cast(wchar[])surrogates[0..1], sl) == '�' && sl == 1);
    assert(next_dchar(cast(wchar[])surrogates[0..2], sl) == '�' && sl == 1);
    assert(next_dchar(cast(wchar[])surrogates[2..3], sl) == '�' && sl == 1);
    assert(next_dchar(cast(wchar[])surrogates[3..5], sl) == '�' && sl == 1);
    assert(next_dchar("😊wow!"d, sl) == '😊' && sl == 1);

    immutable dstring unicode_test = 
        "Basic ASCII: Hello, World!\n" ~
        "Extended Latin: Café, résumé, naïve, jalapeño\n" ~
        "BMP Examples: 你好, مرحبا, שלום, 😊, ☂️\n" ~
        "Supplementary Planes: 𐍈, 𝒜, 🀄, 🚀\n" ~
        "Surrogate Pair Test: 😀👨‍👩‍👧‍👦\n" ~
        "Right-to-Left Text: English مرحبا עברית\n" ~
        "Combining Characters: ñ, à, 🇦🇺\n" ~
        "Whitespace: Space ␣, NBSP , ZWSP​\n" ~
        "Private Use Area: , ﷽, \n" ~
        "Edge Cases: Valid 😊, Invalid: �\n" ~
        "U+E000–U+FFFF Range:  (U+E000), 豈 (U+F900)" ~
        "Control Characters: \u0008 \u001B \u0000\n";

    char[1024] utf8_buffer;
    wchar[512] utf16_buffer;
    dchar[512] utf32_buffer;

    // test all conversions with characters in every significant value range
    size_t utf8_len = uni_convert(unicode_test, utf8_buffer);                // D-C
    size_t utf16_len = uni_convert(utf8_buffer[0..utf8_len], utf16_buffer);   // C-W
    size_t utf32_len = uni_convert(utf16_buffer[0..utf16_len], utf32_buffer); // W-D
    utf16_len = uni_convert(utf32_buffer[0..utf32_len], utf16_buffer);        // D-W
    utf8_len = uni_convert(utf16_buffer[0..utf16_len], utf8_buffer);          // W-C
    utf32_len = uni_convert(utf8_buffer[0..utf8_len], utf32_buffer);          // C-D
    assert(unicode_test[] == utf32_buffer[0..utf32_len]);

    // TODO: test all the error cases; invalid characters, buffer overflows, truncated inputs, etc...
    //...

    // test uni_to_lower and uni_to_upper
    assert(uni_to_lower('A') == 'a');
    assert(uni_to_lower('Z') == 'z');
    assert(uni_to_lower('a') == 'a');
    assert(uni_to_lower('z') == 'z');
    assert(uni_to_lower('À') == 'à');
    assert(uni_to_lower('Ý') == 'ý');
    assert(uni_to_lower('Ÿ') == 'ÿ');
    assert(uni_to_lower('ÿ') == 'ÿ');
    assert(uni_to_lower('ß') == 'ß');
    assert(uni_to_lower('ẞ') == 'ß');
    assert(uni_to_lower('Α') == 'α');
    assert(uni_to_lower('Ω') == 'ω');
    assert(uni_to_lower('α') == 'α');
    assert(uni_to_lower('ω') == 'ω');
    assert(uni_to_lower('Ḁ') == 'ḁ');
    assert(uni_to_lower('ḁ') == 'ḁ');
    assert(uni_to_lower('ẝ') == 'ẝ');
    assert(uni_to_lower('😊') == '😊');
    assert(uni_to_upper('a') == 'A');
    assert(uni_to_upper('z') == 'Z');
    assert(uni_to_upper('A') == 'A');
    assert(uni_to_upper('Z') == 'Z');
    assert(uni_to_upper('à') == 'À');
    assert(uni_to_upper('ý') == 'Ý');
    assert(uni_to_upper('ÿ') == 'Ÿ');
    assert(uni_to_upper('Ÿ') == 'Ÿ');
    assert(uni_to_upper('ß') == 'ẞ');
    assert(uni_to_upper('ẞ') == 'ẞ');
    assert(uni_to_upper('α') == 'Α');
    assert(uni_to_upper('ω') == 'Ω');
    assert(uni_to_upper('Α') == 'Α');
    assert(uni_to_upper('Ω') == 'Ω');
    assert(uni_to_upper('ḁ') == 'Ḁ');
    assert(uni_to_upper('Ḁ') == 'Ḁ');
    assert(uni_to_upper('😊') == '😊');
    assert(uni_to_upper('џ') == 'Џ');
    assert(uni_to_upper('Џ') == 'Џ');
    assert(uni_to_upper('д') == 'Д');
    assert(uni_to_upper('Д') == 'Д');
    assert(uni_to_upper('ѻ') == 'Ѻ');
    assert(uni_to_upper('Ѻ') == 'Ѻ');
    assert(uni_to_upper('ԫ') == 'Ԫ');
    assert(uni_to_upper('Ԫ') == 'Ԫ');
    assert(uni_to_upper('ա') == 'Ա');
    assert(uni_to_upper('Ա') == 'Ա');

    // test uni_compare
    assert(uni_compare("Hello", "Hello") == 0);
    assert(uni_compare("Hello", "hello") < 0);
    assert(uni_compare("hello", "Hello") > 0);
    assert(uni_compare("Hello", "Hello, World!") < 0);
    assert(uni_compare("Café", "Café") == 0);
    assert(uni_compare("Café", "CafÉ") > 0);
    assert(uni_compare("CafÉ", "Café") < 0);
    assert(uni_compare("Hello, 世界", "Hello, 世界") == 0);
    assert(uni_compare("Hello, 世界", "Hello, 世") > 0);
    assert(uni_compare("Hello, 世", "Hello, 世界") < 0);
    assert(uni_compare("Hello, 😊", "Hello, 😊") == 0);
    assert(uni_compare("Hello, 😊", "Hello, 😢") < 0);
    assert(uni_compare("😊A", "😊a") < 0);

    // test uni_compare_i
    assert(uni_compare_i("Hello", "Hello") == 0);
    assert(uni_compare_i("Hello", "hello") == 0);
    assert(uni_compare_i("hello", "Hello") == 0);
    assert(uni_compare_i("Hello", "Hello, World!") < 0);
    assert(uni_compare_i("hello", "HORLD") < 0);
    assert(uni_compare_i("Hello, 世界", "hello, 世界") == 0);
    assert(uni_compare_i("Hello, 世界", "hello, 世") > 0);
    assert(uni_compare_i("Hello, 世", "hello, 世界") < 0);
    assert(uni_compare_i("Hello, 😊", "hello, 😊") == 0);
    assert(uni_compare_i("Hello, 😊", "hello, 😢") < 0);
    assert(uni_compare_i("😊a", "😊B") < 0);
    assert(uni_compare_i("AZÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞ", "azàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþ") == 0); // basic latin + latin-1 supplement
    assert(uni_compare_i("ŸĀĦĬĲĹŁŇŊŒŠŦŶŹŽ", "ÿāħĭĳĺłňŋœšŧŷźž") == 0); // more latin extended-a characters
    assert(uni_compare_i("ḀṤẔẠỸỺỼỾ", "ḁṥẕạỹỻỽỿ") == 0); // just the extended latin

    // test various language pangrams!
    assert(uni_compare_i("The quick brown fox jumps over the lazy dog", "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG") == 0); // english
    assert(uni_compare_i("Sævör grét áðan því úlpan var ónýt", "SÆVÖR GRÉT ÁÐAN ÞVÍ ÚLPAN VAR ÓNÝT") == 0); // icelandic
    assert(uni_compare_i("Příliš žluťoučký kůň úpěl ďábelské ódy.", "PŘÍLIŠ ŽLUŤOUČKÝ KŮŇ ÚPĚL ĎÁBELSKÉ ÓDY.") == 0); // czech
    assert(uni_compare_i("Zażółć gęślą jaźń.", "ZAŻÓŁĆ GĘŚLĄ JAŹŃ.") == 0); // polish
    assert(uni_compare_i("Φλεγματικά χρώματα που εξοβελίζουν ψευδαισθήσεις.", "ΦΛΕΓΜΑΤΙΚΆ ΧΡΏΜΑΤΑ ΠΟΥ ΕΞΟΒΕΛΊΖΟΥΝ ΨΕΥΔΑΙΣΘΉΣΕΙΣ.") == 0); // greek
    assert(uni_compare_i("Любя, съешь щипцы, — вздохнёт мэр, — Кайф жгуч!", "ЛЮБЯ, СЪЕШЬ ЩИПЦЫ, — ВЗДОХНЁТ МЭР, — КАЙФ ЖГУЧ!") == 0); // russian
    assert(uni_compare_i("Բել դղյակի ձախ ժամն օֆ ազգությանը ցպահանջ չճշտած վնաս էր եւ փառք։", "ԲԵԼ ԴՂՅԱԿԻ ՁԱԽ ԺԱՄՆ ՕՖ ԱԶԳՈՒԹՅԱՆԸ ՑՊԱՀԱՆՋ ՉՃՇՏԱԾ ՎՆԱՍ ԷՐ ԵՒ ՓԱՌՔ։") == 0); // armenian
    assert(uni_compare_i("აბგად ევზეთ იკალ მანო, პაჟა რასტა უფქა ღაყაშ, ჩაცა ძაწა ჭახა ჯაჰო", "ᲐᲑᲒᲐᲓ ᲔᲕᲖᲔᲗ ᲘᲙᲐᲚ ᲛᲐᲜᲝ, ᲞᲐᲟᲐ ᲠᲐᲡᲢᲐ ᲣᲤᲥᲐ ᲦᲐᲧᲐᲨ, ᲩᲐᲪᲐ ᲫᲐᲬᲐ ᲭᲐᲮᲐ ᲯᲐᲰᲝ") == 0); // georgian modern
    assert(uni_compare_i("ⴘⴄⴅ ⴟⴓ ⴠⴡⴢ ⴣⴤⴥ ⴇⴍⴚ ⴞⴐⴈ ⴝⴋⴊⴈ.", "ႸႤႥ ႿႳ ჀჁჂ ჃჄჅ ႧႭႺ ႾႰႨ ႽႫႪႨ.") == 0); // georgian ecclesiastical
    assert(uni_compare_i("Ⲁⲛⲟⲕ ⲡⲉ ϣⲏⲙ ⲛ̄ⲕⲏⲙⲉ.", "ⲀⲚⲞⲔ ⲠⲈ ϢⲎⲘ Ⲛ̄ⲔⲎⲘⲈ.") == 0); // coptic

    // test the special-cases around german 'ß' (0xDF) and 'ẞ' (0x1E9E)
    // check sort order
    assert(uni_compare_i("ß", "sr") > 0);
    assert(uni_compare_i("ß", "ss") == 0);
    assert(uni_compare_i("ß", "st") < 0);
    assert(uni_compare_i("sr", "ß") < 0);
    assert(uni_compare_i("ss", "ß") == 0);
    assert(uni_compare_i("st", "ß") > 0);
    // check truncated comparisons
    assert(uni_compare_i("ß", "s") > 0);
    assert(uni_compare_i("ß", "r") > 0);
    assert(uni_compare_i("ß", "t") < 0);
    assert(uni_compare_i("s", "ß") < 0);
    assert(uni_compare_i("r", "ß") < 0);
    assert(uni_compare_i("t", "ß") > 0);
    assert(uni_compare_i("ä", "ß") > 0);
    assert(uni_compare_i("sß", "ss") > 0);
    assert(uni_compare_i("sß", "ß") > 0);
    assert(uni_compare_i("sß", "ßß") < 0);
    assert(uni_compare_i("ss", "sß") < 0);
    assert(uni_compare_i("ß", "sß") < 0);
    assert(uni_compare_i("ßß", "sß") > 0);
    // check uneven/recursive comparisons
    assert(uni_compare_i("ßẞ", "ẞß") == 0);
    assert(uni_compare_i("sß", "ẞs") == 0);
    assert(uni_compare_i("ẞs", "sß") == 0);
    assert(uni_compare_i("ẞß", "sßs") == 0);
    assert(uni_compare_i("sẞs", "ẞß") == 0);
    assert(uni_compare_i("sẞsß", "ßsßs") == 0);
    assert(uni_compare_i("ẞsßs", "sßsß") == 0);
    assert(uni_compare_i("ßßßs", "sßßß") == 0);
    assert(uni_compare_i("sßßß", "ßßßs") == 0);
}
