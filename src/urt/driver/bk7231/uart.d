// BK7231N and BK7231T: UART1 (the console) and UART2, 128-byte FIFOs. Registers and init order follow the
// Beken SDK, platforms/bk7231n/bk7231n_os/beken378/driver/uart/uart.h and uart_bk.c.
module urt.driver.bk7231.uart;

import core.volatile;

import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartError, UartRxCallback, UartRxTiming,
    uart_chars_us, uart_rate_close, uart_rx_chars;
import urt.driver.uart_core : UartPorts, puts_stall_spins;
import urt.driver.gpio : Pull, gpio_set_function;
import urt.driver.irq : irq_handler_set, irq_line_enable;
import urt.time : MonoTime, getTime, usecs;

nothrow @nogc:

enum num_uarts = 2;
enum uint uart_clock_hz = 26_000_000;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd;
enum uint uart_stop_bits = 1 << StopBits.one | 1 << StopBits.two;
enum uint uart_flow_controls = 1 << FlowControl.none | 1 << FlowControl.hardware;
enum bool uart_has_rs485 = false;
enum bool uart_has_pin_select = false;
enum bool uart_reports_rx_gap = false;


// Register offsets (from SDK uart.h)

private enum uint[2] uart_bases = [0x0080_2100, 0x0080_2200];

private enum : uint
{
    REG_CONFIG      = 0x00,  // Baud rate, data bits, parity, stop bits, TX/RX enable
    REG_FIFO_CONFIG = 0x04,  // FIFO thresholds, RX stop detect time
    REG_FIFO_STATUS = 0x08,  // FIFO counts and flags (read-only)
    REG_FIFO_PORT   = 0x0C,  // Data read/write port
    REG_INT_ENABLE  = 0x10,  // Interrupt enable
    REG_INT_STATUS  = 0x14,  // Interrupt status (write 1 to clear)
    REG_FLOW_CONFIG = 0x18,  // Flow control
    REG_WAKE_CONFIG = 0x1C,  // Wakeup configuration
}


// CONFIG register (0x00)

private enum : uint
{
    CFG_TX_ENABLE     = 1 << 0,
    CFG_RX_ENABLE     = 1 << 1,
    CFG_IRDA          = 1 << 2,
    CFG_DATA_LEN_POS  = 3,       // 2 bits: 0=5, 1=6, 2=7, 3=8
    CFG_DATA_LEN_MASK = 0x3 << 3,
    CFG_PARITY_EN     = 1 << 5,
    CFG_PARITY_ODD    = 1 << 6,  // 0=even, 1=odd
    CFG_STOP_LEN_2    = 1 << 7,  // 0=1 stop, 1=2 stop
    CFG_CLK_DIV_POS   = 8,       // 13-bit baud divisor
    CFG_CLK_DIV_MASK  = 0x1FFF << 8,
}


// FIFO_CONFIG register (0x04)

private enum : uint
{
    FIFO_TX_THRESHOLD_POS  = 0,       // 8 bits
    FIFO_TX_THRESHOLD_MASK = 0xFF,
    FIFO_RX_THRESHOLD_POS  = 8,       // 8 bits
    FIFO_RX_THRESHOLD_MASK = 0xFF << 8,
    FIFO_RX_STOP_TIME_POS  = 16,      // 3 bits: 0=32, 1=64, 2=128, 3=256 clks
    FIFO_RX_STOP_TIME_MASK = 0x3 << 16,
}


// FIFO_STATUS register (0x08, read-only)

private enum : uint
{
    STAT_TX_FIFO_COUNT_MASK  = 0xFF,        // bits [7:0]
    STAT_RX_FIFO_COUNT_POS   = 8,
    STAT_RX_FIFO_COUNT_MASK  = 0xFF << 8,   // bits [15:8]
    STAT_TX_FIFO_FULL        = 1 << 16,
    STAT_TX_FIFO_EMPTY       = 1 << 17,
    STAT_RX_FIFO_FULL        = 1 << 18,
    STAT_RX_FIFO_EMPTY       = 1 << 19,
    STAT_RX_FIFO_DOUT_POS    = 8,           // RX byte reads out of FIFO_PORT[15:8]
    STAT_FIFO_WR_READY       = 1 << 20,
    STAT_FIFO_RD_READY       = 1 << 21,
}


// INT_ENABLE (0x10) / INT_STATUS (0x14)
// Same bit layout for both registers.

private enum : uint
{
    INT_TX_FIFO_NEED_WRITE = 1 << 0,
    INT_RX_FIFO_NEED_READ  = 1 << 1,
    INT_RX_FIFO_OVERFLOW   = 1 << 2,
    INT_RX_PARITY_ERR      = 1 << 3,
    INT_RX_STOP_ERR        = 1 << 4,
    INT_TX_STOP_END        = 1 << 5,
    INT_RX_STOP_END        = 1 << 6,
    INT_RXD_WAKEUP         = 1 << 7,

    INT_ALL_ERRORS = INT_RX_FIFO_OVERFLOW | INT_RX_PARITY_ERR | INT_RX_STOP_ERR,
}


// FLOW_CONFIG register (0x18)

private enum : uint
{
    FLOW_LOW_CNT_POS    = 0,         // 8 bits: assert RTS below this count
    FLOW_LOW_CNT_MASK   = 0xFF,
    FLOW_HIGH_CNT_POS   = 8,         // 8 bits: de-assert RTS above this count
    FLOW_HIGH_CNT_MASK  = 0xFF << 8,
    FLOW_CTRL_EN        = 1 << 16,
    FLOW_RTS_POLARITY   = 1 << 17,
    FLOW_CTS_POLARITY   = 1 << 18,
}


private enum uint FIFO_DEPTH = 128;

// SDK defaults (uart.h): TX_FIFO_THRD=0x40, RX_FIFO_THRD=0x30
private enum uint SDK_TX_FIFO_THRESHOLD = 0x40;
private enum uint SDK_RX_STOP_DETECT    = 0;  // 32 clock cycles


// ICU registers for UART clock control
// From SDK icu.h: ICU_PERI_CLK_PWD = ICU_BASE + 2*4

private enum uint ICU_BASE         = 0x0080_2000;
private enum uint ICU_PERI_CLK_PWD = ICU_BASE + 2 * 4;  // 0x0080_2008

// Power-down bits (1=powered down, 0=running)
private enum uint PWD_UART1_CLK = 1 << 0;
private enum uint PWD_UART2_CLK = 1 << 1;


// UART pins are fixed by hardware; perial mode 0 is the only valid value.
private enum ubyte[2] default_tx_pins = [11, 0];   // UART1=GPIO11, UART2=GPIO0
private enum ubyte[2] default_rx_pins = [10, 1];   // UART1=GPIO10, UART2=GPIO1
private enum uint UART_PERIAL_MODE = 0;


private uint reg_read(uint addr)
{
    return volatileLoad(cast(uint*)(cast(size_t)addr));
}

private void reg_write(uint addr, uint val)
{
    volatileStore(cast(uint*)(cast(size_t)addr), val);
}


private bool gpio_setup_uart_pins(uint id, ref const UartConfig cfg)
{
    ubyte tx_pin = cfg.tx_gpio == ubyte.max ? default_tx_pins[id] : cfg.tx_gpio;
    ubyte rx_pin = cfg.rx_gpio == ubyte.max ? default_rx_pins[id] : cfg.rx_gpio;

    if (tx_pin != default_tx_pins[id] || rx_pin != default_rx_pins[id])
        return false;

    gpio_set_function(tx_pin, UART_PERIAL_MODE, Pull.up);
    gpio_set_function(rx_pin, UART_PERIAL_MODE, Pull.up);
    return true;
}


private void icu_uart_clock_enable(uint id)
{
    uint pwd = reg_read(ICU_PERI_CLK_PWD);
    pwd &= ~((id == 0) ? PWD_UART1_CLK : PWD_UART2_CLK);
    reg_write(ICU_PERI_CLK_PWD, pwd);
}

private void icu_uart_clock_disable(uint id)
{
    uint pwd = reg_read(ICU_PERI_CLK_PWD);
    pwd |= (id == 0) ? PWD_UART1_CLK : PWD_UART2_CLK;
    reg_write(ICU_PERI_CLK_PWD, pwd);
}


bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable uint div = divisor(cfg.baud_rate);
    if (!div)
        return false;
    immutable uint base = uart_bases[id];
    icu_uart_clock_enable(id);
    if (!gpio_setup_uart_pins(id, cfg))
        return false;
    reg_write(base + REG_CONFIG, 0);

    // the idle-stop interrupt delivers any sub-threshold tail
    reg_write(base + REG_FIFO_CONFIG,
        (SDK_TX_FIFO_THRESHOLD << FIFO_TX_THRESHOLD_POS)
      | (rx_threshold(cfg)     << FIFO_RX_THRESHOLD_POS)
      | (SDK_RX_STOP_DETECT    << FIFO_RX_STOP_TIME_POS));

    uint flow = 0;
    if (cfg.flow_control == FlowControl.hardware)
        flow = FLOW_CTRL_EN | (0x20 << FLOW_LOW_CNT_POS) | (0x60 << FLOW_HIGH_CNT_POS);
    reg_write(base + REG_FLOW_CONFIG, flow);
    reg_write(base + REG_WAKE_CONFIG, 0);
    reg_write(base + REG_INT_ENABLE, 0);
    reg_write(base + REG_INT_STATUS, reg_read(base + REG_INT_STATUS));

    uint config = CFG_TX_ENABLE | CFG_RX_ENABLE;
    config |= ((cfg.data_bits - 5) & 0x3) << CFG_DATA_LEN_POS;
    if (cfg.parity != Parity.none)
    {
        config |= CFG_PARITY_EN;
        if (cfg.parity == Parity.odd)
            config |= CFG_PARITY_ODD;
    }
    if (cfg.stop_bits == StopBits.two)
        config |= CFG_STOP_LEN_2;
    config |= (div - 1) << CFG_CLK_DIV_POS;
    reg_write(base + REG_CONFIG, config);
    return true;
}

bool uart_hw_open(uint id, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    if (!_ports.acquire(id))
        return false;
    if (!uart_hw_init(id, cfg))
    {
        _ports.release(id);
        return false;
    }
    _ports.start(id, rx_cb, UartRxTiming(uart_chars_us(cfg, rx_threshold(cfg))));
    _char_ticks[id] = cast(uint)usecs(uart_chars_us(cfg, 1) + 1).ticks;
    _fifo_empty[id] = false;
    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    reg_write(uart_bases[id] + REG_INT_ENABLE, INT_RX_FIFO_NEED_READ | INT_RX_STOP_END | INT_ALL_ERRORS);
    return true;
}

void uart_hw_close(uint id)
{
    uart_hw_flush(id);
    immutable uint base = uart_bases[id];
    reg_write(base + REG_INT_ENABLE, 0);
    reg_write(base + REG_CONFIG, reg_read(base + REG_CONFIG) & ~(CFG_TX_ENABLE | CFG_RX_ENABLE));
    _ports.release(id);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
    => _ports.read(id, buffer);

// TODO: TX_FIFO_NEED_WRITE never fires on this part, as the vendor's busy-wait in uart_write_byte suggests, so a
// write goes straight into the FIFO, takes what it holds, and raises no TX callback.
ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    immutable uint base = uart_bases[id];
    auto bytes = cast(const(ubyte)[])data;
    size_t n = 0;
    while (n < bytes.length && (reg_read(base + REG_FIFO_STATUS) & STAT_FIFO_WR_READY))
        reg_write(base + REG_FIFO_PORT, bytes[n++]);
    _fifo_empty[id] = false;
    return n;
}

UartRxTiming uart_hw_rx_timing(uint id)
    => _ports.timing(id);

// The RX threshold takes a new value while the UART runs.
UartRxTiming uart_hw_set_rx_timing(uint id, ref const UartConfig cfg)
{
    immutable uint config = uart_bases[id] + REG_FIFO_CONFIG;
    reg_write(config, (reg_read(config) & ~FIFO_RX_THRESHOLD_MASK) | rx_threshold(cfg) << FIFO_RX_THRESHOLD_POS);
    _ports.retime(id, UartRxTiming(uart_chars_us(cfg, rx_threshold(cfg))));
    return _ports.timing(id);
}

ptrdiff_t uart_hw_tx_pending(uint id)
    => _ports.tx_pending(id);

void uart_hw_poll(uint id) {}

UartError uart_hw_check_errors(uint id)
    => _ports.take_errors(id);

ptrdiff_t uart_hw_rx_pending(uint id)
    => _ports.rx_pending(id);

ptrdiff_t uart_hw_flush(uint id)
{
    if (reg_read(uart_bases[id] + REG_CONFIG) & CFG_TX_ENABLE)
        _ports.drain(id);
    return 0;
}

// Blocking output for early boot and fault context on UART1, the console.
void uart0_hw_puts(const(char)[] s)
{
    enum uint base = uart_bases[0];
    size_t i = 0;
    uint spins = 0;
    while (i < s.length && spins < puts_stall_spins)
    {
        if (reg_read(base + REG_FIFO_STATUS) & STAT_FIFO_WR_READY)
        {
            reg_write(base + REG_FIFO_PORT, s[i++]);
            spins = 0;
        }
        else
            ++spins;
    }
}


private:

// driver/include/intc_pub.h: IRQ_UART1 = 0, IRQ_UART2 = 1
immutable uint[2] uart_irq = [0, 1];

__gshared UartPorts!(num_uarts, 0, tx_idle) _ports;
__gshared uint[num_uarts] _char_ticks;
__gshared MonoTime[num_uarts] _empty_at;
__gshared bool[num_uarts] _fifo_empty;

// Clocks per bit, rounded; CONFIG holds it less one in 13 bits.
uint divisor(uint baud) pure
{
    immutable ulong d = (ulong(uart_clock_hz) + baud / 2) / baud;
    return d >= 2 && d <= 0x2000 && uart_rate_close(baud, uart_clock_hz, d) ? cast(uint)d : 0;
}

uint rx_threshold(ref const UartConfig cfg)
{
    immutable uint chars = uart_rx_chars(cfg);
    return chars < FIFO_DEPTH / 2 ? chars : FIFO_DEPTH / 2;
}

// Nothing shows the character still shifting, so the FIFO must have stood empty for a character time.
bool tx_idle(uint id)
{
    if (!(reg_read(uart_bases[id] + REG_FIFO_STATUS) & STAT_TX_FIFO_EMPTY))
    {
        _fifo_empty[id] = false;
        return false;
    }
    immutable now = getTime();
    if (!_fifo_empty[id])
    {
        _fifo_empty[id] = true;
        _empty_at[id] = now;
    }
    return (now - _empty_at[id]).ticks >= _char_ticks[id];
}

// overflow, parity and stop-bit errors, INT_STATUS bits 2-4
static immutable UartError[8] int_errors = () {
    UartError[8] t;
    foreach (i; 0 .. 8)
        t[i] = cast(UartError)((i & 1 ? UartError.overrun : 0) | (i & 2 ? UartError.parity : 0) | (i & 4 ? UartError.framing : 0));
    return t;
}();

void uart_isr(uint irq)
{
    immutable uint id = irq == uart_irq[1] ? 1 : 0;
    immutable uint base = uart_bases[id];

    immutable uint status = reg_read(base + REG_INT_STATUS);
    reg_write(base + REG_INT_STATUS, status);
    if (status & INT_ALL_ERRORS)
        _ports.error(id, int_errors[(status & INT_ALL_ERRORS) >> 2]);
    bool read;
    while (reg_read(base + REG_FIFO_STATUS) & STAT_FIFO_RD_READY)
    {
        _ports.receive(id, cast(ubyte)(reg_read(base + REG_FIFO_PORT) >> STAT_RX_FIFO_DOUT_POS));
        read = true;
    }
    if (read || (status & (INT_RX_STOP_END | INT_ALL_ERRORS)))
        _ports.notify(id);
}


unittest
{
    assert(divisor(115_200) == 226, "115200 from 26 MHz");
    assert(!divisor(1200) && divisor(3200) == 8125, "the 13-bit divisor floors the rate near 3.2 kbaud");
}
