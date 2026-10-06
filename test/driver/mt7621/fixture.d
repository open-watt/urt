// MT7621 register model: UART2 (a 16550 with 16-entry FIFOs, whose line-status errors clear when read, raising its
// interrupt on GIC line 27 by priority: line status, data at the FCR trigger, the character timeout after a pause,
// and an empty transmitter) and the GPIO block's edge latches; everything else is plain storage.
module fixture;

import model.cpu : deliver;
import model.line : Line, Registers;
import urt.driver.uart : UartError;

nothrow @nogc:

enum ubyte uart_port = 2;
enum ubyte other_port = 3;

// GPIO0 and the I2C and UART3 groups are free for the test; 6 and 7 share a bank, so one ISR takes them together.
static immutable uint[3] event_pins = [ 3, 4, 5 ];
enum bool event_pins_share_line = false;
enum uint output_pin = 13;
static immutable uint[2] batch_pins = [ 6, 7 ];
enum UartError line_errors = cast(UartError)(UartError.parity | UartError.framing | UartError.break_);
enum bool shows_tx_busy = true;
enum bool programs_rx_gap = false;
enum bool keeps_bad_bytes = true;
enum bool has_links = true;

void reset()
{
    import model.cpu : asserted, line_on, irq_on, storms;
    _regs.clear();
    _line = typeof(_line).init;
    _lcr = _ier = 0;
    _trigger = 1;
    _overrun = _timeout = false;
    asserted = &is_asserted;
    line_on[] = false;
    irq_on = true;
    storms = 0;
}

void rx(ubyte b, UartError err = UartError.none)
{
    immutable ubyte bits = cast(ubyte)((err & UartError.parity ? pe : 0) | (err & UartError.framing ? fe : 0) | (err & UartError.break_ ? bi : 0));
    if (!_line.receive(b, bits))
        _overrun = true;
    deliver();
}

void rx_overrun()
{
    _overrun = true;
    deliver();
}

void line_idle()
{
    _timeout = _line.rx_count != 0;
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
    immutable ulong div = _regs.get(uart) | _regs.get(uart + 0x04) << 8;
    return div ? cast(uint)((50_000_000UL + div * 8) / (div * 16)) : 0;
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
    => !(_regs.get(gpio + ctrl + pin / 32 * 4) & 1u << pin % 32);

bool pin_level(uint pin)
    => (_regs.get(gpio + data + pin / 32 * 4) & 1u << pin % 32) != 0;

uint mmio_read(size_t addr)
{
    if (addr >= uart && addr < uart + 0x100)
        return uart_read(cast(uint)(addr - uart));
    return _regs.get(addr);
}

void mmio_write(size_t addr, uint value)
{
    if (addr >= uart && addr < uart + 0x100)
        return uart_write(cast(uint)(addr - uart), value);
    if (addr >= gpio + stat && addr < gpio + stat + 8)
        return _regs.set(addr, _regs.get(addr) & ~value);
    if (addr >= gpio + dset && addr < gpio + dset + 8)
        return _regs.set(addr - dset + data, _regs.get(addr - dset + data) | value);
    if (addr >= gpio + dclr && addr < gpio + dclr + 8)
        return _regs.set(addr - dclr + data, _regs.get(addr - dclr + data) & ~value);
    _regs.set(addr, value);
}


private:

enum size_t uart = 0xBE00_0D00, gpio = 0xBE00_0600;
enum uint ctrl = 0x00, data = 0x20, dset = 0x30, dclr = 0x40, redge = 0x50, fedge = 0x60, stat = 0x90;
enum uint gpio_line = 12;

enum uint rbr = 0x00, ier = 0x04, iir = 0x08, fcr = 0x08, lcr = 0x0C, lsr = 0x14;
enum uint uart_line = 27;
enum uint ier_rda = 1 << 0, ier_thre = 1 << 1, ier_rls = 1 << 2;
static immutable ubyte[4] triggers = [ 1, 4, 8, 14 ];
enum uint dlab = 1 << 7;
enum ubyte dr = 1 << 0, oe = 1 << 1, pe = 1 << 2, fe = 1 << 3, bi = 1 << 4, thre = 1 << 5, temt = 1 << 6;

__gshared Registers _regs;
__gshared Line!(16, 16) _line;
__gshared uint _lcr, _ier, _trigger;
__gshared bool _overrun, _timeout;

// IIR's cause, highest priority first: line status, data at the trigger, the character timeout, an empty transmitter.
uint cause()
{
    if ((_ier & ier_rls) && (_overrun || (_line.rx_count && _line.head_err)))
        return 0x6;
    if ((_ier & ier_rda) && _line.rx_count >= _trigger)
        return 0x4;
    if ((_ier & ier_rda) && _timeout && _line.rx_count)
        return 0xC;
    if ((_ier & ier_thre) && !_line.tx_count)
        return 0x2;
    return 0x1;
}

void latch(uint pin, bool rising)
{
    immutable size_t bank = pin / 32 * 4;
    immutable uint bit = 1u << pin % 32;
    if (_regs.get(gpio + (rising ? redge : fedge) + bank) & bit)
        _regs.set(gpio + stat + bank, _regs.get(gpio + stat + bank) | bit);
}

bool is_asserted(uint line)
    => (line == gpio_line && (_regs.get(gpio + stat) | _regs.get(gpio + stat + 4)) != 0) || (line == uart_line && cause() != 0x1);

uint uart_read(uint off)
{
    if (_lcr & dlab && off < 0x08)
        return _regs.get(uart + off);
    switch (off)
    {
        case rbr:
            _timeout = false;
            return _line.pop();
        case ier:
            return _ier;
        case iir:
            return cause();
        case lsr:
            _line.step();
            uint s = _line.head_err;
            if (_line.rx_count)
                s |= dr;
            if (_overrun)
                s |= oe;
            if (!_line.tx_count)
                s |= thre;
            if (_line.tx_idle)
                s |= temt;
            _overrun = false;
            return s;
        case lcr:
            return _lcr;
        default:
            return _regs.get(uart + off);
    }
}

void uart_write(uint off, uint value)
{
    if (_lcr & dlab && off < 0x08)
        return _regs.set(uart + off, value);
    switch (off)
    {
        case rbr:
            _line.put(cast(ubyte)value);
            break;
        case ier:
            _ier = value;
            break;
        case fcr:
            if (value & 2)
                _line.rx_clear();
            if (value & 4)
                _line.tx_clear();
            _trigger = triggers[(value >> 6) & 3];
            break;
        case lcr:
            _lcr = value;
            break;
        default:
            _regs.set(uart + off, value);
    }
}
