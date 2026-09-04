module urt.crypto.ecdsa;

import urt.crypto.p256;
import urt.digest.hmac;
import urt.digest.sha;

nothrow @nogc:


// Portable ECDSA P-256 / SHA-256 on urt.crypto.p256. Signatures are raw r || s (64 bytes).
// Nonces are RFC 6979 deterministic so signing needs no RNG. Not constant-time.

bool ecdsa_p256_verify(const(ubyte)[] public_key, const(ubyte)[] hash, const(ubyte)[] signature)
{
    if (hash.length != 32 || signature.length != 64)
        return false;
    P256Point q;
    if (!q.from_bytes(public_key))
        return false;

    U256 r = U256.from_bytes(signature[0 .. 32]);
    U256 s = U256.from_bytes(signature[32 .. 64]);
    if (r.is_zero || s.is_zero || !(r < p256_n) || !(s < p256_n))
        return false;

    U256 e = mod_reduce(hash, p256_n);
    U256 w = mod_inv(s, p256_n);
    U256 u1 = mod_mul(e, w, p256_n);
    U256 u2 = mod_mul(r, w, p256_n);
    P256Point g = P256Point.generator();
    P256Point a = point_mul(u1, g);
    P256Point b = point_mul(u2, q);
    P256Point p = point_add(a, b);
    if (p.infinity)
        return false;
    U256 x = mod_reduce_field(p.x);
    return x == r;
}

bool ecdsa_p256_sign(const(ubyte)[] private_key, const(ubyte)[] hash, ubyte[] signature)
{
    if (private_key.length != 32 || hash.length != 32 || signature.length != 64)
        return false;
    U256 d = U256.from_bytes(private_key);
    if (d.is_zero || !(d < p256_n))
        return false;
    U256 e = mod_reduce(hash, p256_n);
    P256Point g = P256Point.generator();

    Rfc6979 nonce;
    nonce.init(private_key, hash);
    foreach (attempt; 0 .. 64)
    {
        U256 k;
        if (!nonce.next(k))
            continue;
        P256Point kg = point_mul(k, g);
        if (kg.infinity)
            continue;
        U256 r = mod_reduce_field(kg.x);
        if (r.is_zero)
            continue;
        U256 kinv = mod_inv(k, p256_n);
        U256 rd = mod_mul(r, d, p256_n);
        U256 sum = mod_add(e, rd, p256_n);
        U256 s = mod_mul(kinv, sum, p256_n);
        if (s.is_zero)
            continue;
        r.to_bytes(signature[0 .. 32]);
        s.to_bytes(signature[32 .. 64]);
        return true;
    }
    return false;
}

bool ecdsa_p256_public_key(const(ubyte)[] private_key, ubyte[] public_key)
{
    if (private_key.length != 32 || public_key.length != 65)
        return false;
    U256 d = U256.from_bytes(private_key);
    if (d.is_zero || !(d < p256_n))
        return false;
    P256Point g = P256Point.generator();
    P256Point q = point_mul(d, g);
    if (q.infinity)
        return false;
    q.to_bytes(public_key);
    return true;
}


private:

// x is already < p; reduce mod n for the r computation.
U256 mod_reduce_field(ref const U256 x) pure
{
    ubyte[32] be = void;
    x.to_bytes(be[]);
    return mod_reduce(be[], p256_n);
}

struct Rfc6979
{
nothrow @nogc:
    void init(const(ubyte)[] private_key, const(ubyte)[] hash)
    {
        ubyte[32] h1 = void;
        U256 e = mod_reduce(hash, p256_n);
        e.to_bytes(h1[]);

        _v[] = 0x01;
        _k[] = 0x00;
        step(0x00, private_key, h1[]);
        _v = hmac!SHA256Context(_k[], _v[]);
        step(0x01, private_key, h1[]);
        _v = hmac!SHA256Context(_k[], _v[]);
    }

    bool next(out U256 k)
    {
        if (_used)
        {
            step(0x00, null, null);
            _v = hmac!SHA256Context(_k[], _v[]);
        }
        _used = true;
        _v = hmac!SHA256Context(_k[], _v[]);
        k = U256.from_bytes(_v[]);
        return !k.is_zero && k < p256_n;
    }

private:
    ubyte[32] _v;
    ubyte[32] _k;
    bool _used;

    void step(ubyte sep, const(ubyte)[] x, const(ubyte)[] h1)
    {
        HMACContext!SHA256Context h;
        hmac_init(h, _k[]);
        hmac_update(h, _v[]);
        hmac_update(h, (&sep)[0 .. 1]);
        if (x.length)
        {
            hmac_update(h, x);
            hmac_update(h, h1);
        }
        _k = hmac_finalise(h);
    }
}


unittest
{
    // RFC 6979 A.2.5, P-256 with SHA-256, message "sample"
    static immutable ubyte[32] priv = [
        0xC9, 0xAF, 0xA9, 0xD8, 0x45, 0xBA, 0x75, 0x16, 0x6B, 0x5C, 0x21, 0x57, 0x67, 0xB1, 0xD6, 0x93,
        0x4E, 0x50, 0xC3, 0xDB, 0x36, 0xE8, 0x9B, 0x12, 0x7B, 0x8A, 0x62, 0x2B, 0x12, 0x0F, 0x67, 0x21,
    ];
    static immutable ubyte[64] expected_sig = [
        0xEF, 0xD4, 0x8B, 0x2A, 0xAC, 0xB6, 0xA8, 0xFD, 0x11, 0x40, 0xDD, 0x9C, 0xD4, 0x5E, 0x81, 0xD6,
        0x9D, 0x2C, 0x87, 0x7B, 0x56, 0xAA, 0xF9, 0x91, 0xC3, 0x4D, 0x0E, 0xA8, 0x4E, 0xAF, 0x37, 0x16,
        0xF7, 0xCB, 0x1C, 0x94, 0x2D, 0x65, 0x7C, 0x41, 0xD4, 0x36, 0xC7, 0xA1, 0xB6, 0xE2, 0x9F, 0x65,
        0xF3, 0xE9, 0x00, 0xDB, 0xB9, 0xAF, 0xF4, 0x06, 0x4D, 0xC4, 0xAB, 0x2F, 0x84, 0x3A, 0xCD, 0xA8,
    ];

    SHA256Context ctx;
    sha_init(ctx);
    sha_update(ctx, "sample");
    ubyte[32] hash = sha_finalise(ctx);

    ubyte[65] pub;
    assert(ecdsa_p256_public_key(priv[], pub[]));
    assert(pub[1] == 0x60 && pub[2] == 0xFE && pub[3] == 0xD4);

    ubyte[64] sig;
    assert(ecdsa_p256_sign(priv[], hash[], sig[]));
    assert(sig == expected_sig);
    assert(ecdsa_p256_verify(pub[], hash[], sig[]));

    sig[10] ^= 1;
    assert(!ecdsa_p256_verify(pub[], hash[], sig[]));
    sig[10] ^= 1;
    hash[0] ^= 1;
    assert(!ecdsa_p256_verify(pub[], hash[], sig[]));
}
