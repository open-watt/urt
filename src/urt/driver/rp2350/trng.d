module urt.driver.rp2350.trng;

import urt.driver.rp2350 : reset_trng, unreset_wait;

import core.volatile;

nothrow @nogc:

bool trng_read(ubyte[] dst)
{
    if (dst.length == 0)
        return true;

    configure();

    while (dst.length)
    {
        uint[ehr_words] ehr = void;
        if (!collect(ehr))
            return false;

        const n = dst.length < ehr.sizeof ? dst.length : ehr.sizeof;
        foreach (i; 0 .. n)
            dst[i] = cast(ubyte)(ehr[i >> 2] >> (8 * (i & 3)));
        dst = dst[n .. $];
    }
    return true;
}

private:

enum ulong trng_base         = 0x400F_0000;

enum ulong rng_isr           = trng_base + 0x104;
enum ulong rng_icr           = trng_base + 0x108;
enum ulong trng_config       = trng_base + 0x10C;
enum ulong ehr_data0         = trng_base + 0x114;
enum ulong rnd_source_enable = trng_base + 0x12C;
enum ulong sample_cnt1       = trng_base + 0x130;
enum ulong trng_debug_control = trng_base + 0x138;
enum ulong trng_sw_reset     = trng_base + 0x140;
enum ulong trng_busy         = trng_base + 0x1B8;

enum uint isr_ehr_valid     = 1 << 0;
enum uint isr_autocorr_err  = 1 << 1;
enum uint isr_crngt_err     = 1 << 2;
enum uint isr_vn_err        = 1 << 3;
enum uint isr_all           = 0xF;
enum uint isr_errors        = isr_autocorr_err | isr_crngt_err | isr_vn_err;

enum size_t ehr_words = 6;

// TODO: Characterize entropy and latency before reducing the reset sample interval.
enum uint sample_interval = 0xFFFF;

enum uint busy_spins = 64_000_000;

void write(ulong addr, uint val) => volatileStore(cast(uint*)addr, val);
uint read(ulong addr) => volatileLoad(cast(uint*)addr);

void configure()
{
    unreset_wait(reset_trng);
    write(trng_sw_reset, 1);
    write(trng_debug_control, 0);
    write(trng_config, 0);
    write(sample_cnt1, sample_interval);
}

bool collect(ref uint[ehr_words] ehr)
{
    write(rng_icr, isr_all);
    write(rnd_source_enable, 1);

    uint spins = busy_spins;
    while (read(trng_busy))
    {
        if (--spins == 0)
        {
            write(rnd_source_enable, 0);
            return false;
        }
    }

    const isr = read(rng_isr);
    write(rnd_source_enable, 0);

    if ((isr & isr_errors) || !(isr & isr_ehr_valid))
    {
        configure();
        return false;
    }

    foreach (i; 0 .. ehr_words)
        ehr[i] = read(ehr_data0 + i * 4);
    return true;
}
