// RP2350 platform package (ARM Cortex-M33)
//
// Provides sys_init() as the single entry point for all
// hardware initialization. Called from start.S before main().
module sys.rp2350;

public import sys.rp2350.uart;
public import sys.rp2350.irq;
public import sys.rp2350.timer;

import sys.baremetal.uart : UartConfig;
import core.volatile;

@nogc nothrow:

private extern(C) void __register_frame_info(const void*, void*);
private extern(C) extern const ubyte __eh_frame_start;
private ubyte[48] __eh_frame_object;  // storage for libgcc (no-op on ARM EHABI)

// RP2350 peripheral base addresses
enum ulong RESETS_BASE      = 0x40020000;
enum ulong CLOCKS_BASE      = 0x40010000;
enum ulong XOSC_BASE        = 0x40048000;
enum ulong PLL_SYS_BASE     = 0x40060000;
enum ulong SIO_BASE         = 0xD0000000;
enum ulong IO_BANK0_BASE    = 0x40028000;
enum ulong PADS_BANK0_BASE  = 0x40038000;

// Atomic set/clear/xor aliases (RP2350 address alias trick)
enum ulong REG_ALIAS_SET    = 0x00002000;
enum ulong REG_ALIAS_CLR    = 0x00003000;

// RESETS register offsets
enum ulong RESETS_RESET     = 0x00;
enum ulong RESETS_DONE      = 0x08;

// Reset bits for peripherals we need early
enum uint RESET_UART0       = 1 << 26;
enum uint RESET_UART1       = 1 << 27;
enum uint RESET_IO_BANK0    = 1 << 8;
enum uint RESET_PADS_BANK0  = 1 << 9;

private void mmio_write(ulong addr, uint val) @nogc nothrow
{
    volatileStore(cast(uint*)addr, val);
}

private uint mmio_read(ulong addr) @nogc nothrow
{
    return volatileLoad(cast(uint*)addr);
}

// Take peripherals out of reset and wait for them to be ready
private void unreset_wait(uint bits)
{
    // Clear reset bits (take out of reset)
    mmio_write(RESETS_BASE + RESETS_RESET + REG_ALIAS_CLR, bits);
    // Wait for reset done
    while ((mmio_read(RESETS_BASE + RESETS_DONE) & bits) != bits)
    {}
}

// Initialize all clocks, peripherals, and I/O needed at boot.
// Order matters:
//   1. Unreset GPIO and UART pads
//   2. Configure GPIO pins for UART0
//   3. Initialize UART0 for console output
//   4. Set up SysTick timer
extern(C) void sys_init()
{
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    // Bring up IO bank and pads, then UART0
    unreset_wait(RESET_IO_BANK0 | RESET_PADS_BANK0 | RESET_UART0);

    // GPIO0 = UART0 TX, GPIO1 = UART0 RX (function 2 on RP2350)
    // IO_BANK0 GPIO_CTRL registers are at offset 0x04 + n*0x08
    enum ulong GPIO0_CTRL = IO_BANK0_BASE + 0x04;
    enum ulong GPIO1_CTRL = IO_BANK0_BASE + 0x0C;
    mmio_write(GPIO0_CTRL, 2);  // FUNCSEL = UART
    mmio_write(GPIO1_CTRL, 2);  // FUNCSEL = UART

    // Init UART0 at default baud for early console
    uart_hw_init(0, UartConfig.init);

    uart0_hw_puts("RP2350: sys_init\r\n");

    // SysTick: 20Hz tick (50ms) for the main loop
    // Default clock is ~150MHz after PLL init, but we're running on the
    // ring oscillator (~6MHz) until clock init is implemented.
    // SysTick reload = clock_hz / desired_hz - 1
    // At 6MHz ring osc: 6_000_000 / 20 - 1 = 299_999
    timer_init(299_999);

    uart0_hw_puts("RP2350: ready\r\n");
}
