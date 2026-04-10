// RP2350 UART driver
//
// RP2350 has 2x PL011 UARTs:
//   UART0  0x4007_0000   Default console (GPIO0=TX, GPIO1=RX)
//   UART1  0x4007_8000   General purpose (GPIO4=TX, GPIO5=RX typical)
//
// PL011 register layout (ARM PrimeCell UART).
module sys.rp2350.uart;

import core.volatile;

import sys.baremetal.uart : Parity, StopBits, UartConfig;

nothrow @nogc:

enum num_uarts = 2;
enum uint uart_clock_hz = 6_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

// PL011 register offsets
private enum
{
    UARTDR     = 0x000,   // Data register
    UARTRSR    = 0x004,   // Receive status / error clear
    UARTFR     = 0x018,   // Flag register
    UARTILPR   = 0x020,   // IrDA low-power counter
    UARTIBRD   = 0x024,   // Integer baud rate divisor
    UARTFBRD   = 0x028,   // Fractional baud rate divisor
    UARTLCR_H  = 0x02C,   // Line control
    UARTCR     = 0x030,   // Control register
    UARTIFLS   = 0x034,   // Interrupt FIFO level select
    UARTIMSC   = 0x038,   // Interrupt mask set/clear
    UARTRIS    = 0x03C,   // Raw interrupt status
    UARTMIS    = 0x040,   // Masked interrupt status
    UARTICR    = 0x044,   // Interrupt clear
    UARTDMACR  = 0x048,   // DMA control
}

// Flag register bits
private enum
{
    FR_TXFF = 1 << 5,     // TX FIFO full
    FR_RXFE = 1 << 4,     // RX FIFO empty
    FR_BUSY = 1 << 3,     // UART busy transmitting
}

// Control register bits
private enum
{
    CR_UARTEN = 1 << 0,   // UART enable
    CR_TXE    = 1 << 8,   // TX enable
    CR_RXE    = 1 << 9,   // RX enable
}

private ulong uart_base(uint id)
{
    return (id == 0) ? 0x40070000 : 0x40078000;
}

private void uart_write_reg(ulong base, uint offset, uint val)
{
    volatileStore(cast(uint*)(base + offset), val);
}

private uint uart_read_reg(ulong base, uint offset)
{
    return volatileLoad(cast(uint*)(base + offset));
}

// Assumed peripheral clock -- ring oscillator ~6MHz at boot.
// After PLL init this should be updated to the actual peri_clk frequency.
private __gshared uint peri_clk_hz = 6_000_000;

bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable base = uart_base(id);

    // Disable UART while configuring
    uart_write_reg(base, UARTCR, 0);

    // Baud rate: BAUDDIV = peri_clk / (16 * baud)
    // Integer part = BAUDDIV
    // Fractional part = (frac * 64 + 0.5)
    immutable uint bauddiv_x64 = (peri_clk_hz * 4) / cfg.baud_rate;
    immutable uint ibrd = bauddiv_x64 / 64;
    immutable uint fbrd = bauddiv_x64 % 64;
    uart_write_reg(base, UARTIBRD, ibrd);
    uart_write_reg(base, UARTFBRD, fbrd);

    // Line control: 8N1, FIFO enable
    uint lcr = 0;
    lcr |= (cfg.data_bits - 5) << 5;   // WLEN: 5=0b00, 6=0b01, 7=0b10, 8=0b11
    lcr |= 1 << 4;                      // FEN: enable FIFOs
    if (cfg.parity != Parity.none)
    {
        lcr |= 1 << 1;                  // PEN: parity enable
        if (cfg.parity == Parity.even)
            lcr |= 1 << 2;              // EPS: even parity
    }
    if (cfg.stop_bits != StopBits.one)
        lcr |= 1 << 3;                  // STP2: 2 stop bits
    uart_write_reg(base, UARTLCR_H, lcr);

    // Enable UART, TX, RX
    uart_write_reg(base, UARTCR, CR_UARTEN | CR_TXE | CR_RXE);

    return true;
}

bool uart_hw_open(uint id, UartConfig cfg)
{
    return uart_hw_init(id, cfg);
}

void uart_hw_close(uint id)
{
    uart_write_reg(uart_base(id), UARTCR, 0);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    immutable base = uart_base(id);
    auto buf = cast(ubyte[])buffer;
    ptrdiff_t n = 0;
    while (n < buf.length)
    {
        if (uart_read_reg(base, UARTFR) & FR_RXFE)
            break;
        buf[n] = cast(ubyte)(uart_read_reg(base, UARTDR) & 0xFF);
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
        if (uart_read_reg(base, UARTFR) & FR_TXFF)
            break;
        uart_write_reg(base, UARTDR, buf[n]);
        ++n;
    }
    return n;
}

void uart_hw_poll(uint id)
{
    // PL011 FIFOs handle buffering -- nothing to poll
}

bool uart_hw_check_errors(uint id)
{
    immutable base = uart_base(id);
    immutable rsr = uart_read_reg(base, UARTRSR);
    if (rsr != 0)
    {
        uart_write_reg(base, UARTRSR, 0);  // Clear errors
        return true;
    }
    return false;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    // PL011 doesn't expose FIFO level directly in a simple way.
    // Return 1 if data available, 0 otherwise.
    if (uart_read_reg(uart_base(id), UARTFR) & FR_RXFE)
        return 0;
    return 1;
}

ptrdiff_t uart_hw_flush(uint id)
{
    immutable base = uart_base(id);
    while (uart_read_reg(base, UARTFR) & FR_BUSY)
    {}
    return 0;
}

// Blocking puts for early boot (before the serial stream is up)
void uart0_hw_puts(const(char)[] s)
{
    enum ulong base = 0x40070000;
    foreach (c; s)
    {
        while (volatileLoad(cast(uint*)(base + UARTFR)) & FR_TXFF)
        {}
        volatileStore(cast(uint*)(base + UARTDR), cast(uint)c);
    }
}
