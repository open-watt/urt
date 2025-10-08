module urt.mem.temp;

import urt.mem;

version = DebugTempAlloc;


enum size_t TempMemSize = 4096;


void[] talloc(size_t size) nothrow @nogc
{
    debug version (DebugTempAlloc)
    {
        import urt.string.format : InFormatFunction;
        assert(InFormatFunction == false, "It is illegal to use the temp allocator inside string conversion functions. Consider using stack or scratchpad.");
    }

    assert(size <= TempMemSize / 2, "Requested temp memory size is too large");

    if (alloc_offset + size > TempMemSize)
        alloc_offset = 0;

    void[] mem = tempMem[alloc_offset .. alloc_offset + size];
    alloc_offset += size;

    return mem;
}

void[] talloc_aligned(size_t size, size_t alignment) nothrow @nogc
{
    assert(false);
}

void[] trealloc(void[] mem, size_t newSize) nothrow @nogc
{
    if (newSize <= mem.length)
        return mem[0 .. newSize];
    void[] r = texpand(mem, newSize);
    if (!r)
    {
        r = talloc(newSize);
        if (r !is null)
            r[0 .. mem.length] = mem[];
    }
    return r;
}

void[] trealloc_aligned(void[] mem, size_t newSize, size_t alignment) nothrow @nogc
{
    assert(false);
}

void[] texpand(void[] mem, size_t newSize) nothrow @nogc
{
    if (mem.ptr + mem.length != tempMem.ptr + alloc_offset)
        return null;
    ptrdiff_t grow = newSize - mem.length;
    if (cast(size_t)(alloc_offset + grow) > TempMemSize)
        return null;
    alloc_offset += grow;
    return mem.ptr[0 .. newSize];
}

void tfree(void[] mem) nothrow @nogc
{
    // maybe do some debug accounting...?
}

char* tstringz(const(char)[] str) nothrow @nogc
{
    char* r = cast(char*)talloc(str.length + 1).ptr;
    r[0 .. str.length] = str[];
    r[str.length] = '\0';
    return r;
}
char* tstringz(const(wchar)[] str) nothrow @nogc
{
    import urt.string.uni : uni_convert;
    char* r = cast(char*)talloc(str.length*3 + 1).ptr;
    size_t len = uni_convert(str, r[0 .. str.length*3]);
    r[len] = '\0';
    return r;
}

wchar* twstringz(const(char)[] str) nothrow @nogc
{
    import urt.string.uni : uni_convert;
    wchar* r = cast(wchar*)talloc(str.length*2 + 2).ptr;
    size_t len = uni_convert(str, r[0 .. str.length]);
    r[len] = '\0';
    return r;
}
wchar* twstringz(const(wchar)[] str) nothrow @nogc
{
    wchar* r = cast(wchar*)talloc(str.length*2 + 2).ptr;
    r[0 .. str.length] = str[];
    r[str.length] = '\0';
    return r;
}

char[] tstring(T)(auto ref T value)
{
    import urt.string.format : toString;
    ptrdiff_t r = toString(value, cast(char[])tempMem[alloc_offset..$]);
    if (r < 0)
    {
        alloc_offset = 0;
        r = toString(value, cast(char[])tempMem[0..TempMemSize / 2]);
        if (r < 0)
        {
//            assert(false, "Formatted string is too large for the temp buffer!");
            return null;
        }
    }
    char[] result = cast(char[])tempMem[alloc_offset .. alloc_offset + r];
    alloc_offset += r;
    return result;
}

dchar[] tdstring(T)(auto ref T value) nothrow @nogc
{
    static if (is(T : const(char)[]) || is(T : const(wchar)[]) || is(T : const(dchar)[]))
        alias s = value;
    else
        char[] s = tstring(value);
    import urt.string.uni : uni_convert;
    dchar* r = cast(dchar*)talloc(s[].length*4).ptr;
    size_t len = uni_convert(s[], r[0 .. s.length]);
    return r[0 .. len];
}

char[] tconcat(Args...)(ref Args args)
{
    import urt.string.format : concat;
    char[] r = concat(cast(char[])tempMem[alloc_offset..$], args);
    if (!r)
    {
        alloc_offset = 0;
        r = concat(cast(char[])tempMem[0..TempMemSize / 2], args);
    }
    alloc_offset += r.length;
    return r;
}

char[] tformat(Args...)(const(char)[] fmt, ref Args args)
{
    import urt.string.format : format;
    char[] r = format(cast(char[])tempMem[alloc_offset..$], fmt, args);
    if (!r)
    {
        alloc_offset = 0;
        r = format(cast(char[])tempMem[0..TempMemSize / 2], fmt, args);
    }
    alloc_offset += r.length;
    return r;
}


class TempAllocator : NoGCAllocator
{
    static import urt.mem.alloc;

    static TempAllocator instance() nothrow @nogc => _instance;

    override void[] alloc(size_t bytes, size_t alignment = DefaultAlign) nothrow @nogc
    {
        return talloc(bytes);
    }

    override void[] realloc(void[] mem, size_t newSize, size_t alignment = DefaultAlign) nothrow @nogc
    {
        return trealloc(mem, newSize);
        // TODO...
//        return realloc(mem.ptr, newSize)[0..newSize];
        return null;
    }

    override void[] expand(void[] mem, size_t newSize) nothrow
    {
        return texpand(mem, newSize);
    }

    override void free(void[] mem) nothrow @nogc
    {
        tfree(mem);
    }

private:
    __gshared TempAllocator _instance = new TempAllocator;
}


private:

static void[TempMemSize] tempMem;
static ushort alloc_offset = 0;
