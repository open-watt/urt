module urt.crypto.aes_ccm;

import urt.crypto.aes : aes_ecb_encrypt;
import urt.result : Result, InternalResult;

nothrow @nogc:


// RFC 3610 / NIST SP 800-38C. nonce is 7..13 bytes; tag is 4..16 bytes, even.
Result aes_ccm_encrypt(const(ubyte)[] key, const(ubyte)[] nonce, const(ubyte)[] aad,
                       const(ubyte)[] plaintext, ubyte[] ciphertext, ubyte[] tag)
{
    Result r = check_params(nonce, plaintext.length, ciphertext.length, tag.length);
    if (r.failed)
        return r;

    ubyte[16] mac = void;
    r = cbc_mac(key, nonce, aad, plaintext, tag.length, mac);
    if (r.failed)
        return r;

    ubyte[16] s0 = void;
    r = ctr_crypt(key, nonce, plaintext, ciphertext, s0);
    if (r.failed)
        return r;

    foreach (i; 0 .. tag.length)
        tag[i] = mac[i] ^ s0[i];
    return Result.success;
}

Result aes_ccm_decrypt(const(ubyte)[] key, const(ubyte)[] nonce, const(ubyte)[] aad,
                       const(ubyte)[] ciphertext, const(ubyte)[] tag, ubyte[] plaintext)
{
    Result r = check_params(nonce, ciphertext.length, plaintext.length, tag.length);
    if (r.failed)
        return r;

    ubyte[16] s0 = void;
    r = ctr_crypt(key, nonce, ciphertext, plaintext, s0);
    if (r.failed)
        return r;

    ubyte[16] mac = void;
    r = cbc_mac(key, nonce, aad, plaintext, tag.length, mac);
    if (r.failed)
    {
        plaintext[] = 0;
        return r;
    }

    ubyte diff = 0;
    foreach (i; 0 .. tag.length)
        diff |= tag[i] ^ mac[i] ^ s0[i];
    if (diff != 0)
    {
        plaintext[] = 0;
        return InternalResult.data_error;
    }
    return Result.success;
}


private:

Result check_params(const(ubyte)[] nonce, size_t in_len, size_t out_len, size_t tag_len)
{
    if (nonce.length < 7 || nonce.length > 13 || in_len != out_len)
        return InternalResult.invalid_parameter;
    if (tag_len < 4 || tag_len > 16 || (tag_len & 1))
        return InternalResult.invalid_parameter;
    size_t l = 15 - nonce.length;
    if (l < 8 && in_len >> (8*l))
        return InternalResult.invalid_parameter;
    return Result.success;
}

Result cbc_mac(const(ubyte)[] key, const(ubyte)[] nonce, const(ubyte)[] aad, const(ubyte)[] msg, size_t tag_len, ref ubyte[16] x)
{
    size_t l = 15 - nonce.length;

    ubyte[16] b = 0;
    b[0] = cast(ubyte)((aad.length ? 0x40 : 0) | ((tag_len - 2) / 2) << 3 | (l - 1));
    b[1 .. 1 + nonce.length] = nonce[];
    size_t len = msg.length;
    foreach (i; 0 .. l)
    {
        b[15 - i] = cast(ubyte)len;
        len >>= 8;
    }
    Result r = aes_ecb_encrypt(key, b, x);
    if (r.failed)
        return r;

    if (aad.length)
    {
        b[] = 0;
        size_t pos;
        if (aad.length < 0xFF00)
        {
            b[0] = cast(ubyte)(aad.length >> 8);
            b[1] = cast(ubyte)aad.length;
            pos = 2;
        }
        else
        {
            b[0] = 0xFF;
            b[1] = 0xFE;
            b[2] = cast(ubyte)(aad.length >> 24);
            b[3] = cast(ubyte)(aad.length >> 16);
            b[4] = cast(ubyte)(aad.length >> 8);
            b[5] = cast(ubyte)aad.length;
            pos = 6;
        }
        size_t taken = 0;
        while (true)
        {
            size_t n = aad.length - taken;
            if (n > 16 - pos)
                n = 16 - pos;
            b[pos .. pos + n] = aad[taken .. taken + n];
            taken += n;
            r = mac_block(key, b, x);
            if (r.failed)
                return r;
            if (taken >= aad.length)
                break;
            b[] = 0;
            pos = 0;
        }
    }

    for (size_t off = 0; off < msg.length; off += 16)
    {
        size_t n = msg.length - off;
        if (n > 16)
            n = 16;
        b[] = 0;
        b[0 .. n] = msg[off .. off + n];
        r = mac_block(key, b, x);
        if (r.failed)
            return r;
    }
    return Result.success;
}

Result mac_block(const(ubyte)[] key, ref const ubyte[16] b, ref ubyte[16] x)
{
    ubyte[16] t = void;
    foreach (i; 0 .. 16)
        t[i] = x[i] ^ b[i];
    return aes_ecb_encrypt(key, t, x);
}

Result ctr_crypt(const(ubyte)[] key, const(ubyte)[] nonce, const(ubyte)[] input, ubyte[] output, ref ubyte[16] s0)
{
    size_t l = 15 - nonce.length;

    ubyte[16] a = 0;
    a[0] = cast(ubyte)(l - 1);
    a[1 .. 1 + nonce.length] = nonce[];
    Result r = aes_ecb_encrypt(key, a, s0);
    if (r.failed)
        return r;

    ubyte[16] s = void;
    size_t counter = 0;
    for (size_t off = 0; off < input.length; off += 16)
    {
        ++counter;
        size_t c = counter;
        foreach (i; 0 .. l)
        {
            a[15 - i] = cast(ubyte)c;
            c >>= 8;
        }
        r = aes_ecb_encrypt(key, a, s);
        if (r.failed)
            return r;
        size_t n = input.length - off;
        if (n > 16)
            n = 16;
        foreach (i; 0 .. n)
            output[off + i] = input[off + i] ^ s[i];
    }
    return Result.success;
}


unittest
{
    // RFC 3610 packet vector #1
    static immutable ubyte[16] key = [0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF];
    static immutable ubyte[13] nonce = [0x00, 0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5];
    static immutable ubyte[8] aad = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07];
    static immutable ubyte[23] plaintext = [
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E,
    ];
    static immutable ubyte[23] expected_ct = [
        0x58, 0x8C, 0x97, 0x9A, 0x61, 0xC6, 0x63, 0xD2, 0xF0, 0x66, 0xD0, 0xC2, 0xC0, 0xF9, 0x89, 0x80,
        0x6D, 0x5F, 0x6B, 0x61, 0xDA, 0xC3, 0x84,
    ];
    static immutable ubyte[8] expected_tag = [0x17, 0xE8, 0xD1, 0x2C, 0xFD, 0xF9, 0x26, 0xE0];

    ubyte[23] ct;
    ubyte[8] tag;
    assert(aes_ccm_encrypt(key[], nonce[], aad[], plaintext[], ct[], tag[]));
    assert(ct == expected_ct);
    assert(tag == expected_tag);

    ubyte[23] pt;
    assert(aes_ccm_decrypt(key[], nonce[], aad[], ct[], tag[], pt[]));
    assert(pt == plaintext);

    tag[0] ^= 1;
    assert(!aes_ccm_decrypt(key[], nonce[], aad[], ct[], tag[], pt[]));
    assert(pt == ubyte[23].init);

    // RFC 3610 packet vector #4: 12-byte AAD, 19-byte payload
    static immutable ubyte[13] nonce4 = [0x00, 0x00, 0x00, 0x06, 0x05, 0x04, 0x03, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5];
    static immutable ubyte[12] aad4 = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B];
    static immutable ubyte[19] pt4 = [0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E];
    static immutable ubyte[19] ct4_expected = [0xA2, 0x8C, 0x68, 0x65, 0x93, 0x9A, 0x9A, 0x79, 0xFF, 0xFF, 0xFF, 0x40, 0x39, 0x00, 0x24, 0x15, 0x31, 0xDD, 0x25];
    static immutable ubyte[8] tag4_expected = [0x4B, 0x99, 0xA7, 0x04, 0x31, 0x19, 0x9C, 0x38];
    ubyte[19] ct4;
    ubyte[8] tag4;
    assert(aes_ccm_encrypt(key[], nonce4[], aad4[], pt4[], ct4[], tag4[]));
    assert(ct4 == ct4_expected);
    assert(tag4 == tag4_expected);

    // 16-byte tag as used by Matter round-trips
    ubyte[16] tag16;
    assert(aes_ccm_encrypt(key[], nonce[], aad[], plaintext[], ct[], tag16[]));
    assert(aes_ccm_decrypt(key[], nonce[], aad[], ct[], tag16[], pt[]));
    assert(pt == plaintext);
}
