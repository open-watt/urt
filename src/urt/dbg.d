module urt.dbg;

import urt.compiler;

version (X86_64)
    version = Intel;
else version (X86)
    version = Intel;

version (Intel)
{
    version (DigitalMars)
    {
//        pragma(inline, true) // DMD can't inline an asm function for some reason!
        extern(C) void breakpoint() pure nothrow @nogc
        {
            debug asm pure nothrow @nogc
            {
                int 3;
                ret;
            }
        }
    }
    else
    {
        pragma(inline, true)
        extern(C) void breakpoint() pure nothrow @nogc
        {
            debug asm pure nothrow @nogc
            {
                "int $3";
            }
        }
    }
}
else version (AArch64)
{
    pragma(inline, true)
    extern(C) void breakpoint() pure nothrow @nogc
    {
        debug asm pure nothrow @nogc
        {
            "brk #0";
        }
    }
}
else version (ARM)
{
    pragma(inline, true)
    extern(C) void breakpoint() pure nothrow @nogc
    {
        debug asm pure nothrow @nogc
        {
            "bkpt #0";
        }
    }
}
else
    static assert(0, "TODO: Unsupported architecture");
