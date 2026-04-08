/// BL618 UART driver
///
/// BL616/BL618 has 2 UARTs sharing the same register-level IP block as BL808:
///
///   UART0  0x2000_A000   Default console
///   UART1  0x2000_A100   General purpose
///
/// Register layout is identical to BL808 (BL6xx/BL8xx common UART IP).
/// Single-core E907 has direct PLIC access to all UART interrupts.
///
/// TODO: Implement full driver from BL616 register map.
///       Stubbed to provide the API surface needed by serial.d.
module sys.bl618.uart;

nothrow @nogc:

enum UartId : uint { uart0 = 0, uart1 = 1 }

enum UartParity : ubyte { none, even, odd }
enum UartStopBits : ubyte { one, one_point_five, two }

struct UartConfig
{
    uint baud_rate = 115200;
    ubyte data_bits = 8;
    UartParity parity = UartParity.none;
    UartStopBits stop_bits = UartStopBits.one;
}

/// Open and configure a UART.
bool uart_open(UartId id, UartConfig cfg)
{
    // TODO: configure UART registers
    return true;
}

/// Close a UART.
void uart_close(UartId id)
{
    // TODO: disable UART
}

/// Read available bytes from UART RX ring buffer.
ptrdiff_t uart_read(UartId id, void[] buffer)
{
    // TODO: read from RX ring buffer
    return 0;
}

/// Write bytes to UART TX.
ptrdiff_t uart_write(UartId id, const(void)[] data)
{
    // TODO: write to TX FIFO/ring buffer
    return 0;
}

/// Poll hardware FIFOs — call from update() to drain/fill ring buffers.
void uart_poll(UartId id)
{
    // TODO: poll RX/TX FIFOs
}

/// Check for UART errors (framing, parity, overflow).
bool uart_check_errors(UartId id)
{
    // TODO: check error status register
    return false;
}

/// Return number of bytes available in RX buffer.
ptrdiff_t uart_rx_pending(UartId id)
{
    // TODO: return ring buffer count
    return 0;
}

/// Flush TX buffer (blocking).
ptrdiff_t uart_flush(UartId id)
{
    // TODO: drain TX ring buffer
    return 0;
}

/// Transmit a string on UART0 (blocking, polled).
/// Used for early boot messages before the full console is up.
void uart0_puts(const(char)[] s)
{
    // TODO: direct register write to UART0 TX FIFO
    // UART0 base: 0x2000_A000, FIFO_WDATA offset: 0x88
    // For now, no-op until registers are wired up.
}
