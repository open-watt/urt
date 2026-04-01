// Minimal C stdlib bindings — only what URT actually uses.

module urt.internal.stdc.stdlib;

extern (C) nothrow @nogc:

noreturn abort() @safe;
noreturn exit(int status);

pure char* gcvt(double value, int ndigit, char* buf);
version (Windows)
    pure int _gcvt_s(const char* buffer, size_t size_in_bytes, double value, int digits);
