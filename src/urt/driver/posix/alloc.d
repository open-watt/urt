module urt.driver.posix.alloc;

import urt.mem.alloc : MemFlags;

nothrow @nogc:

enum has_realloc  = false;
enum has_expand   = false;
enum has_memsize  = true;
enum has_exec     = true;
enum has_retain   = false;
enum has_memflags = false;

void[] _alloc(size_t size, size_t alignment, MemFlags) pure
{
    void* p;
    return posix_memalign(&p, alignment <= 8 ? 8 : alignment, size) ? null : p[0 .. size];
}

void _free(void* ptr) pure
{
    free(ptr);
}


size_t _memsize(void* ptr) pure
{
    return malloc_usable_size(ptr);
}

void[] _alloc_exec(size_t size) pure
{
    void* p = mmap(null, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return (p is MAP_FAILED) ? null : p[0 .. size];
}

void _free_exec(void[] mem) pure
{
    cast(void)munmap(mem.ptr, mem.length);
}


private:

extern(C) int posix_memalign(void** memptr, size_t alignment, size_t size) pure;
extern(C) size_t malloc_usable_size(void* ptr) pure;
extern(C) void* mmap(void* addr, size_t length, int prot, int flags, int fd, long offset) pure;
extern(C) int munmap(void* addr, size_t length) pure;
extern(C) void free(void* ptr) pure;

enum PROT_READ    = 0x1;
enum PROT_WRITE   = 0x2;
enum PROT_EXEC    = 0x4;
enum MAP_PRIVATE   = 0x02;
enum MAP_ANONYMOUS = 0x20;
enum MAP_FAILED    = cast(void*)-1;
