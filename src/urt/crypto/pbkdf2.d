module urt.crypto.pbkdf2;

import urt.digest.hmac : HMACContext, hmac_init, hmac_update, hmac_finalise;
import urt.digest.sha : SHA1Context;
import urt.result : Result, InternalResult;

nothrow @nogc:


// PBKDF2-HMAC-SHA1 as used by WPA/WPA2-PSK to derive the 32-byte PMK from
// passphrase + SSID. The interface is generic over output length so callers can
// also use the standard test vectors without heap allocation.
Result pbkdf2_hmac_sha1(const(ubyte)[] passphrase,
                        const(ubyte)[] salt,
                        uint iterations,
                        ubyte[] output)
{
    Pbkdf2Sha1 kdf;
    Result r = kdf.begin(passphrase, salt, iterations, output);
    if (r.failed)
        return r;
    kdf.step(uint.max);
    return Result.success;
}

// Resumable PBKDF2-HMAC-SHA1: the 4096 WPA2 iterations are ~1.7s on a 120MHz ARM9, so
// callers that cannot stall slice it with step(). passphrase, salt and output must stay
// valid until done.
struct Pbkdf2Sha1
{
nothrow @nogc:
    Result begin(const(ubyte)[] passphrase, const(ubyte)[] salt, uint iterations, ubyte[] output)
    {
        if (passphrase.length == 0 || salt.length == 0 || iterations == 0 || output.length == 0)
            return InternalResult.invalid_parameter;
        _passphrase = passphrase;
        _salt = salt;
        _iterations = iterations;
        _output = output;
        _pos = 0;
        _counter = 0;
        _iter = 0;
        _done = false;
        return Result.success;
    }

    bool done() const pure
        => _done;

    // Runs at most max_iterations HMAC rounds; returns true once the whole output is derived.
    bool step(uint max_iterations)
    {
        while (!_done)
        {
            if (_iter != 0 && _iter >= _iterations)
            {
                size_t n = _output.length - _pos;
                if (n > _block.length)
                    n = _block.length;
                _output[_pos .. _pos + n] = _block[0 .. n];
                _pos += n;
                _iter = 0;
                if (_pos >= _output.length)
                    _done = true;
                continue;
            }
            if (!max_iterations)
                break;

            if (_iter == 0)
            {
                ++_counter;
                ubyte[4] counter_be = void;
                counter_be[0] = cast(ubyte)(_counter >> 24);
                counter_be[1] = cast(ubyte)(_counter >> 16);
                counter_be[2] = cast(ubyte)(_counter >> 8);
                counter_be[3] = cast(ubyte)_counter;

                HMACContext!SHA1Context h;
                hmac_init(h, _passphrase);
                hmac_update(h, _salt);
                hmac_update(h, counter_be[]);
                _u = hmac_finalise(h);
                _block[] = _u[];
                _iter = 1;
                --max_iterations;
                continue;
            }

            HMACContext!SHA1Context h;
            hmac_init(h, _passphrase);
            hmac_update(h, _u[]);
            _u = hmac_finalise(h);
            foreach (i; 0 .. _block.length)
                _block[i] ^= _u[i];
            ++_iter;
            --max_iterations;
        }
        return _done;
    }

private:
    const(ubyte)[] _passphrase;
    const(ubyte)[] _salt;
    ubyte[] _output;
    uint _iterations;
    uint _counter;
    uint _iter;
    size_t _pos;
    bool _done;
    ubyte[SHA1Context.DigestLen] _u = void;
    ubyte[SHA1Context.DigestLen] _block = void;
}

Result wpa2_psk_to_pmk(const(char)[] passphrase,
                       const(char)[] ssid,
                       ubyte[] pmk)
{
    if (passphrase.length < 8 || passphrase.length > 63 || ssid.length == 0 || ssid.length > 32 ||
        pmk.length != 32)
        return InternalResult.invalid_parameter;

    return pbkdf2_hmac_sha1(cast(const(ubyte)[])passphrase,
                            cast(const(ubyte)[])ssid,
                            4096,
                            pmk);
}


unittest
{
    // sliced derivation must equal the one-shot result, whatever the slice size
    ubyte[32] whole, sliced;
    assert(pbkdf2_hmac_sha1(cast(const(ubyte)[])"passphrase", cast(const(ubyte)[])"ssid", 100, whole[]));
    Pbkdf2Sha1 kdf;
    assert(kdf.begin(cast(const(ubyte)[])"passphrase", cast(const(ubyte)[])"ssid", 100, sliced[]));
    uint calls;
    while (!kdf.step(7))
        ++calls;
    assert(calls > 10);
    assert(sliced == whole);

    // an exact budget finishes without a further call: 2 blocks x 100 rounds
    ubyte[32] exact;
    assert(kdf.begin(cast(const(ubyte)[])"passphrase", cast(const(ubyte)[])"ssid", 100, exact[]));
    assert(kdf.step(200));
    assert(exact == whole);

    ubyte[20] out1;
    assert(pbkdf2_hmac_sha1(cast(const(ubyte)[])"password",
                            cast(const(ubyte)[])"salt",
                            1,
                            out1[]));
    static immutable ubyte[20] expected1 = [
        0x0c, 0x60, 0xc8, 0x0f, 0x96, 0x1f, 0x0e, 0x71, 0xf3, 0xa9,
        0xb5, 0x24, 0xaf, 0x60, 0x12, 0x06, 0x2f, 0xe0, 0x37, 0xa6,
    ];
    assert(out1 == expected1);

    ubyte[20] out2;
    assert(pbkdf2_hmac_sha1(cast(const(ubyte)[])"password",
                            cast(const(ubyte)[])"salt",
                            2,
                            out2[]));
    static immutable ubyte[20] expected2 = [
        0xea, 0x6c, 0x01, 0x4d, 0xc7, 0x2d, 0x6f, 0x8c, 0xcd, 0x1e,
        0xd9, 0x2a, 0xce, 0x1d, 0x41, 0xf0, 0xd8, 0xde, 0x89, 0x57,
    ];
    assert(out2 == expected2);
}
