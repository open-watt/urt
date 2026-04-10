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

import sys.baremetal.uart : Parity, StopBits, UartConfig;

nothrow @nogc:

enum num_uarts = 2;
enum uint uart_clock_hz = 40_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

bool uart_hw_open(uint id, UartConfig cfg)
{
    // TODO: configure UART registers
    return true;
}

void uart_hw_close(uint id)
{
    // TODO: disable UART
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    // TODO: read from RX ring buffer
    return 0;
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    // TODO: write to TX FIFO/ring buffer
    return 0;
}

void uart_hw_poll(uint id)
{
    // TODO: poll RX/TX FIFOs
}

bool uart_hw_check_errors(uint id)
{
    // TODO: check error status register
    return false;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    // TODO: return ring buffer count
    return 0;
}

ptrdiff_t uart_hw_flush(uint id)
{
    // TODO: drain TX ring buffer
    return 0;
}

/// Transmit a string on UART0 (blocking, polled).
/// Used for early boot messages before the full console is up.
void uart0_hw_puts(const(char)[] s)
{
    // TODO: direct register write to UART0 TX FIFO
    // UART0 base: 0x2000_A000, FIFO_WDATA offset: 0x88
    // For now, no-op until registers are wired up.
}
