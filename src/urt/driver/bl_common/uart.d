// Bouffalo UART, one IP block on both BL808 cores and the BL618: M0 and the BL618 own UART0/1 on their CLIC,
// D0 owns UART3 on its PLIC. The console is the first port, up from early boot by uart0_early_init or uart_console_init.
module urt.driver.bl_common.uart;

import core.volatile;

import urt.driver.irq : irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartError, UartRxCallback, UartRxTiming,
    uart_chars_us, uart_gap_tenths, uart_rate_close, uart_rx_chars, uart_rx_gap_bits;
import urt.driver.uart_core : UartPorts;

version (BL808_M0)
    version = McuUarts;
else version (BL618)
    version = McuUarts;

nothrow @nogc:


version (McuUarts)
{
    enum uint first_uart = 0;
    enum uint num_uarts = 2;
    private immutable uint[num_uarts] uart_base = [0x2000_A000, 0x2000_A100];
    private immutable ubyte[num_uarts] uart_irq = [16 + 28, 16 + 29];
}
else
{
    enum uint first_uart = 3;
    enum uint num_uarts = 1;
    private immutable uint[num_uarts] uart_base = [0x3000_2000];
    private immutable ubyte[num_uarts] uart_irq = [16 + 4];
}

enum uint uart_clock_hz = 40_000_000;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd;
enum uint uart_stop_bits = 0xF;
enum uint uart_flow_controls = 1 << FlowControl.none;
enum bool uart_has_rs485 = false;
enum bool uart_has_pin_select = false;

private enum : uint
{
    UTX_CONFIG      = 0x00,
    URX_CONFIG      = 0x04,
    BIT_PRD         = 0x08,
    DATA_CONFIG     = 0x0C,
    URX_RTO_TIMER   = 0x18,
    SW_MODE         = 0x1C,
    INT_STS         = 0x20,
    INT_MASK        = 0x24,
    INT_CLEAR       = 0x28,
    INT_EN          = 0x2C,
    STATUS          = 0x30,
    FIFO_CONFIG_0   = 0x80,
    FIFO_CONFIG_1   = 0x84,
    FIFO_WDATA      = 0x88,
    FIFO_RDATA      = 0x8C,
}

// UTX_CONFIG (0x00)
private enum : uint
{
    CR_UTX_EN              = 1 << 0,
    CR_UTX_FRM_EN          = 1 << 2,
    CR_UTX_PRT_EN          = 1 << 4,
    CR_UTX_PRT_SEL         = 1 << 5,   // 0=even, 1=odd
    CR_UTX_BIT_CNT_D_SHIFT = 8,        // [10:8] data bits, field value = bits - 1
    CR_UTX_BIT_CNT_D_MASK  = 0x7 << 8,
    CR_UTX_BIT_CNT_P_SHIFT = 11,       // [12:11] stop bits (NOT [13:12] -- bit 13 is BIT_CNT_B/break)
    CR_UTX_BIT_CNT_P_MASK  = 0x3 << 11,
}

// URX_CONFIG (0x04)
private enum : uint
{
    CR_URX_EN              = 1 << 0,
    CR_URX_PRT_EN          = 1 << 4,
    CR_URX_PRT_SEL         = 1 << 5,
    CR_URX_BIT_CNT_D_SHIFT = 8,
    CR_URX_BIT_CNT_D_MASK  = 0x7 << 8,
}

// INT_STS / INT_MASK / INT_CLEAR / INT_EN
private enum : uint
{
    INT_UTX_FIFO = 1 << 2,
    INT_URX_FIFO = 1 << 3,
    INT_URX_RTO  = 1 << 4,
    INT_URX_PCE  = 1 << 5,
    INT_URX_FER  = 1 << 7,
    INT_RX       = INT_URX_FIFO | INT_URX_RTO | INT_URX_PCE | INT_URX_FER,
    INT_MASK_ALL = 0xFF,
}

private enum uint STS_UTX_BUS_BUSY = 1 << 0;

// FIFO_CONFIG_0 (0x80); the FIFO error flags above the clear bits are read-only
private enum : uint
{
    DMA_EN      = 0x3,
    TX_FIFO_CLR = 1 << 2,
    RX_FIFO_CLR = 1 << 3,
}

// FIFO_CONFIG_1 (0x84)
private enum : uint
{
    TX_FIFO_CNT_MASK  = 0x3F,         // [5:0]
    RX_FIFO_CNT_SHIFT = 8,
    RX_FIFO_CNT_MASK  = 0x3F << 8,    // [13:8]
    TX_FIFO_TH_SHIFT  = 16,
    TX_FIFO_TH_MASK   = 0x1F << 16,
    RX_FIFO_TH_SHIFT  = 24,
    RX_FIFO_TH_MASK   = 0x1F << 24,
}

private enum uint FIFO_DEPTH = 32;
private enum uint TX_FIFO_THRESHOLD = FIFO_DEPTH / 2;


bool uart_hw_open(uint port, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    immutable id = port - first_uart;
    immutable uint period = bit_period(cfg.baud_rate);
    if (!period || !_ports.acquire(id))
        return false;

    immutable base = uart_base[id];
    irq_line_disable(uart_irq[id]);
    reg_write(base, INT_MASK, INT_MASK_ALL);

    auto tx_cfg = reg_read(base, UTX_CONFIG);
    auto rx_cfg = reg_read(base, URX_CONFIG);
    tx_cfg &= ~CR_UTX_EN;
    rx_cfg &= ~CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    reg_write(base, BIT_PRD, (period - 1) << 16 | (period - 1));

    tx_cfg &= ~(CR_UTX_BIT_CNT_D_MASK | CR_UTX_BIT_CNT_P_MASK | CR_UTX_PRT_EN | CR_UTX_PRT_SEL | CR_UTX_FRM_EN);
    tx_cfg |= uint(cfg.data_bits - 1) << CR_UTX_BIT_CNT_D_SHIFT;
    tx_cfg |= uint(cfg.stop_bits) << CR_UTX_BIT_CNT_P_SHIFT;
    tx_cfg |= CR_UTX_FRM_EN;
    if (cfg.parity != Parity.none)
    {
        tx_cfg |= CR_UTX_PRT_EN;
        if (cfg.parity == Parity.odd)
            tx_cfg |= CR_UTX_PRT_SEL;
    }

    rx_cfg &= ~(CR_URX_BIT_CNT_D_MASK | CR_URX_PRT_EN | CR_URX_PRT_SEL);
    rx_cfg |= uint(cfg.data_bits - 1) << CR_URX_BIT_CNT_D_SHIFT;
    if (cfg.parity != Parity.none)
    {
        rx_cfg |= CR_URX_PRT_EN;
        if (cfg.parity == Parity.odd)
            rx_cfg |= CR_URX_PRT_SEL;
    }

    reg_write(base, FIFO_CONFIG_0, (reg_read(base, FIFO_CONFIG_0) & DMA_EN) | TX_FIFO_CLR | RX_FIFO_CLR);

    // the FIFO interrupt fires above its threshold, and the RX timeout counts one more than its field
    uint rx_chars = uart_rx_chars(cfg);
    rx_chars = rx_chars < FIFO_DEPTH / 2 ? rx_chars : FIFO_DEPTH / 2;
    uint gap_bits = uart_rx_gap_bits(cfg);
    gap_bits = gap_bits < 1 ? 1 : gap_bits > 256 ? 256 : gap_bits;
    _ports.start(id, rx_cb, UartRxTiming(uart_chars_us(cfg, rx_chars), uart_gap_tenths(cfg, gap_bits)));

    auto fifo1 = reg_read(base, FIFO_CONFIG_1);
    fifo1 &= ~(TX_FIFO_TH_MASK | RX_FIFO_TH_MASK);
    fifo1 |= (TX_FIFO_THRESHOLD - 1) << TX_FIFO_TH_SHIFT;
    fifo1 |= (rx_chars - 1) << RX_FIFO_TH_SHIFT;
    reg_write(base, FIFO_CONFIG_1, fifo1);
    reg_write(base, URX_RTO_TIMER, gap_bits - 1);

    reg_write(base, INT_CLEAR, INT_MASK_ALL);
    reg_write(base, INT_EN, INT_UTX_FIFO | INT_RX);
    reg_write(base, INT_MASK, INT_MASK_ALL & ~INT_RX);

    tx_cfg |= CR_UTX_EN;
    rx_cfg |= CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    irq_handler_set(uart_irq[id], &uart_isr);
    irq_line_enable(uart_irq[id]);
    return true;
}

void uart_hw_close(uint port)
{
    immutable id = port - first_uart;
    uart_hw_flush(port);
    immutable base = uart_base[id];
    irq_line_disable(uart_irq[id]);
    reg_write(base, INT_MASK, INT_MASK_ALL);
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) & ~CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) & ~CR_URX_EN);
    _ports.release(id);
}

void uart_hw_poll(uint port) {}

ptrdiff_t uart_hw_read(uint port, void[] buffer)
    => _ports.read(port - first_uart, buffer);

ptrdiff_t uart_hw_write(uint port, const(void)[] data)
    => _ports.write(port - first_uart, data);

UartRxTiming uart_hw_rx_timing(uint port)
    => _ports.timing(port - first_uart);

ptrdiff_t uart_hw_tx_pending(uint port)
    => _ports.tx_pending(port - first_uart);

ptrdiff_t uart_hw_rx_pending(uint port)
    => _ports.rx_pending(port - first_uart);

ptrdiff_t uart_hw_flush(uint port)
{
    immutable id = port - first_uart;
    if (reg_read(uart_base[id], UTX_CONFIG) & CR_UTX_EN)
        _ports.drain(id);
    return 0;
}

UartError uart_hw_check_errors(uint port)
    => _ports.take_errors(port - first_uart);


private:

__gshared UartPorts!(num_uarts, first_uart, tx_idle, fill_tx_fifo) _ports;

// Caller holds interrupts off, or runs in the ISR.
void fill_tx_fifo(uint id)
{
    immutable base = uart_base[id];
    ubyte b;
    for (uint space = reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK; space > 0 && _ports.tx_pop(id, b); --space)
        reg_write(base, FIFO_WDATA, b);
    uint mask = reg_read(base, INT_MASK);
    mask = _ports.tx_queued(id) ? mask & ~INT_UTX_FIFO : mask | INT_UTX_FIFO;
    reg_write(base, INT_MASK, mask);
}

bool tx_idle(uint id)
{
    immutable base = uart_base[id];
    return (reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK) == FIFO_DEPTH && !(reg_read(base, STATUS) & STS_UTX_BUS_BUSY);
}

uint drain_rx_fifo(uint id)
{
    immutable base = uart_base[id];
    immutable uint avail = (reg_read(base, FIFO_CONFIG_1) & RX_FIFO_CNT_MASK) >> RX_FIFO_CNT_SHIFT;
    foreach (_; 0 .. avail)
        _ports.receive(id, cast(ubyte)reg_read(base, FIFO_RDATA));
    return avail;
}

// An overflow or underflow holds URX_FER, and its status bits, until the RX FIFO is cleared.
void uart_isr(uint irq)
{
    immutable id = irq - uart_irq[0];
    immutable base = uart_base[id];
    immutable active = reg_read(base, INT_STS) & ~reg_read(base, INT_MASK);

    reg_write(base, INT_CLEAR, active & (INT_URX_RTO | INT_URX_PCE));
    immutable uint read = active & INT_RX ? drain_rx_fifo(id) : 0;
    if (active & INT_URX_PCE)
        _ports.error(id, UartError.parity);
    if (active & INT_URX_FER)
    {
        _ports.error(id, UartError.overrun);
        reg_write(base, FIFO_CONFIG_0, (reg_read(base, FIFO_CONFIG_0) & DMA_EN) | RX_FIFO_CLR);
    }
    if (active & INT_UTX_FIFO)
        fill_tx_fifo(id);

    if (read || (active & (INT_URX_RTO | INT_URX_PCE | INT_URX_FER)))
        _ports.notify(id);
}


public:

version (McuUarts)
{
    // Brings the console up before sys_init: the pads, the signal route and UART0 at 8N1 on the 40 MHz XCLK,
    // which runs whatever MCU_PBCLK is doing.
    void uart0_early_init(uint tx_pin, uint rx_pin, uint baud)
    {
        reg_write(HBN_GLB, 0, (reg_read(HBN_GLB, 0) & ~HBN_UART_CLK_SEL) | HBN_UART_CLK_SEL2);
        pin_uart(tx_pin, false);
        pin_uart(rx_pin, true);
        route_signal(pin_to_slot(tx_pin), UART0_TXD);
        route_signal(pin_to_slot(rx_pin), UART0_RXD);
        uart_console_init(baud);
    }
}

void uart_console_init(uint baud)
{
    immutable base = uart_base[0];
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) & ~CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) & ~CR_URX_EN);
    reg_write(base, INT_MASK, INT_MASK_ALL);
    immutable uint period = bit_period(baud);
    reg_write(base, BIT_PRD, (period - 1) << 16 | (period - 1));
    reg_write(base, UTX_CONFIG, CR_UTX_FRM_EN | (uint(7) << CR_UTX_BIT_CNT_D_SHIFT) | (uint(1) << CR_UTX_BIT_CNT_P_SHIFT));
    reg_write(base, URX_CONFIG, uint(7) << CR_URX_BIT_CNT_D_SHIFT);
    reg_write(base, FIFO_CONFIG_0, (reg_read(base, FIFO_CONFIG_0) & DMA_EN) | TX_FIFO_CLR | RX_FIFO_CLR);
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) | CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) | CR_URX_EN);
}

// Blocking console output for early boot and fault context; a FIFO that never drains drops the character.
void uart0_putc(char c)
{
    import urt.driver.uart_core : puts_stall_spins;

    immutable base = uart_base[0];
    uint spins = 0;
    while ((reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK) == 0)
    {
        if (++spins == puts_stall_spins)
            return;
    }
    reg_write(base, FIFO_WDATA, cast(uint)c);
}

void uart0_hw_puts(const(char)[] s)
{
    foreach (c; s)
    {
        if (c == '\n')
            uart0_putc('\r');
        uart0_putc(c);
    }
}

void uart0_print(const(char)* s)
{
    while (*s != 0)
    {
        if (*s == '\n')
            uart0_putc('\r');
        uart0_putc(*s);
        ++s;
    }
}

void uart0_hex(size_t val)
{
    uart0_putc('0');
    uart0_putc('x');
    int start = size_t.sizeof * 8 - 4;
    while (start > 0 && ((val >> start) & 0xF) == 0)
        start -= 4;
    for (int i = start; i >= 0; i -= 4)
    {
        uint nibble = cast(uint)(val >> i) & 0xF;
        uart0_putc(nibble < 10 ? cast(char)('0' + nibble) : cast(char)('a' + nibble - 10));
    }
}


private:

// UART clocks per bit, rounded; BIT_PRD holds it less one in 16 bits for each direction.
uint bit_period(uint baud) pure
{
    immutable ulong p = (ulong(uart_clock_hz) + baud / 2) / baud;
    return p >= 1 && p <= 0x1_0000 && uart_rate_close(baud, uart_clock_hz, p) ? cast(uint)p : 0;
}

uint reg_read(uint base, uint offset)
    => volatileLoad(cast(uint*)cast(size_t)(base + offset));

void reg_write(uint base, uint offset, uint value)
{
    volatileStore(cast(uint*)cast(size_t)(base + offset), value);
}

version (McuUarts)
{
    enum uint GLB_BASE      = 0x2000_0000;
    enum uint GLB_GPIO_CFG0 = 0x8C4;
    enum uint GLB_UART_CFG1 = 0x154;
    enum uint HBN_GLB       = 0x2000_F030;

    enum uint HBN_UART_CLK_SEL  = 1 << 2 | 1 << 15;
    enum uint HBN_UART_CLK_SEL2 = 1 << 15;

    // vendor GLB_UART_SIG_FUN_Type
    enum uint UART0_TXD = 2;
    enum uint UART0_RXD = 3;

    enum uint PAD_IE        = 1 << 0;
    enum uint PAD_SMT       = 1 << 1;
    enum uint PAD_DRV_MASK  = 3 << 2;
    enum uint PAD_DRV_1     = 1 << 2;
    enum uint PAD_PU        = 1 << 4;
    enum uint PAD_PD        = 1 << 5;
    enum uint PAD_OE        = 1 << 6;
    enum uint PAD_FUNC_MASK = 0x1F << 8;
    enum uint PAD_FUNC_UART = 7 << 8;
    enum uint PAD_MODE_MASK = 3 << 30;

    // start.d swaps the UART signal groups of GPIO12-23 and GPIO36-45
    uint pin_to_slot(uint pin)
        => (pin >= 12 && pin <= 23) || (pin >= 36 && pin <= 45) ? (pin + 6) % 12 : pin % 12;

    // The vendor drops the output enable before reconfiguring the pad.
    void pin_uart(uint pin, bool input)
    {
        immutable uint offset = GLB_GPIO_CFG0 + pin * 4;
        reg_write(GLB_BASE, offset, reg_read(GLB_BASE, offset) & ~PAD_OE);
        uint v = reg_read(GLB_BASE, offset) & ~(PAD_IE | PAD_PD | PAD_DRV_MASK | PAD_FUNC_MASK | PAD_MODE_MASK);
        v |= (input ? PAD_IE : 0) | PAD_PU | PAD_SMT | PAD_DRV_1 | PAD_FUNC_UART;
        reg_write(GLB_BASE, offset, v);
    }

    // Slots 0-7 are in GLB_UART_CFG1 and 8-11 in the word after it, four bits each.
    void route_signal(uint slot, uint signal)
    {
        immutable uint offset = GLB_UART_CFG1 + slot / 8 * 4;
        immutable uint shift = slot % 8 * 4;
        reg_write(GLB_BASE, offset, (reg_read(GLB_BASE, offset) & ~(0xFu << shift)) | signal << shift);
    }
}


unittest
{
    assert(bit_period(2_000_000) == 20 && bit_period(115_200) == 347, "2 Mbaud and 115200 from 40 MHz");
    assert(!bit_period(300) && bit_period(611) == 65_466, "300 baud needs more than 16 bits");
}
