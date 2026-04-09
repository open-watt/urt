module urt;

// maybe we should delete this, but a global import with the tool stuff is kinda handy...

// This enabled the use of move semantics in new compilers
//version = EnableMoveSemantics;

// Enable this to get extra but possibly slow debug info
version = ExtraDebug;

// I reckon this stuff should always be available...
// ...but we really need to keep these guys under control!
public import urt.compiler;
public import urt.platform;
public import urt.processor;
public import urt.meta : Alias, AliasSeq;
public import urt.util : min, max, swap;

import urt.io;

version (Windows)
{
    private enum crt = __traits(getTargetInfo, "cppRuntimeLibrary");
    static if (crt)
        pragma(lib, crt);
    pragma(lib, "kernel32");
}

private:

// ----------------------------------------------------------------------
// C entry point - replaces druntime's rt/dmain2.d
//
// We initialize uRT subsystems, scan the PE .minfo section for
// ModuleInfo records, run module constructors, call the D main
// (_Dmain), then run destructors.
// ----------------------------------------------------------------------

extern(C) int main(int argc, char** argv) nothrow @nogc @trusted
{
    import urt.mem;

    import urt.mem.string : init_string_heap, deinit_string_heap;
    init_string_heap(ushort.max);

    import urt.time : init_clock;
    init_clock();

    import sys.baremetal.uart : uart_init, uart_deinit;
    uart_init();

    import urt.rand;
    init_rand();

    import urt.string.string : initStringAllocators;
    initStringAllocators();

    string* args = cast(string*)alloca(string.sizeof * argc);
    string[] d_args = args[0 .. argc];
    foreach (i; 0 .. argc)
        d_args[i] = cast(string)argv[i][0 .. argv[i].strlen];

    auto modules = get_module_infos();
    run_module_ctors(modules);

    version (unittest)
    {
        import urt.internal.stdc.stdlib : exit;

        size_t executed, passed;
        foreach (m; modules)
        {
            if (m is null) continue;
            if (auto fp = cast(void function() nothrow @nogc) m.unitTest)
            {
                write_err("  running: ", m.name, " ... ");
                flush!(WriteTarget.stderr)();
                ++executed;
                if (run_test(fp))
                    ++passed;
                else
                    writeln_err("FAIL");
            }
        }

        if (executed > 0)
            writeln_err(passed, '/', executed, " modules passed unittests", );
        else
            writeln_err("No unittest functions found!");

        flush!(WriteTarget.stderr)();
        run_module_dtors(modules);
        int result = executed > 0 && passed == executed ? 0 : 1;

        version (FreeStanding)
        {
            import urt.internal.stdc.stdlib : abort;
            writeln_err("Process restarting...");
            abort();
        }
    }
    else
    {
        int result = call_dmain(d_args);

        flush!(WriteTarget.stdout)();
    }

    run_module_dtors(modules);

    uart_deinit();

    deinit_string_heap();

    return result;
}

version (unittest)
{
    // separated from main() because DMD cannot mix alloca() and exception handling
    bool run_test(void function() nothrow @nogc test) nothrow @nogc @trusted
    {
        try
        {
            test();
            writeln_err("ok");
            return true;
        }
        catch (Throwable t)
        {
            writeln_err(t.msg);
            return false;
        }
    }
}
else
{
    extern(C) int _Dmain(scope string[] args) @nogc;

    int call_dmain(scope string[] args) nothrow @nogc @trusted
    {
        int result;
        try
            result = _Dmain(args);
        catch (Throwable t)
        {
            writeln_err("Uncaught exception: ", t.msg);
            result = 1;
        }
        return result;
    }
}

// ----------------------------------------------------------------------
// Module constructor/destructor execution
// ----------------------------------------------------------------------

alias Fn = void function() nothrow @nogc;

void run_module_ctors(immutable(ModuleInfo*)[] modules) nothrow @nogc @trusted
{
    // order-independent constructors first
    foreach (m; modules)
    {
        if (m is null)
            continue;
        if (auto fp = cast(Fn) m.ictor)
            fp();
    }

    // then regular constructors
    foreach (m; modules)
    {
        if (m is null)
            continue;
        if (auto fp = cast(Fn) m.ctor)
            fp();
    }

    // TLS constructors
    foreach (m; modules)
    {
        if (m is null)
            continue;
        if (auto fp = cast(Fn) m.tlsctor)
            fp();
    }
}

void run_module_dtors(immutable(ModuleInfo*)[] modules) nothrow @nogc @trusted
{
    // TLS destructors
    foreach_reverse (m; modules)
    {
        if (m is null)
            continue;
        if (auto fp = cast(Fn) m.tlsdtor)
            fp();
    }

    // regular destructors
    foreach_reverse (m; modules)
    {
        if (m is null)
            continue;
        if (auto fp = cast(Fn) m.dtor)
            fp();
    }
}

immutable(ModuleInfo*)[] get_module_infos() nothrow @nogc @trusted
{
    version (Windows)
    {
        auto section = find_pe_section(cast(void*)&__ImageBase, ".minfo");
        if (!section.length)
            return null;
        return (cast(immutable(ModuleInfo*)*)section.ptr)[0 .. section.length / (void*).sizeof];
    }
    else version (linux)
    {
        // DMD path: _d_dso_registry stashed the .minfo section boundaries
        if (_elf_minfo_beg !is null)
            return _elf_minfo_beg[0 .. _elf_minfo_end - _elf_minfo_beg];

        // LDC path: read __minfo section via linker-generated symbols
        version (LDC)
        {
            if (&__start___minfo !is null && &__stop___minfo !is null)
                return (&__start___minfo)[0 .. &__stop___minfo - &__start___minfo];
        }

        return null;
    }
    else
    {
        // Freestanding/bare-metal: walk _Dmodule_ref linked list.
        // Populated by .init_array at startup.
        if (_Dmodule_ref is null)
            return null;

        size_t count = 0;
        for (auto p = _Dmodule_ref; p !is null; p = p.next)
            ++count;

        import urt.mem.allocator : Mallocator;
        auto arr = Mallocator.instance.allocArray!(void*)(count);
        auto p = _Dmodule_ref;
        foreach (i; 0 .. count) { arr[i] = cast(void*)p.mod; p = p.next; }
        return cast(immutable(ModuleInfo*)[])arr;
    }
}

// ----------------------------------------------------------------------
// PE .minfo section scanning - finds compiler-generated ModuleInfo pointers.
// Inline PE parsing to avoid core.sys.windows struct __init dependencies.
// ----------------------------------------------------------------------

version (Windows)
{
    extern(C) extern __gshared ubyte __ImageBase;

    void[] find_pe_section(void* image_base, string name) nothrow @nogc @trusted
    {
        if (name.length > 8) return null;

        auto base = cast(ubyte*) image_base;

        // DOS header: e_magic at offset 0 (2 bytes), e_lfanew at offset 0x3C (4 bytes)
        if (base[0] != 0x4D || base[1] != 0x5A) // 'MZ'
            return null;

        auto lfanew = *cast(int*)(base + 0x3C);
        auto pe = base + lfanew;

        // PE signature check
        if (pe[0] != 'P' || pe[1] != 'E' || pe[2] != 0 || pe[3] != 0)
            return null;

        // COFF file header starts at pe+4
        //   NumberOfSections at offset 2 (2 bytes)
        //   SizeOfOptionalHeader at offset 16 (2 bytes)
        auto file_header = pe + 4;
        ushort num_sections = *cast(ushort*)(file_header + 2);
        ushort opt_header_size = *cast(ushort*)(file_header + 16);

        // Section headers start after optional header
        auto sections = file_header + 20 + opt_header_size;

        // Each IMAGE_SECTION_HEADER is 40 bytes:
        //   Name[8] at offset 0
        //   VirtualSize at offset 8
        //   VirtualAddress at offset 12
        foreach (i; 0 .. num_sections)
        {
            auto sec = sections + i * 40;
            auto sec_name = (cast(char*) sec)[0 .. 8];

            bool match = true;
            foreach (j; 0 .. name.length)
            {
                if (sec_name[j] != name[j])
                {
                    match = false;
                    break;
                }
            }
            if (match && (name.length == 8 || sec_name[name.length] == 0))
            {
                auto virtual_size = *cast(uint*)(sec + 8);
                auto virtual_address = *cast(uint*)(sec + 12);
                return (base + virtual_address)[0 .. virtual_size];
            }
        }
        return null;
    }
}
else version (linux)
{
    // Stashed by _d_dso_registry in object.d from ELF .init_array callback (DMD)
    extern(C) extern __gshared immutable(ModuleInfo*)* _elf_minfo_beg;
    extern(C) extern __gshared immutable(ModuleInfo*)* _elf_minfo_end;

    version (LDC)
    {
        // LDC emits ModuleInfo pointers into the __minfo ELF section but does
        // not generate .init_array calls to _d_dso_registry. The linker
        // generates __start___minfo / __stop___minfo boundary symbols for us.
        extern(C) extern __gshared immutable(ModuleInfo*) __start___minfo;
        extern(C) extern __gshared immutable(ModuleInfo*) __stop___minfo;
    }
}
else
{
    // Freestanding/bare-metal: LDC chains ModuleReference structs into
    // this linked list via .init_array at startup.
    struct ModuleReference
    {
        ModuleReference* next;
        immutable(ModuleInfo)* mod;
    }
    extern(C) extern __gshared ModuleReference* _Dmodule_ref;
}
