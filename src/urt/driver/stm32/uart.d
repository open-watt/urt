// F4 has the SR/DR register layout, F7 and H7 the ISR/RDR/TDR one; status bit positions agree.
// Port n is the (n+1)th U(S)ART: 0 = USART1, 5 = USART6, 6 = UART7; on H7, port 8 is LPUART1.
module urt.driver.stm32.uart;

import urt.driver.gpio : Pull;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.stm32 : clock_enable, pclk1_hz, pclk2_hz, rcc_apb1enr, rcc_apb2enr, reg_read, reg_write;
import urt.driver.stm32.gpio : gpio_set_function;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, Uart, UartCallbackContext, UartConfig, UartRxCallback, UartRxTiming,
    uart_chars_us, uart_rx_chars, uart_rx_gap_bits;
import urt.mem.alloc : alloc, free;
import urt.mem.ring : RingBuffer;
import urt.sync.spsc : SPSCRing;
import urt.time : getTime, msecs;

nothrow @nogc:

version (STM32F4)      enum uint num_uarts = 6;
else version (STM32H7) enum uint num_uarts = 9;
else                   enum uint num_uarts = 8;

enum bool has_irq_driven_uart = true;
enum bool has_dma_driven_uart = false;

// Refuses what the port cannot do rather than open without it: RS-485 DE and RTS/CTS need their pins.
bool uart_hw_init(uint id, UartConfig cfg)
{
    import urt.driver.gpio : gpio_count;

    if (id >= num_uarts || cfg.baud_rate == 0 || (cfg.drive_mode != DriveMode.auto_ && cfg.drive_mode != DriveMode.interrupt))
        return false;
    immutable base = uart_base[id];
    clock_enable(clock_reg[id], clock_bit[id]);

    uint tx = cfg.tx_gpio != ubyte.max ? cfg.tx_gpio : default_tx[id];
    uint rx = cfg.rx_gpio != ubyte.max ? cfg.rx_gpio : default_rx[id];
    gpio_set_function(tx, pin_af(id, tx));
    gpio_set_function(rx, pin_af(id, rx), Pull.up);

    reg_write(base + cr1, 0);

    uint c1 = cr1_ue | cr1_te | cr1_re;
    if (cfg.parity != Parity.none)
    {
        c1 |= cr1_pce | cr1_m;          // 8 data bits plus parity is a 9-bit word
        if (cfg.parity == Parity.odd)
            c1 |= cr1_ps;
    }

    static immutable ubyte[StopBits.max + 1] stop_field = [ 1, 0, 3, 2 ];
    uint c2 = stop_field[cfg.stop_bits] << 12;

    uint c3 = 0;
    if (cfg.flow_control == FlowControl.hardware)
    {
        if (!has_flow_control(id) || cfg.rts_gpio >= gpio_count() || cfg.cts_gpio >= gpio_count())
            return false;
        gpio_set_function(cfg.rts_gpio, pin_af(id, cfg.rts_gpio));
        gpio_set_function(cfg.cts_gpio, pin_af(id, cfg.cts_gpio), Pull.up);
        c3 |= cr3_rtse | cr3_ctse;
    }
    else if (cfg.flow_control != FlowControl.none)
        return false;

    ulong de_unit_hz = 16 * ulong(cfg.baud_rate);
    static if (has_lpuart)
    {
        if (id == lpuart)
        {
            uint presc, div;
            if (!lpuart_divider(pclk4_hz, cfg.baud_rate, presc, div))
                return false;
            reg_write(base + lpuart_presc, presc);
            reg_write(base + brr, div);
            de_unit_hz = div >> 11 ? pclk4_hz / lpuart_prescalers[presc] / (div >> 11) : 0;
        }
        else
            reg_write(base + brr, (fck(id) + cfg.baud_rate / 2) / cfg.baud_rate);
    }
    else
        reg_write(base + brr, (fck(id) + cfg.baud_rate / 2) / cfg.baud_rate);

    if (cfg.rs485.enabled)
    {
        static if (legacy_usart)
            return false;
        else
        {
            if (cfg.rs485.de_gpio >= gpio_count() || cfg.rs485.turnaround_us || !de_unit_hz)
                return false;
            gpio_set_function(cfg.rs485.de_gpio, pin_af(id, cfg.rs485.de_gpio));
            c3 |= cr3_dem | (cfg.rs485.de_active_high ? 0 : cr3_dep);
            c1 |= de_time(cfg.rs485.de_assert_us, de_unit_hz) << 21 | de_time(cfg.rs485.de_deassert_us, de_unit_hz) << 16;
        }
    }

    static if (!legacy_usart)
    {
        if (has_receiver_timeout(id))
        {
            reg_write(base + rtor, uart_rx_gap_bits(cfg));
            c2 |= cr2_rtoen;
        }
    }
    Port* p = &_port[id];
    p.timing.gap = has_receiver_timeout(id) ? cfg.rx_gap : 10;
    immutable uint chars = uart_rx_chars(cfg);
    static if (has_fifo)
    {
        c1 |= cr1_fifoen;
        immutable uint level = rx_level(chars);
        c3 |= level << 25 | tx_level_half << 29;
        p.timing.latency_us = uart_chars_us(cfg, rx_level_bytes[level]);
    }
    else
    {
        p.rx_chars = cast(ushort)(chars < ushort.max ? chars : ushort.max);
        p.timing.latency_us = uart_chars_us(cfg, p.rx_chars);
    }

    reg_write(base + cr2, c2);
    reg_write(base + cr3, c3);
    reg_write(base + cr1, c1 & ~cr1_ue);        // FIFOEN and DEAT/DEDT take only while the USART is disabled
    reg_write(base + cr1, c1);
    return true;
}

bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    import urt.mem.alloc : MemFlags;

    if (id >= num_uarts)
        return false;
    Port* p = &_port[id];
    if (!p.rx)
    {
        p.rx = alloc!RxRing(MemFlags.none);
        p.tx = alloc!TxRing(MemFlags.none);
        if (!p.rx || !p.tx)
        {
            release_rings(id);
            return false;
        }
    }
    if (!uart_hw_init(id, cfg))
    {
        release_rings(id);
        return false;
    }
    (*p.rx).init();
    p.tx.purge();
    p.cb = rx_cb;
    static if (!has_fifo)
        p.count = 0;
    p.errors = false;
    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    immutable base = uart_base[id];
    static if (has_fifo)
        reg_write(base + cr3, reg_read(base + cr3) | cr3_rxftie);
    reg_write(base + cr1, reg_read(base + cr1) | (has_fifo ? 0 : cr1_rxneie) | gap_ie(id));
    return true;
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    irq_line_disable(uart_irq[id]);
    reg_write(uart_base[id] + cr1, 0);
    reg_write(uart_base[id] + cr3, 0);
    _port[id].cb = null;
    release_rings(id);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
    => _port[id].rx ? _port[id].rx.pop(cast(ubyte[])buffer) : 0;

// Blocks while the ring is full and the line drains it; a line that stops, as CTS can hold it, ends the write short.
ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    if (!_port[id].tx)
        return 0;
    size_t total = 0;
    auto give_up = getTime() + tx_stall_limit;
    while (total < data.length)
    {
        size_t n;
        {
            auto guard = irq_critical();
            n = _port[id].tx.write(data[total .. $]);
            tx_fill(id);
        }
        immutable now = getTime();
        if (n)
        {
            total += n;
            give_up = now + tx_stall_limit;
        }
        else if (now >= give_up)
            break;
    }
    return total;
}

UartRxTiming uart_hw_rx_timing(uint id)
    => _port[id].timing;

ptrdiff_t uart_hw_tx_pending(uint id)
{
    auto guard = irq_critical();
    return _port[id].tx ? _port[id].tx.pending : 0;
}

void uart_hw_poll(uint id) {}

bool uart_hw_check_errors(uint id)
{
    auto guard = irq_critical();
    bool errors = _port[id].errors;
    _port[id].errors = false;
    return errors;
}

ptrdiff_t uart_hw_rx_pending(uint id)
    => _port[id].rx ? _port[id].rx.pending : 0;

// Feeds the FIFO itself, so it drains with interrupts masked too; a peer holding CTS off cannot hold it forever.
ptrdiff_t uart_hw_flush(uint id)
{
    immutable base = uart_base[id];
    if (!(reg_read(base + cr1) & cr1_ue))
        return 0;
    immutable deadline = getTime() + 250.msecs;
    while (getTime() < deadline)
    {
        {
            auto guard = irq_critical();
            tx_fill(id);
            if (!_port[id].tx || _port[id].tx.empty)
                break;
        }
    }
    while (!(reg_read(base + sr) & st_tc) && getTime() < deadline)
    {}
    return 0;
}

// Blocking console output for early boot and fault context; queued output goes first. Each
// byte is its own critical section, so the ISR never shares the ring or TDR mid-step.
void uart0_hw_puts(const(char)[] s)
{
    import urt.driver.uart : console_uart;

    enum base = uart_base[console_uart];
    if (!(reg_read(base + cr1) & cr1_ue))
        return;
    size_t i = 0;
    uint spins = 0;
    while (i < s.length && spins < puts_stall_spins)
    {
        auto guard = irq_critical();
        if (reg_read(base + sr) & st_txe)
        {
            if (_port[console_uart].tx && !_port[console_uart].tx.empty)
                tx_fill(console_uart);
            else
                reg_write(base + tdr, s[i++]);
            spins = 0;
        }
        else
            ++spins;
    }
}


private:

version (STM32F4) enum legacy_usart = true;
else              enum legacy_usart = false;

// F4 has no receiver timeout and takes the one-character IDLE line as its gap; F7 and H7 time 3.5
// characters, save LPUART1, which has no timeout either.
static if (legacy_usart)
{
    enum uint sr = 0x00, rdr = 0x04, tdr = 0x04, brr = 0x08, cr1 = 0x0C, cr2 = 0x10, cr3 = 0x14;
    enum uint cr1_ue = 1 << 13;
}
else
{
    enum uint cr1 = 0x00, cr2 = 0x04, cr3 = 0x08, brr = 0x0C, rtor = 0x14, sr = 0x1C, icr = 0x20, rdr = 0x24, tdr = 0x28;
    enum uint cr1_ue = 1 << 0;
    enum uint cr1_rtoie = 1 << 26;
    enum uint cr2_rtoen = 1 << 23;
    enum uint cr3_dem = 1 << 14;
    enum uint cr3_dep = 1 << 15;
    enum uint st_rtof = 1 << 11;
}
enum uint cr1_idleie = 1 << 4;
enum uint st_idle = 1 << 4;

// The H7 U(S)ARTs and LPUART1 have 16-byte FIFOs: RX interrupts at a fill threshold, TX once half the
// FIFO is free.
// TODO: F4 and F7 have none and take an interrupt per byte; RX wants circular DMA with IDLE/RTO (TODO.md).
version (STM32H7)
{
    enum bool has_fifo = true;
    enum bool has_lpuart = true;
    enum uint lpuart = 8;
    enum uint lpuart_presc = 0x2C;
    import urt.driver.stm32 : pclk4_hz, rcc_apb4enr;
}
else
{
    enum bool has_fifo = false;
    enum bool has_lpuart = false;
}

static if (has_fifo)
{
    enum uint cr1_fifoen = 1 << 29;
    enum uint cr3_txftie = 1 << 23;
    enum uint cr3_rxftie = 1 << 28;
    enum uint tx_level_half = 2;

    static immutable ubyte[3] rx_level_bytes = [ 2, 4, 8 ];

    // the deepest RX threshold within the characters of the RX latency, and never past half the FIFO, which
    // leaves eight characters of ISR latency before an overrun
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
enum uint cr3_rtse   = 1 << 8;
enum uint cr3_ctse   = 1 << 9;

enum uint st_pe   = 1 << 0;
enum uint st_fe   = 1 << 1;
enum uint st_ne   = 1 << 2;
enum uint st_ore  = 1 << 3;
enum uint st_rxne = 1 << 5;
enum uint st_tc   = 1 << 6;
enum uint st_txe  = 1 << 7;
enum uint st_line = st_pe | st_fe | st_ne;

enum uint pa = 0, pb = 16, pc = 32, pd = 48, pe = 64, pf = 80;

static if (has_lpuart)
{
    static immutable ulong[9] uart_base = [
        0x4001_1000, 0x4000_4400, 0x4000_4800, 0x4000_4C00,
        0x4000_5000, 0x4001_1400, 0x4000_7800, 0x4000_7C00, 0x5800_0C00,
    ];
    static immutable ubyte[9] clock_reg = [rcc_apb2enr, rcc_apb1enr, rcc_apb1enr, rcc_apb1enr, rcc_apb1enr, rcc_apb2enr, rcc_apb1enr, rcc_apb1enr, rcc_apb4enr];
    static immutable ubyte[9] clock_bit = [4, 17, 18, 19, 20, 5, 30, 31, 3];
    static immutable ubyte[9] uart_irq = [37, 38, 39, 52, 53, 71, 82, 83, 142];
    static immutable ubyte[9] default_tx = [pa + 9, pa + 2, pb + 10, pa + 0, pc + 12, pc + 6, pf + 7, pe + 1, pa + 9];
    static immutable ubyte[9] default_rx = [pa + 10, pa + 3, pb + 11, pa + 1, pd + 2, pc + 7, pf + 6, pe + 0, pa + 10];
}
else
{
    static immutable ulong[8] uart_base = [
        0x4001_1000, 0x4000_4400, 0x4000_4800, 0x4000_4C00,
        0x4000_5000, 0x4001_1400, 0x4000_7800, 0x4000_7C00,
    ];
    static immutable ubyte[8] clock_reg = [rcc_apb2enr, rcc_apb1enr, rcc_apb1enr, rcc_apb1enr, rcc_apb1enr, rcc_apb2enr, rcc_apb1enr, rcc_apb1enr];
    static immutable ubyte[8] clock_bit = [4, 17, 18, 19, 20, 5, 30, 31];
    static immutable ubyte[8] uart_irq = [37, 38, 39, 52, 53, 71, 82, 83];
    static immutable ubyte[8] default_tx = [pa + 9, pa + 2, pb + 10, pa + 0, pc + 12, pc + 6, pf + 7, pe + 1];
    static immutable ubyte[8] default_rx = [pa + 10, pa + 3, pb + 11, pa + 1, pd + 2, pc + 7, pf + 6, pe + 0];
}

enum uint rx_ring_size = 512;
enum tx_stall_limit = 50.msecs;
enum uint puts_stall_spins = 1_000_000;     // tens of milliseconds of register reads: no clock on a fault path

alias RxRing = SPSCRing!(ubyte, rx_ring_size);
alias TxRing = RingBuffer!1024;

struct Port
{
    RxRing* rx;
    TxRing* tx;
    UartRxCallback cb;
    UartRxTiming timing;
    static if (!has_fifo)
    {
        ushort rx_chars;
        ushort count;
    }
    bool errors;
}

__gshared Port[num_uarts] _port;

uint fck(uint id) pure
    => id == 0 || id == 5 ? pclk2_hz : pclk1_hz;

// F4's UART4 and UART5 have no RTS/CTS.
bool has_flow_control(uint id) pure
    => !legacy_usart || (id != 3 && id != 4);

bool has_receiver_timeout(uint id) pure
{
    static if (has_lpuart)
        return id != lpuart;
    else
        return !legacy_usart;
}

uint gap_ie(uint id) pure
{
    static if (legacy_usart)
        return cr1_idleie;
    else
        return has_receiver_timeout(id) ? cr1_rtoie : cr1_idleie;
}

uint gap_flag(uint id) pure
{
    static if (legacy_usart)
        return st_idle;
    else
        return has_receiver_timeout(id) ? st_rtof : st_idle;
}

// DE assertion and deassertion in sample times, sixteenths of a bit, which DEAT and DEDT hold up to 31.
// DEAT and DEDT count sixteenths of a bit on a USART, and BRR[20:11] cycles of the prescaled clock on LPUART
uint de_time(uint us, ulong unit_hz) pure
{
    immutable ulong t = us * unit_hz / 1_000_000;
    return t < 31 ? cast(uint)t : 31;
}

static if (has_lpuart)
{
    static immutable ushort[12] lpuart_prescalers = [ 1, 2, 4, 6, 8, 10, 12, 16, 32, 64, 128, 256 ];

    // BRR is 256 * fck / baud in 0x300 to 0xFFFFF; a slow baud takes the smallest prescaler that fits
    bool lpuart_divider(uint clock, uint baud, out uint presc, out uint div) pure
    {
        foreach (i, p; lpuart_prescalers)
        {
            immutable ulong d = (ulong(clock / p) * 256 + baud / 2) / baud;
            if (d > 0xF_FFFF)
                continue;
            if (d < 0x300)
                return false;
            presc = cast(uint)i;
            div = cast(uint)d;
            return true;
        }
        return false;
    }
}

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
    static immutable ubyte[9] port_af = [7, 7, 7, 8, 8, 7, 7, 8, 3];
    static immutable PinAf[14] pin_af_exceptions = [
        PinAf(0, pb + 14, 4), PinAf(0, pb + 15, 4),
        PinAf(3, pa + 11, 6), PinAf(3, pa + 12, 6),
        PinAf(4, pb + 5, 14), PinAf(4, pb + 6, 14), PinAf(4, pb + 12, 14), PinAf(4, pb + 13, 14),
        PinAf(6, pa + 8, 11), PinAf(6, pa + 15, 11), PinAf(6, pb + 3, 11), PinAf(6, pb + 4, 11),
        PinAf(8, pb + 6, 8), PinAf(8, pb + 7, 8),
    ];
}
else
{
    static immutable ubyte[8] port_af = [7, 7, 7, 8, 8, 8, 8, 8];
    static immutable PinAf[0] pin_af_exceptions;
}

void release_rings(uint id)
{
    RxRing* rx;
    TxRing* tx;
    {
        auto guard = irq_critical();
        rx = _port[id].rx;
        tx = _port[id].tx;
        _port[id].rx = null;
        _port[id].tx = null;
    }
    if (rx)
        free(rx);
    if (tx)
        free(tx);
}

// TX refills on a free byte, or with a FIFO on half the FIFO free.
static if (has_fifo)
{
    enum uint tx_ie_reg = cr3, tx_ie = cr3_txftie;
}
else
{
    enum uint tx_ie_reg = cr1, tx_ie = cr1_txeie;
}

// Caller holds interrupts off, or runs in the ISR.
void tx_fill(uint id)
{
    immutable base = uart_base[id];
    TxRing* ring = _port[id].tx;
    if (!ring)
        return;
    ubyte[1] b = void;
    while (!ring.empty && (reg_read(base + sr) & st_txe))
    {
        ring.read(b[]);
        reg_write(base + tdr, b[0]);
    }
    uint ie = reg_read(base + tx_ie_reg);
    ie = ring.empty ? ie & ~tx_ie : ie | tx_ie;
    reg_write(base + tx_ie_reg, ie);
}

void uart_isr(uint irq)
{
    uint id = 0;
    while (uart_irq[id] != irq)
        ++id;
    immutable base = uart_base[id];
    Port* p = &_port[id];

    immutable uint status = reg_read(base + sr);
    immutable uint gap = gap_flag(id);
    uint pushed;
    static if (legacy_usart)
    {
        // SR then DR clears RXNE, the line errors, ORE and IDLE; SR is read again just before DR, so a
        // byte that completed since the first read is the one DR returns and is kept.
        if (status & (st_rxne | st_line | st_ore | gap))
        {
            immutable uint now = reg_read(base + sr);
            ubyte b = cast(ubyte)reg_read(base + rdr);
            if (now & (st_line | st_ore))
                p.errors = true;
            if ((now & st_rxne) && !(now & st_line))
            {
                if (p.rx && p.rx.push((&b)[0 .. 1]))
                    ++pushed;
                else
                    p.errors = true;
            }
        }
    }
    else
    {
        // In FIFO mode PE, FE and NE describe the byte at the head of RDR, so each is read before its byte.
        while (true)
        {
            immutable uint now = reg_read(base + sr);
            if (!(now & st_rxne))
                break;
            if (now & st_line)
            {
                p.errors = true;
                reg_write(base + icr, now & st_line);
            }
            ubyte b = cast(ubyte)reg_read(base + rdr);
            if (!(now & st_line))
            {
                if (p.rx && p.rx.push((&b)[0 .. 1]))
                    ++pushed;
                else
                    p.errors = true;
            }
        }
        if (status & (st_ore | gap))
            reg_write(base + icr, status & (st_ore | gap));
        if (status & st_ore)
            p.errors = true;
    }

    bool deliver;
    static if (has_fifo)
        deliver = pushed != 0 || (status & gap) != 0;
    else
    {
        p.count += pushed;
        deliver = p.count >= p.rx_chars || ((status & gap) && p.count != 0);
    }
    if (deliver || p.errors)
    {
        static if (!has_fifo)
            p.count = 0;
        if (p.cb)
            p.cb(Uart(cast(ubyte)id), p.rx ? p.rx.pending : 0, UartCallbackContext.interrupt);
    }
    if (reg_read(base + tx_ie_reg) & tx_ie)
        tx_fill(id);
}


unittest
{
    assert(de_time(0, 16 * 115_200) == 0 && de_time(1000, 16 * 115_200) == 31, "DE times clamp at 31 units");
    assert(de_time(10, 16 * 115_200) == 18, "10 us at 115200 is 18 sixteenths of a bit");
    static if (has_fifo)
    {
        assert(rx_level(4) == 1 && rx_level(35) == 2 && rx_level(0) == 0, "the RX threshold caps at half the FIFO");
    }
    static if (has_lpuart)
    {
        uint presc, div;
        assert(lpuart_divider(100_000_000, 115_200, presc, div) && presc == 0 && div == 222_222, "LPUART at 115200 needs no prescaler");
        assert(lpuart_divider(100_000_000, 9600, presc, div) && presc == 2, "9600 needs a prescaler of 4");
        lpuart_divider(100_000_000, 115_200, presc, div);
        assert(de_time(10, 100_000_000 / (div >> 11)) == 9, "an LPUART DE unit at 115200 is 108 cycles, so 10 us is 9 of them");
    }
}
