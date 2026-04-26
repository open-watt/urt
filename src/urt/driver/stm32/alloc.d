module urt.driver.stm32.alloc;

import urt.mem.alloc : MemFlags;

nothrow @nogc:

enum has_realloc  = false;
enum has_expand   = false;
enum has_memsize  = false;
enum has_exec     = false;
enum has_retain   = false; // TODO: backup SRAM
enum has_memflags = false; // TODO: TCM vs SRAM

void[] _alloc(size_t size, size_t alignment, MemFlags) pure
{
    import urt.util : align_down;

    size_t header_size = (void*).sizeof + alignment;
    void* p = malloc(header_size + size);
    if (p is null)
        return null;

    size_t allocptr = align_down(cast(size_t)p + header_size, alignment);
    (cast(void**)allocptr)[-1] = p;
    return (cast(void*)allocptr)[0 .. size];
}

void _free(void* ptr) pure
{
    free((cast(void**)ptr)[-1]);
}


private:

extern(C) void* malloc(size_t size) pure;
extern(C) void free(void* ptr) pure;
