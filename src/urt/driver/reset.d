module urt.driver.reset;

import urt.attribute : has_persist, persist, used;

nothrow @nogc:


// A `running` mark left in place means the run ended without reaching a handler: a watchdog or hang.
enum ResetMark : ubyte
{
    none,           // no valid record: retained memory was lost, or the platform has none
    running,
    deliberate,
    crashed,
    updated,        // the record was left by another build: a firmware update
}

enum ResetCause : ubyte
{
    unknown,        // the hardware keeps no cause, or none it reports
    power,          // power-on or brownout
    pin,            // the reset line alone
    software,
    watchdog,
}

enum bool has_reset_record = has_persist;

// Runs before anything reads @persist: another build's record reads `updated`, its floating @persist is zeroed.
void reset_record_begin()
{
    static if (has_reset_record)
    {
        import core.volatile : volatileLoad, volatileStore;
        import urt.build : build_id;
        import urt.hash : fnv1a;

        enum uint build = fnv1a(cast(const(ubyte)[])build_id);
        immutable uint layout = persist_layout();
        ResetRecord* r = record();
        immutable uint old_build = volatileLoad(&r.build);
        if (old_build == build && volatileLoad(&r.layout) == layout)
            return;

        zero_floating_persist(r);
        if (r.valid && old_build != build)
            r.set(ResetMark.updated, [0, 0]);
        volatileStore(&r.build, build);
        volatileStore(&r.layout, layout);
    }
}

// The previous run's mark. The first call stamps this run as running; later ones repeat the
// answer, so boot order between callers does not matter.
ResetMark reset_record_take()
{
    static if (has_reset_record)
    {
        if (!_taken)
        {
            _taken = true;
            reset_record_begin();
            ResetRecord* r = record();
            _mark = r.valid ? r.mark : ResetMark.none;
            if (_mark == ResetMark.none)
                r.set(ResetMark.running, [0, 0]);
            else
                r.set(ResetMark.running);
        }
        return _mark;
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
else version (MT7621)   enum bool has_system_reset = true;
else                    enum bool has_system_reset = false;

version (STM32) version = CortexM;

noreturn system_reset()
{
    import core.volatile : volatileLoad, volatileStore;

    version (RP2350)
    {
        // A core reset leaves the peripherals configured, so the watchdog resets the chip as the ROM's reboot()
        // does, without the parameters it leaves in SCRATCH2-3.
        import urt.driver.rp2350 : mmio_write, watchdog_base, watchdog_reset_all;
        watchdog_reset_all();
        mmio_write(watchdog_base, 1u << 31);
    }
    else version (CortexM)
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

    else version (MT7621)
    {
        import urt.driver.mt7621 : mmio_write, sysctl_base, sysc_rstctrl;
        mmio_write(sysctl_base + sysc_rstctrl, 1);
    }

    for (;;)
    {}
}

// Read once: the hardware latches its cause across later resets until it is cleared.
ResetCause reset_cause()
{
    version (STM32)
    {
        import urt.driver.stm32 : rcc_reset_cause;
        return rcc_reset_cause();
    }
    else version (MT7621)
    {
        import urt.driver.mt7621.watchdog : reset_by_watchdog;
        return reset_by_watchdog() ? ResetCause.watchdog : ResetCause.unknown;
    }
    else version (RP2350)
    {
        import urt.driver.rp2350.watchdog : watchdog_reset_cause;
        return watchdog_reset_cause();
    }
    else
        return ResetCause.unknown;
}

// Two bytes that ride with the record, zeroed when retained memory was lost or another build took over.
ubyte[2] reset_record_scratch()
{
    static if (has_reset_record)
        return RecordWord(record()).scratch;
    else
        return [0, 0];
}

void reset_record_scratch(ubyte[2] value)
{
    static if (has_reset_record)
    {
        ResetRecord* r = record();
        RecordWord w = RecordWord(r);
        w.scratch = value;
        w.store(r);
    }
}


private:

static if (has_reset_record)
{
    __gshared bool _taken;
    __gshared ResetMark _mark;

    // Every field is a whole word, and every access a whole-word volatile load or store: the record
    // may live in ECC RAM that drops a partial write at reset, or in peripheral registers.
    struct ResetRecord
    {
    nothrow @nogc:
        enum uint magic_value = 0x5453_5257; // "WRST"

        uint magic;
        uint word;          // RecordWord: mark, check, scratch
        uint build;         // fnv1a of the build_id that last took the record
        uint layout;        // persist_layout() of that build

        bool valid() const
        {
            import core.volatile : volatileLoad;
            RecordWord w = RecordWord(&this);
            return volatileLoad(cast(uint*)&magic) == magic_value && w.check == cast(ubyte)~w.mark && w.mark <= ResetMark.updated;
        }

        ResetMark mark() const => cast(ResetMark)RecordWord(&this).mark;

        void set(ResetMark m)
        {
            RecordWord w = RecordWord(&this);
            w.mark = m;
            w.check = cast(ubyte)~m;
            w.store(&this);
            store_magic();
        }

        void set(ResetMark m, ubyte[2] scratch)
        {
            RecordWord w;
            w.mark = m;
            w.check = cast(ubyte)~m;
            w.scratch = scratch;
            w.store(&this);
            store_magic();
        }

        private void store_magic()
        {
            import core.volatile : volatileStore;
            volatileStore(&magic, magic_value);
        }
    }

    union RecordWord
    {
    nothrow @nogc:
        struct
        {
            ubyte mark;
            ubyte check;
            ubyte[2] scratch;
        }
        uint word;

        this(const(ResetRecord)* r)
        {
            import core.volatile : volatileLoad;
            word = volatileLoad(cast(uint*)&r.word);
        }

        void store(ResetRecord* r) const
        {
            import core.volatile : volatileStore;
            volatileStore(&r.word, word);
        }
    }

    static assert(ResetRecord.sizeof == 16);

    version (Bouffalo)
    {
        // The BL808 cores share HBN RAM and hbn.d keys its struct to the start of .hbn_ram by
        // link order, so the record takes a fixed slot at the top instead: one per core.
        enum size_t hbn_top = 0x2001_1000;
        version (BL808_M0) enum size_t record_address = hbn_top - 2 * ResetRecord.sizeof;
        else               enum size_t record_address = hbn_top - ResetRecord.sizeof;
        ResetRecord* record() => cast(ResetRecord*)record_address;
    }
    else version (Espressif)
    {
        // IDF lays out RTC memory, so the record floats with the image and the stamps guard it.
        @persist @used __gshared ResetRecord _record;
        ResetRecord* record() => &_record;
    }
    else
    {
        // The linker script pins it where every build agrees.
        extern(C) extern __gshared ResetRecord __reset_record;
        ResetRecord* record() => &__reset_record;
    }

    version (ESP32_C2)
        extern(C) extern __gshared ubyte _noinit_start, _noinit_end;
    else version (Espressif)
        extern(C) extern __gshared ubyte _rtc_noinit_start, _rtc_noinit_end;
    else version (Bouffalo) {}
    else
        extern(C) extern __gshared ubyte _persist_start, _persist_end;

    ubyte[] floating_persist()
    {
        version (ESP32_C2)
            return (&_noinit_start)[0 .. &_noinit_end - &_noinit_start];
        else version (Espressif)
            return (&_rtc_noinit_start)[0 .. &_rtc_noinit_end - &_rtc_noinit_start];
        else version (Bouffalo)
            return null;    // the BL808 cores share HBN RAM, so neither may zero it; hbn.d validates its own
        else
            return (&_persist_start)[0 .. &_persist_end - &_persist_start];
    }

    uint persist_layout()
    {
        import urt.hash : fnv1a;
        ubyte[] p = floating_persist();
        size_t[2] bounds = [cast(size_t)p.ptr, p.length];
        return fnv1a(cast(const(ubyte)[])bounds[]);
    }

    void zero_floating_persist(const(ResetRecord)* keep)
    {
        ubyte[] p = floating_persist();
        size_t at = cast(const(ubyte)*)keep - p.ptr;
        if (at < p.length)
        {
            p[0 .. at] = 0;
            p[at + ResetRecord.sizeof .. $] = 0;
        }
        else
            p[] = 0;
    }
}
