module urt.driver.rp2350.uart;

import urt.driver.rp2350 : clk_peri_hz, gpio_route_uart, unreset_wait, reset_io_bank0, reset_pads_bank0, reset_uart0, reset_uart1;
import urt.driver.uart : Parity, StopBits, UartConfig;

import core.volatile;

nothrow @nogc:

enum num_uarts = 2;
enum uint console_uart = 1;
enum uint uart_clock_hz = clk_peri_hz;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable base = uart_base(id);

    unreset_wait(reset_io_bank0 | reset_pads_bank0 | (id == 0 ? reset_uart0 : reset_uart1));
    gpio_route_uart(default_tx_gpio[id], 2, false);
    gpio_route_uart(default_rx_gpio[id], 2, true);

    uart_write_reg(base, uartcr, 0);

    immutable uint bauddiv_x64 = (uart_clock_hz * 4) / cfg.baud_rate;
    uart_write_reg(base, uartibrd, bauddiv_x64 / 64);
    uart_write_reg(base, uartfbrd, bauddiv_x64 % 64);

    uint lcr = (cfg.data_bits - 5) << 5 | (1 << 4);
    if (cfg.parity != Parity.none)
    {
        lcr |= 1 << 1;
        if (cfg.parity == Parity.even)
            lcr |= 1 << 2;
    }
    if (cfg.stop_bits != StopBits.one)
        lcr |= 1 << 3;                  // STP2: 2 stop bits
    uart_write_reg(base, uartlcr_h, lcr);

    uart_write_reg(base, uartcr, cr_uarten | cr_txe | cr_rxe);

    return true;
}

bool uart_hw_open(uint id, UartConfig cfg)
{
    return uart_hw_init(id, cfg);
}

void uart_hw_close(uint id)
{
    uart_write_reg(uart_base(id), uartcr, 0);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    immutable base = uart_base(id);
    auto buf = cast(ubyte[])buffer;
    ptrdiff_t n = 0;
    while (n < buf.length)
    {
        if (uart_read_reg(base, uartfr) & fr_rxfe)
            break;
        buf[n] = cast(ubyte)(uart_read_reg(base, uartdr) & 0xFF);
        ++n;
    }
    return n;
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    immutable base = uart_base(id);
    auto buf = cast(const(ubyte)[])data;
    ptrdiff_t n = 0;
    while (n < buf.length)
    {
        if (uart_read_reg(base, uartfr) & fr_txff)
            break;
        uart_write_reg(base, uartdr, buf[n]);
        ++n;
    }
    return n;
}

void uart_hw_poll(uint id) {}

bool uart_hw_check_errors(uint id)
{
    immutable base = uart_base(id);
    immutable rsr = uart_read_reg(base, uartrsr);
    if (rsr != 0)
    {
        uart_write_reg(base, uartrsr, 0);
        return true;
    }
    return false;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    // PL011 exposes FIFO empty/full flags, not an RX byte count.
    if (uart_read_reg(uart_base(id), uartfr) & fr_rxfe)
        return 0;
    return 1;
}

ptrdiff_t uart_hw_flush(uint id)
{
    immutable base = uart_base(id);
    while (uart_read_reg(base, uartfr) & fr_busy)
    {}
    return 0;
}

void uart0_hw_puts(const(char)[] s)
{
    enum ulong base = uart_base(console_uart);
    foreach (c; s)
    {
        while (volatileLoad(cast(uint*)(base + uartfr)) & fr_txff)
        {}
        volatileStore(cast(uint*)(base + uartdr), cast(uint)c);
    }
}

private:

enum
{
    uartdr     = 0x000,
    uartrsr    = 0x004,
    uartfr     = 0x018,
    uartibrd   = 0x024,
    uartfbrd   = 0x028,
    uartlcr_h  = 0x02C,
    uartcr     = 0x030,
}

enum
{
    fr_txff = 1 << 5,
    fr_rxfe = 1 << 4,
    fr_busy = 1 << 3,
}

enum
{
    cr_uarten = 1 << 0,
    cr_txe    = 1 << 8,
    cr_rxe    = 1 << 9,
}

ulong uart_base(uint id)
{
    return (id == 0) ? 0x40070000 : 0x40078000;
}

void uart_write_reg(ulong base, uint offset, uint val)
{
    volatileStore(cast(uint*)(base + offset), val);
}

uint uart_read_reg(ulong base, uint offset)
{
    return volatileLoad(cast(uint*)(base + offset));
}

static immutable ubyte[num_uarts] default_tx_gpio = [0, 8];
static immutable ubyte[num_uarts] default_rx_gpio = [1, 21];
