module urt.hash;

version = SmallSize;
version = BranchIsFasterThanMod;

nothrow @nogc:


alias fnv1a = fnv1!(uint, true);
alias fnv1a64 = fnv1!(ulong, true);

template fnv1_initial(T)
{
    static if (is(T == ushort))
        enum T fnv1_initial = 0x811C;
    else static if (is(T == uint))
        enum T fnv1_initial = 0x811C9DC5;
    else static if (is(T == ulong))
        enum T fnv1_initial = 0xCBF29CE484222325;
}

T fnv1(T, bool alternate)(const ubyte[] s, T hash = fnv1_initial!T) pure nothrow @nogc
    if (is(T == ushort) || is(T == uint) || is(T == ulong))
{
    static if (is(T == ushort))
        enum T prime = 0x0101;
    else static if (is(T == uint))
        enum T prime = 0x01000193;
    else static if (is(T == ulong))
        enum T prime = 0x100000001B3;

    const ubyte* p = s.ptr;
    for (size_t i = 0; i < s.length; ++i)
    {
        static if (alternate)
        {
            hash ^= p[i];
            hash *= prime;
        }
        else
        {
            hash *= prime;
            hash ^= p[i];
        }
    }
    return hash;
}

unittest
{
    enum hash = fnv1a(cast(ubyte[])"hello world");
    static assert(hash == 0xD58B3FA7);

    enum h1 = fnv1a(cast(ubyte[])"hello ");
    enum h2 = fnv1a(cast(ubyte[])"world", h1);
    static assert(h2 == hash);
}


uint adler32(const void[] data, uint init = 1)
{
    enum A32_BASE = 65521;

    assert(data.length <= int.max, "Data length must be less than or equal to int.max");

    uint s1 = init & 0xFFFF;
    uint s2 = (init >> 16) & 0xFFFF;

    version (SmallSize)
    {
        foreach (ubyte b; cast(ubyte[])data)
        {
            version (BranchIsFasterThanMod)
            {
                s1 += b;
                s2 += s1;
                if (s1 >= A32_BASE)
                    s1 -= A32_BASE;
                if (s2 >= A32_BASE)
                    s2 -= A32_BASE;
            }
            else
            {
                s1 = (s1 + b) % A32_BASE;
                s2 = (s2 + s1) % A32_BASE;
            }
        }
    }
    else
    {
        enum A32_NMAX = 5552;

        const(ubyte)* buf = cast(const ubyte*)data.ptr;
        int length = cast(int)data.length;

        while (length > 0)
        {
            int k = length < A32_NMAX ? length : A32_NMAX;
            int i;

            for (i = k / 16; i; --i, buf += 16)
            {
                s1 += buf[0];
                s2 += s1;
                s1 += buf[1];
                s2 += s1;
                s1 += buf[2];
                s2 += s1;
                s1 += buf[3];
                s2 += s1;
                s1 += buf[4];
                s2 += s1;
                s1 += buf[5];
                s2 += s1;
                s1 += buf[6];
                s2 += s1;
                s1 += buf[7];
                s2 += s1;

                s1 += buf[8];
                s2 += s1;
                s1 += buf[9];
                s2 += s1;
                s1 += buf[10];
                s2 += s1;
                s1 += buf[11];
                s2 += s1;
                s1 += buf[12];
                s2 += s1;
                s1 += buf[13];
                s2 += s1;
                s1 += buf[14];
                s2 += s1;
                s1 += buf[15];
                s2 += s1;
            }

            for (i = k & 0xF; i; --i)
            {
                s1 += *buf++;
                s2 += s1;
            }

            s1 %= A32_BASE;
            s2 %= A32_BASE;

            length -= k;
        }
    }

    return (s2 << 16) | s1;
}


// NOTE: progressive accumulation via `initial` works only when prior chunks have even length!!!
// odd-length chunks misalign the 16-bit word pairing. fixing this requires carrying a pending byte between calls :/
// maybe there's some way to protect against misuse?
ushort internet_checksum(const void[] data, ushort initial = 0xFFFF)
{
    auto bytes = cast(const(const ubyte)[])data;

    uint sum = ~initial;
    while (bytes.length > 1)
    {
        sum += (bytes.ptr[0] << 8) | bytes.ptr[1];
        bytes = bytes[2 .. $];
    }
    if (bytes.length > 0)
        sum += bytes.ptr[0] << 8;

    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);

    return cast(ushort)~sum;
}
