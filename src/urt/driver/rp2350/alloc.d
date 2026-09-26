module urt.driver.rp2350.alloc;

import urt.mem.alloc : MemFlags;

nothrow @nogc:

// malloc returns max_align_t alignment, 8 on the ARM EABI
enum size_t min_alignment = 8;

enum has_realloc  = false;
enum has_expand   = false;
enum has_memsize  = false;
enum has_exec     = false;
enum has_retain   = false;
enum has_memflags = false;

void[] _alloc(size_t size, size_t alignment, MemFlags) pure
{
    import urt.util : align_up, max;

    static if (min_alignment < (void*).sizeof)
    {
        if (alignment < (void*).sizeof)
            alignment = (void*).sizeof;
    }
    void* p = malloc(max(alignment, min_alignment) + size);
    if (p is null)
        return null;

    size_t allocptr = align_up(cast(size_t)p + min_alignment, alignment);
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
