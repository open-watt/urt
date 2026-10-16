module urt.crypto.spake2p;

import urt.crypto.hkdf;
import urt.crypto.p256;
import urt.crypto.pbkdf2;
import urt.crypto.random;
import urt.digest.hmac;
import urt.digest.sha;

nothrow @nogc:


// SPAKE2+-P256-SHA256-HKDF-SHA256-HMAC-SHA256 (RFC 9383) with the Matter profile:
// empty identities, 8-byte little-endian length prefixes, w0/w1 from PBKDF2 over the
// little-endian passcode.

enum spake2p_share_length = 65;
enum spake2p_confirm_length = 32;

struct Spake2pVerifier
{
    U256 w0;
    P256Point l;

nothrow @nogc:
    void to_bytes(ubyte[] out_bytes) const pure
    {
        w0.to_bytes(out_bytes[0 .. 32]);
        l.to_bytes(out_bytes[32 .. 97]);
    }

    bool from_bytes(const(ubyte)[] bytes) pure
    {
        if (bytes.length != 97)
            return false;
        w0 = U256.from_bytes(bytes[0 .. 32]);
        return w0 < p256_n && l.from_bytes(bytes[32 .. 97]);
    }
}

bool spake2p_derive_w0_w1(uint passcode, const(ubyte)[] salt, uint iterations, out U256 w0, out U256 w1)
{
    ubyte[4] pin = void;
    foreach (i; 0 .. 4)
        pin[i] = cast(ubyte)(passcode >> (8*i));
    ubyte[80] ws = void;
    if (!pbkdf2_hmac_sha256(pin[], salt, iterations, ws[]))
        return false;
    w0 = mod_reduce(ws[0 .. 40], p256_n);
    w1 = mod_reduce(ws[40 .. 80], p256_n);
    return true;
}

bool spake2p_derive_verifier(uint passcode, const(ubyte)[] salt, uint iterations, out Spake2pVerifier verifier)
{
    U256 w1;
    if (!spake2p_derive_w0_w1(passcode, salt, iterations, verifier.w0, w1))
        return false;
    P256Point g = P256Point.generator();
    verifier.l = point_mul(w1, g);
    return true;
}


struct Spake2p
{
nothrow @nogc:
    bool begin_prover(ref const U256 w0, ref const U256 w1, const(ubyte)[] context)
    {
        _prover = true;
        _w0 = w0;
        _w1 = w1;
        return begin(context, spake2p_m());
    }

    bool begin_verifier(ref const Spake2pVerifier verifier, const(ubyte)[] context)
    {
        _prover = false;
        _w0 = verifier.w0;
        _l = verifier.l;
        return begin(context, spake2p_n());
    }

    const(ubyte)[] share() const pure
        => _share[];

    bool finish(const(ubyte)[] peer_share)
    {
        if (peer_share.length != spake2p_share_length)
            return false;
        P256Point peer;
        if (!peer.from_bytes(peer_share))
            return false;
        _peer[] = peer_share[];

        // strip the peer's mask: prover removes w0*N, verifier removes w0*M
        P256Point mask = _prover ? spake2p_n() : spake2p_m();
        P256Point w0mask = point_mul(_w0, mask);
        P256Point neg = point_neg(w0mask);
        P256Point unmasked = point_add(peer, neg);

        P256Point z = point_mul(_scalar, unmasked);
        P256Point v = _prover ? point_mul(_w1, unmasked) : point_mul(_scalar, _l);
        if (z.infinity || v.infinity)
            return false;

        ubyte[65] m_bytes = void, n_bytes = void, z_bytes = void, v_bytes = void, w0_bytes = void;
        spake2p_m().to_bytes(m_bytes[]);
        spake2p_n().to_bytes(n_bytes[]);
        z.to_bytes(z_bytes[]);
        v.to_bytes(v_bytes[]);
        _w0.to_bytes(w0_bytes[0 .. 32]);

        absorb(_tt, null);
        absorb(_tt, null);
        absorb(_tt, m_bytes[]);
        absorb(_tt, n_bytes[]);
        absorb(_tt, _prover ? _share[] : _peer[]);
        absorb(_tt, _prover ? _peer[] : _share[]);
        absorb(_tt, z_bytes[]);
        absorb(_tt, v_bytes[]);
        absorb(_tt, w0_bytes[0 .. 32]);
        ubyte[32] k = sha_finalise(_tt);
        ke[] = k[16 .. 32];

        ubyte[32] kc = void;
        if (!hkdf_sha256(null, k[0 .. 16], "ConfirmationKeys", kc[]))
            return false;

        const(ubyte)[] kca = kc[0 .. 16];
        const(ubyte)[] kcb = kc[16 .. 32];
        ubyte[32] ca = hmac!SHA256Context(kca, _prover ? _peer[] : _share[]);
        ubyte[32] cb = hmac!SHA256Context(kcb, _prover ? _share[] : _peer[]);
        _own_confirm = _prover ? ca : cb;
        _peer_confirm = _prover ? cb : ca;
        _finished = true;
        return true;
    }

    const(ubyte)[] confirm() const pure
        => _own_confirm[];

    bool verify(const(ubyte)[] peer_confirm) const pure
    {
        if (!_finished || peer_confirm.length != spake2p_confirm_length)
            return false;
        ubyte diff = 0;
        foreach (i; 0 .. 32)
            diff |= peer_confirm[i] ^ _peer_confirm[i];
        return diff == 0;
    }

    ubyte[16] ke;

private:
    bool _prover;
    bool _finished;
    U256 _w0;
    U256 _w1;
    U256 _scalar;
    P256Point _l;
    ubyte[65] _share;
    ubyte[65] _peer;
    ubyte[32] _own_confirm;
    ubyte[32] _peer_confirm;
    SHA256Context _tt;

    bool begin(const(ubyte)[] context, P256Point mask)
    {
        _finished = false;
        sha_init(_tt);
        absorb(_tt, context);

        ubyte[32] rnd = void;
        do
        {
            if (crypto_random_bytes(rnd[]).failed)
                return false;
            _scalar = mod_reduce(rnd[], p256_n);
        }
        while (_scalar.is_zero);

        P256Point g = P256Point.generator();
        P256Point xg = point_mul(_scalar, g);
        P256Point w0m = point_mul(_w0, mask);
        P256Point s = point_add(xg, w0m);
        if (s.infinity)
            return false;
        s.to_bytes(_share[]);
        return true;
    }
}


P256Point spake2p_m()
{
    static immutable ubyte[33] m = [
        0x02, 0x88, 0x6e, 0x2f, 0x97, 0xac, 0xe4, 0x6e, 0x55, 0xba, 0x9d, 0xd7, 0x24, 0x25, 0x79, 0xf2,
        0x99, 0x3b, 0x64, 0xe1, 0x6e, 0xf3, 0xdc, 0xab, 0x95, 0xaf, 0xd4, 0x97, 0x33, 0x3d, 0x8f, 0xa1, 0x2f,
    ];
    return decompress(m);
}

P256Point spake2p_n()
{
    static immutable ubyte[33] n = [
        0x03, 0xd8, 0xbb, 0xd6, 0xc6, 0x39, 0xc6, 0x29, 0x37, 0xb0, 0x4d, 0x99, 0x7f, 0x38, 0xc3, 0x77,
        0x07, 0x19, 0xc6, 0x29, 0xd7, 0x01, 0x4d, 0x49, 0xa2, 0x4b, 0x4f, 0x98, 0xba, 0xa1, 0x29, 0x2b, 0x49,
    ];
    return decompress(n);
}


private:

void absorb(ref SHA256Context ctx, const(ubyte)[] data)
{
    ubyte[8] len = void;
    foreach (i; 0 .. 8)
        len[i] = cast(ubyte)(cast(ulong)data.length >> (8*i));
    sha_update(ctx, len[]);
    if (data.length)
        sha_update(ctx, data);
}

immutable U256 p256_sqrt_exp = U256([0x00000000, 0x00000000, 0x40000000, 0x00000000, 0x00000000, 0x40000000, 0xC0000000, 0x3FFFFFFF]);

P256Point decompress(ref const ubyte[33] sec1)
{
    P256Point r;
    r.x = U256.from_bytes(sec1[1 .. 33]);
    U256 x2 = mod_mul(r.x, r.x, p256_p);
    U256 rhs = mod_mul(x2, r.x, p256_p);
    U256 ax = mod_mul(p256_a, r.x, p256_p);
    rhs = mod_add(rhs, ax, p256_p);
    rhs = mod_add(rhs, p256_b, p256_p);
    r.y = mod_pow(rhs, p256_sqrt_exp, p256_p);
    if ((r.y.limb[0] & 1) != (sec1[0] & 1))
    {
        U256 zero;
        r.y = mod_sub(zero, r.y, p256_p);
    }
    r.infinity = false;
    return r;
}


unittest
{
    P256Point m = spake2p_m();
    P256Point n = spake2p_n();
    assert(m.on_curve() && n.on_curve());
    assert((m.y.limb[0] & 1) == 0);
    assert((n.y.limb[0] & 1) == 1);

    // Matter test PIN and a fixed salt; prover and verifier must agree
    static immutable ubyte[16] salt = [
        0x53, 0x50, 0x41, 0x4b, 0x45, 0x32, 0x50, 0x20, 0x4b, 0x65, 0x79, 0x20, 0x53, 0x61, 0x6c, 0x74,
    ];
    U256 w0, w1;
    assert(spake2p_derive_w0_w1(20202021, salt[], 1000, w0, w1));
    assert(!w0.is_zero && !w1.is_zero && w0 < p256_n && w1 < p256_n);

    Spake2pVerifier verifier;
    assert(spake2p_derive_verifier(20202021, salt[], 1000, verifier));
    assert(verifier.w0 == w0);
    P256Point g = P256Point.generator();
    assert(verifier.l == point_mul(w1, g));

    ubyte[97] vbytes;
    verifier.to_bytes(vbytes[]);
    Spake2pVerifier back;
    assert(back.from_bytes(vbytes[]));
    assert(back.w0 == verifier.w0 && back.l == verifier.l);

    static immutable ubyte[8] context = [1, 2, 3, 4, 5, 6, 7, 8];
    Spake2p prover, device;
    assert(prover.begin_prover(w0, w1, context[]));
    assert(device.begin_verifier(verifier, context[]));
    assert(prover.share() != device.share());

    assert(device.finish(prover.share()));
    assert(prover.finish(device.share()));
    assert(prover.ke == device.ke);
    assert(device.verify(prover.confirm()));
    assert(prover.verify(device.confirm()));
    assert(!prover.verify(prover.confirm()));

    // wrong passcode on the prover side fails confirmation
    U256 bad_w0, bad_w1;
    assert(spake2p_derive_w0_w1(20202020, salt[], 1000, bad_w0, bad_w1));
    Spake2p bad, device2;
    assert(bad.begin_prover(bad_w0, bad_w1, context[]));
    assert(device2.begin_verifier(verifier, context[]));
    assert(device2.finish(bad.share()));
    assert(bad.finish(device2.share()));
    assert(!device2.verify(bad.confirm()));
    assert(!bad.verify(device2.confirm()));
}
