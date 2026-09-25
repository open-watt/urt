module urt.driver.mt7621;

public import urt.driver.mt7621.irq;
public import urt.driver.mt7621.uart;
public import urt.driver.mt7621.timer;

import urt.driver.uart : UartConfig;
import core.volatile;

@nogc nothrow:

enum uint sysctl_base = 0xBE00_0000;
enum uint memc_base   = 0xBE00_5000;

enum uint sysc_chip_name0     = 0x00;
enum uint sysc_chip_name1     = 0x04;
enum uint sysc_chip_rev       = 0x0C;
enum uint sysc_system_config0 = 0x10;
enum uint sysc_clkcfg0        = 0x2C;
enum uint sysc_rstctrl        = 0x34;
enum uint sysc_cur_clk_sts    = 0x44;
enum uint memc_cpu_pll        = 0x648;

__gshared uint cpu_hz;

extern(C) void sys_init()
{
    cpu_hz = cpu_rate();
    import urt.driver.mt7621.watchdog : wdt_stop;
    wdt_stop();
    stack_guard_init();
    uart_hw_init(console_uart, UartConfig.init);
    uart0_hw_puts("MT7621: sys_init\r\n");
    irq_init();
    counter_init(cpu_hz);
    import urt.exception : assert_handler;
    assert_handler = &assert_reset;
    irq_enable();
    static if (fixed_clock)
    {
        if (cpu_hz != mtime_freq_hz)
            uart0_hw_puts("MT7621: the CPU clock is not the board's CPU_HZ; time runs at the wrong rate\r\n");
    }
}

// "MT7621 ver:1 eco:3", read from the chip's own name and revision registers, as Linux reports it.
string chip_id()
{
    __gshared char[24] buf;
    __gshared size_t len;
    if (!len)
    {
        foreach (reg; [sysc_chip_name0, sysc_chip_name1])
        {
            immutable name = mmio_read(sysctl_base + reg);
            foreach (k; 0 .. 4)
            {
                immutable c = cast(char)(name >> (k * 8));
                if (c != ' ' && c != 0)
                    buf[len++] = c;
            }
        }
        immutable rev = mmio_read(sysctl_base + sysc_chip_rev);
        foreach (c; " ver:")
            buf[len++] = c;
        buf[len++] = cast(char)('0' + ((rev >> 8) & 0xF));
        foreach (c; " eco:")
            buf[len++] = c;
        buf[len++] = cast(char)('0' + (rev & 0xF));
    }
    return cast(string)buf[0 .. len];
}

uint mmio_read(uint addr)
    => volatileLoad(cast(uint*)addr);

void mmio_write(uint addr, uint value)
{
    volatileStore(cast(uint*)addr, value);
}

void assert_reset(string file, size_t line, string msg)
{
    uart0_hw_puts("\r\n*** ASSERT: ");
    uart0_hw_puts(msg);
    uart0_hw_puts(" at ");
    uart0_hw_puts(file);
    char[10] buf = void;
    size_t i = buf.length;
    size_t n = line;
    do
    {
        buf[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    while (n);
    uart0_hw_puts(":");
    uart0_hw_puts(buf[i .. $]);
    uart0_hw_puts("\r\n");
    import urt.driver.reset : system_reset;
    system_reset();
}

private:

extern(C) extern __gshared ubyte _stack_guard;

// A write anywhere in the 4K page below the stack raises a watch exception (ExcCode 23), so an overflow
// faults at its first store instead of corrupting the heap beneath.
void stack_guard_init()
{
    enum uint watch_w = 1 << 0;
    enum uint watchhi_g = 1 << 30;
    enum uint watchhi_mask_4k = 0x1FF << 3;
    enum uint watchhi_clear = 7;
    immutable uint lo = (cast(uint)&_stack_guard & ~7u) | watch_w;
    immutable uint hi = watchhi_g | watchhi_mask_4k | watchhi_clear;
    asm nothrow @nogc { ".set push; .set noat; mtc0 %0, $19, 2; mtc0 %1, $18, 2; ehb; .set pop" :: "r"(hi), "r"(lo) : "memory"; }
}

uint xtal_rate()
{
    immutable sel = (mmio_read(sysctl_base + sysc_system_config0) >> 6) & 7;
    return sel <= 2 ? 20_000_000 : sel <= 5 ? 40_000_000 : 25_000_000;
}

uint cpu_rate()
{
    immutable xtal = xtal_rate();
    ulong clk;
    switch (mmio_read(sysctl_base + sysc_clkcfg0) >> 30)
    {
        case 0:
            clk = 500_000_000;
            break;
        case 1:
            static immutable ubyte[4] prediv_shift = [0, 1, 2, 2];
            immutable pll = mmio_read(memc_base + memc_cpu_pll);
            clk = (ulong(((pll >> 4) & 0x7F) + 1) * xtal) >> prediv_shift[(pll >> 12) & 3];
            break;
        default:
            clk = xtal;
            break;
    }
    immutable sts = mmio_read(sysctl_base + sysc_cur_clk_sts);
    immutable fdiv = (sts >> 8) & 0x1F;
    immutable ffrac = sts & 0x1F;
    return fdiv ? cast(uint)(clk * ffrac / fdiv) : cast(uint)clk;
}
