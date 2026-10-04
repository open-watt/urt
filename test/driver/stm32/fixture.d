// STM32 register model: USART2 (the F4 SR/DR layout, or the F7/H7 ISR/ICR one with the H7's FIFOs), the
// EXTI block and the GPIO ports; everything else is plain storage.
module fixture;

import model.cpu : deliver;
import model.line : Line, Registers;
import urt.driver.uart : UartError;

nothrow @nogc:

enum ubyte uart_port = 1;
enum ubyte other_port = 2;
enum uint uart_line = 38;

version (STM32F4)
    enum legacy = true;
else
    enum legacy = false;
version (STM32H7)
    enum uint depth = 16;
else
    enum uint depth = 1;

// EXTI3 takes one pin from all its ports, so pins 3 and 19 (PA3, PB3) contend for it; pin 4 is its own line.
static immutable uint[3] event_pins = [ 3, 19, 4 ];
enum bool event_pins_share_line = true;
enum uint output_pin = 8;
// EXTI5 and EXTI6 share one vector, so their edges are taken in one batch.
static immutable uint[2] batch_pins = [ 5, 6 ];
// USART2: PA0 carries its CTS, not its TX; PD5 and PD6 are its other TX and RX, on AF7.
enum uint wrong_tx_pin = 0;
enum uint alt_tx_pin = 48 + 5, alt_rx_pin = 48 + 6, alt_af = 7;
enum UartError line_errors = cast(UartError)(UartError.parity | UartError.framing | UartError.noise);
enum bool shows_tx_busy = true;
enum bool keeps_bad_bytes = false;
enum bool has_links = true;

void reset()
{
    import model.cpu : asserted, line_on, irq_on, storms;
    _regs.clear();
    _line = typeof(_line).init;
    _cr1 = _cr2 = _cr3 = 0;
    _flags = 0;
    _sr_read = false;
    _exti_pr = 0;
    asserted = &is_asserted;
    version (STM32H7)
        _regs.set(gpio_base(0), uint.max);
    line_on[] = false;
    irq_on = true;
    storms = 0;
}

void rx(ubyte b, UartError err = UartError.none)
{
    if (!(_cr1 & re))
        return;
    if (!_line.receive(b, error_bits(err)))
        _flags |= ore;
    else if (_line.rx_count == 1)
        _flags |= _line.head_err;
    _since_idle = true;
    deliver();
}

void rx_overrun()
{
    _flags |= ore;
    deliver();
}

void line_idle()
{
    if (_since_idle)
        _flags |= !legacy && (_cr2 & rtoen) ? rtof : idle;
    _since_idle = false;
    deliver();
}

void tx_hold(bool hold) { _line.held = hold; }
void shift_busy(bool busy) { _line.busy = busy; }
const(ubyte)[] wire() => _line.sent_bytes;
void wire_clear() { _line.clear_wire(); }
uint tx_disabled_while_busy() => _line.disabled_while_busy;
uint tx_fifo_overflows() => _line.tx_overflows;

uint programmed_baud()
{
    version (STM32H7)
        enum ulong fck = 100_000_000;
    else
        enum ulong fck = 42_000_000;
    immutable uint brr = _regs.get(usart + (legacy ? 0x08 : 0x0C));
    return brr ? cast(uint)((fck + brr / 2) / brr) : 0;
}

// Time passes on the line with no driver call: the shifter works and interrupts are delivered.
void run_line()
{
    foreach (_; 0 .. 20_000)
    {
        _line.step();
        deliver();
    }
}

void edge(uint pin, bool rising)
{
    latch(pin, rising);
    deliver();
}

void edges_together(uint first, uint second)
{
    import model.cpu : irq_disable, irq_enable;
    irq_disable();
    latch(first, true);
    latch(second, true);
    irq_enable();
}

bool input_enabled(uint pin)
    => ((_regs.get(gpio_base(pin)) >> (pin & 15) * 2) & 3) != 3;

uint pin_function(uint pin)
    => (_regs.get(gpio_base(pin) + ((pin & 15) < 8 ? 0x20 : 0x24)) >> (pin & 7) * 4) & 0xF;

bool pin_level(uint pin)
    => (_regs.get(gpio_base(pin) + 0x14) >> (pin & 15) & 1) != 0;

uint mmio_read(size_t addr)
{
    if (addr >= usart && addr < usart + 0x40)
        return usart_read(cast(uint)(addr - usart));
    if (addr == exti_base + pr)
        return _exti_pr;
    return _regs.get(addr);
}

void mmio_write(size_t addr, uint value)
{
    if (addr >= usart && addr < usart + 0x40)
        return usart_write(cast(uint)(addr - usart), value);
    if (addr == exti_base + pr)
    {
        _exti_pr &= ~value;
        return;
    }
    if (addr >= gpio_base(0) && addr < gpio_base(0) + 11 * 0x400 && (addr & 0x3FF) == 0x18)
    {
        immutable odr = (addr & ~0x3FF) + 0x14;
        _regs.set(odr, (_regs.get(odr) | (value & 0xFFFF)) & ~(value >> 16));
        return;
    }
    _regs.set(addr, value);
}


private:

enum size_t usart = 0x4000_4400;

static if (legacy)
{
    enum uint sr = 0x00, dr = 0x04, cr1 = 0x0C, cr2 = 0x10, cr3 = 0x14;
    enum uint ue = 1 << 13;
}
else
{
    enum uint cr1 = 0x00, cr2 = 0x04, cr3 = 0x08, sr = 0x1C, icr = 0x20, rdr = 0x24, tdr = 0x28;
    enum uint ue = 1 << 0;
}
enum uint re = 1 << 2, te = 1 << 3, idleie = 1 << 4, rxneie = 1 << 5, txeie = 1 << 7, peie = 1 << 8, rtoie = 1 << 26;
enum uint eie = 1 << 0, txftie = 1 << 23, rxftie = 1 << 28, rtoen = 1 << 23;
enum uint pe = 1 << 0, fe = 1 << 1, ne = 1 << 2, ore = 1 << 3, idle = 1 << 4, rxne = 1 << 5, tc = 1 << 6, txe = 1 << 7, rtof = 1 << 11;

version (STM32H7)
{
    enum size_t exti_base = 0x5800_0000, syscfg_base = 0x5800_0400;
    enum uint rtsr = 0x00, ftsr = 0x04, imr = 0x80, pr = 0x88;
    size_t gpio_base(uint pin) => 0x5802_0000 + (pin >> 4) * 0x400;
}
else
{
    enum size_t exti_base = 0x4001_3C00, syscfg_base = 0x4001_3800;
    enum uint imr = 0x00, rtsr = 0x08, ftsr = 0x0C, pr = 0x14;
    size_t gpio_base(uint pin) => 0x4002_0000 + (pin >> 4) * 0x400;
}

static immutable ubyte[16] exti_irq = [ 6, 7, 8, 9, 10, 23, 23, 23, 23, 23, 40, 40, 40, 40, 40, 40 ];

__gshared Registers _regs;
__gshared Line!(depth, depth) _line;
__gshared uint _cr1, _cr2, _cr3, _flags, _exti_pr;
__gshared bool _sr_read, _since_idle;

void latch(uint pin, bool rising)
{
    immutable uint bit = 1u << (pin & 15);
    immutable uint port = (_regs.get(syscfg_base + 0x08 + (pin & 15) / 4 * 4) >> ((pin & 3) * 4)) & 0xF;
    if (port == pin >> 4 && (_regs.get(exti_base + (rising ? rtsr : ftsr)) & bit))
        _exti_pr |= bit;
}

ubyte error_bits(UartError err)
    => cast(ubyte)((err & UartError.parity ? pe : 0) | (err & UartError.framing ? fe : 0) | (err & UartError.noise ? ne : 0));

uint status()
{
    uint s = _flags;
    if (_line.rx_count)
        s |= rxne;
    if (!_line.tx_full)
        s |= txe;
    if (_line.tx_idle)
        s |= tc;
    return s;
}

bool usart_asserted()
{
    immutable s = status();
    bool a = (_cr1 & rxneie) && (s & (rxne | ore));
    a |= (_cr1 & txeie) && (s & txe);
    a |= (_cr1 & idleie) && (s & idle);
    a |= (_cr1 & peie) && (s & pe);
    static if (!legacy)
    {
        a |= (_cr1 & rtoie) && (s & rtof);
        a |= (_cr3 & eie) && (s & (fe | ne | ore));
        static if (depth > 1)
        {
            static immutable ubyte[3] rx_level = [ 2, 4, 8 ];
            a |= (_cr3 & rxftie) && _line.rx_count >= rx_level[(_cr3 >> 25) & 3];
            a |= (_cr3 & txftie) && depth - _line.tx_count >= depth / 2;
        }
    }
    return a;
}

bool is_asserted(uint line)
{
    if (line == uart_line)
        return usart_asserted();
    uint lines = _exti_pr & _regs.get(exti_base + imr);
    for (uint l = 0; lines; ++l, lines >>= 1)
        if ((lines & 1) && exti_irq[l] == line)
            return true;
    return false;
}

uint usart_read(uint off)
{
    if (off == sr)
    {
        _line.step();
        _sr_read = true;
        return status();
    }
    static if (legacy)
        immutable bool data = off == dr;
    else
        immutable bool data = off == rdr;
    if (data)
    {
        immutable b = _line.pop();
        static if (legacy)
        {
            if (_sr_read)
                _flags &= ~(pe | fe | ne | ore | idle);
            _sr_read = false;
        }
        else
            _flags = (_flags & ~(pe | fe | ne)) | _line.head_err;
        return b;
    }
    switch (off)
    {
        case cr1: return _cr1;
        case cr2: return _cr2;
        case cr3: return _cr3;
        default:  return _regs.get(usart + off);
    }
}

void usart_write(uint off, uint value)
{
    static if (legacy)
        immutable bool data = off == dr;
    else
        immutable bool data = off == tdr;
    if (data)
    {
        if (_cr1 & ue && _cr1 & te)
            _line.put(cast(ubyte)value);
        return;
    }
    static if (!legacy)
    {
        if (off == icr)
        {
            _flags &= ~(value & (pe | fe | ne | ore | idle | rtof));
            return;
        }
    }
    switch (off)
    {
        case cr1:
            if ((_cr1 & (ue | te)) == (ue | te) && (value & (ue | te)) != (ue | te))
                _line.tx_disable();
            if (!(value & ue))
            {
                _line.rx_clear();
                _flags = 0;
            }
            _cr1 = value;
            break;
        case cr2: _cr2 = value; break;
        case cr3: _cr3 = value; break;
        default:  _regs.set(usart + off, value);
    }
}
