// RP2350 register model: UART0 (a PL011 with 32-entry FIFOs), RESETS, IO_BANK0's edge latches, the pads and
// SIO outputs; atomic set and clear aliases apply to everything else, which is plain storage.
module fixture;

import model.cpu : deliver;
import model.line : Line, Registers;
import urt.driver.uart : UartError;

nothrow @nogc:

enum ubyte uart_port = 0;
enum ubyte other_port = 1;
enum uint uart_line = 33;

static immutable uint[3] event_pins = [ 2, 3, 4 ];
enum bool event_pins_share_line = false;
enum uint output_pin = 10;
static immutable uint[2] batch_pins = [ 8, 9 ];
enum UartError line_errors = cast(UartError)(UartError.parity | UartError.framing | UartError.break_);
enum bool shows_tx_busy = true;
enum bool programs_rx_gap = false;
enum bool keeps_bad_bytes = false;
enum bool has_links = true;

void reset()
{
    import model.cpu : asserted, line_on, irq_on, storms;
    _regs.clear();
    uart_reset();
    _reset_bits = uint.max;
    foreach (pin; 0 .. 48)
        _regs.set(pads + 4 + pin * 4, pad_iso);
    asserted = &is_asserted;
    line_on[] = false;
    irq_on = true;
    storms = 0;
}

void rx(ubyte b, UartError err = UartError.none)
{
    if (!(_cr & (uarten | rxe)))
        return;
    immutable ubyte bits = cast(ubyte)((err & UartError.framing ? 1 : 0) | (err & UartError.parity ? 2 : 0) | (err & UartError.break_ ? 4 : 0));
    if (!_line.receive(b, bits))
        _ris |= oe;
    _ris |= bits << 7;
    _since_idle = true;
    deliver();
}

void rx_overrun()
{
    _ris |= oe;
    deliver();
}

void line_idle()
{
    if (_since_idle && _line.rx_count)
        _ris |= rt;
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
    immutable ulong div = _regs.get(uart0 + 0x24) * 64 + _regs.get(uart0 + 0x28);
    return div ? cast(uint)((150_000_000UL * 4 + div / 2) / div) : 0;
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
    => (_regs.get(pads + 4 + pin * 4) & (pad_ie | pad_iso)) == pad_ie;

bool pin_level(uint pin)
    => (_out >> pin & 1) != 0;

uint mmio_read(size_t addr)
{
    if (addr >= uart0 && addr < uart0 + 0x1000)
        return uart_read(cast(uint)(addr - uart0));
    if (addr == resets + 0x08)
        return ~_reset_bits;
    if (addr >= io_bank0 + ints && addr < io_bank0 + ints + 24)
    {
        immutable r = (addr - io_bank0 - ints) / 4;
        return _regs.get(io_bank0 + intr + r * 4) & _regs.get(io_bank0 + inte + r * 4);
    }
    return _regs.get(addr);
}

void mmio_write(size_t addr, uint value)
{
    if (addr >= uart0 && addr < uart0 + 0x1000)
        return uart_write(cast(uint)(addr - uart0), value);
    if (addr >= sio && addr < sio + 0x100)
    {
        if (addr == sio + 0x18)
            _out |= value;
        else if (addr == sio + 0x20)
            _out &= ~value;
        return;
    }
    if (addr >= io_bank0 + intr && addr < io_bank0 + intr + 24)
    {
        _regs.set(addr, _regs.get(addr) & ~value);
        return;
    }
    immutable size_t reg = addr & ~size_t(0x3000);
    uint v = _regs.get(reg);
    final switch ((addr >> 12) & 3)
    {
        case 0: v = value; break;
        case 1: v ^= value; break;
        case 2: v |= value; break;
        case 3: v &= ~value; break;
    }
    if (reg == resets)
    {
        if (v & ~_reset_bits & reset_uart0)
            uart_reset();
        _reset_bits = v;
        return;
    }
    _regs.set(reg, v);
}


private:

enum size_t uart0 = 0x4007_0000, resets = 0x4002_0000, io_bank0 = 0x4002_8000, pads = 0x4003_8000, sio = 0xD000_0000;
enum uint intr = 0x230, inte = 0x248, ints = 0x278;
enum uint pad_ie = 1 << 6, pad_iso = 1 << 8;
enum uint reset_uart0 = 1 << 26;

enum uint dr = 0x00, fr = 0x18, cr = 0x30, ifls = 0x34, imsc = 0x38, ris = 0x3C, mis = 0x40, icr = 0x44;
enum uint uarten = 1 << 0, txe = 1 << 8, rxe = 1 << 9;
enum uint busy = 1 << 3, rxfe = 1 << 4, txff = 1 << 5;
enum uint rxi = 1 << 4, txi = 1 << 5, rt = 1 << 6, oe = 1 << 10;

static immutable ubyte[5] rx_level = [ 4, 8, 16, 24, 28 ];

__gshared Registers _regs;
__gshared Line!(32, 32) _line;
__gshared uint _cr, _ifls, _imsc, _ris, _reset_bits;
__gshared ulong _out;
__gshared bool _since_idle;

void uart_reset()
{
    _line = typeof(_line).init;
    _cr = _ifls = _imsc = _ris = 0;
}

void latch(uint pin, bool rising)
{
    if (!input_enabled(pin))
        return;
    immutable size_t reg = io_bank0 + intr + (pin >> 3) * 4;
    _regs.set(reg, _regs.get(reg) | (rising ? 8u : 4u) << (pin & 7) * 4);
}

uint raw()
{
    uint r = _ris & ~(rxi | txi);
    if (_line.rx_count >= rx_level[(_ifls >> 3) & 7])
        r |= rxi;
    if (_line.tx_count <= 4)
        r |= txi;
    if (!_line.rx_count)
        r &= ~rt;
    return r;
}

bool is_asserted(uint line)
{
    if (line == uart_line)
        return (raw() & _imsc) != 0;
    if (line == 21)
    {
        foreach (r; 0 .. 6)
            if (_regs.get(io_bank0 + intr + r * 4) & _regs.get(io_bank0 + inte + r * 4))
                return true;
    }
    return false;
}

uint uart_read(uint off)
{
    switch (off)
    {
        case dr:
            immutable uint err = _line.head_err;
            return _line.pop() | err << 8;
        case fr:
            _line.step();
            return (_line.rx_count ? 0 : rxfe) | (_line.tx_full ? txff : 0) | (_line.tx_idle ? 0 : busy);
        case cr:   return _cr;
        case ifls: return _ifls;
        case imsc: return _imsc;
        case ris:  return raw();
        case mis:  return raw() & _imsc;
        default:   return _regs.get(uart0 + off);
    }
}

void uart_write(uint off, uint value)
{
    switch (off)
    {
        case dr:
            if ((_cr & (uarten | txe)) == (uarten | txe))
                _line.put(cast(ubyte)value);
            break;
        case cr:
            if ((_cr & (uarten | txe)) == (uarten | txe) && (value & (uarten | txe)) != (uarten | txe))
                _line.tx_disable();
            _cr = value;
            break;
        case ifls: _ifls = value; break;
        case imsc: _imsc = value; break;
        case icr:  _ris &= ~value; break;
        default:   _regs.set(uart0 + off, value);
    }
}
