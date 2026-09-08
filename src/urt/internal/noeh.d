/// Terminating entry points for compiler-generated exception cleanup paths.
module urt.internal.noeh;

version (NoExceptions):

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
    version (Windows)
        private enum throw_mangle = "_d_throwc";
    else
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

version (Windows)
{
    version (DigitalMars) version (X86)
    {
        // DMD Win32 uses handler tables for ordinary return/goto cleanup.
        private struct Handler
        {
            int previous;
            uint catch_offset;
            void* finally_code;
        }

        private struct HandlerTable
        {
            void* function_start;
            uint stack_offset;
            uint return_offset;
            Handler[1] handlers;
        }

        private struct Frame
        {
            void* previous;
            void* handler;
            int index;
            uint bp;
        }

        extern(C) int _d_framehandler(void*, void*, void*, void*)
        {
            terminate();
            assert(false);
        }

        extern(C) void _d_local_unwind2() @trusted
        {
            asm nothrow @nogc
            {
                naked;
                jmp local_unwind;
            }
        }

        private extern(C) void local_unwind(HandlerTable* table, Frame* frame, int stop) @trusted
        {
            for (int i = frame.index; i != -1 && i != stop;)
            {
                Handler* handler = &table.handlers.ptr[i];
                i = handler.previous;
                if (!handler.finally_code)
                    continue;
                auto parent_bp = &frame.bp;
                void* code = handler.finally_code;
                asm nothrow @nogc
                {
                    push EBX;
                    mov EBX, code;
                    push EBP;
                    mov EBP, parent_bp;
                    call EBX;
                    pop EBP;
                    pop EBX;
                }
            }
        }
    }
}
else
{
    pragma(mangle, catch_mangle)
    extern(C) Throwable noeh_begin_catch(void* exception_object)
    {
        terminate();
        assert(false);
    }

    pragma(mangle, personality_mangle)
    extern(C) int noeh_personality(int ver, int actions, ulong exception_class, void* exception_object, void* context)
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
}

unittest
{
    int leave(bool early, ref uint order) nothrow @nogc
    {
        scope(exit) order = order * 10 + 1;
        try
        {
            scope(exit) order = order * 10 + 2;
            if (early)
                return 11;
            goto done;
        }
        finally
            order = order * 10 + 3;
    done:
        return 22;
    }

    uint order;
    assert(leave(true, order) == 11 && order == 231);
    order = 0;
    assert(leave(false, order) == 22 && order == 231);
}
