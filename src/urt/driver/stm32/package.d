module urt.driver.stm32;

public import urt.driver.stm32.uart;
public import urt.driver.stm32.irq;
public import urt.driver.stm32.timer;

import urt.attribute : persist, used;
import urt.driver.uart : UartConfig, console_uart;

import core.volatile;

@nogc nothrow:

version (STM32H7)
{
    enum uint sysclk_hz = 400_000_000;
    enum uint hclk_hz   = 200_000_000;
    enum uint pclk1_hz  = 100_000_000;
    enum uint pclk2_hz  = 100_000_000;

    enum ulong rcc_base = 0x5802_4400;
    enum uint rcc_ahb2enr = 0xDC;
    enum uint rcc_gpioenr = 0xE0;
    enum uint rcc_apb1enr = 0xE8;
    enum uint rcc_apb2enr = 0xF0;
    enum uint rcc_gpiorstr = 0x88;
    enum uint rcc_otgfs_enr = 0xD8;         // AHB1ENR.USB2OTGFSEN
    enum uint rcc_otgfs_bit = 27;

    enum ulong system_memory = 0x1FF0_9800;
    enum ulong uid_base = 0x1FF1_E800;
    enum ulong flash_size_reg = 0x1FF1_E880;
}
else
{
    enum uint sysclk_hz = 168_000_000;
    enum uint hclk_hz   = 168_000_000;
    enum uint pclk1_hz  = 42_000_000;
    enum uint pclk2_hz  = 84_000_000;

    enum ulong rcc_base = 0x4002_3800;
    enum uint rcc_ahb2enr = 0x34;
    enum uint rcc_gpioenr = 0x30;
    enum uint rcc_apb1enr = 0x40;
    enum uint rcc_apb2enr = 0x44;
    enum uint rcc_gpiorstr = 0x10;
    enum uint rcc_otgfs_enr = 0x34;         // AHB2ENR.OTGFSEN
    enum uint rcc_otgfs_bit = 7;

    enum ulong system_memory = 0x1FFF_0000;
    version (STM32F7)
    {
        enum ulong uid_base = 0x1FF0_F420;
        enum ulong flash_size_reg = 0x1FF0_F442;
    }
    else
    {
        enum ulong uid_base = 0x1FFF_7A10;
        enum ulong flash_size_reg = 0x1FFF_7A22;
    }
}

// Timers on APB1 run at twice PCLK1 whenever the APB1 prescaler divides.
enum uint apb1_timer_hz = pclk1_hz * 2;

uint reg_read(ulong addr) => volatileLoad(cast(uint*)addr);
void reg_write(ulong addr, uint value) { volatileStore(cast(uint*)addr, value); }
void reg_set(ulong addr, uint bits) { reg_write(addr, reg_read(addr) | bits); }
void reg_clear(ulong addr, uint bits) { reg_write(addr, reg_read(addr) & ~bits); }
void reg_rmw(ulong addr, uint clear, uint set) { reg_write(addr, (reg_read(addr) & ~clear) | set); }

// The read back covers the RCC erratum: a peripheral touched right after its clock is enabled
// may miss the first access.
void clock_enable(uint enr, uint bit)
{
    reg_set(rcc_base + enr, 1u << bit);
    reg_read(rcc_base + enr);
}

// Flash size in KB as the factory programmed it; the part number can undersell it.
uint flash_size_kb() => volatileLoad(cast(ushort*)flash_size_reg);

// Takes effect through a reset, so the ROM starts from a clean peripheral state.
noreturn reboot_to_bootloader()
{
    import urt.driver.reset : system_reset;
    _bootloader_request = bootloader_magic;
    system_reset();
}

// Runs first from Reset_Handler, before .data, .bss or the GOT exist: registers, link-time
// constants and @persist only. A broken image can always be recovered into the ROM from here.
extern(C) void sys_early()
{
    import urt.driver.reset : ResetMark, reset_record_mark, system_reset;

    // DFU's leave request jumps here without a reset, leaving the ROM's USB core and clocks live.
    if (reg_read(rcc_base + rcc_otgfs_enr) & (1u << rcc_otgfs_bit))
    {
        reset_record_mark(ResetMark.deliberate);
        system_reset();
    }

    if (_bootloader_request == bootloader_magic || dfu_button_held())
    {
        _bootloader_request = 0;
        enter_system_bootloader();
    }
}

extern(C) void sys_init()
{
    bool on_hse = clocks_init();
    version (STM32F4) {} else
        caches_enable();

    uart_hw_init(console_uart, UartConfig.init);
    uart0_hw_puts("STM32: ");
    put_decimal(sysclk_hz / 1_000_000);
    uart0_hw_puts(on_hse ? " MHz from HSE, " : " MHz from HSI, ");
    put_decimal(flash_size_kb());
    uart0_hw_puts(" KB flash\r\n");

    mtime_init();
}


private:

enum uint bootloader_magic = 0xB007_10AD;
@persist @used __gshared uint _bootloader_request;

extern(C) extern __gshared const ubyte __stm32_hse_hz;
extern(C) extern __gshared const ubyte __stm32_dfu_button;

uint board_hse_hz() => cast(uint)cast(size_t)&__stm32_hse_hz;

void put_decimal(uint value)
{
    char[10] buf = void;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    uart0_hw_puts(buf[i .. $]);
}

bool dfu_button_held()
{
    import urt.driver.gpio : Pull, gpio_input_init, gpio_input_read;

    uint cfg = cast(uint)cast(size_t)&__stm32_dfu_button;
    if (cfg == 0xFFFF)
        return false;
    uint pin = cfg & 0xFF;
    bool active_high = (cfg & 0x100) != 0;

    gpio_input_init(pin, active_high ? Pull.down : Pull.up);
    foreach (i; 0 .. 2000)
        asm @nogc nothrow { "nop"; }
    bool held = gpio_input_read(pin) == active_high;

    uint port_bit = 1u << (pin / 16);
    reg_set(rcc_base + rcc_gpiorstr, port_bit);
    reg_clear(rcc_base + rcc_gpiorstr, port_bit);
    reg_clear(rcc_base + rcc_gpioenr, port_bit);
    return held;
}

noreturn enter_system_bootloader()
{
    version (STM32H7) {} else
    {
        // The F4/F7 ROM expects system memory aliased at 0.
        enum ulong syscfg_memrmp = 0x4001_3800;
        clock_enable(rcc_apb2enr, 14);
        reg_write(syscfg_memrmp, 1);
    }

    enum ulong scb_vtor = 0xE000_ED08;
    reg_write(scb_vtor, cast(uint)system_memory);
    uint sp = reg_read(system_memory);
    uint pc = reg_read(system_memory + 4);
    asm @nogc nothrow
    {
        `
        msr   msp, %0
        dsb
        isb
        cpsie i
        bx    %1
        `
        : : "r" (sp), "r" (pc) : "memory";
    }
    for (;;)
    {}
}

enum uint cr_hseon   = 1 << 16;
enum uint cr_hserdy  = 1 << 17;
enum uint cr_pllon   = 1 << 24;
enum uint cr_pllrdy  = 1 << 25;

enum uint hse_timeout = 500_000;

bool hse_start()
{
    uint hse = board_hse_hz();
    if (hse == 0)
        return false;
    reg_set(rcc_base, cr_hseon);
    foreach (i; 0 .. hse_timeout)
    {
        if (reg_read(rcc_base) & cr_hserdy)
            return true;
    }
    reg_clear(rcc_base, cr_hseon);
    return false;
}

version (STM32H7)
{
    bool clocks_init()
    {
        enum ulong pwr_base   = 0x5802_4800;
        enum ulong pwr_csr1   = pwr_base + 0x04;
        enum ulong pwr_cr3    = pwr_base + 0x0C;
        enum ulong pwr_d3cr   = pwr_base + 0x18;
        enum ulong flash_acr  = 0x5200_2000;

        enum ulong rcc_cfgr     = rcc_base + 0x10;
        enum ulong rcc_d1cfgr   = rcc_base + 0x18;
        enum ulong rcc_d2cfgr   = rcc_base + 0x1C;
        enum ulong rcc_d3cfgr   = rcc_base + 0x20;
        enum ulong rcc_pllckselr = rcc_base + 0x28;
        enum ulong rcc_pllcfgr  = rcc_base + 0x2C;
        enum ulong rcc_pll1divr = rcc_base + 0x30;

        // LDO supply; clearing SCUEN locks the configuration until the next power-on.
        reg_write(pwr_cr3, 1 << 1);
        while (!(reg_read(pwr_csr1) & (1 << 13)))
        {}

        reg_rmw(pwr_d3cr, 3 << 14, 3 << 14);        // VOS1
        while (!(reg_read(pwr_d3cr) & (1 << 13)))
        {}

        // HSI48 feeds USB and the RNG.
        reg_set(rcc_base, 1 << 12);
        while (!(reg_read(rcc_base) & (1 << 13)))
        {}

        // PLL1 reference must sit in 4..8 MHz for the wide-range VCO.
        uint src = 0;
        uint ref_hz = 4_000_000;
        uint divm = 64_000_000 / ref_hz;
        uint hse = board_hse_hz();
        if ((hse % 5_000_000 == 0 || hse % 4_000_000 == 0) && hse_start())
        {
            src = 2;
            ref_hz = hse % 5_000_000 == 0 ? 5_000_000 : 4_000_000;
            divm = hse / ref_hz;
        }
        enum uint vco_hz = 800_000_000;
        reg_write(rcc_pllckselr, (divm << 4) | src);
        reg_write(rcc_pllcfgr, (1 << 16) | (1 << 17) | (1 << 18) | (2 << 2));
        reg_write(rcc_pll1divr, ((vco_hz / ref_hz - 1) << 0) | ((2 - 1) << 9) | ((8 - 1) << 16) | ((2 - 1) << 24));
        reg_set(rcc_base, cr_pllon);
        while (!(reg_read(rcc_base) & cr_pllrdy))
        {}

        // VOS1, 200 MHz AXI: 2 wait states, WRHIGHFREQ 2.
        reg_write(flash_acr, 2 | (2 << 4));
        while ((reg_read(flash_acr) & 0x3F) != (2 | (2 << 4)))
        {}

        reg_write(rcc_d1cfgr, (0b1000 << 0) | (0b100 << 4));    // HPRE /2, D1PPRE /2
        reg_write(rcc_d2cfgr, (0b100 << 4) | (0b100 << 8));     // D2PPRE1 /2, D2PPRE2 /2
        reg_write(rcc_d3cfgr, 0b100 << 4);                      // D3PPRE /2

        reg_rmw(rcc_cfgr, 7, 3);
        while (((reg_read(rcc_cfgr) >> 3) & 7) != 3)
        {}
        return src != 0;
    }
}
else
{
    bool clocks_init()
    {
        enum ulong pwr_cr     = 0x4000_7000;
        enum ulong flash_acr  = 0x4002_3C00;
        enum ulong rcc_pllcfgr = rcc_base + 0x04;
        enum ulong rcc_cfgr    = rcc_base + 0x08;

        clock_enable(rcc_apb1enr, 28);                  // PWR
        reg_set(pwr_cr, 3 << 14);                       // regulator scale 1

        // PLL reference 1 MHz; VCO 336 MHz; /2 for SYSCLK, /7 for the 48 MHz USB/RNG clock.
        uint pllm = 16;
        uint src = 0;
        uint hse = board_hse_hz();
        if (hse % 1_000_000 == 0 && hse >= 4_000_000 && hse <= 26_000_000 && hse_start())
        {
            pllm = hse / 1_000_000;
            src = 1 << 22;
        }
        reg_write(rcc_pllcfgr, pllm | (336 << 6) | (0 << 16) | src | (7 << 24));
        reg_set(rcc_base, cr_pllon);
        while (!(reg_read(rcc_base) & cr_pllrdy))
        {}

        version (STM32F7)
            enum uint acr = 5 | (1 << 8) | (1 << 9);                // PRFTEN, ARTEN
        else
            enum uint acr = 5 | (1 << 8) | (1 << 9) | (1 << 10);    // PRFTEN, ICEN, DCEN
        reg_write(flash_acr, acr);
        while ((reg_read(flash_acr) & 0xF) != 5)
        {}

        // AHB /1, APB1 /4, APB2 /2, then switch to the PLL.
        reg_rmw(rcc_cfgr, (0xF << 4) | (7 << 10) | (7 << 13), (0b101 << 10) | (0b100 << 13));
        reg_rmw(rcc_cfgr, 3, 2);
        while (((reg_read(rcc_cfgr) >> 2) & 3) != 2)
        {}
        return src != 0;
    }

    // A spare PLLQ output: RNG and USB need exactly 48 MHz, which HSI cannot promise.
    static assert(336_000_000 / 7 == 48_000_000);
}

version (STM32F4) {} else
{
    void caches_enable()
    {
        enum ulong scb_ccr    = 0xE000_ED14;
        enum ulong scb_ccsidr = 0xE000_ED80;
        enum ulong scb_csselr = 0xE000_ED84;
        enum ulong scb_iciallu = 0xE000_EF50;
        enum ulong scb_dcisw  = 0xE000_EF60;

        asm @nogc nothrow { "dsb sy"; "isb"; }
        reg_write(scb_iciallu, 0);

        reg_write(scb_csselr, 0);
        asm @nogc nothrow { "dsb sy"; }
        uint ccsidr = reg_read(scb_ccsidr);
        uint sets = ((ccsidr >> 13) & 0x7FFF) + 1;
        uint ways = ((ccsidr >> 3) & 0x3FF) + 1;
        foreach (set; 0 .. sets)
            foreach (way; 0 .. ways)
                reg_write(scb_dcisw, (way << 30) | (set << 5));

        asm @nogc nothrow { "dsb sy"; }
        reg_set(scb_ccr, (1 << 16) | (1 << 17));
        asm @nogc nothrow { "dsb sy"; "isb"; }
    }
}
