module urt.driver.rp2350.uart;

import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.gpio : Pull;
import urt.driver.rp2350 : clk_peri_hz, gpio_route, out_of_reset, reset_io_bank0, reset_pads_bank0, reset_pulse, reset_uart0, reset_uart1, unreset_wait;
import urt.driver.rp2350.gpio : gpio_set_pull;
import urt.driver.uart : DriveMode, Parity, StopBits, Uart, UartCallbackContext, UartConfig, UartRxCallback, UartRxTiming,
    uart_chars_us, uart_gap_tenths, uart_rx_chars;
import urt.mem.alloc : alloc, free;
import urt.mem.ring : RingBuffer;
import urt.sync.spsc : SPSCRing;

import core.volatile;

nothrow @nogc:

enum num_uarts = 2;
enum uint console_uart = 1;
enum uint uart_clock_hz = clk_peri_hz;
enum bool has_irq_driven_uart = true;
enum bool has_dma_driven_uart = false;

bool uart_hw_init(uint id, UartConfig cfg)
{
    if (cfg.baud_rate == 0 || cfg.data_bits < 5 || cfg.data_bits > 8 || (cfg.drive_mode != DriveMode.auto_ && cfg.drive_mode != DriveMode.interrupt))
        return false;
    immutable base = uart_base(id);

    unreset_wait(reset_io_bank0 | reset_pads_bank0 | (id == 0 ? reset_uart0 : reset_uart1));
    gpio_route(default_tx_gpio[id], 2, false);
    gpio_route(default_rx_gpio[id], 2, true);
    gpio_set_pull(default_rx_gpio[id], Pull.up);

    uart_write_reg(base, uartcr, 0);

    immutable uint bauddiv_x64 = (uart_clock_hz * 4) / cfg.baud_rate;
    uart_write_reg(base, uartibrd, bauddiv_x64 / 64);
    uart_write_reg(base, uartfbrd, bauddiv_x64 % 64);

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
    import urt.mem.alloc : MemFlags;

    uart_hw_flush(id);
    reset_pulse(id == 0 ? reset_uart0 : reset_uart1);
    if (!rx_ring[id])
    {
        rx_ring[id] = alloc!RxRing(MemFlags.none);
        tx_ring[id] = alloc!TxRing(MemFlags.none);
    }
    if (!rx_ring[id] || !tx_ring[id] || !uart_hw_init(id, cfg))
    {
        release_rings(id);
        return false;
    }
    (*rx_ring[id]).init();
    tx_ring[id].purge();
    _errors[id] = false;
    _rx_cb[id] = rx_cb;
    immutable base = uart_base(id);
    immutable uint level = rx_level(uart_rx_chars(cfg));
    uart_write_reg(base, uartifls, level << 3 | ifls_tx_eighth);
    _timing[id] = UartRxTiming(uart_chars_us(cfg, rx_level_chars[level]), uart_gap_tenths(cfg, rx_timeout_bits));
    uart_write_reg(base, uarticr, 0x7FF);
    uart_write_reg(base, uartimsc, im_rx | im_rt | im_errors);
    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    return true;
}

void uart_hw_close(uint id)
{
    irq_line_disable(uart_irq[id]);
    immutable base = uart_base(id);
    uart_write_reg(base, uartimsc, 0);
    uart_write_reg(base, uartcr, 0);
    _rx_cb[id] = null;
    release_rings(id);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
    => rx_ring[id] ? rx_ring[id].pop(cast(ubyte[])buffer) : 0;

// Blocks while the ring is full; the console treats a short write as sent.
ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    if (!tx_ring[id])
        return 0;
    size_t total = 0;
    while (total < data.length)
    {
        auto guard = irq_critical();
        total += tx_ring[id].write(data[total .. $]);
        tx_fill(id);
    }
    return total;
}

UartRxTiming uart_hw_rx_timing(uint id)
    => _timing[id];

ptrdiff_t uart_hw_tx_pending(uint id)
{
    auto guard = irq_critical();
    return tx_ring[id] ? tx_ring[id].pending : 0;
}

void uart_hw_poll(uint id) {}

bool uart_hw_check_errors(uint id)
{
    auto guard = irq_critical();
    bool errors = _errors[id];
    _errors[id] = false;
    return errors;
}

ptrdiff_t uart_hw_rx_pending(uint id)
    => rx_ring[id] ? rx_ring[id].pending : 0;

// Feeds the FIFO itself, so it drains with interrupts masked too.
ptrdiff_t uart_hw_flush(uint id)
{
    immutable base = uart_base(id);
    if (!out_of_reset(id == 0 ? reset_uart0 : reset_uart1) || !(uart_read_reg(base, uartcr) & cr_uarten))
        return 0;
    while (true)
    {
        auto guard = irq_critical();
        tx_fill(id);
        if (!tx_ring[id] || tx_ring[id].empty)
            break;
    }
    while (uart_read_reg(base, uartfr) & fr_busy)
    {}
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
    while (i < s.length)
    {
        auto guard = irq_critical();
        if (!(volatileLoad(cast(uint*)(base + uartfr)) & fr_txff))
        {
            if (tx_ring[console_uart] && !tx_ring[console_uart].empty)
                tx_fill(console_uart);
            else
                volatileStore(cast(uint*)(base + uartdr), cast(uint)s[i++]);
        }
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

enum uint rx_ring_size = 512;
enum uint rx_timeout_bits = 32;

// RX signals on the receive timeout, fixed in the PL011 at 32 quiet bit times, or on the FIFO reaching the deepest
// level within the characters of the RX latency, so a steady stream still reaches the main loop in that time.
static immutable ubyte[5] rx_level_chars = [ 4, 8, 16, 24, 28 ];

uint rx_level(uint chars) pure
{
    uint level = 0;
    while (level + 1 < rx_level_chars.length && rx_level_chars[level + 1] <= chars)
        ++level;
    return level;
}

alias RxRing = SPSCRing!(ubyte, rx_ring_size);
alias TxRing = RingBuffer!1024;

__gshared RxRing*[num_uarts] rx_ring;
__gshared TxRing*[num_uarts] tx_ring;
__gshared UartRxCallback[num_uarts] _rx_cb;
__gshared bool[num_uarts] _errors;
__gshared UartRxTiming[num_uarts] _timing;

void release_rings(uint id)
{
    RxRing* rx;
    TxRing* tx;
    {
        auto guard = irq_critical();
        rx = rx_ring[id];
        tx = tx_ring[id];
        rx_ring[id] = null;
        tx_ring[id] = null;
    }
    if (rx)
        free(rx);
    if (tx)
        free(tx);
}

// Caller holds interrupts off, or runs in the ISR. The PL011 raises TX only on the FIFO falling to its level, so
// the FIFO is filled here directly and TX is armed only while the ring still holds more.
void tx_fill(uint id)
{
    immutable base = uart_base(id);
    TxRing* ring = tx_ring[id];
    if (!ring)
        return;
    ubyte[1] b = void;
    while (!ring.empty && !(uart_read_reg(base, uartfr) & fr_txff))
    {
        ring.read(b[]);
        uart_write_reg(base, uartdr, b[0]);
    }
    uint mask = uart_read_reg(base, uartimsc);
    mask = ring.empty ? mask & ~im_tx : mask | im_tx;
    uart_write_reg(base, uartimsc, mask);
}

void uart_isr(uint irq)
{
    immutable uint id = irq == uart_irq[0] ? 0 : 1;
    immutable base = uart_base(id);

    immutable uint status = uart_read_reg(base, uartmis);
    uart_write_reg(base, uarticr, status);
    if (status & im_errors)
        _errors[id] = true;
    bool pushed;
    while (!(uart_read_reg(base, uartfr) & fr_rxfe))
    {
        immutable uint d = uart_read_reg(base, uartdr);
        ubyte b = cast(ubyte)d;
        if ((d & dr_errors) || !rx_ring[id] || !rx_ring[id].push((&b)[0 .. 1]))
            _errors[id] = true;
        else
            pushed = true;
    }
    if (_rx_cb[id] && (pushed || (status & (im_rt | im_errors))))
        _rx_cb[id](Uart(cast(ubyte)id), rx_ring[id] ? rx_ring[id].pending : 0, UartCallbackContext.interrupt);
    if (status & im_tx)
        tx_fill(id);
}


unittest
{
    assert(rx_level(4) == 0, "4 characters, 347 us at 115200, take the first level");
    assert(rx_level(16) == 2, "16 characters, 347 us at 460800");
    assert(rx_level(35) == 4, "28 of the 35 characters of 350 us at 1 Mbaud");
    assert(rx_level(0) == 0, "a slow line still takes the first level");
}
