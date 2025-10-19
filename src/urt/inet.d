module urt.inet;

import urt.conv;
import urt.endian;
import urt.meta.nullable;
import urt.string.format;
import urt.util : clz;

nothrow @nogc:


enum AddressFamily : byte
{
    unknown = -1,
    unspecified = 0,
    unix,
    ipv4,
    ipv6,
}

enum WellKnownPort : ushort
{
    Auto    = 0,
    FTP     = 21,
    SSH     = 22,
    Telnet  = 23,
    DNS     = 53,
    DHCP    = 67,
    HTTP    = 80,
    NTP     = 123,
    SNMP    = 161,
    HTTPS   = 443,
    MQTT    = 1883,
    MDNS    = 5353,
}

enum IPAddr IPAddrLit(string addr) = () { IPAddr a; size_t taken = a.fromString(addr); assert(taken == addr.length, "Not an ipv4 address"); return a; }();
enum IPv6Addr IPv6AddrLit(string addr) = () { IPv6Addr a; size_t taken = a.fromString(addr); assert(taken == addr.length, "Not an ipv6 address"); return a; }();

struct IPAddr
{
nothrow @nogc:

    enum any       = IPAddr(0, 0, 0, 0);
    enum loopback  = IPAddr(127, 0, 0, 1);
    enum broadcast = IPAddr(255, 255, 255, 255);
    enum none      = IPAddr(255, 255, 255, 255);

    union {
        uint address;
        ubyte[4] b;
    }

    this(ubyte[4] b...) pure
    {
        this.b = b;
    }

    bool is_multicast() const pure
        => (b[0] & 0xF0) == 224;
    bool is_loopback() const pure
        => b[0] == 127;
    bool is_link_local() const pure
        => (b[0] == 169 && b[1] == 254);
    bool is_private() const pure
        => (b[0] == 192 && b[1] == 168) || b[0] == 10 || (b[0] == 172 && (b[1] & 0xF) == 16);

    bool opCast(T : bool)() const pure
        => address != 0;

    bool opEquals(ref const IPAddr rhs) const pure
        => address == rhs.address;

    bool opEquals(const(ubyte)[4] bytes) const pure
        => b == bytes;

    int opCmp(ref const IPAddr rhs) const pure
    {
        uint a = loadBigEndian(&address), b = loadBigEndian(&rhs.address);
        if (a < b)
            return -1;
        else if (a > b)
            return 1;
        return 0;
    }

    IPAddr opUnary(string op : "~")() const pure
    {
        IPAddr r;
        r.address = ~address;
        return r;
    }

    IPAddr opBinary(string op)(const IPAddr rhs) const pure
        if (op == "&" || op == "|" || op == "^")
    {
        IPAddr r;
        r.address = mixin("address" ~ op ~ "rhs.address");
        return r;
    }

    void opOpAssign(string op)(const IPAddr rhs) pure
        if (op == "&" || op == "|" || op == "^")
    {
        address = mixin("address" ~ op ~ "rhs.address");
    }

    size_t toHash() const pure
    {
        import urt.hash : fnv1a, fnv1a64;
        static if (size_t.sizeof > 4)
            return fnv1a64(b[]);
        else
            return fnv1a(b[]);
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const pure
    {
        char[15] stack_buffer = void;
        char[] tmp = buffer.length < stack_buffer.sizeof ? stack_buffer : buffer;
        size_t offset = 0;
        for (int i = 0; i < 4; i++)
        {
            if (i > 0)
                tmp[offset++] = '.';
            offset += b[i].format_int(tmp[offset..$]);
        }

        if (buffer.ptr && tmp.ptr == stack_buffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        ubyte[4] t;
        size_t offset = 0, len;
        ulong i = s[offset..$].parse_int(&len);
        offset += len;
        if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
            return -1;
        t[0] = cast(ubyte)i;
        i = s[offset..$].parse_int(&len);
        offset += len;
        if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
            return -1;
        t[1] = cast(ubyte)i;
        i = s[offset..$].parse_int(&len);
        offset += len;
        if (len == 0 || i > 255 || s.length < offset + 1 || s[offset++] != '.')
            return -1;
        t[2] = cast(ubyte)i;
        i = s[offset..$].parse_int(&len);
        offset += len;
        if (len == 0 || i > 255)
            return -1;
        t[3] = cast(ubyte)i;
        b = t;
        return offset;
    }

    auto __debugOverview()
    {
        import urt.mem;
        char[] buffer = cast(char[])tempAllocator.alloc(15);
        ptrdiff_t len = toString(buffer, null, null);
        return buffer[0 .. len];
    }
    auto __debugExpanded() => b[];
}


struct IPv6Addr
{
nothrow @nogc:

    enum any                = IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0);
    enum loopback           = IPv6Addr(0, 0, 0, 0, 0, 0, 0, 1);
    enum linkLocal_allNodes = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 1);
    enum linkLocal_routers  = IPv6Addr(0xFF02, 0, 0, 0, 0, 0, 0, 2);

    ushort[8] s;

    this(ushort[8] s...) pure
    {
        this.s = s;
    }

    bool is_global() const pure
        => (s[0] & 0xE000) == 0x2000;
    bool is_link_local() const pure
        => (s[0] & 0xFFC0) == 0xFE80;
    bool is_multicast() const pure
        => (s[0] & 0xFF00) == 0xFF00;
    bool is_unique_local() const pure
        => (s[0] & 0xFE00) == 0xFC00;

    bool opCast(T : bool)() const pure
        => (s[0] | s[1] | s[2] | s[3] | s[4] | s[5] | s[6] | s[7]) != 0;

    bool opEquals(ref const IPv6Addr rhs) const pure
        => s == rhs.s;

    bool opEquals(const(ushort)[8] words) const pure
        => s == words;

    int opCmp(ref const IPv6Addr rhs) const pure
    {
        for (int i = 0; i < 8; i++)
        {
            if (s[i] < rhs.s[i])
                return -1;
            else if (s[i] > rhs.s[i])
                return 1;
        }
        return 0;
    }

    IPv6Addr opUnary(string op : "~")() const pure
    {
        IPv6Addr r;
        foreach (i; 0..8)
            r.s[i] = cast(ushort)~s[i];
        return r;
    }

    IPv6Addr opBinary(string op)(const IPv6Addr rhs) const pure
        if (op == "&" || op == "|" || op == "^")
    {
        IPv6Addr t;
        foreach (i, v; s)
            t.s[i] = mixin("v " ~ op ~ " rhs.s[i]");
        return t;
    }

    void opOpAssign(string op)(const IPv6Addr rhs) pure
        if (op == "&" || op == "|" || op == "^")
    {
        foreach (i, v; s)
            this = mixin("this " ~ op ~ " rhs");
    }

    size_t toHash() const pure
    {
        import urt.hash : fnv1a, fnv1a64;
        static if (size_t.sizeof > 4)
            return fnv1a64(cast(ubyte[])s[]);
        else
            return fnv1a(cast(ubyte[])s[]);
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const pure
    {
        import urt.string.ascii;

        // find consecutive zeroes...
        int skip_from = 0;
        int[8] z;
        for (int i = 0; i < 8; i++)
        {
            if (s[i] == 0)
            {
                for (int j = i - 1; j >= 0; --j)
                {
                    if (z[j] != 0)
                    {
                        ++z[j];
                        if (z[j] > z[skip_from])
                            skip_from = j;
                    }
                    else
                        break;
                }
                z[i] = 1;
                if (z[i] > z[skip_from])
                    skip_from = i;
            }
        }

        // write the string to a temp buffer
        char[39] tmp;
        size_t offset = 0;
        for (int i = 0; i < 8;)
        {
            if (i > 0)
                tmp[offset++] = ':';
            if (z[skip_from] > 1 && i == skip_from)
            {
                if (i == 0)
                    tmp[offset++] = ':';
                i += z[skip_from];
                if (i == 8)
                    tmp[offset++] = ':';
                continue;
            }
            offset += s[i].format_int(tmp[offset..$], 16);
            ++i;
        }

        if (buffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            foreach (i, c; tmp[0 .. offset])
                buffer[i] = c.to_lower;
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] str)
    {
        ushort[8][2] t = void;
        ubyte[2] count;
        int part = 0;

        size_t offset = 0, len;
        while (offset < str.length)
        {
            if (offset < str.length - 1 && str[offset] == ':' && str[offset + 1] == ':')
            {
                if (part != 0)
                    return -1;
                part = 1;
                offset += 2;
                if (offset == str.length)
                    break;
            }
            else if (count[part] > 0)
            {
                if (str[offset] != ':')
                    break;
                if (++offset == str.length)
                    return -1;
            }
            if (str[offset] == ':')
                return -1;
            ulong i = str[offset..$].parse_int(&len, 16);
            if (len == 0)
                break;
            if (i > ushort.max || count[0] + count[1] == 8)
                return -1;
            t[part][count[part]++] = cast(ushort)i;
            offset += len;
        }
        if (part == 0 && count[0] != 8)
            return -1;

        s[0 .. count[0]] = t[0][0 .. count[0]];
        s[count[0] .. 8 - count[1]] = 0;
        s[8 - count[1] .. 8] = t[1][0 .. count[1]];
        return offset;
    }

    auto __debugOverview()
    {
        import urt.mem;
        char[] buffer = cast(char[])tempAllocator.alloc(39);
        ptrdiff_t len = toString(buffer, null, null);
        return buffer[0 .. len];
    }
    auto __debugExpanded() => s[];
}

struct IPNetworkAddress
{
nothrow @nogc:

    enum multicast = IPNetworkAddress(IPAddr(224, 0, 0, 0), 4);
    enum loopback  = IPNetworkAddress(IPAddr(127, 0, 0, 0), 8);
    enum linklocal = IPNetworkAddress(IPAddr(169, 254, 0, 0), 16);
    enum private_a = IPNetworkAddress(IPAddr(10, 0, 0, 0), 8);
    enum private_b = IPNetworkAddress(IPAddr(172, 16, 0, 0), 12);
    enum private_c = IPNetworkAddress(IPAddr(192, 168, 0, 0), 16);
    // TODO: ya know, this is gonna align to 4-bytes anyway...
    //       we could store the actual mask in the native endian, and then clz to recover the prefix len in one opcode

    IPAddr addr;
    IPAddr mask;

    ubyte prefix_len() @property const pure
        => clz(~loadBigEndian(&mask.address));
    void prefix_len(ubyte len) @property pure
    {
        if (len == 0)
            mask.address = 0;
        else
            storeBigEndian(&mask.address, 0xFFFFFFFF << (32 - len));
    }

    this(IPAddr addr, ubyte prefix_len)
    {
        this.addr = addr;
        this.prefix_len = prefix_len;
    }

    IPAddr net_mask() const pure
        => mask;

    bool contains(IPAddr ip) const pure
        => (ip & mask) == get_network();

    IPAddr get_network() const pure
        => addr & mask;
    IPAddr get_local() const pure
        => addr & ~mask;

    size_t toHash() const pure
        => addr.toHash() ^ prefix_len;

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const pure
    {
        char[18] stack_buffer = void;
        char[] tmp = buffer.length < stack_buffer.sizeof ? stack_buffer : buffer;

        size_t offset = addr.toString(tmp, null, null);
        tmp[offset++] = '/';
        offset += prefix_len.format_int(tmp[offset..$]);

        if (buffer.ptr && tmp.ptr == stack_buffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        IPAddr a;
        size_t taken = a.fromString(s);
        if (taken < 0 || s.length <= taken + 1 || s[taken++] != '/')
            return -1;
        size_t t;
        ulong plen = s[taken..$].parse_int(&t);
        if (t == 0 || plen > 32)
            return -1;
        addr = a;
        prefix_len = cast(ubyte)plen;
        return taken + t;
    }

    auto __debugOverview()
    {
        import urt.mem;
        char[] buffer = cast(char[])tempAllocator.alloc(18);
        ptrdiff_t len = toString(buffer, null, null);
        return buffer[0 .. len];
    }
}

struct IPv6NetworkAddress
{
nothrow @nogc:

    enum global      = IPv6NetworkAddress(IPv6Addr(0x2000, 0, 0, 0, 0, 0, 0, 0), 3);
    enum linklocal   = IPv6NetworkAddress(IPv6Addr(0xFE80, 0, 0, 0, 0, 0, 0, 0), 10);
    enum multicast   = IPv6NetworkAddress(IPv6Addr(0xFF00, 0, 0, 0, 0, 0, 0, 0), 8);
    enum uniquelocal = IPv6NetworkAddress(IPv6Addr(0xFC00, 0, 0, 0, 0, 0, 0, 0), 7);

    IPv6Addr addr;
    ubyte prefix_len;

    this(IPv6Addr addr, ubyte prefix_len)
    {
        this.addr = addr;
        this.prefix_len = prefix_len;
    }

    IPv6Addr net_mask() const pure
    {
        IPv6Addr r;
        int i, j = prefix_len / 16;
        while (i < j) r.s[i++] = 0xFFFF;
        if (j < 8)
        {
            r.s[i++] = cast(ushort)(0xFFFF << (16 - (prefix_len % 16)));
            while (i < 8) r.s[i++] = 0;
        }
        return r;
    }

    bool contains(IPv6Addr ip) const pure
    {
        uint n = prefix_len / 16;
        uint i = 0;
        for (; i < n; ++i)
            if (ip.s[i] != addr.s[i])
                return false;
        if (prefix_len % 16)
        {
            uint s = 16 - (prefix_len % 16);
            if (ip.s[i] >> s != addr.s[i] >> s)
                return false;
        }
        return true;
    }

    IPv6Addr get_network() const pure
        => addr & net_mask();
    IPv6Addr get_local() const pure
        => addr & ~net_mask();

    size_t toHash() const pure
        => addr.toHash() ^ prefix_len;

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const pure
    {
        char[42] stack_buffer = void;
        char[] tmp = buffer.length < stack_buffer.sizeof ? stack_buffer : buffer;

        size_t offset = addr.toString(tmp, null, null);
        tmp[offset++] = '/';
        offset += prefix_len.format_int(tmp[offset..$]);

        if (buffer.ptr && tmp.ptr == stack_buffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        IPv6Addr a;
        size_t taken = a.fromString(s);
        if (taken < 0 || s.length <= taken + 1 || s[taken++] != '/')
            return -1;
        size_t t;
        ulong plen = s[taken..$].parse_int(&t);
        if (t == 0 || plen > 128)
            return -1;
        addr = a;
        prefix_len = cast(ubyte)plen;
        return taken + t;
    }

    auto __debugOverview()
    {
        import urt.mem;
        char[] buffer = cast(char[])tempAllocator.alloc(42);
        ptrdiff_t len = toString(buffer, null, null);
        return buffer[0 .. len];
    }
}

struct MulticastGroup
{
    IPAddr address;
    IPAddr iface;
}

struct InetAddress
{
nothrow @nogc:

    struct IPv4
    {
        IPAddr addr;
        ushort port;
    }
    struct IPv6
    {
        IPv6Addr addr;
        ushort port;
        uint flow_info;
        uint scopeId;
    }
    struct Addr
    {
        IPv4 ipv4;
        IPv6 ipv6;
    }

    AddressFamily family;
    Addr _a;

    this(IPAddr addr, ushort port)
    {
        family = AddressFamily.ipv4;
        this._a.ipv4.addr = addr;
        this._a.ipv4.port = port;
    }

    this(IPv6Addr addr, ushort port, int flow_info = 0, uint scopeId = 0)
    {
        family = AddressFamily.ipv6;
        this._a.ipv6.addr = addr;
        this._a.ipv6.port = port;
        this._a.ipv6.flow_info = flow_info;
        this._a.ipv6.scopeId = scopeId;
    }

    inout(IPv4)* as_ipv4() inout pure
        => family == AddressFamily.ipv4 ? &_a.ipv4 : null;

    inout(IPv6)* as_ipv6() inout pure
        => family == AddressFamily.ipv6 ? &_a.ipv6 : null;

    bool opCast(T : bool)() const pure
        => family > AddressFamily.Unspecified;

    bool opEquals(ref const InetAddress rhs) const pure
    {
        if (family != rhs.family)
            return false;
        switch (family)
        {
            case AddressFamily.ipv4:
                return _a.ipv4 == rhs._a.ipv4;
            case AddressFamily.ipv6:
                return _a.ipv6 == rhs._a.ipv6;
            default:
                return true;
        }
    }

    int opCmp(ref const InetAddress rhs) const pure
    {
        if (family != rhs.family)
            return family < rhs.family ? -1 : 1;
        switch (family)
        {
            case AddressFamily.ipv4:
                int c = _a.ipv4.addr.opCmp(rhs._a.ipv4.addr);
                return c != 0 ? c : _a.ipv4.port - rhs._a.ipv4.port;
            case AddressFamily.ipv6:
                int c = _a.ipv6.addr.opCmp(rhs._a.ipv6.addr);
                if (c != 0)
                    return c;
                if (_a.ipv6.port == rhs._a.ipv6.port)
                {
                    if (_a.ipv6.flow_info == rhs._a.ipv6.flow_info)
                        return _a.ipv6.scopeId - rhs._a.ipv6.scopeId;
                    return _a.ipv6.flow_info - rhs._a.ipv6.flow_info;
                }
                return _a.ipv6.port - rhs._a.ipv6.port;
            default:
                return 0;
        }
        return 0;
    }

    size_t toHash() const pure
    {
        if (family == AddressFamily.ipv4)
            return _a.ipv4.addr.toHash() ^ _a.ipv4.port;
        else
            return _a.ipv6.addr.toHash() ^ _a.ipv6.port;
    }

    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] format_args) const pure
    {
        char[47] stack_buffer = void;
        char[] tmp = buffer.length < stack_buffer.sizeof ? stack_buffer : buffer;

        size_t offset = void;
        if (family == AddressFamily.ipv4)
        {
            offset = _a.ipv4.addr.toString(tmp, null, null);
            tmp[offset++] = ':';
            offset += _a.ipv4.port.format_int(tmp[offset..$]);
        }
        else
        {
            tmp[0] = '[';
            offset = 1 + _a.ipv6.addr.toString(tmp[1 .. $], null, null);
            tmp[offset++] = ']';
            tmp[offset++] = ':';
            offset += _a.ipv6.port.format_int(tmp[offset..$]);
        }

        if (buffer.ptr && tmp.ptr == stack_buffer.ptr)
        {
            if (buffer.length < offset)
                return -1;
            buffer[0 .. offset] = tmp[0 .. offset];
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        AddressFamily af;
        IPAddr a4 = void;
        IPv6Addr a6 = void;
        ushort port = 0;
        size_t taken = 0;

        // take address
        if (s.length >= 4 && (s[1] == '.' || s[2] == '.' || s[3] == '.'))
            af = AddressFamily.ipv4;
        else
            af = AddressFamily.ipv6;
        if (af == AddressFamily.ipv4)
        {
            taken = a4.fromString(s);
            if (taken < 0)
                return -1;
        }
        else
        {
            if (s.length > 0 && s[0] == '[')
                ++taken;
            size_t t = a6.fromString(s[taken..$]);
            if (t < 0)
                return -1;
            if (s[0] == '[' && (s.length < t + 2 || s[t + taken++] != ']'))
                return -1;
            taken += t;
        }

        // take port
        if (s.length > taken && s[taken] == ':')
        {
            size_t t;
            ulong p = s[++taken..$].parse_int(&t);
            if (t == 0 || p > ushort.max)
                return -1;
            taken += t;
            port = cast(ushort)p;
        }

        // success! store results..
        family = af;
        if (af == AddressFamily.ipv4)
        {
            _a.ipv4.addr = a4;
            _a.ipv4.port = port;
        }
        else
        {
            _a.ipv6.addr = a6;
            _a.ipv6.port = port;
            _a.ipv6.flow_info = 0;
            _a.ipv6.scopeId = 0;
        }
        return taken;
    }

    auto __debugOverview()
    {
        import urt.mem;
        char[] buffer = cast(char[])tempAllocator.alloc(47);
        ptrdiff_t len = toString(buffer, null, null);
        return buffer[0 .. len];
    }
}


unittest
{
    char[64] tmp;

    assert(~IPAddr(255, 255, 248, 0) == IPAddr(0, 0, 7, 255));
    assert((IPAddr(255, 255, 248, 0) & IPAddr(255, 0, 255, 255)) == IPAddr(255, 0, 248, 0));
    assert((IPAddr(255, 255, 248, 0) | IPAddr(255, 0, 255, 255)) == IPAddr(255, 255, 255, 255));
    assert((IPAddr(255, 255, 248, 0) ^ IPAddr(255, 0, 255, 255)) == IPAddr(0, 255, 7, 255));
    assert(IPNetworkAddress(IPAddr(), 21).net_mask() == IPAddr(0xFF, 0xFF, 0xF8, 0));
    assert(IPNetworkAddress(IPAddr(192, 168, 0, 10), 24).get_network() == IPAddr(192, 168, 0, 0));
    assert(IPNetworkAddress(IPAddr(192, 168, 0, 10), 24).get_local() == IPAddr(0, 0, 0, 10));

    assert(tmp[0 .. IPAddr(192, 168, 0, 1).toString(tmp, null, null)] == "192.168.0.1");
    assert(tmp[0 .. IPAddr(0, 0, 0, 0).toString(tmp, null, null)] == "0.0.0.0");

    IPAddr addr;
    assert(addr.fromString("192.168.0.1/24") == 11 && addr == IPAddr(192, 168, 0, 1));
    assert(addr.fromString("0.0.0.0:21") == 7 && addr == IPAddr(0, 0, 0, 0));
    addr |= IPAddr(1, 2, 3, 4);
    assert(addr == IPAddr(1, 2, 3, 4));

    assert(tmp[0 .. IPNetworkAddress(IPAddr(192, 168, 0, 0), 24).toString(tmp, null, null)] == "192.168.0.0/24");
    assert(tmp[0 .. IPNetworkAddress(IPAddr(0, 0, 0, 0), 0).toString(tmp, null, null)] == "0.0.0.0/0");

    IPNetworkAddress subnet;
    assert(subnet.fromString("192.168.0.0/24") == 14 && subnet == IPNetworkAddress(IPAddr(192, 168, 0, 0), 24));
    assert(subnet.fromString("0.0.0.0/0") == 9 && subnet == IPNetworkAddress(IPAddr(0, 0, 0, 0), 0));
    assert(subnet.fromString("1.2.3.4") == -1);
    assert(subnet.fromString("1.2.3.4/33") == -1);
    assert(subnet.fromString("1.2.3.4/a") == -1);

    assert(~IPv6Addr(0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFF0, 0, 0, 0) == IPv6Addr(0, 0, 0, 0, 0xF, 0xFFFF, 0xFFFF, 0xFFFF));
    assert((IPv6Addr(0xFFFF, 0, 1, 2, 3, 4, 5, 6) & IPv6Addr(0xFF00, 0, 3, 0, 0, 0, 0, 2)) == IPv6Addr(0xFF00, 0, 1, 0, 0, 0, 0, 2));
    assert((IPv6Addr(0xFFFF, 0, 1, 2, 3, 4, 5, 6) | IPv6Addr(0xFF00, 0, 3, 0, 0, 0, 0, 2)) == IPv6Addr(0xFFFF, 0, 3, 2, 3, 4, 5, 6));
    assert((IPv6Addr(0xFFFF, 0, 1, 2, 3, 4, 5, 6) ^ IPv6Addr(0xFF00, 0, 3, 0, 0, 0, 0, 2)) == IPv6Addr(0xFF, 0, 2, 2, 3, 4, 5, 4));
    assert(IPv6NetworkAddress(IPv6Addr(), 21).net_mask() == IPv6Addr(0xFFFF, 0xF800, 0, 0, 0, 0, 0, 0));
    assert(IPv6NetworkAddress(IPv6Addr.loopback, 64).get_network() == IPv6Addr.any);
    assert(IPv6NetworkAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 32).get_network() == IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0));
    assert(IPv6NetworkAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 32).get_local() == IPv6Addr(0, 0, 0, 1, 0, 0, 0, 1));

    assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1).toString(tmp, null, null)] == "2001:db8:0:1::1");
    assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 0, 1, 0, 0, 1).toString(tmp, null, null)] == "2001:db8::1:0:0:1");
    assert(tmp[0 .. IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0).toString(tmp, null, null)] == "2001:db8::");
    assert(tmp[0 .. IPv6Addr(0, 0, 0, 0, 0, 0, 0, 1).toString(tmp, null, null)] == "::1");
    assert(tmp[0 .. IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0).toString(tmp, null, null)] == "::");

    IPv6Addr addr6;
    assert(addr6.fromString("::") == 2 && addr6.s[] == [0,0,0,0,0,0,0,0]);
    assert(addr6.fromString("1::") == 3 && addr6.s[] == [1,0,0,0,0,0,0,0]);
    assert(addr6.fromString("::2") == 3 && addr6.s[] == [0,0,0,0,0,0,0,2]);
    assert(addr6.fromString("1::2") == 4 && addr6.s[] == [1,0,0,0,0,0,0,2]);
    assert(addr6.fromString("1:FFFF::2") == 9 && addr6.s[] == [1,0xFFFF,0,0,0,0,0,2]);
    assert(addr6.fromString("1:2:3:4:5:6:7:8") == 15 && addr6.s[] == [1,2,3,4,5,6,7,8]);
    assert(addr6.fromString("1:2:3:4") == -1);
    assert(addr6.fromString("1:2:3:4:5:6:7:8:9") == -1);
    assert(addr6.fromString("1:2:3:4:5:6:7:8:") == -1);
    assert(addr6.fromString("10000::2") == -1);
    assert(addr6.fromString(":2") == -1);
    assert(addr6.fromString("2:") == -1);
    assert(addr6.fromString(":2:") == -1);
    assert(addr6.fromString(":2::") == -1);
    assert(addr6.fromString(":2::1") == -1);
    assert(addr6.fromString("::2:") == -1);
    assert(addr6.fromString("1::2:") == -1);
    assert(addr6.fromString("1:::2") == -1);
    assert(addr6.fromString("::G") == 2 && addr6 == IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0));
    assert(addr6.fromString("1::2.3") == 4 && addr6 == IPv6Addr(1, 0, 0, 0, 0, 0, 0, 2));
    assert(addr6.fromString("1::2 4") == 4 && addr6 == IPv6Addr(1, 0, 0, 0, 0, 0, 0, 2));
    assert(addr6.fromString("2001:db8::1/24") == 11 && addr6 == IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));


    assert(tmp[0 .. IPv6NetworkAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 24).toString(tmp, null, null)] == "2001:db8::1/24");
    assert(tmp[0 .. IPv6NetworkAddress(IPv6Addr(), 0).toString(tmp, null, null)] == "::/0");

    IPv6NetworkAddress subnet6;
    assert(subnet6.fromString("2001:db8::1/24") == 14 && subnet6 == IPv6NetworkAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 24));
    assert(subnet6.fromString("::/0") == 4 && subnet6 == IPv6NetworkAddress(IPv6Addr(), 0));
    assert(subnet6.fromString("1::2") == -1);
    assert(subnet6.fromString("1::2/129") == -1);
    assert(subnet6.fromString("1::2/a") == -1);

    assert(tmp[0 .. InetAddress(IPAddr(192, 168, 0, 1), 12345).toString(tmp, null, null)] == "192.168.0.1:12345");
    assert(tmp[0 .. InetAddress(IPAddr(10, 0, 0, 0), 21).toString(tmp, null, null)] == "10.0.0.0:21");

    assert(tmp[0 .. InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 12345).toString(tmp, null, null)] == "[2001:db8:0:1::1]:12345");
    assert(tmp[0 .. InetAddress(IPv6Addr(), 21).toString(tmp, null, null)] == "[::]:21");

    InetAddress address;
    assert(address.fromString("192.168.0.1:21") == 14 && address == InetAddress(IPAddr(192, 168, 0, 1), 21));
    assert(address.fromString("10.0.0.1:12345") == 14 && address == InetAddress(IPAddr(10, 0, 0, 1), 12345));

    assert(address.fromString("[2001:db8:0:1::1]:12345") == 23 && address == InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 1, 0, 0, 0, 1), 12345));
    assert(address.fromString("[::]:21") == 7 && address == InetAddress(IPv6Addr(), 21));
    assert(address.fromString("[::]:a") == -1);
    assert(address.fromString("[::]:65536") == -1);

    // IPAddr sorting tests
    {
        IPAddr[8] expected = [
            IPAddr(0, 0, 0, 0),
            IPAddr(1, 2, 3, 4),
            IPAddr(1, 2, 3, 5),
            IPAddr(1, 2, 4, 4),
            IPAddr(10, 0, 0, 1),
            IPAddr(127, 0, 0, 1),
            IPAddr(192, 168, 1, 1),
            IPAddr(255, 255, 255, 255),
        ];

        for (size_t i = 0; i < expected.length - 1; ++i)
        {
            assert(expected[i].opCmp(expected[i]) == 0, "IPAddr self-comparison failed");
            assert(expected[i].opCmp(expected[i+1]) < 0, "IPAddr sorting is incorrect");
            assert(expected[i+1].opCmp(expected[i]) > 0, "IPAddr sorting is incorrect");
        }
    }

    // IPv6Addr sorting tests
    {
        IPv6Addr[14] expected = [
            IPv6Addr(0, 0, 0, 0, 0, 0, 0, 0), // ::
            IPv6Addr(0, 0, 0, 0, 0, 0, 0, 1), // ::1
            IPv6Addr(0, 0, 0, 0, 0, 0, 0, 2), // ::2
            IPv6Addr(0, 0, 0, 0, 0, 0, 9, 0), // ::9:0
            IPv6Addr(0, 0, 0, 0, 0, 8, 0, 0), // ::8:0:0
            IPv6Addr(0, 0, 0, 0, 7, 0, 0, 0), // ::7:0:0:0
            IPv6Addr(0, 0, 0, 6, 0, 0, 0, 0), // 0:0:0:6::
            IPv6Addr(0, 0, 5, 0, 0, 0, 0, 0), // 0:0:5::
            IPv6Addr(0, 4, 0, 0, 0, 0, 0, 0), // 0:4::
            IPv6Addr(1, 0, 0, 0, 0, 0, 0, 0), // 1::
            IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
            IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2),
            IPv6Addr(0xfe80, 0, 0, 0, 0, 0, 0, 1),
            IPv6Addr(0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff),
        ];

        for (size_t i = 0; i < expected.length - 1; ++i)
        {
            assert(expected[i].opCmp(expected[i]) == 0, "IPv6Addr self-comparison failed");
            assert(expected[i].opCmp(expected[i+1]) < 0, "IPv6Addr sorting is incorrect");
            assert(expected[i+1].opCmp(expected[i]) > 0, "IPv6Addr sorting is incorrect");
        }
    }

    // InetAddress sorting tests
    {
        InetAddress[10] expected = [
            // ipv4 sorted first
            InetAddress(IPAddr(10, 0, 0, 1), 80),
            InetAddress(IPAddr(127, 0, 0, 1), 8080),
            InetAddress(IPAddr(192, 168, 1, 1), 80),
            InetAddress(IPAddr(192, 168, 1, 1), 443),

            // ipv6 sorted next
            InetAddress(IPv6Addr(1, 0, 0, 0, 0, 0, 0, 0), 1024),
            InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 80, 0, 0),
            InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 433, 1, 1),
            InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 8080, 0, 0), // flow=0, scope=0
            InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 8080, 0, 1), // flow=0, scope=1
            InetAddress(IPv6Addr(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 8080, 1, 0), // flow=1, scope=0
        ];

        for (size_t i = 0; i < expected.length - 1; ++i)
        {
            assert(expected[i].opCmp(expected[i]) == 0, "InetAddress self-comparison failed");
            assert(expected[i].opCmp(expected[i+1]) < 0, "InetAddress sorting is incorrect");
            assert(expected[i+1].opCmp(expected[i]) > 0, "InetAddress sorting is incorrect");
        }
    }
}
