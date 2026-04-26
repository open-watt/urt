module urt.system;

import urt.platform;
import urt.processor;
import urt.time;

version (Espressif)
{
    enum uint MALLOC_CAP_DEFAULT = 1 << 12;
    extern(C) nothrow @nogc
    {
        size_t heap_caps_get_total_size(uint caps);
        size_t heap_caps_get_free_size(uint caps);
        size_t heap_caps_get_minimum_free_size(uint caps);
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
            static if (has_wfi_sleep)
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

struct SystemInfo
{
    string os_name;
    string processor;
    ulong total_memory;     // total physical RAM or heap region
    ulong used_memory;      // actively allocated
    ulong reserved_memory;  // claimed from OS/sbrk (>= used, includes freed blocks)
    ulong avail_memory;     // system-wide available for new allocations
    ulong peak_memory;      // high-water mark (0 if unavailable)
    Duration uptime;
}

SystemInfo get_sysinfo()
{
    SystemInfo r;
    r.os_name = Platform;
    r.processor = ProcessorName;
    version (Windows)
    {
        MEMORYSTATUSEX mem;
        mem.dwLength = MEMORYSTATUSEX.sizeof;
        if (GlobalMemoryStatusEx(&mem))
        {
            r.total_memory = mem.ullTotalPhys;
            r.avail_memory = mem.ullAvailPhys;
        }
        PROCESS_MEMORY_COUNTERS pmc;
        pmc.cb = PROCESS_MEMORY_COUNTERS.sizeof;
        if (GetProcessMemoryInfo(GetCurrentProcess(), &pmc, pmc.sizeof))
        {
            r.reserved_memory = pmc.WorkingSetSize;      // resident pages
            r.used_memory = pmc.PagefileUsage;            // committed private bytes
            r.peak_memory = pmc.PeakWorkingSetSize;
        }
        r.uptime = msecs(GetTickCount64());
    }
    else version (linux)
    {
        import core.sys.linux.sys.sysinfo;

        sysinfo_ info;
        if (sysinfo(&info) < 0)
            assert(false, "sysinfo() failed!");

        auto unit = cast(ulong)info.mem_unit;
        r.total_memory = info.totalram * unit;
        r.avail_memory = info.freeram * unit;

        // Process-level stats from /proc/self/status
        r.reserved_memory = read_proc_self_field("VmRSS:");   // resident set
        r.used_memory = read_proc_self_field("VmSize:");       // virtual size (committed)
        r.peak_memory = read_proc_self_field("VmPeak:");
        r.uptime = seconds(info.uptime);
    }
    else version (Posix)
    {
        import urt.internal.sys.posix;

        int pages = sysconf(_SC_PHYS_PAGES);
        int avail = sysconf(_SC_AVPHYS_PAGES);
        int page_size = sysconf(_SC_PAGE_SIZE);

        assert(pages >= 0 && page_size >= 0, "sysconf() failed!");

        r.total_memory = cast(ulong)pages * page_size;
        r.avail_memory = (avail >= 0) ? cast(ulong)avail * page_size : 0;
        r.used_memory = r.total_memory - r.avail_memory;
        r.reserved_memory = r.used_memory;
    }
    else version (Espressif)
    {
        r.total_memory = heap_caps_get_total_size(MALLOC_CAP_DEFAULT);
        r.avail_memory = heap_caps_get_free_size(MALLOC_CAP_DEFAULT);
        r.used_memory = r.total_memory - r.avail_memory;
        r.peak_memory = r.total_memory - heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
        r.uptime = getAppTime();
    }
    else version (Bouffalo)
    {
        auto mi = mallinfo();
        r.total_memory = heap_len();
        r.used_memory = mi.uordblks;
        r.reserved_memory = mi.arena;
        r.avail_memory = r.total_memory - mi.arena + mi.fordblks;
        r.peak_memory = mi.max_total_mem;
        r.uptime = getAppTime();
    }
    return r;
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


unittest
{
    SystemInfo info = get_sysinfo();
    assert(info.uptime > Duration.zero);

    import urt.io;
    writelnf("System: {0} - {1}", info.os_name, info.processor);
    writelnf("  total: {0}kb  used: {1}kb  reserved: {2}kb  free: {3}kb  peak: {4}kb",
        info.total_memory / 1024, info.used_memory / 1024,
        info.reserved_memory / 1024, info.avail_memory / 1024,
        info.peak_memory / 1024);

    version (Embedded)
    {
        import urt.driver.irq;
        static if (has_irq_diagnostics)
        {
            writelnf("  IRQ total: {0}", irq_count);
            foreach (i; 0 .. irq_histogram.length)
            {
                if (irq_histogram[i] > 0)
                    writelnf("    IRQ {0}: {1}", i, irq_histogram[i]);
            }
        }
    }
}


package:

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
