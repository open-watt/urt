module urt.crypto.ecdh;

import urt.result;

version (MbedTLS)
    import urt.internal.mbedtls : urt_ecdh_p256_compute_shared;
else version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    pragma(lib, "Bcrypt");

    // druntime gates this behind NTDDI_WINBLUE; declare directly so it's available
    // regardless of the target's NTDDI_VERSION (the KDF itself works on Win8.1+).
    private enum wstring BCRYPT_KDF_RAW_SECRET = "TRUNCATE"w;
}

nothrow @nogc:


// ECDH P-256 shared-secret computation.
//
// priv_d:   32-byte big-endian private scalar.
// priv_xy:  64-byte own public key (X || Y, no leading 0x04). Required by the
//           Windows BCrypt backend, which cannot derive it from the private
//           scalar alone; the mbedtls backend ignores it. Callers tracking a
//           P-256 keypair already have both halves available.
// peer_xy:  64-byte peer public key (X || Y, no leading 0x04).
// shared_x: 32-byte output — big-endian X coordinate of (priv_d * peer_point).
Result ecdh_p256_compute_shared(const(ubyte)[] priv_d,
                                 const(ubyte)[] priv_xy,
                                 const(ubyte)[] peer_xy,
                                 ubyte[] shared_x)
{
    if (priv_d.length != 32 || peer_xy.length != 64 || shared_x.length != 32)
        return InternalResult.invalid_parameter;

    version (MbedTLS)
    {
        int ret = urt_ecdh_p256_compute_shared(
            priv_d.ptr, priv_d.length,
            peer_xy.ptr, peer_xy.length,
            shared_x.ptr);
        return ret == 0 ? Result.success : Result(cast(uint)ret);
    }
    else version (Windows)
    {
        if (priv_xy.length != 64)
            return InternalResult.invalid_parameter;

        BCRYPT_ALG_HANDLE halg;
        NTSTATUS status = BCryptOpenAlgorithmProvider(&halg, BCRYPT_ECDH_P256_ALGORITHM.ptr, null, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptCloseAlgorithmProvider(halg, 0);

        // BCRYPT_ECCKEY_BLOB: { Magic, cbKey=32 } then X[32] Y[32] d[32]
        ubyte[104] priv_blob = void;
        (cast(uint[])priv_blob[0 .. 8])[0] = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
        (cast(uint[])priv_blob[0 .. 8])[1] = 32;
        priv_blob[8 .. 40]   = priv_xy[0 .. 32];   // X
        priv_blob[40 .. 72]  = priv_xy[32 .. 64];  // Y
        priv_blob[72 .. 104] = priv_d[];           // d

        // BCRYPT_NO_KEY_VALIDATION skips BCrypt's d*G==(X,Y) consistency check.
        // Some Windows hosts reject otherwise-valid imports (observed with the
        // RFC 5903 P-256 test vector); the shared-secret math doesn't depend on
        // this check so bypassing it is safe for any caller that trusts its own d.
        enum uint BCRYPT_NO_KEY_VALIDATION = 0x00000008;

        BCRYPT_KEY_HANDLE hpriv;
        status = BCryptImportKeyPair(halg, null, BCRYPT_ECCPRIVATE_BLOB.ptr, &hpriv,
                                      priv_blob.ptr, priv_blob.length, BCRYPT_NO_KEY_VALIDATION);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptDestroyKey(hpriv);

        // public blob: { Magic, cbKey=32 } then X[32] Y[32]
        ubyte[72] pub_blob = void;
        (cast(uint[])pub_blob[0 .. 8])[0] = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
        (cast(uint[])pub_blob[0 .. 8])[1] = 32;
        pub_blob[8 .. 40]  = peer_xy[0 .. 32];
        pub_blob[40 .. 72] = peer_xy[32 .. 64];

        BCRYPT_KEY_HANDLE hpub;
        status = BCryptImportKeyPair(halg, null, BCRYPT_ECCPUBLIC_BLOB.ptr, &hpub,
                                      pub_blob.ptr, pub_blob.length, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptDestroyKey(hpub);

        BCRYPT_SECRET_HANDLE hsecret;
        status = BCryptSecretAgreement(hpriv, hpub, &hsecret, 0);
        if (status != 0)
            return Result(cast(uint)status);
        scope(exit) BCryptDestroySecret(hsecret);

        // BCRYPT_KDF_RAW_SECRET returns the X coord in LITTLE-endian byte order.
        // Everyone else (mbedtls, Tesla, NIST vectors) expects big-endian — reverse.
        ubyte[32] tmp = void;
        uint result_len;
        status = BCryptDeriveKey(hsecret, BCRYPT_KDF_RAW_SECRET.ptr, null,
                                  tmp.ptr, tmp.length, &result_len, 0);
        if (status != 0)
            return Result(cast(uint)status);

        foreach (i; 0 .. 32)
            shared_x[i] = tmp[31 - i];
        return Result.success;
    }
    else
        return InternalResult.unsupported;
}


unittest
{
    // RFC 5903 Section 8.1 (IKE Group 19, P-256) ECDH test vector
    import urt.encoding : HexDecode;

    auto i_priv = HexDecode!"c88f01f510d9ac3f70a292daa2316de544e9aab8afe84049c62a9c57862d1433";
    auto i_pub  = HexDecode!"dad0b65394221cf9b051e1feca57124565a55c5e3d6a66ac6ccb0ae69d5da873b6d1ac3639e83d2a35712f034cd7b62a0fab6671e51cc9b0d1d6f70f4a6ec3f5";
    auto r_pub  = HexDecode!"d12dfb5289c8d4f81208b70270398c342296970a0bccb74c736fc7554494bf6356fbf3ca366cc23e8157854c13c58d6aac23f046ada30f8353e74f33039872ab";
    auto expected_z = HexDecode!"d6840f6b42f6edafd13116e0e12565202fef8e9ece7dce03812464d04b9442de";

    ubyte[32] shared_secret;
    auto r = ecdh_p256_compute_shared(i_priv[], i_pub[], r_pub[], shared_secret[]);
    assert(r.succeeded);
    assert(shared_secret == expected_z);
}
