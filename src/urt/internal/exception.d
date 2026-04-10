/**
 * D exception handling — throw, catch, finally.
 *
 * Ported from druntime for use in uRT.
 * Two implementations:
 *   - Win32 (x86): SEH-based, ported from rt/deh_win32.d
 *   - Win64/POSIX (x86_64): RBP-chain walking, ported from rt/deh_win64_posix.d
 *
 * Copyright: Digital Mars 1999-2013 (original), uRT authors (port).
 * License: Boost Software License 1.0
 */
module urt.internal.exception;

// No top-level gate — individual version blocks guard platform-specific code.

// ══════════════════════════════════════════════════════════════════════
// Shared declarations
// ══════════════════════════════════════════════════════════════════════

alias ClassInfo = TypeInfo_Class;

extern(C) int _d_isbaseof(scope ClassInfo oc, scope const ClassInfo c) nothrow @nogc pure @trusted
{
    if (oc is c)
        return true;

    do
    {
        if (oc.base is c)
            return true;

        foreach (iface; oc.interfaces)
        {
            if (iface.classinfo is c || _d_isbaseof(iface.classinfo, c))
                return true;
        }

        oc = oc.base;
    }
    while (oc);

    return false;
}

// Thread-local trace buffer. _d_createTrace captures here silently;
// terminate() and _d_printLastTrace() read it back for display.
private struct StackTraceData
{
    void*[32] addrs;
    ubyte length;
}

private StackTraceData _tls_trace;  // static = TLS in D

extern(C) void _d_createTrace(Throwable t, void*) nothrow @nogc @trusted
{
    // Capture return addresses into the TLS buffer. No output —
    // the trace is only printed on unhandled exceptions (terminate)
    // or when explicitly requested via _d_printLastTrace().
    debug
    {
        _tls_trace.length = 0;

        version (Windows)
        {
            auto n = rtlCaptureStackBackTrace(2, 32, _tls_trace.addrs.ptr, null);
            if (n == 0)
                n = cast(ushort) stack_walk64_capture(_tls_trace.addrs);
            _tls_trace.length = cast(ubyte) n;
        }
        else version (D_InlineAsm_X86_64)
        {
            size_t bp;
            asm nothrow @nogc { mov bp, RBP; }

            ubyte n = 0;
            foreach (_; 0 .. 32)
            {
                if (!bp)
                    break;
                auto next_bp = *cast(size_t*) bp;
                if (!next_bp || next_bp <= bp)
                    break;
                auto retaddr = *cast(void**)(bp + size_t.sizeof);
                if (!retaddr)
                    break;
                _tls_trace.addrs[n++] = retaddr;
                bp = next_bp;
            }
            _tls_trace.length = n;
        }
        else version (D_InlineAsm_X86)
        {
            size_t bp;
            asm nothrow @nogc { mov bp, EBP; }

            ubyte n = 0;
            foreach (_; 0 .. 32)
            {
                if (!bp)
                    break;
                auto next_bp = *cast(size_t*) bp;
                if (!next_bp || next_bp <= bp)
                    break;
                auto retaddr = *cast(void**)(bp + size_t.sizeof);
                if (!retaddr)
                    break;
                _tls_trace.addrs[n++] = retaddr;
                bp = next_bp;
            }
            _tls_trace.length = n;
        }
        else version (FreeStanding)
        {
            // No stack trace on bare-metal
        }
        else
        {
            // ARM, AArch64, RISC-V, etc. — use _Unwind_Backtrace
            unwind_backtrace(_tls_trace);
        }
    }
}

/// Print the stack trace from the most recent throw on this thread.
/// Safe to call from catch blocks, assert handlers, or anywhere else.
extern(C) void _d_printLastTrace(Throwable t) nothrow @nogc @trusted
{
    debug
    {
        import urt.io : writeln_err, writef_to, WriteTarget;

        if (_tls_trace.length == 0)
            return;

        if (t !is null)
        {
            auto msg = t.msg;
            writef_to!(WriteTarget.stderr, true)("Exception: {0}", msg);
        }

        writeln_err("  stack trace:");

        version (Windows)
            dbghelp_print_trace(_tls_trace.addrs[0 .. _tls_trace.length]);
        else version (FreeStanding)
        {}
        else
            posix_print_trace(_tls_trace.addrs[0 .. _tls_trace.length]);
    }
}

// ── Stack trace support (Windows, debug only) ────────────────────────
//
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: DbgHelp is NOT thread-safe. All calls to SymFromAddr,
// SymGetLineFromAddr64, SymInitialize, and StackWalk64 must be
// serialized with a CRITICAL_SECTION (or equivalent) once this
// program uses threads. Without this, concurrent exceptions from
// multiple threads WILL crash or corrupt DbgHelp's internal state.
// Both DMD and LDC druntime protect all DbgHelp access with a mutex.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//
version (Windows) debug
{
    // --- DbgHelp types ---------------------------------------------------

    private struct SYMBOL_INFOA
    {
        uint SizeOfStruct;
        uint TypeIndex;
        ulong[2] Reserved;
        uint Index;
        uint Size;
        ulong ModBase;
        uint Flags;
        ulong Value;
        ulong Address;
        uint Register;
        uint Scope;
        uint Tag;
        uint NameLen;
        uint MaxNameLen;
        char[1] Name; // variable-length
    }

    private struct IMAGEHLP_LINEA64
    {
        uint SizeOfStruct;
        void* Key;
        uint LineNumber;
        const(char)* FileName;
        ulong Address;
    }

    // --- StackWalk64 types -----------------------------------------------

    private alias HANDLE = void*;
    private enum AddrModeFlat = 3;

    private struct ADDRESS64
    {
        ulong Offset;
        ushort Segment;
        uint Mode;
    }

    private struct STACKFRAME64
    {
        ADDRESS64 AddrPC;
        ADDRESS64 AddrReturn;
        ADDRESS64 AddrFrame;
        ADDRESS64 AddrStack;
        ADDRESS64 AddrBStore;
        void* FuncTableEntry;
        ulong[4] Params;
        int Far;
        int Virtual;
        ulong[3] Reserved;
        ubyte[96] KdHelp; // KDHELP64, opaque
    }

    // CONTEXT — opaque aligned buffer, accessed via offset constants.
    version (Win64)
    {
        private enum CONTEXT_SIZE  = 1232;
        private enum CTX_FLAGS_OFF = 48;
        private enum CTX_IP_OFF    = 248;  // Rip
        private enum CTX_SP_OFF    = 152;  // Rsp
        private enum CTX_FP_OFF    = 160;  // Rbp
        private enum CTX_FULL      = 0x10000B;
        private enum MACHINE_TYPE  = 0x8664; // IMAGE_FILE_MACHINE_AMD64
    }
    else
    {
        private enum CONTEXT_SIZE  = 716;
        private enum CTX_FLAGS_OFF = 0;
        private enum CTX_IP_OFF    = 184;  // Eip
        private enum CTX_SP_OFF    = 196;  // Esp
        private enum CTX_FP_OFF    = 180;  // Ebp
        private enum CTX_FULL      = 0x10007;
        private enum MACHINE_TYPE  = 0x014C; // IMAGE_FILE_MACHINE_I386
    }

    // --- Function pointer types ------------------------------------------

    extern (Windows) nothrow @nogc
    {
        private alias SymInitializeFn        = int  function(HANDLE, const(char)*, int);
        private alias SymSetOptionsFn        = uint function(uint);
        private alias SymFromAddrFn          = int  function(HANDLE, ulong, ulong*, SYMBOL_INFOA*);
        private alias SymGetLineFromAddr64Fn = int  function(HANDLE, ulong, uint*, IMAGEHLP_LINEA64*);
        private alias FuncTableAccessFn      = void* function(HANDLE, ulong);
        private alias GetModuleBaseFn        = ulong function(HANDLE, ulong);
        private alias StackWalk64Fn          = int  function(
            uint machineType, HANDLE hProcess, HANDLE hThread,
            STACKFRAME64* stackFrame, void* contextRecord,
            void* readMemory, FuncTableAccessFn funcTableAccess,
            GetModuleBaseFn getModuleBase, void* translateAddress);
    }

    // --- Globals ---------------------------------------------------------

    private __gshared bool _dbg_inited;
    private __gshared bool _dbg_available;
    private __gshared HANDLE _dbg_process;
    private __gshared SymFromAddrFn _sym_from_addr;
    private __gshared SymGetLineFromAddr64Fn _sym_get_line;
    private __gshared StackWalk64Fn _stack_walk64;
    private __gshared FuncTableAccessFn _func_table_access64;
    private __gshared GetModuleBaseFn _get_module_base64;

    // --- Initialization --------------------------------------------------

    private void dbghelp_init() nothrow @nogc @trusted
    {
        if (_dbg_inited)
            return;
        _dbg_inited = true;

        auto hDbg = loadLibraryA("dbghelp.dll");
        if (hDbg is null)
            return;

        auto sym_init   = cast(SymInitializeFn)        getProcAddress(hDbg, "SymInitialize");
        auto sym_set_opt = cast(SymSetOptionsFn)        getProcAddress(hDbg, "SymSetOptions");
        _sym_from_addr   = cast(SymFromAddrFn)          getProcAddress(hDbg, "SymFromAddr");
        _sym_get_line    = cast(SymGetLineFromAddr64Fn) getProcAddress(hDbg, "SymGetLineFromAddr64");
        _stack_walk64   = cast(StackWalk64Fn)          getProcAddress(hDbg, "StackWalk64");
        _func_table_access64 = cast(FuncTableAccessFn)  getProcAddress(hDbg, "SymFunctionTableAccess64");
        _get_module_base64   = cast(GetModuleBaseFn)    getProcAddress(hDbg, "SymGetModuleBase64");

        if (sym_init is null || sym_set_opt is null || _sym_from_addr is null)
            return;

        // SYMOPT_DEFERRED_LOAD | SYMOPT_LOAD_LINES
        sym_set_opt(0x00000004 | 0x00000010);

        _dbg_process = cast(HANDLE) cast(size_t)-1; // GetCurrentProcess() pseudo-handle
        if (!sym_init(_dbg_process, null, 1)) // fInvadeProcess = TRUE
            return;

        _dbg_available = true;
    }

    // --- Kernel32/ntdll imports ------------------------------------------

    pragma(mangle, "LoadLibraryA")
    extern (Windows) private void* loadLibraryA(const(char)*) nothrow @nogc;

    pragma(mangle, "GetProcAddress")
    extern (Windows) private void* getProcAddress(void*, const(char)*) nothrow @nogc;

    pragma(mangle, "RtlCaptureStackBackTrace")
    extern (Windows) private ushort rtlCaptureStackBackTrace(
        uint FramesToSkip, uint FramesToCapture, void** BackTrace, uint* BackTraceHash) nothrow @nogc;

    pragma(mangle, "RtlCaptureContext")
    extern (Windows) private void rtlCaptureContext(void* contextRecord) nothrow @nogc;

    pragma(mangle, "GetCurrentThread")
    extern (Windows) private HANDLE getCurrentThread() nothrow @nogc;

    // --- StackWalk64 fallback --------------------------------------------

    private size_t stack_walk64_capture(ref void*[32] addrs) nothrow @nogc @trusted
    {
        dbghelp_init();

        if (_stack_walk64 is null || _func_table_access64 is null || _get_module_base64 is null)
            return 0;

        align(16) ubyte[CONTEXT_SIZE] ctx = 0;
        *cast(uint*)(ctx.ptr + CTX_FLAGS_OFF) = CTX_FULL;
        rtlCaptureContext(ctx.ptr);

        STACKFRAME64 sf;
        version (Win64)
        {
            sf.AddrPC.Offset    = *cast(ulong*)(ctx.ptr + CTX_IP_OFF);
            sf.AddrFrame.Offset = *cast(ulong*)(ctx.ptr + CTX_FP_OFF);
            sf.AddrStack.Offset = *cast(ulong*)(ctx.ptr + CTX_SP_OFF);
        }
        else
        {
            sf.AddrPC.Offset    = *cast(uint*)(ctx.ptr + CTX_IP_OFF);
            sf.AddrFrame.Offset = *cast(uint*)(ctx.ptr + CTX_FP_OFF);
            sf.AddrStack.Offset = *cast(uint*)(ctx.ptr + CTX_SP_OFF);
        }
        sf.AddrPC.Mode    = AddrModeFlat;
        sf.AddrFrame.Mode = AddrModeFlat;
        sf.AddrStack.Mode = AddrModeFlat;

        auto hThread = getCurrentThread();
        size_t n = 0;

        // Skip internal frames (_d_createTrace + stack_walk64_capture + RtlCaptureContext)
        uint skip = 3;

        while (n < 32)
        {
            if (!_stack_walk64(MACHINE_TYPE, _dbg_process, hThread,
                    &sf, ctx.ptr, null, _func_table_access64, _get_module_base64, null))
                break;
            if (sf.AddrPC.Offset == 0)
                break;
            if (skip > 0)
            {
                --skip;
                continue;
            }
            addrs[n++] = cast(void*) cast(size_t) sf.AddrPC.Offset;
        }
        return n;
    }

    // --- Symbol resolution & printing ------------------------------------

    private void dbghelp_print_trace(void*[] addrs) nothrow @nogc @trusted
    {
        import urt.io : writef_to, writeln_err, WriteTarget;
        import urt.mem : strlen;
        import urt.string : endsWith;

        dbghelp_init();

        // Skip frames up through _d_throw_exception (internal machinery).
        // LDC druntime does the same — clears accumulated frames when it
        // hits _d_throw_exception, so the trace starts at the throw site.
        size_t start = 0;
        if (_dbg_available)
        {
            foreach (i, addr; addrs)
            {
                align(8) ubyte[SYMBOL_INFOA.sizeof + 256] sym_buf = 0;
                auto p_sym = cast(SYMBOL_INFOA*) sym_buf.ptr;
                p_sym.SizeOfStruct = SYMBOL_INFOA.sizeof;
                p_sym.MaxNameLen = 256;

                ulong disp;
                if (_sym_from_addr(_dbg_process, cast(ulong) addr, &disp, p_sym))
                {
                    auto name = p_sym.Name.ptr[0 .. strlen(p_sym.Name.ptr)];
                    if (name.endsWith("_d_throw_exception"))
                        start = i + 1;
                }
            }
        }

        enum addr_fmt = size_t.sizeof == 4 ? "08x" : "016x";

        foreach (addr; addrs[start .. $])
        {
            if (_dbg_available)
            {
                align(8) ubyte[SYMBOL_INFOA.sizeof + 256] sym_buf = 0;
                auto p_sym = cast(SYMBOL_INFOA*) sym_buf.ptr;
                p_sym.SizeOfStruct = SYMBOL_INFOA.sizeof;
                p_sym.MaxNameLen = 256;

                ulong displacement64;
                auto a = cast(ulong) addr;
                if (_sym_from_addr(_dbg_process, a, &displacement64, p_sym))
                {
                    auto name = p_sym.Name.ptr[0 .. strlen(p_sym.Name.ptr)];

                    uint displacement32;
                    IMAGEHLP_LINEA64 line_info;
                    line_info.SizeOfStruct = IMAGEHLP_LINEA64.sizeof;

                    if (_sym_get_line !is null &&
                        _sym_get_line(_dbg_process, a, &displacement32, &line_info))
                    {
                        auto fname = line_info.FileName[0 .. strlen(line_info.FileName)];
                        writef_to!(WriteTarget.stderr, true)("    {0}+0x{1:x} [{2}:{3}]",
                            name, displacement64, fname, line_info.LineNumber);
                    }
                    else
                    {
                        writef_to!(WriteTarget.stderr, true)("    {0}+0x{1:x}", name, displacement64);
                    }
                    continue;
                }
            }

            // Fallback: raw address
            writef_to!(WriteTarget.stderr, true)("    0x{0:" ~ addr_fmt ~ "}", cast(size_t)addr);
        }
    }
}

// ── Stack trace support (POSIX, debug only) ──────────────────────────
//
// Uses dladdr for symbol names and DWARF .debug_line for file:line info.
// Ported from druntime's core.internal.backtrace.{dwarf,elf} and
// core.internal.elf.{io,dl}.
//
version (Windows) {} else version (FreeStanding) {} else debug
{
    import urt.io : write_err, writeln_err, writef_to, WriteTarget;
    import urt.mem : strlen, memcpy;

    import urt.internal.sys.posix;

    private enum SEEK_END = 2;

    // ── _Unwind_Backtrace capture (ARM, AArch64, RISC-V) ────────────

    version (D_InlineAsm_X86_64) {} else version (D_InlineAsm_X86) {} else
    {
        private alias _Unwind_Trace_Fn = extern(C) int function(void* ctx, void* data) nothrow @nogc;

        extern(C) private int _Unwind_Backtrace(_Unwind_Trace_Fn, void*) nothrow @nogc;
        extern(C) private size_t _Unwind_GetIP(void*) nothrow @nogc;

        private struct UnwindState { StackTraceData* trace; ubyte skip; }

        extern(C) private int unwind_trace_callback(void* ctx, void* data) nothrow @nogc
        {
            auto s = cast(UnwindState*) data;
            if (s.skip > 0) { s.skip--; return 0; }
            if (s.trace.length >= 32) return 1;
            auto ip = _Unwind_GetIP(ctx);
            if (!ip) return 1;
            s.trace.addrs[s.trace.length++] = cast(void*) ip;
            return 0;
        }

        private void unwind_backtrace(ref StackTraceData trace) nothrow @nogc @trusted
        {
            UnwindState state = UnwindState(&trace, 2);
            _Unwind_Backtrace(&unwind_trace_callback, &state);
        }
    }

    // ── Minimal ELF types ────────────────────────────────────────────

    version (D_LP64)
    {
        private struct Elf_Ehdr
        {
            ubyte[16] e_ident;
            ushort e_type;
            ushort e_machine;
            uint   e_version;
            ulong  e_entry;
            ulong  e_phoff;
            ulong  e_shoff;
            uint   e_flags;
            ushort e_ehsize;
            ushort e_phentsize;
            ushort e_phnum;
            ushort e_shentsize;
            ushort e_shnum;
            ushort e_shstrndx;
        }

        private struct Elf_Shdr
        {
            uint   sh_name;
            uint   sh_type;
            ulong  sh_flags;
            ulong  sh_addr;
            ulong  sh_offset;
            ulong  sh_size;
            uint   sh_link;
            uint   sh_info;
            ulong  sh_addralign;
            ulong  sh_entsize;
        }

        private struct Elf_Phdr
        {
            uint   p_type;
            uint   p_flags;
            ulong  p_offset;
            ulong  p_vaddr;
            ulong  p_paddr;
            ulong  p_filesz;
            ulong  p_memsz;
            ulong  p_align;
        }
    }
    else
    {
        private struct Elf_Ehdr
        {
            ubyte[16] e_ident;
            ushort e_type;
            ushort e_machine;
            uint   e_version;
            uint   e_entry;
            uint   e_phoff;
            uint   e_shoff;
            uint   e_flags;
            ushort e_ehsize;
            ushort e_phentsize;
            ushort e_phnum;
            ushort e_shentsize;
            ushort e_shnum;
            ushort e_shstrndx;
        }

        private struct Elf_Shdr
        {
            uint sh_name;
            uint sh_type;
            uint sh_flags;
            uint sh_addr;
            uint sh_offset;
            uint sh_size;
            uint sh_link;
            uint sh_info;
            uint sh_addralign;
            uint sh_entsize;
        }

        private struct Elf_Phdr
        {
            uint p_type;
            uint p_offset;
            uint p_vaddr;
            uint p_paddr;
            uint p_filesz;
            uint p_memsz;
            uint p_flags;
            uint p_align;
        }
    }

    private enum EI_MAG0   = 0;
    private enum EI_CLASS  = 4;
    private enum EI_DATA   = 5;
    private enum ELFMAG    = "\x7fELF";
    private enum ET_DYN    = 3;
    private enum SHF_COMPRESSED = 0x800;

    version (D_LP64)
        private enum ELFCLASS_NATIVE = 2; // ELFCLASS64
    else
        private enum ELFCLASS_NATIVE = 1; // ELFCLASS32

    version (LittleEndian)
        private enum ELFDATA_NATIVE = 1; // ELFDATA2LSB
    else
        private enum ELFDATA_NATIVE = 2; // ELFDATA2MSB

    // ── dl_iterate_phdr for base address ─────────────────────────────

    private struct dl_phdr_info
    {
        size_t         dlpi_addr;
        const(char)*   dlpi_name;
        const(Elf_Phdr)* dlpi_phdr;
        ushort         dlpi_phnum;
    }

    private alias dl_iterate_phdr_callback_t = extern(C) int function(dl_phdr_info*, size_t, void*) nothrow @nogc;

    extern(C) private int dl_iterate_phdr(dl_iterate_phdr_callback_t callback, void* data) nothrow @nogc;

    private size_t get_executable_base_address() nothrow @nogc @trusted
    {
        size_t result = 0;

        extern(C) static int callback(dl_phdr_info* info, size_t, void* data) nothrow @nogc
        {
            // First entry is the executable itself
            *cast(size_t*) data = info.dlpi_addr;
            return 1; // stop iteration
        }

        dl_iterate_phdr(&callback, &result);
        return result;
    }

    // ── Memory-mapped file region ────────────────────────────────────

    private struct MappedRegion
    {
        const(ubyte)* data;
        size_t mapped_size;

    nothrow @nogc @trusted:

        static MappedRegion map(int fd, size_t offset, size_t length)
        {
            if (fd == -1 || length == 0)
                return MappedRegion.init;

            auto pgsz = cast(size_t) sysconf(_SC_PAGE_SIZE);
            if (cast(int) pgsz <= 0)
                pgsz = 4096;

            const page_off = offset / pgsz;
            const diff = offset - page_off * pgsz;
            const needed = length + diff;
            const pages = (needed + pgsz - 1) / pgsz;
            const msize = pages * pgsz;

            auto p = mmap(null, msize, PROT_READ, MAP_PRIVATE, fd, cast(off_t)(page_off * pgsz));
            if (p is MAP_FAILED)
                return MappedRegion.init;

            return MappedRegion(cast(const(ubyte)*) p + diff, msize);
        }

        void unmap()
        {
            if (data !is null)
            {
                auto pgsz = cast(size_t) sysconf(_SC_PAGE_SIZE);
                if (cast(int) pgsz <= 0)
                    pgsz = 4096;
                // Align back to page boundary
                auto base = cast(void*)(cast(size_t) data & ~(pgsz - 1));
                munmap(base, mapped_size);
                data = null;
            }
        }
    }

    // ── ELF self-reader ──────────────────────────────────────────────

    private struct ElfSelf
    {
        int fd = -1;
        MappedRegion ehdr_region;
        const(Elf_Ehdr)* ehdr;

    nothrow @nogc @trusted:

        static ElfSelf open()
        {
            ElfSelf self;

            // Read /proc/self/exe path
            char[512] pathbuf = void;
            auto n = readlink("/proc/self/exe", pathbuf.ptr, pathbuf.length - 1);
            if (n <= 0)
                return self;
            pathbuf[n] = 0;

            self.fd = .open(pathbuf.ptr, O_RDONLY);
            if (self.fd == -1)
                return self;

            // Map the ELF header
            self.ehdr_region = MappedRegion.map(self.fd, 0, Elf_Ehdr.sizeof);
            if (self.ehdr_region.data is null)
            {
                .close(self.fd);
                self.fd = -1;
                return self;
            }

            self.ehdr = cast(const(Elf_Ehdr)*) self.ehdr_region.data;

            // Validate ELF magic, class, and byte order
            if (self.ehdr.e_ident[0..4] != cast(const(ubyte)[4]) ELFMAG
                || self.ehdr.e_ident[EI_CLASS] != ELFCLASS_NATIVE
                || self.ehdr.e_ident[EI_DATA] != ELFDATA_NATIVE)
            {
                self.close();
                return ElfSelf.init;
            }

            return self;
        }

        void close()
        {
            ehdr_region.unmap();
            ehdr = null;
            if (fd != -1) { .close(fd); fd = -1; }
        }

        bool valid() const { return fd != -1 && ehdr !is null; }

        /// Find a section by name, return its offset and size.
        bool find_section(const(char)[] name, out size_t offset, out size_t size)
        {
            if (!valid())
                return false;

            // Map section headers
            auto shdr_total = cast(size_t) ehdr.e_shnum * Elf_Shdr.sizeof;
            auto shdr_region = MappedRegion.map(fd, cast(size_t) ehdr.e_shoff, shdr_total);
            if (shdr_region.data is null)
                return false;
            scope(exit) shdr_region.unmap();

            auto shdrs = (cast(const(Elf_Shdr)*) shdr_region.data)[0 .. ehdr.e_shnum];

            // Map string table section
            if (ehdr.e_shstrndx >= ehdr.e_shnum)
                return false;
            auto strtab_shdr = &shdrs[ehdr.e_shstrndx];
            auto strtab_region = MappedRegion.map(fd,
                cast(size_t) strtab_shdr.sh_offset,
                cast(size_t) strtab_shdr.sh_size);
            if (strtab_region.data is null)
                return false;
            scope(exit) strtab_region.unmap();

            auto strtab = cast(const(char)*) strtab_region.data;

            // Search for the named section
            foreach (ref shdr; shdrs)
            {
                if (shdr.sh_name >= strtab_shdr.sh_size)
                    continue;
                auto sec_name = strtab + shdr.sh_name;
                auto sec_name_len = strlen(sec_name);
                if (sec_name_len == name.length && sec_name[0 .. sec_name_len] == name)
                {
                    if (shdr.sh_flags & SHF_COMPRESSED)
                        return false; // compressed debug sections not supported
                    offset = cast(size_t) shdr.sh_offset;
                    size = cast(size_t) shdr.sh_size;
                    return true;
                }
            }
            return false;
        }
    }

    // ── DWARF .debug_line types and constants ────────────────────────

    private struct LocationInfo
    {
        int file = -1;
        int line = -1;
    }

    private struct SourceFile
    {
        const(char)[] file;
        size_t dir_index; // 1-based
    }

    private struct LineNumberProgram
    {
        ulong unit_length;
        ushort dwarf_version;
        ubyte address_size;
        ubyte segment_selector_size;
        ulong header_length;
        ubyte minimum_instruction_length;
        ubyte maximum_operations_per_instruction;
        bool  default_is_statement;
        byte  line_base;
        ubyte line_range;
        ubyte opcode_base;
        const(ubyte)[] standard_opcode_lengths;
        // Directory and file tables stored as slices into scratch buffers.
        // The caller owns the scratch; the LineNumberProgram just borrows.
        const(char)[][] include_directories;
        size_t num_dirs;
        SourceFile[] source_files;
        size_t num_files;
        const(ubyte)[] program;
    }

    private struct StateMachine
    {
        const(void)* address;
        uint operation_index = 0;
        uint file_index = 1;
        int  line = 1;
        uint column = 0;
        bool is_statement;
        bool is_end_sequence = false;
    }

    private enum StandardOpcode : ubyte
    {
        extended_op = 0,
        copy = 1,
        advance_pc = 2,
        advance_line = 3,
        set_file = 4,
        set_column = 5,
        negate_statement = 6,
        set_basic_block = 7,
        const_add_pc = 8,
        fixed_advance_pc = 9,
        set_prologue_end = 10,
        set_epilogue_begin = 11,
        set_isa = 12,
    }

    private enum ExtendedOpcode : ubyte
    {
        end_sequence = 1,
        set_address = 2,
        define_file = 3,
        set_discriminator = 4,
    }

    // ── LEB128 and DWARF helpers ─────────────────────────────────────

    private T dw_read(T)(ref const(ubyte)[] buf) nothrow @nogc @trusted
    {
        if (buf.length < T.sizeof)
            return T.init;
        version (X86_64)
            T result = *cast(const(T)*) buf.ptr;
        else version (X86)
            T result = *cast(const(T)*) buf.ptr;
        else
        {
            T result = void;
            memcpy(&result, buf.ptr, T.sizeof);
        }
        buf = buf[T.sizeof .. $];
        return result;
    }

    private const(char)[] dw_read_stringz(ref const(ubyte)[] buf) nothrow @nogc @trusted
    {
        auto p = cast(const(char)*) buf.ptr;
        auto len = strlen(p);
        buf = buf[len + 1 .. $];
        return p[0 .. len];
    }

    private ulong dw_read_uleb128(ref const(ubyte)[] buf) nothrow @nogc
    {
        ulong val = 0;
        uint shift = 0;
        while (buf.length > 0)
        {
            ubyte b = buf[0]; buf = buf[1 .. $];
            val |= cast(ulong)(b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
        }
        return val;
    }

    private long dw_read_sleb128(ref const(ubyte)[] buf) nothrow @nogc
    {
        long val = 0;
        uint shift = 0;
        ubyte b;
        while (buf.length > 0)
        {
            b = buf[0]; buf = buf[1 .. $];
            val |= cast(long)(b & 0x7f) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
        }
        if (shift < 64 && (b & 0x40) != 0)
            val |= -(cast(long) 1 << shift);
        return val;
    }

    // ── DWARF v5 entry format ────────────────────────────────────────

    private enum DW_LNCT : ushort
    {
        path = 1,
        directory_index = 2,
    }

    private enum DW_FORM : ubyte
    {
        data1 = 11,
        data2 = 5,
        data4 = 6,
        data8 = 7,
        data16 = 30,
        string_ = 8,
        strp = 14,
        line_strp = 31,
        udata = 15,
        block = 9,
        strx = 26,
        strx1 = 37,
        strx2 = 38,
        strx3 = 39,
        strx4 = 40,
        sec_offset = 23,
        sdata = 13,
        flag = 12,
        flag_present = 25,
    }

    private struct EntryFormatPair
    {
        DW_LNCT type;
        DW_FORM form;
    }

    /// Skip a DWARF form value we don't care about.
    private void dw_skip_form(ref const(ubyte)[] data, DW_FORM form, bool is64bit) nothrow @nogc
    {
        with (DW_FORM) switch (form)
        {
            case strp, line_strp, sec_offset:
                data = data[is64bit ? 8 : 4 .. $]; break;
            case data1, strx1, flag, flag_present:
                data = data[1 .. $]; break;
            case data2, strx2:
                data = data[2 .. $]; break;
            case strx3:
                data = data[3 .. $]; break;
            case data4, strx4:
                data = data[4 .. $]; break;
            case data8:
                data = data[8 .. $]; break;
            case data16:
                data = data[16 .. $]; break;
            case udata, strx, sdata:
                dw_read_uleb128(data); break;
            case block:
                auto length = cast(size_t) dw_read_uleb128(data);
                data = data[length .. $]; break;
            default:
                break;
        }
    }

    // ── Read DWARF line number program header ────────────────────────

    // Scratch buffers allocated on the stack for directory/file tables.
    // 256 entries each should be more than enough for any compilation unit.
    private enum MAX_DIRS  = 256;
    private enum MAX_FILES = 512;

    private LineNumberProgram dw_read_line_number_program(ref const(ubyte)[] data) nothrow @nogc @trusted
    {
        const original_data = data;
        LineNumberProgram lp;

        bool is_64bit_dwarf = false;
        lp.unit_length = dw_read!uint(data);
        if (lp.unit_length == uint.max)
        {
            is_64bit_dwarf = true;
            lp.unit_length = dw_read!ulong(data);
        }

        const version_field_offset = cast(size_t)(data.ptr - original_data.ptr);
        lp.dwarf_version = dw_read!ushort(data);

        if (lp.dwarf_version >= 5)
        {
            lp.address_size = dw_read!ubyte(data);
            lp.segment_selector_size = dw_read!ubyte(data);
        }

        lp.header_length = is_64bit_dwarf ? dw_read!ulong(data) : dw_read!uint(data);

        const min_insn_field_offset = cast(size_t)(data.ptr - original_data.ptr);
        lp.minimum_instruction_length = dw_read!ubyte(data);
        lp.maximum_operations_per_instruction = (lp.dwarf_version >= 4) ? dw_read!ubyte(data) : 1;
        lp.default_is_statement = (dw_read!ubyte(data) != 0);
        lp.line_base = dw_read!byte(data);
        lp.line_range = dw_read!ubyte(data);
        lp.opcode_base = dw_read!ubyte(data);

        lp.standard_opcode_lengths = data[0 .. lp.opcode_base - 1];
        data = data[lp.opcode_base - 1 .. $];

        if (lp.dwarf_version >= 5)
        {
            // DWARF v5: directory format + entries
            auto num_pairs = dw_read!ubyte(data);
            EntryFormatPair[8] dir_fmt = void;
            foreach (i; 0 .. num_pairs)
            {
                if (i < 8)
                {
                    dir_fmt[i].type = cast(DW_LNCT) dw_read_uleb128(data);
                    dir_fmt[i].form = cast(DW_FORM) dw_read_uleb128(data);
                }
            }

            lp.num_dirs = cast(size_t) dw_read_uleb128(data);
            // Caller must provide scratch buffers; we use __gshared static for simplicity.
            foreach (d; 0 .. lp.num_dirs)
            {
                foreach (p; 0 .. num_pairs)
                {
                    if (p < 8 && dir_fmt[p].type == DW_LNCT.path && dir_fmt[p].form == DW_FORM.string_)
                    {
                        if (d < MAX_DIRS)
                            _dir_scratch[d] = dw_read_stringz(data);
                        else
                            dw_read_stringz(data);
                    }
                    else if (p < 8)
                        dw_skip_form(data, dir_fmt[p].form, is_64bit_dwarf);
                }
            }
            if (lp.num_dirs > MAX_DIRS) lp.num_dirs = MAX_DIRS;
            lp.include_directories = _dir_scratch[0 .. lp.num_dirs];

            // File format + entries
            num_pairs = dw_read!ubyte(data);
            EntryFormatPair[8] file_fmt = void;
            foreach (i; 0 .. num_pairs)
            {
                if (i < 8)
                {
                    file_fmt[i].type = cast(DW_LNCT) dw_read_uleb128(data);
                    file_fmt[i].form = cast(DW_FORM) dw_read_uleb128(data);
                }
            }

            lp.num_files = cast(size_t) dw_read_uleb128(data);
            foreach (f; 0 .. lp.num_files)
            {
                SourceFile sf;
                sf.file = "<unknown>";
                foreach (p; 0 .. num_pairs)
                {
                    if (p < 8 && file_fmt[p].type == DW_LNCT.path && file_fmt[p].form == DW_FORM.string_)
                        sf.file = dw_read_stringz(data);
                    else if (p < 8 && file_fmt[p].type == DW_LNCT.directory_index)
                    {
                        if (file_fmt[p].form == DW_FORM.data1)
                            sf.dir_index = dw_read!ubyte(data);
                        else if (file_fmt[p].form == DW_FORM.data2)
                            sf.dir_index = dw_read!ushort(data);
                        else if (file_fmt[p].form == DW_FORM.udata)
                            sf.dir_index = cast(size_t) dw_read_uleb128(data);
                        else
                            dw_skip_form(data, file_fmt[p].form, is_64bit_dwarf);
                        sf.dir_index++; // DWARF v5 indices are 0-based, normalize to 1-based
                    }
                    else if (p < 8)
                        dw_skip_form(data, file_fmt[p].form, is_64bit_dwarf);
                }
                if (f < MAX_FILES)
                    _file_scratch[f] = sf;
            }
            if (lp.num_files > MAX_FILES) lp.num_files = MAX_FILES;
            lp.source_files = _file_scratch[0 .. lp.num_files];
        }
        else
        {
            // DWARF v3/v4: NUL-terminated sequences
            lp.num_dirs = 0;
            while (data.length > 0 && data[0] != 0)
            {
                auto dir = dw_read_stringz(data);
                if (lp.num_dirs < MAX_DIRS)
                    _dir_scratch[lp.num_dirs++] = dir;
            }
            if (data.length > 0) data = data[1 .. $]; // skip NUL terminator
            lp.include_directories = _dir_scratch[0 .. lp.num_dirs];

            lp.num_files = 0;
            while (data.length > 0 && data[0] != 0)
            {
                SourceFile sf;
                sf.file = dw_read_stringz(data);
                sf.dir_index = cast(size_t) dw_read_uleb128(data);
                dw_read_uleb128(data); // last modification time
                dw_read_uleb128(data); // file length
                if (lp.num_files < MAX_FILES)
                    _file_scratch[lp.num_files++] = sf;
            }
            if (data.length > 0) data = data[1 .. $]; // skip NUL terminator
            lp.source_files = _file_scratch[0 .. lp.num_files];
        }

        const program_start = cast(size_t)(min_insn_field_offset + lp.header_length);
        const program_end = cast(size_t)(version_field_offset + lp.unit_length);
        if (program_start <= original_data.length && program_end <= original_data.length)
            lp.program = original_data[program_start .. program_end];

        data = (program_end <= original_data.length) ? original_data[program_end .. $] : null;

        return lp;
    }

    // Static scratch buffers for DWARF parsing (debug-only, no allocator needed).
    private __gshared const(char)[][MAX_DIRS] _dir_scratch;
    private __gshared SourceFile[MAX_FILES] _file_scratch;

    // ── DWARF state machine — resolve addresses to file:line ─────────

    private struct ResolvedLocation
    {
        const(char)[] file;
        const(char)[] dir;
        int line = -1;
    }

    /// Resolve an array of addresses to file:line using .debug_line data.
    private void dw_resolve_addresses(
        const(ubyte)[] debug_line_data,
        void*[] addresses,
        ResolvedLocation[] results,
        size_t base_address) nothrow @nogc @trusted
    {
        size_t found = 0;
        const num_addrs = addresses.length;

        while (debug_line_data.length > 0 && found < num_addrs)
        {
            auto lp = dw_read_line_number_program(debug_line_data);
            if (lp.program.length == 0)
                break;

            StateMachine machine;
            machine.is_statement = lp.default_is_statement;

            LocationInfo last_loc = LocationInfo(-1, -1);
            const(void)* last_address;

            const(ubyte)[] prog = lp.program;
            while (prog.length > 0)
            {
                size_t advance_addr(size_t op_advance)
                {
                    const inc = lp.minimum_instruction_length *
                        ((machine.operation_index + op_advance) / lp.maximum_operations_per_instruction);
                    machine.address += inc;
                    machine.operation_index =
                        (machine.operation_index + op_advance) % lp.maximum_operations_per_instruction;
                    return inc;
                }

                void emit_row(bool is_end)
                {
                    auto addr = machine.address + base_address;

                    foreach (idx; 0 .. num_addrs)
                    {
                        if (results[idx].line != -1)
                            continue;
                        auto target = addresses[idx];

                        void apply_loc(LocationInfo loc)
                        {
                            auto file_idx = loc.file - (lp.dwarf_version < 5 ? 1 : 0);
                            if (file_idx >= 0 && file_idx < lp.num_files)
                            {
                                results[idx].file = lp.source_files[file_idx].file;
                                auto di = lp.source_files[file_idx].dir_index;
                                if (di > 0 && di <= lp.num_dirs)
                                    results[idx].dir = lp.include_directories[di - 1];
                            }
                            results[idx].line = loc.line;
                            found++;
                        }

                        if (target == addr)
                            apply_loc(LocationInfo(machine.file_index, machine.line));
                        else if (last_address !is null && target > last_address && target < addr)
                            apply_loc(last_loc);
                    }

                    if (is_end)
                        last_address = null;
                    else
                    {
                        last_address = addr;
                        last_loc = LocationInfo(machine.file_index, machine.line);
                    }
                }

                ubyte opcode = prog[0]; prog = prog[1 .. $];

                if (opcode >= lp.opcode_base)
                {
                    // Special opcode
                    opcode -= lp.opcode_base;
                    advance_addr(opcode / lp.line_range);
                    machine.line += lp.line_base + (opcode % lp.line_range);
                    emit_row(false);
                }
                else if (opcode == 0)
                {
                    // Extended opcode
                    auto len = cast(size_t) dw_read_uleb128(prog);
                    if (prog.length == 0) break;
                    ubyte eopcode = prog[0]; prog = prog[1 .. $];

                    switch (eopcode)
                    {
                        case ExtendedOpcode.end_sequence:
                            machine.is_end_sequence = true;
                            emit_row(true);
                            machine = StateMachine.init;
                            machine.is_statement = lp.default_is_statement;
                            break;
                        case ExtendedOpcode.set_address:
                            machine.address = dw_read!(const(void)*)(prog);
                            machine.operation_index = 0;
                            break;
                        case ExtendedOpcode.set_discriminator:
                            dw_read_uleb128(prog);
                            break;
                        default:
                            if (len > 1)
                                prog = prog[len - 1 .. $];
                            break;
                    }
                }
                else switch (opcode) with (StandardOpcode)
                {
                    case copy:
                        emit_row(false);
                        break;
                    case advance_pc:
                        advance_addr(cast(size_t) dw_read_uleb128(prog));
                        break;
                    case advance_line:
                        machine.line += cast(int) dw_read_sleb128(prog);
                        break;
                    case set_file:
                        machine.file_index = cast(uint) dw_read_uleb128(prog);
                        break;
                    case set_column:
                        machine.column = cast(uint) dw_read_uleb128(prog);
                        break;
                    case negate_statement:
                        machine.is_statement = !machine.is_statement;
                        break;
                    case set_basic_block:
                        break;
                    case const_add_pc:
                        advance_addr((255 - lp.opcode_base) / lp.line_range);
                        break;
                    case fixed_advance_pc:
                        machine.address += dw_read!ushort(prog);
                        machine.operation_index = 0;
                        break;
                    case set_prologue_end:
                    case set_epilogue_begin:
                        break;
                    case set_isa:
                        dw_read_uleb128(prog);
                        break;
                    default:
                        // Unknown standard opcode: skip according to standard_opcode_lengths
                        if (opcode > 0 && opcode <= lp.standard_opcode_lengths.length)
                        {
                            foreach (_; 0 .. lp.standard_opcode_lengths[opcode - 1])
                                dw_read_uleb128(prog);
                        }
                        break;
                }
            }
        }
    }

    // ── Minimal D symbol demangler ─────────────────────────────────────
    //
    // Extracts the dot-separated qualified name from a D mangled symbol.
    // Does not decode type signatures — just returns e.g. "module.Class.func".

    private const(char)[] demangle_symbol(
        const(char)[] mangled, return ref char[512] buf) nothrow @nogc @trusted
    {
        import urt.array : beginsWith;
        import urt.conv : parse_uint;

        if (mangled.length < 3 || !mangled.beginsWith("_D"))
            return mangled;

        auto src = mangled[2 .. $];
        size_t pos = 0;
        bool first = true;

        while (src.length > 0)
        {
            auto ch = src[0];

            if (ch >= '1' && ch <= '9')
            {
                // LName: decimal length followed by that many characters
                size_t taken;
                size_t len = cast(size_t)parse_uint(src, &taken);
                src = src[taken .. $];
                if (len > src.length || pos + len + 1 > buf.length)
                    break;

                if (!first)
                    buf[pos++] = '.';
                first = false;

                buf[pos .. pos + len] = src[0 .. len];
                pos += len;
                src = src[len .. $];
            }
            else if (ch == 'Q')
            {
                // Back reference: base-26 offset pointing to an earlier LName.
                auto q_pos = cast(size_t)(src.ptr - mangled.ptr);
                src = src[1 .. $];

                size_t ref_val = 0;
                while (src.length > 0 && src[0] >= 'A' && src[0] <= 'Z')
                {
                    ref_val = ref_val * 26 + (src[0] - 'A');
                    src = src[1 .. $];
                }
                if (src.length > 0 && src[0] >= 'a' && src[0] <= 'z')
                {
                    ref_val = ref_val * 26 + (src[0] - 'a');
                    src = src[1 .. $];
                }
                else
                    break; // malformed

                if (ref_val >= q_pos)
                    break;
                auto target = mangled[q_pos - ref_val .. $];
                if (target.length == 0 || target[0] < '1' || target[0] > '9')
                    break;

                // Parse LName at target
                size_t taken;
                size_t len = cast(size_t)parse_uint(target, &taken);
                target = target[taken .. $];
                if (len > target.length || pos + len + 1 > buf.length)
                    break;

                if (!first)
                    buf[pos++] = '.';
                first = false;

                buf[pos .. pos + len] = target[0 .. len];
                pos += len;
            }
            else if (ch == '_' && src.length >= 3 && src[1] == '_'
                && (src[2] == 'T' || src[2] == 'U'))
            {
                // Template instance __T/__U: extract name, skip args until Z
                src = src[3 .. $];

                if (src.length > 0 && src[0] >= '1' && src[0] <= '9')
                {
                    size_t taken;
                    size_t len = cast(size_t)parse_uint(src, &taken);
                    src = src[taken .. $];
                    if (len <= src.length && pos + len + 1 <= buf.length)
                    {
                        if (!first)
                            buf[pos++] = '.';
                        first = false;

                        buf[pos .. pos + len] = src[0 .. len];
                        pos += len;
                        src = src[len .. $];
                    }
                }

                // Skip template args until matching Z
                int depth = 1;
                while (src.length > 0 && depth > 0)
                {
                    if (src[0] == 'Z')
                        --depth;
                    else if (src.length >= 3 && src[0] == '_' && src[1] == '_'
                        && (src[2] == 'T' || src[2] == 'U'))
                    {
                        ++depth;
                        src = src[2 .. $];
                    }
                    src = src[1 .. $];
                }
            }
            else if (ch == '0')
                src = src[1 .. $]; // anonymous — skip
            else
                break; // type signature — done
        }

        if (pos == 0)
            return mangled;

        // Append $TypeSignature if there's anything left
        if (src.length > 0 && pos + 1 + src.length <= buf.length)
        {
            buf[pos++] = '$';
            buf[pos .. pos + src.length] = src[];
            pos += src.length;
        }

        return buf[0 .. pos];
    }

    // ── Print formatted trace ────────────────────────────────────────

    private void posix_print_trace(void*[] addrs) nothrow @nogc @trusted
    {
        if (addrs.length == 0)
            return;

        // Skip internal frames (find _d_throw_exception / _d_throwdwarf)
        import urt.string : endsWith;
        size_t start = 0;
        foreach (i, addr; addrs)
        {
            Dl_info info = void;
            if (dladdr(addr, &info) && info.dli_sname !is null)
            {
                auto sym = info.dli_sname[0 .. strlen(info.dli_sname)];
                if (sym.endsWith("_d_throw_exception") || sym.endsWith("_d_throwdwarf"))
                    start = i + 1;
            }
        }

        // Try DWARF .debug_line resolution
        ResolvedLocation[32] locations;
        foreach (ref loc; locations)
            loc = ResolvedLocation.init;

        auto elf = ElfSelf.open();
        scope(exit) elf.close();

        if (elf.valid())
        {
            size_t dbg_offset, dbg_size;
            if (elf.find_section(".debug_line", dbg_offset, dbg_size))
            {
                auto dbg_region = MappedRegion.map(elf.fd, dbg_offset, dbg_size);
                if (dbg_region.data !is null)
                {
                    scope(exit) dbg_region.unmap();

                    auto base_addr = (elf.ehdr.e_type == ET_DYN)
                        ? get_executable_base_address() : cast(size_t) 0;

                    auto dbg_data = dbg_region.data[0 .. dbg_size];
                    dw_resolve_addresses(dbg_data,
                        addrs[0 .. addrs.length],
                        locations[0 .. addrs.length],
                        base_addr);
                }
            }
        }

        // Print each frame
        foreach (i; start .. addrs.length)
        {
            auto addr = addrs[i];
            ref loc = locations[i];

            // Symbol name via dladdr
            Dl_info info = void;
            const(char)* symname = null;
            size_t sym_offset = 0;
            if (dladdr(addr, &info) && info.dli_sname !is null)
            {
                symname = info.dli_sname;
                sym_offset = cast(size_t) addr - cast(size_t) info.dli_saddr;
            }

            // Format: file:line symbol+0xoffset [0xaddress]
            //    or:  ??:? symbol+0xoffset [0xaddress]
            //    or:  ??:? 0xaddress

            if (loc.line >= 0)
            {
                // Have file:line
                if (loc.dir.length > 0 && loc.dir[$ - 1] != '/')
                    writef_to!(WriteTarget.stderr, false)("    {0}/{1}:{2}", loc.dir, loc.file, loc.line);
                else if (loc.dir.length > 0)
                    writef_to!(WriteTarget.stderr, false)("    {0}{1}:{2}", loc.dir, loc.file, loc.line);
                else
                    writef_to!(WriteTarget.stderr, false)("    {0}:{1}", loc.file, loc.line);
            }
            else
                write_err("    ??:?");

            if (symname !is null)
            {
                auto sym = symname[0 .. strlen(symname)];
                char[512] dbuf = void;
                auto demangled = demangle_symbol(sym, dbuf);
                writef_to!(WriteTarget.stderr, false)(" {0}+0x{1:x}", demangled, sym_offset);
            }

            enum addr_fmt = size_t.sizeof == 4 ? "08x" : "016x";
            writef_to!(WriteTarget.stderr, true)(" [0x{0:" ~ addr_fmt ~ "}]", cast(size_t)addr);

            // Stop at _Dmain
            if (symname !is null)
            {
                auto sym = symname[0 .. strlen(symname)];
                if (sym == "_Dmain")
                    break;
            }
        }
    }
} // version (!Windows) debug

private void terminate() nothrow @nogc @trusted
{
    import urt.io : writeln_err;
    writeln_err("Unhandled exception -- no catch handler found, terminating.");

    debug
    {
        if (_tls_trace.length > 0)
        {
            writeln_err("  stack trace:");
            version (Windows)
                dbghelp_print_trace(_tls_trace.addrs[0 .. _tls_trace.length]);
            else version (FreeStanding)
            {}
            else
                posix_print_trace(_tls_trace.addrs[0 .. _tls_trace.length]);
        }
    }

    version (D_InlineAsm_X86_64)
        asm nothrow @nogc { hlt; }
    else version (D_InlineAsm_X86)
        asm nothrow @nogc { hlt; }
    else
    {
        import urt.internal.stdc.stdlib : abort;
        abort();
    }
}

// ══════════════════════════════════════════════════════════════════════
//  Platform-specific implementations
// ══════════════════════════════════════════════════════════════════════

version (GDC)
{
    static assert(false, "!!");
}
else version (LDC)
{

// ──────────────────────────────────────────────────────────────────────
// LDC MSVC SEH exception handling
//
// LDC on Windows uses the MSVC C++ exception infrastructure.
// _d_throw_exception builds MSVC-compatible type metadata and calls
// RaiseException(). The MSVC CRT's table-based SEH unwinds the stack
// and delivers exceptions to catch landing pads, which call
// _d_eh_enter_catch to extract the D Throwable from the SEH record.
//
// Ported from ldc/eh_msvc.d in LDC's druntime.
// ──────────────────────────────────────────────────────────────────────

version (Windows)
{

// --- Windows ABI types ---------------------------------------------------

private alias DWORD = uint;
private alias ULONG_PTR = size_t;

extern (Windows) void RaiseException(DWORD dwExceptionCode, DWORD dwExceptionFlags,
    DWORD nNumberOfArguments, ULONG_PTR* lpArguments) nothrow;

// --- MSVC SEH structures -------------------------------------------------

// On Win64, type info pointers are 32-bit offsets from a heap base.
version (Win64)
    private struct ImgPtr(T) { uint offset; }
else
    private alias ImgPtr(T) = T*;

private alias PMFN = ImgPtr!(void function(void*));

private struct TypeDescriptor
{
    uint hash;
    void* spare;
    char[1] name; // variable-size, zero-terminated
}

private struct PMD
{
    int mdisp;
    int pdisp;
    int vdisp;
}

private struct CatchableType
{
    uint properties;
    ImgPtr!TypeDescriptor pType;
    PMD thisDisplacement;
    int sizeOrOffset;
    PMFN copyFunction;
}

private enum CT_IsSimpleType = 0x00000001;

private struct CatchableTypeArray
{
    int nCatchableTypes;
    ImgPtr!CatchableType[1] arrayOfCatchableTypes; // variable size
}

private struct _ThrowInfo
{
    uint attributes;
    PMFN pmfnUnwind;
    PMFN pForwardCompat;
    ImgPtr!CatchableTypeArray pCatchableTypeArray;
}

private struct CxxExceptionInfo
{
    size_t Magic;
    Throwable* pThrowable;
    _ThrowInfo* ThrowInfo;
    version (Win64) void* ImgBase;
}

private enum int STATUS_MSC_EXCEPTION = 0xe0000000 | ('m' << 16) | ('s' << 8) | ('c' << 0);
private enum EXCEPTION_NONCONTINUABLE = 0x01;
private enum EH_MAGIC_NUMBER1 = 0x19930520;


// --- EH Heap (image-relative pointer support) ----------------------------

version (Win64)
{
    private struct EHHeap
    {
        void* base;
        size_t capacity;
        size_t length;

        void initialize(size_t initial_capacity) nothrow @nogc
        {
            import urt.mem : malloc;
            base = malloc(initial_capacity);
            capacity = initial_capacity;
            length = size_t.sizeof; // offset 0 reserved (null sentinel)
        }

        size_t alloc(size_t size) nothrow @nogc
        {
            import urt.mem : malloc, memcpy;
            auto offset = length;
            enum align_mask = size_t.sizeof - 1;
            auto new_length = (length + size + align_mask) & ~align_mask;
            auto new_capacity = capacity;
            while (new_length > new_capacity)
                new_capacity *= 2;
            if (new_capacity != capacity)
            {
                auto new_base = malloc(new_capacity);
                memcpy(new_base, base, length);
                // Old base leaks — may be referenced by in-flight exceptions.
                base = new_base;
                capacity = new_capacity;
            }
            length = new_length;
            return offset;
        }
    }

    private __gshared EHHeap _eh_heap;

    private ImgPtr!T eh_malloc(T)(size_t size = T.sizeof) nothrow @nogc
    {
        return ImgPtr!T(cast(uint) _eh_heap.alloc(size));
    }

    private T* to_pointer(T)(ImgPtr!T img_ptr) nothrow @nogc
    {
        return cast(T*)(cast(ubyte*) _eh_heap.base + img_ptr.offset);
    }
}
else // Win32
{
    private ImgPtr!T eh_malloc(T)(size_t size = T.sizeof) nothrow @nogc
    {
        import urt.mem : malloc;
        return cast(T*) malloc(size);
    }

    private T* to_pointer(T)(T* img_ptr) nothrow @nogc
    {
        return img_ptr;
    }
}


// --- ThrowInfo cache (simple linear-scan arrays) -------------------------
// No mutex — OpenWatt's exception paths are single-threaded.

private enum EH_CACHE_SIZE = 64;

private __gshared ClassInfo[EH_CACHE_SIZE] _throw_info_keys;
private __gshared ImgPtr!_ThrowInfo[EH_CACHE_SIZE] _throw_info_vals;
private __gshared size_t _throw_info_len;

private __gshared ClassInfo[EH_CACHE_SIZE] _catchable_keys;
private __gshared ImgPtr!CatchableType[EH_CACHE_SIZE] _catchable_vals;
private __gshared size_t _catchable_len;

private __gshared bool _eh_initialized;

private void ensure_eh_init() nothrow @nogc
{
    if (_eh_initialized)
        return;
    version (Win64)
        _eh_heap.initialize(0x10000);
    _eh_initialized = true;
}


// --- ThrowInfo generation ------------------------------------------------

private ImgPtr!CatchableType get_catchable_type(ClassInfo ti) nothrow @nogc
{
    import urt.mem : memcpy;

    foreach (i; 0 .. _catchable_len)
        if (_catchable_keys[i] is ti)
            return _catchable_vals[i];

    const sz = TypeDescriptor.sizeof + ti.name.length + 1;
    auto td = eh_malloc!TypeDescriptor(sz);
    auto ptd = td.to_pointer;

    ptd.hash = 0;
    ptd.spare = null;
    ptd.name.ptr[0] = 'D';
    memcpy(ptd.name.ptr + 1, ti.name.ptr, ti.name.length);
    ptd.name.ptr[ti.name.length + 1] = 0;

    auto ct = eh_malloc!CatchableType();
    ct.to_pointer[0] = CatchableType(
        CT_IsSimpleType, td, PMD(0, -1, 0),
        cast(int) size_t.sizeof, PMFN.init);

    if (_catchable_len < EH_CACHE_SIZE)
    {
        _catchable_keys[_catchable_len] = ti;
        _catchable_vals[_catchable_len] = ct;
        ++_catchable_len;
    }
    return ct;
}

private ImgPtr!_ThrowInfo get_throw_info(ClassInfo ti) nothrow @nogc
{
    foreach (i; 0 .. _throw_info_len)
        if (_throw_info_keys[i] is ti)
            return _throw_info_vals[i];

    int classes = 0;
    for (ClassInfo tic = ti; tic !is null; tic = tic.base)
        ++classes;

    const arr_size = int.sizeof + classes * ImgPtr!(CatchableType).sizeof;
    ImgPtr!CatchableTypeArray cta = eh_malloc!CatchableTypeArray(arr_size);
    to_pointer(cta).nCatchableTypes = classes;

    size_t c = 0;
    for (ClassInfo tic = ti; tic !is null; tic = tic.base)
        cta.to_pointer.arrayOfCatchableTypes.ptr[c++] = get_catchable_type(tic);

    auto tinf = eh_malloc!_ThrowInfo();
    *(tinf.to_pointer) = _ThrowInfo(0, PMFN.init, PMFN.init, cta);

    if (_throw_info_len < EH_CACHE_SIZE)
    {
        _throw_info_keys[_throw_info_len] = ti;
        _throw_info_vals[_throw_info_len] = tinf;
        ++_throw_info_len;
    }
    return tinf;
}


// --- Exception stack (thread-local) --------------------------------------

private struct ExceptionStack
{
nothrow @nogc:

    void push(Throwable e)
    {
        if (_length == _cap)
            grow();
        _p[_length++] = e;
    }

    Throwable pop()
    {
        return _p[--_length];
    }

    void shrink(size_t sz)
    {
        while (_length > sz)
            _p[--_length] = null;
    }

    ref inout(Throwable) opIndex(size_t idx) inout
    {
        return _p[idx];
    }

    size_t find(Throwable e)
    {
        for (size_t i = _length; i > 0;)
            if (_p[--i] is e)
                return i;
        return ~cast(size_t) 0;
    }

    @property size_t length() const { return _length; }

private:

    void grow()
    {
        import urt.mem : malloc, free, memcpy;
        immutable ncap = _cap ? 2 * _cap : 16;
        auto p = cast(Throwable*) malloc(ncap * size_t.sizeof);
        if (_length > 0)
            memcpy(p, _p, _length * size_t.sizeof);
        if (_p !is null)
            free(_p);
        _p = p;
        _cap = ncap;
    }

    size_t _length;
    Throwable* _p;
    size_t _cap;
}

private ExceptionStack _exception_stack;


// --- Exception chaining --------------------------------------------------

private Throwable chain_exceptions(Throwable e, Throwable t) nothrow @nogc
{
    if (!cast(Error) e)
        if (auto err = cast(Error) t)
        {
            err.bypassedException = e;
            return err;
        }
    return Throwable.chainTogether(e, t);
}


// --- Core SEH API --------------------------------------------------------

extern (C) void _d_throw_exception(Throwable throwable)
{
    if (throwable is null || typeid(throwable) is null)
    {
        terminate();
        assert(0);
    }

    auto refcount = throwable.refcount();
    if (refcount)
        throwable.refcount() = refcount + 1;

    ensure_eh_init();

    _exception_stack.push(throwable);
    _d_createTrace(throwable, null);

    CxxExceptionInfo info;
    info.Magic = EH_MAGIC_NUMBER1;
    info.pThrowable = &throwable;
    info.ThrowInfo = get_throw_info(typeid(throwable)).to_pointer;
    version (Win64)
        info.ImgBase = _eh_heap.base;

    RaiseException(STATUS_MSC_EXCEPTION, EXCEPTION_NONCONTINUABLE,
        info.sizeof / size_t.sizeof, cast(ULONG_PTR*) &info);
}

extern (C) Throwable _d_eh_enter_catch(void* ptr, ClassInfo catch_type)
{
    if (ptr is null)
        return null;

    auto e = *(cast(Throwable*) ptr);
    size_t pos = _exception_stack.find(e);
    if (pos >= _exception_stack.length())
        return null; // not a D exception

    auto caught = e;

    // Chain inner unhandled exceptions as collateral
    for (size_t p = pos + 1; p < _exception_stack.length(); ++p)
        e = chain_exceptions(e, _exception_stack[p]);
    _exception_stack.shrink(pos);

    if (e !is caught)
    {
        if (_d_isbaseof(typeid(e), catch_type))
            *cast(Throwable*) ptr = e;
        else
            _d_throw_exception(e); // rethrow collateral
    }
    return e;
}

extern (C) bool _d_enter_cleanup(void* ptr) nothrow @nogc @trusted
{
    // Prevents LLVM from optimizing away cleanup (finally) blocks.
    return true;
}

extern (C) void _d_leave_cleanup(void* ptr) nothrow @nogc @trusted
{
}

} // version (Windows)
else
{
// Non-Windows LDC: DWARF EH is in the shared block below.
} // else (non-Windows LDC)

}
else version (Win32) // DMD Win32
{

// ──────────────────────────────────────────────────────────────────────
// Win32 SEH-based exception handling
// ──────────────────────────────────────────────────────────────────────

// Windows types (inlined to avoid core.sys.windows dependency)
alias DWORD = uint;
alias BYTE = ubyte;
alias PVOID = void*;
alias ULONG_PTR = size_t;

enum size_t EXCEPTION_MAXIMUM_PARAMETERS = 15;
enum DWORD EXCEPTION_NONCONTINUABLE = 1;
enum EXCEPTION_UNWIND = 6;
enum EXCEPTION_COLLATERAL = 0x100;

enum DWORD STATUS_DIGITAL_MARS_D_EXCEPTION =
    (3 << 30) | (1 << 29) | (0 << 28) | ('D' << 16) | 1;

struct EXCEPTION_RECORD
{
    DWORD ExceptionCode;
    DWORD ExceptionFlags;
    EXCEPTION_RECORD* ExceptionRecord;
    PVOID ExceptionAddress;
    DWORD NumberParameters;
    ULONG_PTR[EXCEPTION_MAXIMUM_PARAMETERS] ExceptionInformation;
}

enum MAXIMUM_SUPPORTED_EXTENSION = 512;

struct FLOATING_SAVE_AREA
{
    DWORD ControlWord, StatusWord, TagWord;
    DWORD ErrorOffset, ErrorSelector;
    DWORD DataOffset, DataSelector;
    BYTE[80] RegisterArea;
    DWORD Cr0NpxState;
}

struct CONTEXT
{
    DWORD ContextFlags;
    DWORD Dr0, Dr1, Dr2, Dr3, Dr6, Dr7;
    FLOATING_SAVE_AREA FloatSave;
    DWORD SegGs, SegFs, SegEs, SegDs;
    DWORD Edi, Esi, Ebx, Edx, Ecx, Eax;
    DWORD Ebp, Eip, SegCs, EFlags, Esp, SegSs;
    BYTE[MAXIMUM_SUPPORTED_EXTENSION] ExtendedRegisters;
}

struct EXCEPTION_POINTERS
{
    EXCEPTION_RECORD* ExceptionRecord;
    CONTEXT* ContextRecord;
}

enum EXCEPTION_DISPOSITION
{
    ExceptionContinueExecution,
    ExceptionContinueSearch,
    ExceptionNestedException,
    ExceptionCollidedUnwind,
}

alias LanguageSpecificHandler = extern(C)
    EXCEPTION_DISPOSITION function(
        EXCEPTION_RECORD* exceptionRecord,
        DEstablisherFrame* frame,
        CONTEXT* context,
        void* dispatcherContext);

extern (Windows) void RaiseException(DWORD, DWORD, DWORD, void*);
extern (Windows) void RtlUnwind(void* targetFrame, void* targetIp,
    EXCEPTION_RECORD* pExceptRec, void* valueForEAX);

extern(C) extern __gshared DWORD _except_list; // FS:[0]

// Data structures — compiler-generated exception handler tables (Win32)

struct DEstablisherFrame
{
    DEstablisherFrame* prev;
    LanguageSpecificHandler handler;
    DWORD table_index;
    DWORD ebp;
}

struct DHandlerInfo
{
    int prev_index;
    uint cioffset;          // offset to DCatchInfo data from start of table
    void* finally_code;     // pointer to finally code (!=null if try-finally)
}

struct DHandlerTable
{
    void* fptr;             // pointer to start of function
    uint espoffset;
    uint retoffset;
    DHandlerInfo[1] handler_info;
}

struct DCatchBlock
{
    ClassInfo type;
    uint bpoffset;          // EBP offset of catch var
    void* code;             // catch handler code pointer
}

struct DCatchInfo
{
    uint ncatches;
    DCatchBlock[1] catch_block;
}

// InFlight exception list (per-stack, swapped on fiber switches)

EXCEPTION_RECORD* inflight_exception_list = null;

extern(C) void* _d_eh_swapContext(void* newContext) nothrow @nogc
{
    auto old = inflight_exception_list;
    inflight_exception_list = cast(EXCEPTION_RECORD*) newContext;
    return old;
}

private EXCEPTION_RECORD* skip_collateral_exceptions(EXCEPTION_RECORD* n) nothrow @nogc @trusted
{
    while (n.ExceptionRecord && n.ExceptionFlags & EXCEPTION_COLLATERAL)
        n = n.ExceptionRecord;
    return n;
}

// SEH to D exception translation

private Throwable _d_translate_se_to_d_exception(
    EXCEPTION_RECORD* exceptionRecord, CONTEXT*) nothrow @nogc @trusted
{
    if (exceptionRecord.ExceptionCode == STATUS_DIGITAL_MARS_D_EXCEPTION)
        return cast(Throwable) cast(void*)(exceptionRecord.ExceptionInformation[0]);

    // Non-D (hardware) exceptions: cannot create Error objects without GC.
    terminate();
    assert(0);
}

// _d_throwc — throw a D exception via Windows SEH

private void throw_impl(Throwable h) @trusted
{
    auto refcount = h.refcount();
    if (refcount)
        h.refcount() = refcount + 1;

    _d_createTrace(h, null);
    RaiseException(STATUS_DIGITAL_MARS_D_EXCEPTION,
        EXCEPTION_NONCONTINUABLE, 1, cast(void*)&h);
}

extern(C) void _d_throwc(Throwable h) @trusted
{
    version (D_InlineAsm_X86)
        asm
        {
            naked;
            enter 0, 0;
            mov EAX, [EBP + 8];
            call throw_impl;
            leave;
            ret;
        }
}

// _d_framehandler — SEH frame handler called by OS for each frame.
// The handler table address is passed in EAX by compiler-generated thunks.

extern(C) EXCEPTION_DISPOSITION _d_framehandler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame* frame,
    CONTEXT* context,
    void* dispatcherContext) @trusted
{
    DHandlerTable* handler_table;
    asm { mov handler_table, EAX; }

    if (exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND)
    {
        // Unwind phase: call all finally blocks in this frame
        _d_local_unwind(handler_table, frame, -1, &unwindCollisionExceptionHandler);
    }
    else
    {
        // Search phase: look for a matching catch handler

        EXCEPTION_RECORD* master = null;
        ClassInfo master_class_info = null;

        int prev_ndx;
        for (auto ndx = frame.table_index; ndx != -1; ndx = prev_ndx)
        {
            auto phi = &handler_table.handler_info.ptr[ndx];
            prev_ndx = phi.prev_index;

            if (phi.cioffset)
            {
                auto pci = cast(DCatchInfo*)(cast(ubyte*) handler_table + phi.cioffset);
                auto ncatches = pci.ncatches;

                foreach (i; 0 .. ncatches)
                {
                    auto pcb = &pci.catch_block.ptr[i];

                    // Walk the collateral exception chain to find the master
                    EXCEPTION_RECORD* er = exceptionRecord;
                    master = null;
                    master_class_info = null;

                    for (;;)
                    {
                        if (er.ExceptionCode == STATUS_DIGITAL_MARS_D_EXCEPTION)
                        {
                            ClassInfo ci = (**(cast(ClassInfo**)(er.ExceptionInformation[0])));
                            if (!master && !(er.ExceptionFlags & EXCEPTION_COLLATERAL))
                            {
                                master = er;
                                master_class_info = ci;
                                break;
                            }
                            if (_d_isbaseof(ci, typeid(Error)))
                            {
                                master = er;
                                master_class_info = ci;
                            }
                        }
                        else
                        {
                            // Non-D exception — cannot translate without GC
                            terminate();
                        }

                        if (!(er.ExceptionFlags & EXCEPTION_COLLATERAL))
                            break;

                        if (er.ExceptionRecord)
                            er = er.ExceptionRecord;
                        else
                            er = inflight_exception_list;
                    }

                    if (_d_isbaseof(master_class_info, pcb.type))
                    {
                        // Found matching catch handler

                        auto original_exception = skip_collateral_exceptions(exceptionRecord);
                        if (original_exception.ExceptionRecord is null
                            && !(exceptionRecord is inflight_exception_list))
                            original_exception.ExceptionRecord = inflight_exception_list;
                        inflight_exception_list = exceptionRecord;

                        // Global unwind: call finally blocks in intervening frames
                        _d_global_unwind(frame, exceptionRecord);

                        // Local unwind: call finally blocks skipped in this frame
                        _d_local_unwind(handler_table, frame, ndx,
                            &searchCollisionExceptionHandler);

                        frame.table_index = prev_ndx;

                        // Build D exception chain from SEH records
                        EXCEPTION_RECORD* z = exceptionRecord;
                        Throwable prev = null;
                        Error master_error = null;

                        for (;;)
                        {
                            Throwable w = _d_translate_se_to_d_exception(z, context);
                            if (z == master && (z.ExceptionFlags & EXCEPTION_COLLATERAL))
                                master_error = cast(Error) w;
                            prev = Throwable.chainTogether(w, prev);
                            if (!(z.ExceptionFlags & EXCEPTION_COLLATERAL))
                                break;
                            z = z.ExceptionRecord;
                        }

                        Throwable pti;
                        if (master_error)
                        {
                            master_error.bypassedException = prev;
                            pti = master_error;
                        }
                        else
                            pti = prev;

                        inflight_exception_list = z.ExceptionRecord;

                        // Initialize catch variable and jump to handler
                        int regebp = cast(int)&frame.ebp;
                        *cast(Object*)(regebp + pcb.bpoffset) = pti;

                        {
                            uint catch_esp;
                            alias fp_t = void function();
                            fp_t catch_addr = cast(fp_t) pcb.code;
                            catch_esp = regebp - handler_table.espoffset - fp_t.sizeof;
                            asm
                            {
                                mov EAX, catch_esp;
                                mov ECX, catch_addr;
                                mov [EAX], ECX;
                                mov EBP, regebp;
                                mov ESP, EAX;
                                ret;
                            }
                        }
                    }
                }
            }
        }
    }
    return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
}

// Exception filter for __try/__except around Dmain

extern(C) int _d_exception_filter(EXCEPTION_POINTERS* eptrs,
    int retval, Object* exception_object) @trusted
{
    *exception_object = _d_translate_se_to_d_exception(
        eptrs.ExceptionRecord, eptrs.ContextRecord);
    return retval;
}

// Collision exception handlers

extern(C) EXCEPTION_DISPOSITION searchCollisionExceptionHandler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame*,
    CONTEXT*,
    void* dispatcherContext) @trusted
{
    if (!(exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND))
    {
        auto n = skip_collateral_exceptions(exceptionRecord);
        n.ExceptionFlags |= EXCEPTION_COLLATERAL;
        return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
    }
    // Collision during SEARCH phase — restart from 'frame'
    *(cast(void**) dispatcherContext) = dispatcherContext; // frame
    return EXCEPTION_DISPOSITION.ExceptionCollidedUnwind;
}

extern(C) EXCEPTION_DISPOSITION unwindCollisionExceptionHandler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame* frame,
    CONTEXT*,
    void* dispatcherContext) @trusted
{
    if (!(exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND))
    {
        auto n = skip_collateral_exceptions(exceptionRecord);
        n.ExceptionFlags |= EXCEPTION_COLLATERAL;
        return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
    }
    // Collision during UNWIND phase — restart from 'frame.prev'
    *(cast(void**) dispatcherContext) = frame.prev;
    return EXCEPTION_DISPOSITION.ExceptionCollidedUnwind;
}

// Local unwind — run finally blocks in the current frame

extern(C) void _d_local_unwind(DHandlerTable* handler_table,
    DEstablisherFrame* frame, int stop_index,
    LanguageSpecificHandler collision_handler) @trusted
{
    // Install collision handler on SEH chain
    asm
    {
        push dword ptr -1;
        push dword ptr 0;
        push collision_handler;
        push dword ptr FS:_except_list;
        mov FS:_except_list, ESP;
    }

    for (auto i = frame.table_index; i != -1 && i != stop_index;)
    {
        auto phi = &handler_table.handler_info.ptr[i];
        i = phi.prev_index;

        if (phi.finally_code)
        {
            auto catch_ebp = &frame.ebp;
            auto blockaddr = phi.finally_code;
            asm
            {
                push EBX;
                mov EBX, blockaddr;
                push EBP;
                mov EBP, catch_ebp;
                call EBX;
                pop EBP;
                pop EBX;
            }
        }
    }

    // Remove collision handler from SEH chain
    asm
    {
        pop FS:_except_list;
        add ESP, 12;
    }
}

// Global unwind — thin wrapper around RtlUnwind

extern(C) int _d_global_unwind(DEstablisherFrame* pFrame,
    EXCEPTION_RECORD* eRecord) @trusted
{
    asm
    {
        naked;
        push EBP;
        mov EBP, ESP;
        push ECX;
        push EBX;
        push ESI;
        push EDI;
        push EBP;
        push 0;
        push dword ptr 12[EBP]; // eRecord
        call __system_unwind;
        jmp __unwind_exit;
    __system_unwind:
        push dword ptr 8[EBP];  // pFrame
        call RtlUnwind;
    __unwind_exit:
        pop EBP;
        pop EDI;
        pop ESI;
        pop EBX;
        pop ECX;
        mov ESP, EBP;
        pop EBP;
        ret;
    }
}

// Local unwind for goto/return across finally blocks

extern(C) void _d_local_unwind2() @trusted
{
    asm
    {
        naked;
        jmp _d_localUnwindForGoto;
    }
}

extern(C) void _d_localUnwindForGoto(DHandlerTable* handler_table,
    DEstablisherFrame* frame, int stop_index) @trusted
{
    _d_local_unwind(handler_table, frame, stop_index,
        &searchCollisionExceptionHandler);
}

// Monitor handler stubs (for synchronized blocks)

extern(C) EXCEPTION_DISPOSITION _d_monitor_handler(
    EXCEPTION_RECORD* exceptionRecord,
    DEstablisherFrame*,
    CONTEXT*,
    void*) @trusted
{
    if (exceptionRecord.ExceptionFlags & EXCEPTION_UNWIND)
    {
        // TODO: _d_monitorexit(cast(Object)cast(void*)frame.table_index);
    }
    return EXCEPTION_DISPOSITION.ExceptionContinueSearch;
}

extern(C) void _d_monitor_prolog(void*, void*, Object) @trusted
{
    // TODO: _d_monitorenter(h);
}

extern(C) void _d_monitor_epilog(void*, void*, Object) @trusted
{
    // TODO: _d_monitorexit(h);
}


}
else version (Win64)
{

// ──────────────────────────────────────────────────────────────────────
// Win64 — RBP-chain walking with ._deh section tables
// ──────────────────────────────────────────────────────────────────────

// Data structures — compiler-generated exception handler tables

struct DHandlerInfo
{
    uint offset;            // offset from function address to start of guarded section
    uint endoffset;         // offset of end of guarded section
    int prev_index;         // previous table index
    uint cioffset;          // offset to DCatchInfo data from start of table (!=0 if try-catch)
    size_t finally_offset;  // offset to finally code to execute (!=0 if try-finally)
}

struct DHandlerTable
{
    uint espoffset;         // offset of ESP from EBP
    uint retoffset;         // offset from start of function to return code
    size_t nhandlers;       // dimension of handler_info[]
    DHandlerInfo[1] handler_info;
}

struct DCatchBlock
{
    ClassInfo type;         // catch type
    size_t bpoffset;        // EBP offset of catch var
    size_t codeoffset;      // catch handler offset
}

struct DCatchInfo
{
    size_t ncatches;        // number of catch blocks
    DCatchBlock[1] catch_block;
}

struct FuncTable
{
    void* fptr;             // pointer to start of function
    DHandlerTable* handlertable;
    uint fsize;             // size of function in bytes
}

// InFlight exception tracking (per-stack, swapped on fiber switches)

private struct InFlight
{
    InFlight* next;
    void* addr;
    Throwable t;
}

private __gshared InFlight* __inflight = null;

extern(C) void* _d_eh_swapContext(void* newContext) nothrow @nogc
{
    auto old = __inflight;
    __inflight = cast(InFlight*) newContext;
    return old;
}

// DEH section scanning — find exception handler tables in the binary

version (Windows)
    extern(C) extern __gshared ubyte __ImageBase;

private __gshared immutable(FuncTable)* _deh_start;
private __gshared immutable(FuncTable)* _deh_end;

private void ensure_deh_loaded() nothrow @nogc @trusted
{
    if (_deh_start !is null)
        return;

    version (Windows)
    {
        auto section = find_pe_section(cast(void*) &__ImageBase, "._deh\0\0\0");
        if (section.length)
        {
            _deh_start = cast(immutable(FuncTable)*) section.ptr;
            _deh_end = cast(immutable(FuncTable)*)(section.ptr + section.length);
        }
    }
    else version (linux)
    {
        // TODO: ELF section scanning for .deh
    }
}

/// PE section lookup — duplicated from urt.package to avoid import cycle.
private void[] find_pe_section(void* imageBase, string name) nothrow @nogc @trusted
{
    if (name.length > 8) return null;

    auto base = cast(ubyte*) imageBase;
    if (base[0] != 0x4D || base[1] != 0x5A)
        return null;

    auto lfanew = *cast(int*)(base + 0x3C);
    auto pe = base + lfanew;
    if (pe[0] != 'P' || pe[1] != 'E' || pe[2] != 0 || pe[3] != 0)
        return null;

    auto fileHeader = pe + 4;
    ushort numSections = *cast(ushort*)(fileHeader + 2);
    ushort optHeaderSize = *cast(ushort*)(fileHeader + 16);
    auto sections = fileHeader + 20 + optHeaderSize;

    foreach (i; 0 .. numSections)
    {
        auto sec = sections + i * 40;
        auto secName = (cast(char*) sec)[0 .. 8];
        bool match = true;
        foreach (j; 0 .. 8)
        {
            if (secName[j] != name[j])
            {
                match = false;
                break;
            }
        }
        if (match)
        {
            auto virtualSize = *cast(uint*)(sec + 8);
            auto virtualAddress = *cast(uint*)(sec + 12);
            return (base + virtualAddress)[0 .. virtualSize];
        }
    }
    return null;
}

// Handler table lookup

immutable(FuncTable)* __eh_finddata(void* address) nothrow @nogc @trusted
{
    ensure_deh_loaded();
    if (_deh_start is null)
        return null;
    return __eh_finddata_range(address, _deh_start, _deh_end);
}

immutable(FuncTable)* __eh_finddata_range(void* address,
    immutable(FuncTable)* pstart, immutable(FuncTable)* pend) nothrow @nogc @trusted
{
    for (auto ft = pstart; ; ft++)
    {
    Lagain:
        if (ft >= pend)
            break;

        version (Win64)
        {
            // MS Linker sometimes inserts zero padding between .obj sections
            if (ft.fptr == null)
            {
                ft = cast(immutable(FuncTable)*)(cast(void**) ft + 1);
                goto Lagain;
            }
        }

        immutable(void)* fptr = ft.fptr;
        version (Win64)
        {
            // Follow JMP indirection from /DEBUG linker
            if ((cast(ubyte*) fptr)[0] == 0xE9)
                fptr = fptr + 5 + *cast(int*)(fptr + 1);
        }

        if (fptr <= address && address < cast(void*)(cast(char*) fptr + ft.fsize))
            return ft;
    }
    return null;
}

// Stack frame walking

size_t __eh_find_caller(size_t regbp, size_t* pretaddr) nothrow @nogc @trusted
{
    size_t bp = *cast(size_t*) regbp;

    if (bp)
    {
        // Stack grows downward — new BP must be above old
        if (bp <= regbp)
            terminate();

        *pretaddr = *cast(size_t*)(regbp + size_t.sizeof);
    }
    return bp;
}

// _d_throwc — the core throw implementation (RBP-chain walking)

alias fp_t = int function();

extern(C) void _d_throwc(Throwable h) @trusted
{
    size_t regebp;

    version (D_InlineAsm_X86)
        asm { mov regebp, EBP; }
    else version (D_InlineAsm_X86_64)
        asm { mov regebp, RBP; }

    // Increment reference count if refcounted
    auto refcount = h.refcount();
    if (refcount)
        h.refcount() = refcount + 1;

    _d_createTrace(h, null);

    while (1)
    {
        size_t retaddr;

        regebp = __eh_find_caller(regebp, &retaddr);
        if (!regebp)
            break;

        auto func_table = __eh_finddata(cast(void*) retaddr);
        auto handler_table = func_table ? func_table.handlertable : null;
        if (!handler_table)
            continue;

        auto funcoffset = cast(size_t) func_table.fptr;
        version (Win64)
        {
            // Follow JMP indirection from /DEBUG linker
            if ((cast(ubyte*) funcoffset)[0] == 0xE9)
                funcoffset = funcoffset + 5 + *cast(int*)(funcoffset + 1);
        }

        // Find start index for retaddr in handler table
        auto dim = handler_table.nhandlers;
        auto index = -1;
        for (uint i = 0; i < dim; i++)
        {
            auto phi = &handler_table.handler_info.ptr[i];
            if (retaddr > funcoffset + phi.offset &&
                retaddr <= funcoffset + phi.endoffset)
                index = i;
        }

        // Handle inflight exception chaining
        if (dim)
        {
            auto phi = &handler_table.handler_info.ptr[index + 1];
            auto prev = cast(InFlight*) &__inflight;
            auto curr = prev.next;

            if (curr !is null && curr.addr == cast(void*)(funcoffset + phi.finally_offset))
            {
                auto e = cast(Error) h;
                if (e !is null && (cast(Error) curr.t) is null)
                {
                    e.bypassedException = curr.t;
                    prev.next = curr.next;
                }
                else
                {
                    h = Throwable.chainTogether(curr.t, h);
                    prev.next = curr.next;
                }
            }
        }

        // Walk handler table entries
        int prev_ndx;
        for (auto ndx = index; ndx != -1; ndx = prev_ndx)
        {
            auto phi = &handler_table.handler_info.ptr[ndx];
            prev_ndx = phi.prev_index;

            if (phi.cioffset)
            {
                // Catch handler
                auto pci = cast(DCatchInfo*)(cast(char*) handler_table + phi.cioffset);
                auto ncatches = pci.ncatches;

                for (uint i = 0; i < ncatches; i++)
                {
                    auto ci = **cast(ClassInfo**) h;
                    auto pcb = &pci.catch_block.ptr[i];

                    if (_d_isbaseof(ci, pcb.type))
                    {
                        // Initialize catch variable
                        *cast(void**)(regebp + pcb.bpoffset) = cast(void*) h;

                        // Jump to catch block — does not return
                        {
                            size_t catch_esp;
                            fp_t catch_addr;

                            catch_addr = cast(fp_t)(funcoffset + pcb.codeoffset);
                            catch_esp = regebp - handler_table.espoffset - fp_t.sizeof;

                            version (D_InlineAsm_X86)
                                asm
                                {
                                    mov EAX, catch_esp;
                                    mov ECX, catch_addr;
                                    mov [EAX], ECX;
                                    mov EBP, regebp;
                                    mov ESP, EAX;
                                    ret;
                                }
                            else version (D_InlineAsm_X86_64)
                                asm
                                {
                                    mov RAX, catch_esp;
                                    mov RCX, catch_esp;
                                    mov RCX, catch_addr;
                                    mov [RAX], RCX;
                                    mov RBP, regebp;
                                    mov RSP, RAX;
                                    ret;
                                }
                        }
                    }
                }
            }
            else if (phi.finally_offset)
            {
                // Finally block
                auto blockaddr = cast(void*)(funcoffset + phi.finally_offset);
                InFlight inflight;

                inflight.addr = blockaddr;
                inflight.next = __inflight;
                inflight.t = h;
                __inflight = &inflight;

                version (D_InlineAsm_X86)
                    asm
                    {
                        push EBX;
                        mov EBX, blockaddr;
                        push EBP;
                        mov EBP, regebp;
                        call EBX;
                        pop EBP;
                        pop EBX;
                    }
                else version (D_InlineAsm_X86_64)
                    asm
                    {
                        sub RSP, 8;
                        push RBX;
                        mov RBX, blockaddr;
                        push RBP;
                        mov RBP, regebp;
                        call RBX;
                        pop RBP;
                        pop RBX;
                        add RSP, 8;
                    }

                if (__inflight is &inflight)
                    __inflight = __inflight.next;
            }
        }
    }
    terminate();
}

} // version (Win64)
// Shared DWARF block — not part of the version chain above.
// Compiles on all non-Windows platforms (DMD Linux, LDC everywhere).
version (Windows) {} else
{

// ──────────────────────────────────────────────────────────────────────
// DWARF exception handling (shared by DMD and LDC)
//
// Uses the GCC/DWARF unwinder (libgcc_s / libunwind).
// pragma(mangle) selects the compiler-specific symbol names:
//   DMD:  _d_throwdwarf, __dmd_begin_catch, __dmd_personality_v0
//   LDC:  _d_throw_exception, _d_eh_enter_catch, _d_eh_personality
//
// Ported from druntime rt/dwarfeh.d.
// Copyright: Digital Mars 2015-2016 (original), uRT authors (port).
// License: Boost Software License 1.0
// ──────────────────────────────────────────────────────────────────────

// ── libunwind / libgcc_s bindings ───────────────────────────────────

private:

alias _Unwind_Ptr = size_t;
alias _Unwind_Word = size_t;
alias _Unwind_Exception_Class = ulong;
alias _uleb128_t = size_t;
alias _sleb128_t = ptrdiff_t;

alias _Unwind_Reason_Code = int;
enum
{
    _URC_NO_REASON = 0,
    _URC_FOREIGN_EXCEPTION_CAUGHT = 1,
    _URC_FATAL_PHASE2_ERROR = 2,
    _URC_FATAL_PHASE1_ERROR = 3,
    _URC_NORMAL_STOP = 4,
    _URC_END_OF_STACK = 5,
    _URC_HANDLER_FOUND = 6,
    _URC_INSTALL_CONTEXT = 7,
    _URC_CONTINUE_UNWIND = 8,
}

alias _Unwind_Action = int;
enum : _Unwind_Action
{
    _UA_SEARCH_PHASE  = 1,
    _UA_CLEANUP_PHASE = 2,
    _UA_HANDLER_FRAME = 4,
    _UA_FORCE_UNWIND  = 8,
}

alias _Unwind_Exception_Cleanup_Fn = extern(C) void function(
    _Unwind_Reason_Code, _Unwind_Exception*);

version (X86_64)
{
    align(16) struct _Unwind_Exception
    {
        _Unwind_Exception_Class exception_class;
        _Unwind_Exception_Cleanup_Fn exception_cleanup;
        _Unwind_Word private_1;
        _Unwind_Word private_2;
    }
}
else
{
    align(8) struct _Unwind_Exception
    {
        _Unwind_Exception_Class exception_class;
        _Unwind_Exception_Cleanup_Fn exception_cleanup;
        _Unwind_Word private_1;
        _Unwind_Word private_2;
    }
}

struct _Unwind_Context;

extern(C) nothrow @nogc
{
    _Unwind_Reason_Code _Unwind_RaiseException(_Unwind_Exception*);
    void _Unwind_DeleteException(_Unwind_Exception*);
    _Unwind_Word _Unwind_GetGR(_Unwind_Context*, int);
    void _Unwind_SetGR(_Unwind_Context*, int, _Unwind_Word);
    _Unwind_Ptr _Unwind_GetIP(_Unwind_Context*);
    _Unwind_Ptr _Unwind_GetIPInfo(_Unwind_Context*, int*);
    void _Unwind_SetIP(_Unwind_Context*, _Unwind_Ptr);
    void* _Unwind_GetLanguageSpecificData(_Unwind_Context*);
    _Unwind_Ptr _Unwind_GetRegionStart(_Unwind_Context*);
}


// ── ARM EABI unwinder types ────────────────────────────────────────

version (ARM)
{
    alias _Unwind_State = int;
    enum : _Unwind_State
    {
        _US_VIRTUAL_UNWIND_FRAME  = 0,
        _US_UNWIND_FRAME_STARTING = 1,
        _US_UNWIND_FRAME_RESUME   = 2,
        _US_ACTION_MASK           = 3,
        _US_FORCE_UNWIND          = 8,
    }

    extern(C) void _Unwind_Complete(_Unwind_Exception*) nothrow @nogc;
}

// ── EH register numbers (architecture-specific) ────────────────────

version (X86_64)
{
    enum eh_exception_regno = 0;
    enum eh_selector_regno = 1;
}
else version (X86)
{
    enum eh_exception_regno = 0;
    enum eh_selector_regno = 2;
}
else version (AArch64)
{
    enum eh_exception_regno = 0;
    enum eh_selector_regno = 1;
}
else version (ARM)
{
    enum eh_exception_regno = 0;
    enum eh_selector_regno = 1;
}
else version (RISCV64)
{
    enum eh_exception_regno = 10;
    enum eh_selector_regno = 11;
}
else version (RISCV32)
{
    enum eh_exception_regno = 10;
    enum eh_selector_regno = 11;
}
else version (Xtensa)
{
    enum eh_exception_regno = 2;  // a2
    enum eh_selector_regno = 3;  // a3
}
else
    static assert(0, "Unknown EH register numbers for this architecture");

// ── DWARF encoding constants ───────────────────────────────────────

enum
{
    DW_EH_PE_FORMAT_MASK = 0x0F,
    DW_EH_PE_APPL_MASK  = 0x70,
    DW_EH_PE_indirect    = 0x80,

    DW_EH_PE_omit    = 0xFF,
    DW_EH_PE_ptr     = 0x00,
    DW_EH_PE_uleb128 = 0x01,
    DW_EH_PE_udata2  = 0x02,
    DW_EH_PE_udata4  = 0x03,
    DW_EH_PE_udata8  = 0x04,
    DW_EH_PE_sleb128 = 0x09,
    DW_EH_PE_sdata2  = 0x0A,
    DW_EH_PE_sdata4  = 0x0B,
    DW_EH_PE_sdata8  = 0x0C,

    DW_EH_PE_absptr  = 0x00,
    DW_EH_PE_pcrel   = 0x10,
    DW_EH_PE_textrel = 0x20,
    DW_EH_PE_datarel = 0x30,
    DW_EH_PE_funcrel = 0x40,
    DW_EH_PE_aligned = 0x50,
}

// ── DMD exception class identifier ─────────────────────────────────

enum _Unwind_Exception_Class dmd_exception_class =
    (cast(_Unwind_Exception_Class)'D' << 56) |
    (cast(_Unwind_Exception_Class)'M' << 48) |
    (cast(_Unwind_Exception_Class)'D' << 40) |
    (cast(_Unwind_Exception_Class)'D' << 24);

// ── Compiler-specific symbol names ─────────────────────────────────

version (LDC)
{
    private enum throw_mangle = "_d_throw_exception";
    private enum catch_mangle = "_d_eh_enter_catch";
    private enum personality_mangle = "_d_eh_personality";
}
else
{
    private enum throw_mangle = "_d_throwdwarf";
    private enum catch_mangle = "__dmd_begin_catch";
    private enum personality_mangle = "__dmd_personality_v0";
}

// ── ExceptionHeader ────────────────────────────────────────────────

struct ExceptionHeader
{
    Throwable object;
    _Unwind_Exception exception_object;

    int handler;
    const(ubyte)* language_specific_data;
    _Unwind_Ptr landing_pad;

    ExceptionHeader* next;

    static ExceptionHeader* stack;  // thread-local chain
    static ExceptionHeader ehstorage;  // pre-allocated (one per thread)

    static ExceptionHeader* create(Throwable o) nothrow @nogc
    {
        import urt.mem : calloc;
        auto eh = &ehstorage;
        if (eh.object)
        {
            eh = cast(ExceptionHeader*) calloc(1, ExceptionHeader.sizeof);
            if (!eh)
                dwarf_terminate(__LINE__);
        }
        eh.object = o;
        eh.exception_object.exception_class = dmd_exception_class;
        return eh;
    }

    static void release(ExceptionHeader* eh) nothrow @nogc
    {
        import urt.mem : free;
        *eh = ExceptionHeader.init;
        if (eh != &ehstorage)
            free(eh);
    }

    void push() nothrow @nogc
    {
        next = stack;
        stack = &this;
    }

    static ExceptionHeader* pop() nothrow @nogc
    {
        auto eh = stack;
        stack = eh.next;
        return eh;
    }

    static ExceptionHeader* to_exception_header(_Unwind_Exception* eo) nothrow @nogc
    {
        return cast(ExceptionHeader*)(cast(void*) eo - ExceptionHeader.exception_object.offsetof);
    }
}

// ── Helpers ────────────────────────────────────────────────────────

_Unwind_Ptr read_unaligned(T, bool consume)(ref const(ubyte)* p) nothrow @nogc @trusted
{
    import urt.processor : SupportUnalignedLoadStore;
    static if (SupportUnalignedLoadStore)
        T value = *cast(T*) p;
    else
    {
        import urt.mem : memcpy;
        T value = void;
        memcpy(&value, p, T.sizeof);
    }

    static if (consume)
        p += T.sizeof;
    return cast(_Unwind_Ptr) value;
}

_uleb128_t u_leb128(const(ubyte)** p) nothrow @nogc
{
    auto q = *p;
    _uleb128_t result = 0;
    uint shift = 0;
    while (1)
    {
        ubyte b = *q++;
        result |= cast(_uleb128_t)(b & 0x7F) << shift;
        if ((b & 0x80) == 0)
            break;
        shift += 7;
    }
    *p = q;
    return result;
}

_sleb128_t s_leb128(const(ubyte)** p) nothrow @nogc
{
    auto q = *p;
    ubyte b;
    _sleb128_t result = 0;
    uint shift = 0;
    while (1)
    {
        b = *q++;
        result |= cast(_sleb128_t)(b & 0x7F) << shift;
        shift += 7;
        if ((b & 0x80) == 0)
            break;
    }
    if (shift < result.sizeof * 8 && (b & 0x40))
        result |= -(cast(_sleb128_t)1 << shift);
    *p = q;
    return result;
}

void dwarf_terminate(uint line) nothrow @nogc
{
    import urt.io : writef_to, WriteTarget;
    import urt.internal.stdc.stdlib : abort;
    writef_to!(WriteTarget.stderr, true)("dwarfeh({0}) fatal error", line);
    abort();
}

// ── LSDA scanning ──────────────────────────────────────────────────

enum LsdaResult
{
    not_found,
    foreign,
    corrupt,
    no_action,
    cleanup,
    handler,
}

ClassInfo get_class_info(_Unwind_Exception* exception_object, const(ubyte)* current_lsd) nothrow @nogc
{
    ExceptionHeader* eh = ExceptionHeader.to_exception_header(exception_object);
    Throwable ehobject = eh.object;
    for (ExceptionHeader* ehn = eh.next; ehn; ehn = ehn.next)
    {
        if (current_lsd != ehn.language_specific_data)
            break;
        Error e = cast(Error) ehobject;
        if (e is null || (cast(Error) ehn.object) !is null)
            ehobject = ehn.object;
    }
    return typeid(ehobject);
}

int action_table_lookup(_Unwind_Exception* exception_object, uint action_record_ptr, const(ubyte)* p_action_table, const(ubyte)* tt,
    ubyte ttype, _Unwind_Exception_Class exception_class, const(ubyte)* lsda) nothrow @nogc
{
    ClassInfo thrown_type;
    if (exception_class == dmd_exception_class)
        thrown_type = get_class_info(exception_object, lsda);

    for (auto ap = p_action_table + action_record_ptr - 1; 1; )
    {
        auto type_filter = s_leb128(&ap);
        auto apn = ap;
        auto next_record_ptr = s_leb128(&ap);

        if (type_filter <= 0)
            return -1;

        _Unwind_Ptr entry;
        const(ubyte)* tt2;
        switch (ttype & DW_EH_PE_FORMAT_MASK)
        {
            case DW_EH_PE_sdata2: entry = read_unaligned!(short,  false)(tt2 = tt - type_filter * 2); break;
            case DW_EH_PE_udata2: entry = read_unaligned!(ushort, false)(tt2 = tt - type_filter * 2); break;
            case DW_EH_PE_sdata4: entry = read_unaligned!(int,    false)(tt2 = tt - type_filter * 4); break;
            case DW_EH_PE_udata4: entry = read_unaligned!(uint,   false)(tt2 = tt - type_filter * 4); break;
            case DW_EH_PE_sdata8: entry = read_unaligned!(long,   false)(tt2 = tt - type_filter * 8); break;
            case DW_EH_PE_udata8: entry = read_unaligned!(ulong,  false)(tt2 = tt - type_filter * 8); break;
            case DW_EH_PE_ptr:    if (size_t.sizeof == 8)
                                      goto case DW_EH_PE_udata8;
                                  else
                                      goto case DW_EH_PE_udata4;
            default:
                return -1;
        }
        if (!entry)
            return -1;

        switch (ttype & DW_EH_PE_APPL_MASK)
        {
            case DW_EH_PE_absptr:
                break;
            case DW_EH_PE_pcrel:
                entry += cast(_Unwind_Ptr) tt2;
                break;
            default:
                return -1;
        }
        if (ttype & DW_EH_PE_indirect)
            entry = *cast(_Unwind_Ptr*) entry;

        ClassInfo ci = cast(ClassInfo) cast(void*) entry;

        // D exception — check class hierarchy
        if (exception_class == dmd_exception_class && _d_isbaseof(thrown_type, ci))
            return cast(int) type_filter;

        if (!next_record_ptr)
            return 0;

        ap = apn + next_record_ptr;
    }
    assert(0); // unreachable — all paths return inside the loop
}

LsdaResult scan_lsda(const(ubyte)* lsda, _Unwind_Ptr ip, _Unwind_Exception_Class exception_class, bool cleanups_only, bool prefer_handler,
    _Unwind_Exception* exception_object, out _Unwind_Ptr landing_pad, out int handler) nothrow @nogc
{
    auto p = lsda;
    if (!p)
        return LsdaResult.no_action;

    _Unwind_Ptr dw_pe_value(ubyte pe)
    {
        switch (pe)
        {
            case DW_EH_PE_sdata2:  return read_unaligned!(short,  true)(p);
            case DW_EH_PE_udata2:  return read_unaligned!(ushort, true)(p);
            case DW_EH_PE_sdata4:  return read_unaligned!(int,    true)(p);
            case DW_EH_PE_udata4:  return read_unaligned!(uint,   true)(p);
            case DW_EH_PE_sdata8:  return read_unaligned!(long,   true)(p);
            case DW_EH_PE_udata8:  return read_unaligned!(ulong,  true)(p);
            case DW_EH_PE_sleb128: return cast(_Unwind_Ptr) s_leb128(&p);
            case DW_EH_PE_uleb128: return cast(_Unwind_Ptr) u_leb128(&p);
            case DW_EH_PE_ptr:     if (size_t.sizeof == 8)
                                       goto case DW_EH_PE_udata8;
                                   else
                                       goto case DW_EH_PE_udata4;
            default:
                dwarf_terminate(__LINE__);
                return 0;
        }
    }

    ubyte lp_start = *p++;

    _Unwind_Ptr lp_base = 0;
    if (lp_start != DW_EH_PE_omit)
        lp_base = dw_pe_value(lp_start);

    ubyte ttype = *p++;
    _Unwind_Ptr tt_base = 0;
    _Unwind_Ptr tt_offset = 0;
    if (ttype != DW_EH_PE_omit)
    {
        tt_base = u_leb128(&p);
        tt_offset = (p - lsda) + tt_base;
    }

    ubyte call_site_format = *p++;
    _Unwind_Ptr call_site_table_size = dw_pe_value(DW_EH_PE_uleb128);

    _Unwind_Ptr ip_offset = ip - lp_base;
    bool no_action = false;
    auto tt = lsda + tt_offset;
    const(ubyte)* p_action_table = p + call_site_table_size;

    while (1)
    {
        if (p >= p_action_table)
        {
            if (p == p_action_table)
                break;
            return LsdaResult.corrupt;
        }

        _Unwind_Ptr call_site_start = dw_pe_value(call_site_format);
        _Unwind_Ptr call_site_range = dw_pe_value(call_site_format);
        _Unwind_Ptr call_site_lp    = dw_pe_value(call_site_format);
        _uleb128_t action_record_ptr_val = u_leb128(&p);

        if (ip_offset < call_site_start)
            break;

        if (ip_offset < call_site_start + call_site_range)
        {
            if (action_record_ptr_val)
            {
                if (cleanups_only)
                    continue;

                auto h = action_table_lookup(exception_object, cast(uint) action_record_ptr_val,
                    p_action_table, tt, ttype, exception_class, lsda);
                if (h < 0)
                    return LsdaResult.corrupt;
                if (h == 0)
                    continue;

                no_action = false;
                landing_pad = call_site_lp;
                handler = h;
            }
            else if (call_site_lp)
            {
                if (prefer_handler && handler)
                    continue;
                no_action = false;
                landing_pad = call_site_lp;
                handler = 0;
            }
            else
                no_action = true;
        }
    }

    if (no_action)
        return LsdaResult.no_action;

    if (landing_pad)
        return handler ? LsdaResult.handler : LsdaResult.cleanup;

    return LsdaResult.not_found;
}

// ── Public API ──────────────────────────────────────────────────────

pragma(mangle, catch_mangle)
extern(C) Throwable dwarfeh_begin_catch(_Unwind_Exception* exception_object) nothrow @nogc
{
    version (ARM) version (LDC)
        _Unwind_Complete(exception_object);

    ExceptionHeader* eh = ExceptionHeader.to_exception_header(exception_object);
    auto o = eh.object;
    eh.object = null;

    if (eh != ExceptionHeader.pop())
        dwarf_terminate(__LINE__);

    _Unwind_DeleteException(&eh.exception_object);
    return o;
}

extern(C) void* _d_eh_swapContextDwarf(void* newContext) nothrow @nogc
{
    auto old = ExceptionHeader.stack;
    ExceptionHeader.stack = cast(ExceptionHeader*) newContext;
    return old;
}

pragma(mangle, throw_mangle)
extern(C) void dwarfeh_throw(Throwable o)
{
    import urt.io : writeln_err, writef_to, WriteTarget;
    import urt.internal.stdc.stdlib : abort;

    ExceptionHeader* eh = ExceptionHeader.create(o);
    eh.push();

    auto refcount = o.refcount();
    if (refcount)
        o.refcount() = refcount + 1;

    extern(C) static void exception_cleanup(_Unwind_Reason_Code reason,
        _Unwind_Exception* eo) nothrow @nogc
    {
        switch (reason)
        {
            case _URC_FOREIGN_EXCEPTION_CAUGHT:
            case _URC_NO_REASON:
                ExceptionHeader.release(ExceptionHeader.to_exception_header(eo));
                break;
            default:
                dwarf_terminate(__LINE__);
        }
    }

    eh.exception_object.exception_cleanup = &exception_cleanup;
    _d_createTrace(o, null);

    auto r = _Unwind_RaiseException(&eh.exception_object);

    // Should not return — if it did, the exception was not caught.
    dwarfeh_begin_catch(&eh.exception_object);
    writeln_err("uncaught exception reached top of stack");
    auto msg = o.msg;
    if (msg.length)
        writef_to!(WriteTarget.stderr, true)("  {0}", msg);
    abort();
}

// Common personality implementation.
_Unwind_Reason_Code dwarfeh_personality_common(_Unwind_Action actions, _Unwind_Exception_Class exception_class, _Unwind_Exception* exception_object, _Unwind_Context* context) nothrow @nogc
{
    const(ubyte)* language_specific_data;
    int handler;
    _Unwind_Ptr landing_pad;

    language_specific_data = cast(const(ubyte)*) _Unwind_GetLanguageSpecificData(context);
    auto Start = _Unwind_GetRegionStart(context);

    // Get IP; use _Unwind_GetIPInfo to handle signal frames correctly.
    int ip_before_insn;
    auto ip = _Unwind_GetIPInfo(context, &ip_before_insn);
    if (!ip_before_insn)
        --ip;

    auto result = scan_lsda(language_specific_data, ip - Start, exception_class,
        (actions & _UA_FORCE_UNWIND) != 0,
        (actions & _UA_SEARCH_PHASE) != 0,
        exception_object,
        landing_pad,
        handler);
    landing_pad += Start;

    final switch (result)
    {
        case LsdaResult.not_found:
            dwarf_terminate(__LINE__);
            assert(0);

        case LsdaResult.foreign:
            dwarf_terminate(__LINE__);
            assert(0);

        case LsdaResult.corrupt:
            dwarf_terminate(__LINE__);
            assert(0);

        case LsdaResult.no_action:
            return _URC_CONTINUE_UNWIND;

        case LsdaResult.cleanup:
            if (actions & _UA_SEARCH_PHASE)
                return _URC_CONTINUE_UNWIND;
            break;

        case LsdaResult.handler:
            if (actions & _UA_SEARCH_PHASE)
            {
                if (exception_class == dmd_exception_class)
                {
                    auto eh = ExceptionHeader.to_exception_header(exception_object);
                    eh.handler = handler;
                    eh.language_specific_data = language_specific_data;
                    eh.landing_pad = landing_pad;
                }
                return _URC_HANDLER_FOUND;
            }
            break;
    }

    // Multiple exceptions in flight — chain them
    if (exception_class == dmd_exception_class)
    {
        auto eh = ExceptionHeader.to_exception_header(exception_object);
        auto current_lsd = language_specific_data;
        bool bypassed = false;

        while (eh.next)
        {
            ExceptionHeader* ehn = eh.next;

            Error e = cast(Error) eh.object;
            if (e !is null && !cast(Error) ehn.object)
            {
                current_lsd = ehn.language_specific_data;
                eh = ehn;
                bypassed = true;
                continue;
            }

            if (current_lsd != ehn.language_specific_data)
                break;

            eh.object = Throwable.chainTogether(ehn.object, eh.object);

            if (ehn.handler != handler && !bypassed)
            {
                handler = ehn.handler;
                eh.handler = handler;
                eh.language_specific_data = language_specific_data;
                eh.landing_pad = landing_pad;
            }

            eh.next = ehn.next;
            _Unwind_DeleteException(&ehn.exception_object);
        }

        if (bypassed)
        {
            eh = ExceptionHeader.to_exception_header(exception_object);
            Error e = cast(Error) eh.object;
            auto ehn = eh.next;
            e.bypassedException = ehn.object;
            eh.next = ehn.next;
            _Unwind_DeleteException(&ehn.exception_object);
        }
    }

    _Unwind_SetGR(context, eh_exception_regno, cast(_Unwind_Word) exception_object);
    _Unwind_SetGR(context, eh_selector_regno, handler);
    _Unwind_SetIP(context, landing_pad);

    return _URC_INSTALL_CONTEXT;
}

// Personality function entry points.
// ARM EABI uses a different calling convention than the standard Itanium ABI.
// FreeStanding ARM (bare-metal) uses DWARF EH, not ARM EHABI, so use the standard personality.
version (ARM)
{
    version (Beken)
        enum UseArmEhabi = true;
    else version (FreeStanding)
        enum UseArmEhabi = false;
    else version (LDC)
        enum UseArmEhabi = true;
    else
        enum UseArmEhabi = false;
}
else
    enum UseArmEhabi = false;

static if (UseArmEhabi)
{
    extern(C) _Unwind_Reason_Code _d_eh_personality(_Unwind_State state, _Unwind_Exception* exception_object, _Unwind_Context* context) nothrow @nogc
    {
        _Unwind_Action actions;
        switch (state & _US_ACTION_MASK)
        {
            case _US_VIRTUAL_UNWIND_FRAME:
                actions = _UA_SEARCH_PHASE;
                break;
            case _US_UNWIND_FRAME_STARTING:
                actions = _UA_CLEANUP_PHASE;
                break;
            case _US_UNWIND_FRAME_RESUME:
                return _URC_CONTINUE_UNWIND;
            default:
                dwarf_terminate(__LINE__);
                return _URC_FATAL_PHASE1_ERROR;
        }
        if (state & _US_FORCE_UNWIND)
            actions |= _UA_FORCE_UNWIND;

        return dwarfeh_personality_common(actions, exception_object.exception_class,
            exception_object, context);
    }
}
else
{
    pragma(mangle, personality_mangle)
    extern(C) _Unwind_Reason_Code dwarfeh_personality(int ver, _Unwind_Action actions, _Unwind_Exception_Class exception_class, _Unwind_Exception* exception_object, _Unwind_Context* context) nothrow @nogc
    {
        if (ver != 1)
            return _URC_FATAL_PHASE1_ERROR;

        return dwarfeh_personality_common(actions, exception_class,
            exception_object, context);
    }
}

// LDC-only: trivial cleanup hooks (DWARF handles cleanup via personality).
version (LDC)
{
    extern(C) bool _d_enter_cleanup(void* ptr) nothrow @nogc @trusted => true;
    extern(C) void _d_leave_cleanup(void* ptr) nothrow @nogc @trusted {}
}

} // version (!Windows) — shared DWARF EH
