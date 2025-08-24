module urt.encoding;

nothrow @nogc:


enum Base64Decode(string str) = () { ubyte[base64_decode_length(str.length)] r; size_t len = base64_decode(str, r[]); assert(len == r.sizeof, "Not a base64 string: " ~ str);      return r; }();
enum HexDecode(string str) =    () { ubyte[hex_decode_length(str.length)] r;    size_t len = hex_decode(str, r[]);    assert(len == r.sizeof, "Not a hex string: " ~ str);         return r; }();
enum URLDecode(string str) =    () {  char[url_decode_length(str)] r;           size_t len = url_decode(str, r[]);    assert(len == r.sizeof, "Not a URL encoded string: " ~ str); return r; }();


ptrdiff_t base64_encode_length(size_t source_length) pure
    => (source_length + 2) / 3 * 4;

ptrdiff_t base64_encode_length(const void[] data) pure
    => base64_encode_length(data.length);

ptrdiff_t base64_encode(const void[] data, char[] result) pure
{
    auto src = cast(const(ubyte)[])data;
    size_t len = data.length;
    size_t out_len = base64_encode_length(len);

    if (result.length < out_len)
        return -1;

    size_t i = 0;
    size_t j = 0;
    while (i + 3 <= len)
    {
        ubyte b0 = src[i++];
        ubyte b1 = src[i++];
        ubyte b2 = src[i++];

        result[j++] = base64[b0 >> 2];
        result[j++] = base64[((b0 & 0x03) << 4) | (b1 >> 4)];
        result[j++] = base64[((b1 & 0x0F) << 2) | (b2 >> 6)];
        result[j++] = base64[b2 & 0x3F];
    }

    if (i < len)
    {
        ubyte b0 = src[i++];
        result[j++] = base64[b0 >> 2];
        if (i < len)
        {
            ubyte b1 = src[i];
            result[j++] = base64[((b0 & 0x03) << 4) | (b1 >> 4)];
            result[j++] = base64[((b1 & 0x0F) << 2)];
        }
        else
        {
            result[j++] = base64[((b0 & 0x03) << 4)];
            result[j++] = '=';
        }
        result[j] = '=';
    }

    return out_len;
}

ptrdiff_t base64_decode_length(size_t source_length) pure
    => source_length / 4 * 3;

ptrdiff_t base64_decode_length(const char[] data) pure
    => base64_decode_length(data.length);

ptrdiff_t base64_decode(const char[] data, void[] result) pure
{
    size_t len = data.length;
    auto dest = cast(ubyte[])result;
    size_t out_len = base64_decode_length(len);
    if (data[len - 1] == '=')
        out_len--;
    if (data[len - 2] == '=')
        out_len--;

    if (result.length < out_len)
        return -1;

    size_t i = 0;
    size_t j = 0;
    while (i < len)
    {
        if (i > len - 4)
            return -1;

        // TODO: this could be faster by using more memory, store a full 256-byte table and no comparisons...
        uint b0 = data[i++] - 43;
        uint b1 = data[i++] - 43;
        uint b2 = data[i++] - 43;
        uint b3 = data[i++] - 43;
        if (b0 >= 80)
            return -1;
        if (b1 >= 80)
            return -1;
        if (b2 >= 80)
            return -1;
        if (b3 >= 80)
            return -1;

        b0 = base64_map[b0];
        b1 = base64_map[b1];
        b2 = base64_map[b2];
        b3 = base64_map[b3];

        dest[j++] = cast(ubyte)((b0 << 2) | (b1 >> 4));
        if (b2 != 64)
            dest[j++] = cast(ubyte)((b1 << 4) | (b2 >> 2));
        if (b3 != 64)
            dest[j++] = cast(ubyte)((b2 << 6) | b3);
    }

    return out_len;
}

unittest
{
    immutable ubyte[12] data = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C];
    char[16] encoded = void;
    ubyte[12] decoded = void;

    static assert(Base64Decode!"AQIDBAUGBwgJCgsM" == data[]);

    size_t len = base64_encode(data, encoded);
    assert(len == 16);
    assert(encoded == "AQIDBAUGBwgJCgsM");
    len = base64_decode(encoded, decoded);
    assert(len == 12);
    assert(data == decoded);

    len = base64_encode(data[0..11], encoded);
    assert(len == 16);
    assert(encoded == "AQIDBAUGBwgJCgs=");
    len = base64_decode(encoded, decoded);
    assert(len == 11);
    assert(data[0..11] == decoded[0..11]);

    len = base64_encode(data[0..10], encoded);
    assert(len == 16);
    assert(encoded == "AQIDBAUGBwgJCg==");
    len = base64_decode(encoded, decoded);
    assert(len == 10);
    assert(data[0..10] == decoded[0..10]);
}

ptrdiff_t hex_encode_length(size_t sourceLength) pure
    => sourceLength * 2;

ptrdiff_t hex_encode_length(const void[] data) pure
    => data.length * 2;

ptrdiff_t hex_encode(const void[] data, char[] result) pure
{
    import urt.string : toHexString;

    // reuse this since we already have it...
    return toHexString(data, result).length;
}

ptrdiff_t hex_decode_length(size_t sourceLength) pure
    => sourceLength / 2;

ptrdiff_t hex_decode_length(const char[] data) pure
    => data.length / 2;

ptrdiff_t hex_decode(const char[] data, void[] result) pure
{
    import urt.string.ascii : is_hex;

    if (data.length & 1)
        return -1;
    if (result.length < data.length / 2)
        return -1;

    auto dest = cast(ubyte[])result;

    for (size_t i = 0, j = 0; i < data.length; i += 2, ++j)
    {
        ubyte c0 = data[i];
        ubyte c1 = data[i + 1];
        if (!c0.is_hex || !c1.is_hex)
            return -1;

        if ((c0 | 0x20) >= 'a')
            c0 = cast(ubyte)((c0 | 0x20) - 'a' + 10);
        else
            c0 -= '0';
        if ((c1 | 0x20) >= 'a')
            c1 = cast(ubyte)((c1 | 0x20) - 'a' + 10);
        else
            c1 -= '0';
        dest[j] = cast(ubyte)(c0 << 4 | c1);
    }

    return data.length / 2;
}

unittest
{
    immutable ubyte[12] data = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C];
    char[24] encoded = void;
    ubyte[12] decoded = void;

    static assert(HexDecode!"0102030405060708090A0B0C" == data);

    size_t len = hex_encode(data, encoded);
    assert(len == 24);
    assert(encoded == "0102030405060708090A0B0C");
    len = hex_decode(encoded, decoded);
    assert(len == 12);
    assert(data == decoded);
}


ptrdiff_t url_encode_length(const char[] data) pure
{
    import urt.string.ascii : is_url;

    size_t len = 0;
    foreach (c; data)
    {
        if (c.is_url || c == ' ')
            ++len;
        else
            len += 3;
    }
    return len;
}

ptrdiff_t url_encode(const char[] data, char[] result) pure
{
    import urt.string.ascii : is_url, hex_digits;

    size_t j = 0;

    for (size_t i = 0; i < data.length; ++i)
    {
        char c = data[i];
        if (c.is_url || c == ' ')
        {
            if (j == result.length)
                return -1;
            result[j++] = c == ' ' ? '+' : c;
        }
        else
        {
            if (j + 2 == result.length)
                return -1;
            result[j++] = '%';
            result[j++] = hex_digits[c >> 4];
            result[j++] = hex_digits[c & 0xF];
        }
    }

    return j;
}

ptrdiff_t url_decode_length(const char[] data) pure
{
    size_t len = 0;
    for (size_t i = 0; i < data.length;)
    {
        if (data.ptr[i] == '%')
            i += 3;
        else
            ++i;
        ++len;
    }
    return len;
}

ptrdiff_t url_decode(const char[] data, char[] result) pure
{
    import urt.string.ascii : is_hex;

    size_t j = 0;
    for (size_t i = 0; i < data.length; ++i)
    {
        if (result.length == j)
            return -1;

        char c = data[i];
        if (c == '+')
            c = ' ';
        else if (c == '%')
        {
            if (i + 2 >= data.length)
                return -1;

            ubyte c0 = data[i + 1];
            ubyte c1 = data[i + 2];
            if (!c0.is_hex || !c1.is_hex)
                return -1;
            i += 2;

            if ((c0 | 0x20) >= 'a')
                c0 = cast(ubyte)((c0 | 0x20) - 'a' + 10);
            else
                c0 -= '0';
            if ((c1 | 0x20) >= 'a')
                c1 = cast(ubyte)((c1 | 0x20) - 'a' + 10);
            else
                c1 -= '0';
            c = cast(char)(c0 << 4 | c1);
        }
        result[j++] = c;
    }

    return j;
}

unittest
{
    static assert(URLDecode!"Hello%2C+World%21" == "Hello, World!");

    char[13] data = "Hello, World!";
    char[17] encoded = void;
    char[13] decoded = void;

    assert(url_encode_length(data) == 17);
    size_t len = url_encode(data, encoded);
    assert(len == 17);
    assert(encoded == "Hello%2C+World%21");
    assert(url_decode_length(encoded) == 13);
    len = url_decode(encoded, decoded);
    assert(len == 13);
    assert(data == decoded);
}


private:

__gshared immutable char[64] base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
__gshared immutable ubyte[80] base64_map = [    62, 0,  0,  0,  63,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 0,  0,  0,  64,  0,  0,
    0,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 0,  0,  0,  0,  0,
    0,  26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51
];
