// The parts of the STM32 platform package the UART, GPIO and event backends use, with clocks that need no PLL.
module urt.driver.stm32;

import core.volatile;

nothrow @nogc:

version (STM32H7)
{
    enum uint pclk1_hz  = 100_000_000;
    enum uint pclk2_hz  = 100_000_000;
    enum uint pclk4_hz  = 100_000_000;

    enum ulong rcc_base = 0x5802_4400;
    enum uint rcc_gpioenr = 0xE0;
    enum uint rcc_apb1enr = 0xE8;
    enum uint rcc_apb2enr = 0xF0;
    enum uint rcc_apb4enr = 0xF4;
}
else
{
    enum uint pclk1_hz  = 42_000_000;
    enum uint pclk2_hz  = 84_000_000;

    enum ulong rcc_base = 0x4002_3800;
    enum uint rcc_gpioenr = 0x30;
    enum uint rcc_apb1enr = 0x40;
    enum uint rcc_apb2enr = 0x44;
}

uint reg_read(ulong addr) => volatileLoad(cast(uint*)addr);
void reg_write(ulong addr, uint value) { volatileStore(cast(uint*)addr, value); }
void reg_rmw(ulong addr, uint clear, uint set) { reg_write(addr, (reg_read(addr) & ~clear) | set); }

void clock_enable(uint enr, uint bit)
{
    reg_write(rcc_base + enr, reg_read(rcc_base + enr) | 1u << bit);
}
