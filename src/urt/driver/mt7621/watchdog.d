// Timer 1 of the SoC timer block, in watchdog mode: counts down in milliseconds and resets the chip at zero.
module urt.driver.mt7621.watchdog;

import urt.driver.mt7621 : mmio_read, mmio_write, sysctl_base;

nothrow @nogc:

enum uint wdt_max_ms = 0xFFFF;

void wdt_start(uint timeout_ms)
{
    mmio_write(tmr1ctl, 1000 << tmr1ctl_prescale_shift);
    mmio_write(tmr1load, timeout_ms < wdt_max_ms ? timeout_ms : wdt_max_ms);
    wdt_feed();
    mmio_write(tmr1ctl, mmio_read(tmr1ctl) | tmr1ctl_enable);
}

void wdt_feed()
{
    mmio_write(tmrstat, tmr1_restart);
}

void wdt_stop()
{
    wdt_feed();
    mmio_write(tmr1ctl, mmio_read(tmr1ctl) & ~tmr1ctl_enable);
}

// Read-and-clear: the cause stays latched across later resets otherwise.
bool reset_by_watchdog()
{
    immutable status = mmio_read(sysctl_base + sysc_rststat);
    mmio_write(sysctl_base + sysc_rststat, status);
    return (status & rststat_wdt) != 0;
}


private:

enum uint timer_base = 0xBE00_0100;
enum uint tmrstat  = timer_base + 0x00;
enum uint tmr1ctl  = timer_base + 0x20;
enum uint tmr1load = timer_base + 0x24;

enum uint tmr1ctl_enable = 1 << 7;
enum uint tmr1_restart = 1 << 9;
enum uint tmr1ctl_prescale_shift = 16;

enum uint sysc_rststat = 0x38;
enum uint rststat_wdt = 1 << 1;
