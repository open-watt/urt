module urt.mem.string;

import urt.mem;
import urt.string;


// TODO: THIS IS TEMP!! REMOVE ME!!
shared static this()
{
    initStringHeap(ushort.max);
}


struct StringCache
{
}


struct CacheString
{
nothrow @nogc:
    alias toString this;

    this(typeof(null)) pure 
    {
        offset = 0;
    }

    string toString() const pure
    {
        // HACK: deploy the pure hack!
        static char[] pureHack() nothrow @nogc => stringHeap;
        string heap = (cast(immutable(char[]) function() pure nothrow @nogc)&pureHack)();

        ushort len = *cast(ushort*)(heap.ptr + offset);
        return heap[offset + 2 .. offset + 2 + len];
    }

    immutable(char)* ptr() const pure
        => toString().ptr;

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

    auto __debugOverview() => toString;
    auto __debugExpanded() => toString;
    auto __debugStringView() => toString;
}

void initStringHeap(uint stringHeapSize) nothrow
{
    assert(stringHeapInitialised == false, "String heap already initialised!");
    assert(stringHeapSize <= ushort.max, "String heap too large!");

    stringHeap = defaultAllocator.allocArray!char(stringHeapSize);

    // write the null string to the start
    stringHeap[0..2] = 0;
    stringHeapCursor = 2;

    stringHeapInitialised = true;
}

void deinitStringHeap() nothrow
{
}

uint getStringHeapAllocated() nothrow @nogc
{
    return stringHeapCursor;
}

uint getStringHeapRemaining() nothrow @nogc
{
    return cast(uint)stringHeap.length - stringHeapCursor;
}

CacheString addString(const(char)[] str) pure nothrow @nogc
{
    // HACK: even though this mutates global state, the string cache is immutable after it's emplaced
    //       so, multiple calls with the same source string will always return the same result!
    static CacheString impl(const(char)[] str) nothrow @nogc
    {
        // null string
        if (str.length == 0)
            return CacheString(0);

        assert(str.length < 2^^14, "String longer than max string len (32768 chars)");

        // first we scan to see if it's already in here...
        for (ushort i = 2; i < stringHeapCursor;)
        {
            ushort offset = i;
            ushort len = *cast(ushort*)(stringHeap.ptr + i);
            i += 2;
            if (len == str.length && stringHeap[i .. i + len] == str[])
                return CacheString(offset);
            i += len + (len & 1);
        }

        // add the string to the heap...
        assert(stringHeapCursor + str.length < stringHeap.length, "String heap overflow!");

        char[] heap = stringHeap[stringHeapCursor .. $];
        ushort offset = stringHeapCursor;

        *cast(ushort*)heap.ptr = cast(ushort)str.length;
        heap[2 .. 2 + str.length] = str[];
        stringHeapCursor += str.length + 2;
        if (stringHeapCursor & 1)
            stringHeap[stringHeapCursor++] = '\0';

        return CacheString(offset);
    }
    return (cast(CacheString function(const(char)[]) pure nothrow @nogc)&impl)(str);
}

void* allocWithStringCache(size_t bytes, String[] cachedStrings, const(char[])[] strings) nothrow @nogc
{
    import urt.mem.alloc;

    size_t extra = 0;
    foreach (s; strings)
        extra += 2 + s.length + (s.length & 1);

    void* ptr = alloc(bytes + extra).ptr;
    char* buffer = cast(char*)ptr + bytes;
    foreach (size_t i, str; strings)
    {
        cachedStrings[i] = str.makeString(buffer[0..extra]);
        buffer += 2 + str.length + (str.length & 1);
    }

    return ptr;
}

//T* allocWithStringCache(T)(char*[] cachedStrings, const(char)[] strings...)
//{
//    T* item = cast(T*)allocWithStringCache(T.sizeof, cachedStrings, strings);
//    // construct!
//    return item;
//}

class StringAllocator : NoGCAllocator
{
    override void[] alloc(size_t bytes, size_t alignment = 1) nothrow @nogc
    {
        assert(stringHeapCursor + bytes < stringHeap.length, "String heap overflow!");

        char[] heap = cast(char[])stringHeap;
        return heap[stringHeapCursor .. stringHeapCursor + bytes];
    }

    override void free(void[] mem) nothrow @nogc
    {
        // you don't free cached strings!
    }
}



private:

__gshared bool stringHeapInitialised = false;
__gshared char[] stringHeap = null;
__gshared ushort stringHeapCursor = 0;


unittest
{
    // TODO: uncomment this when all the global/static boot-time string allocations are removed
/+
    initStringHeap(1024);

    CacheString s1 = addString("hello");
    assert(s1.offset == 1);
    assert(s1.length == 5);
    assert(s1[] == "hello");
    assert(!!s1 == true);
    CacheString s2 = addString("hello");
    assert(s2.offset == 1);
    CacheString s3 = addString("hello", false);
    assert(s3.offset == 7);
    CacheString s4 = addString(null);
    assert(s4.offset == 0);
    assert(s4.ptr == stringHeap.ptr + 1);
    assert(!!s4 == false);
    CacheString s5 = addString("");
    assert(s5.offset == 0);
    CacheString s6 = addString("really really really really really really really really really really really really really really really really really long string!");
    assert(s6.length == 131);
    assert(s6.ptr == stringHeap.ptr + s6.offset + 2);
    assert(s6[] == "really really really really really really really really really really really really really really really really really long string!");
    CacheString s7 = addString("really really really really really really really really really really really really really really really really really long string!");
    assert(s7.offset == s6.offset);
+/
}
