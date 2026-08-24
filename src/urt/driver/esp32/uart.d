// ESP32 UART driver -- D wrapper over the C shim (ow_shim.c).
//
// 3 UART ports: UART0 (console), UART1, UART2.
// UART0 TX/RX defaults set by bootloader (typically GPIO43/44 on S3).
module urt.driver.esp32.uart;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.driver.uart : Parity, StopBits, Uart, UartCallbackContext, UartError,
    UartConfig, UartRxCallback;

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
enum bool has_irq_driven_uart = true;
enum bool has_dma_driven_uart = false;

bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    if (id >= num_uarts)
        return false;
    if (cfg.rs485.enabled &&
        (cfg.rs485.de_assert_us != 0 || cfg.rs485.de_deassert_us != 0 ||
         cfg.rs485.turnaround_us != 0))
        return false;

    byte tx = cfg.tx_gpio == ubyte.max ? -1 : cast(byte)cfg.tx_gpio;
    byte rx = cfg.rx_gpio == ubyte.max ? -1 : cast(byte)cfg.rx_gpio;
    byte de = cfg.rs485.enabled && cfg.rs485.de_gpio != ubyte.max
        ? cast(byte)cfg.rs485.de_gpio : -1;
    atomicStore!(MemoryOrder.release)(_rx_callback_bits[id],
                                      cast(size_t)rx_cb);
    bool opened = ow_uart_open(id, cfg.baud_rate, cfg.data_bits,
                               cast(ubyte)cfg.stop_bits,
                               cast(ubyte)cfg.parity,
                               tx, rx, cfg.rs485.enabled, de,
                               cfg.rs485.de_active_high,
                               &rx_ready) != 0;
    if (!opened)
        atomicStore!(MemoryOrder.release)(_rx_callback_bits[id],
                                          cast(size_t)0);
    return opened;
}

void uart_hw_close(uint id)
{
    if (id < num_uarts)
        atomicStore!(MemoryOrder.release)(_rx_callback_bits[id],
                                          cast(size_t)0);
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
    ow_uart_poll(id);
}

UartError uart_hw_check_errors(uint id)
{
    return cast(UartError)ow_uart_check_errors(id);
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    return ow_uart_rx_pending(id);
}

ptrdiff_t uart_hw_tx_pending(uint id)
{
    return ow_uart_tx_pending(id);
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

shared size_t[num_uarts] _rx_callback_bits;

extern(C) void rx_ready(uint port, size_t available)
{
    if (port >= num_uarts)
        return;
    auto callback = cast(UartRxCallback)
        atomicLoad!(MemoryOrder.acquire)(_rx_callback_bits[port]);
    if (callback !is null)
        callback(Uart(cast(ubyte)port), available, UartCallbackContext.thread);
}

extern(C) nothrow @nogc
{
    void esp_rom_uart_putc(char c) nothrow @nogc;

    int ow_uart_open(uint port, uint baud_rate, ubyte data_bits, ubyte stop_bits,
                     ubyte parity, byte tx_gpio, byte rx_gpio,
                     bool rs485_enabled, byte de_gpio, bool de_active_high,
                     void function(uint, size_t) nothrow @nogc rx_ready);
    void ow_uart_close(uint port);
    void ow_uart_poll(uint port);
    int ow_uart_read(uint port, ubyte* buf, int len);
    int ow_uart_write(uint port, const(ubyte)* buf, int len);
    int ow_uart_rx_pending(uint port);
    int ow_uart_tx_pending(uint port);
    int ow_uart_tx_idle(uint port);
    int ow_uart_flush(uint port);
    int ow_uart_check_errors(uint port);
}
