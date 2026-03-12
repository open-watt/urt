module urt.result;

nothrow @nogc:


struct Result
{
nothrow @nogc:
    enum success = Result();

    uint system_code = 0;

    bool opCast(T : bool)() const
        => system_code == 0;

    bool succeeded() const
        => system_code == 0;
    bool failed() const
        => system_code != 0;
}

struct SizeResult
{
nothrow @nogc:
    this(size_t size)
    {
        debug assert(size <= ptrdiff_t.max, "Size too large to fit in a signed integer!");
        this.size = size;
    }
    this(Result result)
    {
        static if (size_t.sizeof == 4)
            assert(cast(int)result.system_code >= 0, "Negative result codes not supported on 32-bit machines!");
        this.size = -cast(ptrdiff_t)result.system_code;
    }

    ptrdiff_t size = 0;

    bool opCast(T : bool)() const
        => size >= 0;

    bool succeeded() const
        => size >= 0;
    bool failed() const
        => size < 0;

    Result result() const
        => size >= 0 ? Result.success : Result(cast(uint)-size);
}

struct StringResult
{
nothrow @nogc:
    enum success = StringResult();

    const(char)[] message = null;

    bool opCast(T : bool)() const
        => message is null;

    bool succeeded() const
        => message is null;
    bool failed() const
        => message !is null;
}

// TODO: should we have a way to convert Result to StringResult, so we can format error messages?


version (Windows)
{
    import urt.internal.sys.windows;

    enum InternalResult : Result
    {
        success =           Result.success,
        failed =            Result(ERROR_GEN_FAILURE),
        buffer_too_small =  Result(ERROR_INSUFFICIENT_BUFFER),
        invalid_parameter = Result(ERROR_INVALID_PARAMETER),
        data_error =        Result(ERROR_INVALID_DATA),
        unsupported =       Result(ERROR_NOT_SUPPORTED),
        out_of_range =      Result(ERROR_ARITHMETIC_OVERFLOW),
        already_exists =    Result(ERROR_ALREADY_EXISTS),
        timeout =           Result(ERROR_TIMEOUT),
        aborted =           Result(ERROR_OPERATION_ABORTED),
        no_memory =         Result(ERROR_NOT_ENOUGH_MEMORY),
    }

    Result win32_result(uint err)
        => Result(err);
    Result getlasterror_result()
        => Result(GetLastError());
}
else version (Posix)
{
    import urt.internal.stdc;

    extern (C) private int* __errno_location() nothrow @nogc;

    @property int errno() nothrow @nogc @trusted
    {
        return *__errno_location();
    }

    enum InternalResult : Result
    {
        success =           Result.success,
        failed =            Result(EIO), // not a good general failure, but a lot of people use it this way
        buffer_too_small =  Result(ERANGE),
        invalid_parameter = Result(EINVAL),
        data_error =        Result(EILSEQ),
        unsupported =       Result(ENOTSUP),
        out_of_range =      Result(ERANGE),
        already_exists =    Result(EEXIST),
        timeout =           Result(ETIMEDOUT),
        aborted =           Result(EINTR),
        no_memory =         Result(ENOMEM),
    }

    Result posix_result(int err)
        => Result(err);
    Result errno_result()
        => Result(errno);
}
