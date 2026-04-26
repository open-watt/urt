// STM32 UART driver
//
// Supports both F4 (legacy SR/DR register layout) and F7 (ISR/RDR/TDR).
// USART1-6 on F4, USART1-6 + UART7-8 on F7.
//
// Default console: USART1 on PA9 (TX) / PA10 (RX), configured in sys_init.
module urt.driver.stm32.uart;

import core.volatile;

import urt.driver.uart : Parity, StopBits, UartConfig;

nothrow @nogc:

version (STM32F7)
    enum uint num_uarts = 8;
else
    enum uint num_uarts = 6;

enum uint uart_clock_hz = 16_000_000;
enum bool has_irq_driven_uart = false;
enum bool has_dma_driven_uart = false;

// F4 uses legacy register layout (SR/DR), F7 uses new layout (ISR/RDR/TDR).
// Register offsets and UE bit position differ; status bit positions are the same.
version (STM32F4) enum legacy_usart = true;
else              enum legacy_usart = false;

// Status bits (same positions in F4 SR and F7 ISR)
private enum
{
    ST_TXE  = 1 << 7,
    ST_RXNE = 1 << 5,
    ST_TC   = 1 << 6,
    ST_ORE  = 1 << 3,
    ST_FE   = 1 << 1,
    ST_PE   = 1 << 0,
}

// CR1 bits shared between F4 and F7
private enum
{
    CR1_TE = 1 << 3,
    CR1_RE = 1 << 2,
}

// F4: UE is bit 13 in CR1 at offset 0x0C
// F7: UE is bit 0  in CR1 at offset 0x00
static if (legacy_usart)
    private enum uint CR1_UE = 1 << 13;
else
    private enum uint CR1_UE = 1 << 0;

// Register offsets
static if (legacy_usart)
{
    private enum { SR = 0x00, DR = 0x04, BRR = 0x08, CR1 = 0x0C, CR2 = 0x10, CR3 = 0x14 }
}
else
{
    private enum { CR1 = 0x00, CR2 = 0x04, CR3 = 0x08, BRR = 0x0C, ISR = 0x1C, ICR = 0x20, RDR = 0x24, TDR = 0x28 }
}

// USART base addresses (F4 and F7 share the same addresses for USART1-6)
private ulong uart_base(uint id)
{
    immutable ulong[8] bases = [
        0x40011000,  // USART1 (APB2)
        0x40004400,  // USART2 (APB1)
        0x40004800,  // USART3 (APB1)
        0x40004C00,  // UART4  (APB1)
        0x40005000,  // UART5  (APB1)
        0x40011400,  // USART6 (APB2)
        0x40007800,  // UART7  (APB1, F7 only)
        0x40007C00,  // UART8  (APB1, F7 only)
    ];
    return bases[id];
}

private void reg_write(ulong base, uint offset, uint val)
{
    volatileStore(cast(uint*)(base + offset), val);
}

private uint reg_read(ulong base, uint offset)
{
    return volatileLoad(cast(uint*)(base + offset));
}

private uint read_status(ulong base)
{
    static if (legacy_usart)
        return reg_read(base, SR);
    else
        return reg_read(base, ISR);
}

private ubyte read_data(ulong base)
{
    static if (legacy_usart)
        return cast(ubyte)(reg_read(base, DR) & 0xFF);
    else
        return cast(ubyte)(reg_read(base, RDR) & 0xFF);
}

private void write_data(ulong base, ubyte val)
{
    static if (legacy_usart)
        reg_write(base, DR, val);
    else
        reg_write(base, TDR, val);
}

bool uart_hw_init(uint id, UartConfig cfg)
{
    immutable base = uart_base(id);

    // Disable UART while configuring
    reg_write(base, CR1, 0);

    // Baud rate: BRR = fck / baud (16x oversampling)
    immutable uint brr = uart_clock_hz / cfg.baud_rate;
    reg_write(base, BRR, brr);

    // Line control: word length, parity, stop bits
    uint cr1 = CR1_UE | CR1_TE | CR1_RE;
    uint cr2 = 0;

    if (cfg.parity != Parity.none)
    {
        static if (legacy_usart)
            cr1 |= 1 << 10;               // PCE: parity enable
        else
            cr1 |= 1 << 10;               // PCE: parity enable
        if (cfg.parity == Parity.odd)
        {
            static if (legacy_usart)
                cr1 |= 1 << 9;            // PS: odd parity
            else
                cr1 |= 1 << 9;            // PS: odd parity
        }
        // With parity, need M=1 (9 data bits) to keep 8 data + 1 parity
        static if (legacy_usart)
            cr1 |= 1 << 12;               // M: word length 9
        else
            cr1 |= 1 << 12;               // M0: word length 9
    }

    if (cfg.stop_bits == StopBits.two)
        cr2 |= 2 << 12;                   // STOP: 2 stop bits
    else if (cfg.stop_bits == StopBits.half)
        cr2 |= 1 << 12;                   // STOP: 0.5 stop bits
    else if (cfg.stop_bits == StopBits.one_point_five)
        cr2 |= 3 << 12;                   // STOP: 1.5 stop bits

    reg_write(base, CR2, cr2);
    reg_write(base, CR3, 0);
    reg_write(base, CR1, cr1);

    return true;
}

bool uart_hw_open(uint id, UartConfig cfg)
{
    return uart_hw_init(id, cfg);
}

void uart_hw_close(uint id)
{
    reg_write(uart_base(id), CR1, 0);
}

ptrdiff_t uart_hw_read(uint id, void[] buffer)
{
    immutable base = uart_base(id);
    auto buf = cast(ubyte[])buffer;
    ptrdiff_t n = 0;
    while (n < buf.length)
    {
        if (!(read_status(base) & ST_RXNE))
            break;
        buf[n] = read_data(base);
        ++n;
    }
    return n;
}

ptrdiff_t uart_hw_write(uint id, const(void)[] data)
{
    immutable base = uart_base(id);
    auto buf = cast(const(ubyte)[])data;
    ptrdiff_t n = 0;
    while (n < buf.length)
    {
        if (!(read_status(base) & ST_TXE))
            break;
        write_data(base, buf[n]);
        ++n;
    }
    return n;
}

void uart_hw_poll(uint id) {}

bool uart_hw_check_errors(uint id)
{
    immutable base = uart_base(id);
    immutable st = read_status(base);
    if (st & (ST_ORE | ST_FE | ST_PE))
    {
        static if (legacy_usart)
        {
            // F4: read SR then DR to clear error flags
            reg_read(base, DR);
        }
        else
        {
            // F7: write ICR to clear error flags
            reg_write(base, ICR, ST_ORE | ST_FE | ST_PE);
        }
        return true;
    }
    return false;
}

ptrdiff_t uart_hw_rx_pending(uint id)
{
    if (read_status(uart_base(id)) & ST_RXNE)
        return 1;
    return 0;
}

ptrdiff_t uart_hw_flush(uint id)
{
    immutable base = uart_base(id);
    while (!(read_status(base) & ST_TC))
    {}
    return 0;
}

// Blocking puts for early boot (before the serial stream is up)
void uart0_hw_puts(const(char)[] s)
{
    enum ulong base = 0x40011000;  // USART1
    foreach (c; s)
    {
        static if (legacy_usart)
        {
            while (!(volatileLoad(cast(uint*)(base + SR)) & ST_TXE))
            {}
            volatileStore(cast(uint*)(base + DR), cast(uint)c);
        }
        else
        {
            while (!(volatileLoad(cast(uint*)(base + ISR)) & ST_TXE))
            {}
            volatileStore(cast(uint*)(base + TDR), cast(uint)c);
        }
    }
}
