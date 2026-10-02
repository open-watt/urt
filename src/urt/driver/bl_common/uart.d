// Bouffalo UART driver, shared by the BL808 cores and the BL618; every UART is the same IP block.
//
// M0 and the BL618 own UART0/1 in the MCU domain, whose interrupts reach only their CLIC. D0 owns
// UART3 in the MM domain, on its PLIC.
//
// Interrupt driven: the ISR drains the RX FIFO into a ring at the threshold of the RX latency or after the line
// gap, both from UartConfig, and refills the TX FIFO from a ring while the ring holds data.
//
// The console is the first port. Early boot brings it up with uart0_early_init (M0 and the BL618,
// which also route its pins) or uart_console_init (D0), then writes it with uart0_putc and friends.
module urt.driver.bl_common.uart;

import core.volatile;

import urt.driver.irq : irq_critical, irq_handler_set, irq_line_disable, irq_line_enable;
import urt.driver.uart : Parity, StopBits, Uart, UartCallbackContext, UartConfig, UartRxCallback, UartRxTiming,
    uart_chars_us, uart_gap_tenths, uart_rx_chars, uart_rx_gap_bits;
import urt.mem.alloc : alloc, free;
import urt.mem.ring : RingBuffer;
import urt.sync.spsc : SPSCRing;
import urt.time : getTime, msecs;

version (BL808_M0)
    version = McuUarts;
else version (BL618)
    version = McuUarts;

nothrow @nogc:


// ----------------------------------------------------------------------------
// Register definitions
// ----------------------------------------------------------------------------

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
enum bool has_irq_driven_uart = true;
enum bool has_dma_driven_uart = false;

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
    INT_MASK_ALL = 0xFF,
}

// FIFO_CONFIG_0 (0x80)
private enum : uint
{
    TX_FIFO_CLR       = 1 << 2,
    RX_FIFO_CLR       = 1 << 3,
    TX_FIFO_OVERFLOW  = 1 << 4,
    TX_FIFO_UNDERFLOW = 1 << 5,
    RX_FIFO_OVERFLOW  = 1 << 6,
    RX_FIFO_UNDERFLOW = 1 << 7,
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
private enum uint RX_RING_SIZE = 512;
private enum tx_stall_limit = 50.msecs;


// ----------------------------------------------------------------------------
// Driver API
// ----------------------------------------------------------------------------

bool uart_hw_open(uint port, ref const UartConfig cfg, UartRxCallback rx_cb)
{
    import urt.mem.alloc : MemFlags;

    immutable id = port - first_uart;
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

    immutable base = uart_base[id];
    irq_line_disable(uart_irq[id]);
    reg_write(base, INT_MASK, INT_MASK_ALL);

    auto tx_cfg = reg_read(base, UTX_CONFIG);
    auto rx_cfg = reg_read(base, URX_CONFIG);
    tx_cfg &= ~CR_UTX_EN;
    rx_cfg &= ~CR_URX_EN;
    reg_write(base, UTX_CONFIG, tx_cfg);
    reg_write(base, URX_CONFIG, rx_cfg);

    immutable uint div = cast(uint)((cast(ulong)uart_clock_hz * 10 / cfg.baud_rate + 5) / 10);
    reg_write(base, BIT_PRD, ((div - 1) << 16) | (div - 1));

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

    (*p.rx).init();
    p.tx.purge();
    p.errors = false;
    p.cb = rx_cb;

    reg_write(base, FIFO_CONFIG_0, reg_read(base, FIFO_CONFIG_0) | TX_FIFO_CLR | RX_FIFO_CLR);

    // the FIFO interrupt fires above its threshold, and the RX timeout counts one more than its field
    uint rx_chars = uart_rx_chars(cfg);
    rx_chars = rx_chars < FIFO_DEPTH / 2 ? rx_chars : FIFO_DEPTH / 2;
    uint gap_bits = uart_rx_gap_bits(cfg);
    gap_bits = gap_bits < 1 ? 1 : gap_bits > 256 ? 256 : gap_bits;
    p.timing = UartRxTiming(uart_chars_us(cfg, rx_chars), uart_gap_tenths(cfg, gap_bits));

    auto fifo1 = reg_read(base, FIFO_CONFIG_1);
    fifo1 &= ~(TX_FIFO_TH_MASK | RX_FIFO_TH_MASK);
    fifo1 |= (TX_FIFO_THRESHOLD - 1) << TX_FIFO_TH_SHIFT;
    fifo1 |= (rx_chars - 1) << RX_FIFO_TH_SHIFT;
    reg_write(base, FIFO_CONFIG_1, fifo1);
    reg_write(base, URX_RTO_TIMER, gap_bits - 1);

    reg_write(base, INT_CLEAR, INT_MASK_ALL);
    reg_write(base, INT_EN, INT_UTX_FIFO | INT_URX_FIFO | INT_URX_RTO | INT_URX_PCE);
    reg_write(base, INT_MASK, INT_MASK_ALL & ~(INT_URX_FIFO | INT_URX_RTO | INT_URX_PCE));

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
    if (id >= num_uarts)
        return;

    uart_hw_flush(port);
    immutable base = uart_base[id];
    irq_line_disable(uart_irq[id]);
    reg_write(base, INT_MASK, INT_MASK_ALL);
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) & ~CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) & ~CR_URX_EN);
    _port[id].cb = null;
    release_rings(id);
}

void uart_hw_poll(uint port) {}

ptrdiff_t uart_hw_read(uint port, void[] buffer)
{
    immutable id = port - first_uart;
    return id < num_uarts && _port[id].rx ? _port[id].rx.pop(cast(ubyte[])buffer) : 0;
}

// Blocks while the ring is full and the line drains it; a line that stops ends the write short.
ptrdiff_t uart_hw_write(uint port, const(void)[] data)
{
    immutable id = port - first_uart;
    if (id >= num_uarts || !_port[id].tx)
        return 0;
    size_t total = 0;
    auto give_up = getTime() + tx_stall_limit;
    while (total < data.length)
    {
        size_t n;
        {
            auto guard = irq_critical();
            n = _port[id].tx.write(data[total .. $]);
            fill_tx_fifo(id);
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

UartRxTiming uart_hw_rx_timing(uint port)
{
    immutable id = port - first_uart;
    return id < num_uarts ? _port[id].timing : UartRxTiming();
}

ptrdiff_t uart_hw_tx_pending(uint port)
{
    immutable id = port - first_uart;
    if (id >= num_uarts || !_port[id].tx)
        return 0;
    auto guard = irq_critical();
    return _port[id].tx.pending + FIFO_DEPTH - (reg_read(uart_base[id], FIFO_CONFIG_1) & TX_FIFO_CNT_MASK);
}

ptrdiff_t uart_hw_rx_pending(uint port)
{
    immutable id = port - first_uart;
    return id < num_uarts && _port[id].rx ? _port[id].rx.pending : 0;
}

// Feeds the FIFO itself, so it drains with interrupts masked too.
ptrdiff_t uart_hw_flush(uint port)
{
    immutable id = port - first_uart;
    if (id >= num_uarts)
        return 0;
    immutable base = uart_base[id];
    if (!(reg_read(base, UTX_CONFIG) & CR_UTX_EN))
        return 0;
    immutable deadline = getTime() + 250.msecs;
    while (getTime() < deadline)
    {
        auto guard = irq_critical();
        fill_tx_fifo(id);
        if (!_port[id].tx || _port[id].tx.empty)
            break;
    }
    while ((reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK) < FIFO_DEPTH && getTime() < deadline)
    {}
    return 0;
}

bool uart_hw_check_errors(uint port)
{
    immutable id = port - first_uart;
    if (id >= num_uarts)
        return true;
    immutable base = uart_base[id];
    auto guard = irq_critical();
    immutable fifo0 = reg_read(base, FIFO_CONFIG_0);
    immutable fifo_errors = fifo0 & (RX_FIFO_OVERFLOW | RX_FIFO_UNDERFLOW);
    if (fifo_errors)
        reg_write(base, FIFO_CONFIG_0, fifo0);
    immutable errors = _port[id].errors || fifo_errors;
    _port[id].errors = false;
    return errors;
}


// ----------------------------------------------------------------------------
// Interrupt handler and FIFO transfer
// ----------------------------------------------------------------------------

private:

alias RxRing = SPSCRing!(ubyte, RX_RING_SIZE);
alias TxRing = RingBuffer!1024;

struct Port
{
    RxRing* rx;
    TxRing* tx;
    UartRxCallback cb;
    UartRxTiming timing;
    bool errors;
}

__gshared Port[num_uarts] _port;

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

// A full ring drops the byte rather than leave it in the FIFO, where its level interrupt would storm.
uint drain_rx_fifo(uint id)
{
    immutable base = uart_base[id];
    Port* p = &_port[id];
    uint pushed;
    for (uint avail = (reg_read(base, FIFO_CONFIG_1) & RX_FIFO_CNT_MASK) >> RX_FIFO_CNT_SHIFT; avail > 0; --avail)
    {
        ubyte b = cast(ubyte)reg_read(base, FIFO_RDATA);
        if (p.rx && p.rx.push((&b)[0 .. 1]))
            ++pushed;
        else
            p.errors = true;
    }
    return pushed;
}

// Caller holds interrupts off, or runs in the ISR.
void fill_tx_fifo(uint id)
{
    immutable base = uart_base[id];
    TxRing* tx = _port[id].tx;
    ubyte[1] b = void;

    for (uint space = reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK; space > 0 && tx && !tx.empty; --space)
    {
        tx.read(b);
        reg_write(base, FIFO_WDATA, cast(uint)b[0]);
    }

    uint mask = reg_read(base, INT_MASK);
    mask = !tx || tx.empty ? mask | INT_UTX_FIFO : mask & ~INT_UTX_FIFO;
    reg_write(base, INT_MASK, mask);
}

void uart_isr(uint irq)
{
    immutable id = irq - uart_irq[0];
    immutable base = uart_base[id];
    Port* p = &_port[id];
    immutable active = reg_read(base, INT_STS) & ~reg_read(base, INT_MASK);

    reg_write(base, INT_CLEAR, active & (INT_URX_RTO | INT_URX_PCE));
    if (active & INT_URX_PCE)
        p.errors = true;
    immutable uint pushed = active & (INT_URX_FIFO | INT_URX_RTO | INT_URX_PCE) ? drain_rx_fifo(id) : 0;
    if (active & INT_UTX_FIFO)
        fill_tx_fifo(id);

    if ((pushed || (active & INT_URX_RTO) || p.errors) && p.cb)
        p.cb(Uart(cast(ubyte)(id + first_uart)), p.rx ? p.rx.pending : 0, UartCallbackContext.interrupt);
}


// ----------------------------------------------------------------------------
// Early-boot pin/signal/UART setup
// ----------------------------------------------------------------------------
//
// Pin-to-slot mapping with UART swap groups enabled (start.d sets GPIO12-23
// and GPIO36-45 swap bits in GLB_PARM_CFG0):
//
//   GPIO 12..23 -> slot = (pin + 6) % 12
//   GPIO 36..45 -> slot = (pin + 6) % 12
//   otherwise   -> slot = pin % 12
//
// Slot 0..7 live in GLB_UART_CFG1, slot 8..11 in GLB_UART_CFG2. Each slot has
// a 4-bit field selecting which UART signal (UART0_TXD=2, UART0_RXD=3, ...)
// drives that pin.

public:

version (McuUarts)
{
    private enum uint GLB_BASE              = 0x2000_0000;
    private enum uint GLB_GPIO_CFG0_OFFSET  = 0x8C4;
    private enum uint GLB_UART_CFG1_OFFSET  = 0x154;
    private enum uint GLB_UART_CFG2_OFFSET  = 0x158;
    private enum uint HBN_GLB_ADDR          = 0x2000_F030;

    // UART signal function codes (matches vendor GLB_UART_SIG_FUN_Type enum order)
    enum uint UART0_TXD = 2;
    enum uint UART0_RXD = 3;
    enum uint UART1_TXD = 6;
    enum uint UART1_RXD = 7;

    // Configure GPIO pad for UART alt-function, signal-route the slot to the
    // requested UART signal, then bring UART0 up at the given baud, 8N1.
    // Idempotent: safe to call again from uart_hw_open() once the driver proper
    // is online.
    void uart0_early_init(uint tx_pin, uint rx_pin, uint baud)
    {
        // HBN UART_CLK_SEL = XCLK (enum 2 -> SEL2=1 at bit 15, SEL=0 at bit 2).
        // XCLK is deterministically 40 MHz (XTAL) regardless of MCU_PBCLK state;
        // see bouffalo-m0-clock-sources-at-boot.
        uint h = mmio_read(HBN_GLB_ADDR);
        h &= ~((uint(1) << 2) | (uint(1) << 15));
        h |= uint(1) << 15;
        mmio_write(HBN_GLB_ADDR, h);

        gpio_config_uart_af(tx_pin, false);     // TX: output via AF
        gpio_config_uart_af(rx_pin, true);      // RX: input via AF
        uart_route_signal(pin_to_slot(tx_pin), UART0_TXD);
        uart_route_signal(pin_to_slot(rx_pin), UART0_RXD);
        uart_console_init(baud);
    }

    private uint pin_to_slot(uint pin)
    {
        if ((pin >= 12 && pin <= 23) || (pin >= 36 && pin <= 45))
            return (pin + 6) % 12;
        return pin % 12;
    }

    private void gpio_config_uart_af(uint pin, bool is_input)
    {
        immutable addr = GLB_BASE + GLB_GPIO_CFG0_OFFSET + (pin << 2);
        uint v = mmio_read(addr);

        // Disable output first (vendor order).
        v &= ~(uint(1) << 6);              // OE = 0
        mmio_write(addr, v);

        v = mmio_read(addr);
        if (is_input)
        {
            v |= uint(1) << 0;             // IE = 1
            v &= ~(uint(1) << 6);          // OE = 0 (AF drives)
        }
        else
        {
            v &= ~uint(1);                 // IE = 0
            v &= ~(uint(1) << 6);          // OE = 0 (AF drives)
        }

        v |= uint(1) << 4;                 // PU = 1
        v &= ~(uint(1) << 5);              // PD = 0
        v |= uint(1) << 1;                 // SMT = 1
        v = (v & ~(uint(0x3) << 2)) | (uint(1) << 2);             // DRV = 1
        v = (v & ~(uint(0x1F) << 8)) | (uint(7) << 8);            // FUNC_SEL = GPIO_FUN_UART
        v = (v & ~(uint(0x3) << 30)) | (uint(0) << 30);           // output value mode

        mmio_write(addr, v);
    }

    private void uart_route_signal(uint slot, uint sig_fun)
    {
        uint reg_off;
        uint bit_off;
        if (slot < 8)
        {
            reg_off = GLB_UART_CFG1_OFFSET;
            bit_off = slot * 4;
        }
        else
        {
            reg_off = GLB_UART_CFG2_OFFSET;
            bit_off = (slot - 8) * 4;
        }
        immutable addr = GLB_BASE + reg_off;
        uint v = mmio_read(addr);
        v = (v & ~(uint(0xF) << bit_off)) | ((sig_fun & 0xF) << bit_off);
        mmio_write(addr, v);
    }
}

void uart_console_init(uint baud)
{
    immutable base = uart_base[0];

    // TX/RX off while reconfiguring
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) & ~CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) & ~CR_URX_EN);

    // Mask all IRQs
    reg_write(base, INT_MASK, INT_MASK_ALL);

    // Baud divisor: round-to-nearest on a x10 scaled fraction
    immutable uint div = cast(uint)((cast(ulong)uart_clock_hz * 10 / baud + 5) / 10);
    reg_write(base, BIT_PRD, ((div - 1) << 16) | (div - 1));

    // 8N1, framing on
    uint tx = CR_UTX_FRM_EN | (uint(7) << CR_UTX_BIT_CNT_D_SHIFT) | (uint(1) << CR_UTX_BIT_CNT_P_SHIFT);
    uint rx = uint(7) << CR_URX_BIT_CNT_D_SHIFT;
    reg_write(base, UTX_CONFIG, tx);
    reg_write(base, URX_CONFIG, rx);

    // Clear FIFOs
    reg_write(base, FIFO_CONFIG_0, reg_read(base, FIFO_CONFIG_0) | TX_FIFO_CLR | RX_FIFO_CLR);

    // Enable TX + RX
    reg_write(base, UTX_CONFIG, reg_read(base, UTX_CONFIG) | CR_UTX_EN);
    reg_write(base, URX_CONFIG, reg_read(base, URX_CONFIG) | CR_URX_EN);
}


// ----------------------------------------------------------------------------
// Early-boot blocking console output, usable before sys_init
// ----------------------------------------------------------------------------

void uart0_putc(char c)
{
    immutable base = uart_base[0];
    while ((reg_read(base, FIFO_CONFIG_1) & TX_FIFO_CNT_MASK) == 0) {}
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


// ----------------------------------------------------------------------------
// Register access helpers
// ----------------------------------------------------------------------------

private:

uint reg_read(uint base, uint offset)
{
    return volatileLoad(cast(uint*)cast(size_t)(base + offset));
}

void reg_write(uint base, uint offset, uint value)
{
    volatileStore(cast(uint*)cast(size_t)(base + offset), value);
}

version (McuUarts)
{
    uint mmio_read(uint addr)
    {
        return volatileLoad(cast(uint*)cast(size_t)addr);
    }

    void mmio_write(uint addr, uint value)
    {
        volatileStore(cast(uint*)cast(size_t)addr, value);
    }
}
