// TODO: DISSOLVE THIS FILE...
module urt.internal.bitop;

nothrow @nogc @safe:

version (D_InlineAsm_X86_64)
    version = AsmX86;
else version (D_InlineAsm_X86)
    version = AsmX86;

version (X86_64)
    version = AnyX86;
else version (X86)
    version = AnyX86;

// Use to implement 64-bit bitops on 32-bit arch.
private union Split64
{
    ulong u64;
    struct
    {
        version (LittleEndian)
        {
            uint lo;
            uint hi;
        }
        else
        {
            uint hi;
            uint lo;
        }
    }

    pragma(inline, true)
    this(ulong u64) @safe pure nothrow @nogc
    {
        if (__ctfe)
        {
            lo = cast(uint) u64;
            hi = cast(uint) (u64 >>> 32);
        }
        else
            this.u64 = u64;
    }
}

/**
 * Scans the bits in v starting with bit 0, looking
 * for the first set bit.
 * Returns:
 *      The bit number of the first bit set.
 *      The return value is undefined if v is zero.
 */
int bsf(uint v) pure
{
    pragma(inline, false);  // so intrinsic detection will work
    return softBsf!uint(v);
}

/// ditto
int bsf(ulong v) pure
{
    static if (size_t.sizeof == ulong.sizeof)  // 64 bit code gen
    {
        pragma(inline, false);   // so intrinsic detection will work
        return softBsf!ulong(v);
    }
    else
    {
        const sv = Split64(v);
        return (sv.lo == 0)?
            bsf(sv.hi) + 32 :
            bsf(sv.lo);
    }
}

/**
 * Scans the bits in v from the most significant bit
 * to the least significant bit, looking
 * for the first set bit.
 * Returns:
 *      The bit number of the first bit set.
 *      The return value is undefined if v is zero.
 */
int bsr(uint v) pure
{
    pragma(inline, false);  // so intrinsic detection will work
    return softBsr!uint(v);
}

/// ditto
int bsr(ulong v) pure
{
    static if (size_t.sizeof == ulong.sizeof)  // 64 bit code gen
    {
        pragma(inline, false);   // so intrinsic detection will work
        return softBsr!ulong(v);
    }
    else
    {
        const sv = Split64(v);
        return (sv.hi == 0)?
            bsr(sv.lo) :
            bsr(sv.hi) + 32;
    }
}

private alias softBsf(N) = softScan!(N, true);
private alias softBsr(N) = softScan!(N, false);

private int softScan(N, bool forward)(N v) pure
    if (is(N == uint) || is(N == ulong))
{
    if (!v)
        return -1;

    enum mask(ulong lo) = forward ? cast(N) lo : cast(N)~lo;
    enum inc(int up) = forward ? up : -up;

    N x;
    int ret;
    static if (is(N == ulong))
    {
        x = v & mask!0x0000_0000_FFFF_FFFFL;
        if (x)
        {
            v = x;
            ret = forward ? 0 : 63;
        }
        else
            ret = forward ? 32 : 31;

        x = v & mask!0x0000_FFFF_0000_FFFFL;
        if (x)
            v = x;
        else
            ret += inc!16;
    }
    else static if (is(N == uint))
    {
        x = v & mask!0x0000_FFFF;
        if (x)
        {
            v = x;
            ret = forward ? 0 : 31;
        }
        else
            ret = forward ? 16 : 15;
    }
    else
        static assert(false);

    x = v & mask!0x00FF_00FF_00FF_00FFL;
    if (x)
        v = x;
    else
        ret += inc!8;

    x = v & mask!0x0F0F_0F0F_0F0F_0F0FL;
    if (x)
        v = x;
    else
        ret += inc!4;

    x = v & mask!0x3333_3333_3333_3333L;
    if (x)
        v = x;
    else
        ret += inc!2;

    x = v & mask!0x5555_5555_5555_5555L;
    if (!x)
        ret += inc!1;

    return ret;
}

/**
 * Tests the bit.
 */
int bt(const scope size_t* p, size_t bitnum) pure @system
{
    static if (size_t.sizeof == 8)
        return ((p[bitnum >> 6] & (1L << (bitnum & 63)))) != 0;
    else static if (size_t.sizeof == 4)
        return ((p[bitnum >> 5] & (1  << (bitnum & 31)))) != 0;
    else
        static assert(0);
}

/**
 * Tests and complements the bit.
 */
int btc(size_t* p, size_t bitnum) pure @system;

/**
 * Tests and resets (sets to 0) the bit.
 */
int btr(size_t* p, size_t bitnum) pure @system;

/**
 * Tests and sets the bit.
 */
int bts(size_t* p, size_t bitnum) pure @system;

/**
 * Swaps bytes in a 2 byte ushort.
 */
pragma(inline, false)
ushort byteswap(ushort x) pure
{
    return cast(ushort) (((x >> 8) & 0xFF) | ((x << 8) & 0xFF00u));
}

/**
 * Swaps bytes in a 4 byte uint end-to-end.
 */
uint bswap(uint v) pure;

/**
 * Swaps bytes in an 8 byte ulong end-to-end.
 */
ulong bswap(ulong v) pure;

version (DigitalMars) version (AnyX86) @system // not pure
{
    ubyte inp(uint port_address);
    ushort inpw(uint port_address);
    uint inpl(uint port_address);
    ubyte outp(uint port_address, ubyte value);
    ushort outpw(uint port_address, ushort value);
    uint outpl(uint port_address, uint value);
}

/**
 *  Calculates the number of set bits in an integer.
 */
int popcnt(uint x) pure
{
    return softPopcnt!uint(x);
}

/// ditto
int popcnt(ulong x) pure
{
    static if (size_t.sizeof == uint.sizeof)
    {
        const sx = Split64(x);
        return softPopcnt!uint(sx.lo) + softPopcnt!uint(sx.hi);
    }
    else static if (size_t.sizeof == ulong.sizeof)
    {
        return softPopcnt!ulong(x);
    }
    else
        static assert(false);
}

version (DigitalMars) version (AnyX86)
{
    ushort _popcnt( ushort x ) pure;
    int _popcnt( uint x ) pure;
    version (X86_64)
    {
        int _popcnt( ulong x ) pure;
    }
}

private int softPopcnt(N)(N x) pure
    if (is(N == uint) || is(N == ulong))
{
    enum mask1 = cast(N) 0x5555_5555_5555_5555L;
    x = x - ((x>>1) & mask1);
    enum mask2a = cast(N) 0xCCCC_CCCC_CCCC_CCCCL;
    enum mask2b = cast(N) 0x3333_3333_3333_3333L;
    x = ((x & mask2a)>>2) + (x & mask2b);
    enum mask4 = cast(N) 0x0F0F_0F0F_0F0F_0F0FL;
    x = (x + (x >> 4)) & mask4;
    enum shiftbits = is(N == uint)? 24 : 56;
    enum maskMul = cast(N) 0x0101_0101_0101_0101L;
    x = (x * maskMul) >> shiftbits;
    return cast(int) x;
}
