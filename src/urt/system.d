module urt.system;

import urt.mem.pressure : MaxUsagePools, sample_pool_usage;
import urt.platform;
import urt.processor;
import urt.time;

version (Espressif)
{
    enum uint MALLOC_CAP_8BIT      = 1 << 2;
    enum uint MALLOC_CAP_SPIRAM    = 1 << 10;
    enum uint MALLOC_CAP_INTERNAL  = 1 << 11;
    enum uint MALLOC_CAP_IRAM_8BIT = 1 << 13;

    version (Iram8BitSlowMemory)
    {
        enum uint slow_memory_caps = MALLOC_CAP_IRAM_8BIT;
        enum string slow_memory_name = "IRAM";
    }
    else
    {
        enum uint slow_memory_caps = MALLOC_CAP_SPIRAM;
        enum string slow_memory_name = "PSRAM";
    }

    extern(C) nothrow @nogc
    {
        size_t heap_caps_get_total_size(uint caps);
        size_t heap_caps_get_free_size(uint caps);
        size_t heap_caps_get_minimum_free_size(uint caps);
        size_t heap_caps_get_largest_free_block(uint caps);
    }
}

nothrow @nogc:


enum IdleParams : ubyte
{
    system_required = 1,     // stop the system from going to sleep
    display_required = 2,    // keep the display turned on
}

extern(C) noreturn abort();
extern(C) noreturn exit(int status);

void sleep(Duration duration)
{
//    enum Duration spinThreshold = 10.msecs;
//    if (duration < spinThreshold)
//    {
//        // spin lock...
//    }

    version (Windows)
    {
        import urt.internal.sys.windows.winbase : Sleep;
        Sleep(cast(uint)duration.as!"msecs");
    }
    else version (Embedded)
    {
        import urt.driver.timer;
        import urt.driver.irq;

        static if (has_mtime)
        {
            ulong deadline = mtime_read() + duration.as!"usecs";
            static if (has_oneshot_timer && has_wait_for_interrupt)
            {
                mtimecmp_write_oneshot(deadline);
                auto was_enabled = enable_irq(IrqClass.timer);
                while (mtime_read() < deadline)
                    wait_for_interrupt();
                if (!was_enabled)
                    disable_irq(IrqClass.timer);
            }
            else
            {
                while (mtime_read() < deadline) {}
            }
        }
    }
    else
    {
        usleep(cast(uint)duration.as!"usecs");
    }
}

struct MemoryPool
{
    string name;        // short label ("RAM", "TCM", "SRAM", "PSRAM", ...)
    ulong total;        // capacity in bytes (0 means slot unused)
    ulong used;         // currently allocated
    ulong peak_used;    // high-water mark of used (0 if unavailable)
    ulong largest_free; // largest contiguous allocatable block (0 if unknown)
    ulong low;          // interval watermarks; only sample_memory_watermarks() fills these
    ulong high;
}

enum MaxMemoryPools = 4;
static assert(MaxMemoryPools <= MaxUsagePools, "the allocator tracks fewer pools than sysinfo reports");

struct SystemInfo
{
    string os_name;
    string processor;
    MemoryPool[MaxMemoryPools] pools;  // unused slots have total == 0
    Duration uptime;
}

SystemInfo get_sysinfo()
{
    SystemInfo r;
    r.os_name = Platform;
    r.processor = ProcessorName;
    version (Windows)
    {
        r.pools[0].name = "RAM";
        MEMORYSTATUSEX mem;
        mem.dwLength = MEMORYSTATUSEX.sizeof;
        if (GlobalMemoryStatusEx(&mem))
            r.pools[0].total = mem.ullTotalPhys;
        PROCESS_MEMORY_COUNTERS pmc;
        pmc.cb = PROCESS_MEMORY_COUNTERS.sizeof;
        if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, pmc.sizeof))
        {
            r.pools[0].used = pmc.WorkingSetSize;          // process resident
            r.pools[0].peak_used = pmc.PeakWorkingSetSize; // peak resident
        }
        r.uptime = msecs(GetTickCount64());
    }
    else version (linux)
    {
        import core.sys.linux.sys.sysinfo;

        sysinfo_ info;
        if (sysinfo(&info) < 0)
            assert(false, "sysinfo() failed!");

        r.pools[0].name = "RAM";
        r.pools[0].total = info.totalram * cast(ulong)info.mem_unit;

        // mallinfo2 gives heap-precise bytes-in-use; VmHWM is peak resident
        // (process-level, includes code/libs/stack but glibc has no peak-heap
        // counter so it's the tightest available proxy).
        Mallinfo2 mi = mallinfo2();
        r.pools[0].used = mi.uordblks + mi.hblkhd;
        r.pools[0].peak_used = read_proc_self_field("VmHWM:");

        r.uptime = seconds(info.uptime);
    }
    else version (Posix)
    {
        import urt.internal.sys.posix;

        int pages = sysconf(_SC_PHYS_PAGES);
        int avail = sysconf(_SC_AVPHYS_PAGES);
        int page_size = sysconf(_SC_PAGE_SIZE);

        assert(pages >= 0 && page_size >= 0, "sysconf() failed!");

        r.pools[0].name = "RAM";
        r.pools[0].total = cast(ulong)pages * page_size;
        if (avail >= 0)
            r.pools[0].used = r.pools[0].total - cast(ulong)avail * page_size;
    }
    else version (Espressif)
    {
        r.pools[0].name = "SRAM";
        enum sram_caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
        r.pools[0].total = heap_caps_get_total_size(sram_caps);
        if (r.pools[0].total > 0)
        {
            r.pools[0].used = r.pools[0].total - heap_caps_get_free_size(sram_caps);
            r.pools[0].peak_used = r.pools[0].total - heap_caps_get_minimum_free_size(sram_caps);
            r.pools[0].largest_free = heap_caps_get_largest_free_block(sram_caps);
        }

        r.pools[1].name = slow_memory_name;
        r.pools[1].total = heap_caps_get_total_size(slow_memory_caps);
        if (r.pools[1].total > 0)
        {
            r.pools[1].used = r.pools[1].total - heap_caps_get_free_size(slow_memory_caps);
            r.pools[1].peak_used = r.pools[1].total - heap_caps_get_minimum_free_size(slow_memory_caps);
            r.pools[1].largest_free = heap_caps_get_largest_free_block(slow_memory_caps);
        }

        r.uptime = get_app_time();
    }
    else version (Bouffalo)
    {
        import urt.driver.bl_common.alloc : num_pools, query_pool_stats, PoolStats;
        import urt.string : c_string;

        foreach (i; 0 .. num_pools)
        {
            PoolStats s;
            query_pool_stats(i, s);
            r.pools[i].name = s.name.c_string;
            r.pools[i].total = s.total;
            r.pools[i].used = s.used;
            r.pools[i].peak_used = s.peak_used;
            r.pools[i].largest_free = s.largest_free;
        }
        r.uptime = get_app_time();
    }
    return r;
}

// The least and greatest usage the allocator saw between this call and the previous one, which
// is where a transient spike or a creeping floor shows itself -- a once-a-second reading of
// `used` walks straight past both. Reading re-arms the interval, so exactly one caller owns the
// cadence. Where the allocator owns the pool outright (the embedded targets) the watermarks
// follow `used`; elsewhere they follow urt's own heap total, which `used` does not report.
void sample_memory_watermarks(ref SystemInfo info)
{
    foreach (i, ref p; info.pools)
    {
        size_t low, high;
        sample_pool_usage(i, low, high);
        p.low = low;
        p.high = high;
    }
}

void set_system_idle_params(IdleParams params)
{
    version (Windows)
    {
        import urt.internal.sys.windows.winbase;

        enum EXECUTION_STATE ES_SYSTEM_REQUIRED = 0x00000001;
        enum EXECUTION_STATE ES_DISPLAY_REQUIRED = 0x00000002;
        enum EXECUTION_STATE ES_CONTINUOUS = 0x80000000;

        SetThreadExecutionState(ES_CONTINUOUS | ((params & IdleParams.system_required) ? ES_SYSTEM_REQUIRED : 0) | ((params & IdleParams.display_required) ? ES_DISPLAY_REQUIRED : 0));
    }
    else version (Posix)
    {
        // TODO: ...we're not likely to run on a POSIX desktop system any time soon...
    }
    else version (FreeStanding)
    {
        // Bare-metal: no idle state management needed
    }
    else
        static assert(0, "Not implemented");
}

// `reference` is when the loop went idle and the wake is now, so everything between the two
// is idle and everything since the previous wake was busy.
void count_system_load(MonoTime reference)
{
    import urt.util : log2;
    enum shift = log2(cpu_bucket_len);
    enum uint offset_mask = cpu_bucket_len - 1;

    ulong idle_from = (reference - MonoTime()).as!"usecs";
    ulong idle_to = (get_time() - MonoTime()).as!"usecs";

    // Roll to where the idle span begins before crediting anything. The busy stretch since the
    // previous wake can itself cross a boundary, and the buckets it crossed hold no idle at
    // all; measuring the span from `reference` alone leaves the ring pointing wherever it was
    // and dumps this idle into a bucket that has already closed, taking it over capacity.
    roll_cpu_buckets(idle_from >> shift, 0);

    uint from_offset = idle_from & offset_mask;
    uint to_offset = idle_to & offset_mask;
    if ((idle_to >> shift) == g_bucket_base)
    {
        g_cpu_time[g_bucket] += to_offset - from_offset;
        return;
    }

    g_cpu_time[g_bucket] += cpu_bucket_len - from_offset;
    roll_cpu_buckets(idle_to >> shift, cpu_bucket_len);     // buckets lying wholly inside the span
    g_cpu_time[g_bucket] = to_offset;
}

uint get_cpu_load()
{
    uint idle_time = 0;
    for (uint i = 0; i < cpu_counter_buckets; i++)
        if (i != g_bucket)
            idle_time += g_cpu_time[i];
    enum total_time = cpu_bucket_len*(cpu_counter_buckets - 1);
    uint cpu_time = total_time - idle_time;
    return cpu_time * 100 / total_time;
}

unittest
{
    SystemInfo info = get_sysinfo();
    assert(info.uptime > Duration.zero);

    import urt.io;
    writelnf("\nSystem: {0} - {1}", info.os_name, info.processor);
    foreach (ref p; info.pools)
    {
        if (p.total == 0)
            continue;
        writelnf("  {0}: {1}kb used / {2}kb total (peak {3}kb)",
            p.name, p.used / 1024, p.total / 1024, p.peak_used / 1024);
    }
}


package:

import urt.attribute : fast_data;

// Microsecond buckets of ~65ms. Nanoseconds put total_time near 1e9, so the percentage in
// get_cpu_load needed 64-bit arithmetic to survive its own multiply; microseconds keep a whole
// window inside 20 bits and leave the load calculation as 32-bit multiply and divide, which is
// what the 32-bit targets want.
enum uint cpu_bucket_len = 0x1_0000;
enum cpu_counter_buckets = 16;

__gshared @fast_data uint[16] g_cpu_time;
__gshared @fast_data ubyte g_bucket = 0;
// absolute bucket number sitting in g_bucket; 64 bits so it never wraps, and only ever
// shifted and compared, so a 32-bit target pays nothing for the width
__gshared @fast_data ulong g_bucket_base;

// step the ring forward to absolute bucket `to`, writing `fill` into every bucket passed over
void roll_cpu_buckets(ulong to, uint fill)
{
    ulong steps = to - g_bucket_base;
    if (steps == 0)
        return;
    if (steps > cpu_counter_buckets)
        steps = cpu_counter_buckets;
    foreach (i; 0 .. steps)
    {
        g_bucket = (g_bucket + 1) & (cpu_counter_buckets - 1);
        g_cpu_time[g_bucket] = fill;
    }
    g_bucket_base = to;
}

version (Bouffalo)
{
    extern(C) extern __gshared {
        void* __heap_start;
        void* __heap_end;
    }

    struct Mallinfo
    {
        size_t arena;      // total space from sbrk
        size_t ordblks;    // number of free chunks
        size_t smblks;     // unused
        size_t hblks;      // unused
        size_t hblkhd;     // unused
        size_t uordblks;   // total allocated space
        size_t fordblks;   // total free space
        size_t keepcost;   // releasable space
        size_t aordblks;   // number of allocated chunks
        size_t max_total_mem; // max total allocated space
    }
    extern(C) Mallinfo mallinfo() @nogc nothrow;

    extern(C) void* _sbrk(int incr) @nogc nothrow;

    size_t heap_len()
        => cast(size_t)&__heap_end - cast(size_t)&__heap_start;
}

version (linux)
{
    struct Mallinfo2
    {
        size_t arena;     // non-mmapped space allocated from system
        size_t ordblks;   // number of free chunks
        size_t smblks;    // number of free fastbin blocks
        size_t hblks;     // number of mmapped regions
        size_t hblkhd;    // space allocated in mmapped regions
        size_t usmblks;   // unused (historical)
        size_t fsmblks;   // space in freed fastbin blocks
        size_t uordblks;  // total allocated (in-use) space
        size_t fordblks;  // total free space
        size_t keepcost;  // top-most releasable space
    }
    extern(C) Mallinfo2 mallinfo2() nothrow @nogc;

    // Read a field from /proc/self/status, returns value in bytes (field is in kB)
    ulong read_proc_self_field(string field) nothrow @nogc
    {
        import urt.file : File, open, read, close, FileOpenMode;

        File f;
        if (!f.open("/proc/self/status", FileOpenMode.ReadExisting))
            return 0;

        char[4096] buf = void;
        size_t n;
        auto r = f.read(buf, n);
        f.close();
        if (!r || n == 0)
            return 0;

        auto content = buf[0 .. n];
        // Find field name in content
        for (size_t i = 0; i + field.length < content.length; ++i)
        {
            if (content[i .. i + field.length] == field)
            {
                // Skip whitespace after field name
                size_t j = i + field.length;
                while (j < content.length && (content[j] == ' ' || content[j] == '\t'))
                    ++j;
                // Parse number
                ulong val = 0;
                while (j < content.length && content[j] >= '0' && content[j] <= '9')
                {
                    val = val * 10 + (content[j] - '0');
                    ++j;
                }
                // /proc/self/status reports in kB
                return val * 1024;
            }
        }
        return 0;
    }
}

version (Windows)
{
    import urt.internal.sys.windows.winbase : GlobalMemoryStatusEx, GetCurrentProcess, MEMORYSTATUSEX;

    struct PROCESS_MEMORY_COUNTERS
    {
        uint cb;
        uint PageFaultCount;
        size_t PeakWorkingSetSize;
        size_t WorkingSetSize;
        size_t QuotaPeakPagedPoolUsage;
        size_t QuotaPagedPoolUsage;
        size_t QuotaPeakNonPagedPoolUsage;
        size_t QuotaNonPagedPoolUsage;
        size_t PagefileUsage;
        size_t PeakPagefileUsage;
    }

    extern(Windows) int GetProcessMemoryInfo(void* Process, PROCESS_MEMORY_COUNTERS* ppsmemCounters, uint cb) nothrow @nogc;

    pragma(lib, "psapi");

    extern(Windows) ulong GetTickCount64();

    alias _EXCEPTION_REGISTRATION_RECORD = void;
    struct NT_TIB
    {
        _EXCEPTION_REGISTRATION_RECORD* ExceptionList;
        void* StackBase;
        void* StackLimit;
        void* SubSystemTib;
        void* FiberData;
        void* ArbitraryUserPointer;
        NT_TIB* Self;
    }

    version (X86_64)
    {
        extern(C) ubyte __readgsbyte(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, GS:[ECX];
                ret;
            }
        }
        extern(C) ushort __readgsword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, GS:[ECX];
                ret;
            }
        }
        extern(C) uint __readgsdword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, GS:[ECX];
                ret;
            }
        }
        extern(C) ulong __readgsqword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov RAX, GS:[ECX];
                ret;
            }
        }

        extern(C) void __writegsbyte(uint Offset, ubyte Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], DL;
                ret;
            }
        }
        extern(C) void __writegsword(uint Offset, ushort Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], DX;
                ret;
            }
        }
        extern(C) void __writegsdword(uint Offset, uint Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], EDX;
                ret;
            }
        }
        extern(C) void __writegsqword(uint Offset, ulong Value) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov GS:[ECX], RDX;
                ret;
            }
        }
    }
    else version (X86)
    {
        extern(C) ubyte __readfsbyte(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov AL, FS:[EAX];
                ret;
            }
        }
        extern(C) ushort __readfsword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov AX, FS:[EAX];
                ret;
            }
        }
        extern(C) uint __readfsdword(uint Offset) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EAX, FS:[EAX];
                ret;
            }
        }

        extern(C) void __writefsbyte(uint Offset, ubyte Data) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EDX, [ESP + 8];
                mov FS:[EAX], DL;
                ret;
            }
        }
        extern(C) void __writefsword(uint Offset, ushort Data) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EDX, [ESP + 8];
                mov FS:[EAX], DX;
                ret;
            }
        }
        extern(C) void __writefsdword(uint Offset, uint Data) nothrow @nogc
        {
            asm nothrow @nogc {
                naked;
                mov EAX, [ESP + 4];
                mov EDX, [ESP + 8];
                mov FS:[EAX], EDX;
                ret;
            }
        }
    }
    else
        static assert(0, "TODO");
}
else
{
    extern(C) int usleep(uint usec) nothrow @nogc;
}
