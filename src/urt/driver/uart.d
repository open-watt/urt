module urt.driver.uart;

import urt.result : Result, InternalResult;
import urt.time : Duration;

version (Bouffalo)
    public import urt.driver.bl_common.uart;
else version (Beken)
    public import urt.driver.bk7231.uart;
else version (RP2350)
    public import urt.driver.rp2350.uart;
else version (MT7621)
    public import urt.driver.mt7621.uart;
else version (STM32)
    public import urt.driver.stm32.uart;
else version (Espressif)
    public import urt.driver.esp32.uart;
else
    enum uint num_uarts = 0;

// Platforms that number their ports from the datasheet's UART1 declare their own.
static if (!__traits(compiles, first_uart))
    enum uint first_uart = 0;

// Platforms whose console is not the first port declare their own.
static if (!__traits(compiles, console_uart))
    enum uint console_uart = first_uart;

nothrow @nogc:


enum UartError : ubyte
{
    none     = 0,
    framing  = 1 << 0,
    parity   = 1 << 1,
    overrun  = 1 << 2,
    noise    = 1 << 3,
    break_   = 1 << 4,
}

static assert(UartError.framing == 1 << 0);
static assert(UartError.parity == 1 << 1);
static assert(UartError.overrun == 1 << 2);
static assert(UartError.break_ == 1 << 4);

enum StopBits : ubyte
{
    half,
    one,
    one_point_five,
    two,
}

enum Parity : ubyte
{
    none,
    even,
    odd,
    mark,
    space
}

enum FlowControl : ubyte
{
    none,
    hardware,
    software,
    dsr_dtr,

    rts_cts = hardware,
    xon_xoff = software
}

enum DriveMode : ubyte
{
    polled,     // caller must call uart_poll; no interrupts
    interrupt,  // IRQ-driven FIFO drain into software ring buffer
    dma,        // DMA circular RX, DMA one-shot TX
    auto_,      // driver picks best available (dma > interrupt > polled)
}

struct Rs485Config
{
    bool enabled;
    bool de_active_high = true; // DE pin polarity
    ubyte de_gpio = ubyte.max;   // GPIO pin for driver enable (max = auto/hardware)
    ushort de_assert_us;        // us to assert DE before first TX bit
    ushort de_deassert_us;      // us to hold DE after last TX bit
    ushort turnaround_us;       // minimum idle time between RX end and TX start
}

struct UartConfig
{
    uint baud_rate = 115200;
    ubyte data_bits = 8;
    StopBits stop_bits = StopBits.one;
    Parity parity = Parity.none;
    FlowControl flow_control = FlowControl.none;
    DriveMode drive_mode = DriveMode.auto_;
    ubyte tx_gpio = ubyte.max;  // GPIO pin for TX (max = platform default)
    ubyte rx_gpio = ubyte.max;  // GPIO pin for RX (max = platform default)
    ubyte rts_gpio = ubyte.max; // GPIO pin for RTS (max = platform default)
    ubyte cts_gpio = ubyte.max; // GPIO pin for CTS (max = platform default)
    uint rx_latency_us = 350;   // longest received bytes may wait for the RX event
    ubyte rx_gap = 35;          // quiet line that delivers a burst early, in tenths of a character
    Rs485Config rs485;
}

// The RX timing a port runs with once its hardware has clamped the request; zero where a backend cannot say.
struct UartRxTiming
{
    uint latency_us;
    ubyte gap;
}

// Start, data, parity and stop bits; half a stop bit counts as one, one and a half as two.
uint uart_frame_bits(ref const UartConfig cfg) pure
    => 2 + cfg.data_bits + (cfg.parity != Parity.none) + (cfg.stop_bits >= StopBits.one_point_five);

// Whole characters that arrive within rx_latency_us, never fewer than one.
uint uart_rx_chars(ref const UartConfig cfg) pure
{
    immutable uint chars = cast(uint)(ulong(cfg.baud_rate) * cfg.rx_latency_us / (uart_frame_bits(cfg) * 1_000_000UL));
    return chars ? chars : 1;
}

uint uart_rx_gap_bits(ref const UartConfig cfg) pure
    => (cfg.rx_gap * uart_frame_bits(cfg) + 5) / 10;

uint uart_chars_us(ref const UartConfig cfg, uint chars) pure
    => cast(uint)(ulong(chars) * uart_frame_bits(cfg) * 1_000_000 / cfg.baud_rate);

ubyte uart_gap_tenths(ref const UartConfig cfg, uint bits) pure
{
    immutable uint tenths = (bits * 10 + uart_frame_bits(cfg) / 2) / uart_frame_bits(cfg);
    return cast(ubyte)(tenths < ubyte.max ? tenths : ubyte.max);
}

enum UartCallbackContext : ubyte
{
    thread,
    interrupt,
}

// Called when received data is available in the driver's RX buffer, or with
// rx_avail == 0 when status/error state changes. rx_avail is a snapshot; the
// callback only signals the consumer and uart_read() owns delivery/draining.
// It must be non-blocking and must not call back into the UART driver.
// Interrupt-context callbacks return whether the interrupted platform should
// yield to a woken thread. Thread-context backends ignore the return value.
alias UartRxCallback = bool function(Uart uart, size_t rx_avail,
                                     UartCallbackContext context) nothrow @nogc;

enum bool has_rx_callback = __traits(compiles, { UartConfig c; uart_hw_open(0, c, UartRxCallback.init); });

// Called from ISR/DMA when TX buffer space becomes available (e.g. FIFO
// drains below threshold). The callee should feed more data via uart_write.
// tx_avail: number of bytes that can be written to the TX buffer.
alias UartTxCallback = void function(Uart uart, size_t tx_avail) nothrow @nogc;

// Called from ISR to pull the next chunk of data for an async transmit.
// offset: bytes already supplied so far (including initial buffer).
// The driver provides a buffer; the callee fills it and returns how many
// bytes were written. Called repeatedly until the transfer length is met.
alias UartTxSupplyCallback = size_t function(Uart uart, size_t offset, void[] buf) nothrow @nogc;

// Called when the RX line has been idle for the configured threshold.
// Used for RS-485 frame boundary detection and bus arbitration.
alias UartLineIdleCallback = void function(Uart uart) nothrow @nogc;

// Caller-owned write operation token. Pass to any write call to track
// completion and support cancellation. The driver writes status from
// ISR context; the caller polls it from main context.
struct UartWriteOp
{
    enum Status : ubyte
    {
        idle,       // not submitted
        pending,    // driver is working on it
        complete,   // all bytes consumed / transmitted
        cancelled,  // cancelled via uart_write_cancel
        error,      // hardware error during transfer
    }

    alias Callback = void function(Uart* uart, ref UartWriteOp op) nothrow @nogc;

    Status status;
    size_t bytes_sent; // updated by driver as transfer progresses
    void* user_data;
    Callback cb;

    bool is_pending() const => status == Status.pending;
    bool is_done() const => status >= Status.complete;
}

struct Uart
{
    ubyte port = ubyte.max;
}

bool is_open(ref const Uart uart)
{
    return uart.port != ubyte.max;
}


// ====================================================================
// Error type
// ====================================================================

UartError uart_result(Result result)
{
    return cast(UartError)result.system_code;
}


// ====================================================================
// Implementation
// ====================================================================

// Lifecycle

void uart_init()
{
    if (_init_refcount++ == 0)
    {
        // TODO: enable clocks/power for UART peripheral block
    }
}

void uart_deinit()
{
    assert(_init_refcount > 0);
    if (--_init_refcount == 0)
    {
        // TODO: disable clocks/power for UART peripheral block
    }
}

// Port operations

Result uart_open(ref Uart uart, ubyte port, ref const UartConfig cfg, size_t buf_size = 0, UartRxCallback rx_cb = null, UartTxCallback tx_cb = null)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        if (port < first_uart || port >= first_uart + num_uarts)
            return InternalResult.invalid_parameter;

        static if (__traits(compiles, uart_hw_open(port, cfg, rx_cb)))
            bool opened = uart_hw_open(port, cfg, rx_cb);
        else
        {
            if (rx_cb !is null)
                return InternalResult.unsupported;
            bool opened = uart_hw_open(port, cfg);
        }

        if (!opened)
            return InternalResult.failed;

        uart.port = port;
        return Result.success;
    }
}

Result uart_reconfigure(ref Uart uart, ref const UartConfig cfg)
{
    assert(false, "TODO: uart_reconfigure (hot reconfigure)");
}

void uart_close(ref Uart uart)
{
    if (!is_open(uart))
        return;
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        uart_hw_close(uart.port);
    uart.port = ubyte.max;
}

// Single-byte I/O

bool uart_putc(ref Uart uart, ubyte c)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return uart_hw_write(uart.port, (cast(void*)&c)[0 .. 1]) == 1;
}

bool uart_getc(ref Uart uart, out ubyte c)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return uart_hw_read(uart.port, (cast(void*)&c)[0 .. 1]) == 1;
}

// Bulk I/O

ptrdiff_t uart_read(ref Uart uart, void[] buffer, Duration timeout = Duration.zero)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        if (timeout != Duration.zero)
            assert(false, "TODO: uart_read with timeout");
        uart_hw_poll(uart.port);
        return uart_hw_read(uart.port, buffer);
    }
}

ptrdiff_t uart_write(ref Uart uart, const(void)[] data, UartWriteOp* op = null)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        auto n = uart_hw_write(uart.port, data);
        if (op !is null)
        {
            op.bytes_sent = n > 0 ? cast(size_t)n : 0;
            op.status = n >= 0 ? UartWriteOp.Status.complete : UartWriteOp.Status.error;
            if (op.cb !is null)
                op.cb(&uart, *op);
        }
        return n;
    }
}

ptrdiff_t uart_writev(ref Uart uart, const(void[])[] buffers, UartWriteOp* op = null)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        ptrdiff_t total = 0;
        foreach (buf; buffers)
        {
            auto n = uart_hw_write(uart.port, buf);
            if (n < 0)
            {
                if (op !is null)
                {
                    op.bytes_sent = cast(size_t)total;
                    op.status = UartWriteOp.Status.error;
                    if (op.cb !is null)
                        op.cb(&uart, *op);
                }
                return n;
            }
            total += n;
            if (n < buf.length)
                break;
        }
        if (op !is null)
        {
            op.bytes_sent = cast(size_t)total;
            op.status = UartWriteOp.Status.complete;
            if (op.cb !is null)
                op.cb(&uart, *op);
        }
        return total;
    }
}

ptrdiff_t uart_write_async(ref Uart uart, size_t total_len, UartTxSupplyCallback supply_cb, const(void)[] initial = null, UartWriteOp* op = null)
{
    assert(false, "TODO: uart_write_async (needs ISR integration)");
}

void uart_write_cancel(ref Uart uart, UartWriteOp* op)
{
    assert(false, "TODO: uart_write_cancel");
}

// Buffer queries

size_t uart_rx_available(ref const Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        auto n = uart_hw_rx_pending(uart.port);
        return n > 0 ? cast(size_t)n : 0;
    }
}

size_t uart_tx_available(ref const Uart uart)
{
    assert(false, "TODO: uart_tx_available");
}

size_t uart_tx_queued(ref const Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else static if (__traits(compiles, uart_hw_tx_pending(0)))
    {
        auto n = uart_hw_tx_pending(uart.port);
        return n > 0 ? cast(size_t)n : 0;
    }
    else
        return 0;   // remaining drivers write synchronously, so nothing is ever queued
}

// Buffer control

void uart_rx_flush(ref Uart uart)
{
    assert(false, "TODO: uart_rx_flush");
}

void uart_tx_flush(ref Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        uart_hw_flush(uart.port);
}

void uart_tx_drain(ref Uart uart)
{
    assert(false, "TODO: uart_tx_drain (block until TX idle)");
}

void uart_tx_abort(ref Uart uart)
{
    assert(false, "TODO: uart_tx_abort");
}

// Line status

bool uart_line_idle(ref const Uart uart)
{
    assert(false, "TODO: uart_line_idle");
}

void uart_set_idle_threshold(ref Uart uart, uint bit_times)
{
    assert(false, "TODO: uart_set_idle_threshold");
}

void uart_set_idle_callback(ref Uart uart, UartLineIdleCallback cb)
{
    assert(false, "TODO: uart_set_idle_callback");
}

// TX timing

void uart_tx_gap(ref Uart uart, Duration gap)
{
    assert(false, "TODO: uart_tx_gap");
}

void uart_send_break(ref Uart uart, Duration duration)
{
    assert(false, "TODO: uart_send_break");
}

// Error and status

UartError uart_check_errors(ref Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        auto error = uart_hw_check_errors(uart.port);
        static if (is(typeof(error) == UartError))
            return error;
        else
            return error ? UartError.framing : UartError.none;
    }
}

void uart_poll(ref Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        uart_hw_poll(uart.port);
}

UartRxTiming uart_rx_timing(ref const Uart uart)
{
    static if (__traits(compiles, uart_hw_rx_timing(0)))
        return uart_hw_rx_timing(uart.port);
    else
        return UartRxTiming();
}

// Early boot (pre-driver, polled, blocking)

void uart0_putc(ubyte c)
{
    static if (num_uarts == 0) {}
    else uart0_puts((cast(char*)&c)[0 .. 1]);
}

void uart0_puts(const(char)[] s)
{
    static if (num_uarts == 0) {}
    else uart0_hw_puts(s);
}


// ====================================================================
// Tests
// ====================================================================

unittest
{
    UartConfig c;
    assert(uart_frame_bits(c) == 10 && uart_rx_chars(c) == 4 && uart_rx_gap_bits(c) == 35, "8N1 at 115200: 4 characters in 350 us, a 35-bit gap");
    c.baud_rate = 2_000_000;
    assert(uart_rx_chars(c) == 70 && uart_chars_us(c, 16) == 80, "16 characters take 80 us at 2 Mbaud");
    c.parity = Parity.even;
    c.stop_bits = StopBits.two;
    assert(uart_frame_bits(c) == 12 && uart_rx_gap_bits(c) == 42 && uart_gap_tenths(c, 32) == 27, "8E2 frames are 12 bits");
    c.baud_rate = 300;
    assert(uart_rx_chars(c) == 1, "a slow line still delivers each character");

    static if (num_uarts > 0)
    {
        Uart u;
        UartConfig cfg;

        uart_init();

        auto r = uart_open(u, cast(ubyte)(first_uart + num_uarts), cfg);
        assert(!r);
        assert(!u.is_open);
        static if (first_uart > 0)
            assert(!uart_open(u, 0, cfg));

        // Open/close each valid port; reconfiguring the console would kill it
        foreach (p; first_uart .. first_uart + num_uarts)
        {
            if (p == console_uart)
                continue;

            Uart port;
            auto r2 = uart_open(port, cast(ubyte)p, cfg);
            assert(r2, "uart_open failed");
            assert(port.is_open);
            assert(port.port == p);

            // RX should be empty on a freshly opened port
            assert(uart_rx_available(port) == 0);

            // Poll should not crash
            uart_poll(port);

            // Check errors on a clean port
            assert(uart_check_errors(port) == UartError.none);

            uart_close(port);
            assert(!port.is_open);
        }

        uart_deinit();
    }
}


private:

__gshared ubyte _init_refcount;
