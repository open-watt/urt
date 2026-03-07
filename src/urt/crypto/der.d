module urt.crypto.der;

import urt.time : DateTime;

nothrow @nogc:


// pre-encoded OID content bytes
static immutable ubyte[7] oid_ec_public_key = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]; // 1.2.840.10045.2.1
static immutable ubyte[8] oid_prime256v1 = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]; // 1.2.840.10045.3.1.7
static immutable ubyte[8] oid_sha256_ecdsa = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]; // 1.2.840.10045.4.3.2
static immutable ubyte[3] oid_common_name = [0x55, 0x04, 0x03]; // 2.5.4.3


// Primitives...

uint der_length_size(size_t len) pure
{
    if (len < 0x80) return 1;
    if (len < 0x100) return 2;
    return 3;
}

// write tag + length header for known content size
ptrdiff_t der_header(ubyte[] buf, ubyte tag, size_t content_len)
{
    size_t n = 1 + der_length_size(content_len);
    if (!buf.ptr)
        return n;
    if (buf.length < n)
        return -1;
    size_t pos = 0;
    buf[pos++] = tag;
    pos += put_length(buf[pos .. $], content_len);
    return pos;
}

// write tag + length + content
ptrdiff_t der_tlv(ubyte[] buf, ubyte tag, const(ubyte)[] content)
{
    size_t n = 1 + der_length_size(content.length) + content.length;
    if (!buf.ptr)
        return n;
    if (buf.length < n)
        return -1;
    size_t pos = 0;
    buf[pos++] = tag;
    pos += put_length(buf[pos .. $], content.length);
    buf[pos .. pos + content.length] = content[];
    return n;
}

// INTEGER with leading-zero stripping and sign padding
ptrdiff_t der_integer(ubyte[] buf, const(ubyte)[] value)
{
    while (value.length > 1 && value[0] == 0)
        value = value[1 .. $];
    bool pad = (value[0] & 0x80) != 0;
    size_t content_len = (pad ? 1 : 0) + value.length;
    size_t n = 1 + der_length_size(content_len) + content_len;
    if (!buf.ptr)
        return n;
    if (buf.length < n)
        return -1;
    size_t pos = 0;
    buf[pos++] = 0x02;
    pos += put_length(buf[pos .. $], content_len);
    if (pad)
        buf[pos++] = 0;
    buf[pos .. pos + value.length] = value[];
    return n;
}

ptrdiff_t der_integer_small(ubyte[] buf, uint value)
{
    if (value == 0)
    {
        if (!buf.ptr)
            return 3;
        if (buf.length < 3)
            return -1;
        buf[0] = 0x02;
        buf[1] = 0x01;
        buf[2] = 0x00;
        return 3;
    }
    ubyte[4] be = void;
    uint n = 0;
    for (uint v = value; v > 0; v >>= 8)
        ++n;
    for (uint i = 0; i < n; ++i)
        be[i] = cast(ubyte)(value >> ((n - 1 - i) * 8));
    return der_integer(buf, be[0 .. n]);
}


// Composite structures...

// SEQUENCE { INTEGER r, INTEGER s } from raw 64-byte ECDSA P-256 signature
ptrdiff_t der_ecdsa_sig(ubyte[] buf, const(ubyte)[] raw_sig)
{
    ptrdiff_t r_size = der_integer(null, raw_sig[0 .. 32]);
    ptrdiff_t s_size = der_integer(null, raw_sig[32 .. 64]);
    size_t content = r_size + s_size;
    size_t total = 1 + der_length_size(content) + content;
    if (!buf.ptr)
        return total;
    if (buf.length < total)
        return -1;
    size_t pos = 0;
    buf[pos++] = 0x30;
    pos += put_length(buf[pos .. $], content);
    pos += der_integer(buf[pos .. $], raw_sig[0 .. 32]);
    pos += der_integer(buf[pos .. $], raw_sig[32 .. 64]);
    return total;
}

ptrdiff_t der_utctime(ubyte[] buf, DateTime dt)
{
    enum size_t total = 15; // tag(1) + length(1) + content(13)
    if (!buf.ptr)
        return total;
    if (buf.length < total)
        return -1;
    buf[0] = 0x17;
    buf[1] = 13;
    ubyte yr = cast(ubyte)(dt.year % 100);
    ubyte mo = cast(ubyte)dt.month;
    buf[2] = cast(ubyte)('0' + yr / 10);
    buf[3] = cast(ubyte)('0' + yr % 10);
    buf[4] = cast(ubyte)('0' + mo / 10);
    buf[5] = cast(ubyte)('0' + mo % 10);
    buf[6] = cast(ubyte)('0' + dt.day / 10);
    buf[7] = cast(ubyte)('0' + dt.day % 10);
    buf[8] = cast(ubyte)('0' + dt.hour / 10);
    buf[9] = cast(ubyte)('0' + dt.hour % 10);
    buf[10] = cast(ubyte)('0' + dt.minute / 10);
    buf[11] = cast(ubyte)('0' + dt.minute % 10);
    buf[12] = cast(ubyte)('0' + dt.second / 10);
    buf[13] = cast(ubyte)('0' + dt.second % 10);
    buf[14] = 'Z';
    return total;
}

// X.500 Name with a single CN attribute: SEQUENCE { SET { SEQUENCE { OID, UTF8String } } }
ptrdiff_t der_name_cn(ubyte[] buf, const(char)[] cn)
{
    size_t oid_tlv = 1 + 1 + oid_common_name.length;
    size_t utf8_tlv = 1 + der_length_size(cn.length) + cn.length;
    size_t atv_content = oid_tlv + utf8_tlv;
    size_t atv = 1 + der_length_size(atv_content) + atv_content;
    size_t rdn = 1 + der_length_size(atv) + atv;
    size_t total = 1 + der_length_size(rdn) + rdn;
    if (!buf.ptr)
        return total;
    if (buf.length < total)
        return -1;
    size_t pos = 0;
    buf[pos++] = 0x30;
    pos += put_length(buf[pos .. $], rdn);
    buf[pos++] = 0x31;
    pos += put_length(buf[pos .. $], atv);
    buf[pos++] = 0x30;
    pos += put_length(buf[pos .. $], atv_content);
    pos += der_tlv(buf[pos .. $], 0x06, oid_common_name[]);
    pos += der_tlv(buf[pos .. $], 0x0c, cast(const(ubyte)[])cn);
    return total;
}

// SubjectPublicKeyInfo for EC P-256 uncompressed point
ptrdiff_t der_ec_pubkey_info(ubyte[] buf, const(ubyte)[] x, const(ubyte)[] y)
{
    size_t oid1_tlv = 1 + 1 + oid_ec_public_key.length;
    size_t oid2_tlv = 1 + 1 + oid_prime256v1.length;
    size_t alg_content = oid1_tlv + oid2_tlv;
    size_t alg = 1 + der_length_size(alg_content) + alg_content;

    size_t bs_content = 1 + 1 + x.length + y.length; // unused_bits + 0x04 + x + y
    size_t bs = 1 + der_length_size(bs_content) + bs_content;

    size_t spki_content = alg + bs;
    size_t total = 1 + der_length_size(spki_content) + spki_content;
    if (!buf.ptr)
        return total;
    if (buf.length < total)
        return -1;

    size_t pos = 0;
    buf[pos++] = 0x30;
    pos += put_length(buf[pos .. $], spki_content);

    buf[pos++] = 0x30;
    pos += put_length(buf[pos .. $], alg_content);
    pos += der_tlv(buf[pos .. $], 0x06, oid_ec_public_key[]);
    pos += der_tlv(buf[pos .. $], 0x06, oid_prime256v1[]);

    buf[pos++] = 0x03;
    pos += put_length(buf[pos .. $], bs_content);
    buf[pos++] = 0x00;
    buf[pos++] = 0x04;
    buf[pos .. pos + x.length] = x[];
    pos += x.length;
    buf[pos .. pos + y.length] = y[];
    pos += y.length;

    return total;
}

// AlgorithmIdentifier for sha256WithECDSA
ptrdiff_t der_sig_alg(ubyte[] buf)
{
    size_t oid_tlv = 1 + 1 + oid_sha256_ecdsa.length;
    size_t total = 1 + der_length_size(oid_tlv) + oid_tlv;
    if (!buf.ptr)
        return total;
    if (buf.length < total)
        return -1;
    size_t pos = 0;
    buf[pos++] = 0x30;
    pos += put_length(buf[pos .. $], oid_tlv);
    pos += der_tlv(buf[pos .. $], 0x06, oid_sha256_ecdsa[]);
    return total;
}


private:

uint put_length(ubyte[] buf, size_t len)
{
    if (len < 0x80)
    {
        buf[0] = cast(ubyte)len;
        return 1;
    }
    if (len < 0x100)
    {
        buf[0] = 0x81;
        buf[1] = cast(ubyte)len;
        return 2;
    }
    buf[0] = 0x82;
    buf[1] = cast(ubyte)(len >> 8);
    buf[2] = cast(ubyte)(len & 0xff);
    return 3;
}
