// MikroTik RouterBOOT's hard_config: the board's MACs, serial and model, as tagged records in NOR.
module urt.driver.routerboot;

version (RouterBoot):

import core.volatile;

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
    return hard_config(RouterBootTag.mac_count, b[]) == 4 ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : 0;
}


// Copies the tag's payload into `buf` and returns its length, truncated to the buffer; 0 if absent.
size_t hard_config(ushort tag, ubyte[] buf)
{
    if (!load(hard_config_magic))
        return 0;
    size_t len;
    immutable p = find_tag(_sector[4 .. $], tag, len);
    if (!p)
        return 0;
    immutable off = p + 4;
    immutable n = len < buf.length ? len : buf.length;
    buf[0 .. n] = _sector[off .. off + n];
    return n;
}

// Arms RouterBOOT's "try Ethernet once, then NAND" for the next reset; RouterBOOT disarms it itself.
bool netboot_once()
{
    if (!load(soft_config_magic))
        return false;
    size_t len;
    immutable p = find_tag(_sector[8 .. $], SoftTag.boot_device, len);
    if (!p || len != 4)
        return false;
    immutable off = p + 8;
    if (get32(off) == boot_device_eth_once)
        return true;
    put32(off, boot_device_eth_once);
    put32(4, soft_config_crc());

    immutable flash = _found[1] - nor_window;
    if (!nor_erase_sector(flash) || !nor_program(flash, _sector[]))
        return false;
    foreach (i; 0 .. hard_config_size / 4)
    {
        if (read32(_found[1] + i * 4) != get32(i * 4))
            return false;
    }
    return true;
}


private:

version (MT7621)
{
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

align(4) __gshared ubyte[hard_config_size] _sector;
__gshared uint[2] _found = [uint.max, uint.max];

uint read32(uint addr)
    => volatileLoad(cast(uint*)addr);

uint get32(size_t off)
    => _sector[off] | _sector[off + 1] << 8 | _sector[off + 2] << 16 | _sector[off + 3] << 24;

void put32(size_t off, uint v)
{
    foreach (i; 0 .. 4)
        _sector[off + i] = cast(ubyte)(v >> (i * 8));
}

// An Ethernet FCS over the whole sector with the CRC field as zero.
uint soft_config_crc()
{
    import urt.crc : Algorithm, calculate_crc;
    put32(4, 0);
    return calculate_crc!(Algorithm.crc32_iso_hdlc)(_sector[]);
}

// RouterBOOT's own partition is the first 256K of the NOR; both configs sit on 4K sectors inside it.
bool load(uint magic)
{
    immutable k = magic == soft_config_magic;
    if (_found[k] == uint.max)
    {
        _found[k] = 0;
        for (uint off = 0; off < 0x4_0000; off += hard_config_size)
        {
            if (read32(nor_window + off) == magic)
            {
                _found[k] = nor_window + off;
                break;
            }
        }
    }
    if (!_found[k])
        return false;
    foreach (i; 0 .. hard_config_size / 4)
        put32(i * 4, read32(_found[k] + i * 4));
    return true;
}

// Offset of the tag's payload within `records`, which start with a u32 node: id low, length high.
size_t find_tag(const(ubyte)[] records, ushort tag, out size_t len)
{
    for (size_t p = 0; p + 4 <= records.length;)
    {
        immutable node = records[p] | records[p + 1] << 8 | records[p + 2] << 16 | records[p + 3] << 24;
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

    assert(load(soft_config_magic));
    immutable stored = get32(4);
    assert(soft_config_crc() == stored);
    put32(4, stored);

    align(4) ubyte[256] pio = void;
    assert(nor_read(_found[1] - nor_window, pio[]));
    assert(pio[] == _sector[0 .. pio.length]);
    assert(read32(_found[1]) == soft_config_magic);
    assert((nor_status() & 1) == 0);
}
