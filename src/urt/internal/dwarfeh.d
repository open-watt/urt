/// DWARF / Itanium-ABI exception-handling runtime.
///
/// Shared between DMD-Linux and LDC on every non-Windows target
/// (including bare-metal LDC like BL808). pragma(mangle) picks the
/// compiler-specific symbol names:
///   DMD:  _d_throwdwarf, __dmd_begin_catch, __dmd_personality_v0
///   LDC:  _d_throw_exception, _d_eh_enter_catch, _d_eh_personality
///
/// Lives in urt.internal (not urt.driver.posix) so it compiles on bare-metal
/// builds whose Makefile source list excludes urt/driver/posix/**.
///
/// Ported from druntime rt/dwarfeh.d.
module urt.internal.dwarfeh;

version (Windows) {} else:

import urt.internal.exception : ClassInfo, _d_isbaseof, _d_createTrace;


// ---------------------------------------------------------------------
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
// ---------------------------------------------------------------------

// --- libunwind / libgcc_s bindings -----------------------------------

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


// --- ARM EABI unwinder types ----------------------------------------

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

// --- EH register numbers (architecture-specific) --------------------

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

// --- DWARF encoding constants ---------------------------------------

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

// --- DMD exception class identifier ---------------------------------

enum _Unwind_Exception_Class dmd_exception_class =
    (cast(_Unwind_Exception_Class)'D' << 56) |
    (cast(_Unwind_Exception_Class)'M' << 48) |
    (cast(_Unwind_Exception_Class)'D' << 40) |
    (cast(_Unwind_Exception_Class)'D' << 24);

// --- Compiler-specific symbol names ---------------------------------

version (LDC)
{
    private enum throw_mangle = "_d_throw_exception";
    private enum catch_mangle = "_d_eh_enter_catch";
    private enum personality_mangle = "_d_eh_personality";
}
else version (GNU)
{
    private enum throw_mangle = "_d_throw";
    private enum catch_mangle = "__gdc_begin_catch";
    private enum personality_mangle = "__gdc_personality_v0";
}
else
{
    private enum throw_mangle = "_d_throwdwarf";
    private enum catch_mangle = "__dmd_begin_catch";
    private enum personality_mangle = "__dmd_personality_v0";
}

// --- ExceptionHeader ------------------------------------------------

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
        import urt.mem.alloc : alloc;
        auto eh = &ehstorage;
        if (eh.object)
        {
            eh = cast(ExceptionHeader*)alloc(ExceptionHeader.sizeof).ptr;
            if (!eh)
                dwarf_terminate(__LINE__);
        }
        eh.object = o;
        eh.exception_object.exception_class = dmd_exception_class;
        return eh;
    }

    static void release(ExceptionHeader* eh) nothrow @nogc
    {
        import urt.mem.alloc : free;
        *eh = ExceptionHeader.init;
        if (eh != &ehstorage)
            free(eh[0..1]);
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

// --- Helpers --------------------------------------------------------

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

// --- LSDA scanning --------------------------------------------------

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

        // D exception - check class hierarchy
        if (exception_class == dmd_exception_class && _d_isbaseof(thrown_type, ci))
            return cast(int) type_filter;

        if (!next_record_ptr)
            return 0;

        ap = apn + next_record_ptr;
    }
    assert(0); // unreachable - all paths return inside the loop
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

// --- Public API ------------------------------------------------------

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

    // Should not return - if it did, the exception was not caught.
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

    // Multiple exceptions in flight - chain them
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
// Bare-metal ARM uses DWARF EH, not ARM EHABI, so use the standard personality.
version (ARM)
{
    version (Beken)
        enum UseArmEhabi = true;
    else version (BareMetal)
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

