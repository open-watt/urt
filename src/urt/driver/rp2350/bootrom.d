module urt.driver.rp2350.bootrom;

nothrow @nogc:

enum RebootType : uint
{
    normal  = 0x0,
    bootsel = 0x2,
}

bool rom_reboot(RebootType type, uint delay_ms = 1)
{
    alias RebootFn = extern(C) int function(uint flags, uint delay_ms, uint p0, uint p1) nothrow @nogc;

    auto fn = cast(RebootFn)rom_func_lookup(rom_code('R', 'B'));
    if (!fn)
        return false;
    // A zero delay never fires.
    return fn(type, delay_ms ? delay_ms : 1, 0, 0) >= 0;
}

bool rom_chip_info(out uint[4] info)
{
    alias SysInfoFn = extern(C) int function(uint* buffer, uint words, uint flags) nothrow @nogc;

    auto fn = cast(SysInfoFn)rom_func_lookup(rom_code('G', 'S'));
    if (!fn)
        return false;
    return fn(info.ptr, info.length, sys_info_chip_info) == int(info.length);
}

private:

enum size_t table_lookup_offset  = 0x16;
enum uint   rt_flag_func_arm_sec = 0x0004;
enum uint   sys_info_chip_info   = 0x0001;

void* rom_func_lookup(ushort code)
{
    alias LookupFn = extern(C) void* function(uint code, uint flags) nothrow @nogc;

    auto lookup = cast(LookupFn)size_t(*cast(const(ushort)*)table_lookup_offset);
    return lookup ? lookup(code, rt_flag_func_arm_sec) : null;
}

ushort rom_code(char a, char b) pure => cast(ushort)(a | b << 8);
