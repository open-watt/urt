// MT7621 UART1-3: 16550s with 16-entry FIFOs on GIC shared lines 26-28 (Linux mt7621.dtsi).
module urt.driver.mt7621.uart;

import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartCounters, UartError, UartRxCallback,
    UartRxTiming, UartTxCallback, uart_chars_us, uart_rate_close, uart_rx_chars;
import urt.driver.uart_core : UartPorts, puts_stall_spins;
import urt.mem.page : Page;

import core.volatile;

nothrow @nogc:

enum num_uarts = 3;
enum uint first_uart = 1;
enum uint console_uart = 1;
enum uint uart_clock_hz = 50_000_000;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
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

bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb, UartTxCallback tx_cb)
{
    immutable uint i = id - first_uart;
    if (!divisor(cfg.baud_rate) || !_ports.acquire(i, cfg))
        return false;
    uart_hw_init(id, cfg);
    _ports.start(i, rx_cb, tx_cb, set_rx_timing(id, cfg));
    irq_handler_set(uart_irq(id), &uart_isr);
    irq_line_enable(uart_irq(id));
    write_reg(uart_base(id), ier, ier_rda | ier_rls);
    return true;
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    irq_line_disable(uart_irq(id));
    write_reg(uart_base(id), ier, 0);
    _ports.release(id - first_uart);
}

// TODO: the hEX S has no UART header, so the netconsole copies the console until OpenWatt carries a UDP log sink; it
// copies here, in the sender's context, since it submits Ethernet frames the ISR must not
bool uart_hw_send(uint id, Page* chain)
{
    if (id == console_uart)
    {
        import urt.driver.mt7621.netcon : netcon_put;
        for (Page* page = chain; page; page = page.next)
            netcon_put(cast(const(char)[])page.data);
    }
    return _ports.send(id - first_uart, chain);
}

size_t uart_hw_write(uint id, const(void)[] data)
{
    immutable size_t written = _ports.write(id - first_uart, data);
    if (id == console_uart)
    {
        import urt.driver.mt7621.netcon : netcon_put;
        netcon_put(cast(const(char)[])data[0 .. written]);
    }
    return written;
}

Page* uart_hw_rx_take(uint id)
    => _ports.rx_take(id - first_uart);

UartRxTiming uart_hw_rx_timing(uint id)
    => _ports.timing(id - first_uart);

// The character timeout is fixed at four characters.
bool uart_hw_reconfigure(uint id, ref const UartConfig cfg)
{
    if (!divisor(cfg.baud_rate))
        return false;
    UartRxTiming timing;
    {
        auto guard = irq_critical();
        uart_hw_init(id, cfg);
        timing = set_rx_timing(id, cfg);
        write_reg(uart_base(id), ier, ier_rda | ier_rls);
    }
    _ports.reconfigure(id - first_uart, cfg, timing);
    _ports.kick(id - first_uart);
    return true;
}

size_t uart_hw_tx_pending(uint id)
    => _ports.tx_pending(id - first_uart);

UartCounters uart_hw_counters(uint id)
    => _ports.counters(id - first_uart);

UartError uart_hw_check_errors(uint id)
{
    {
        auto guard = irq_critical();
        line_status(id);
    }
    return _ports.take_errors(id - first_uart);
}

void uart_hw_flush(uint id)
{
    _ports.drain(id - first_uart);
}

// Blocking console output for early boot and fault context; queued output goes first.
void uart0_hw_puts(const(char)[] s)
{
    import urt.driver.mt7621.netcon : netcon_put;

    enum uint base = uart_base(console_uart);
    uint spins = 0;
    while (_ports.tx_queued(console_uart - first_uart) && spins++ < puts_stall_spins)
    {
        auto guard = irq_critical();
        tx_fill(console_uart - first_uart);
    }
    netcon_put(s);
    foreach (c; s)
    {
        spins = 0;
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
    iir     = 0x08,
    fcr     = 0x08,
    lcr_reg = 0x0C,
    mcr     = 0x10,
    lsr     = 0x14,
}

enum : uint
{
    ier_rda  = 1 << 0,      // data available, and the character timeout
    ier_thre = 1 << 1,
    ier_rls  = 1 << 2,

    iir_none = 0x1,
    iir_mask = 0xF,
    iir_rls  = 0x6,
    iir_rda  = 0x4,
    iir_cti  = 0xC,
    iir_thre = 0x2,

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

enum uint fifo_depth = 16;

uint uart_base(uint id)
    => 0xBE00_0B00 + id * 0x100;

uint uart_irq(uint id)
    => 25 + id;

// FCR trigger levels from 4: the data interrupt leaves a byte for the character timeout, so a level of 1 would
// take nothing and storm.
static immutable ubyte[3] rx_levels = [ 4, 8, 14 ];
static immutable ubyte[3] rx_level_field = [ 1, 2, 3 ];

__gshared UartPorts!(num_uarts, first_uart, tx_idle, tx_fill) _ports;
__gshared ubyte[num_uarts] _rx_take;

// The 16550 divisor latch, rounded: 16 clocks a bit, 1 to 0xFFFF.
uint divisor(uint baud) pure
{
    immutable ulong d = (ulong(uart_clock_hz) + ulong(baud) * 8) / (ulong(baud) * 16);
    return d >= 1 && d <= 0xFFFF && uart_rate_close(baud, uart_clock_hz, 16 * d) ? cast(uint)d : 0;
}

UartRxTiming set_rx_timing(uint id, ref const UartConfig cfg)
{
    immutable uint chars = uart_rx_chars(cfg);
    uint level = 0;
    while (level + 1 < rx_levels.length && rx_levels[level + 1] <= chars)
        ++level;
    _rx_take[id - first_uart] = cast(ubyte)(rx_levels[level] - 1);
    write_reg(uart_base(id), fcr, fcr_enable | rx_level_field[level] << 6);
    return UartRxTiming(uart_chars_us(cfg, rx_levels[level]), 40);
}

// Reading LSR clears its error bits, so every read keeps them for uart_hw_check_errors.
uint line_status(uint id)
{
    immutable uint s = read_reg(uart_base(id), lsr);
    if (s & lsr_errors)
        _ports.error(id - first_uart, lsr_error_kinds[(s & lsr_errors) >> 1]);
    return s;
}

// LSR bits 1-4: overrun, parity, framing, break
static immutable UartError[16] lsr_error_kinds = () {
    UartError[16] t;
    foreach (i; 0 .. 16)
        t[i] = cast(UartError)((i & 1 ? UartError.overrun : 0) | (i & 2 ? UartError.parity : 0) | (i & 4 ? UartError.framing : 0) | (i & 8 ? UartError.break_ : 0));
    return t;
}();

// Caller holds interrupts off, or runs in the ISR. THRE means the whole FIFO is empty, so it takes a full load.
void tx_fill(uint i)
{
    immutable uint id = i + first_uart;
    immutable base = uart_base(id);
    if (line_status(id) & lsr_thre)
    {
        uint space = fifo_depth;
        while (space)
        {
            const(ubyte)[] bytes = _ports.tx_bytes(i);
            if (!bytes.length)
                break;
            immutable size_t n = bytes.length < space ? bytes.length : space;
            foreach (b; bytes[0 .. n])
                write_reg(base, thr, b);
            space -= n;
            _ports.tx_advance(i, n);
        }
    }
    immutable uint ie = read_reg(base, ier);
    write_reg(base, ier, _ports.tx_queued(i) ? ie | ier_thre : ie & ~ier_thre);
}

bool tx_idle(uint i)
    => (line_status(i + first_uart) & lsr_temt) != 0;

void uart_isr(uint irq)
{
    immutable uint id = irq - 25;
    immutable uint i = id - first_uart;
    immutable base = uart_base(id);
    bool rx;
    while (true)
    {
        immutable uint cause = read_reg(base, iir) & iir_mask;
        if (cause & iir_none)
            break;
        if (cause == iir_thre)
        {
            tx_fill(i);
            continue;
        }
        // the data interrupt leaves a byte for the character timeout; the timeout and an error take all
        uint budget = cause == iir_rda ? _rx_take[i] : uint.max;
        while (budget-- && (line_status(id) & lsr_dr))
            _ports.receive(i, cast(ubyte)read_reg(base, rbr));
        if (cause == iir_cti)
            _ports.gap(i);
        rx = true;
    }
    if (rx)
        _ports.notify(i);
}

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
