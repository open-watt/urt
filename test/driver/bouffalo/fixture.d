// Bouffalo register model: one UART (UART1 of the BL618 or the BL808 M0, or D0's UART3) with 32-entry FIFOs, read-only FIFO error
// status cleared only by the FIFO clear bits, and on M0 the GPIO_CFG interrupt latches; everything else is
// plain storage.
module fixture;

import model.cpu : deliver;
import model.line : Line, Registers;
import urt.driver.uart : UartError;

nothrow @nogc:

version (BL808_M0)
    version = McuUarts;
else version (BL618)
    version = McuUarts;

version (McuUarts)
{
    enum ubyte uart_port = 1;
    enum ubyte other_port = 0;
    enum uint uart_line = 16 + 29;
    enum size_t uart_base = 0x2000_A100;
    version (BL808_M0)
        enum bool has_links = true;
    else
        enum bool has_links = false;
}
else
{
    enum ubyte uart_port = 3;
    enum ubyte other_port = 3;
    enum uint uart_line = 16 + 4;
    enum size_t uart_base = 0x3000_2000;
    enum bool has_links = false;
}

static immutable uint[3] event_pins = [ 2, 3, 4 ];
enum bool event_pins_share_line = false;
enum uint output_pin = 10;
static immutable uint[2] batch_pins = [ 8, 9 ];
enum UartError line_errors = UartError.parity;
enum bool shows_tx_busy = true;
enum bool keeps_bad_bytes = true;

void reset()
{
    import model.cpu : asserted, line_on, irq_on, storms;
    _regs.clear();
    _line = typeof(_line).init;
    _utx = _urx = _int_mask = _int_en = _latched = _fifo0 = _fifo1 = 0;
    asserted = &is_asserted;
    line_on[] = false;
    irq_on = true;
    storms = 0;
}

void rx(ubyte b, UartError err = UartError.none)
{
    if (!(_urx & en))
        return;
    if (!_line.receive(b, 0))
        _fifo0 |= rx_overflow;
    if (err & UartError.parity)
        _latched |= urx_pce;
    _since_idle = true;
    deliver();
}

void rx_overrun()
{
    _fifo0 |= rx_overflow;
    deliver();
}

void line_idle()
{
    if (_since_idle)
        _latched |= urx_rto;
    _since_idle = false;
    deliver();
}

void tx_hold(bool hold) { _line.held = hold; }
void shift_busy(bool busy) { _line.busy = busy; }
const(ubyte)[] wire() => _line.sent_bytes;
void wire_clear() { _line.clear_wire(); }
uint tx_disabled_while_busy() => _line.disabled_while_busy;
uint tx_fifo_overflows() => _line.tx_overflows;

// BIT_PRD holds the period less one for TX in its low half and RX in its high half; they must agree.
uint programmed_baud()
{
    immutable uint v = _regs.get(uart_base + 0x08);
    if ((v & 0xFFFF) != v >> 16)
        return 0;
    return cast(uint)((40_000_000UL + ((v & 0xFFFF) + 1) / 2) / ((v & 0xFFFF) + 1));
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
    => (_regs.get(gpio_cfg(pin)) & gpio_input_en) != 0;

bool pin_level(uint pin)
    => (_regs.get(gpio_cfg(pin)) & gpio_output_high) != 0;

uint mmio_read(size_t addr)
{
    if (addr >= uart_base && addr < uart_base + 0x100)
        return uart_read(cast(uint)(addr - uart_base));
    return _regs.get(addr);
}

void mmio_write(size_t addr, uint value)
{
    if (addr >= uart_base && addr < uart_base + 0x100)
        return uart_write(cast(uint)(addr - uart_base), value);
    if (addr >= gpio_cfg(0) && addr < gpio_cfg(46))
    {
        immutable uint pending = value & gpio_int_clear ? 0 : _regs.get(addr) & gpio_int_pending;
        _regs.set(addr, (value & ~(gpio_int_pending | gpio_int_clear)) | pending);
        return;
    }
    _regs.set(addr, value);
}


private:

enum uint utx_config = 0x00, urx_config = 0x04, int_sts = 0x20, int_mask = 0x24, int_clear = 0x28, int_en = 0x2C, status = 0x30;
enum uint fifo_config_0 = 0x80, fifo_config_1 = 0x84, wdata = 0x88, rdata = 0x8C;
enum uint en = 1 << 0;
enum uint utx_fifo = 1 << 2, urx_fifo = 1 << 3, urx_rto = 1 << 4, urx_pce = 1 << 5, urx_fer = 1 << 7;
enum uint tx_clear = 1 << 2, rx_clear = 1 << 3, rx_overflow = 1 << 6, rx_underflow = 1 << 7;

enum uint gpio_input_en = 1 << 0, gpio_int_clear = 1 << 20, gpio_int_pending = 1 << 21, gpio_int_mask = 1 << 22, gpio_output_high = 1 << 24;
enum uint gpio_line = 16 + 44;

size_t gpio_cfg(uint pin) => 0x2000_08C4 + pin * 4;

__gshared Registers _regs;
__gshared Line!(32, 32) _line;
__gshared uint _utx, _urx, _int_mask, _int_en, _latched, _fifo0, _fifo1;
__gshared bool _since_idle;

void latch(uint pin, bool rising)
{
    immutable uint cfg = _regs.get(gpio_cfg(pin));
    immutable uint mode = (cfg >> 16) & 0xF;
    if (!(cfg & gpio_input_en) || !(mode == 4 || mode == (rising ? 1 : 0)))
        return;
    _regs.set(gpio_cfg(pin), cfg | gpio_int_pending);
}

uint int_status()
{
    uint s = _latched;
    if (32 - _line.tx_count > ((_fifo1 >> 16) & 0x1F))
        s |= utx_fifo;
    if (_line.rx_count > ((_fifo1 >> 24) & 0x1F))
        s |= urx_fifo;
    if (_fifo0 & (rx_overflow | rx_underflow))
        s |= urx_fer;
    return s;
}

bool is_asserted(uint line)
{
    if (line == uart_line)
        return (int_status() & ~_int_mask & _int_en) != 0;
    version (BL808_M0)
    {
        if (line == gpio_line)
        {
            foreach (pin; 0 .. 46)
            {
                immutable uint cfg = _regs.get(gpio_cfg(pin));
                if ((cfg & gpio_int_pending) && !(cfg & gpio_int_mask))
                    return true;
            }
        }
    }
    return false;
}

uint uart_read(uint off)
{
    switch (off)
    {
        case utx_config: return _utx;
        case urx_config: return _urx;
        case int_sts:    return int_status();
        case int_mask:   return _int_mask;
        case int_en:     return _int_en;
        case status:
            _line.step();
            return _line.tx_idle ? 0 : 1;
        case fifo_config_0: return _fifo0;
        case fifo_config_1:
            _line.step();
            return (_fifo1 & 0x1F1F_0000) | _line.rx_count << 8 | (32 - _line.tx_count);
        case rdata:
            if (!_line.rx_count)
                _fifo0 |= rx_underflow;
            return _line.pop();
        default: return _regs.get(uart_base + off);
    }
}

void uart_write(uint off, uint value)
{
    switch (off)
    {
        case utx_config:
            if ((_utx & en) && !(value & en))
                _line.tx_disable();
            _utx = value;
            break;
        case urx_config: _urx = value; break;
        case int_mask:   _int_mask = value; break;
        case int_en:     _int_en = value; break;
        case int_clear:  _latched &= ~(value & (urx_rto | urx_pce)); break;
        case fifo_config_0:
            if (value & tx_clear)
                _line.tx_clear();
            if (value & rx_clear)
            {
                _line.rx_clear();
                _fifo0 &= ~(rx_overflow | rx_underflow);
            }
            _fifo0 = (_fifo0 & 0xF0) | (value & 0x3);
            break;
        case fifo_config_1: _fifo1 = value & 0x1F1F_0000; break;
        case wdata:
            if (_utx & en)
                _line.put(cast(ubyte)value);
            break;
        default: _regs.set(uart_base + off, value);
    }
}
