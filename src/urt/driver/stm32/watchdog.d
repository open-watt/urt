// The independent watchdog, counting the 32 kHz LSI down to a reset. Once started only a reset stops it.
module urt.driver.stm32.watchdog;

import urt.driver.stm32 : reg_read, reg_write;

nothrow @nogc:

enum uint wdt_max_ms = 4096 * 256 / lsi_per_ms;

void wdt_start(uint timeout_ms)
{
    reg_write(iwdg_base + kr, key_start);
    configure(timeout_ms);
}

void wdt_feed()
{
    reg_write(iwdg_base + kr, key_reload);
}

// The IWDG cannot be stopped, so the longest timeout stands in for it until the coming reset.
void wdt_stop()
{
    configure(wdt_max_ms);
}


private:

version (STM32H7)
    enum ulong iwdg_base = 0x5800_4800;
else
    enum ulong iwdg_base = 0x4000_3000;

enum uint kr  = 0x00;
enum uint pr  = 0x04;
enum uint rlr = 0x08;
enum uint sr  = 0x0C;

enum uint key_start  = 0xCCCC;
enum uint key_reload = 0xAAAA;
enum uint key_access = 0x5555;
enum uint sr_busy    = 3;
enum uint lsi_per_ms = 32;

// the smallest prescaler, 4 << pr, whose 12-bit reload reaches the timeout
void configure(uint timeout_ms)
{
    immutable uint ticks = (timeout_ms < wdt_max_ms ? timeout_ms : wdt_max_ms) * lsi_per_ms;
    uint prescale = 0;
    while (ticks > 4096 << (prescale + 2))
        ++prescale;
    immutable uint reload = ticks >> (prescale + 2);
    while (reg_read(iwdg_base + sr) & sr_busy)
    {}
    reg_write(iwdg_base + kr, key_access);
    reg_write(iwdg_base + pr, prescale);
    reg_write(iwdg_base + rlr, reload ? reload - 1 : 0);
    while (reg_read(iwdg_base + sr) & sr_busy)
    {}
    wdt_feed();
}
