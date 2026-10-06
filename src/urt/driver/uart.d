module urt.driver.uart;

import urt.mem.page : Page;
import urt.result : Result, InternalResult;
import urt.time : Duration, MonoTime;

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
    lost     = 1 << 5,      // the device went away, as a USB adapter unplugged
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
    polled,     // no interrupts
    interrupt,  // the FIFO is serviced from its interrupts
    dma,        // DMA moves the bytes between the FIFO and memory
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
    uint rx_latency_us = 350;   // how long a continuous stream batches before the RX event; a pause delivers at rx_gap
    ubyte rx_gap = 35;          // quiet line that delivers what preceded it, in tenths of a character
    Rs485Config rs485;
}

// Each backend declares a bit per setting it can run (uart_drive_modes, uart_data_bits by width, uart_parities,
// uart_stop_bits, uart_flow_controls) and whether it honours RS-485 and pin requests; uart_open refuses the rest.
bool uart_config_supported(ref const UartConfig cfg) pure
{
    static if (num_uarts == 0)
        return false;
    else
        return (cfg.drive_mode == DriveMode.auto_ || (uart_drive_modes & 1 << cfg.drive_mode))
            && cfg.data_bits < 32 && (uart_data_bits & 1 << cfg.data_bits)
            && (uart_parities & 1 << cfg.parity)
            && (uart_stop_bits & 1 << cfg.stop_bits)
            && (uart_flow_controls & 1 << cfg.flow_control)
            && (uart_has_rs485 || !cfg.rs485.enabled)
            && (uart_has_pin_select || (cfg.tx_gpio & cfg.rx_gpio & cfg.rts_gpio & cfg.cts_gpio) == ubyte.max);
}

// The RX timing a port runs with once its hardware has clamped the request; zero where a backend cannot say.
struct UartRxTiming
{
    uint latency_us;
    ubyte gap;
}

// What the port has moved and the line errors it has seen since it opened.
struct UartCounters
{
    ulong rx_bytes;
    ulong tx_bytes;
    uint framing;
    uint parity;
    uint overrun;
    uint noise;
    uint breaks;
}

enum UartLine : ubyte
{
    rts,
    dtr,
}

// The modem lines: what the port asserts, where it can read them back, and what the peer presents.
struct UartLines
{
    bool valid;
    bool outputs_valid;
    bool rts;
    bool dtr;
    bool cts;
    bool dsr;
    bool dcd;
    bool ri;
}

// A port the platform knows: the name uart_find takes, and what it can say of the hardware behind it.
struct UartPortInfo
{
    const(char)[] name;
    const(char)[] description;
    const(char)[] manufacturer;
    const(char)[] product;
    const(char)[] serial;
    ushort usb_vid;
    ushort usb_pid;
    ubyte port;
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

// Whether clock / divisor lands within 3% of the requested rate; a receiver samples mid-bit and tolerates about 5%.
bool uart_rate_close(uint baud, ulong clock, ulong divisor) pure
{
    immutable ulong rate = (clock + divisor / 2) / divisor;
    immutable ulong miss = rate > baud ? rate - baud : baud - rate;
    return miss * 100 <= ulong(baud) * 3;
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

// A backend that cannot report the gap it programs says so with uart_reports_rx_gap.
static if (!__traits(compiles, uart_reports_rx_gap))
    enum bool uart_reports_rx_gap = num_uarts > 0;

// Raised when bytes arrived, the line went quiet, or an error was recorded; uart_rx_take then takes what arrived. Like
// the TX callback it only signals: it must not block or call back into the driver, and in interrupt context returns
// whether the interrupted platform should yield to a woken thread.
alias UartRxCallback = bool function(Uart uart, UartCallbackContext context) nothrow @nogc;

// Raised when the line finished a page and has room for more.
alias UartTxCallback = bool function(Uart uart, UartCallbackContext context) nothrow @nogc;

// A burst of received bytes in a taken chain, read as one series of bytes (page_chain_span walks it): start and end are
// when its first and last bytes arrived, gap says a quiet line ended it, and quiet is how long the line stayed quiet
// before the next burst, when that had begun by the take.
struct UartBurst
{
    size_t offset;
    size_t length;
    MonoTime start;
    MonoTime end;
    Duration quiet;
    bool gap;
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

// Ports

// The port a name stands for, or ubyte.max. A part names its ports uart0 and on; a host takes any name its OS gives
// the device, and every name for one device finds the same port, for as long as the process runs.
ubyte uart_find(const(char)[] name)
{
    static if (__traits(compiles, uart_hw_find(name)))
        return uart_hw_find(name);
    else
    {
        if (name.length < 5 || name[0 .. 4] != "uart")
            return ubyte.max;
        uint port;
        foreach (c; name[4 .. $])
        {
            if (c < '0' || c > '9' || port > first_uart + num_uarts)
                return ubyte.max;
            port = port * 10 + (c - '0');
        }
        return port >= first_uart && port < first_uart + num_uarts ? cast(ubyte)port : ubyte.max;
    }
}

// The ports the platform knows, from cursor 0; info's strings hold until the next call.
bool uart_enumerate(ref uint cursor, out UartPortInfo info)
{
    static if (__traits(compiles, uart_hw_enumerate(cursor, info)))
        return uart_hw_enumerate(cursor, info);
    else
    {
        static immutable string[10] names = [ "uart0", "uart1", "uart2", "uart3", "uart4", "uart5", "uart6", "uart7", "uart8", "uart9" ];
        static assert(first_uart + num_uarts <= names.length);
        if (cursor >= num_uarts)
            return false;
        info.port = cast(ubyte)(first_uart + cursor++);
        info.name = names[info.port];
        return true;
    }
}

Result uart_open(ref Uart uart, ubyte port, ref const UartConfig cfg, UartRxCallback rx_cb = null, UartTxCallback tx_cb = null)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        if (port < first_uart || port >= first_uart + num_uarts || cfg.baud_rate == 0)
            return InternalResult.invalid_parameter;
        if (!uart_config_supported(cfg))
            return InternalResult.unsupported;
        immutable uint owned = 1 << (port - first_uart);
        if (uart.is_open || (_open_ports & owned))
            return InternalResult.already_exists;
        if (!uart_hw_open(port, cfg, rx_cb, tx_cb))
            return InternalResult.failed;
        _open_ports |= owned;
        _pins[port - first_uart] = Pins(cfg);
        uart.port = port;
        return Result.success;
    }
}

// Applies cfg to an open port at once: what the FIFOs and the line held at that moment may come out mangled either way,
// and what is queued goes out under the new settings. A change in how the line is read ends the frame arriving then,
// which the caller takes; no callback reports it. Pins are fixed while it is open.
Result uart_reconfigure(ref Uart uart, ref const UartConfig cfg)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        if (!is_open(uart))
            return InternalResult.invalid_parameter;
        if (cfg.baud_rate == 0 || Pins(cfg) != _pins[uart.port - first_uart])
            return InternalResult.invalid_parameter;
        if (!uart_config_supported(cfg))
            return InternalResult.unsupported;
        return uart_hw_reconfigure(uart.port, cfg) ? Result.success : InternalResult.failed;
    }
}

// What was queued goes out first, boundedly; the pages the driver still held, sent or received or not, are released.
void uart_close(ref Uart uart)
{
    if (!is_open(uart))
        return;
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
    {
        uart_hw_close(uart.port);
        _open_ports &= ~(1 << (uart.port - first_uart));
        uart.port = ubyte.max;
    }
}

// TX

// The chain becomes the driver's: it goes out in order behind what was written or sent before it, and each page is
// released once sent. A closed port refuses it and the caller keeps it.
bool uart_send(ref Uart uart, Page* chain)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return is_open(uart) && uart_hw_send(uart.port, chain);
}

// Copies data in behind what was written or sent before it; returns how much it took, short only when no page could be
// had. Thread context.
size_t uart_write(ref Uart uart, const(void)[] data)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return is_open(uart) ? uart_hw_write(uart.port, data) : 0;
}

// Bytes sent that have not yet reached the transmitter FIFO.
size_t uart_tx_queued(ref const Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return is_open(uart) ? uart_hw_tx_pending(uart.port) : 0;
}

// Waits, boundedly, for what was sent to leave the line.
void uart_tx_flush(ref Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else if (is_open(uart))
        uart_hw_flush(uart.port);
}

// RX

// The pages received since the last take, oldest first, the one still filling included; the caller frees them.
Page* uart_rx_take(ref Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return is_open(uart) ? uart_hw_rx_take(uart.port) : null;
}

public import urt.driver.uart_core : uart_burst, uart_burst_count;

UartError uart_check_errors(ref Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return is_open(uart) ? uart_hw_check_errors(uart.port) : UartError.none;
}

UartCounters uart_counters(ref const Uart uart)
{
    static if (num_uarts == 0)
        assert(false, "no UART on this platform");
    else
        return is_open(uart) ? uart_hw_counters(uart.port) : UartCounters();
}

// Drives a modem line the port's flow control does not own; false where the port has no such line.
bool uart_set_line(ref Uart uart, UartLine line, bool asserted)
{
    static if (__traits(compiles, uart_hw_set_line(0, line, asserted)))
        return is_open(uart) && uart_hw_set_line(uart.port, line, asserted);
    else
        return false;
}

UartLines uart_lines(ref Uart uart)
{
    static if (__traits(compiles, uart_hw_lines(0)))
        return is_open(uart) ? uart_hw_lines(uart.port) : UartLines();
    else
        return UartLines();
}

UartRxTiming uart_rx_timing(ref const Uart uart)
{
    static if (__traits(compiles, uart_hw_rx_timing(0)))
        return is_open(uart) ? uart_hw_rx_timing(uart.port) : UartRxTiming();
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
    assert(uart_rate_close(115_200, 50_000_000, 16 * 27) && !uart_rate_close(4_000_000, 50_000_000, 16), "3.125 Mbaud is no 4 Mbaud");

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

        UartConfig bad;
        bad.baud_rate = 0;
        assert(!uart_open(u, cast(ubyte)console_uart, bad), "a zero baud rate is refused");
        bad = UartConfig.init;
        foreach (m; DriveMode.polled .. DriveMode.auto_)
        {
            if (uart_drive_modes & 1 << m)
                continue;
            bad.drive_mode = m;
            assert(!uart_open(u, cast(ubyte)console_uart, bad), "a drive mode the backend lacks is refused");
        }

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

            assert(uart_rx_take(port) is null && uart_tx_queued(port) == 0, "a fresh port holds nothing");
            assert(uart_check_errors(port) == UartError.none);

            uart_close(port);
            assert(!port.is_open);
        }

        uart_deinit();
    }
}


private:

struct Pins
{
nothrow @nogc:
    ubyte tx, rx, rts, cts, de;
    this(ref const UartConfig cfg) pure
    {
        tx = cfg.tx_gpio;
        rx = cfg.rx_gpio;
        rts = cfg.rts_gpio;
        cts = cfg.cts_gpio;
        de = cfg.rs485.enabled ? cfg.rs485.de_gpio : ubyte.max;
    }
}

__gshared ubyte _init_refcount;
__gshared uint _open_ports;
static if (num_uarts > 0)
    __gshared Pins[num_uarts] _pins;
