// The boot NOR through the SPI controller's PIO path. The memory-mapped window at 0x1FC00000 reads
// through the same controller, so nothing may read it while a transfer here is in progress.
module urt.driver.mt7621.spi_nor;

import urt.driver.mt7621 : mmio_read, mmio_write;
import urt.driver.irq : irq_global_disable, irq_global_set;

nothrow @nogc:

enum uint nor_sector_size = 0x1000;
enum uint nor_page_size = 256;

bool nor_read_id(ref ubyte[3] id)
{
    static immutable ubyte[1] cmd = [0x9F];
    return command(cmd[], id[]);
}

ubyte nor_status()
{
    static immutable ubyte[1] cmd = [0x05];
    ubyte[1] sr = 0xFF;
    command(cmd[], sr[]);
    return sr[0];
}

bool nor_read(uint addr, ubyte[] buf)
{
    immutable ubyte[4] cmd = [0x03, cast(ubyte)(addr >> 16), cast(ubyte)(addr >> 8), cast(ubyte)addr];
    return command(cmd[], buf);
}

bool nor_erase_sector(uint addr)
{
    assert((addr & (nor_sector_size - 1)) == 0);
    immutable ubyte[4] cmd = [0x20, cast(ubyte)(addr >> 16), cast(ubyte)(addr >> 8), cast(ubyte)addr];
    return write_enable() && command(cmd[], null) && wait_ready(500_000);
}

// Pages that are already erased are skipped.
bool nor_program(uint addr, const(ubyte)[] data)
{
    while (data.length)
    {
        immutable n = nor_page_size - (addr & (nor_page_size - 1)) < data.length ? nor_page_size - (addr & (nor_page_size - 1)) : data.length;
        bool blank = true;
        foreach (b; data[0 .. n])
            blank &= b == 0xFF;
        if (!blank)
        {
            immutable ubyte[4] cmd = [0x02, cast(ubyte)(addr >> 16), cast(ubyte)(addr >> 8), cast(ubyte)addr];
            if (!write_enable() || !command(cmd[], null, data[0 .. n]) || !wait_ready(10_000))
                return false;
        }
        addr += n;
        data = data[n .. $];
    }
    return true;
}


private:

enum uint spi_base = 0xBE00_0B00;

enum uint spi_trans  = spi_base + 0x00;
enum uint spi_opcode = spi_base + 0x04;
enum uint spi_master = spi_base + 0x28;
enum uint spi_morebuf = spi_base + 0x2C;
enum uint spi_polar  = spi_base + 0x38;

enum uint trans_start = 1 << 8;
enum uint trans_busy = 1 << 16;
enum uint master_more_bufmode = 1 << 2;
enum uint master_full_duplex = 1 << 10;
enum uint master_rs_slave_sel = 7u << 29;

enum size_t shift_bytes = 36;
enum size_t rx_bytes = 32;

enum ubyte sr_wip = 1 << 0;
enum ubyte sr_wel = 1 << 1;

bool write_enable()
{
    static immutable ubyte[1] wren = [0x06];
    return command(wren[], null) && (nor_status() & sr_wel) != 0;
}

bool wait_ready(uint polls)
{
    foreach (i; 0 .. polls)
    {
        if ((nor_status() & sr_wip) == 0)
            return true;
    }
    return false;
}

// One chip-select frame: `cmd`, then `payload`, then clock `rx` in.
bool command(const(ubyte)[] cmd, ubyte[] rx, const(ubyte)[] payload = null)
{
    immutable irq = irq_global_disable();
    immutable master = mmio_read(spi_master);
    mmio_write(spi_master, (master | master_rs_slave_sel | master_more_bufmode) & ~master_full_duplex);
    mmio_write(spi_polar, 1);

    ubyte[shift_bytes] buf = void;
    size_t pending = 0;
    bool ok = true;
    foreach (i; 0 .. cmd.length + payload.length)
    {
        if (pending == shift_bytes)
        {
            ok &= shift(buf, pending, null);
            pending = 0;
        }
        buf[pending++] = i < cmd.length ? cmd[i] : payload[i - cmd.length];
    }
    ok &= shift(buf, pending, rx);

    mmio_write(spi_polar, 0);
    mmio_write(spi_master, master);
    irq_global_set(irq);
    return ok;
}

// The first four bytes go out of OPCODE most significant first; the rest out of DATA0..7 little-endian.
bool shift(ref const ubyte[shift_bytes] buf, size_t tx, ubyte[] rx)
{
    if (tx)
    {
        uint op = 0;
        foreach (i; 0 .. tx < 4 ? tx : 4)
            op = op << 8 | buf[i];
        mmio_write(spi_opcode, op);
        for (size_t i = 4; i < tx; i += 4)
        {
            uint v = 0;
            foreach (k; 0 .. 4)
            {
                if (i + k < tx)
                    v |= buf[i + k] << (8 * k);
            }
            mmio_write(spi_opcode + cast(uint)i, v);
        }
    }
    while (tx || rx.length)
    {
        immutable n = rx.length < rx_bytes ? rx.length : rx_bytes;
        mmio_write(spi_morebuf, cast(uint)((tx < 4 ? tx : 4) * 8) << 24 | cast(uint)(n * 8) << 12 | cast(uint)(tx > 4 ? (tx - 4) * 8 : 0));
        tx = 0;
        mmio_write(spi_trans, mmio_read(spi_trans) | trans_start);
        uint polls = 100_000;
        while (mmio_read(spi_trans) & trans_busy)
        {
            if (--polls == 0)
                return false;
        }
        uint v;
        foreach (i; 0 .. n)
        {
            if ((i & 3) == 0)
                v = mmio_read(spi_opcode + 4 + cast(uint)i);
            rx[i] = cast(ubyte)v;
            v >>= 8;
        }
        rx = rx[n .. $];
    }
    return true;
}
