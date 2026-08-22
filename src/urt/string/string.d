module urt.string.string;

import urt.lifetime : forward, move;
import urt.mem;
import urt.hash : fnv1a, fnv1a64;
import urt.string.tailstring : TailString;

public import urt.array : Alloc_T, Alloc, Reserve_T, Reserve, Concat_T, Concat;
enum Format_T { Value }
alias Format = Format_T.Value;


enum MaxStringLen = 0x7FFF;

struct StringCacheBuilder
{
nothrow @nogc:
    this(char[] buffer) pure
    {
        assert(buffer.length >= 2 && buffer.length <= ushort.max, "Invalid buffer length");
        if (__ctfe)
            buffer[0] = buffer[1] = '\0';
        else
            *cast(ushort*)buffer.ptr = 0;
        _buffer = buffer;
        _offset = 2;
    }

    ushort add_string(const(char)[] s) pure
    {
        if (s.length == 0)
            return 0;

        assert(s.length <= MaxStringLen, "String too long");
        for (ushort offset = 2; offset < _offset;)
        {
            ushort length;
            if (__ctfe)
            {
                version (LittleEndian)
                    length = cast(ushort)(_buffer[offset] | (_buffer[offset + 1] << 8));
                else
                    length = cast(ushort)(_buffer[offset + 1] | (_buffer[offset] << 8));
            }
            else
                length = *cast(ushort*)(_buffer.ptr + offset);

            ushort result = cast(ushort)(offset + 2);
            if (length == s.length && _buffer[result .. result + length] == s[])
                return result;
            offset = cast(ushort)(result + length + (length & 1));
        }

        assert(_offset + s.length + 2 + (s.length & 1) <= _buffer.length, "Not enough space in buffer");
        if (__ctfe)
        {
            version (LittleEndian)
            {
                _buffer[_offset] = cast(char)(s.length & 0xFF);
                _buffer[_offset + 1] = cast(char)(s.length >> 8);
            }
            else
            {
                _buffer[_offset] = cast(char)(s.length >> 8);
                _buffer[_offset + 1] = cast(char)(s.length & 0xFF);
            }
        }
        else
            *cast(ushort*)(_buffer.ptr + _offset) = cast(ushort)s.length;

        ushort result = cast(ushort)(_offset + 2);
        _buffer[result .. result + s.length] = s[];
        _offset = cast(ushort)(result + s.length);
        if (_offset & 1)
            _buffer[_offset++] = '\0';
        return result;
    }

    size_t used() const pure
        => _offset;

    size_t remaining() const pure
        => _buffer.length - _offset;

    bool full() const pure
        => _offset == _buffer.length;

private:
    char[] _buffer;
    ushort _offset;
}

unittest
{
    align(2) char[32] buffer;
    StringCacheBuilder cache = StringCacheBuilder(buffer[]);
    ushort first = cache.add_string("unit");
    assert(first == cache.add_string("unit"));
    assert(as_dstring(buffer.ptr + first) == "unit");
    assert(cache.add_string(null) == 0);
}

//enum String StringLit(string s) = s.make_string;
template StringLit(const(char)[] lit, bool zeroTerminate = true)
{
    static assert(lit.length <= MaxStringLen, "String too long");

    private enum LitLen = 2 + lit.length + (zeroTerminate ? 1 : 0);
    private enum char[LitLen] LiteralData = () {
        align(2) char[LitLen] buffer;
        version (LittleEndian)
        {
            buffer[0] = lit.length & 0xFF;
            buffer[1] = cast(ubyte)(lit.length >> 8);
        }
        else
        {
            buffer[0] = cast(ubyte)(lit.length >> 8);
            buffer[1] = lit.length & 0xFF;
        }
        buffer[2 .. 2 + lit.length] = lit[];
        static if (zeroTerminate)
            buffer[$-1] = '\0'; // add a zero terminator for good measure
        return buffer;
    }();
    // ARMv5 silently reads the neighbouring halfword when this is unaligned.
    align(2)
    private __gshared immutable literal = LiteralData;

    enum StringLit = immutable(String)(literal.ptr + 2, false);
}

String make_string(const(char)[] s) nothrow @nogc
{
    if (s.length == 0)
        return String(null);

    assert(s.length <= MaxStringLen, "String too long");

    return String(alloc_string(s), false);
}

String make_string(const(char)[] s, char[] buffer) nothrow @nogc
{
    if (s.length == 0)
        return String(null);

    debug assert((cast(size_t)buffer.ptr & 1) == 0, "Buffer must be 2-byte aligned");
    assert(buffer.length >= 2 + s.length, "Not enough memory for string");

    return String(write_string(buffer.ptr + 2, s), false);
}

char* write_string(char* buffer, const(char)[] str) pure nothrow @nogc
{
    // TODO: assume the calling code has confirmed the length is within spec
    if (__ctfe)
    {
        version (LittleEndian)
        {
            buffer[-2] = cast(char)(str.length & 0xFF);
            buffer[-1] = cast(char)(str.length >> 8);
        }
        else
        {
            buffer[-2] = cast(char)(str.length >> 8);
            buffer[-1] = cast(char)(str.length & 0xFF);
        }
    }
    else
        (cast(ushort*)buffer)[-1] = cast(ushort)str.length;
    buffer[0 .. str.length] = str[];
    return buffer;
}

String as_string(const(char)* s) pure nothrow @nogc
    => String(s, false);

inout(char)[] as_dstring(inout(char)* s) pure nothrow @nogc
{
    debug assert(s !is null);

    if (__ctfe)
    {
        version (LittleEndian)
            ushort len = cast(ushort)(s[-2] | (s[-1] << 8));
        else
            ushort len = cast(ushort)(s[-1] | (s[-2] << 8));
        return s[0 .. len];
    }
    else
        return s[0 .. (cast(ushort*)s)[-1]];
}

struct String
{
nothrow @nogc:
    alias This = typeof(this);

    const(char)* ptr;

    this(typeof(null)) inout pure
    {
        this.ptr = null;
    }

    this(ref inout This rhs) inout pure
    {
        ptr = rhs.ptr;
        if (!ptr)
            return;
        if (ushort* rc = ((cast(ushort*)ptr)[-1] >> 15) ? cast(ushort*)ptr - 2 : null)
        {
            assert(*rc < 0xFFFF, "Reference count overflow");
            ++*rc;
        }
    }

    this(size_t Embed)(MutableString!Embed str) inout pure
    {
        if (!str.ptr)
            return;

        ptr = cast(inout(char*))str.ptr;
        *cast(ushort*)(ptr - 4) = 0; // rc = 0, allocator = 0 (default)
        str.ptr = null;
    }

    this(TS)(inout TailString!TS ts) inout pure
    {
        ptr = ts.ptr;
    }

    ~this() pure
    {
        if (ptr)
            dec_ref();
    }

    const(char)[] toString() const pure
        => ptr[0 .. length()];

    // TODO: I made this return ushort, but normally length() returns size_t
    ushort length() const pure
    {
        if (__ctfe)
        {
            version (LittleEndian)
                return ptr ? cast(ushort)(ptr[-2] | (ptr[-1] << 8)) & 0x7FFF : 0;
            else
                return ptr ? cast(ushort)((ptr[-1] | (ptr[-2] << 8)) & 0x7FFF) : 0;
        }
        else
            return ptr ? ((cast(ushort*)ptr)[-1] & 0x7FFF) : 0;
    }

    bool empty() const pure
        => length() == 0;

    bool opCast(T : bool)() const pure
        => ptr != null && ((cast(ushort*)ptr)[-1] & 0x7FFF) != 0;

    void opAssign(typeof(null))
    {
        if (ptr)
        {
            dec_ref();
            ptr = null;
        }
    }

    void opAssign(TS)(const(TailString!TS) ts) pure
    {
        if (ptr)
            dec_ref();

        ptr = ts.ptr;
    }

    bool opEquals(const(char)[] rhs) const pure
    {
        if (!ptr)
            return rhs.length == 0;
        ushort len = (cast(ushort*)ptr)[-1] & 0x7FFF;
        return len == rhs.length && (ptr == rhs.ptr || ptr[0 .. len] == rhs[]);
    }

    int opEquals(ref const String rhs) const pure
        => opEquals(rhs[]);

    int opEquals(size_t N)(ref const MutableString!N rhs) const pure
        => opEquals(rhs[]);

    int opEquals(size_t N)(ref const Array!N rhs) const pure
        => opEquals(rhs[]);

    int opCmp(const(char)[] rhs) const pure
    {
        import urt.algorithm : compare;
        if (!ptr)
            return rhs.length == 0 ? 0 : -1;
        return compare(ptr[0 .. length()], rhs);
    }

    int opCmp(ref const String rhs) const pure
        => opCmp(rhs[]);

    int opCmp(size_t N)(ref const MutableString!N rhs) const pure
        => opCmp(rhs[]);

    int opCmp(size_t N)(ref const Array!N rhs) const pure
        => opCmp(rhs[]);

    size_t toHash() const pure
    {
        if (!ptr)
            return 0;
        ushort len = (cast(ushort*)ptr)[-1] & 0x7FFF;
        static if (size_t.sizeof == 4)
            return fnv1a(cast(ubyte[])ptr[0 .. len]);
        else
            return fnv1a64(cast(ubyte[])ptr[0 .. len]);
    }

    const(char)[] opIndex() const pure
        => ptr[0 .. length()];

    char opIndex(size_t i) const pure
    {
        debug assert(i < length());
        return ptr[i];
    }

    const(char)[] opSlice(size_t x, size_t y) const pure
    {
        debug assert(y <= length(), "Range error");
        return ptr[x .. y];
    }

    size_t opDollar() const pure
        => length();

    bool has_rc() const pure
        => ptr && ((cast(ushort*)ptr)[-1] >> 15) != 0;

private:
    ushort* ref_counter() const pure
        => ((cast(ushort*)ptr)[-1] >> 15) ? cast(ushort*)ptr - 2 : null;

    void add_ref() pure
    {
        if (ushort* rc = ref_counter())
        {
            assert(*rc < 0xFFFF, "Reference count overflow");
            ++*rc;
        }
    }

    void dec_ref() pure
    {
        if (ushort* rc = ref_counter())
        {
            if (*rc == 0)
                free_string(cast(char*)ptr);
            else
                --*rc;
        }
    }

    this(inout(char)* str, bool ref_counted) inout pure
    {
        ptr = str;
        if (ref_counted)
            *cast(ushort*)(ptr - 2) |= 0x8000;
    }

    version (Windows)
    {
        auto __debugOverview() const pure => ptr ? ptr[0 .. length].debug_escape_string() : null;
        auto __debugExpanded() const pure => ptr ? ptr[0 .. length] : null;
        auto __debugStringView() const pure => ptr ? ptr[0 .. length] : null;
    }
}

unittest
{
    // Test StringLit
    enum hello = StringLit!"Hello";
    assert(hello.length == 5);
    assert(hello == "Hello");
    assert(hello.toString == "Hello");
    assert(hello.opDollar() == 5);

    // Test empty StringLit
    enum emptyLit = StringLit!"";
    assert(emptyLit.length == 0);
    assert(emptyLit == "");
    assert(!emptyLit); // opCast!bool

    // Test make_string (default allocator)
    // TODO: reinstate the GC for debug allocations...
//    String s1 = make_string("World");
    String s1 = StringLit!"World";
    assert(s1.length == 5);
    assert(s1 == "World");

    // Test empty string creation
    String emptyStr = make_string("");
    assert(emptyStr.ptr is null);
    assert(emptyStr.length == 0);
    assert(emptyStr == "");
    assert(!emptyStr);

    String owned = "Owned".make_string();
    assert(owned == "Owned");

    String nullStr = String(null);
    assert(nullStr.ptr is null);
    assert(nullStr.length == 0);
    assert(nullStr == "");
    assert(!nullStr);

    // TODO: reinstate once GC make_string is available
    // Test assignment and reference counting (basic check)
    String s3 = s1; // s3 references the same data as s1
    assert(s3.ptr == s1.ptr);
    assert(s3 == "World");
    s1 = null; // s1 releases its reference
    assert(s3 == "World"); // s3 should still be valid
    assert(s3.length == 5);

    // Test equality
    String s4 = StringLit!"World";
    assert(s3 == s4); // Different allocations, same content
    assert(s3 != "world"); // Case sensitive
    assert(s3 != "Worl");
    assert(s3 != "Worlds");

    // Test opIndex and opSlice
    String s5 = StringLit!"Testing";
    assert(s5[0] == 'T');
    assert(s5[6] == 'g');
    assert(s5[1 .. 4] == "est");
    assert(s5[] == "Testing");
    assert(s5[1 .. $] == "esting");
    assert(s5[0 .. $-1] == "Testin");

    // Test hashing (basic check - ensure it runs)
    size_t hash1 = s3.toHash();
    size_t hash2 = s4.toHash();
    size_t hashEmpty = emptyStr.toHash();
    assert(hash1 == hash2);
    assert(hashEmpty == 0);
    assert(StringLit!"abc".toHash() != StringLit!"abd".toHash());

    // Test conversion from MutableString
    MutableString!0 mut = "Mutable";
    String s6 = move(mut); // Takes ownership
    assert(s6 == "Mutable");
    assert(mut.ptr is null); // Original mutable string should be empty

    // Test copy construction
    String s7 = s6;
    assert(s7 == "Mutable");
    assert(s6.ptr == s7.ptr); // Should share the buffer initially
    s6 = null; // Release s6's reference
    assert(s7 == "Mutable"); // s7 should still be valid

    // Test assignment from null
    s7 = null;
    assert(s7.ptr is null);
    assert(s7.length == 0);

    // Test opCmp
    assert(StringLit!"abc".opCmp("abc") == 0);
    assert(StringLit!"abc".opCmp("abd") < 0);
    assert(StringLit!"abd".opCmp("abc") > 0);
    assert(StringLit!"ab".opCmp("abc") < 0);
    assert(StringLit!"abc".opCmp("ab") > 0);
    assert(String(null).opCmp("") == 0);
    assert(String(null).opCmp("a") < 0);
    assert(StringLit!"a".opCmp("") > 0);
}


struct StringTable(size_t n, size_t data_len, size_t max_offset = data_len)
{
nothrow @nogc:

    static assert(n > 0 && n <= ushort.max, "Invalid number of strings");
    static assert(data_len <= ushort.max, "String cache too large");

    // offsets are always even, so halving them doubles the reach of a byte
    static if (max_offset <= ubyte.max)
    {
        alias Offset = ubyte;
        enum offset_shift = 0;
    }
    else static if (max_offset <= ubyte.max * 2)
    {
        alias Offset = ubyte;
        enum offset_shift = 1;
    }
    else
    {
        alias Offset = ushort;
        enum offset_shift = 0;
    }

    enum length = n;

    Offset[n] offsets;
    align(2) char[data_len] cache = '\0';

    size_t find_first(const(char)[] s) const pure
    {
        if (__ctfe)
        {
            foreach (i; 0 .. n)
            {
                size_t offset = cast(size_t)offsets[i] << offset_shift;
                if (offset == 0)
                {
                    if (s.length == 0)
                        return i;
                    continue;
                }

                ushort len;
                version (LittleEndian)
                    len = cast(ushort)(cast(ubyte)cache[offset - 2]) |
                        cast(ushort)(cast(ubyte)cache[offset - 1]) << 8;
                else
                    len = cast(ushort)(cast(ubyte)cache[offset - 1]) |
                        cast(ushort)(cast(ubyte)cache[offset - 2]) << 8;
                if (len == s.length && cache[offset .. offset + len] == s[])
                    return i;
            }
        }
        else
        {
            foreach (i; 0 .. n)
            {
                if (opIndex(i) == s)
                    return i;
            }
        }
        return n;
    }

    String opIndex(size_t i) const pure
    {
        debug assert(i < n, "Range error");
        return offsets[i] ? as_string(cache.ptr + (offsets[i] << offset_shift)) : String(null);
    }

    size_t opDollar() const pure
        => n;

    int opApply(scope int delegate(String) nothrow @nogc dg) const
    {
        foreach (i; 0 .. n)
        {
            int r = dg(opIndex(i));
            if (r)
                return r;
        }
        return 0;
    }

    int opApply(scope int delegate(size_t, String) nothrow @nogc dg) const
    {
        foreach (i; 0 .. n)
        {
            int r = dg(i, opIndex(i));
            if (r)
                return r;
        }
        return 0;
    }
}

template make_table(const(char[])[] strings, bool dedupe = true)
{
    private enum packed = pack_strings!(strings.length)(strings, dedupe);

    enum make_table = fill_table!(StringTable!(packed.offsets.length, packed.cache.length, packed.max_offset))(packed);
}

private Table fill_table(Table, size_t count)(PackedStrings!count packed)
{
    Table table;
    foreach (i, o; packed.offsets)
    {
        assert((o >> Table.offset_shift) <= Table.Offset.max, "Offset out of range");
        table.offsets[i] = cast(Table.Offset)(o >> Table.offset_shift);
    }
    table.cache[] = packed.cache[];
    return table;
}

private struct PackedStrings(size_t count)
{
    ushort[count] offsets;
    char[] cache;
    ushort max_offset;
}

private PackedStrings!count pack_strings(size_t count)(const(char[])[] strings, bool dedupe) nothrow
{
    assert(__ctfe, "only for compile-time use");

    PackedStrings!count r;
    foreach (i, s; strings)
    {
        assert(s.length <= MaxStringLen, "String too long");
        if (s.length == 0)
            continue;

        ushort at = 0;
        if (dedupe)
        {
            foreach (j; 0 .. i)
            {
                if (strings[j][] == s[])
                {
                    at = r.offsets[j];
                    break;
                }
            }
        }
        if (at == 0)
        {
            version (LittleEndian)
                r.cache ~= [ char(s.length & 0xFF), cast(char)(s.length >> 8) ];
            else
                r.cache ~= [ cast(char)(s.length >> 8), char(s.length & 0xFF) ];
            at = cast(ushort)r.cache.length;
            r.cache ~= s[];
            if (s.length & 1)
                r.cache ~= '\0';
        }
        r.offsets[i] = at;
        if (at > r.max_offset)
            r.max_offset = at;
    }
    assert(r.cache.length <= ushort.max, "String cache too large");
    return r;
}

unittest
{
    static immutable words = make_table!([ "zero", "one", "", "three", "one" ]);

    assert(words.length == 5);
    assert(words[0] == "zero");
    assert(words[1] == "one");
    assert(words[3] == "three");

    assert(words[2] == "");
    assert(words[2].ptr is null);

    assert(words[4] == "one");
    assert(words[4].ptr is words[1].ptr);

    assert(words.cache.length == (2+4) + (2+3+1) + (2+5+1));
    static assert((words.cache.offsetof & 1) == 0);
    foreach (size_t i, String s; words)
    {
        assert(s.ptr is words[i].ptr);
        assert((cast(size_t)s.ptr & 1) == 0);
    }

    static assert(words.offsets[0].sizeof == 1);
    static assert(words.offset_shift == 0);
    static assert(words.sizeof == 5 + 1 + (2+4) + (2+3+1) + (2+5+1));

    assert(words.find_first("three") == 3);
    assert(words.find_first("one") == 1);
    assert(words.find_first("") == 2);
    assert(words.find_first("nope") == words.length);
    static assert(words.find_first("three") == 3);
    static assert(words.find_first("nope") == words.length);

    size_t visited = 0;
    foreach (String s; words)
        visited += s.length;
    assert(visited == 4 + 3 + 0 + 5 + 3);

    auto copy = words;
    assert(copy[3] == "three");
    assert(copy[3].ptr !is words[3].ptr);

    static immutable dupes = make_table!([ "zero", "one", "", "three", "one" ], false);
    assert(dupes[4] == "one");
    assert(dupes[4].ptr !is dupes[1].ptr);
    assert(dupes.cache.length == words.cache.length + (2+3+1));

    enum k64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    enum k512 = k64 ~ k64 ~ k64 ~ k64 ~ k64 ~ k64 ~ k64 ~ k64;

    static immutable big = make_table!([ "head", k64 ~ k64 ~ k64 ~ k64, "tail" ]);

    static assert(big.offsets[0].sizeof == 1);
    static assert(big.offset_shift == 1);
    assert(big.cache.length == (2+4) + (2+256) + (2+4));
    assert(big[1].length == 256 && big[1][0 .. 16] == "0123456789abcdef");
    assert(big[2] == "tail");
    assert((cast(size_t)big[2].ptr & 1) == 0);

    static immutable tail_heavy = make_table!([ "head", k512 ]);

    static assert(tail_heavy.offsets[0].sizeof == 1);
    static assert(tail_heavy.offset_shift == 0);
    assert(tail_heavy.cache.length == (2+4) + (2+512));
    assert(tail_heavy[1].length == 512);

    static immutable huge = make_table!([ "head", k512, "tail" ]);

    static assert(huge.offsets[0].sizeof == 2);
    static assert(huge.offset_shift == 0);
    assert(huge[2] == "tail");
}


struct MutableString(size_t Embed = 0)
{
nothrow @nogc:

    static assert(Embed == 0, "Not without move semantics!");

    char* ptr;

    // TODO: DELETE POSTBLIT!
    this(this)
    {
        // HACK! THIS SHOULDN'T EXIST, USE COPY-CTOR INSTEAD
        const(char)[] t = this[];
        ptr = null;
        this = t[];
    }

    this(ref const typeof(this) rh)
    {
        this(rh[]);
    }
    this(size_t E)(ref const MutableString!E rh)
        if (E != Embed)
    {
        this(rh[]);
    }

    this(typeof(null)) pure
    {
    }

    this(const(char)[] s)
    {
        if (s.length == 0)
            return;
        debug assert(s.length <= MaxStringLen, "String too long");
        reserve(cast(ushort)s.length);
        writeLength(s.length);
        ptr[0 .. s.length] = s[];
    }

    this(Alloc_T, size_t length, char pad = '\0')
    {
        debug assert(length <= MaxStringLen, "String too long");
        reserve(cast(ushort)length);
        writeLength(length);
        ptr[0 .. length] = pad;
    }

    this(Reserve_T, size_t length)
    {
        debug assert(length <= MaxStringLen, "String too long");
        reserve(cast(ushort)length);
    }

    this(Things...)(Concat_T, auto ref Things things)
    {
        append(forward!things);
    }

    this(Args...)(Format_T, const(char)[] format, auto ref Args args)
    {
        this.format(format, forward!args);
    }

    ~this() pure
    {
        free_string_buffer(ptr);
    }

    inout(char)[] toString() inout pure
        => ptr[0 .. length()];

    // TODO: I made this return ushort, but normally length() returns size_t
    ushort length() const pure
        => ptr ? ((cast(ushort*)ptr)[-1] & 0x7FFF) : 0;

    bool empty() const pure
        => length() == 0;

    size_t capacity() const pure
        => allocated();

    bool opCast(T : bool)() const pure
        => ptr != null && ((cast(ushort*)ptr)[-1] & 0x7FFF) != 0;

    bool opEquals(const(char)[] rhs) const pure
    {
        if (!ptr)
            return rhs.length == 0;
        ushort len = (cast(ushort*)ptr)[-1] & 0x7FFF;
        return len == rhs.length && (ptr == rhs.ptr || ptr[0 .. len] == rhs[]);
    }

    int opEquals(ref const String rhs) const pure
        => opEquals(rhs[]);

    int opEquals(size_t N)(ref const MutableString!N rhs) const pure
        => opEquals(rhs[]);

    int opEquals(size_t N)(ref const Array!N rhs) const pure
        => opEquals(rhs[]);

    int opCmp(const(char)[] rhs) const pure
    {
        import urt.algorithm : compare;
        if (!ptr)
            return rhs.length == 0 ? 0 : -1;
        return compare(ptr[0 .. length], rhs);
    }

    int opCmp(ref const String rhs) const pure
        => opCmp(rhs[]);

    int opCmp(size_t N)(ref const MutableString!N rhs) const pure
        => opCmp(rhs[]);

    int opCmp(size_t N)(ref const Array!N rhs) const pure
        => opCmp(rhs[]);

    size_t toHash() const pure
    {
        if (!ptr)
            return 0;
        ushort len = (cast(ushort*)ptr)[-1] & 0x7FFF;
        static if (size_t.sizeof == 4)
            return fnv1a(cast(ubyte[])ptr[0 .. len]);
        else
            return fnv1a64(cast(ubyte[])ptr[0 .. len]);
    }

    void opAssign(ref const typeof(this) rh)
    {
        opAssign(rh[]);
    }
    void opAssign(size_t E)(ref const MutableString!E rh)
    {
        opAssign(rh[]);
    }

    void opAssign(char c)
    {
        reserve(1);
        writeLength(1);
        ptr[0] = c;
    }

    void opAssign(const(char)[] s)
    {
        if (s == null)
        {
            clear();
            return;
        }
        debug assert(s.length <= MaxStringLen, "String too long");
        reserve(cast(ushort)s.length);
        writeLength(s.length);
        ptr[0 .. s.length] = s[];
    }

    void opOpAssign(string op: "~", Things)(Things things)
    {
        insert(length(), forward!things);
    }

    size_t opDollar() const pure
        => length();

    inout(char)[] opIndex() inout pure
        => ptr[0 .. length()];

    ref char opIndex(size_t i) pure
    {
        debug assert(i < length());
        return ptr[i];
    }

    char opIndex(size_t i) const pure
    {
        debug assert(i < length());
        return ptr[i];
    }

    inout(char)[] opSlice(size_t x, size_t y) inout pure
    {
        debug assert(y <= length(), "Range error");
        return ptr[x .. y];
    }

    char popFront()
    {
        char c = this[0];
        erase(0, 1);
        return c;
    }

    char popBack()
    {
        char c = this[$-1];
        erase(-1, 1);
        return c;
    }

    MutableString!E takeFront(size_t E = Embed)(size_t count)
    {
        auto r = MutableString!E(this[0 .. count]);
        erase(0, count);
        return r;
    }

    MutableString!N takeFront(size_t N)()
    {
        auto r = MutableString!N(this[0 .. N]);
        erase(0, N);
        return r;
    }

    MutableString!E takeBack(size_t E = Embed)(size_t count)
    {
        auto r = MutableString!E(this[$-count .. $]);
        erase(-count, count);
        return r;
    }

    MutableString!N takeBack(size_t N)()
    {
        auto r = MutableString!N(this[$-N .. $]);
        erase(-N, N);
        return r;
    }

    ref MutableString!Embed append(Things...)(auto ref Things things)
    {
        import urt.string.format : ConcatArg, concat_mask, make_concat_args;
        ConcatArg[Things.length] args = void;
        make_concat_args(things, args.ptr);
        return insert_impl(length(), args.ptr, concat_mask!Things);
    }

    ref MutableString!Embed append_format(Things...)(const(char)[] format, auto ref Things args)
    {
        return insert_format(length(), format, forward!args);
    }

    ref MutableString!Embed concat(Things...)(auto ref Things things)
    {
        if (ptr)
            writeLength(0);
        import urt.string.format : ConcatArg, concat_mask, make_concat_args;
        ConcatArg[Things.length] args = void;
        make_concat_args(things, args.ptr);
        return insert_impl(0, args.ptr, concat_mask!Things);
    }

    ref MutableString!Embed format(Args...)(const(char)[] format, auto ref Args args)
    {
        if (ptr)
            writeLength(0);
        return insert_format(0, format, forward!args);
    }

    ref MutableString!Embed insert(Things...)(size_t offset, auto ref Things things)
    {
        import urt.string.format : ConcatArg, concat_mask, make_concat_args;
        ConcatArg[Things.length] args = void;
        make_concat_args(things, args.ptr);
        return insert_impl(offset, args.ptr, concat_mask!Things);
    }

    ref MutableString!Embed insert_format(Things...)(size_t offset, const(char)[] format, auto ref Things args)
    {
        import urt.string.format : _format = format;

        char* oldPtr = ptr;
        size_t oldLen = length();

        size_t insertLen = _format(null, format, args).length;
        size_t newLen = oldLen + insertLen;
        if (newLen == oldLen)
            return this;
        debug assert(newLen <= MaxStringLen, "String too long");

        size_t oldAlloc = allocated();
        ptr = newLen <= oldAlloc ? oldPtr : alloc_string_buffer(grow_capacity(newLen, oldAlloc));
        memmove(ptr + offset + insertLen, oldPtr + offset, oldLen - offset);
        _format(ptr[offset .. offset + insertLen], format, forward!args);
        writeLength(newLen);

        if (oldPtr && ptr != oldPtr)
        {
            ptr[0 .. offset] = oldPtr[0 .. offset];
            free_string_buffer(oldPtr);
        }
        return this;
    }

    ref MutableString!Embed erase(ptrdiff_t offset, size_t count)
    {
        size_t len = length();
        debug assert(count <= len, "Out of bounds");

        if (offset < 0)
            offset = len + offset;
        if (offset != len - count)
        {
            debug assert(size_t(offset) <= len - count, "Out of bounds");
            size_t eraseEnd = offset + count;
            memmove(ptr + offset, ptr + eraseEnd, len - eraseEnd);
        }
        writeLength(len - count);
        return this;
    }

    void reserve(ushort bytes)
    {
        if (bytes > allocated())
        {
            char* newPtr = alloc_string_buffer(bytes);
            if (ptr != newPtr)
            {
                size_t len = length();
                newPtr[0 .. len] = ptr[0 .. len];
                free_string_buffer(ptr);
                ptr = newPtr;
                writeLength(len);
            }
        }
    }

    char[] extend(size_t length)
    {
        size_t oldLen = this.length;
        debug assert(oldLen + length <= MaxStringLen, "String too long");

        reserve(cast(ushort)(oldLen + length));
        writeLength(oldLen + length);
        return ptr[oldLen .. oldLen + length];
    }

    void clear()
    {
        if (ptr)
            writeLength(0);
    }

private:
    static if (Embed > 0)
    {
        static assert((Embed & (size_t.sizeof - 1)) == 0, "Embed must be multiple of size_t.sizeof bytes");
        char[Embed] embed;
    }

    ushort allocated() const pure nothrow @nogc
    {
        if (!ptr)
            return Embed > 0 ? Embed - 2 : 0;
        static if (Embed > 0)
        {
            if (ptr == embed.ptr + 2)
                return Embed - 2;
        }
        return (cast(ushort*)ptr)[-2];
    }

    static ushort grow_capacity(size_t target, size_t current) pure
    {
        import urt.util : next_power_of_2;
        size_t doubled = (current + 4) * 2;
        size_t total = target + 4;
        if (total <= doubled)
            total = next_power_of_2(total);
        if (total < 16)
            total = 16;
        if (total > MaxStringLen + 4)
            total = MaxStringLen + 4;
        return cast(ushort)(total - 4);
    }

    void writeLength(size_t len)
    {
        (cast(ushort*)ptr)[-1] = cast(ushort)len;
    }

    char* alloc_string_buffer(size_t len)
    {
        static if (Embed > 0)
            if (len <= Embed - 2)
                return embed.ptr + 2;
        char* buffer = cast(char*)alloc(len + 4, 2).ptr;
        *cast(ushort*)buffer = cast(ushort)len;
        return buffer + 4;
    }

    void free_string_buffer(char* buffer) pure
    {
        if (!buffer)
            return;
        static if (Embed > 0)
            if (buffer == embed.ptr + 2)
                return;
        buffer -= 4;
        free(buffer[0 .. 4 + *cast(ushort*)buffer]);
    }

    ref MutableString!Embed insert_impl(size_t offset, const(void)* raw_args, size_t arg_mask)
    {
        import urt.string.format : ConcatArg, concat_impl;
        const(ConcatArg)* args = cast(const(ConcatArg)*)raw_args;

        char* oldPtr = ptr;
        size_t oldLen = length();

        size_t insertLen = concat_impl(null, 0, args, arg_mask).length;
        size_t newLen = oldLen + insertLen;
        if (newLen == oldLen)
            return this;
        debug assert(newLen <= MaxStringLen, "String too long");

        size_t oldAlloc = allocated();
        ptr = newLen <= oldAlloc ? oldPtr : alloc_string_buffer(grow_capacity(newLen, oldAlloc));
        memmove(ptr + offset + insertLen, oldPtr + offset, oldLen - offset);
        concat_impl(ptr + offset, insertLen, args, arg_mask);
        writeLength(newLen);

        if (oldPtr && ptr != oldPtr)
        {
            ptr[0 .. offset] = oldPtr[0 .. offset];
            free_string_buffer(oldPtr);
        }
        return this;
    }

    version (Windows)
    {
        auto __debugOverview() const pure => ptr ? ptr[0 .. length].debug_escape_string() : null;
        auto __debugExpanded() const pure => ptr ? ptr[0 .. length] : null;
        auto __debugStringView() const pure => ptr ? ptr[0 .. length] : null;
    }
}

unittest
{
    // Initial tests from previous version
    MutableString!0 s;
    s.reserve(10); // Reserve some initial space
    assert(s.allocated >= 10);
    s = "Hello";
    assert(s == "Hello");
    assert(s.length == 5);

    s.append(", world!\n");
    assert(s == "Hello, world!\n");
    assert(s.length == 14);

    s = null;
    assert(s.length == 0);

    MutableString!0 s_long;
    s_long.reserve(4567);
    s_long = "Start";
    foreach (i; 0 .. 100)
    {
        s_long.append(" Loop ");
        assert(s_long.length == 5 + (i + 1) * 6);
    }
    s_long.clear();
    assert(s_long.length == 0);
    assert(s_long == "");
    s_long = "wow!";
    assert(s_long == "wow!");

    // New tests for missing methods
    MutableString!0 m;

    // opAssign(char)
    m = 'X';
    assert(m == "X");
    assert(m.length == 1);

    // opAssign(const(char)[]) - already tested implicitly

    // opOpAssign("~", ...) / append
    m ~= '!';
    assert(m == "X!");
    m ~= " More";
    assert(m == "X! More");
    m.append(" Text");
    assert(m == "X! More Text");

    // append_format
    m.clear();
    m.append_format("Value: {0}", 123);
    assert(m == "Value: 123");
    m.append_format(", String: {0}", "abc");
    assert(m == "Value: 123, String: abc");

    // concat
    m.concat("New", ' ', "String");
    assert(m == "New String");
    assert(m.length == 10);

    // format
    m.format("Formatted: {0} {1}", "test", 456);
    assert(m == "Formatted: test 456");

    // insert
    m = "String";
    m.insert(0, "My ");   // Beginning
    assert(m == "My String");
    m.insert(3, "Super "); // Middle
    assert(m == "My Super String");
    m.insert(m.length, "!"); // End (same as append)
    assert(m == "My Super String!");

    // insert_format
    m = "Data";
    m.insert_format(0, "[{0}] ", 1);
    assert(m == "[1] Data");
    m.insert_format(4, "\\{{0}\\}", "fmt");
    assert(m == "[1] {fmt}Data");
    m.insert_format(m.length, " End");
    assert(m == "[1] {fmt}Data End");

    // erase
    m = "RemoveStuff";
    m.erase(0, 6); // Remove "Remove"
    assert(m == "Stuff");
    m = "RemoveStuff";
    m.erase(6, 5); // Remove "Stuff"
    assert(m == "Remove");
    m = "RemoveStuff";
    m.erase(3, 4); // Remove "oveS"
    assert(m == "Remtuff");
    m.erase(0, m.length); // Erase all
    assert(m == "");

    // reserve - already tested implicitly

    // extend
    m = "Init";
    char[] extended = m.extend(3);
    assert(m.length == 7);
    assert(extended.length == 3);
    extended[] = "ial";
    assert(m == "Initial");

    // clear - already tested

    // opIndex, opSlice
    m = "Access";
    assert(m[0] == 'A');
    assert(m[5] == 's');
    m[1] = 'k'; // Modify via ref opIndex
    assert(m == "Akcess");
    assert(m[1..4] == "kce");
    assert(m[] == "Akcess");
    assert(m[1 .. $] == "kcess");
    assert(m[0 .. $ - 1] == "Akces");

    // opDollar
    assert(m.opDollar() == m.length);

    // Constructor variations
    auto m_alloc = MutableString!0(Alloc, 5, 'Z');
    assert(m_alloc == "ZZZZZ");

    auto m_reserve = MutableString!0(Reserve, 20);
    assert(m_reserve.length == 0);
    assert(m_reserve.allocated >= 20);

    auto m_concat = MutableString!0(Concat, "One", "Two", "Three");
    assert(m_concat == "OneTwoThree");

    auto m_format = MutableString!0(Format, "Num: {0}", 99);
    assert(m_format == "Num: 99");

    // Copy construction / assignment
    MutableString!0 m_copy_src = "Copy Me";
    MutableString!0 m_copy_dst = m_copy_src; // Uses copy constructor (or postblit hack)
    assert(m_copy_dst == "Copy Me");
    m_copy_src[0] = 'X'; // Modify original
    assert(m_copy_src == "Xopy Me");
    assert(m_copy_dst == "Copy Me"); // Destination should be independent

    MutableString!0 m_assign_dst;
    m_assign_dst = m_copy_src; // Assignment operator
    assert(m_assign_dst == "Xopy Me");
    m_copy_src[1] = 'Y';
    assert(m_copy_src == "XYpy Me");
    assert(m_assign_dst == "Xopy Me"); // Assignment should also copy
}


private:

pragma(inline, false)
char* alloc_string(const(char)[] s) pure nothrow @nogc
{
    char* buffer = cast(char*)alloc(4 + s.length, ushort.alignof).ptr;
    if (buffer is null)
        return null;
    buffer += 4;
    (cast(ushort*)buffer)[-2] = 0;
    (cast(ushort*)buffer)[-1] = cast(ushort)s.length | 0x8000;
    buffer[0 .. s.length] = s[];
    return buffer;
}

pragma(inline, false)
void free_string(char* str) pure nothrow @nogc
{
    ushort length = (cast(ushort*)str)[-1] & 0x7FFF;
    str -= 4;
    free(str[0 .. 4 + length]);
}

version (Windows)
{
    char[] debug_escape_string(const char[] s) pure nothrow @nogc
    {
        char[] t = debug_alloc!char(s.length*2);
        int d;
        foreach (i; 0 .. s.length)
        {
            switch (s.ptr[i])
            {
                case '\0':  t[d++] = '\\', t[d++] = '0';    break;
                case '\a':  t[d++] = '\\', t[d++] = 'a';    break;
                case '\b':  t[d++] = '\\', t[d++] = 'b';    break;
                case '\f':  t[d++] = '\\', t[d++] = 'f';    break;
                case '\n':  t[d++] = '\\', t[d++] = 'n';    break;
                case '\r':  t[d++] = '\\', t[d++] = 'r';    break;
                case '\t':  t[d++] = '\\', t[d++] = 't';    break;
                case '\v':  t[d++] = '\\', t[d++] = 'v';    break;
                default:    t[d++] = s.ptr[i];              break;
            }
        }
        return t[0..d];
    }
}

unittest
{
    String a = make_string("Refcounted");
    assert(a.length == 10 && a == "Refcounted");

    {
        String b = a;
        assert(b.ptr is a.ptr);
        {
            String c = b;
            assert(c == "Refcounted");
        }
        assert(b == "Refcounted");
    }
    assert(a == "Refcounted");

    String d = a;
    a = null;
    assert(d == "Refcounted");
    d = null;

    assert(make_string("").ptr is null);

    // a leak or a double free in free_string shows up here, not in the single-shot cases above
    foreach (i; 0 .. 10_000)
    {
        String t = make_string("churn");
        assert(t == "churn");
    }
}
