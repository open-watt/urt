module urt.uuid;

import urt.conv : format_uint, parse_uint;
import urt.string.format : FormatArg;

nothrow @nogc:

enum GUID UUID(string s) = () { UUID g; ptrdiff_t n = g.fromString(s); assert(n == s.length, "Not a valid GUID/UUID"); return g; }();

struct GUID
{
nothrow @nogc:
align(1):
    uint data1;
    ushort data2;
    ushort data3;
    ubyte[8] data4;

    bool opEquals(ref const GUID rh) const pure
        => data1 == rh.data1 && data2 == rh.data2 && data3 == rh.data3 && data4 == rh.data4;

    bool opCast(T : bool)() const pure
        => data1 != 0 || data2 != 0 || data3 != 0 || data4 != typeof(data4).init;

    // xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ptrdiff_t toString(char[] buf, const(char)[], const(FormatArg)[]) const pure 
    {
        import urt.string.ascii : hex_digits;
        if (!buf.ptr)
            return 36;
        if (buf.length < 36)
            return -1;
        format_uint(data1, buf[0 .. 8], 16, 8, '0');
        buf[8] = '-';
        format_uint(data2, buf[9 .. 13], 16, 4, '0');
        buf[13] = '-';
        format_uint(data3, buf[14 .. 18], 16, 4, '0');
        buf[18] = '-';
        buf[19] = hex_digits[data4[0] >> 4];
        buf[20] = hex_digits[data4[0] & 0xf];
        buf[21] = hex_digits[data4[1] >> 4];
        buf[22] = hex_digits[data4[1] & 0xf];
        buf[23] = '-';
        buf[24] = hex_digits[data4[2] >> 4];
        buf[25] = hex_digits[data4[2] & 0xf];
        buf[26] = hex_digits[data4[3] >> 4];
        buf[27] = hex_digits[data4[3] & 0xf];
        buf[28] = hex_digits[data4[4] >> 4];
        buf[29] = hex_digits[data4[4] & 0xf];
        buf[30] = hex_digits[data4[5] >> 4];
        buf[31] = hex_digits[data4[5] & 0xf];
        buf[32] = hex_digits[data4[6] >> 4];
        buf[33] = hex_digits[data4[6] & 0xf];
        buf[34] = hex_digits[data4[7] >> 4];
        buf[35] = hex_digits[data4[7] & 0xf];
        return 36;
    }

    ptrdiff_t fromString(const(char)[] s) pure
    {
        if (s.length < 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-')
            return -1;
        size_t n;
        ulong d1 = s[0 .. 8].parse_uint(&n, 16);    if (n != 8)  return -1;
        ulong d2 = s[9 .. 13].parse_uint(&n, 16);   if (n != 4)  return -1;
        ulong d3 = s[14 .. 18].parse_uint(&n, 16);  if (n != 4)  return -1;
        data1 = cast(uint)d1;
        data2 = cast(ushort)d2;
        data3 = cast(ushort)d3;
        foreach (i; 0 .. 8)
        {
            size_t off = i < 2 ? 19 + i*2 : 20 + i*2;
            ulong b = s[off .. off + 2].parse_uint(&n, 16);
            if (n != 2) return -1;
            data4[i] = cast(ubyte)b;
        }
        return 36;
    }

    debug auto __debugOverview()
    {
        import urt.mem;
        char[] buf = debug_alloc!char(36);
        toString(buf, null, null);
        return buf[0 .. 36];
    }
}

static assert(GUID.sizeof == 16);
static assert(GUID.alignof == 1);
