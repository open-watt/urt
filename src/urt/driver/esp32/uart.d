// ESP32 UART: the IDF configures the port, and this ISR owns the FIFOs through the C shim (idf_shim.c). UART0 is the
// console, its defaults set by the bootloader.
module urt.driver.esp32.uart;

import urt.driver.irq : irq_critical;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartError, UartRxCallback,
    UartRxTiming, UartTxCallback, uart_chars_us, uart_rx_chars;
import urt.driver.uart_core : UartPorts;
import urt.mem.page : Page;

nothrow @nogc:


// SOC_UART_NUM per chip variant
version (ESP32)          enum num_uarts = 3;
else version (ESP32_S3)  enum num_uarts = 3;
else version (ESP32_S31) enum num_uarts = 4;
else version (ESP32_P4)  enum num_uarts = 6;
else version (ESP32_S2)  enum num_uarts = 2;
else version (ESP32_C2)  enum num_uarts = 2;
else version (ESP32_C3)  enum num_uarts = 2;
else version (ESP32_C5)  enum num_uarts = 2;
else version (ESP32_C6)  enum num_uarts = 3;
else version (ESP32_H2)  enum num_uarts = 2;
else static assert(false, "unknown Espressif chip -- add num_uarts");

enum uint uart_clock_hz = 80_000_000;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd;
enum uint uart_stop_bits = 1 << StopBits.one | 1 << StopBits.one_point_five | 1 << StopBits.two;
enum uint uart_flow_controls = 1 << FlowControl.none;
enum bool uart_has_rs485 = true;
enum bool uart_has_pin_select = true;

// The IDF's half-duplex mode times DE from TX_DONE, so DE timing and turnaround requests are refused.
bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb, UartTxCallback tx_cb)
{
    if (cfg.rs485.enabled && (cfg.rs485.de_assert_us || cfg.rs485.de_deassert_us || cfg.rs485.turnaround_us))
        return false;
    if (!_ports.acquire(id, cfg))
        return false;
    _fifo_len[id] = cast(ushort)urt_uart_fifo_len(id);
    ubyte full, timeout;
    immutable UartRxTiming timing = rx_timing(id, cfg, full, timeout);
    byte de = cfg.rs485.enabled && cfg.rs485.de_gpio != ubyte.max ? cast(byte)cfg.rs485.de_gpio : -1;
    _ports.start(id, rx_cb, tx_cb, timing);
    if (!urt_uart_open(id, cfg.baud_rate, cfg.data_bits, cast(ubyte)cfg.stop_bits, cast(ubyte)cfg.parity,
                       cfg.tx_gpio == ubyte.max ? -1 : cast(byte)cfg.tx_gpio, cfg.rx_gpio == ubyte.max ? -1 : cast(byte)cfg.rx_gpio,
                       cfg.rs485.enabled, de, cfg.rs485.de_active_high, full, timeout))
    {
        _ports.release(id);
        return false;
    }
    return true;
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    urt_uart_close(id);
    _ports.release(id);
}

bool uart_hw_send(uint id, Page* chain)
    => _ports.send(id, chain);

size_t uart_hw_write(uint id, const(void)[] data)
    => _ports.write(id, data);

Page* uart_hw_rx_take(uint id)
    => _ports.rx_take(id);

UartRxTiming uart_hw_rx_timing(uint id)
    => _ports.timing(id);

UartRxTiming uart_hw_set_rx_timing(uint id, ref const UartConfig cfg)
{
    ubyte full, timeout;
    immutable UartRxTiming timing = rx_timing(id, cfg, full, timeout);
    auto guard = irq_critical();
    urt_uart_set_rx(id, full, timeout);
    _ports.retime(id, timing);
    return timing;
}

size_t uart_hw_tx_pending(uint id)
    => _ports.tx_pending(id);

UartError uart_hw_check_errors(uint id)
    => _ports.take_errors(id);

void uart_hw_flush(uint id)
{
    _ports.drain(id);
}

void uart0_hw_puts(const(char)[] s)
{
    foreach (ch; s)
        esp_rom_uart_putc(ch);
}


private:

enum : uint
{
    cause_rx       = 1 << 0,
    cause_timeout  = 1 << 1,
    cause_tx       = 1 << 2,
    cause_tx_done  = 1 << 3,
    cause_parity   = 1 << 4,
    cause_framing  = 1 << 5,
    cause_overflow = 1 << 6,
    cause_break    = 1 << 7,
}

__gshared UartPorts!(num_uarts, 0, tx_idle, tx_fill) _ports;
__gshared ushort[num_uarts] _fifo_len;

// The RX interrupt fires at the deepest threshold within the RX latency, from two so it can leave the byte the
// timeout needs, and never past half the FIFO; the timeout counts whole characters.
UartRxTiming rx_timing(uint id, ref const UartConfig cfg, out ubyte full, out ubyte timeout)
{
    immutable uint limit = _fifo_len[id] / 2;
    immutable uint chars = uart_rx_chars(cfg);
    full = cast(ubyte)(chars < 2 ? 2 : chars > limit ? limit : chars);
    immutable uint tenths = cfg.rx_gap < 10 ? 10 : cfg.rx_gap;
    timeout = cast(ubyte)((tenths + 9) / 10);
    return UartRxTiming(uart_chars_us(cfg, full), cast(ubyte)(timeout * 10));
}

// Caller holds interrupts off, or runs in the ISR.
void tx_fill(uint id)
{
    for (uint room = urt_uart_tx_room(id); room; )
    {
        const(ubyte)[] bytes = _ports.tx_bytes(id);
        if (!bytes.length)
            break;
        immutable uint n = cast(uint)(bytes.length < room ? bytes.length : room);
        immutable uint written = urt_uart_tx_write(id, bytes.ptr, n);
        _ports.tx_advance(id, written);
        if (written < n)
            break;
        room -= n;
    }
    urt_uart_tx_irq(id, _ports.tx_queued(id));
}

bool tx_idle(uint id)
    => urt_uart_tx_idle(id);

static immutable UartError[16] cause_errors = () {
    UartError[16] t;
    foreach (i; 0 .. 16)
        t[i] = cast(UartError)((i & 1 ? UartError.parity : 0) | (i & 2 ? UartError.framing : 0) | (i & 4 ? UartError.overrun : 0) | (i & 8 ? UartError.break_ : 0));
    return t;
}();

extern(C) void urt_uart_isr(uint id)
{
    immutable uint causes = urt_uart_take_causes(id);
    if (causes & (cause_parity | cause_framing | cause_overflow | cause_break))
        _ports.error(id, cause_errors[(causes >> 4) & 0xF]);
    if (causes & cause_rx)
    {
        // the timeout runs only while the FIFO holds a byte, so the threshold interrupt leaves one for it
        uint len = urt_uart_rx_len(id);
        if (!(causes & cause_timeout) && len)
            --len;
        ubyte[128] buf = void;
        while (len)
        {
            immutable uint got = urt_uart_rx_read(id, buf.ptr, len < buf.length ? len : buf.length);
            if (!got)
                break;
            foreach (b; buf[0 .. got])
                _ports.receive(id, b);
            len -= got;
        }
    }
    if (causes & cause_timeout)
        _ports.gap(id);
    if (causes & cause_tx)
        tx_fill(id);
    if (causes & (cause_rx | cause_parity | cause_framing | cause_overflow | cause_break))
        _ports.notify(id);
}

extern(C) nothrow @nogc
{
    void esp_rom_uart_putc(char c);

    int urt_uart_open(uint port, uint baud_rate, ubyte data_bits, ubyte stop_bits, ubyte parity, byte tx_gpio, byte rx_gpio,
                      bool rs485_enabled, byte de_gpio, bool de_active_high, ubyte rx_full, ubyte rx_timeout);
    void urt_uart_close(uint port);
    void urt_uart_set_rx(uint port, ubyte rx_full, ubyte rx_timeout);
    uint urt_uart_take_causes(uint port);
    uint urt_uart_rx_len(uint port);
    uint urt_uart_rx_read(uint port, ubyte* buf, uint len);
    uint urt_uart_tx_room(uint port);
    uint urt_uart_tx_write(uint port, const(ubyte)* buf, uint len);
    void urt_uart_tx_irq(uint port, bool enable);
    bool urt_uart_tx_idle(uint port);
    uint urt_uart_fifo_len(uint port);
}
