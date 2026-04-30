module urt.driver.windows.alloc;

version (Windows):

import urt.mem.alloc : MemFlags;

nothrow @nogc:


enum has_realloc  = true;
enum has_expand   = true;
enum has_memsize  = true;
enum has_exec     = true;
enum has_retain   = false;
enum has_memflags = false;

void[] _alloc(size_t size, size_t alignment, MemFlags) pure
{
    void* p = _aligned_malloc(size, alignment);
    return p ? p[0 .. size] : null;
}

void _free(void* ptr) pure
{
    _aligned_free(ptr);
}

void[] _realloc(void[] mem, size_t new_size, size_t alignment, MemFlags) pure
{
    void* p = _aligned_realloc(mem.ptr, new_size, alignment);
    return p ? p[0 .. new_size] : null;
}

void[] _expand(void[] mem, size_t new_size) pure
{
    if (new_size <= _aligned_msize(mem.ptr))
        return mem.ptr[0 .. new_size];
    return null;
}

size_t _memsize(void* ptr) pure
{
    return _aligned_msize(ptr);
}

void[] _alloc_exec(size_t size) pure
{
    void* p = VirtualAlloc(null, size, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    return p ? p[0 .. size] : null;
}

void _free_exec(void[] mem) pure
{
    VirtualFree(mem.ptr, 0, MEM_RELEASE);
}


private:

extern(C) void* _aligned_malloc(size_t size, size_t alignment) pure;
extern(C) void* _aligned_realloc(void* memblock, size_t size, size_t alignment) pure;
extern(C) void _aligned_free(void* memblock) pure;
extern(C) size_t _aligned_msize(void* memblock) pure;

extern(Windows) void* VirtualAlloc(void* addr, size_t size, uint type, uint protect) pure;
extern(Windows) bool VirtualFree(void* addr, size_t size, uint type) pure;

enum MEM_COMMIT             = 0x1000;
enum MEM_RESERVE            = 0x2000;
enum MEM_RELEASE            = 0x8000;
enum PAGE_EXECUTE_READWRITE = 0x40;
