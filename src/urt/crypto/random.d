module urt.crypto.random;

import urt.result;

version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    pragma(lib, "Bcrypt");
}
else version (Espressif)
{
    // use the ESP-IDF hardware RNG
}
else version (Posix)
{
    import urt.internal.mbedtls;
}

nothrow @nogc:


Result crypto_random_bytes(ubyte[] dst)
{
    if (dst.length == 0)
        return Result.success;

    version (Windows)
    {
        NTSTATUS status = BCryptGenRandom(null, dst.ptr, cast(uint)dst.length, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        return status == 0 ? Result.success : Result(cast(uint)status);
    }
    else version (Espressif)
    {
        esp_fill_random(dst.ptr, dst.length);
        return Result.success;
    }
    else version (Posix)
    {
        auto rng = get_rng();
        if (rng is null)
            return InternalResult.failed;
        int ret = mbedtls_ctr_drbg_random(rng, dst.ptr, dst.length);
        return ret == 0 ? Result.success : Result(cast(uint)ret);
    }
    else
        return InternalResult.unsupported;
}


version (Posix)
{
    // Lazily-initialised process-global CTR-DRBG seeded from mbedtls_entropy.
    // Exposed so primitives that need an mbedtls (f_rng, p_rng) callback pair
    // (pk_sign, ecdh_calc_secret, etc.) can reuse the same RNG.
    mbedtls_ctr_drbg_context* get_rng()
    {
        __gshared mbedtls_ctr_drbg_context* rng;
        __gshared mbedtls_entropy_context* entropy;
        __gshared bool initialised;

        if (initialised)
            return rng;

        entropy = urt_entropy_new();
        if (entropy is null)
            return null;

        rng = urt_ctr_drbg_new();
        if (rng is null)
        {
            urt_entropy_delete(entropy);
            entropy = null;
            return null;
        }

        int ret = mbedtls_ctr_drbg_seed(rng, &mbedtls_entropy_func, cast(void*)entropy, null, 0);
        if (ret != 0)
        {
            urt_ctr_drbg_delete(rng);
            urt_entropy_delete(entropy);
            rng = null;
            entropy = null;
            return null;
        }

        initialised = true;
        return rng;
    }
}


private:

// classic ESP32 only: esp_fill_random is cryptographically strong only while the WiFi/BT radio is active
//                     pre-radio callers must bracket with bootloader_random_enable/disable!
version (Espressif)
{
    extern(C) void esp_fill_random(void* buf, size_t len) nothrow @nogc;
}
