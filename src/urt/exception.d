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
    import urt.internal.stdc : exit;

    debug
    {
        import urt.internal.stdc;
        import urt.dbg;

        if (msg.length == 0)
            msg = "Assertion failed";

        version (Windows)
        {
            import urt.internal.sys.windows.winbase;
            char[1024] buffer;
            _snprintf(buffer.ptr, buffer.length, "%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
            OutputDebugStringA(buffer.ptr);

            // Windows can have it at stdout aswell?
            printf("%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
        }
        else
        {
            // TODO: write to stderr would be better...
            printf("%.*s(%d): %.*s\n", cast(int)file.length, file.ptr, cast(int)line, cast(int)msg.length, msg.ptr);
        }

        breakpoint();
//        exit(-1); // TODO: what if some systems don't support a software breakpoint?
    }
    else
        exit(-1);
}
