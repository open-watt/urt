module urt.mem;

public import core.stdc.stddef : wchar_t;

public import urt.lifetime : emplace, moveEmplace, forward, move;
public import urt.mem.allocator;


extern(C)
{
nothrow @nogc:
    void* alloca(size_t size);

    void* memcpy(void* dest, const void* src, size_t n) pure;
    void* memmove(void* dest, const void* src, size_t n) pure;
    void* memset(void* s, int c, size_t n) pure;
    void* memzero(void* s, size_t n) pure => memset(s, 0, n);

    size_t strlen(const char* s) pure;
    int strcmp(const char* s1, const char* s2) pure;
    char* strcpy(char* dest, const char* src) pure;
    char* strcat(char* dest, const char* src);

    size_t wcslen(const wchar_t* s) pure;
//    wchar_t* wcscpy(wchar_t* dest, const wchar_t* src) pure;
//    wchar_t* wcscat(wchar_t* dest, const wchar_t* src);
//    wchar_t* wcsncpy(wchar_t* dest, const wchar_t* src, size_t n) pure;
//    wchar_t* wcsncat(wchar_t* dest, const wchar_t* src, size_t n);
}
