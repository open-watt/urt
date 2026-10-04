// The host heap, with failure on demand and a live count, so a test can fail an open and see nothing leak.
module urt.driver.posix.alloc;

import urt.mem.alloc : MemFlags;

nothrow @nogc:

enum size_t min_alignment = 8;

enum has_realloc  = false;
enum has_expand   = false;
enum has_memsize  = false;
enum has_exec     = false;
enum has_retain   = false;
enum has_memflags = false;
enum has_pool_usage = false;

__gshared uint fail_after = uint.max;
__gshared int live;

void[] _alloc(size_t size, size_t alignment, MemFlags) pure
{
    void* p;
    if ((cast(bool function() pure nothrow @nogc)&take_failure)())
        return null;
    if (posix_memalign(&p, alignment < min_alignment ? min_alignment : alignment, size))
        return null;
    (cast(void function(int) pure nothrow @nogc)&count)(1);
    return p[0 .. size];
}

void _free(void* ptr) pure
{
    (cast(void function(int) pure nothrow @nogc)&count)(-1);
    free(ptr);
}


private:

bool take_failure()
{
    if (fail_after == uint.max)
        return false;
    if (fail_after == 0)
    {
        fail_after = uint.max;
        return true;
    }
    --fail_after;
    return false;
}

void count(int n)
{
    live += n;
}

extern(C) int posix_memalign(void** memptr, size_t alignment, size_t size) pure;
extern(C) void free(void* ptr) pure;
