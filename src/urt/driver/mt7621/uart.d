module urt.driver.mt7621.uart;

import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartError, uart_rate_close;
import urt.driver.uart_core : puts_stall_spins, tx_drain_limit;
import urt.time : getTime;

import core.volatile;

nothrow @nogc:

enum num_uarts = 3;
enum uint first_uart = 1;
enum uint console_uart = 1;
enum uint uart_clock_hz = 50_000_000;
enum uint uart_drive_modes = 1 << DriveMode.polled;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd;
enum uint uart_stop_bits = 1 << StopBits.one | 1 << StopBits.two;
enum uint uart_flow_controls = 1 << FlowControl.none;
enum bool uart_has_rs485 = false;
enum bool uart_has_pin_select = false;

bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable uint div = divisor(cfg.baud_rate);
    if (!div)
        return false;
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
{
    _errors[id - first_uart] = UartError.none;
    return uart_hw_init(id, cfg);
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    write_reg(uart_base(id), ier, 0);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    immutable base = uart_base(id);
    auto buf = cast(ubyte[])buffer;
    ptrdiff_t n = 0;
    while (n < buf.length && (line_status(id) & lsr_dr))
        buf[n++] = cast(ubyte)read_reg(base, rbr);
    return n;
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    immutable base = uart_base(id);
    auto buf = cast(const(ubyte)[])data;
    ptrdiff_t n = 0;
    while (n < buf.length && (line_status(id) & lsr_thre))
    {
        // THRE means the whole 16-byte FIFO is empty.
        immutable end = n + 16 < buf.length ? n + 16 : buf.length;
        while (n < end)
            write_reg(base, thr, buf[n++]);
    }
    // TODO: the hEX S has no UART header, so the netconsole copies the console until OpenWatt carries a UDP log sink
    if (id == console_uart)
    {
        import urt.driver.mt7621.netcon : netcon_put;
        netcon_put(cast(const(char)[])buf[0 .. n]);
    }
    return n;
}

void uart_hw_poll(uint id) {}

UartError uart_hw_check_errors(uint id)
{
    line_status(id);
    immutable errors = _errors[id - first_uart];
    _errors[id - first_uart] = UartError.none;
    return errors;
}

ptrdiff_t uart_hw_rx_pending(uint id)
    => (line_status(id) & lsr_dr) ? 1 : 0;

ptrdiff_t uart_hw_flush(uint id)
{
    immutable deadline = getTime() + tx_drain_limit;
    while (!(line_status(id) & lsr_temt) && getTime() < deadline)
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
        uint spins = 0;
        while (!(read_reg(base, lsr) & lsr_thre))
        {
            if (++spins == puts_stall_spins)
                return;
        }
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
    lsr_errors = lsr_oe | lsr_pe | lsr_fe | lsr_bi,
}

uint uart_base(uint id)
    => 0xBE00_0B00 + id * 0x100;

// The 16550 divisor latch, rounded: 16 clocks a bit, 1 to 0xFFFF.
uint divisor(uint baud) pure
{
    immutable ulong d = (ulong(uart_clock_hz) + ulong(baud) * 8) / (ulong(baud) * 16);
    return d >= 1 && d <= 0xFFFF && uart_rate_close(baud, uart_clock_hz, 16 * d) ? cast(uint)d : 0;
}

// Reading LSR clears its error bits, so every read keeps them for uart_hw_check_errors.
uint line_status(uint id)
{
    immutable uint s = read_reg(uart_base(id), lsr);
    if (s & lsr_errors)
        _errors[id - first_uart] = cast(UartError)(_errors[id - first_uart] | lsr_error_kinds[(s & lsr_errors) >> 1]);
    return s;
}

// LSR bits 1-4: overrun, parity, framing, break
static immutable UartError[16] lsr_error_kinds = () {
    UartError[16] t;
    foreach (i; 0 .. 16)
        t[i] = cast(UartError)((i & 1 ? UartError.overrun : 0) | (i & 2 ? UartError.parity : 0) | (i & 4 ? UartError.framing : 0) | (i & 8 ? UartError.break_ : 0));
    return t;
}();

__gshared UartError[num_uarts] _errors;

uint read_reg(uint base, uint offset)
    => volatileLoad(cast(uint*)(base + offset));

void write_reg(uint base, uint offset, uint value)
{
    volatileStore(cast(uint*)(base + offset), value);
}


unittest
{
    assert(divisor(115_200) == 27, "115200 from 50 MHz");
    assert(!divisor(40) && !divisor(4_000_000), "past the divisor latch either way");
}
