module urt.driver.reset;

import urt.attribute : has_persist, persist, used;

nothrow @nogc:


// A `running` mark left in place means the run ended without reaching a handler: a watchdog or hang.
enum ResetMark : ubyte
{
    none,           // no valid record: RAM was lost, or the platform has no retained memory
    running,
    deliberate,
    crashed,
}

enum bool has_reset_record = has_persist;

// Call early in boot: returns the previous run's mark and stamps this one as running.
ResetMark reset_record_take()
{
    static if (has_reset_record)
    {
        ResetRecord* r = record();
        ResetMark m = r.valid ? cast(ResetMark)r.mark : ResetMark.none;
        if (m == ResetMark.none)
            r.scratch[] = 0;
        r.set(ResetMark.running);
        return m;
    }
    else
        return ResetMark.none;
}

// Safe from a fault handler: a store and no calls.
void reset_record_mark(ResetMark m)
{
    static if (has_reset_record)
        record().set(m);
}

// Reset the part. For fault paths with nowhere to return to; hanging there leaves a dead board
// that no watchdog is arming and no boot guard can count.
version (RP2350)        enum bool has_system_reset = true;
else version (STM32)    enum bool has_system_reset = true;
else version (Beken)    enum bool has_system_reset = true;
else                    enum bool has_system_reset = false;

version (RP2350) version = CortexM;
else version (STM32) version = CortexM;

noreturn system_reset()
{
    import core.volatile : volatileLoad, volatileStore;

    version (CortexM)
    {
        asm @nogc nothrow { "dsb sy" ::: "memory"; }
        volatileStore(cast(uint*)0xE000ED0C, 0x05FA_0004);    // AIRCR SYSRESETREQ
        asm @nogc nothrow { "dsb sy" ::: "memory"; }
    }
    else version (Beken)
    {
        import urt.driver.irq : irq_global_disable;

        irq_global_disable();
        enum uint icu_peri_clk_pwd = 0x0080_2008;
        enum uint wdt_clk_pwd = 1 << 8;
        volatileStore(cast(uint*)icu_peri_clk_pwd, volatileLoad(cast(uint*)icu_peri_clk_pwd) | wdt_clk_pwd);
        // Watchdog control, key-sequenced: 0x5A then 0xA5 in [23:16], period in [15:0].
        enum uint wdt_ctrl = 0x0080_2900;
        volatileStore(cast(uint*)wdt_ctrl, 0x005A_0010);
        volatileStore(cast(uint*)wdt_ctrl, 0x00A5_0010);
        volatileStore(cast(uint*)icu_peri_clk_pwd, volatileLoad(cast(uint*)icu_peri_clk_pwd) & ~wdt_clk_pwd);
    }

    for (;;)
    {}
}

// Two bytes that ride with the record: kept while RAM is kept, zeroed when it was lost.
ubyte[] reset_record_scratch()
{
    static if (has_reset_record)
        return record().scratch[];
    else
        return null;
}


private:

static if (has_reset_record)
{
    struct ResetRecord
    {
    nothrow @nogc:
        enum uint magic_value = 0x5453_5257; // "WRST"

        uint magic;
        ubyte mark;
        ubyte check;
        ubyte[2] scratch;

        bool valid() const => magic == magic_value && check == cast(ubyte)~mark && mark <= ResetMark.crashed;

        void set(ResetMark m)
        {
            mark = m;
            check = cast(ubyte)~m;
            magic = magic_value;
        }
    }

    version (Bouffalo)
    {
        // The BL808 cores share HBN RAM and hbn.d keys its struct to the start of .hbn_ram by
        // link order, so the record takes a fixed slot at the top instead: one per core.
        enum size_t hbn_top = 0x2001_1000;
        version (BL808_M0) enum size_t record_address = hbn_top - 2 * ResetRecord.sizeof;
        else               enum size_t record_address = hbn_top - ResetRecord.sizeof;
        ResetRecord* record() => cast(ResetRecord*)record_address;
    }
    else
    {
        @persist @used __gshared ResetRecord _record;
        ResetRecord* record() => &_record;
    }
}
