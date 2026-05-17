module urt.crypto.random;

import urt.result;

version (Espressif)
{
    // use the hardware RNG peripheral on ESP32
}
else version (MbedTLS)
{
    import urt.internal.mbedtls;
}
else version (Windows)
{
    import core.sys.windows.bcrypt;
    import core.sys.windows.ntdef : NTSTATUS;
    pragma(lib, "Bcrypt");
}

nothrow @nogc:


Result crypto_random_bytes(ubyte[] dst)
{
    if (dst.length == 0)
        return Result.success;

    version (Espressif)
    {
        esp_fill_random(dst.ptr, dst.length);
        return Result.success;
    }
    else version (MbedTLS)
    {
        int ret = urt_rng_random(dst.ptr, dst.length);
        return ret == 0 ? Result.success : Result(cast(uint)ret);
    }
    else version (Windows)
    {
        NTSTATUS status = BCryptGenRandom(null, dst.ptr, cast(uint)dst.length, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        return status == 0 ? Result.success : Result(cast(uint)status);
    }
    else
        return InternalResult.unsupported;
}


private:

// classic ESP32 only: esp_fill_random is cryptographically strong only while the WiFi/BT radio is active
//                     pre-radio callers must bracket with bootloader_random_enable/disable!
version (Espressif)
{
    extern(C) void esp_fill_random(void* buf, size_t len) nothrow @nogc;
}
