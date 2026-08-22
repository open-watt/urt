module urt.mem.string;

import urt.array;
import urt.mem;
import urt.string;



struct CacheString
{
nothrow @nogc:

    this(typeof(null)) pure 
    {
        offset = 0;
    }

    string toString() const pure
    {
        // HACK: deploy the pure hack!
        static char[] pure_hack() nothrow @nogc => string_heap[];
        string heap = (cast(immutable(char[]) function() pure nothrow @nogc)&pure_hack)();

        ushort len = *cast(ushort*)(heap.ptr + offset);
        return heap[offset + 2 .. offset + 2 + len];
    }

    size_t length() const pure
        => toString().length;

    string opIndex() const pure
        => toString();

    bool opCast(T : bool)() const pure
        => offset != 0;

    void opAssign(typeof(null)) pure
    {
        offset = 0;
    }

    bool opEquals(const(char)[] rhs) const pure
    {
        string s = toString();
        return s.length == rhs.length && (s.ptr is rhs.ptr || s[] == rhs[]);
    }

    size_t toHash() const pure
    {
        import urt.hash;

        static if (size_t.sizeof == 4)
            return fnv1a(cast(ubyte[])toString());
        else
            return fnv1a64(cast(ubyte[])toString());
    }

private:
    ushort offset;

    this(ushort offset) pure nothrow @nogc
    {
        this.offset = offset;
    }

    version (Windows)
    {
        auto __debugOverview() => toString;
        auto __debugExpanded() => toString;
        auto __debugStringView() => toString;
    }
}

void init_string_heap(uint string_heap_size) nothrow @nogc
{
    assert(!string_heap_initialised, "String heap already initialised!");
    assert(string_heap_size <= ushort.max, "String heap too large!");

    string_heap.reserve(string_heap_size);
    string_heap.resize(2);

    // write the null string to the start
    string_heap[][0 .. 2] = '\0';
    string_heap_cursor = 2;

    string_heap_initialised = true;
}

void deinit_string_heap() nothrow @nogc
{
    destroy(string_heap);
    string_heap_cursor = 0;
    string_heap_initialised = false;
}

uint get_string_heap_allocated() nothrow @nogc
{
    return string_heap_cursor;
}

uint get_string_heap_remaining() nothrow @nogc
{
    return ushort.max - string_heap_cursor;
}

CacheString add_string(const(char)[] str) pure nothrow @nogc
{
    // HACK: even though this mutates global state, the string cache is immutable after it's emplaced
    //       so, multiple calls with the same source string will always return the same result!
    static CacheString impl(const(char)[] str) nothrow @nogc
    {
        return CacheString(find_or_add_string(string_heap, string_heap_cursor, str));
    }
    return (cast(CacheString function(const(char)[]) pure nothrow @nogc)&impl)(str);
}

void* alloc_with_string_cache(size_t bytes, String[] cached_strings, const(char[])[] strings) nothrow @nogc
{
    import urt.mem.alloc;

    size_t extra = 0;
    foreach (s; strings)
        extra += 2 + s.length + (s.length & 1);

    void* ptr = alloc(bytes + extra).ptr;
    char* buffer = cast(char*)ptr + bytes;
    foreach (size_t i, str; strings)
    {
        cached_strings[i] = str.makeString(buffer[0..extra]);
        buffer += 2 + str.length + (str.length & 1);
    }

    return ptr;
}

private:

__gshared bool string_heap_initialised = false;
__gshared Array!char string_heap;
__gshared ushort string_heap_cursor = 0;

ushort find_or_add_string(ref Array!char heap, ref ushort cursor, const(char)[] str) nothrow @nogc
{
    if (str.length == 0)
        return 0;

    assert(str.length < 2^^14, "String longer than max string len (32768 chars)");

    for (ushort i = 2; i < cursor;)
    {
        ushort offset = i;
        ushort len = *cast(ushort*)(heap.ptr + i);
        i += 2;
        if (len == str.length && heap[i .. i + len] == str[])
            return offset;
        i += len + (len & 1);
    }

    size_t record_length = 2 + str.length + (str.length & 1);
    size_t end = cursor + record_length;
    assert(end <= ushort.max, "String cache exhausted the 16bit offset space!");

    ushort offset = cursor;
    char[] record = heap.extend!false(record_length);
    *cast(ushort*)record.ptr = cast(ushort)str.length;
    record[2 .. 2 + str.length] = str[];
    if (str.length & 1)
        record[$ - 1] = '\0';
    cursor = cast(ushort)end;
    return offset;
}


unittest
{
    Array!char heap;
    heap.resize(2);
    heap[][0 .. 2] = '\0';
    ushort cursor = 2;

    ushort hello = find_or_add_string(heap, cursor, "hello");
    assert(hello == 2);
    assert(*cast(ushort*)(heap.ptr + hello) == 5);
    assert(heap[hello + 2 .. hello + 7] == "hello");
    assert(find_or_add_string(heap, cursor, "hello") == hello);

    char* old_heap = heap.ptr;
    ushort world = find_or_add_string(heap, cursor, "world!");
    assert(heap.ptr !is old_heap);
    assert(world == 10);
    assert(*cast(ushort*)(heap.ptr + hello) == 5);
    assert(heap[hello + 2 .. hello + 7] == "hello");
    assert(heap[world + 2 .. world + 8] == "world!");
    assert(find_or_add_string(heap, cursor, null) == 0);
}
