// The MCU timer block's watchdog, counting the 32 kHz clock divided to 1024 Hz and resetting the chip at
// its match. Every write to its registers must follow the two access keys.
module urt.driver.bl808.watchdog;

import core.volatile : volatileLoad, volatileStore;

nothrow @nogc:

enum uint wdt_max_ms = 0xFFFF * 1000 / tick_hz;

void wdt_start(uint timeout_ms)
{
    unlock();
    write(wmer, 0);
    write(tccr, (read(tccr) & ~(0xFu << 8)) | clk_32k << 8);
    write(tcdr, (read(tcdr) & ~(0xFFu << 24)) | (32_768 / tick_hz - 1) << 24);
    immutable uint ms = timeout_ms < wdt_max_ms ? timeout_ms : wdt_max_ms;
    unlock();
    write(wmr, (read(wmr) & ~0x1_FFFF) | ms * tick_hz / 1000);
    wdt_feed();
    unlock();
    write(wmer, enable | reset_on_match);
}

void wdt_feed()
{
    unlock();
    write(wcr, 1);
}

void wdt_stop()
{
    unlock();
    write(wmer, 0);
}

private:

enum uint tick_hz = 1024;

enum uint timer_base = 0x2000_A500;
enum uint tccr = timer_base + 0x00;
enum uint wmer = timer_base + 0x64;
enum uint wmr  = timer_base + 0x68;
enum uint wcr  = timer_base + 0x98;
enum uint wfar = timer_base + 0x9C;
enum uint wsar = timer_base + 0xA0;
enum uint tcdr = timer_base + 0xBC;

enum uint clk_32k = 1;
enum uint enable = 1 << 0;
enum uint reset_on_match = 1 << 1;

uint read(uint reg)
    => volatileLoad(cast(uint*)reg);

void write(uint reg, uint value)
{
    volatileStore(cast(uint*)reg, value);
}

void unlock()
{
    write(wfar, 0xBABA);
    write(wsar, 0xEB10);
}
