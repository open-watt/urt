// MikroTik RouterBOOT's hard_config: the board's MACs, serial and model, as tagged records in NOR.
module urt.driver.routerboot;

version (RouterBoot):

import urt.endian : littleEndianToNative, nativeToLittleEndian;

nothrow @nogc:

enum RouterBootTag : ushort
{
    mac_address  = 0x04,
    board_code   = 0x05,
    serial       = 0x0B,
    memory_size  = 0x0D,
    mac_count    = 0x0E,
    product_name = 0x21,
}

// The serial is 12 hex digits; the MAC stands in if it is ever anything else.
ulong board_unique_id()
{
    char[16] serial = void;
    immutable len = hard_config(RouterBootTag.serial, cast(ubyte[])serial[]);
    ulong id = 0;
    size_t digits = 0;
    foreach (c; serial[0 .. len])
    {
        if (c == 0)
            break;
        immutable v = c >= '0' && c <= '9' ? c - '0' : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (v < 0)
        {
            digits = 0;
            break;
        }
        id = id << 4 | v;
        ++digits;
    }
    if (digits == 12 && id)
        return id;

    ubyte[6] mac = void;
    if (!board_mac(mac))
        return 0;
    id = 0;
    foreach (b; mac)
        id = id << 8 | b;
    return id;
}

bool board_mac(ref ubyte[6] mac)
    => hard_config(RouterBootTag.mac_address, mac[]) == 6;

uint board_mac_count()
{
    ubyte[4] b = void;
    return hard_config(RouterBootTag.mac_count, b[]) == 4 ? littleEndianToNative!uint(b) : 0;
}


// Copies the tag's payload into `buf` and returns its length, truncated to the buffer; 0 if absent.
size_t hard_config(ushort tag, ubyte[] buf)
{
    align(4) Sector s = void;
    if (!load(hard_config_magic, s))
        return 0;
    size_t len;
    immutable p = find_tag(s[4 .. $], tag, len);
    if (!p)
        return 0;
    immutable off = p + 4;
    immutable n = len < buf.length ? len : buf.length;
    buf[0 .. n] = s[off .. off + n];
    return n;
}

// Arms RouterBOOT's "try Ethernet once, then NAND" for the next reset; RouterBOOT disarms it itself.
bool netboot_once()
{
    align(4) Sector s = void;
    if (!load(soft_config_magic, s))
        return false;
    immutable stored = littleEndianToNative!uint(s[4 .. 8]);
    if (soft_config_crc(s) != stored)
        return false;
    size_t len;
    immutable p = find_tag(s[8 .. $], SoftTag.boot_device, len);
    if (!p || len != 4)
        return false;
    immutable off = p + 8;
    if (littleEndianToNative!uint(s[off .. off + 4][0 .. 4]) == boot_device_eth_once)
        return true;
    s[off .. off + 4] = nativeToLittleEndian(boot_device_eth_once);
    s[4 .. 8] = nativeToLittleEndian(soft_config_crc(s));

    immutable flash = _found[1] - nor_window;
    if (!nor_erase_sector(flash) || !nor_program(flash, s[]))
        return false;
    foreach (i; 0 .. hard_config_size / 4)
    {
        if (mmio_read(_found[1] + i * 4) != littleEndianToNative!uint(s[i * 4 .. i * 4 + 4][0 .. 4]))
            return false;
    }
    return true;
}


private:

version (MT7621)
{
    import urt.driver.mt7621 : mmio_read;
    import urt.driver.mt7621.spi_nor : nor_erase_sector, nor_program;
    enum uint nor_window = 0xBFC0_0000;
}
else
    static assert(false, "RouterBOOT: no memory-mapped NOR window for this platform");

enum SoftTag : ushort
{
    boot_device = 0x03,
}

enum uint boot_device_eth_once = 3;

enum uint hard_config_magic = 0x6472_6148;
enum uint soft_config_magic = 0x7466_6F53;
enum uint hard_config_size = 0x1000;

alias Sector = ubyte[hard_config_size];
__gshared uint[2] _found = [uint.max, uint.max];

// An Ethernet FCS over the whole sector with the CRC field as zero.
uint soft_config_crc(ref Sector s)
{
    import urt.crc : Algorithm, calculate_crc;
    s[4 .. 8] = 0;
    return calculate_crc!(Algorithm.crc32_iso_hdlc)(s[]);
}

// RouterBOOT's own partition is the first 256K of the NOR; both configs sit on 4K sectors inside it.
bool load(uint magic, ref Sector s)
{
    immutable k = magic == soft_config_magic;
    if (_found[k] == uint.max)
    {
        _found[k] = 0;
        for (uint off = 0; off < 0x4_0000; off += hard_config_size)
        {
            if (mmio_read(nor_window + off) == magic)
            {
                _found[k] = nor_window + off;
                break;
            }
        }
    }
    if (!_found[k])
        return false;
    foreach (i; 0 .. hard_config_size / 4)
        s[i * 4 .. i * 4 + 4] = nativeToLittleEndian(mmio_read(_found[k] + i * 4));
    return true;
}

// Offset of the tag's payload within `records`, which start with a u32 node: id low, length high.
size_t find_tag(const(ubyte)[] records, ushort tag, out size_t len)
{
    for (size_t p = 0; p + 4 <= records.length;)
    {
        immutable node = littleEndianToNative!uint(records[p .. p + 4][0 .. 4]);
        if (node == 0 || node == 0xFFFF_FFFF)
            break;
        immutable n = node >> 16;
        if ((node & 0xFFFF) == tag && p + 4 + n <= records.length)
        {
            len = n;
            return p + 4;
        }
        p += 4 + ((n + 3) & ~3);
    }
    return 0;
}


unittest
{
    import urt.driver.mt7621.spi_nor : nor_read, nor_read_id, nor_status;

    ubyte[3] id;
    assert(nor_read_id(id) && id[0] != 0 && id[0] != 0xFF);

    align(4) Sector s = void;
    assert(load(soft_config_magic, s));
    immutable stored = littleEndianToNative!uint(s[4 .. 8]);
    assert(soft_config_crc(s) == stored);

    align(4) ubyte[256] pio = void;
    assert(nor_read(_found[1] - nor_window, pio[]));
    assert(pio[0 .. 4] == s[0 .. 4] && pio[8 .. $] == s[8 .. pio.length]);
    assert(mmio_read(_found[1]) == soft_config_magic);
    assert((nor_status() & 1) == 0);
}
