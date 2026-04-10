// STM32 platform package (ARM Cortex-M4/M7)
//
// Provides sys_init() as the single entry point for all
// hardware initialization. Called from start.S before main().
//
// At reset, STM32 runs on HSI at 16 MHz (no PLL).
// sys_init brings up USART1 for console output and SysTick.
// PLL configuration for full-speed operation is not yet implemented.
module sys.stm32;

public import sys.stm32.uart;
public import sys.stm32.irq;
public import sys.stm32.timer;

import sys.baremetal.uart : UartConfig;
import core.volatile;

@nogc nothrow:

private extern(C) void __register_frame_info(const void*, void*);
private extern(C) extern const ubyte __eh_frame_start;
private ubyte[48] __eh_frame_object;

// RCC base and clock enable registers (same for F4 and F7)
enum ulong RCC_BASE     = 0x40023800;
enum ulong RCC_AHB1ENR  = 0x30;
enum ulong RCC_APB2ENR  = 0x44;

// GPIO base addresses
enum ulong GPIOA_BASE   = 0x40020000;

// GPIO register offsets
enum ulong GPIO_MODER   = 0x00;
enum ulong GPIO_OSPEEDR = 0x08;
enum ulong GPIO_AFRH    = 0x24;

// SCB registers for cache control (F7 only)
enum ulong SCB_CCR      = 0xE000ED14;
enum ulong ICIALLU      = 0xE000EF50;

private void mmio_write(ulong addr, uint val)
{
    volatileStore(cast(uint*)addr, val);
}

private uint mmio_read(ulong addr)
{
    return volatileLoad(cast(uint*)addr);
}

private void mmio_set(ulong addr, uint bits)
{
    volatileStore(cast(uint*)addr, volatileLoad(cast(uint*)addr) | bits);
}

private void mmio_rmw(ulong addr, uint clear_mask, uint set_bits)
{
    immutable val = volatileLoad(cast(uint*)addr);
    volatileStore(cast(uint*)addr, (val & ~clear_mask) | set_bits);
}

extern(C) void sys_init()
{
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    // Enable GPIOA clock (AHB1ENR bit 0)
    mmio_set(RCC_BASE + RCC_AHB1ENR, 1 << 0);

    // Enable USART1 clock (APB2ENR bit 4)
    mmio_set(RCC_BASE + RCC_APB2ENR, 1 << 4);

    // Configure PA9 (USART1_TX) and PA10 (USART1_RX) as AF7
    // MODER: bits 19:18 = 0b10 (PA9 AF), bits 21:20 = 0b10 (PA10 AF)
    mmio_rmw(GPIOA_BASE + GPIO_MODER,
        (3u << 18) | (3u << 20),
        (2u << 18) | (2u << 20));

    // OSPEEDR: high speed for PA9/PA10
    mmio_set(GPIOA_BASE + GPIO_OSPEEDR, (3u << 18) | (3u << 20));

    // AFRH: PA9 bits 7:4 = 7 (AF7), PA10 bits 11:8 = 7 (AF7)
    mmio_rmw(GPIOA_BASE + GPIO_AFRH,
        (0xFu << 4) | (0xFu << 8),
        (7u << 4) | (7u << 8));

    // Init UART0 (USART1) at default baud for early console
    uart_hw_init(0, UartConfig.init);

    uart0_hw_puts("STM32: sys_init\r\n");

    version (STM32F7)
    {
        // Enable instruction cache (D-cache needs DMA coherence handling)
        asm @nogc nothrow { "dsb sy"; "isb"; }
        mmio_write(ICIALLU, 0);
        asm @nogc nothrow { "dsb sy"; "isb"; }
        mmio_set(SCB_CCR, 1 << 17);
        asm @nogc nothrow { "dsb sy"; "isb"; }
        uart0_hw_puts("STM32F7: I-cache enabled\r\n");
    }

    // SysTick: 20 Hz tick (50ms)
    // HSI = 16 MHz, AHB prescaler = 1 at reset
    // Reload = 16_000_000 / 20 - 1 = 799_999
    timer_init(799_999);

    uart0_hw_puts("STM32: ready\r\n");
}
