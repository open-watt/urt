// STM32 hardware RNG. F4/F7 clock it from PLLQ at 48 MHz, H7 from HSI48; sys_init starts both.
module urt.driver.stm32.trng;

import urt.driver.stm32 : clock_enable, rcc_ahb2enr, reg_read, reg_write;

nothrow @nogc:

bool trng_read(ubyte[] dst)
{
    if (!_enabled)
    {
        clock_enable(rcc_ahb2enr, 6);
        restart();
        _enabled = true;
    }

    while (dst.length)
    {
        uint word;
        if (!next(word))
            return false;
        const n = dst.length < 4 ? dst.length : 4;
        foreach (i; 0 .. n)
            dst[i] = cast(ubyte)(word >> (8 * i));
        dst = dst[n .. $];
    }
    return true;
}


private:

version (STM32H7)
    enum ulong rng_base = 0x4802_1800;
else
    enum ulong rng_base = 0x5006_0800;

enum ulong rng_cr = rng_base + 0x00;
enum ulong rng_sr = rng_base + 0x04;
enum ulong rng_dr = rng_base + 0x08;

enum uint cr_rngen = 1 << 2;
enum uint sr_drdy  = 1 << 0;
enum uint sr_cecs  = 1 << 1;
enum uint sr_secs  = 1 << 2;
enum uint sr_ceis  = 1 << 5;
enum uint sr_seis  = 1 << 6;

enum uint ready_spins = 1_000_000;

__gshared bool _enabled;
__gshared uint _last;

// The first word after enable is never handed out; it primes the repetition check.
void restart()
{
    reg_write(rng_cr, 0);
    reg_write(rng_sr, 0);
    reg_write(rng_cr, cr_rngen);
    uint word;
    raw(word);
    _last = word;
}

bool raw(out uint word)
{
    foreach (i; 0 .. ready_spins)
    {
        uint sr = reg_read(rng_sr);
        if (sr & (sr_secs | sr_cecs | sr_seis | sr_ceis))
            return false;
        if (sr & sr_drdy)
        {
            word = reg_read(rng_dr);
            return true;
        }
    }
    return false;
}

bool next(out uint word)
{
    foreach (attempt; 0 .. 2)
    {
        if (raw(word) && word != _last)
        {
            _last = word;
            return true;
        }
        restart();
    }
    return false;
}
