// Minimal C stdio bindings — only what URT actually uses.
// FILE is opaque; we never dereference its fields.

module urt.internal.stdc.stdio;

struct FILE;

extern(C) nothrow @nogc:

size_t fread(scope void* ptr, size_t size, size_t nmemb, FILE* stream);
size_t fwrite(scope const void* ptr, size_t size, size_t nmemb, FILE* stream);
int fgetc(FILE* stream);
char* fgets(char* s, int n, FILE* stream);
int feof(FILE* stream);
int ferror(FILE* stream);
int fflush(FILE* stream);

version (CRuntime_Microsoft)
{
    FILE* __acrt_iob_func(int hnd);

    FILE* stdin()()  { return __acrt_iob_func(0); }
    FILE* stdout()() { return __acrt_iob_func(1); }
    FILE* stderr()() { return __acrt_iob_func(2); }
}
else version (CRuntime_Glibc)
{
    extern __gshared FILE* stdin;
    extern __gshared FILE* stdout;
    extern __gshared FILE* stderr;
}
else version (Darwin)
{
    private extern __gshared FILE* __stdinp;
    private extern __gshared FILE* __stdoutp;
    private extern __gshared FILE* __stderrp;

    alias stdin  = __stdinp;
    alias stdout = __stdoutp;
    alias stderr = __stderrp;
}
else version (FreeBSD)
{
    private extern __gshared FILE* __stdinp;
    private extern __gshared FILE* __stdoutp;
    private extern __gshared FILE* __stderrp;

    alias stdin  = __stdinp;
    alias stdout = __stdoutp;
    alias stderr = __stderrp;
}
else version (DragonFlyBSD)
{
    private extern __gshared FILE* __stdinp;
    private extern __gshared FILE* __stdoutp;
    private extern __gshared FILE* __stderrp;

    alias stdin  = __stdinp;
    alias stdout = __stdoutp;
    alias stderr = __stderrp;
}
else version (CRuntime_Musl)
{
    extern __gshared FILE* stdin;
    extern __gshared FILE* stdout;
    extern __gshared FILE* stderr;
}
else version (CRuntime_UClibc)
{
    extern __gshared FILE* stdin;
    extern __gshared FILE* stdout;
    extern __gshared FILE* stderr;
}
else version (CRuntime_Bionic)
{
    private extern __gshared FILE[3] __sF;

    @property FILE* stdin()()  { return &__sF[0]; }
    @property FILE* stdout()() { return &__sF[1]; }
    @property FILE* stderr()() { return &__sF[2]; }
}
else version (CRuntime_Newlib)
{
    private struct _reent
    {
        int _errno;
        FILE* _stdin;
        FILE* _stdout;
        FILE* _stderr;
    }

    private extern(C) _reent* __getreent();

    @property FILE* stdin()()  { return __getreent()._stdin; }
    @property FILE* stdout()() { return __getreent()._stdout; }
    @property FILE* stderr()() { return __getreent()._stderr; }
}
else version (WASI)
{
    extern __gshared FILE* stdin;
    extern __gshared FILE* stdout;
    extern __gshared FILE* stderr;
}
else version (FreeStanding)
{
    // no stdio streams — io.d uses UART directly
}
else
{
    static assert(false, "Unsupported platform");
}
