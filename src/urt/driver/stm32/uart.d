// F4 has the SR/DR register layout, F7 and H7 the ISR/RDR/TDR one; status bit positions agree.
// Port n is the (n+1)th U(S)ART: 0 = USART1, 5 = USART6, 6 = UART7.
module urt.driver.stm32.uart;

import urt.driver.stm32 : clock_enable, pclk1_hz, pclk2_hz, rcc_apb1enr, rcc_apb2enr, reg_read, reg_write;
import urt.driver.stm32.irq : irq_clear_enable, irq_disable, irq_enable, irq_set_enable, irq_set_handler;
import urt.driver.uart : Parity, StopBits, UartConfig;
import urt.mem.ring : RingBuffer;

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
    final switch (cfg.stop_bits)
    {
        case StopBits.one:            break;
        case StopBits.half:           c2 = 1 << 12; break;
        case StopBits.two:            c2 = 2 << 12; break;
        case StopBits.one_point_five: c2 = 3 << 12; break;
    }

    reg_write(base + cr2, c2);
    reg_write(base + cr3, 0);
    reg_write(base + cr1, c1);
    return true;
}

bool uart_hw_open(uint id, UartConfig cfg)
{
    if (!uart_hw_init(id, cfg))
        return false;
    rx_ring[id].purge();
    tx_ring[id].purge();
    irq_set_handler(uart_irq[id], &uart_isr);
    irq_set_enable(uart_irq[id]);
    reg_write(uart_base[id] + cr1, reg_read(uart_base[id] + cr1) | cr1_rxneie);
    return true;
}

void uart_hw_close(uint id)
{
    irq_clear_enable(uart_irq[id]);
    reg_write(uart_base[id] + cr1, 0);
    rx_ring[id].purge();
    tx_ring[id].purge();
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    bool was_enabled = irq_disable();
    size_t n = rx_ring[id].read(buffer);
    if (was_enabled)
        irq_enable();
    return n;
}

// Blocks while the ring is full; the console treats a short write as sent.
ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    size_t total = 0;
    while (total < data.length)
    {
        bool was_enabled = irq_disable();
        size_t n = tx_ring[id].write(data[total .. $]);
        total += n;
        tx_fill(id);
        if (was_enabled)
            irq_enable();
    }
    return total;
}

ptrdiff_t uart_hw_tx_pending(uint id)
{
    bool was_enabled = irq_disable();
    size_t n = tx_ring[id].pending;
    if (was_enabled)
        irq_enable();
    return n;
}

void uart_hw_poll(uint id) {}

bool uart_hw_check_errors(uint id)
{
    bool was_enabled = irq_disable();
    bool errors = _errors[id];
    _errors[id] = false;
    if (was_enabled)
        irq_enable();
    return errors;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    bool was_enabled = irq_disable();
    size_t n = rx_ring[id].pending;
    if (was_enabled)
        irq_enable();
    return n;
}

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
        bool was_enabled = irq_disable();
        if (reg_read(base + sr) & st_txe)
        {
            if (!tx_ring[console_uart].empty)
                tx_fill(console_uart);
            else
                reg_write(base + tdr, s[i++]);
        }
        if (was_enabled)
            irq_enable();
    }
}


private:

version (STM32F4) enum legacy_usart = true;
else              enum legacy_usart = false;

static if (legacy_usart)
{
    enum uint sr = 0x00, rdr = 0x04, tdr = 0x04, brr = 0x08, cr1 = 0x0C, cr2 = 0x10, cr3 = 0x14;
    enum uint cr1_ue = 1 << 13;
}
else
{
    enum uint cr1 = 0x00, cr2 = 0x04, cr3 = 0x08, brr = 0x0C, sr = 0x1C, icr = 0x20, rdr = 0x24, tdr = 0x28;
    enum uint cr1_ue = 1 << 0;
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

__gshared RingBuffer!256[num_uarts] rx_ring;
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
    uint c1 = reg_read(base + cr1);
    c1 = tx_ring[id].empty ? c1 & ~cr1_txeie : c1 | cr1_txeie;
    reg_write(base + cr1, c1);
}

void uart_isr(uint irq)
{
    uint id = 0;
    while (uart_irq[id] != irq)
        ++id;
    immutable base = uart_base[id];

    uint status = reg_read(base + sr);
    if (status & (st_rxne | st_ore))
    {
        // F4 clears ORE/FE/PE by the SR read followed by this DR read.
        ubyte b = cast(ubyte)reg_read(base + rdr);
        if ((status & st_rxne) && !rx_ring[id].write((&b)[0 .. 1]))
            _errors[id] = true;
    }
    if (status & st_errors)
    {
        _errors[id] = true;
        static if (!legacy_usart)
            reg_write(base + icr, st_errors);
    }
    if (reg_read(base + cr1) & cr1_txeie)
        tx_fill(id);
}
