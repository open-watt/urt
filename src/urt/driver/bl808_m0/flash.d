// BL808 M0 access to its own SPI flash (a W25Q128JV on the M1s Dock). M0 executes from it, so each
// operation runs from RAM with interrupts off while the controller is taken from the instruction bus.
module urt.driver.bl808_m0.flash;

import core.volatile;
import urt.attribute : critical;
import urt.crc : Algorithm, calculate_crc;
import urt.driver.bl808.clock : mtime_hz;
import urt.endian : littleEndianToNative;

nothrow @nogc:

enum uint flash_sector_size = 4096;

bool flash_read(uint address, void[] buffer)
    => run(Op.read, address, cast(ubyte*)buffer.ptr, cast(uint)buffer.length);

bool flash_program(uint address, const(void)[] data)
    => run(Op.program, address, cast(ubyte*)data.ptr, cast(uint)data.length);

bool flash_erase(uint address, uint length)
    => (address | length) % flash_sector_size == 0 && run(Op.erase, address, null, length);

// Finds a partition in the table boot2 selects, so the layout lives in partition.toml alone: of its two
// copies the valid one, or the newer when both are.
bool flash_partition(ubyte type, out uint address, out uint size)
{
    align(4) ubyte[table_size][2] tables = void;
    immutable bool valid0 = read_table(partition_tables[0], tables[0]);
    immutable bool valid1 = read_table(partition_tables[1], tables[1]);
    if (!valid0 && !valid1)
        return false;
    const(ubyte)[] table = valid0 && (!valid1 || table_age(tables[0]) >= table_age(tables[1])) ? tables[0][] : tables[1][];

    foreach (i; 0 .. table_count(table))
    {
        const(ubyte)[] entry = table[16 + i * entry_size .. 16 + (i + 1) * entry_size];
        if (entry[0] != type)
            continue;
        immutable uint active = entry[2];
        if (active > 1)
            return false;
        address = littleEndianToNative!uint(entry[12 + active * 4 .. $][0 .. 4]);
        size = littleEndianToNative!uint(entry[20 + active * 4 .. $][0 .. 4]);
        return size != 0 && (address | size) % flash_sector_size == 0;
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

static immutable uint[2] partition_tables = [ 0xE000, 0xF000 ];
enum uint partition_max = 16;
enum uint entry_size = 36;
enum uint table_size = 16 + partition_max * entry_size + 4;
enum ubyte partition_type_media = 5;

// A header {magic, version, count, age, crc of the 12 before it}, the entries, then their crc.
bool read_table(uint address, ref ubyte[table_size] table)
{
    if (!flash_read(address, table[]) || cast(const(char)[])table[0 .. 4] != "BFPT")
        return false;
    immutable uint count = table_count(table[]);
    if (count > partition_max)
        return false;
    immutable uint entries_end = 16 + count * entry_size;
    return littleEndianToNative!uint(table[12 .. 16]) == calculate_crc!(Algorithm.crc32_iso_hdlc)(table[0 .. 12])
        && littleEndianToNative!uint(table[entries_end .. $][0 .. 4]) == calculate_crc!(Algorithm.crc32_iso_hdlc)(table[16 .. entries_end]);
}

uint table_count(const(ubyte)[] table)
    => littleEndianToNative!ushort(table[6 .. 8]);

uint table_age(const(ubyte)[] table)
    => littleEndianToNative!uint(table[8 .. 12]);

enum uint sf_ctrl = 0x2000_B000;
enum uint sf_buffer = 0x2000_B600;
enum uint buffer_size = 256;
enum uint page_size = 256;

enum uint ctrl_1 = 0x04, sahb_0 = 0x08, sahb_1 = 0x0C, sahb_2 = 0x10, image_offset = 0xA0;
enum uint owner_iahb = 1 << 28, ahb2sif_en = 1 << 30;
enum uint if_busy = 1 << 0, trigger = 1 << 1, rw_write = 1 << 23;
enum uint data_en = 1 << 24, dummy_en = 1 << 25, addr_en = 1 << 26, cmd_en = 1 << 27;
enum uint quad_io = 4 << 28;

enum ubyte cmd_write_enable = 0x06, cmd_read_status = 0x05, cmd_page_program = 0x02;
enum ubyte cmd_sector_erase = 0x20, cmd_fast_read = 0x0B, cmd_burst_wrap = 0x77;
enum ubyte status_busy = 1 << 0, status_write_enabled = 1 << 1;

// the instruction bus fills cache lines with 32-byte wrapped reads; commands need wrap off
enum uint wrap_off = 0xF0, wrap_32 = 0x40;

enum uint program_us = 10_000, erase_us = 1_000_000, transfer_us = 1_000;

enum Op : ubyte { read, program, erase }

@critical bool run(Op op, uint address, ubyte* data, uint length)
{
    uint mstatus;
    asm nothrow @nogc { "csrrci %0, mstatus, 8" : "=r" (mstatus); }

    // let an instruction fetch already in flight finish before the bus changes hands
    for (immutable uint start = now(); now() - start < mtime_hz / 1_000_000;) {}
    bool ok = idle();
    immutable uint offset = reg(image_offset);
    if (ok)
    {
        set_reg(ctrl_1, reg(ctrl_1) & ~(owner_iahb | ahb2sif_en));
        burst_wrap(wrap_off);
        set_reg(image_offset, 0);

        if (op == Op.read)
            ok = read(address, data, length);
        else if (op == Op.program)
            ok = program(address, data, length);
        else
            ok = erase(address, length);

        set_reg(image_offset, offset);
        burst_wrap(wrap_32);
        idle();
        set_reg(ctrl_1, reg(ctrl_1) | owner_iahb | ahb2sif_en);
    }

    if (mstatus & 8)
        asm nothrow @nogc { "csrsi mstatus, 8"; }
    return ok;
}

@critical bool read(uint address, ubyte* data, uint length)
{
    while (length)
    {
        immutable uint n = length < buffer_size ? length : buffer_size;
        if (!command(cmd_fast_read << 24 | address, frame(3, 1, (n + 3) & ~3u)))
            return false;
        from_buffer(data, n);
        address += n;
        data += n;
        length -= n;
    }
    return true;
}

@critical bool program(uint address, const(ubyte)* data, uint length)
{
    while (length)
    {
        uint n = page_size - (address & (page_size - 1));
        n = n < length ? n : length;
        if (!write_enable())
            return false;
        to_buffer(data, n);
        if (!command(cmd_page_program << 24 | address, frame(3, 0, n) | rw_write) || !ready(program_us))
            return false;
        address += n;
        data += n;
        length -= n;
    }
    return true;
}

@critical bool erase(uint address, uint length)
{
    for (uint end = address + length; address < end; address += flash_sector_size)
    {
        if (!write_enable() || !command(cmd_sector_erase << 24 | address, frame(3, 0, 0)) || !ready(erase_us))
            return false;
    }
    return true;
}

@critical bool write_enable()
    => command(cmd_write_enable << 24, frame(0, 0, 0)) && (status() & status_write_enabled) != 0;

@critical ubyte status()
{
    if (!command(cmd_read_status << 24, frame(0, 0, 1)))
        return status_busy;
    return cast(ubyte)volatileLoad(cast(uint*)sf_buffer);
}

@critical bool ready(uint limit_us)
{
    immutable uint start = now();
    while (status() & status_busy)
    {
        if (now() - start > limit_us * (mtime_hz / 1_000_000))
            return false;
    }
    return true;
}

@critical void burst_wrap(uint wrap)
{
    volatileStore(cast(uint*)sf_buffer, wrap);
    command(cmd_burst_wrap << 24, frame(0, 3, 1) | quad_io | rw_write);
}

// Field counts are bytes on the lines the mode selects, each stored less one.
@critical uint frame(uint addr_bytes, uint dummy_bytes, uint data_bytes)
    => cmd_en
     | (addr_bytes ? addr_en | (addr_bytes - 1) << 17 : 0)
     | (dummy_bytes ? dummy_en | (dummy_bytes - 1) << 12 : 0)
     | (data_bytes ? data_en | (data_bytes - 1) << 2 : 0);

@critical bool command(uint word, uint frame)
{
    if (!idle())
        return false;
    set_reg(sahb_0, reg(sahb_0) & ~trigger);
    set_reg(sahb_1, word);
    set_reg(sahb_2, 0);
    set_reg(sahb_0, frame);
    set_reg(sahb_0, frame | trigger);
    return idle();
}

@critical bool idle()
{
    immutable uint start = now();
    while (reg(sahb_0) & if_busy)
    {
        if (now() - start > transfer_us * (mtime_hz / 1_000_000))
            return false;
    }
    return true;
}

// The controller's buffer is taken a word at a time; the caller's bytes may sit at any alignment.
@critical void to_buffer(const(ubyte)* data, uint length)
{
    for (uint i = 0; i < length; i += 4)
    {
        uint word = 0;
        for (uint j = 0; j < 4 && i + j < length; ++j)
            word |= data[i + j] << (j * 8);
        volatileStore(cast(uint*)(sf_buffer + i), word);
    }
}

@critical void from_buffer(ubyte* data, uint length)
{
    for (uint i = 0; i < length; i += 4)
    {
        immutable uint word = volatileLoad(cast(uint*)(sf_buffer + i));
        for (uint j = 0; j < 4 && i + j < length; ++j)
            data[i + j] = cast(ubyte)(word >> (j * 8));
    }
}

pragma(inline, true) uint reg(uint offset)
    => volatileLoad(cast(uint*)(sf_ctrl + offset));

pragma(inline, true) void set_reg(uint offset, uint value)
{
    volatileStore(cast(uint*)(sf_ctrl + offset), value);
}

pragma(inline, true) uint now()
{
    uint t;
    asm nothrow @nogc { "rdtime %0" : "=r" (t); }
    return t;
}
