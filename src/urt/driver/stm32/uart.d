// F4 has the SR/DR register layout, F7 and H7 the ISR/RDR/TDR one; status bit positions agree.
// Port n is the (n+1)th U(S)ART: 0 = USART1, 5 = USART6, 6 = UART7.
module urt.driver.stm32.uart;

import urt.driver.stm32 : clock_enable, pclk1_hz, pclk2_hz, rcc_apb1enr, rcc_apb2enr, reg_read, reg_write;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.uart : Parity, StopBits, Uart, UartCallbackContext, UartConfig, UartRxCallback;
import urt.mem.ring : RingBuffer;
import urt.sync.spsc : SPSCRing;

nothrow @nogc:

version (STM32F4)
    enum uint num_uarts = 6;
else
    enum uint num_uarts = 8;

enum bool has_irq_driven_uart = true;
enum bool has_dma_driven_uart = false;

bool uart_hw_init(uint id, UartConfig cfg)
{
    import urt.driver.gpio : Pull, gpio_set_function;

    immutable base = uart_base[id];
    clock_enable(on_apb2(id) ? rcc_apb2enr : rcc_apb1enr, clock_bit[id]);

    uint tx = cfg.tx_gpio != ubyte.max ? cfg.tx_gpio : default_tx[id];
    uint rx = cfg.rx_gpio != ubyte.max ? cfg.rx_gpio : default_rx[id];
    gpio_set_function(tx, pin_af(id, tx));
    gpio_set_function(rx, pin_af(id, rx), Pull.up);

    reg_write(base + cr1, 0);
    immutable fck = on_apb2(id) ? pclk2_hz : pclk1_hz;
    reg_write(base + brr, (fck + cfg.baud_rate / 2) / cfg.baud_rate);

    uint c1 = cr1_ue | cr1_te | cr1_re;
    if (cfg.parity != Parity.none)
    {
        c1 |= cr1_pce | cr1_m;          // 8 data bits plus parity is a 9-bit word
        if (cfg.parity == Parity.odd)
            c1 |= cr1_ps;
    }

    uint c2 = 0;
    uint frame_bits = 1 + cfg.data_bits + (cfg.parity != Parity.none);
    final switch (cfg.stop_bits)
    {
        case StopBits.one:            frame_bits += 1; break;
        case StopBits.half:           frame_bits += 1; c2 = 1 << 12; break;
        case StopBits.two:            frame_bits += 2; c2 = 2 << 12; break;
        case StopBits.one_point_five: frame_bits += 2; c2 = 3 << 12; break;
    }
    static if (has_receiver_timeout)
    {
        reg_write(base + rtor, (7 * frame_bits + 1) / 2);
        c2 |= cr2_rtoen;
    }
    _rx_chars[id] = cast(ushort)(cfg.baud_rate / frame_bits * rx_latency_us / 1_000_000);

    uint c3 = 0;
    static if (has_fifo)
    {
        c1 |= cr1_fifoen;
        c3 = rx_level(_rx_chars[id]) << 25 | tx_level_half << 29;
    }

    reg_write(base + cr2, c2);
    reg_write(base + cr3, c3);
    reg_write(base + cr1, c1 & ~cr1_ue);        // FIFOEN takes only while the USART is disabled
    reg_write(base + cr1, c1);
    return true;
}

bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    if (!uart_hw_init(id, cfg))
        return false;
    rx_ring[id].init();
    tx_ring[id].purge();
    _rx_cb[id] = rx_cb;
    static if (!has_fifo)
        _rx_count[id] = 0;
    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    static if (has_fifo)
        reg_write(uart_base[id] + cr3, reg_read(uart_base[id] + cr3) | cr3_rxftie);
    reg_write(uart_base[id] + cr1, reg_read(uart_base[id] + cr1) | (has_fifo ? 0 : cr1_rxneie) | cr1_gapie);
    return true;
}

void uart_hw_close(uint id)
{
    irq_line_disable(uart_irq[id]);
    reg_write(uart_base[id] + cr1, 0);
    reg_write(uart_base[id] + cr3, 0);
    _rx_cb[id] = null;
    rx_ring[id].init();
    tx_ring[id].purge();
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
    => rx_ring[id].pop(cast(ubyte[])buffer);

// Blocks while the ring is full; the console treats a short write as sent.
ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    size_t total = 0;
    while (total < data.length)
    {
        auto guard = irq_critical();
        total += tx_ring[id].write(data[total .. $]);
        tx_fill(id);
    }
    return total;
}

ptrdiff_t uart_hw_tx_pending(uint id)
{
    auto guard = irq_critical();
    return tx_ring[id].pending;
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
    => rx_ring[id].pending;

ptrdiff_t uart_hw_flush(uint id)
{
    while (uart_hw_tx_pending(id))
    {}
    while (!(reg_read(uart_base[id] + sr) & st_tc))
    {}
    return 0;
}

// Blocking console output for early boot and fault context; queued output goes first. Each
// byte is its own critical section, so the ISR never shares the ring or TDR mid-step.
void uart0_hw_puts(const(char)[] s)
{
    import urt.driver.uart : console_uart;

    enum base = uart_base[console_uart];
    size_t i = 0;
    while (i < s.length)
    {
        auto guard = irq_critical();
        if (reg_read(base + sr) & st_txe)
        {
            if (!tx_ring[console_uart].empty)
                tx_fill(console_uart);
            else
                reg_write(base + tdr, s[i++]);
        }
    }
}


private:

version (STM32F4) enum legacy_usart = true;
else              enum legacy_usart = false;

// F4 has no receiver timeout, so its gap is the one-character IDLE line; F7 and H7 time 3.5 characters.
static if (legacy_usart)
{
    enum uint sr = 0x00, rdr = 0x04, tdr = 0x04, brr = 0x08, cr1 = 0x0C, cr2 = 0x10, cr3 = 0x14;
    enum uint cr1_ue = 1 << 13;
    enum uint cr1_gapie = 1 << 4;
    enum uint st_gap = 1 << 4;
    enum bool has_receiver_timeout = false;
}
else
{
    enum uint cr1 = 0x00, cr2 = 0x04, cr3 = 0x08, brr = 0x0C, rtor = 0x14, sr = 0x1C, icr = 0x20, rdr = 0x24, tdr = 0x28;
    enum uint cr1_ue = 1 << 0;
    enum uint cr1_gapie = 1 << 26;
    enum uint cr2_rtoen = 1 << 23;
    enum uint st_gap = 1 << 11;
    enum bool has_receiver_timeout = true;
}

// The H7 U(S)ARTs have 16-byte FIFOs: RX interrupts at a fill threshold, TX once half the FIFO is free.
// TODO: F4 and F7 have none and take an interrupt per byte; RX wants circular DMA with IDLE/RTO (TODO.md).
version (STM32H7) enum bool has_fifo = true;
else              enum bool has_fifo = false;

static if (has_fifo)
{
    enum uint cr1_fifoen = 1 << 29;
    enum uint cr3_txftie = 1 << 23;
    enum uint cr3_rxftie = 1 << 28;
    enum uint st_rxft = 1 << 26;
    enum uint tx_level_half = 2;

    static immutable ubyte[5] rx_level_bytes = [ 2, 4, 8, 12, 14 ];

    // the deepest RX threshold that fills within rx_latency_us, and never below the first
    uint rx_level(uint chars) pure
    {
        uint level = 0;
        while (level + 1 < rx_level_bytes.length && rx_level_bytes[level + 1] <= chars)
            ++level;
        return level;
    }
}

enum uint cr1_re     = 1 << 2;
enum uint cr1_te     = 1 << 3;
enum uint cr1_rxneie = 1 << 5;
enum uint cr1_txeie  = 1 << 7;
enum uint cr1_ps     = 1 << 9;
enum uint cr1_pce    = 1 << 10;
enum uint cr1_m      = 1 << 12;

enum uint st_pe   = 1 << 0;
enum uint st_fe   = 1 << 1;
enum uint st_ore  = 1 << 3;
enum uint st_rxne = 1 << 5;
enum uint st_tc   = 1 << 6;
enum uint st_txe  = 1 << 7;
enum uint st_errors = st_pe | st_fe | st_ore;

static immutable ulong[8] uart_base = [
    0x4001_1000, 0x4000_4400, 0x4000_4800, 0x4000_4C00,
    0x4000_5000, 0x4001_1400, 0x4000_7800, 0x4000_7C00,
];
static immutable ubyte[8] clock_bit = [4, 17, 18, 19, 20, 5, 30, 31];
static immutable ubyte[8] uart_irq = [37, 38, 39, 52, 53, 71, 82, 83];

enum uint pa = 0, pb = 16, pc = 32, pd = 48, pe = 64, pf = 80;
static immutable ubyte[8] default_tx = [pa + 9, pa + 2, pb + 10, pa + 0, pc + 12, pc + 6, pf + 7, pe + 1];
static immutable ubyte[8] default_rx = [pa + 10, pa + 3, pb + 11, pa + 1, pd + 2, pc + 7, pf + 6, pe + 0];

enum uint rx_ring_size = 512;
enum uint rx_latency_us = 350;

__gshared SPSCRing!(ubyte, rx_ring_size)[num_uarts] rx_ring;
__gshared UartRxCallback[num_uarts] _rx_cb;
__gshared ushort[num_uarts] _rx_chars;
static if (!has_fifo)
    __gshared ushort[num_uarts] _rx_count;

// TX refills on a free byte, or with a FIFO on half the FIFO free.
static if (has_fifo)
{
    enum uint tx_ie_reg = cr3, tx_ie = cr3_txftie;
}
else
{
    enum uint tx_ie_reg = cr1, tx_ie = cr1_txeie;
}
__gshared RingBuffer!1024[num_uarts] tx_ring;
__gshared bool[num_uarts] _errors;

bool on_apb2(uint id) => id == 0 || id == 5;

uint pin_af(uint id, uint pin)
{
    foreach (e; pin_af_exceptions)
    {
        if (e.id == id && e.pin == pin)
            return e.af;
    }
    return port_af[id];
}

struct PinAf
{
    ubyte id, pin, af;
}

// Each port's usual alternate function, then the H7 pins that route a port through another.
version (STM32H7)
{
    static immutable ubyte[8] port_af = [7, 7, 7, 8, 8, 7, 7, 8];
    static immutable PinAf[12] pin_af_exceptions = [
        PinAf(0, pb + 14, 4), PinAf(0, pb + 15, 4),
        PinAf(3, pa + 11, 6), PinAf(3, pa + 12, 6),
        PinAf(4, pb + 5, 14), PinAf(4, pb + 6, 14), PinAf(4, pb + 12, 14), PinAf(4, pb + 13, 14),
        PinAf(6, pa + 8, 11), PinAf(6, pa + 15, 11), PinAf(6, pb + 3, 11), PinAf(6, pb + 4, 11),
    ];
}
else
{
    static immutable ubyte[8] port_af = [7, 7, 7, 8, 8, 8, 8, 8];
    static immutable PinAf[0] pin_af_exceptions;
}

// Caller holds interrupts off, or runs in the ISR.
void tx_fill(uint id)
{
    immutable base = uart_base[id];
    ubyte[1] b = void;
    while (!tx_ring[id].empty && (reg_read(base + sr) & st_txe))
    {
        tx_ring[id].read(b[]);
        reg_write(base + tdr, b[0]);
    }
    uint ie = reg_read(base + tx_ie_reg);
    ie = tx_ring[id].empty ? ie & ~tx_ie : ie | tx_ie;
    reg_write(base + tx_ie_reg, ie);
}

void uart_isr(uint irq)
{
    uint id = 0;
    while (uart_irq[id] != irq)
        ++id;
    immutable base = uart_base[id];

    uint status = reg_read(base + sr);
    bool deliver;
    static if (has_fifo)
    {
        while (reg_read(base + sr) & st_rxne)
        {
            ubyte b = cast(ubyte)reg_read(base + rdr);
            if (!rx_ring[id].push((&b)[0 .. 1]))
                _errors[id] = true;
        }
        if (status & st_gap)
            reg_write(base + icr, st_gap);
        deliver = (status & (st_rxft | st_gap)) != 0;
    }
    else
    {
        if (status & (st_rxne | st_ore | st_gap))
        {
            // F4 clears ORE/FE/PE and IDLE by the SR read followed by this DR read.
            ubyte b = cast(ubyte)reg_read(base + rdr);
            if (status & st_rxne)
            {
                if (!rx_ring[id].push((&b)[0 .. 1]))
                    _errors[id] = true;
                if (++_rx_count[id] >= _rx_chars[id])
                    deliver = true;
            }
        }
        if (status & st_gap)
        {
            static if (!legacy_usart)
                reg_write(base + icr, st_gap);
            deliver = _rx_count[id] != 0;
        }
    }
    if (status & st_errors)
    {
        _errors[id] = true;
        static if (!legacy_usart)
            reg_write(base + icr, st_errors);
    }
    if (deliver)
    {
        static if (!has_fifo)
            _rx_count[id] = 0;
        if (_rx_cb[id])
            _rx_cb[id](Uart(cast(ubyte)id), rx_ring[id].pending, UartCallbackContext.interrupt);
    }
    if (reg_read(base + tx_ie_reg) & tx_ie)
        tx_fill(id);
}
