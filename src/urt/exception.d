/// Assert handler registration for uRT.
module urt.exception;

nothrow @nogc:


alias AssertHandler = void function(string file, size_t line, string msg) nothrow @nogc;

AssertHandler assert_handler() @property nothrow @nogc @trusted
    => _assert_handler;

void assert_handler(AssertHandler handler) @property nothrow @nogc @trusted
{
    if (handler is null)
        _assert_handler = &urt_assert;
    else
        _assert_handler = handler;
}


private:

__gshared AssertHandler _assert_handler = &urt_assert;

void urt_assert(string file, size_t line, string msg) nothrow @nogc
{
    if (msg.length == 0)
        msg = "Assertion failed";

    version (BareMetal)
    {
        import urt.driver.uart : uart0_puts;
        import urt.mem.temp : tconcat;
        uart0_puts(tconcat("\n*** ASSERT: ", msg, " at ", file, ':', line, '\n'));
        while (true) {}
    }
    else version (Espressif)
    {
        import urt.io : writef_to, WriteTarget;
        writef_to!(WriteTarget.stdout, true)("*** ASSERT: {2} at {0}:{1}", file, line, msg);
        import urt.internal.stdc.stdlib : exit;
        exit(-1);
    }
    else
    {
        debug
        {
            import urt.io : writef_to, WriteTarget;
            import urt.dbg;

            version (Windows)
                writef_to!(WriteTarget.debugstring, true)("{0}({1}): {2}", file, line, msg);
            writef_to!(WriteTarget.stdout, true)("{0}({1}): {2}", file, line, msg);

            breakpoint();
        }
        else
        {
            import urt.internal.stdc.stdlib : exit;
            exit(-1);
        }
    }
}
