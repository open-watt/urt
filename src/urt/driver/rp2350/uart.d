module urt.driver.rp2350.uart;

import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.gpio : Pull;
import urt.driver.rp2350 : clk_peri_hz, gpio_route, out_of_reset, reset_io_bank0, reset_pads_bank0, reset_pulse, reset_uart0, reset_uart1, unreset_wait;
import urt.driver.rp2350.gpio : gpio_set_pull;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartError, UartRxCallback, UartRxTiming,
    uart_chars_us, uart_gap_tenths, uart_rate_close, uart_rx_chars;
import urt.driver.uart_core : UartPorts, puts_stall_spins;

import core.volatile;

nothrow @nogc:

enum num_uarts = 2;
enum uint console_uart = 1;
enum uint uart_clock_hz = clk_peri_hz;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd;
enum uint uart_stop_bits = 1 << StopBits.one | 1 << StopBits.two;
enum uint uart_flow_controls = 1 << FlowControl.none;
enum bool uart_has_rs485 = false;
enum bool uart_has_pin_select = false;

bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable uint div = divider_x64(cfg.baud_rate);
    if (!div)
        return false;
    immutable base = uart_base(id);

    unreset_wait(reset_io_bank0 | reset_pads_bank0 | (id == 0 ? reset_uart0 : reset_uart1));
    gpio_route(default_tx_gpio[id], 2, false);
    gpio_route(default_rx_gpio[id], 2, true);
    gpio_set_pull(default_rx_gpio[id], Pull.up);

    uart_write_reg(base, uartcr, 0);

    uart_write_reg(base, uartibrd, div / 64);
    uart_write_reg(base, uartfbrd, div % 64);

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

// A warm reset spares the UART, so it is reset here: what is queued goes out first, then it starts clean.
bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    if (!divider_x64(cfg.baud_rate))
        return false;
    uart_hw_flush(id);
    reset_pulse(id == 0 ? reset_uart0 : reset_uart1);
    if (!_ports.acquire(id))
        return false;
    if (!uart_hw_init(id, cfg))
    {
        _ports.release(id);
        return false;
    }
    immutable base = uart_base(id);
    _ports.start(id, rx_cb, set_rx_level(id, cfg));
    uart_write_reg(base, uarticr, 0x7FF);
    uart_write_reg(base, uartimsc, im_rx | im_rt | im_errors);
    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    return true;
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    irq_line_disable(uart_irq[id]);
    immutable base = uart_base(id);
    uart_write_reg(base, uartimsc, 0);
    uart_write_reg(base, uartcr, 0);
    _ports.release(id);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
    => _ports.read(id, buffer);

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
    => _ports.write(id, data);

UartRxTiming uart_hw_rx_timing(uint id)
    => _ports.timing(id);

// UARTIFLS takes a new level while the UART runs; the receive timeout is fixed.
UartRxTiming uart_hw_set_rx_timing(uint id, ref const UartConfig cfg)
{
    _ports.retime(id, set_rx_level(id, cfg));
    return _ports.timing(id);
}

ptrdiff_t uart_hw_tx_pending(uint id)
    => _ports.tx_pending(id);

void uart_hw_poll(uint id) {}

UartError uart_hw_check_errors(uint id)
    => _ports.take_errors(id);

ptrdiff_t uart_hw_rx_pending(uint id)
    => _ports.rx_pending(id);

ptrdiff_t uart_hw_flush(uint id)
{
    if (out_of_reset(id == 0 ? reset_uart0 : reset_uart1) && (uart_read_reg(uart_base(id), uartcr) & cr_uarten))
        _ports.drain(id);
    return 0;
}

// Blocking console output for early boot and fault context; queued output goes first. Each
// byte is its own critical section, so the ISR never shares the ring or the FIFO mid-step.
void uart0_hw_puts(const(char)[] s)
{
    enum ulong base = uart_base(console_uart);
    if (!(volatileLoad(cast(uint*)(base + uartcr)) & cr_uarten))
        return;
    size_t i = 0;
    uint spins = 0;
    while (i < s.length && spins < puts_stall_spins)
    {
        auto guard = irq_critical();
        if (!(volatileLoad(cast(uint*)(base + uartfr)) & fr_txff))
        {
            if (_ports.tx_queued(console_uart))
                tx_fill(console_uart);
            else
                volatileStore(cast(uint*)(base + uartdr), cast(uint)s[i++]);
            spins = 0;
        }
        else
            ++spins;
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
    uartifls   = 0x034,
    uartimsc   = 0x038,
    uartmis    = 0x040,
    uarticr    = 0x044,
}

enum
{
    fr_txff = 1 << 5,
    fr_rxfe = 1 << 4,
    fr_busy = 1 << 3,
}

enum
{
    im_rx     = 1 << 4,
    im_tx     = 1 << 5,
    im_rt     = 1 << 6,
    im_errors = 0xF << 7,
    ifls_tx_eighth = 0 << 0,
    dr_errors = 0xF << 8,
}

// framing, parity, break and overrun, in that order in both UARTMIS and UARTDR
static immutable UartError[16] pl011_errors = () {
    UartError[16] t;
    foreach (i; 0 .. 16)
        t[i] = cast(UartError)((i & 1 ? UartError.framing : 0) | (i & 2 ? UartError.parity : 0) | (i & 4 ? UartError.break_ : 0) | (i & 8 ? UartError.overrun : 0));
    return t;
}();

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
static immutable ubyte[num_uarts] uart_irq = [33, 34];

enum uint rx_timeout_bits = 32;

// RX signals on the receive timeout, fixed in the PL011 at 32 quiet bit times, or on the FIFO reaching the deepest
// level within the characters of the RX latency, so a steady stream still reaches the main loop in that time.
static immutable ubyte[5] rx_level_chars = [ 4, 8, 16, 24, 28 ];

// The baud divisor in 64ths, rounded; its integer part runs from 1 to 0xFFFF, and 0xFFFF takes no fraction.
uint divider_x64(uint baud) pure
{
    immutable ulong d = (ulong(uart_clock_hz) * 8 / baud + 1) / 2;
    return d >= 64 && d <= 0xFFFF * 64 && uart_rate_close(baud, ulong(uart_clock_hz) * 4, d) ? cast(uint)d : 0;
}

UartRxTiming set_rx_level(uint id, ref const UartConfig cfg)
{
    immutable uint level = rx_level(uart_rx_chars(cfg));
    uart_write_reg(uart_base(id), uartifls, level << 3 | ifls_tx_eighth);
    return UartRxTiming(uart_chars_us(cfg, rx_level_chars[level]), uart_gap_tenths(cfg, rx_timeout_bits));
}

uint rx_level(uint chars) pure
{
    uint level = 0;
    while (level + 1 < rx_level_chars.length && rx_level_chars[level + 1] <= chars)
        ++level;
    return level;
}

__gshared UartPorts!(num_uarts, 0, tx_idle, tx_fill) _ports;

// Caller holds interrupts off, or runs in the ISR. The PL011 raises TX only on the FIFO falling to its level, so
// the FIFO is filled here directly and TX is armed only while the ring still holds more.
void tx_fill(uint id)
{
    immutable base = uart_base(id);
    ubyte b;
    while (!(uart_read_reg(base, uartfr) & fr_txff) && _ports.tx_pop(id, b))
        uart_write_reg(base, uartdr, b);
    uint mask = uart_read_reg(base, uartimsc);
    mask = _ports.tx_queued(id) ? mask | im_tx : mask & ~im_tx;
    uart_write_reg(base, uartimsc, mask);
}

bool tx_idle(uint id)
    => !(uart_read_reg(uart_base(id), uartfr) & fr_busy);

void uart_isr(uint irq)
{
    immutable uint id = irq == uart_irq[0] ? 0 : 1;
    immutable base = uart_base(id);

    immutable uint status = uart_read_reg(base, uartmis);
    uart_write_reg(base, uarticr, status);
    if (status & im_errors)
        _ports.error(id, pl011_errors[(status & im_errors) >> 7]);
    bool read;
    while (!(uart_read_reg(base, uartfr) & fr_rxfe))
    {
        immutable uint d = uart_read_reg(base, uartdr);
        if (d & dr_errors)
            _ports.error(id, pl011_errors[(d & dr_errors) >> 8]);
        else
            _ports.receive(id, cast(ubyte)d);
        read = true;
    }
    if (read || (status & (im_rt | im_errors)))
        _ports.notify(id);
    if (status & im_tx)
        tx_fill(id);
}


unittest
{
    assert(rx_level(4) == 0, "4 characters, 347 us at 115200, take the first level");
    assert(rx_level(16) == 2, "16 characters, 347 us at 460800");
    assert(rx_level(35) == 4, "28 of the 35 characters of 350 us at 1 Mbaud");
    assert(rx_level(0) == 0, "a slow line still takes the first level");
    assert(divider_x64(115_200) == 5208, "115200 from 150 MHz is 81 + 24/64");
    assert(!divider_x64(100) && !divider_x64(10_000_000), "past the divisor's range either way");
}
