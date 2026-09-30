// The watchdog counts microsecond ticks from the TICKS block down to a reset of every block but the oscillators.
module urt.driver.rp2350.watchdog;

import urt.driver.rp2350 : mmio_read, mmio_write, ticks_base, watchdog_base, watchdog_reset_all, xosc_hz;

nothrow @nogc:

enum uint wdt_max_ms = 0xFF_FFFF / 1000;

void wdt_start(uint timeout_ms)
{
    mmio_write(ticks_base + ticks_watchdog_ctrl, 0);
    mmio_write(ticks_base + ticks_watchdog_cycles, xosc_hz / 1_000_000);
    mmio_write(ticks_base + ticks_watchdog_ctrl, 1);
    watchdog_reset_all();
    _load = (timeout_ms < 1 ? 1 : timeout_ms < wdt_max_ms ? timeout_ms : wdt_max_ms) * 1000;
    wdt_feed();
    mmio_write(watchdog_base + ctrl, mmio_read(watchdog_base + ctrl) | ctrl_enable);
}

void wdt_feed()
{
    mmio_write(watchdog_base + load, _load);
}

void wdt_stop()
{
    mmio_write(watchdog_base + ctrl, mmio_read(watchdog_base + ctrl) & ~ctrl_enable);
}


private:

enum uint ctrl     = 0x00;
enum uint load     = 0x04;

enum uint ctrl_enable  = 1 << 30;

enum uint ticks_watchdog_ctrl   = 0x30;
enum uint ticks_watchdog_cycles = 0x34;

__gshared uint _load;
