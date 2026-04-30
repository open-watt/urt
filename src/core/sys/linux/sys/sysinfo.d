// uRT shim for druntime's core.sys.linux.sys.sysinfo binding.
//
// urt.system imports this when version (linux) to read total/free memory
// and uptime via the glibc sysinfo(2) syscall wrapper. Mirror just the
// struct fields and function signature uRT actually uses.
module core.sys.linux.sys.sysinfo;

extern(C) @nogc nothrow:

struct sysinfo_
{
    long uptime;
    ulong[3] loads;
    ulong totalram;
    ulong freeram;
    ulong sharedram;
    ulong bufferram;
    ulong totalswap;
    ulong freeswap;
    ushort procs;
    ushort pad;
    ulong totalhigh;
    ulong freehigh;
    uint mem_unit;
    char[20 - 2 * (ulong.sizeof) - 4] _f;
}

int sysinfo(sysinfo_* info);
