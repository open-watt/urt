module urt.endian;

import urt.processor;
import urt.traits;

public import urt.processor : LittleEndian;
public import urt.util : byte_reverse;
import urt.util : is_aligned;

pure nothrow @nogc:

// Xtensa lowers unaligned scalars to bytes; assemble the swapped order directly.
version (Xtensa)
    private enum bytewise_swap = true;
else
    private enum bytewise_swap = false;


// Byte-array loads accept byte-aligned input.
pragma(inline, true) T endianToNative(T, bool little)(ref const ubyte[1] bytes)
    if (T.sizeof == 1 && is_integral!T)
{
    return cast(T)bytes[0];
}

pragma(inline, true) ushort endianToNative(T, bool little)(ref const ubyte[2] bytes)
    if (T.sizeof == 2 && is_integral!T)
{
    if (__ctfe || ((max_unaligned_scalar_access_bytes < 2 || bytewise_swap) && LittleEndian != little))
    {
        static if (little)
            return cast(T)(bytes[0] | bytes[1] << 8);
        else
            return cast(T)(bytes[0] << 8 | bytes[1]);
    }
    static if (max_unaligned_scalar_access_bytes >= 2 || LittleEndian == little)
    {
        static if (LittleEndian == little)
            return load_unaligned!ushort(bytes);
        else
            return byte_reverse(load_unaligned!ushort(bytes));
    }
}

uint endianToNative(T, bool little)(ref const ubyte[4] bytes)
    if (T.sizeof == 4 && is_integral!T)
{
    if (__ctfe || max_unaligned_scalar_access_bytes < 4 || (bytewise_swap && LittleEndian != little))
    {
        static if (little)
            return cast(T)(bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24);
        else
            return cast(T)(bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]);
    }
    static if (max_unaligned_scalar_access_bytes >= 4)
    {
        pragma(inline, true);
        static if (LittleEndian == little)
            return load_unaligned!uint(bytes);
        else
            return byte_reverse(load_unaligned!uint(bytes));
    }
}

ulong endianToNative(T, bool little)(ref const ubyte[8] bytes)
    if (T.sizeof == 8 && is_integral!T)
{
    if (__ctfe || max_unaligned_scalar_access_bytes < 4)
    {
        static if (little)
            return cast(T)(bytes[0] | bytes[1] << 8 | bytes[2] << 16 | ulong(bytes[3]) << 24 | ulong(bytes[4]) << 32 | ulong(bytes[5]) << 40 | ulong(bytes[6]) << 48 | ulong(bytes[7]) << 56);
        else
            return cast(T)(ulong(bytes[0]) << 56 | ulong(bytes[1]) << 48 | ulong(bytes[2]) << 40 | ulong(bytes[3]) << 32 | ulong(bytes[4]) << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7]);
    }
    static if (max_unaligned_scalar_access_bytes >= 8)
    {
        pragma(inline, true);
        static if (LittleEndian == little)
            return load_unaligned!ulong(bytes);
        else
            return byte_reverse(load_unaligned!ulong(bytes));
    }
    else static if (max_unaligned_scalar_access_bytes >= 4)
    {
        pragma(inline, true);
        enum first_shift = little ? 0 : 32;
        return (ulong(endianToNative!(uint, little)(bytes[0 .. 4])) << first_shift) | (ulong(endianToNative!(uint, little)(bytes[4 .. 8])) << (32 - first_shift));
    }
}

pragma(inline, true) T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (!is_integral!T && !is(T == struct) && !is(T == U[N], U, size_t N))
{
    import urt.meta : IntForWidth;
    alias U = IntForWidth!(T.sizeof*8);
    U u = endianToNative!(U, little)(bytes);
    return *cast(T*)&u;
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == U[N], U, size_t N))
{
    static if (is(T == U[N], U, size_t N))
    {
        static assert(!is(U == class) && !is(U == interface) && !is(U == V*, V), T.stringof ~ " is not POD");

        static if (U.sizeof == 1)
            return *cast(T*)&bytes;
        else
        {
            T r;
            for (size_t i = 0, j = 0; i < N; ++i, j += U.sizeof)
                r[i] = endianToNative!(U, little)(bytes.ptr[j .. j + U.sizeof][0 .. U.sizeof]);
            return r;
        }
    }
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == struct))
{
    // assert that T is POD

    T r;

    size_t offset = 0;
    alias members = r.tupleof;
    static foreach(i; 0 .. members.length)
    {{
        enum Len = members[i].sizeof;
        members[i] = endianToNative!(typeof(members[i]), little)(bytes.ptr[offset .. offset + Len][0 .. Len]);
        offset += Len;
    }}

    return r;
}

T endianToNative(T, bool little)(ref const ubyte[T.sizeof] bytes)
    if (is(T == U[], U) || is(T == U*, U) || is(T == class) || is(T == interface))
{
    static assert(false, "Invalid call for " ~ T.stringof);
}


alias bigEndianToNative(T) = endianToNative!(T, false);
alias littleEndianToNative(T) = endianToNative!(T, true);


// store to byte arrays
pragma(inline, true) ubyte[1] nativeToEndian(bool little)(ubyte u)
{
    return [ u ];
}

pragma(inline, true) ubyte[2] nativeToEndian(bool little)(ushort u)
{
    if (__ctfe || max_unaligned_scalar_access_bytes < 2)
    {
        static if (little)
            return [ u & 0xFF, u >> 8 ];
        else
            return [ u >> 8, u & 0xFF ];
    }
    static if (max_unaligned_scalar_access_bytes >= 2)
    {
        static if (LittleEndian != little)
            u = byte_reverse(u);
        return *cast(ubyte[2]*)&u;
    }
}

pragma(inline, true) ubyte[4] nativeToEndian(bool little)(uint u)
{
    if (__ctfe || max_unaligned_scalar_access_bytes < 4)
    {
        static if (little)
            return [ u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF, u >> 24 ];
        else
            return [ u >> 24, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF ];
    }
    static if (max_unaligned_scalar_access_bytes >= 4)
    {
        static if (LittleEndian != little)
            u = byte_reverse(u);
        return *cast(ubyte[4]*)&u;
    }
}

pragma(inline, true) ubyte[8] nativeToEndian(bool little)(ulong u)
{
    if (__ctfe || max_unaligned_scalar_access_bytes < 4)
    {
        static if (little)
            return [ u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF, (u >> 24) & 0xFF, (u >> 32) & 0xFF, (u >> 40) & 0xFF, (u >> 48) & 0xFF, u >> 56 ];
        else
            return [ u >> 56, (u >> 48) & 0xFF, (u >> 40) & 0xFF, (u >> 32) & 0xFF, (u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF ];
    }
    static if (max_unaligned_scalar_access_bytes >= 8)
    {
        static if (LittleEndian != little)
            u = byte_reverse(u);
        return *cast(ubyte[8]*)&u;
    }
    else static if (max_unaligned_scalar_access_bytes >= 4)
    {
        enum first_shift = little ? 0 : 32;
        ubyte[8] bytes = void;
        bytes[0 .. 4] = nativeToEndian!little(cast(uint)(u >> first_shift));
        bytes[4 .. 8] = nativeToEndian!little(cast(uint)(u >> (32 - first_shift)));
        return bytes;
    }
}

pragma(inline, true) auto nativeToEndian(bool little, T)(T val)
    if (!is_integral!T && !is(T == struct) && !is(T == U[N], U, size_t N))
{
    import urt.meta : IntForWidth;
    alias U = IntForWidth!(T.sizeof*8);
    return nativeToEndian!little(*cast(U*)&val);
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == U[N], U, size_t N))
{
    static assert(is(T == U[N], U, size_t N) && !is(U == class) && !is(U == interface) && !is(U == V*, V), T.stringof ~ " is not POD");

    static if (U.sizeof == 1)
        return *cast(ubyte[T.sizeof])&data;
    else
    {
        ubyte[T.sizeof] buffer = void;
        for (size_t i = 0; i < N*T.sizeof; i += T.sizeof)
           buffer.ptr[i .. i + T.sizeof][0 .. T.sizeof] = nativeToEndian!little(data[i]);
        return buffer;
    }
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == struct))
{
    // assert that T is POD

    ubyte[T.sizeof] buffer = void;

    size_t offset = 0;
    alias members = data.tupleof;
    static foreach(i; 0 .. members.length)
    {{
        enum Len = members[i].sizeof;
        buffer.ptr[offset .. offset + Len][0 .. Len] = nativeToEndian!little(members[i]);
        offset += Len;
    }}

    return buffer;
}

ubyte[T.sizeof] nativeToEndian(bool little, T)(auto ref const T data)
    if (is(T == U[], U) || is(T == U*, U) || is(T == class) || is(T == interface))
{
    static assert(false, "Invalid call for " ~ T.stringof);
}

ubyte[T.sizeof] nativeToBigEndian(T)(auto ref const T data)
    => nativeToEndian!false(data);
ubyte[T.sizeof] nativeToLittleEndian(T)(auto ref const T data)
    => nativeToEndian!true(data);


// Pointer loads and stores require T.alignof.
void storeBigEndian(T)(T* target, const T val)
    if (is_some_int!T || is(T == float) || is(T == double))
{
    debug if (!__ctfe)
        assert(is_aligned!(T.alignof)(target));
    version (BigEndian)
        *target = val;
    else
        *target = byte_reverse(val);
}
void storeLittleEndian(T)(T* target, const T val)
    if (is_some_int!T || is(T == float) || is(T == double))
{
    debug if (!__ctfe)
        assert(is_aligned!(T.alignof)(target));
    version (LittleEndian)
        *target = val;
    else
        *target = byte_reverse(val);
}
T loadBigEndian(T)(const(T)* src)
    if (is_some_int!T || is(T == float) || is(T == double))
{
    debug if (!__ctfe)
        assert(is_aligned!(T.alignof)(src));
    version (BigEndian)
        return *src;
    else
        return byte_reverse(*src);
}
T loadLittleEndian(T)(const(T)* src)
    if (is_some_int!T || is(T == float) || is(T == double))
{
    debug if (!__ctfe)
        assert(is_aligned!(T.alignof)(src));
    version (LittleEndian)
        return *src;
    else
        return byte_reverse(*src);
}


template can_reverse_endian(T)
{
    static if (is(T == union) || is(T == class) || is(T == interface) ||
               is(T == U*, U) || is(T == U[], U))
        enum can_reverse_endian = false;
    else static if (is(T == struct))
        enum can_reverse_endian = () {
            bool r = true;
            size_t end = 0;
            static foreach (i; 0 .. T.tupleof.length)
            {
                // overlapping members (anonymous unions) fail the monotonic-offset check
                r = r && can_reverse_endian!(typeof(T.tupleof[i])) && T.tupleof[i].offsetof >= end;
                end = T.tupleof[i].offsetof + typeof(T.tupleof[i]).sizeof;
            }
            return r;
        }();
    else static if (is(T == U[N], U, size_t N))
        enum can_reverse_endian = can_reverse_endian!U;
    else
        enum can_reverse_endian = T.sizeof == 1 || T.sizeof == 2 || T.sizeof == 4 || T.sizeof == 8;
}

void reverse_endian(T)(ref const T src, ref T dst)
    if (can_reverse_endian!T)
{
    static if (is(T == struct))
    {
        static foreach (i; 0 .. T.tupleof.length)
            reverse_endian(src.tupleof[i], dst.tupleof[i]);
    }
    else static if (is(T == U[N], U, size_t N))
    {
        static if (U.sizeof > 1)
        {
            foreach (i; 0 .. N)
                reverse_endian(src[i], dst[i]);
        }
        else
        {
            if (&src !is &dst)
                dst = src;
        }
    }
    else static if (T.sizeof > 1)
    {
        import urt.meta : IntForWidth;
        alias U = IntForWidth!(T.sizeof*8);
        *cast(U*)&dst = byte_reverse(*cast(const(U)*)&src);
    }
    else
        dst = src;
}


private pragma(inline, true) T load_unaligned(T)(ref const ubyte[T.sizeof] bytes)
{
    version (DigitalMars)
    {
        struct Unaligned { align(1) T value; }
        return (cast(const(Unaligned)*)bytes.ptr).value;
    }
    else
    {
        T value = void;
        (cast(ubyte*)&value)[0 .. T.sizeof] = bytes[];
        return value;
    }
}

unittest
{
    import urt.meta : AliasSeq;

    static assert({
        ubyte[8] bytes = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0];
        return bigEndianToNative!ushort(bytes[0 .. 2]) == 0x1234
            && littleEndianToNative!uint(bytes[0 .. 4]) == 0x78563412
            && bigEndianToNative!ulong(bytes) == 0x123456789ABCDEF0
            && nativeToLittleEndian(0xF0DEBC9A78563412UL) == bytes;
    }());

    align(8) ubyte[24] buffer = void;
    static foreach (T; AliasSeq!(ushort, uint, ulong))
    {{
        enum T value = cast(T)0xFEDCBA9876543210UL;
        foreach (offset; 1 .. 9)
        {
            buffer[] = 0xA5;
            buffer[offset .. offset + T.sizeof] = nativeToLittleEndian(value);
            foreach (i; 0 .. T.sizeof)
                assert(buffer[offset + i] == cast(ubyte)(value >> (i * 8)));
            assert(littleEndianToNative!T(buffer[offset .. offset + T.sizeof][0 .. T.sizeof]) == value);
            assert(buffer[offset - 1] == 0xA5 && buffer[offset + T.sizeof] == 0xA5);

            buffer[offset .. offset + T.sizeof] = nativeToBigEndian(value);
            foreach (i; 0 .. T.sizeof)
                assert(buffer[offset + i] == cast(ubyte)(value >> ((T.sizeof - i - 1) * 8)));
            assert(bigEndianToNative!T(buffer[offset .. offset + T.sizeof][0 .. T.sizeof]) == value);
            assert(buffer[offset - 1] == 0xA5 && buffer[offset + T.sizeof] == 0xA5);
        }
    }}
    static foreach (T; AliasSeq!(float, double))
    {{
        import urt.meta : IntForWidth;
        alias U = IntForWidth!(T.sizeof * 8);
        static if (T.sizeof == 4)
            enum U[] patterns = [0, 0x80000000, 0x3F800000, 0x7F800000, 0xFF800000, 0x7FC12345, 1, 0x007FFFFF];
        else
            enum U[] patterns = [0, 0x8000000000000000, 0x3FF0000000000000, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8123456789ABC, 1, 0x000FFFFFFFFFFFFF];
        foreach (bits; patterns)
            foreach (offset; 1 .. 9)
                static foreach (little; AliasSeq!(false, true))
                {{
                    T value = *cast(T*)&bits;
                    buffer[] = 0xA5;
                    buffer[offset .. offset + T.sizeof] = nativeToEndian!little(value);
                    foreach (i; 0 .. T.sizeof)
                        assert(buffer[offset + i] == cast(ubyte)(bits >> (8 * (little ? i : T.sizeof - 1 - i))));
                    T decoded = endianToNative!(T, little)(buffer[offset .. offset + T.sizeof][0 .. T.sizeof]);
                    assert(*cast(U*)&decoded == bits);
                    assert(buffer[offset - 1] == 0xA5 && buffer[offset + T.sizeof] == 0xA5);
                }}
    }}

    ubyte[8] test = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0];

    assert(endianToNative!(ubyte,   LittleEndian)(test[0..1]) == 0x12);
    assert(endianToNative!(ushort,  LittleEndian)(test[0..2]) == 0x3412);
    assert(endianToNative!(uint,    LittleEndian)(test[0..4]) == 0x78563412);
    assert(endianToNative!(ulong,   LittleEndian)(test) == 0xF0DEBC9A78563412);
    assert(endianToNative!(ubyte,  !LittleEndian)(test[0..1]) == 0x12);
    assert(endianToNative!(ushort, !LittleEndian)(test[0..2]) == 0x1234);
    assert(endianToNative!(uint,   !LittleEndian)(test[0..4]) == 0x12345678);
    assert(endianToNative!(ulong,  !LittleEndian)(test) == 0x123456789ABCDEF0);

    assert(nativeToEndian!( LittleEndian)(0x12) == test[0..1]);
    assert(nativeToEndian!( LittleEndian)(0x3412) == test[0..2]);
    assert(nativeToEndian!( LittleEndian)(0x78563412) == test[0..4]);
    assert(nativeToEndian!( LittleEndian)(0xF0DEBC9A78563412) == test);
    assert(nativeToEndian!(!LittleEndian)(0x12) == test[0..1]);
    assert(nativeToEndian!(!LittleEndian)(0x1234) == test[0..2]);
    assert(nativeToEndian!(!LittleEndian)(0x12345678) == test[0..4]);
    assert(nativeToEndian!(!LittleEndian)(0x123456789ABCDEF0) == test);

    // reverse_endian: member-recursive flip, padding-exact, aliasing-tolerant
    static struct Flip { ubyte a; ushort b; uint c; }
    Flip fl = Flip(1, 0x0203, 0x04050607);
    reverse_endian(fl, fl);
    assert(fl.a == 1 && fl.b == 0x0302 && fl.c == 0x07060504);
    Flip fl2;
    reverse_endian(fl, fl2);
    assert(fl2 == Flip(1, 0x0203, 0x04050607));
    ushort[2] arr = [0x0102, 0x0304];
    reverse_endian(arr, arr);
    assert(arr[0] == 0x0201 && arr[1] == 0x0403);
    static struct Nested { Flip f; ushort w; }
    static assert(can_reverse_endian!Nested && can_reverse_endian!(ushort[4]));
    static struct HasUnion { union { ushort u; ubyte b2; } }
    static assert(!can_reverse_endian!HasUnion);
    static assert(!can_reverse_endian!(int*));
}
