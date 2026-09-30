// BL808 M0 access to its own SPI flash, through the vendor's XIP-aware flash driver.
//
// M0 executes from this flash, so every operation suspends XIP; the vendor
// XIP_SFlash_*_Need_Lock functions do that from ITCM, and interrupts stay off
// around them because an interrupt vectoring into flash mid-operation would fetch
// garbage. Addresses are physical flash offsets. Buffers must be in RAM: the
// controller cannot read from XIP while XIP is suspended.
module urt.driver.bl808_m0.flash;

import urt.endian : littleEndianToNative;

nothrow @nogc:

enum uint flash_sector_size = 4096;

bool flash_read(uint address, void[] buffer)
{
    if (!flash_config_ready())
        return false;
    return read_locked(address, cast(ubyte*)buffer.ptr, cast(uint)buffer.length) == 0;
}

bool flash_program(uint address, const(void)[] data)
{
    if (!flash_config_ready())
        return false;
    return write_locked(address, cast(ubyte*)data.ptr, cast(uint)data.length) == 0;
}

bool flash_erase(uint address, uint length)
{
    if (!flash_config_ready() || (address | length) % flash_sector_size != 0)
        return false;
    return erase_locked(address, length) == 0;
}

// Finds a partition in the table boot2 reads, so the layout lives in partition.toml alone.
bool flash_partition(ubyte type, out uint address, out uint size)
{
    align(4) ubyte[16 + partition_max * 36] table = void;
    if (!flash_read(partition_table, table[]))
        return false;
    if (cast(const(char)[])table[0 .. 4] != "BFPT")
        return false;
    uint count = littleEndianToNative!ushort(table[6 .. 8]);
    if (count > partition_max)
        return false;
    foreach (i; 0 .. count)
    {
        const(ubyte)[] entry = table[16 + i * 36 .. 16 + i * 36 + 36];
        if (entry[0] != type)
            continue;
        address = littleEndianToNative!uint(entry[12 .. 16]);
        size = littleEndianToNative!uint(entry[20 .. 24]);
        return true;
    }
    return false;
}

extern(C) bool urt_flash_fs_region(uint* address, uint* size, uint* erase_size)
{
    *erase_size = flash_sector_size;
    return flash_partition(partition_type_media, *address, *size);
}

extern(C) bool urt_flash_read(uint address, void* buffer, uint size)
    => flash_read(address, buffer[0 .. size]);

extern(C) bool urt_flash_program(uint address, const(void)* data, uint size)
    => flash_program(address, data[0 .. size]);

extern(C) bool urt_flash_erase(uint address, uint size)
    => flash_erase(address, size);


private:

enum uint partition_table = 0xE000;
enum uint partition_max = 16;
enum ubyte partition_type_media = 5;
enum uint glb_hw_rsv1 = 0x2000_05C4;
enum uint flash_id_valid = 0x8000_0000;

extern(C) int SF_Cfg_Get_Flash_Cfg_Need_Lock(uint flash_id, void* cfg, ubyte group, int bank);
extern(C) int XIP_SFlash_Read_Need_Lock(void* cfg, uint address, ubyte* data, uint length, ubyte group, int bank);
extern(C) int XIP_SFlash_Write_Need_Lock(void* cfg, uint address, ubyte* data, uint length, ubyte group, int bank);
extern(C) int XIP_SFlash_Erase_Need_Lock(void* cfg, uint address, int length, ubyte group, int bank);

// SPI_Flash_Cfg_Type, 84 bytes packed.
align(4) __gshared ubyte[84] g_flash_cfg;
__gshared bool g_flash_cfg_valid;

bool flash_config_ready()
{
    if (!g_flash_cfg_valid)
        g_flash_cfg_valid = load_config() == 0;
    return g_flash_cfg_valid;
}

pragma(inline, true) uint irq_save()
{
    uint mstatus;
    asm nothrow @nogc { "csrrci %0, mstatus, 8" : "=r" (mstatus); }
    return mstatus;
}

pragma(inline, true) void irq_restore(uint mstatus)
{
    if (mstatus & 8)
        asm nothrow @nogc { "csrsi mstatus, 8"; }
}

// Boot leaves the flash's JEDEC id in GLB_HW_RSV1; the config comes from the vendor's table
// without touching the flash.
int load_config()
{
    import core.volatile : volatileLoad;
    uint id = volatileLoad(cast(uint*)glb_hw_rsv1);
    if (!(id & flash_id_valid))
        return -1;
    return SF_Cfg_Get_Flash_Cfg_Need_Lock(id & ~flash_id_valid, g_flash_cfg.ptr, 0, 0);
}

int read_locked(uint address, ubyte* data, uint length)
{
    uint s = irq_save();
    int r = XIP_SFlash_Read_Need_Lock(g_flash_cfg.ptr, address, data, length, 0, 0);
    irq_restore(s);
    return r;
}

int write_locked(uint address, ubyte* data, uint length)
{
    uint s = irq_save();
    int r = XIP_SFlash_Write_Need_Lock(g_flash_cfg.ptr, address, data, length, 0, 0);
    irq_restore(s);
    return r;
}

int erase_locked(uint address, uint length)
{
    uint s = irq_save();
    int r = XIP_SFlash_Erase_Need_Lock(g_flash_cfg.ptr, address, length, 0, 0);
    irq_restore(s);
    return r;
}
