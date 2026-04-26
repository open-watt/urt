// ESP32 UART driver -- D wrapper over the C shim (ow_shim.c)
//
// The C shim calls ESP-IDF UART HAL directly (no FreeRTOS UART driver).
// GPIO pin routing is done via the ROM GPIO matrix.
//
// 3 UART ports: UART0 (console), UART1, UART2.
// UART0 TX/RX defaults set by bootloader (typically GPIO43/44 on S3).
module urt.driver.esp32.uart;

import urt.driver.uart : Parity, StopBits, UartConfig;

nothrow @nogc:


// SOC_UART_NUM per chip variant
version (ESP32)         enum num_uarts = 3;
else version (ESP32_S3) enum num_uarts = 3;
else version (ESP32_P4) enum num_uarts = 6;
else version (ESP32_S2) enum num_uarts = 2;
else version (ESP32_C2) enum num_uarts = 2;
else version (ESP32_C3) enum num_uarts = 2;
else version (ESP32_C5) enum num_uarts = 2;
else version (ESP32_C6) enum num_uarts = 3;
else version (ESP32_H2) enum num_uarts = 2;
else static assert(false, "unknown Espressif chip -- add num_uarts");

enum uint uart_clock_hz = 80_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

bool uart_hw_open(uint id, ref const UartConfig cfg)
{
    if (id >= num_uarts)
        return false;
    byte tx = cfg.tx_gpio == ubyte.max ? -1 : cast(byte)cfg.tx_gpio;
    byte rx = cfg.rx_gpio == ubyte.max ? -1 : cast(byte)cfg.rx_gpio;
    return ow_uart_open(id, cfg.baud_rate, cfg.data_bits, cast(ubyte)cfg.stop_bits, cast(ubyte)cfg.parity, tx, rx) != 0;
}

void uart_hw_close(uint id)
{
    ow_uart_close(id);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    return ow_uart_read(id, cast(ubyte*)buffer.ptr, cast(int)buffer.length);
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    return ow_uart_write(id, cast(const(ubyte)*)data.ptr, cast(int)data.length);
}

void uart_hw_poll(uint id)
{
    // ESP32 UART HAL is polled via read/rx_pending -- no separate poll needed
}

bool uart_hw_check_errors(uint id)
{
    // TODO: check UART error status register via HAL
    return false;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    return ow_uart_rx_pending(id);
}

ptrdiff_t uart_hw_flush(uint id)
{
    return ow_uart_flush(id);
}

bool uart_tx_idle(uint id)
{
    return ow_uart_tx_idle(id) != 0;
}

void uart0_hw_puts(const(char)[] s)
{
    foreach (ch; s)
        esp_rom_uart_putc(ch);
}

private:

extern(C) nothrow @nogc
{
    void esp_rom_uart_putc(char c) nothrow @nogc;

    int ow_uart_open(uint port, uint baud_rate, ubyte data_bits, ubyte stop_bits, ubyte parity, byte tx_gpio, byte rx_gpio);
    void ow_uart_close(uint port);
    int ow_uart_read(uint port, ubyte* buf, int len);
    int ow_uart_write(uint port, const(ubyte)* buf, int len);
    int ow_uart_rx_pending(uint port);
    int ow_uart_tx_idle(uint port);
    int ow_uart_flush(uint port);
}
