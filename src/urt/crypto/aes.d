module urt.crypto.aes;

import urt.result;

// AesLib: a library backs every AES entry point. Without it only the single-block ECB
// primitive is available, on the software cipher at the bottom of this module.
version (MbedTLS)      version = AesLib;
else version (Windows) version = AesLib;
version (AesLib) { version (unittest) version = AesSw; }
else                   version = AesSw;

version (MbedTLS)
{
    extern (C) nothrow @nogc
    {
        int urt_gcm_encrypt(const(ubyte)* key, size_t key_len,
                            const(ubyte)* iv, size_t iv_len,
                            const(ubyte)* aad, size_t aad_len,
                            const(ubyte)* plaintext, size_t pt_len,
                            ubyte* ciphertext,
                            ubyte* tag, size_t tag_len);

        int urt_gcm_decrypt(const(ubyte)* key, size_t key_len,
                            const(ubyte)* iv, size_t iv_len,
                            const(ubyte)* aad, size_t aad_len,
                            const(ubyte)* ciphertext, size_t ct_len,
                            const(ubyte)* tag, size_t tag_len,
                            ubyte* plaintext);
    }
}
else version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    pragma(lib, "Bcrypt");

    // STATUS_AUTH_TAG_MISMATCH - returned by BCryptDecrypt when GCM tag verification fails.
    private enum NTSTATUS STATUS_AUTH_TAG_MISMATCH = cast(NTSTATUS)0xC000A002;
}

nothrow @nogc:


// AES-GCM authenticated encryption. Writes ciphertext (length == plaintext.length)
// and the authentication tag.
//
// key: 16, 24, or 32 bytes (AES-128/192/256).
// iv:  any non-zero length; 12 bytes is the GCM-native size and the only one
//      that doesn't trigger the GHASH-based IV reduction.
// aad: associated data - authenticated but not encrypted; may be empty.
// tag: 4..16 bytes (16 is standard).
Result aes_gcm_encrypt(const(ubyte)[] key,
                       const(ubyte)[] iv,
                       const(ubyte)[] aad,
                       const(ubyte)[] plaintext,
                       ubyte[] ciphertext,
                       ubyte[] tag)
{
    if (key.length != 16 && key.length != 24 && key.length != 32)
        return InternalResult.invalid_parameter;
    if (iv.length == 0 || ciphertext.length != plaintext.length || tag.length < 4 || tag.length > 16)
        return InternalResult.invalid_parameter;

    version (MbedTLS)
    {
        int ret = urt_gcm_encrypt(
            key.ptr, key.length,
            iv.ptr, iv.length,
            aad.length ? aad.ptr : null, aad.length,
            plaintext.length ? plaintext.ptr : null, plaintext.length,
            ciphertext.length ? ciphertext.ptr : null,
            tag.ptr, tag.length);
        return ret == 0 ? Result.success : Result(cast(uint)ret);
    }
    else version (Windows)
    {
        BCRYPT_ALG_HANDLE halg;
        NTSTATUS status = BCryptOpenAlgorithmProvider(&halg, BCRYPT_AES_ALGORITHM.ptr, null, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptCloseAlgorithmProvider(halg, 0);

        status = BCryptSetProperty(halg, BCRYPT_CHAINING_MODE.ptr,
            cast(ubyte*)BCRYPT_CHAIN_MODE_GCM.ptr,
            cast(uint)(BCRYPT_CHAIN_MODE_GCM.length * wchar.sizeof), 0);
        if (status != 0)
            return Result(cast(uint)status);

        BCRYPT_KEY_HANDLE hkey;
        status = BCryptGenerateSymmetricKey(halg, &hkey, null, 0,
            cast(ubyte*)key.ptr, cast(uint)key.length, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptDestroyKey(hkey);

        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        info.cbSize = BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO.sizeof;
        info.dwInfoVersion = BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO_VERSION;
        info.pbNonce = cast(ubyte*)iv.ptr;
        info.cbNonce = cast(uint)iv.length;
        info.pbAuthData = aad.length ? cast(ubyte*)aad.ptr : null;
        info.cbAuthData = cast(uint)aad.length;
        info.pbTag = tag.ptr;
        info.cbTag = cast(uint)tag.length;

        uint result_len;
        status = BCryptEncrypt(hkey,
            plaintext.length ? cast(ubyte*)plaintext.ptr : null, cast(uint)plaintext.length,
            &info,
            null, 0,
            ciphertext.length ? ciphertext.ptr : null, cast(uint)ciphertext.length,
            &result_len, 0);
        return status == 0 ? Result.success : Result(cast(uint)status);
    }
    else
        return InternalResult.unsupported;
}


// AES-GCM authenticated decryption with tag verification.
// On tag-verify failure returns a system-specific failure code; callers should
// treat any failure as authentication failure and discard `plaintext`.
Result aes_gcm_decrypt(const(ubyte)[] key,
                       const(ubyte)[] iv,
                       const(ubyte)[] aad,
                       const(ubyte)[] ciphertext,
                       const(ubyte)[] tag,
                       ubyte[] plaintext)
{
    if (key.length != 16 && key.length != 24 && key.length != 32)
        return InternalResult.invalid_parameter;
    if (iv.length == 0 || plaintext.length != ciphertext.length || tag.length < 4 || tag.length > 16)
        return InternalResult.invalid_parameter;

    version (MbedTLS)
    {
        int ret = urt_gcm_decrypt(
            key.ptr, key.length,
            iv.ptr, iv.length,
            aad.length ? aad.ptr : null, aad.length,
            ciphertext.length ? ciphertext.ptr : null, ciphertext.length,
            tag.ptr, tag.length,
            plaintext.length ? plaintext.ptr : null);
        return ret == 0 ? Result.success : Result(cast(uint)ret);
    }
    else version (Windows)
    {
        BCRYPT_ALG_HANDLE halg;
        NTSTATUS status = BCryptOpenAlgorithmProvider(&halg, BCRYPT_AES_ALGORITHM.ptr, null, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptCloseAlgorithmProvider(halg, 0);

        status = BCryptSetProperty(halg, BCRYPT_CHAINING_MODE.ptr,
            cast(ubyte*)BCRYPT_CHAIN_MODE_GCM.ptr,
            cast(uint)(BCRYPT_CHAIN_MODE_GCM.length * wchar.sizeof), 0);
        if (status != 0)
            return Result(cast(uint)status);

        BCRYPT_KEY_HANDLE hkey;
        status = BCryptGenerateSymmetricKey(halg, &hkey, null, 0,
            cast(ubyte*)key.ptr, cast(uint)key.length, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptDestroyKey(hkey);

        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        info.cbSize = BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO.sizeof;
        info.dwInfoVersion = BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO_VERSION;
        info.pbNonce = cast(ubyte*)iv.ptr;
        info.cbNonce = cast(uint)iv.length;
        info.pbAuthData = aad.length ? cast(ubyte*)aad.ptr : null;
        info.cbAuthData = cast(uint)aad.length;
        info.pbTag = cast(ubyte*)tag.ptr;
        info.cbTag = cast(uint)tag.length;

        uint result_len;
        status = BCryptDecrypt(hkey,
            ciphertext.length ? cast(ubyte*)ciphertext.ptr : null, cast(uint)ciphertext.length,
            &info,
            null, 0,
            plaintext.length ? plaintext.ptr : null, cast(uint)plaintext.length,
            &result_len, 0);
        return status == 0 ? Result.success : Result(cast(uint)status);
    }
    else
        return InternalResult.unsupported;
}


// Raw AES-ECB on a single 16-byte block (no padding, no IV). The building
// block for RFC 3394 key wrap; not a general-purpose cipher mode. key is
// 16/24/32 bytes. This is the one entry point that works without a library (AesSw);
// the GCM functions above still return unsupported there.
Result aes_ecb_encrypt(const(ubyte)[] key, ref const ubyte[16] input, ref ubyte[16] output)
{
    if (key.length != 16 && key.length != 24 && key.length != 32)
        return InternalResult.invalid_parameter;

    version (MbedTLS)
    {
        import urt.internal.mbedtls : urt_aes_ecb_encrypt;
        return urt_aes_ecb_encrypt(key.ptr, key.length, input.ptr, output.ptr) == 0 ? Result.success : InternalResult.failed;
    }
    else version (Windows)
        return aes_ecb_block_win(key, input, output, false);
    else
    {
        AesSw a;
        if (!a.expand(key))
            return InternalResult.invalid_parameter;
        a.encrypt(input, output);
        return Result.success;
    }
}

Result aes_ecb_decrypt(const(ubyte)[] key, ref const ubyte[16] input, ref ubyte[16] output)
{
    if (key.length != 16 && key.length != 24 && key.length != 32)
        return InternalResult.invalid_parameter;

    version (MbedTLS)
    {
        import urt.internal.mbedtls : urt_aes_ecb_decrypt;
        return urt_aes_ecb_decrypt(key.ptr, key.length, input.ptr, output.ptr) == 0 ? Result.success : InternalResult.failed;
    }
    else version (Windows)
        return aes_ecb_block_win(key, input, output, true);
    else
    {
        AesSw a;
        if (!a.expand(key))
            return InternalResult.invalid_parameter;
        a.decrypt(input, output);
        return Result.success;
    }
}

version (Windows)
private Result aes_ecb_block_win(const(ubyte)[] key, ref const ubyte[16] input, ref ubyte[16] output, bool decrypt)
{
    BCRYPT_ALG_HANDLE halg;
    NTSTATUS status = BCryptOpenAlgorithmProvider(&halg, BCRYPT_AES_ALGORITHM.ptr, null, 0);
    if (status != 0)
        return Result(cast(uint)status);
    scope(exit) BCryptCloseAlgorithmProvider(halg, 0);

    status = BCryptSetProperty(halg, BCRYPT_CHAINING_MODE.ptr,
        cast(ubyte*)BCRYPT_CHAIN_MODE_ECB.ptr,
        cast(uint)(BCRYPT_CHAIN_MODE_ECB.length * wchar.sizeof), 0);
    if (status != 0)
        return Result(cast(uint)status);

    BCRYPT_KEY_HANDLE hkey;
    status = BCryptGenerateSymmetricKey(halg, &hkey, null, 0, cast(ubyte*)key.ptr, cast(uint)key.length, 0);
    if (status != 0)
        return Result(cast(uint)status);
    scope(exit) BCryptDestroyKey(hkey);

    uint result_len;
    if (decrypt)
        status = BCryptDecrypt(hkey, cast(ubyte*)input.ptr, 16, null, null, 0, output.ptr, 16, &result_len, 0);
    else
        status = BCryptEncrypt(hkey, cast(ubyte*)input.ptr, 16, null, null, 0, output.ptr, 16, &result_len, 0);
    return status == 0 ? Result.success : Result(cast(uint)status);
}


unittest
{
    // McGrew/Viega AES-GCM test vectors (FIPS 800-38D Annex B examples)
    import urt.encoding : HexDecode;

    // Test 1: empty PT, empty AAD, AES-128
    {
        auto key = HexDecode!"00000000000000000000000000000000";
        auto iv  = HexDecode!"000000000000000000000000";
        auto expected_tag = HexDecode!"58e2fccefa7e3061367f1d57a4e7455a";

        ubyte[16] tag;
        auto r = aes_gcm_encrypt(key[], iv[], null, null, null, tag[]);
        assert(r.succeeded);
        assert(tag == expected_tag);

        // verify round-trip via decrypt with the produced tag
        r = aes_gcm_decrypt(key[], iv[], null, null, tag[], null);
        assert(r.succeeded);
    }

    // Test 2: 16-byte zero PT, empty AAD, AES-128
    {
        auto key = HexDecode!"00000000000000000000000000000000";
        auto iv  = HexDecode!"000000000000000000000000";
        auto pt  = HexDecode!"00000000000000000000000000000000";
        auto expected_ct  = HexDecode!"0388dace60b6a392f328c2b971b2fe78";
        auto expected_tag = HexDecode!"ab6e47d42cec13bdf53a67b21257bddf";

        ubyte[16] ct, tag;
        auto r = aes_gcm_encrypt(key[], iv[], null, pt[], ct[], tag[]);
        assert(r.succeeded);
        assert(ct == expected_ct);
        assert(tag == expected_tag);

        ubyte[16] pt_out;
        r = aes_gcm_decrypt(key[], iv[], null, ct[], tag[], pt_out[]);
        assert(r.succeeded);
        assert(pt_out == pt);
    }

    // Test 4: 60-byte PT (partial last block) + 20-byte AAD, AES-128
    {
        auto key = HexDecode!"feffe9928665731c6d6a8f9467308308";
        auto iv  = HexDecode!"cafebabefacedbaddecaf888";
        auto aad = HexDecode!"feedfacedeadbeeffeedfacedeadbeefabaddad2";
        auto pt  = HexDecode!"d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39";
        auto expected_ct  = HexDecode!"42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091";
        auto expected_tag = HexDecode!"5bc94fbc3221a5db94fae95ae7121a47";

        ubyte[60] ct;
        ubyte[16] tag;
        auto r = aes_gcm_encrypt(key[], iv[], aad[], pt[], ct[], tag[]);
        assert(r.succeeded);
        assert(ct == expected_ct);
        assert(tag == expected_tag);

        ubyte[60] pt_out;
        r = aes_gcm_decrypt(key[], iv[], aad[], ct[], tag[], pt_out[]);
        assert(r.succeeded);
        assert(pt_out == pt);

        // tag tamper should fail authentication
        ubyte[16] bad_tag = tag;
        bad_tag[0] ^= 1;
        r = aes_gcm_decrypt(key[], iv[], aad[], ct[], bad_tag[], pt_out[]);
        assert(r.failed);
    }
}

version (AesSw):

// ====================================================================
// Software block cipher (FIPS-197), byte-oriented; the backend when no
// crypto library is compiled in. Only the single-block ECB primitives sit
// on it (RFC 3394 key wrap), so speed is not a concern and no T-tables.
// ====================================================================

private struct AesSw
{
nothrow @nogc:
    ubyte[240] rk;      // 16 * (rounds + 1), enough for AES-256
    uint rounds;

    bool expand(const(ubyte)[] key)
    {
        uint nk = cast(uint)key.length / 4;
        if (nk != 4 && nk != 6 && nk != 8)
            return false;
        rounds = nk + 6;
        uint total = 4 * (rounds + 1);
        rk[0 .. key.length] = key[];
        ubyte rcon = 1;
        for (uint i = nk; i < total; ++i)
        {
            ubyte[4] t = rk[(i - 1) * 4 .. i * 4];
            if (i % nk == 0)
            {
                ubyte t0 = t[0];
                t[0] = sbox[t[1]] ^ rcon;
                t[1] = sbox[t[2]];
                t[2] = sbox[t[3]];
                t[3] = sbox[t0];
                rcon = xtime(rcon);
            }
            else if (nk > 6 && i % nk == 4)
            {
                foreach (ref b; t)
                    b = sbox[b];
            }
            foreach (j; 0 .. 4)
                rk[i * 4 + j] = rk[(i - nk) * 4 + j] ^ t[j];
        }
        return true;
    }

    void encrypt(ref const ubyte[16] input, ref ubyte[16] output) const
    {
        ubyte[16] s = input;
        add_round_key(s, 0);
        foreach (r; 1 .. rounds)
        {
            sub_bytes(s);
            shift_rows(s);
            mix_columns(s);
            add_round_key(s, r);
        }
        sub_bytes(s);
        shift_rows(s);
        add_round_key(s, rounds);
        output = s;
    }

    void decrypt(ref const ubyte[16] input, ref ubyte[16] output) const
    {
        ubyte[16] s = input;
        add_round_key(s, rounds);
        for (uint r = rounds - 1; r >= 1; --r)
        {
            inv_shift_rows(s);
            inv_sub_bytes(s);
            add_round_key(s, r);
            inv_mix_columns(s);
        }
        inv_shift_rows(s);
        inv_sub_bytes(s);
        add_round_key(s, 0);
        output = s;
    }

private:
    void add_round_key(ref ubyte[16] s, uint r) const
    {
        foreach (i; 0 .. 16)
            s[i] ^= rk[r * 16 + i];
    }

    static void sub_bytes(ref ubyte[16] s)
    {
        foreach (ref b; s)
            b = sbox[b];
    }

    static void inv_sub_bytes(ref ubyte[16] s)
    {
        foreach (ref b; s)
            b = inv_sbox[b];
    }

    // state is column-major: s[c*4 + r]
    static void shift_rows(ref ubyte[16] s)
    {
        ubyte t;
        t = s[1];  s[1]  = s[5];  s[5]  = s[9];  s[9]  = s[13]; s[13] = t;
        t = s[2];  s[2]  = s[10]; s[10] = t;  t = s[6]; s[6] = s[14]; s[14] = t;
        t = s[15]; s[15] = s[11]; s[11] = s[7];  s[7]  = s[3];  s[3]  = t;
    }

    static void inv_shift_rows(ref ubyte[16] s)
    {
        ubyte t;
        t = s[13]; s[13] = s[9];  s[9]  = s[5];  s[5]  = s[1];  s[1]  = t;
        t = s[2];  s[2]  = s[10]; s[10] = t;  t = s[6]; s[6] = s[14]; s[14] = t;
        t = s[3];  s[3]  = s[7];  s[7]  = s[11]; s[11] = s[15]; s[15] = t;
    }

    static void mix_columns(ref ubyte[16] s)
    {
        foreach (c; 0 .. 4)
        {
            ubyte a0 = s[c*4], a1 = s[c*4+1], a2 = s[c*4+2], a3 = s[c*4+3];
            ubyte all = a0 ^ a1 ^ a2 ^ a3;
            s[c*4]   = cast(ubyte)(a0 ^ all ^ xtime(a0 ^ a1));
            s[c*4+1] = cast(ubyte)(a1 ^ all ^ xtime(a1 ^ a2));
            s[c*4+2] = cast(ubyte)(a2 ^ all ^ xtime(a2 ^ a3));
            s[c*4+3] = cast(ubyte)(a3 ^ all ^ xtime(a3 ^ a0));
        }
    }

    static void inv_mix_columns(ref ubyte[16] s)
    {
        foreach (c; 0 .. 4)
        {
            ubyte a0 = s[c*4], a1 = s[c*4+1], a2 = s[c*4+2], a3 = s[c*4+3];
            s[c*4]   = cast(ubyte)(mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9));
            s[c*4+1] = cast(ubyte)(mul(a0, 9)  ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13));
            s[c*4+2] = cast(ubyte)(mul(a0, 13) ^ mul(a1, 9)  ^ mul(a2, 14) ^ mul(a3, 11));
            s[c*4+3] = cast(ubyte)(mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9)  ^ mul(a3, 14));
        }
    }

    static ubyte xtime(uint x)
        => cast(ubyte)((x << 1) ^ ((x & 0x80) ? 0x1b : 0));

    static ubyte mul(ubyte a, ubyte b)
    {
        ubyte p = 0;
        while (b)
        {
            if (b & 1)
                p ^= a;
            a = xtime(a);
            b >>= 1;
        }
        return p;
    }
}

private immutable ubyte[256] sbox = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
];

private immutable ubyte[256] inv_sbox = () {
    ubyte[256] t;
    foreach (i; 0 .. 256)
        t[sbox[i]] = cast(ubyte)i;
    return t;
}();

unittest
{
    import urt.encoding : HexDecode;

    // FIPS-197 C.1 / C.2 / C.3
    static immutable ubyte[16] pt = HexDecode!"00112233445566778899aabbccddeeff";
    static void check(const(ubyte)[] key, ref const ubyte[16] expected)
    {
        AesSw a;
        assert(a.expand(key));
        ubyte[16] ct, back;
        a.encrypt(pt, ct);
        assert(ct == expected);
        a.decrypt(ct, back);
        assert(back == pt);
    }
    static immutable ubyte[16] k128 = HexDecode!"000102030405060708090a0b0c0d0e0f";
    static immutable ubyte[24] k192 = HexDecode!"000102030405060708090a0b0c0d0e0f1011121314151617";
    static immutable ubyte[32] k256 = HexDecode!"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    static immutable ubyte[16] c128 = HexDecode!"69c4e0d86a7b0430d8cdb78070b4c55a";
    static immutable ubyte[16] c192 = HexDecode!"dda97ca4864cdfe06eaf70a0ec0d7191";
    static immutable ubyte[16] c256 = HexDecode!"8ea2b7ca516745bfeafc49904b496089";
    check(k128[], c128);
    check(k192[], c192);
    check(k256[], c256);
}
