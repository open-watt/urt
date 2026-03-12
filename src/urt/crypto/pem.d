module urt.crypto.pem;

import urt.array;
import urt.encoding;
import urt.mem;

nothrow @nogc:


bool is_pem(const(char)[] data)
    => data.length >= 11 && data[0 .. 11] == "-----BEGIN ";

Array!char encode_pem(const(ubyte)[] der, const(char)[] label)
{
    Array!char result = "-----BEGIN ";
    result ~= label;
    result ~= "-----\n";

    size_t enc_len = base64_encode_length(der.length);
    if (enc_len > 256)
        assert(false, "PEM encode: DER input too large for stack buffer");
    char[256] b64_buf = void;
    base64_encode(der, b64_buf[0 .. enc_len]);

    size_t pos = 0;
    while (pos < enc_len)
    {
        size_t line_len = enc_len - pos;
        if (line_len > 64)
            line_len = 64;
        result ~= b64_buf[pos .. pos + line_len];
        result ~= "\n";
        pos += line_len;
    }

    result ~= "-----END ";
    result ~= label;
    result ~= "-----\n";
    return result;
}

Array!ubyte decode_pem(const(char)[] data)
{
    import urt.string;

    size_t start = data.findFirst('\n');
    if (start == data.length)
        return Array!ubyte();
    data = data[start .. $].trimFront;

    size_t end = data.findFirst("-----END");
    if (end == data.length)
        return Array!ubyte();
    data = data[0 .. end].trimBack;

    if (data.length == 0)
        return Array!ubyte();

    // strip whitespace from base64 content
    auto b64 = Array!char(Reserve, data.length);
    for (size_t i = 0; i < data.length; ++i)
        if (!data[i].is_whitespace)
            b64 ~= data[i];

    auto result = Array!ubyte(Alloc, base64_decode_length(b64.length));
    ptrdiff_t decoded_len = base64_decode(b64[], result[]);
    if (decoded_len < 0)
        return Array!ubyte();

    result.resize(decoded_len);
    return result;
}
