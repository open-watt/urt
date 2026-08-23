// Chip-burned identity, shared across BL618 and BL808. The efuse carries exactly one
// per-chip field -- the WiFi MAC, which is what the vendor's own EF_Ctrl_Read_Chip_ID
// hands back -- so the id is a hash of those six bytes. EF_CTRL and EF_DATA sit at
// 0x2005_6000 with the same field layout on both chips, so nothing here forks per chip.
//
// EF_DATA +0x14 wifi_mac_low    mac[5..2], little-endian in the word
// EF_DATA +0x18 wifi_mac_high   mac[1..0] in bits 0..15, 6-bit zero-count parity at 16
// EF_CTRL +0x800 ef_if_ctrl_0   1=autoload_done 2=busy 4=trig 18=auto_rd_en 21=int_clr
module urt.driver.bl_common.identity;

import core.volatile;

import urt.driver.timer : mtime_freq_hz, mtime_read;
import urt.hash : fnv1a64;

// The M0 build sets BL808 as well, so D0 has no flag of its own.
version (BL808_M0) {}
else version (BL808) version = BL808_D0;

@nogc nothrow:


ulong chip_unique_id()
{
    ubyte[6] mac = void;
    if (!read_mac(mac))
    {
        reload_efuse_r0();
        if (!read_mac(mac))
            return 0;
    }

    // The two BL808 cores run separate instances off the one MAC, and discovery drops any announce bearing our
    // own id. Only the low bit separates them, so the pair still reads as one chip in the last hex digits.
    version (BL808_D0) enum ulong core_tag = 1;
    else               enum ulong core_tag = 0;

    ulong id = fnv1a64(mac[]);
    if (id <= core_tag)
        id = core_tag + 1;

    return id ^ core_tag;
}


private:

enum uint EF_BASE       = 0x2005_6000;
enum uint WIFI_MAC_LOW  = EF_BASE + 0x14;
enum uint WIFI_MAC_HIGH = EF_BASE + 0x18;
enum uint EF_IF_CTRL_0  = EF_BASE + 0x800;

enum uint BIT_AUTOLOAD_DONE = 1U << 1;
enum uint BIT_BUSY          = 1U << 2;
enum uint BIT_TRIG          = 1U << 4;

// 0xbf in ef_if_prot_code_ctrl is the write key for the control fields; without it the write is dropped.
enum uint CTRL_IDLE = (0xBF << 8) | (1U << 18) | (1U << 21);


bool read_mac(ref ubyte[6] mac)
{
    const uint lo = mmio_load(WIFI_MAC_LOW);
    const uint hi = mmio_load(WIFI_MAC_HIGH);

    mac[5] = cast(ubyte)lo;
    mac[4] = cast(ubyte)(lo >> 8);
    mac[3] = cast(ubyte)(lo >> 16);
    mac[2] = cast(ubyte)(lo >> 24);
    mac[1] = cast(ubyte)hi;
    mac[0] = cast(ubyte)(hi >> 8);

    return !blank(mac[]);
}

// An unprogrammed cell reads 0, and a denied or unmapped bus read gives all-ones.
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

void reload_efuse_r0()
{
    wait_ready(0);

    mmio_store(EF_IF_CTRL_0, CTRL_IDLE);
    mmio_store(EF_IF_CTRL_0, CTRL_IDLE | BIT_TRIG);

    // BUSY does not assert immediately, and autoload_done still carries the boot ROM's load until it does.
    delay_us(10);

    wait_ready(BIT_AUTOLOAD_DONE);
    mmio_store(EF_IF_CTRL_0, CTRL_IDLE);
}

void wait_ready(uint set_bits)
{
    const ulong deadline = mtime_read() + mtime_freq_hz / 100;
    while (mtime_read() < deadline)
    {
        const uint v = mmio_load(EF_IF_CTRL_0);
        if (!(v & BIT_BUSY) && (v & set_bits) == set_bits)
            return;
    }
}

void delay_us(uint us)
{
    const ulong deadline = mtime_read() + (ulong(mtime_freq_hz) * us + 999_999) / 1_000_000;
    while (mtime_read() < deadline) {}
}

pragma(inline, true) uint mmio_load(uint addr)
    => volatileLoad(cast(uint*)cast(size_t)addr);

pragma(inline, true) void mmio_store(uint addr, uint val)
    => volatileStore(cast(uint*)cast(size_t)addr, val);
