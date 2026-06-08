module urt.crypto.aes;

import urt.result;

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

    // STATUS_AUTH_TAG_MISMATCH — returned by BCryptDecrypt when GCM tag verification fails.
    private enum NTSTATUS STATUS_AUTH_TAG_MISMATCH = cast(NTSTATUS)0xC000A002;
}

nothrow @nogc:


// AES-GCM authenticated encryption. Writes ciphertext (length == plaintext.length)
// and the authentication tag.
//
// key: 16, 24, or 32 bytes (AES-128/192/256).
// iv:  any non-zero length; 12 bytes is the GCM-native size and the only one
//      that doesn't trigger the GHASH-based IV reduction.
// aad: associated data — authenticated but not encrypted; may be empty.
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
// 16/24/32 bytes. Returns unsupported when no AES backend is compiled in.
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
        return InternalResult.unsupported;
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
        return InternalResult.unsupported;
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
