module urt.io;

nothrow @nogc:

enum WriteTarget : ubyte
{
    stdout = 0,
    stderr = 1,
    debugstring = 2,    // Windows OutputDebugStringA
}

int write_to(WriteTarget target, bool newline = false)(const(char)[] str)
{
    static if (target == WriteTarget.stdout)
    {
        import urt.internal.stdc;
        return printf("%.*s" ~ (newline ? "\n" : ""), cast(int)str.length, str.ptr);
    }
    else static if (target == WriteTarget.stderr)
    {
        import urt.internal.stdc;
        return fprintf(stderr, "%.*s" ~ (newline ? "\n" : ""), cast(int)str.length, str.ptr);
    }
    else static if (target == WriteTarget.debugstring)
    {
        version (Windows)
        {
            import core.sys.windows.windows;
            OutputDebugStringA(str.ptr);
            static if (newline)
                OutputDebugStringA("\n");
            return cast(int)str.length + newline;
        }
        else
        {
            // is stderr the best analogy on other platforms?
            return write_to!(WriteTarget.stderr, newline)(str);
        }
    }
     else
        static assert(0, "Invalid WriteTarget");
}

int write_to(WriteTarget target, bool newline = false, Args...)(ref Args args)
    if (Args.length != 1 || !is(Args[0] : const(char)[]))
{
    import urt.string.format;
    import urt.mem.temp;

    size_t len = concat(null, args).length;
    const(char)[] t = concat(cast(char[])talloc(len), args);
    return write_to!(target, newline)(t);
}

int writef_to(WriteTarget target, bool newline = false, Args...)(const(char)[] fmt, ref Args args)
    if (Args.length > 0)
{
    import urt.string.format;
    import urt.mem.temp;

    size_t len = format(null, fmt, args).length;
    const(char)[] t = format(cast(char[])talloc(len), fmt, args);
    return write_to!(target, newline)(t);
}

alias write = write_to!(WriteTarget.stdout, false);
alias writeln = write_to!(WriteTarget.stdout, true);
alias write_err = write_to!(WriteTarget.stderr, false);
alias writeln_err = write_to!(WriteTarget.stderr, true);
alias write_debug = write_to!(WriteTarget.debugstring, false);
alias writeln_debug = write_to!(WriteTarget.debugstring, true);

int write(Args...)(ref Args args)
    if (Args.length != 1 || !is(Args[0] : const(char)[]))
    => write_to!(WriteTarget.stdout, false)(args);
int writeln(Args...)(ref Args args)
    if (Args.length != 1 || !is(Args[0] : const(char)[]))
    => write_to!(WriteTarget.stdout, true)(args);

int writef(Args...)(ref Args args)
    => writef_to!(WriteTarget.stdout, false)(args);
int writelnf(Args...)(ref Args args)
    => writef_to!(WriteTarget.stdout, true)(args);

unittest
{
    writeln("Hello, World!");
    writeln("Hello", " World!");
    writelnf("Hello, World! {0}", "wow!");

    writeln();
    writeln(10u, " why count ", 20, '?');

    write("Hello there ");
    write("mister ", "robot ");
    writef("how do {0} do?\n", "you");
}
