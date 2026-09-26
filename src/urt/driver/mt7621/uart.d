module urt.driver.mt7621.uart;

import urt.driver.uart : Parity, StopBits, UartConfig;

import core.volatile;

nothrow @nogc:

enum num_uarts = 3;
enum uint first_uart = 1;
enum uint console_uart = 1;
enum uint uart_clock_hz = 50_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable base = uart_base(id);

    uint lcr = (cfg.data_bits - 5) & 3;
    if (cfg.stop_bits != StopBits.one)
        lcr |= lcr_stb;
    if (cfg.parity != Parity.none)
    {
        lcr |= lcr_pen;
        if (cfg.parity == Parity.even)
            lcr |= lcr_eps;
    }

    immutable uint div = (uart_clock_hz + cfg.baud_rate * 8) / (cfg.baud_rate * 16);
    write_reg(base, ier, 0);
    write_reg(base, lcr_reg, lcr_dlab);
    write_reg(base, dll, div & 0xFF);
    write_reg(base, dlm, (div >> 8) & 0xFF);
    write_reg(base, lcr_reg, lcr);
    write_reg(base, fcr, fcr_enable | fcr_clear_rx | fcr_clear_tx);
    write_reg(base, mcr, mcr_dtr | mcr_rts);
    return true;
}

bool uart_hw_open(uint id, UartConfig cfg)
    => uart_hw_init(id, cfg);

void uart_hw_close(uint id)
{
    write_reg(uart_base(id), ier, 0);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    immutable base = uart_base(id);
    auto buf = cast(ubyte[])buffer;
    ptrdiff_t n = 0;
    while (n < buf.length && (read_reg(base, lsr) & lsr_dr))
        buf[n++] = cast(ubyte)read_reg(base, rbr);
    return n;
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    immutable base = uart_base(id);
    auto buf = cast(const(ubyte)[])data;
    ptrdiff_t n = 0;
    while (n < buf.length && (read_reg(base, lsr) & lsr_thre))
    {
        // THRE means the whole 16-byte FIFO is empty.
        immutable end = n + 16 < buf.length ? n + 16 : buf.length;
        while (n < end)
            write_reg(base, thr, buf[n++]);
    }
    // The hEX S has no UART header, so the netconsole is the console and takes it all; the UART gets what its
    // FIFO has room for. Nothing is left for the caller to retry, so nothing repeats.
    if (id == console_uart)
    {
        import urt.driver.mt7621.netcon : netcon_put;
        netcon_put(cast(const(char)[])buf);
        return buf.length;
    }
    return n;
}

void uart_hw_poll(uint id) {}

bool uart_hw_check_errors(uint id)
    => (read_reg(uart_base(id), lsr) & (lsr_oe | lsr_pe | lsr_fe | lsr_bi)) != 0;

ptrdiff_t uart_hw_rx_pending(uint id)
    => (read_reg(uart_base(id), lsr) & lsr_dr) ? 1 : 0;

ptrdiff_t uart_hw_flush(uint id)
{
    immutable base = uart_base(id);
    while (!(read_reg(base, lsr) & lsr_temt))
    {}
    return 0;
}

void uart0_hw_puts(const(char)[] s)
{
    import urt.driver.mt7621.netcon : netcon_put;
    netcon_put(s);
    enum uint base = uart_base(console_uart);
    foreach (c; s)
    {
        while (!(read_reg(base, lsr) & lsr_thre))
        {}
        write_reg(base, thr, c);
    }
}


private:

enum : uint
{
    rbr     = 0x00,
    thr     = 0x00,
    dll     = 0x00,
    ier     = 0x04,
    dlm     = 0x04,
    fcr     = 0x08,
    lcr_reg = 0x0C,
    mcr     = 0x10,
    lsr     = 0x14,
}

enum : uint
{
    lcr_stb  = 1 << 2,
    lcr_pen  = 1 << 3,
    lcr_eps  = 1 << 4,
    lcr_dlab = 1 << 7,

    fcr_enable   = 1 << 0,
    fcr_clear_rx = 1 << 1,
    fcr_clear_tx = 1 << 2,

    mcr_dtr = 1 << 0,
    mcr_rts = 1 << 1,

    lsr_dr   = 1 << 0,
    lsr_oe   = 1 << 1,
    lsr_pe   = 1 << 2,
    lsr_fe   = 1 << 3,
    lsr_bi   = 1 << 4,
    lsr_thre = 1 << 5,
    lsr_temt = 1 << 6,
}

uint uart_base(uint id)
    => 0xBE00_0B00 + id * 0x100;

uint read_reg(uint base, uint offset)
    => volatileLoad(cast(uint*)(base + offset));

void write_reg(uint base, uint offset, uint value)
{
    volatileStore(cast(uint*)(base + offset), value);
}
