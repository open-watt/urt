// F4 has the SR/DR register layout, F7 and H7 the ISR/RDR/TDR one; status bit positions agree.
// Port n is the (n+1)th U(S)ART: 0 = USART1, 5 = USART6, 6 = UART7; on H7, port 8 is LPUART1.
module urt.driver.stm32.uart;

import urt.driver.gpio : Pull;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.stm32 : clock_enable, pclk1_hz, pclk2_hz, rcc_apb1enr, rcc_apb2enr, reg_read, reg_write;
import urt.driver.stm32.gpio : gpio_set_function;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartError, UartRxCallback,
    UartRxTiming, UartTxCallback, uart_chars_us, uart_rate_close, uart_rx_chars, uart_rx_gap_bits;
import urt.driver.uart_core : UartPorts, puts_stall_spins;
import urt.mem.page : Page;

nothrow @nogc:

version (STM32F4)      enum uint num_uarts = 6;
else version (STM32H7) enum uint num_uarts = 9;
else                   enum uint num_uarts = 8;

enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 1 << 8;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd;
enum uint uart_stop_bits = 0xF;
enum uint uart_flow_controls = 1 << FlowControl.none | 1 << FlowControl.hardware;
enum bool uart_has_rs485 = true;
enum bool uart_has_pin_select = true;

// Refuses what the port cannot do, before it touches the hardware: a pin that does not carry the signal asked of
// it, a rate its divider cannot hold.
bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable uint tx = cfg.tx_gpio != ubyte.max ? cfg.tx_gpio : default_tx[id];
    immutable uint rx = cfg.rx_gpio != ubyte.max ? cfg.rx_gpio : default_rx[id];
    immutable bool flow = cfg.flow_control == FlowControl.hardware;
    immutable ubyte tx_af = route_af(id, Signal.tx, tx);
    immutable ubyte rx_af = route_af(id, Signal.rx, rx);
    immutable ubyte rts_af = flow ? route_af(id, Signal.rts, cfg.rts_gpio) : 0;
    immutable ubyte cts_af = flow ? route_af(id, Signal.cts, cfg.cts_gpio) : 0;
    immutable ubyte de_af = cfg.rs485.enabled ? route_af(id, Signal.rts, cfg.rs485.de_gpio) : 0;
    if (tx_af == ubyte.max || rx_af == ubyte.max || rts_af == ubyte.max || cts_af == ubyte.max || de_af == ubyte.max)
        return false;

    uint presc, div;
    ulong de_unit_hz = 16 * ulong(cfg.baud_rate);
    static if (has_lpuart)
    {
        if (id == lpuart)
        {
            if (!lpuart_divider(pclk4_hz, cfg.baud_rate, presc, div))
                return false;
            de_unit_hz = div >> 11 ? pclk4_hz / lpuart_prescalers[presc] / (div >> 11) : 0;
        }
        else if (!usart_divider(fck(id), cfg.baud_rate, div))
            return false;
    }
    else if (!usart_divider(fck(id), cfg.baud_rate, div))
        return false;

    if (cfg.rs485.enabled)
    {
        static if (legacy_usart)
            return false;
        else if (cfg.rs485.turnaround_us || !de_unit_hz)
            return false;
    }

    immutable base = uart_base[id];
    clock_enable(clock_reg[id], clock_bit[id]);
    gpio_set_function(tx, tx_af);
    gpio_set_function(rx, rx_af, Pull.up);
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
    if (flow)
    {
        gpio_set_function(cfg.rts_gpio, rts_af);
        gpio_set_function(cfg.cts_gpio, cts_af, Pull.up);
        c3 |= cr3_rtse | cr3_ctse;
    }

    static if (has_lpuart)
    {
        if (id == lpuart)
            reg_write(base + lpuart_presc, presc);
    }
    reg_write(base + brr, div);

    static if (!legacy_usart)
    {
        if (cfg.rs485.enabled)
        {
            gpio_set_function(cfg.rs485.de_gpio, de_af);
            c3 |= cr3_dem | (cfg.rs485.de_active_high ? 0 : cr3_dep);
            c1 |= de_time(cfg.rs485.de_assert_us, de_unit_hz) << 21 | de_time(cfg.rs485.de_deassert_us, de_unit_hz) << 16;
        }
        if (has_receiver_timeout(id))
        {
            reg_write(base + rtor, uart_rx_gap_bits(cfg));
            c2 |= cr2_rtoen;
        }
    }
    static if (has_fifo)
    {
        c1 |= cr1_fifoen;
        c3 |= rx_level(uart_rx_chars(cfg)) << 25 | tx_level_half << 29;
    }

    reg_write(base + cr2, c2);
    reg_write(base + cr3, c3);
    reg_write(base + cr1, c1 & ~cr1_ue);        // FIFOEN and DEAT/DEDT take only while the USART is disabled
    reg_write(base + cr1, c1);
    return true;
}

bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb, UartTxCallback tx_cb)
{
    if (!_ports.acquire(id, cfg))
        return false;
    if (!uart_hw_init(id, cfg))
    {
        _ports.release(id);
        return false;
    }
    static if (!has_fifo)
        _rx_count[id] = 0;
    _ports.start(id, rx_cb, tx_cb, rx_timing(id, cfg));
    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    immutable base = uart_base[id];
    immutable uint c1 = reg_read(base + cr1);
    static if (has_fifo)
        enum uint rx_ie3 = cr3_rxftie, rx_ie1 = 0;
    else
        enum uint rx_ie3 = 0, rx_ie1 = cr1_rxneie;
    reg_write(base + cr3, reg_read(base + cr3) | cr3_eie | rx_ie3);
    reg_write(base + cr1, c1 | rx_ie1 | (c1 & cr1_pce ? cr1_peie : 0) | gap_ie(id));
    return true;
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    irq_line_disable(uart_irq[id]);
    reg_write(uart_base[id] + cr1, 0);
    reg_write(uart_base[id] + cr3, 0);
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

// The receiver timeout takes a new value while the USART runs; the H7 FIFO trigger only with it disabled, so its
// latency waits for the next open.
UartRxTiming uart_hw_set_rx_timing(uint id, ref const UartConfig cfg)
{
    auto guard = irq_critical();
    static if (!legacy_usart)
    {
        if (has_receiver_timeout(id))
            reg_write(uart_base[id] + rtor, uart_rx_gap_bits(cfg));
    }
    immutable UartRxTiming timing = rx_timing(id, cfg);
    static if (has_fifo)
        _ports.retime(id, UartRxTiming(_ports.timing(id).latency_us, timing.gap));
    else
        _ports.retime(id, timing);
    return _ports.timing(id);
}

size_t uart_hw_tx_pending(uint id)
    => _ports.tx_pending(id);

UartError uart_hw_check_errors(uint id)
    => _ports.take_errors(id);

void uart_hw_flush(uint id)
{
    if (reg_read(uart_base[id] + cr1) & cr1_ue)
        _ports.drain(id);
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
            if (_ports.tx_queued(console_uart))
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
enum uint cr1_peie   = 1 << 8;
enum uint cr1_ps     = 1 << 9;
enum uint cr1_pce    = 1 << 10;
enum uint cr1_m      = 1 << 12;
enum uint cr3_eie    = 1 << 0;
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

static immutable UartError[16] sr_errors = () {
    UartError[16] t;
    foreach (i; 0 .. 16)
        t[i] = cast(UartError)((i & st_pe ? UartError.parity : 0) | (i & st_fe ? UartError.framing : 0) | (i & st_ne ? UartError.noise : 0) | (i & st_ore ? UartError.overrun : 0));
    return t;
}();

enum uint pa = 0, pb = 16, pc = 32, pd = 48, pe = 64, pf = 80, pg = 96, ph = 112, pi = 128, pj = 144, pk = 160;

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

__gshared UartPorts!(num_uarts, 0, tx_idle, tx_fill) _ports;
static if (!has_fifo)
    __gshared ushort[num_uarts] _rx_chars, _rx_count;

uint fck(uint id) pure
    => id == 0 || id == 5 ? pclk2_hz : pclk1_hz;


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

// The RX trigger: the FIFO level, or without a FIFO the character count the ISR delivers at.
UartRxTiming rx_timing(uint id, ref const UartConfig cfg)
{
    immutable uint chars = uart_rx_chars(cfg);
    immutable ubyte gap = has_receiver_timeout(id) ? cfg.rx_gap : 10;
    static if (has_fifo)
        return UartRxTiming(uart_chars_us(cfg, rx_level_bytes[rx_level(chars)]), gap);
    else
    {
        _rx_chars[id] = cast(ushort)(chars < ushort.max ? chars : ushort.max);
        return UartRxTiming(uart_chars_us(cfg, _rx_chars[id]), gap);
    }
}

// DE assertion and deassertion in sample times, sixteenths of a bit, which DEAT and DEDT hold up to 31.
// DEAT and DEDT count sixteenths of a bit on a USART, and BRR[20:11] cycles of the prescaled clock on LPUART
uint de_time(uint us, ulong unit_hz) pure
{
    immutable ulong t = us * unit_hz / 1_000_000;
    return t < 31 ? cast(uint)t : 31;
}

// Oversampling by 16 takes a BRR from 16 to 0xFFFF.
bool usart_divider(uint clock, uint baud, out uint div) pure
{
    immutable ulong d = (ulong(clock) + baud / 2) / baud;
    if (d < 16 || d > 0xFFFF || !uart_rate_close(baud, clock, d))
        return false;
    div = cast(uint)d;
    return true;
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

enum Signal : ubyte
{
    tx,
    rx,
    rts,        // DE too: RS-485 drives it on the RTS pin
    cts,
}

struct UartRoute
{
    ubyte pin, port;
    Signal signal;
    ubyte af;
}

// The alternate function that carries a port's signal on a pin, or ubyte.max where that pin cannot.
ubyte route_af(uint id, Signal signal, uint pin) pure
{
    foreach (ref r; uart_routes)
    {
        if (r.port == id && r.signal == signal && r.pin == pin)
            return r.af;
    }
    return ubyte.max;
}

static assert(() {
    foreach (id; 0 .. num_uarts)
    {
        if (route_af(id, Signal.tx, default_tx[id]) == ubyte.max || route_af(id, Signal.rx, default_rx[id]) == ubyte.max)
            return false;
    }
    return true;
}(), "every port's default pins carry its TX and RX");

// Generated by tools/stm32_uart_routes.py from ST's STM32_open_pin_data, the CubeMX pin database.
version (STM32H7)
{
    static immutable UartRoute[83] uart_routes = [
        UartRoute(pa + 9, 0, Signal.tx, 7), UartRoute(pb + 6, 0, Signal.tx, 7), UartRoute(pb + 14, 0, Signal.tx, 4),
        UartRoute(pa + 10, 0, Signal.rx, 7), UartRoute(pb + 7, 0, Signal.rx, 7),
        UartRoute(pb + 15, 0, Signal.rx, 4),
        UartRoute(pa + 12, 0, Signal.rts, 7),
        UartRoute(pa + 11, 0, Signal.cts, 7),
        UartRoute(pa + 2, 1, Signal.tx, 7), UartRoute(pd + 5, 1, Signal.tx, 7),
        UartRoute(pa + 3, 1, Signal.rx, 7), UartRoute(pd + 6, 1, Signal.rx, 7),
        UartRoute(pa + 1, 1, Signal.rts, 7), UartRoute(pd + 4, 1, Signal.rts, 7),
        UartRoute(pa, 1, Signal.cts, 7), UartRoute(pd + 3, 1, Signal.cts, 7),
        UartRoute(pb + 10, 2, Signal.tx, 7), UartRoute(pc + 10, 2, Signal.tx, 7),
        UartRoute(pd + 8, 2, Signal.tx, 7),
        UartRoute(pb + 11, 2, Signal.rx, 7), UartRoute(pc + 11, 2, Signal.rx, 7),
        UartRoute(pd + 9, 2, Signal.rx, 7),
        UartRoute(pb + 14, 2, Signal.rts, 7), UartRoute(pd + 12, 2, Signal.rts, 7),
        UartRoute(pb + 13, 2, Signal.cts, 7), UartRoute(pd + 11, 2, Signal.cts, 7),
        UartRoute(pa, 3, Signal.tx, 8), UartRoute(pa + 12, 3, Signal.tx, 6), UartRoute(pb + 9, 3, Signal.tx, 8),
        UartRoute(pc + 10, 3, Signal.tx, 8), UartRoute(pd + 1, 3, Signal.tx, 8),
        UartRoute(ph + 13, 3, Signal.tx, 8),
        UartRoute(pa + 1, 3, Signal.rx, 8), UartRoute(pa + 11, 3, Signal.rx, 6), UartRoute(pb + 8, 3, Signal.rx, 8),
        UartRoute(pc + 11, 3, Signal.rx, 8), UartRoute(pd, 3, Signal.rx, 8), UartRoute(ph + 14, 3, Signal.rx, 8),
        UartRoute(pi + 9, 3, Signal.rx, 8),
        UartRoute(pa + 15, 3, Signal.rts, 8), UartRoute(pb + 14, 3, Signal.rts, 8),
        UartRoute(pb, 3, Signal.cts, 8), UartRoute(pb + 15, 3, Signal.cts, 8),
        UartRoute(pb + 6, 4, Signal.tx, 14), UartRoute(pb + 13, 4, Signal.tx, 14),
        UartRoute(pc + 12, 4, Signal.tx, 8),
        UartRoute(pb + 5, 4, Signal.rx, 14), UartRoute(pb + 12, 4, Signal.rx, 14),
        UartRoute(pd + 2, 4, Signal.rx, 8),
        UartRoute(pc + 8, 4, Signal.rts, 8),
        UartRoute(pc + 9, 4, Signal.cts, 8),
        UartRoute(pc + 6, 5, Signal.tx, 7), UartRoute(pg + 14, 5, Signal.tx, 7),
        UartRoute(pc + 7, 5, Signal.rx, 7), UartRoute(pg + 9, 5, Signal.rx, 7),
        UartRoute(pg + 8, 5, Signal.rts, 7), UartRoute(pg + 12, 5, Signal.rts, 7),
        UartRoute(pg + 13, 5, Signal.cts, 7), UartRoute(pg + 15, 5, Signal.cts, 7),
        UartRoute(pa + 15, 6, Signal.tx, 11), UartRoute(pb + 4, 6, Signal.tx, 11),
        UartRoute(pe + 8, 6, Signal.tx, 7), UartRoute(pf + 7, 6, Signal.tx, 7),
        UartRoute(pa + 8, 6, Signal.rx, 11), UartRoute(pb + 3, 6, Signal.rx, 11),
        UartRoute(pe + 7, 6, Signal.rx, 7), UartRoute(pf + 6, 6, Signal.rx, 7),
        UartRoute(pe + 9, 6, Signal.rts, 7), UartRoute(pf + 8, 6, Signal.rts, 7),
        UartRoute(pe + 10, 6, Signal.cts, 7), UartRoute(pf + 9, 6, Signal.cts, 7),
        UartRoute(pe + 1, 7, Signal.tx, 8), UartRoute(pj + 8, 7, Signal.tx, 8),
        UartRoute(pe, 7, Signal.rx, 8), UartRoute(pj + 9, 7, Signal.rx, 8),
        UartRoute(pd + 15, 7, Signal.rts, 8),
        UartRoute(pd + 14, 7, Signal.cts, 8),
        UartRoute(pa + 9, 8, Signal.tx, 3), UartRoute(pb + 6, 8, Signal.tx, 8),
        UartRoute(pa + 10, 8, Signal.rx, 3), UartRoute(pb + 7, 8, Signal.rx, 8),
        UartRoute(pa + 12, 8, Signal.rts, 3),
        UartRoute(pa + 11, 8, Signal.cts, 3),
    ];
}
else version (STM32F7)
{
    static immutable UartRoute[54] uart_routes = [
        UartRoute(pa + 9, 0, Signal.tx, 7), UartRoute(pb + 6, 0, Signal.tx, 7),
        UartRoute(pa + 10, 0, Signal.rx, 7), UartRoute(pb + 7, 0, Signal.rx, 7),
        UartRoute(pa + 12, 0, Signal.rts, 7),
        UartRoute(pa + 11, 0, Signal.cts, 7),
        UartRoute(pa + 2, 1, Signal.tx, 7), UartRoute(pd + 5, 1, Signal.tx, 7),
        UartRoute(pa + 3, 1, Signal.rx, 7), UartRoute(pd + 6, 1, Signal.rx, 7),
        UartRoute(pa + 1, 1, Signal.rts, 7), UartRoute(pd + 4, 1, Signal.rts, 7),
        UartRoute(pa, 1, Signal.cts, 7), UartRoute(pd + 3, 1, Signal.cts, 7),
        UartRoute(pb + 10, 2, Signal.tx, 7), UartRoute(pc + 10, 2, Signal.tx, 7),
        UartRoute(pd + 8, 2, Signal.tx, 7),
        UartRoute(pb + 11, 2, Signal.rx, 7), UartRoute(pc + 11, 2, Signal.rx, 7),
        UartRoute(pd + 9, 2, Signal.rx, 7),
        UartRoute(pb + 14, 2, Signal.rts, 7), UartRoute(pd + 12, 2, Signal.rts, 7),
        UartRoute(pb + 13, 2, Signal.cts, 7), UartRoute(pd + 11, 2, Signal.cts, 7),
        UartRoute(pa, 3, Signal.tx, 8), UartRoute(pc + 10, 3, Signal.tx, 8),
        UartRoute(pa + 1, 3, Signal.rx, 8), UartRoute(pc + 11, 3, Signal.rx, 8),
        UartRoute(pa + 15, 3, Signal.rts, 8),
        UartRoute(pb, 3, Signal.cts, 8),
        UartRoute(pc + 12, 4, Signal.tx, 8),
        UartRoute(pd + 2, 4, Signal.rx, 8),
        UartRoute(pc + 8, 4, Signal.rts, 7),
        UartRoute(pc + 9, 4, Signal.cts, 7),
        UartRoute(pc + 6, 5, Signal.tx, 8), UartRoute(pg + 14, 5, Signal.tx, 8),
        UartRoute(pc + 7, 5, Signal.rx, 8), UartRoute(pg + 9, 5, Signal.rx, 8),
        UartRoute(pg + 8, 5, Signal.rts, 8), UartRoute(pg + 12, 5, Signal.rts, 8),
        UartRoute(pg + 13, 5, Signal.cts, 8), UartRoute(pg + 15, 5, Signal.cts, 8),
        UartRoute(pe + 8, 6, Signal.tx, 8), UartRoute(pf + 7, 6, Signal.tx, 8),
        UartRoute(pe + 7, 6, Signal.rx, 8), UartRoute(pf + 6, 6, Signal.rx, 8),
        UartRoute(pe + 9, 6, Signal.rts, 8), UartRoute(pf + 8, 6, Signal.rts, 8),
        UartRoute(pe + 10, 6, Signal.cts, 8), UartRoute(pf + 9, 6, Signal.cts, 8),
        UartRoute(pe + 1, 7, Signal.tx, 8),
        UartRoute(pe, 7, Signal.rx, 8),
        UartRoute(pd + 15, 7, Signal.rts, 8),
        UartRoute(pd + 14, 7, Signal.cts, 8),
    ];
}
else
{
    static immutable UartRoute[38] uart_routes = [
        UartRoute(pa + 9, 0, Signal.tx, 7), UartRoute(pb + 6, 0, Signal.tx, 7),
        UartRoute(pa + 10, 0, Signal.rx, 7), UartRoute(pb + 7, 0, Signal.rx, 7),
        UartRoute(pa + 12, 0, Signal.rts, 7),
        UartRoute(pa + 11, 0, Signal.cts, 7),
        UartRoute(pa + 2, 1, Signal.tx, 7), UartRoute(pd + 5, 1, Signal.tx, 7),
        UartRoute(pa + 3, 1, Signal.rx, 7), UartRoute(pd + 6, 1, Signal.rx, 7),
        UartRoute(pa + 1, 1, Signal.rts, 7), UartRoute(pd + 4, 1, Signal.rts, 7),
        UartRoute(pa, 1, Signal.cts, 7), UartRoute(pd + 3, 1, Signal.cts, 7),
        UartRoute(pb + 10, 2, Signal.tx, 7), UartRoute(pc + 10, 2, Signal.tx, 7),
        UartRoute(pd + 8, 2, Signal.tx, 7),
        UartRoute(pb + 11, 2, Signal.rx, 7), UartRoute(pc + 11, 2, Signal.rx, 7),
        UartRoute(pd + 9, 2, Signal.rx, 7),
        UartRoute(pb + 14, 2, Signal.rts, 7), UartRoute(pd + 12, 2, Signal.rts, 7),
        UartRoute(pb + 13, 2, Signal.cts, 7), UartRoute(pd + 11, 2, Signal.cts, 7),
        UartRoute(pa, 3, Signal.tx, 8), UartRoute(pc + 10, 3, Signal.tx, 8),
        UartRoute(pa + 1, 3, Signal.rx, 8), UartRoute(pc + 11, 3, Signal.rx, 8),
        UartRoute(pc + 12, 4, Signal.tx, 8),
        UartRoute(pd + 2, 4, Signal.rx, 8),
        UartRoute(pc + 6, 5, Signal.tx, 8), UartRoute(pg + 14, 5, Signal.tx, 8),
        UartRoute(pc + 7, 5, Signal.rx, 8), UartRoute(pg + 9, 5, Signal.rx, 8),
        UartRoute(pg + 8, 5, Signal.rts, 8), UartRoute(pg + 12, 5, Signal.rts, 8),
        UartRoute(pg + 13, 5, Signal.cts, 8), UartRoute(pg + 15, 5, Signal.cts, 8),
    ];
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
    while (reg_read(base + sr) & st_txe)
    {
        const(ubyte)[] bytes = _ports.tx_bytes(id);
        if (!bytes.length)
            break;
        size_t n;
        while (n < bytes.length && (reg_read(base + sr) & st_txe))
            reg_write(base + tdr, bytes[n++]);
        _ports.tx_advance(id, n);
    }
    uint ie = reg_read(base + tx_ie_reg);
    ie = _ports.tx_queued(id) ? ie | tx_ie : ie & ~tx_ie;
    reg_write(base + tx_ie_reg, ie);
}

bool tx_idle(uint id)
    => (reg_read(uart_base[id] + sr) & st_tc) != 0;

void uart_isr(uint irq)
{
    uint id = 0;
    while (uart_irq[id] != irq)
        ++id;
    immutable base = uart_base[id];

    immutable uint status = reg_read(base + sr);
    immutable uint gap = gap_flag(id);
    uint read;
    uint fault;
    static if (legacy_usart)
    {
        // SR then DR clears RXNE, the line errors, ORE and IDLE; SR is read again just before DR, so a
        // byte that completed since the first read is the one DR returns and is kept.
        if (status & (st_rxne | st_line | st_ore | gap))
        {
            immutable uint now = reg_read(base + sr);
            immutable ubyte b = cast(ubyte)reg_read(base + rdr);
            fault = now & (st_line | st_ore);
            if ((now & st_rxne) && !(now & st_line))
            {
                _ports.receive(id, b);
                ++read;
            }
        }
    }
    else
    {
        // In FIFO mode PE, FE and NE describe the byte at the head of RDR, so each is read before its byte.
        while (true)
        {
            immutable uint now = reg_read(base + sr);
            if (now & st_line)
            {
                fault |= now & st_line;
                reg_write(base + icr, now & st_line);
            }
            if (!(now & st_rxne))
                break;
            immutable ubyte b = cast(ubyte)reg_read(base + rdr);
            if (!(now & st_line))
            {
                _ports.receive(id, b);
                ++read;
            }
        }
        if (status & (st_ore | gap))
            reg_write(base + icr, status & (st_ore | gap));
        fault |= status & st_ore;
    }
    if (fault)
        _ports.error(id, sr_errors[fault]);
    immutable bool ended = (status & gap) && _ports.gap(id);

    bool deliver;
    static if (has_fifo)
        deliver = read != 0 || ended;
    else
    {
        _rx_count[id] += read;
        deliver = _rx_count[id] >= _rx_chars[id] || ended;
    }
    if (deliver || fault)
    {
        static if (!has_fifo)
            _rx_count[id] = 0;
        _ports.notify(id);
    }
    if (reg_read(base + tx_ie_reg) & tx_ie)
        tx_fill(id);
}


unittest
{
    assert(de_time(0, 16 * 115_200) == 0 && de_time(1000, 16 * 115_200) == 31, "DE times clamp at 31 units");
    assert(de_time(10, 16 * 115_200) == 18, "10 us at 115200 is 18 sixteenths of a bit");
    uint div;
    assert(usart_divider(100_000_000, 115_200, div) && div == 868, "115200 from 100 MHz");
    assert(!usart_divider(100_000_000, 1200, div) && !usart_divider(100_000_000, 7_000_000, div), "past BRR's range either way");
    static if (has_fifo)
    {
        assert(rx_level(4) == 1 && rx_level(35) == 2 && rx_level(0) == 0, "the RX threshold caps at half the FIFO");
    }
    static if (has_lpuart)
    {
        uint presc;
        assert(lpuart_divider(100_000_000, 115_200, presc, div) && presc == 0 && div == 222_222, "LPUART at 115200 needs no prescaler");
        assert(lpuart_divider(100_000_000, 9600, presc, div) && presc == 2, "9600 needs a prescaler of 4");
        lpuart_divider(100_000_000, 115_200, presc, div);
        assert(de_time(10, 100_000_000 / (div >> 11)) == 9, "an LPUART DE unit at 115200 is 108 cycles, so 10 us is 9 of them");
    }
}
