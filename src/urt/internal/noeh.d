/// Terminating stubs for the DWARF exception runtime under `version (NoExceptions)`.
///
/// Still needed with nothing to raise: the compiler emits an implicit
/// terminating landing pad in `nothrow` functions that own cleanups.
///
/// Windows keeps its real runtime. DMD routes ordinary scope and destructor
/// unwinding through _d_local_unwind2/_d_framehandler, so stubbing those
/// breaks non-exception control flow, and Windows is not size-constrained.
module urt.internal.noeh;

version (NoExceptions):
version (Windows) {} else:

import urt.internal.exception : terminate;

nothrow @nogc:

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

pragma(mangle, throw_mangle)
extern(C) void noeh_throw(Throwable o)
{
    import urt.io : writeln_err;

    writeln_err("throw in a NoExceptions build: ", o ? o.msg : "(null)");
    terminate();
}

pragma(mangle, catch_mangle)
extern(C) Throwable noeh_begin_catch(void* exception_object)
{
    terminate();
    assert(false);
}

pragma(mangle, personality_mangle)
extern(C) int noeh_personality(int ver, int actions, ulong exception_class,
                               void* exception_object, void* context)
{
    terminate();
    assert(false);
}

version (LDC)
{
    extern(C) void _d_eh_resume_unwind(void* exception_object)
    {
        terminate();
    }
}
