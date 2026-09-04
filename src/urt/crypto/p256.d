module urt.crypto.p256;

nothrow @nogc:


// Portable P-256 (secp256r1) group arithmetic for protocols that need raw point operations
// (SPAKE2+, key validation). Not constant-time; do not use for long-lived private scalars.

struct U256
{
    uint[8] limb;

nothrow @nogc:
    static U256 from_bytes(const(ubyte)[] be) pure
    {
        U256 r;
        if (be.length > 32)
            return r;
        foreach (i, b; be)
        {
            size_t bit = (be.length - 1 - i) * 8;
            r.limb[bit / 32] |= cast(uint)b << (bit & 31);
        }
        return r;
    }

    void to_bytes(ubyte[] be) const pure
    {
        be[] = 0;
        foreach (i; 0 .. 32)
        {
            if (i < be.length)
                be[be.length - 1 - i] = cast(ubyte)(limb[i / 4] >> (8*(i & 3)));
        }
    }

    bool is_zero() const pure
    {
        uint acc = 0;
        foreach (l; limb)
            acc |= l;
        return acc == 0;
    }

    bool bit(size_t i) const pure
        => ((limb[i / 32] >> (i & 31)) & 1) != 0;

    bool opEquals(const U256 rh) const pure
        => limb == rh.limb;

    int opCmp(ref const U256 rh) const pure
    {
        foreach_reverse (i; 0 .. 8)
        {
            if (limb[i] != rh.limb[i])
                return limb[i] < rh.limb[i] ? -1 : 1;
        }
        return 0;
    }
}

struct P256Point
{
    U256 x;
    U256 y;
    bool infinity = true;

nothrow @nogc:
    static P256Point generator() pure
        => P256Point(p256_gx, p256_gy, false);

    bool opEquals(const P256Point rh) const pure
        => infinity == rh.infinity && (infinity || (x == rh.x && y == rh.y));

    // 65-byte uncompressed SEC1 encoding.
    bool from_bytes(const(ubyte)[] sec1) pure
    {
        if (sec1.length != 65 || sec1[0] != 0x04)
            return false;
        x = U256.from_bytes(sec1[1 .. 33]);
        y = U256.from_bytes(sec1[33 .. 65]);
        infinity = false;
        return x < p256_p && y < p256_p && on_curve();
    }

    void to_bytes(ubyte[] sec1) const pure
    {
        sec1[0] = 0x04;
        x.to_bytes(sec1[1 .. 33]);
        y.to_bytes(sec1[33 .. 65]);
    }

    bool on_curve() const pure
    {
        if (infinity)
            return false;
        U256 lhs = mod_mul(y, y, p256_p);
        U256 x2 = mod_mul(x, x, p256_p);
        U256 rhs = mod_mul(x2, x, p256_p);
        U256 ax = mod_mul(p256_a, x, p256_p);
        rhs = mod_add(rhs, ax, p256_p);
        rhs = mod_add(rhs, p256_b, p256_p);
        return lhs == rhs;
    }
}

immutable U256 p256_p = U256([0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]);
immutable U256 p256_n = U256([0xFC632551, 0xF3B9CAC2, 0xA7179E84, 0xBCE6FAAD, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0xFFFFFFFF]);
immutable U256 p256_a = U256([0xFFFFFFFC, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0xFFFFFFFF]);
immutable U256 p256_b = U256([0x27D2604B, 0x3BCE3C3E, 0xCC53B0F6, 0x651D06B0, 0x769886BC, 0xB3EBBD55, 0xAA3A93E7, 0x5AC635D8]);
immutable U256 p256_gx = U256([0xD898C296, 0xF4A13945, 0x2DEB33A0, 0x77037D81, 0x63A440F2, 0xF8BCE6E5, 0xE12C4247, 0x6B17D1F2]);
immutable U256 p256_gy = U256([0x37BF51F5, 0xCBB64068, 0x6B315ECE, 0x2BCE3357, 0x7C0F9E16, 0x8EE7EB4A, 0xFE1A7F9B, 0x4FE342E2]);


U256 mod_add(ref const U256 a, ref const U256 b, ref const U256 m) pure
{
    U256 r;
    ulong carry = 0;
    foreach (i; 0 .. 8)
    {
        carry += cast(ulong)a.limb[i] + b.limb[i];
        r.limb[i] = cast(uint)carry;
        carry >>= 32;
    }
    if (carry || !(r < m))
        sub_in_place(r, m);
    return r;
}

U256 mod_sub(ref const U256 a, ref const U256 b, ref const U256 m) pure
{
    U256 r = a;
    if (a < b)
        add_in_place(r, m);
    sub_in_place(r, b);
    return r;
}

U256 mod_mul(ref const U256 a, ref const U256 b, ref const U256 m) pure
{
    U256 r;
    foreach_reverse (i; 0 .. 256)
    {
        r = mod_add(r, r, m);
        if (a.bit(i))
            r = mod_add(r, b, m);
    }
    return r;
}

U256 mod_pow(ref const U256 a, ref const U256 e, ref const U256 m) pure
{
    U256 r;
    r.limb[0] = 1;
    foreach_reverse (i; 0 .. 256)
    {
        r = mod_mul(r, r, m);
        if (e.bit(i))
            r = mod_mul(r, a, m);
    }
    return r;
}

U256 mod_inv(ref const U256 a, ref const U256 m) pure
{
    U256 e = m;
    e.limb[0] -= 2;
    return mod_pow(a, e, m);
}

U256 mod_reduce(const(ubyte)[] be, ref const U256 m) pure
{
    U256 r;
    foreach (b; be)
    {
        foreach_reverse (i; 0 .. 8)
        {
            r = mod_add(r, r, m);
            if ((b >> i) & 1)
            {
                U256 one;
                one.limb[0] = 1;
                r = mod_add(r, one, m);
            }
        }
    }
    return r;
}


P256Point point_add(ref const P256Point p, ref const P256Point q) pure
{
    if (p.infinity)
        return q;
    if (q.infinity)
        return p;
    if (p.x == q.x)
    {
        if (p.y == q.y)
            return point_double(p);
        return P256Point.init;
    }
    U256 dx = mod_sub(q.x, p.x, p256_p);
    U256 dy = mod_sub(q.y, p.y, p256_p);
    U256 inv = mod_inv(dx, p256_p);
    U256 lambda = mod_mul(dy, inv, p256_p);
    return finish_add(p, q, lambda);
}

P256Point point_double(ref const P256Point p) pure
{
    if (p.infinity || p.y.is_zero)
        return P256Point.init;
    U256 x2 = mod_mul(p.x, p.x, p256_p);
    U256 num = mod_add(x2, x2, p256_p);
    num = mod_add(num, x2, p256_p);
    num = mod_add(num, p256_a, p256_p);
    U256 den = mod_add(p.y, p.y, p256_p);
    U256 inv = mod_inv(den, p256_p);
    U256 lambda = mod_mul(num, inv, p256_p);
    return finish_add(p, p, lambda);
}

P256Point point_neg(ref const P256Point p) pure
{
    if (p.infinity)
        return p;
    U256 zero;
    return P256Point(p.x, mod_sub(zero, p.y, p256_p), false);
}

P256Point point_mul(ref const U256 k, ref const P256Point p) pure
{
    P256Point r;
    foreach_reverse (i; 0 .. 256)
    {
        r = point_double(r);
        if (k.bit(i))
            r = point_add(r, p);
    }
    return r;
}


private:

P256Point finish_add(ref const P256Point p, ref const P256Point q, ref const U256 lambda) pure
{
    U256 l2 = mod_mul(lambda, lambda, p256_p);
    U256 x3 = mod_sub(l2, p.x, p256_p);
    x3 = mod_sub(x3, q.x, p256_p);
    U256 t = mod_sub(p.x, x3, p256_p);
    U256 y3 = mod_mul(lambda, t, p256_p);
    y3 = mod_sub(y3, p.y, p256_p);
    return P256Point(x3, y3, false);
}

void add_in_place(ref U256 r, ref const U256 b) pure
{
    ulong carry = 0;
    foreach (i; 0 .. 8)
    {
        carry += cast(ulong)r.limb[i] + b.limb[i];
        r.limb[i] = cast(uint)carry;
        carry >>= 32;
    }
}

void sub_in_place(ref U256 r, ref const U256 b) pure
{
    long borrow = 0;
    foreach (i; 0 .. 8)
    {
        borrow += cast(long)r.limb[i] - b.limb[i];
        r.limb[i] = cast(uint)borrow;
        borrow >>= 32;
    }
}


unittest
{
    P256Point g = P256Point.generator();
    assert(g.on_curve());

    U256 two;
    two.limb[0] = 2;
    U256 three;
    three.limb[0] = 3;

    static immutable U256 g2x = U256([0x47669978, 0xA60B48FC, 0x77F21B35, 0xC08969E2, 0x04B51AC3, 0x8A523803, 0x8D034F7E, 0x7CF27B18]);
    static immutable U256 g2y = U256([0x227873D1, 0x9E04B79D, 0x3CE98229, 0xBA7DADE6, 0x9F7430DB, 0x293D9AC6, 0xDB8ED040, 0x07775510]);
    static immutable U256 g3x = U256([0xC6E7FD6C, 0xFB41661B, 0xEFADA985, 0xE6C6B721, 0x1D4BF165, 0xC8F7EF95, 0xA6330A44, 0x5ECBE4D1]);
    static immutable U256 g3y = U256([0xA27D5032, 0x9A79B127, 0x384FB83D, 0xD82AB036, 0x1A64A2EC, 0x374B06CE, 0x4998FF7E, 0x8734640C]);

    P256Point g2 = point_double(g);
    assert(g2.x == g2x && g2.y == g2y);
    assert(point_mul(two, g) == g2);

    P256Point g3 = point_add(g2, g);
    assert(g3.x == g3x && g3.y == g3y);
    assert(point_mul(three, g) == g3);
    assert(g3.on_curve());

    // n*G is the identity, (n-1)*G is -G
    P256Point inf = point_mul(p256_n, g);
    assert(inf.infinity);
    U256 n1 = p256_n;
    n1.limb[0] -= 1;
    P256Point neg = point_mul(n1, g);
    assert(neg == point_neg(g));
    assert(point_add(neg, g).infinity);

    // SEC1 round trip and on-curve rejection
    ubyte[65] sec1;
    g3.to_bytes(sec1[]);
    P256Point back;
    assert(back.from_bytes(sec1[]));
    assert(back == g3);
    sec1[64] ^= 1;
    assert(!back.from_bytes(sec1[]));

    // modular inverse against the prime and the order
    U256 inv = mod_inv(three, p256_p);
    assert(mod_mul(inv, three, p256_p) == U256([1, 0, 0, 0, 0, 0, 0, 0]));
    inv = mod_inv(three, p256_n);
    assert(mod_mul(inv, three, p256_n) == U256([1, 0, 0, 0, 0, 0, 0, 0]));

    // byte conversion
    ubyte[32] be;
    p256_gx.to_bytes(be[]);
    assert(be[0] == 0x6B && be[31] == 0x96);
    assert(U256.from_bytes(be[]) == p256_gx);
    static immutable ubyte[40] wide = 0xFF;
    U256 reduced = mod_reduce(wide[], p256_n);
    assert(reduced < p256_n);
}
