// Chip-burned identity. Neither source is trustworthy alone -- the efuse UID carries its
// entropy in a few bytes and leaves the rest unprogrammed, and the MAC is a fixed OUI plus
// a serial -- so every burned byte we can reach is hashed together into the node id.
module urt.driver.bk7231.identity;

version (Beken):

nothrow @nogc:

ulong chip_unique_id()
{
    ubyte[14] material = void;
    size_t n = 0;

    ubyte[8] uid = void;
    immutable ubyte uid_len = ow_efuse_uid_len();
    if (read_efuse(ow_efuse_uid_addr(), uid_len, uid[]))
    {
        material[n .. n + uid_len] = uid[0 .. uid_len];
        n += uid_len;
    }

    ubyte[6] mac = void;
    immutable ubyte mac_len = ow_efuse_mac_len();
    if (read_efuse(ow_efuse_mac_addr(), mac_len, mac[]))
    {
        material[n .. n + mac_len] = mac[0 .. mac_len];
        n += mac_len;
    }
    else if (manual_cal_get_macaddr_from_flash(mac.ptr) != 0 && !blank(mac[]))
    {
        material[n .. n + 6] = mac[];
        n += 6;
    }

    if (n == 0)
        return 0;

    import urt.hash : fnv1a64;
    ulong id = fnv1a64(material[0 .. n]);
    return id ? id : 1;
}

private:

extern(C) int ow_efuse_read_byte(ubyte addr, ubyte* value);
extern(C) ubyte ow_efuse_uid_addr();
extern(C) ubyte ow_efuse_uid_len();
extern(C) ubyte ow_efuse_mac_addr();
extern(C) ubyte ow_efuse_mac_len();

// Returns zero on failure, per the vendor SDK's own callers.
extern(C) int manual_cal_get_macaddr_from_flash(ubyte* mac);

// An unprogrammed cell reads 0xFF, so all-ones is as blank as all-zeroes.
bool blank(const(ubyte)[] bytes)
{
    ubyte and = 0xFF, or = 0;
    foreach (b; bytes)
    {
        and &= b;
        or |= b;
    }
    return or == 0 || and == 0xFF;
}

bool read_efuse(ubyte addr, ubyte len, ubyte[] dst)
{
    if (len == 0 || len > dst.length)
        return false;
    foreach (i; 0 .. len)
    {
        if (ow_efuse_read_byte(cast(ubyte)(addr + i), &dst[i]) != 0)
            return false;
    }
    return !blank(dst[0 .. len]);
}
