// BK7231 register model: UART2 with 128-entry FIFOs. Its TX interrupt never fires, as on the part; RX raises
// at the FIFO threshold and on the stop-detect gap. Everything else is plain storage.
module fixture;

import model.cpu : deliver;
import model.line : Line, Registers;
import urt.driver.uart : UartError;

nothrow @nogc:

enum ubyte uart_port = 1;
enum ubyte other_port = 0;

static immutable uint[3] event_pins = [ 2, 3, 4 ];
enum bool event_pins_share_line = false;
enum uint output_pin = 10;
static immutable uint[2] batch_pins = [ 8, 9 ];
enum UartError line_errors = cast(UartError)(UartError.parity | UartError.framing);
enum bool shows_tx_busy = false;
enum bool retimes_latency_live = true;
enum bool programs_rx_gap = false;
enum bool keeps_bad_bytes = true;
enum bool has_links = false;

void reset()
{
    import model.cpu : asserted, line_on, irq_on, storms;
    _regs.clear();
    _line = typeof(_line).init;
    _config = _fifo_config = _int_en = _latched = 0;
    asserted = &is_asserted;
    line_on[] = false;
    irq_on = true;
    storms = 0;
}

void rx(ubyte b, UartError err = UartError.none)
{
    if (!(_config & rx_enable))
        return;
    if (!_line.receive(b, 0))
        _latched |= rx_overflow;
    if (err & UartError.parity)
        _latched |= parity_err;
    if (err & UartError.framing)
        _latched |= stop_err;
    _since_idle = true;
    deliver();
}

void rx_overrun()
{
    _latched |= rx_overflow;
    deliver();
}

void line_idle()
{
    if (_since_idle)
        _latched |= rx_stop_end;
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
    immutable ulong div = ((_config >> 8) & 0x1FFF) + 1;
    return cast(uint)((26_000_000UL + div / 2) / div);
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

void edge(uint, bool) {}
void edges_together(uint, uint) {}
bool input_enabled(uint) => false;
bool pin_level(uint) => false;

uint mmio_read(size_t addr)
{
    if (addr >= uart && addr < uart + 0x20)
        return uart_read(cast(uint)(addr - uart));
    return _regs.get(addr);
}

void mmio_write(size_t addr, uint value)
{
    if (addr >= uart && addr < uart + 0x20)
        return uart_write(cast(uint)(addr - uart), value);
    _regs.set(addr, value);
}


private:

enum size_t uart = 0x0080_2200;
enum uint uart_line = 1;

enum uint config = 0x00, fifo_config = 0x04, fifo_status = 0x08, fifo_port = 0x0C, int_enable = 0x10, int_status = 0x14;
enum uint tx_enable = 1 << 0, rx_enable = 1 << 1;
enum uint rx_need_read = 1 << 1, rx_overflow = 1 << 2, parity_err = 1 << 3, stop_err = 1 << 4, rx_stop_end = 1 << 6;
enum uint tx_empty = 1 << 17, wr_ready = 1 << 20, rd_ready = 1 << 21;

__gshared Registers _regs;
__gshared Line!(128, 128) _line;
__gshared uint _config, _fifo_config, _int_en, _latched;
__gshared bool _since_idle;

uint status()
{
    uint s = _latched;
    if (_line.rx_count >= ((_fifo_config >> 8) & 0xFF))
        s |= rx_need_read;
    return s;
}

bool is_asserted(uint line)
    => line == uart_line && (status() & _int_en) != 0;

uint uart_read(uint off)
{
    switch (off)
    {
        case config:      return _config;
        case fifo_config: return _fifo_config;
        case fifo_status:
            _line.step();
            return _line.tx_count | _line.rx_count << 8 | (_line.tx_count ? 0 : tx_empty)
                | (_line.tx_full ? 0 : wr_ready) | (_line.rx_count ? rd_ready : 0);
        case fifo_port:   return _line.pop() << 8;
        case int_enable:  return _int_en;
        case int_status:  return status();
        default:          return _regs.get(uart + off);
    }
}

void uart_write(uint off, uint value)
{
    switch (off)
    {
        case config:
            if ((_config & tx_enable) && !(value & tx_enable))
                _line.tx_disable();
            _config = value;
            break;
        case fifo_config: _fifo_config = value; break;
        case fifo_port:
            if (_config & tx_enable)
                _line.put(cast(ubyte)value);
            break;
        case int_enable:  _int_en = value; break;
        case int_status:  _latched &= ~value; break;
        default:          _regs.set(uart + off, value);
    }
}
