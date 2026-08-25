module urt.meta.enuminfo;

import urt.algorithm : binary_search;
import urt.bimap : BiMap, StaticBiMap, static_bimap_write_string, synthesise_bimap_storage;
import urt.kvp : KVP;
import urt.traits : EnumType, is_enum, Unqual;
import urt.mem;
import urt.util : align_up;
import urt.variant;

nothrow @nogc:


// UDA for bitfield declarations
struct bitfield {}

// UDA to attach a human-readable display name to an enum member; an empty name is no display name
struct display_name
{
    string name;
}

template is_bitfield_enum(E)
    if (is(E == enum))
{
    enum is_bitfield_enum = has_bitfield_attr!(__traits(getAttributes, E));
}

private template has_bitfield_attr(Attrs...)
{
    static if (Attrs.length == 0)
        enum has_bitfield_attr = false;
    else static if (__traits(isSame, Attrs[0], bitfield))
        enum has_bitfield_attr = true;
    else
        enum has_bitfield_attr = has_bitfield_attr!(Attrs[1 .. $]);
}

private template get_display_attr(Attrs...)
{
    static if (Attrs.length == 0)
        enum string get_display_attr = null;
    else static if (is(typeof(Attrs[0]) == display_name))
        enum get_display_attr = Attrs[0].name;
    else
        enum get_display_attr = get_display_attr!(Attrs[1 .. $]);
}

// Canonical CLI/profile key for an enum member name: edge underscores trimmed,
// so digit-leading keys can be expressed as identifiers (`_5g` -> "5g").
import urt.string : trim;
enum trim_key(string key) = key.trim!(c => c == '_');

const(E)* enum_from_key(E)(const(char)[] key) pure
    if (is_enum!E)
    => enum_info!E.value_for(key);

const(char)[] enum_key_from_value(E)(EnumType!E value) pure
    if (is_enum!E)
    => enum_info!E.key_for(value);

const(char)[] enum_key_by_decl_index(E)(size_t value) pure
    if (is_enum!E)
    => enum_info!E.key_by_decl_index(value);

struct VoidEnumInfo
{
    import urt.algorithm : binary_search;
nothrow @nogc:

    // keys and values are sorted for binary search
    ushort stride() const pure
        => _map.stride_flags >> 2;

    uint type_hash() const pure
        => _prefix.type_hash;

    bool bitfield() const pure
        => (_map.stride_flags & 1) != 0;

    void bitfield(bool value)
    {
        _map.stride_flags = cast(ushort)((_map.stride_flags & ~1) | value);
    }

    ushort count() const pure
        => _map.nk;

    ushort value_count() const pure
        => _map.nv;

    const(char)[] key_for(const void* value, int function(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(_map.v[0 .. value_count*stride], stride, value, pred);
        if (i < value_count)
            return get_key(_map.map_b[_map.vs + i]);
        return null;
    }

    const(char)[] key_for(const void* value, int delegate(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(_map.v[0 .. value_count*stride], stride, value, pred);
        if (i < value_count)
            return get_key(_map.map_b[_map.vs + i]);
        return null;
    }

    const(char)[] key_by_decl_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_key(declarations[i]);
    }

    const(char)[] key_by_sorted_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_key(i);
    }

    bool has_display_names() const pure
        => (_map.stride_flags & 2) != 0;

    const(char)[] display_by_decl_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_display(declarations[i]);
    }

    const(char)[] display_by_sorted_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_display(i);
    }

    Variant value_for(const(char)[] key) const pure
    {
        size_t i = binary_search!key_compare(_map.k[0 .. count], key, _map.k_strings);
        if (i == count)
            return Variant();
        return _prefix.get_value(_map.v + _map.map_b[i]*stride, &this);
    }

    // display names are stored in key order, so this scans where value_for can binary search
    Variant value_for_display(const(char)[] display) const pure
    {
        // an empty name is no name; it must not match every unlabelled entry
        if (!has_display_names || display.length == 0)
            return Variant();
        foreach (i; 0 .. count)
        {
            if (get_display(i) == display)
                return _prefix.get_value(_map.v + _map.map_b[i]*stride, &this);
        }
        return Variant();
    }

    bool contains(const(char)[] key) const pure
    {
        size_t i = binary_search!key_compare(_map.k[0 .. count], key, _map.k_strings);
        return i < count;
    }

    const(char)[] key_for_raw(long value) const
    {
        foreach (i; 0 .. value_count)
        {
            if (_prefix.get_value(_map.v + i*stride, &this).asLong == value)
                return get_key(_map.map_b[_map.vs + i]);
        }
        return null;
    }

    long parse_flags(const(char)[] text, out bool ok) const
    {
        import urt.conv : parse_int_with_base;
        import urt.string : split, trimBack, trimFront;

        long r = 0;
        ok = true;
        while (text.length)
        {
            const(char)[] key = text.split!'|'.trimFront.trimBack;
            if (!key.length)
                continue;
            Variant v = value_for(key);
            if (!v.isNull)
            {
                r |= v.asLong;
                continue;
            }
            size_t taken;
            long num = key.parse_int_with_base(&taken);
            if (taken != key.length)
            {
                ok = false;
                return 0;
            }
            r |= num;
        }
        return r;
    }

    ptrdiff_t format_flags(long value, char[] buffer) const
    {
        import urt.conv : format_uint;

        size_t offset = 0;
        if (const(char)[] exact = key_for_raw(value))
            return append(buffer, offset, exact) ? offset : -1;

        long residue = value;
        foreach (i; 0 .. value_count)
        {
            long m = _prefix.get_value(_map.v + i*stride, &this).asLong;
            if (m == 0 || (residue & m) != m)
                continue;
            residue &= ~m;
            const(char)[] key = get_key(_map.map_b[_map.vs + i]);
            if (offset && !append(buffer, offset, "|"))
                return -1;
            if (!append(buffer, offset, key))
                return -1;
        }
        if (residue || offset == 0)
        {
            if (offset && !append(buffer, offset, "|"))
                return -1;
            if (!append(buffer, offset, "0x"))
                return -1;
            ptrdiff_t n = format_uint(cast(ulong)residue, buffer.ptr ? buffer[offset .. $] : null, 16);
            if (n < 0)
                return -1;
            offset += n;
        }
        return offset;
    }

private:
    static bool append(char[] buffer, ref size_t offset, const(char)[] s) pure
    {
        if (buffer.ptr)
        {
            if (offset + s.length > buffer.length)
                return false;
            buffer[offset .. offset + s.length] = s[];
        }
        offset += s.length;
        return true;
    }

    struct Prefix
    {
        uint type_hash;
        GetFun get_value;
    }
    Prefix _prefix;

    struct MapHeader
    {
        const ushort* k;
        const char* k_strings;
        ushort k_slen;
        ushort stride_flags;
        const void* v;
        ushort nk;
        ushort nv;
        ushort vs;
        union
        {
            const ubyte* map_b;
            const ushort* map_s;
        }
    }
    MapHeader _map;

    this(ushort stride, uint type_hash, inout(const void*) values, inout(const ushort*) keys,
        inout(const char*) strings, ushort string_length, inout(const ubyte*) map_b, ushort vs,
        ushort nk, ushort nv, GetFun get_value, bool bitfield = false, bool has_display = false) inout pure
    {
        assert(stride <= ushort.max >> 2);
        this._prefix = inout(Prefix)(type_hash, get_value);
        this._map = inout(MapHeader)(keys, strings, string_length,
            cast(ushort)(stride << 2 | bitfield | has_display << 1), values, nk, nv, vs, map_b);
    }

    const(char)[] get_key(size_t i) const pure
    {
        if (_map.k[i] == 0)
            return null;
        const(char)* s = _map.k_strings + _map.k[i];
        return s[0 .. s.key_length];
    }

    const(char)[] get_display(size_t i) const pure
    {
        // offset 0 marks no display name; a real string never starts there, it needs its length prefix first
        const(ushort)* display = display_table;
        if (display is null || display[i] == 0)
            return null;
        const(char)* s = _map.k_strings + display[i];
        return s[0 .. s.key_length];
    }

    const(ubyte)* declarations() const pure
        => _map.map_b + _map.vs + value_count;

    const(ushort)* display_table() const pure
    {
        if (!has_display_names)
            return null;
        size_t address = cast(size_t)(declarations + count);
        return cast(const(ushort)*)align_up(address, ushort.alignof);
    }
}

template EnumInfo(E)
{
    static assert (is(E == Unqual!E), "EnumInfo can only be instantiated with unqualified types!");

    static if (is(E == void))
        alias EnumInfo = VoidEnumInfo;
    else
    {
        struct EnumInfo
        {
            import urt.algorithm : binary_search;
        nothrow @nogc:

            static assert(EnumInfo.sizeof == VoidEnumInfo.sizeof, "Template EnumInfo must not add any members!");

            static if (is(E T == enum))
                alias V = T;
            else
                static assert(false, E.string ~ " is not an enum type!");
            alias Map = BiMap!(string, E);
            static assert(VoidEnumInfo.MapHeader.sizeof == Map.sizeof);
            static assert(VoidEnumInfo.MapHeader.k.offsetof == Map.k.offsetof &&
                          VoidEnumInfo.MapHeader.k_strings.offsetof == Map.k_strings.offsetof &&
                          VoidEnumInfo.MapHeader.k_slen.offsetof == Map.k_slen.offsetof &&
                          VoidEnumInfo.MapHeader.v.offsetof == Map.v.offsetof &&
                          VoidEnumInfo.MapHeader.nk.offsetof == Map.nk.offsetof &&
                          VoidEnumInfo.MapHeader.nv.offsetof == Map.nv.offsetof &&
                          VoidEnumInfo.MapHeader.vs.offsetof == Map.vs.offsetof &&
                          VoidEnumInfo.MapHeader.map_b.offsetof == Map.map_b.offsetof);

            // keys and values are sorted for binary search
            union {
                VoidEnumInfo _base;
                struct {
                    ubyte[VoidEnumInfo._map.offsetof + VoidEnumInfo.MapHeader.v.offsetof] _pad;
                    const E* _values;
                }
            }
            alias _base this;

            inout(VoidEnumInfo*) make_void() inout pure
                => &_base;

            this(uint type_hash, inout(const(E)*) values, inout(const ushort*) keys,
                inout(const char*) strings, ushort string_length, inout(const ubyte*) map_b, ushort vs,
                ushort nk, ushort nv, bool bitfield = false, bool has_display = false) inout pure
            {
                _base = inout(VoidEnumInfo)(E.sizeof, type_hash, values, keys, strings, string_length,
                    map_b, vs, nk, nv, cast(GetFun)&get_value!V, bitfield, has_display);
            }

            const(E)[] values() const pure
                => _values[0 .. value_count];

            const(char)[] key_for(V value) const pure
            {
                size_t i = binary_search(values, value);
                if (i < value_count)
                    return get_key(_map.map_b[_map.vs + i]);
                return null;
            }

            const(char)[] display_for(V value) const pure
            {
                size_t i = binary_search(values, value);
                if (i < value_count)
                    return get_display(_map.map_b[_map.vs + i]);
                return null;
            }

            const(char)[] key_by_decl_index(size_t i) const pure
                => _base.key_by_decl_index(i);

            const(char)[] key_by_sorted_index(size_t i) const pure
                => _base.key_by_sorted_index(i);

            const(E)* value_for(const(char)[] key) const pure
            {
                size_t i = binary_search!key_compare(_map.k[0 .. count], key, _map.k_strings);
                if (i == count)
                    return null;
                return _values + _map.map_b[i];
            }

            // display names are stored in key order, so this scans where value_for can binary search
            const(E)* value_for_display(const(char)[] display) const pure
            {
                // an empty name is no name; it must not match every unlabelled entry
                if (!has_display_names || display.length == 0)
                    return null;
                foreach (i; 0 .. count)
                {
                    if (get_display(i) == display)
                        return _values + _map.map_b[i];
                }
                return null;
            }

            bool contains(const(char)[] key) const pure
                => _base.contains(key);
        }
    }
}

template enum_info(E)
    if (is(E == enum))
{
    static assert (is(E == Unqual!E), "EnumInfo can only be instantiated with unqualified types!");

    enum ubyte num_items = enum_members.length;
    static assert(num_items <= ubyte.max, "Too many enum items!");
    static assert(MapData.key_count == num_items, "Duplicate enum key: " ~ E.stringof);
    static assert(total_strings <= ushort.max, "Enum key and display name data too large: " ~ E.stringof);

    __gshared immutable enum_info = immutable(EnumInfo!E)(
        fnv1a(cast(ubyte[])E.stringof),
        _values.ptr,
        _keys.ptr,
        _strings.ptr,
        cast(ushort)total_strings,
        _tables.ptr,
        num_items,
        num_items,
        num_values,
        is_bitfield_enum!E,
        has_display
    );

private:
    import urt.hash : fnv1a;
    enum enum_members = __traits(allMembers, E);
    enum entries = () {
        KVP!(string, E)[num_items] result;
        static foreach (i; 0 .. num_items)
            result[i] = KVP!(string, E)(trim_key!(enum_members[i]), __traits(getMember, E, enum_members[i]));
        return result;
    }();
    alias MapData = StaticBiMap!entries.Data;
    enum ushort num_values = MapData.value_count;
    enum string[num_items] displays = () {
        string[num_items] result;
        static foreach (i; 0 .. num_items)
            result[i] = GetDisplay!i;
        return result;
    }();

    __gshared immutable E[num_values] _values = () {
        E[num_values] result;
        foreach (i; 0 .. num_values)
            result[i] = entries[MapData.result.value_sources[i]].value;
        return result;
    }();

    __gshared immutable ushort[num_items] _keys = () {
        ushort[num_items] key_offsets;
        size_t offset = 2;
        foreach (i; 0 .. num_items)
        {
            const(char)[] key = entries[MapData.result.key_sources[i]].key;
            key_offsets[i] = cast(ushort)offset;
            offset += 2 + key.length;
            if (key.length & 1)
                ++offset;
        }
        return key_offsets;
    }();

    __gshared immutable char[total_strings] _strings = () {
        char[total_strings] str_data;
        char* ptr = str_data.ptr;
        foreach (i; 0 .. num_items)
        {
            const(char)[] key = entries[MapData.result.key_sources[i]].key;
            version (LittleEndian)
            {
                *ptr++ = key.length & 0xFF;
                *ptr++ = (key.length >> 8) & 0xFF;
            }
            else
            {
                *ptr++ = (key.length >> 8) & 0xFF;
                *ptr++ = key.length & 0xFF;
            }
            ptr[0 .. key.length] = key[];
            ptr += key.length;
            if (key.length & 1)
                *ptr++ = 0;
        }
        foreach (i; 0 .. num_items)
        {
            string d = displays[MapData.result.key_sources[i]];
            if (d.length == 0)
                continue;
            version (LittleEndian)
            {
                *ptr++ = d.length & 0xFF;
                *ptr++ = (d.length >> 8) & 0xFF;
            }
            else
            {
                *ptr++ = (d.length >> 8) & 0xFF;
                *ptr++ = d.length & 0xFF;
            }
            ptr[0 .. d.length] = d[];
            ptr += d.length;
            if (d.length & 1)
                *ptr++ = 0;
        }
        return str_data;
    }();

    enum size_t map_size = num_items * 2 + num_values;
    enum size_t display_offset = align_up(map_size, ushort.alignof);
    enum size_t table_size = has_display ? display_offset + ushort.sizeof*num_items : map_size;
    align(ushort.alignof) __gshared immutable ubyte[table_size] _tables = () {
        ubyte[table_size] result;
        foreach (key_index; 0 .. num_items)
        {
            ushort source = MapData.result.key_sources[key_index];
            result[key_index] = cast(ubyte)MapData.result.source_to_value[source];
        }
        foreach (value_index; 0 .. num_values)
        {
            ushort source = MapData.result.value_sources[value_index];
            result[num_items + value_index] = cast(ubyte)MapData.result.source_to_key[source];
        }
        foreach (source; 0 .. num_items)
            result[num_items + num_values + source] = cast(ubyte)MapData.result.source_to_key[source];
        static if (has_display)
        {
            size_t offset = total_key_strings + 2;
            foreach (i; 0 .. num_items)
            {
                string d = displays[MapData.result.key_sources[i]];
                if (d.length != 0)
                {
                    version (LittleEndian)
                    {
                        result[display_offset + i*2] = offset & 0xFF;
                        result[display_offset + i*2 + 1] = (offset >> 8) & 0xFF;
                    }
                    else
                    {
                        result[display_offset + i*2] = (offset >> 8) & 0xFF;
                        result[display_offset + i*2 + 1] = offset & 0xFF;
                    }
                    offset += 2 + d.length + (d.length & 1);
                }
            }
        }
        return result;
    }();

    enum has_display = () {
        foreach (source; MapData.result.key_sources[0 .. num_items])
            if (displays[source].length != 0)
                return true;
        return false;
    }();

    enum total_key_strings = () {
        size_t total = 0;
        foreach (i; 0 .. num_items)
        {
            size_t l = entries[MapData.result.key_sources[i]].key.length;
            total += 2 + l + (l & 1);
        }
        return total;
    }();

    enum total_strings = () {
        size_t total = total_key_strings;
        foreach (source; MapData.result.key_sources[0 .. num_items])
        {{
            string d = displays[source];
            if (d.length != 0)
                total += 2 + d.length + (d.length & 1);
        }}
        return total;
    }();

    enum GetDisplay(size_t i) = get_display_attr!(__traits(getAttributes, __traits(getMember, E, enum_members[i])));
}

VoidEnumInfo* make_enum_info(T)(const(char)[] name, const(char)[][] keys, T[] values, const(char)[][] display_names = null)
{
    import urt.hash : fnv1a;
    assert(keys.length == values.length, "keys and values must have the same length");
    assert(display_names is null || display_names.length == keys.length, "keys and display_names must have the same length");
    assert(keys.length <= ubyte.max, "Too many enum items!");

    bool any_display = false;
    foreach (d; display_names)
    {
        if (d.length != 0)
        {
            any_display = true;
            break;
        }
    }

    ushort count = cast(ushort)keys.length;
    size_t display_string_length;
    foreach (d; display_names)
        if (d.length != 0)
            display_string_length += 2 + d.length + (d.length & 1);
    assert(display_string_length <= ushort.max, "Enum display name data too large");

    size_t tail_size = count + (any_display ? ushort.alignof - 1 + ushort.sizeof*count : 0);
    alias Map = BiMap!(const(char)[], T);
    ushort[] scratch = (cast(ushort*)alloca(count*5*ushort.sizeof))[0 .. count*5];
    ushort[] sources = scratch[0 .. count];
    auto storage = synthesise_bimap_storage!(true, const(char)[], T)(keys.ptr, (const(char)[]).sizeof, values.ptr, T.sizeof, count, scratch,
        VoidEnumInfo._map.offsetof, cast(ushort)display_string_length, tail_size);
    assert(storage.memory.ptr !is null);

    Map* map = cast(Map*)storage.map;
    ubyte* declarations = cast(ubyte*)storage.tail;
    ushort* displays = any_display ? cast(ushort*)align_up(cast(size_t)(declarations + count), ushort.alignof) : null;
    if (displays !is null)
        displays[0 .. count] = 0;
    size_t string_used = storage.key_data_slen;
    foreach (key_index, source; sources)
    {
        declarations[source] = cast(ubyte)key_index;
        if (displays is null || display_names[source].length == 0)
            continue;
        displays[key_index] = static_bimap_write_string(map.k_strings[0 .. map.k_slen], string_used, display_names[source]);
    }
    assert(string_used == map.k_slen);

    VoidEnumInfo* result = cast(VoidEnumInfo*)storage.memory.ptr;
    assert(T.sizeof <= ushort.max >> 2);
    result._prefix = VoidEnumInfo.Prefix(fnv1a(cast(ubyte[])name), cast(GetFun)&get_value!T);
    result._map.stride_flags = cast(ushort)(T.sizeof << 2 | any_display << 1);
    return result;
}

size_t enum_info_size(ref const VoidEnumInfo info) pure nothrow @nogc
{
    return cast(size_t)(info._map.k_strings - cast(const(char)*)&info) + info._map.k_slen;
}

bool enum_info_equal(ref const VoidEnumInfo a, ref const VoidEnumInfo b) pure nothrow @nogc
{
    if (a.count != b.count || a.value_count != b.value_count || a.stride != b.stride || a.bitfield != b.bitfield || a.type_hash != b.type_hash)
        return false;
    if ((cast(const(ubyte)*)a._map.v)[0 .. a.value_count*a.stride] != (cast(const(ubyte)*)b._map.v)[0 .. b.value_count*b.stride])
        return false;
    foreach (i; 0 .. a.count)
    {
        if (a.key_by_sorted_index(i) != b.key_by_sorted_index(i))
            return false;
        if (a.display_by_sorted_index(i) != b.display_by_sorted_index(i))
            return false;
    }
    return true;
}


private:

alias GetFun = Variant function(const(void)*, const(VoidEnumInfo)*) pure;

Variant get_value(T)(const(void)* ptr, const(VoidEnumInfo)* info)
    => Variant(*cast(T*)ptr, info);

ushort key_length(const(char)* key) pure
{
    if (__ctfe)
    {
        version (LittleEndian)
            return key[-2] | cast(ushort)(key[-1] << 8);
        else
            return key[-1] | cast(ushort)(key[-2] << 8);
    }
    else
        return *cast(ushort*)(key - 2);
}

int key_compare(ushort a, const(char)[] b, const(char)* strings) pure
{
    import urt.string.uni : uni_compare;
    const(char)* s = strings + a;
    return uni_compare(s[0 .. s.key_length], b);
}


unittest
{
    @bitfield enum TestFlags : ubyte { a = 1, b = 2, c = 4, all = 7 }
    enum TestPlain { x = 1, y = 2 }

    static assert(is_bitfield_enum!TestFlags);
    static assert(!is_bitfield_enum!TestPlain);

    const VoidEnumInfo* info = enum_info!TestFlags.make_void();
    assert(info.bitfield);

    char[64] buf = void;
    ptrdiff_t n = info.format_flags(3, buf);
    assert(buf[0 .. n] == "a|b");
    n = info.format_flags(7, buf);      // exact compound key wins over decomposition
    assert(buf[0 .. n] == "all");
    n = info.format_flags(9, buf);      // unknown bits keep their hex residue
    assert(buf[0 .. n] == "a|0x8");
    n = info.format_flags(0, buf);
    assert(buf[0 .. n] == "0x0");

    bool ok;
    assert(info.parse_flags("a|b", ok) == 3 && ok);
    assert(info.parse_flags("a | 0x8", ok) == 9 && ok);
    assert(info.parse_flags("a|nope", ok) == 0 && !ok);

    enum TestDisplay { @display_name("First Thing") first, second, @display_name("Third Thing") third }
    enum TestAlias { first = 1, alias_ = 1, second = 2 }

    assert(!enum_info!TestPlain.has_display_names);
    assert(enum_info!TestPlain.display_by_decl_index(0) is null);
    assert(enum_info!TestAlias.count == 3 && enum_info!TestAlias.value_count == 2);
    assert(enum_info!TestAlias.key_for(TestAlias.first) == "first");
    assert(enum_info!TestAlias.key_by_decl_index(1) == "alias");
    assert(*enum_info!TestAlias.value_for("alias") == TestAlias.first);

    // trimmed keys must not desynchronise the display offsets from the packed strings
    enum TestTrimmed { _alpha_, @display_name("Beta Name") beta }
    assert(enum_info!TestTrimmed.key_by_decl_index(0) == "alpha");
    assert(enum_info!TestTrimmed.display_by_decl_index(1) == "Beta Name");

    // an empty display name is no display name at all
    enum TestEmptyDisplay { @display_name("") nothing, plain }
    assert(!enum_info!TestEmptyDisplay.has_display_names);
    assert(enum_info!TestEmptyDisplay.display_by_decl_index(0) is null);

    auto dinfo = &enum_info!TestDisplay;
    assert(dinfo.has_display_names);
    assert(dinfo.display_for(TestDisplay.first) == "First Thing");
    assert(dinfo.display_for(TestDisplay.second) is null);  // unlabelled member of a labelled enum
    assert(dinfo.display_by_decl_index(2) == "Third Thing");
    assert(dinfo.key_for(TestDisplay.first) == "first");

    assert(*dinfo.value_for_display("First Thing") == TestDisplay.first);
    assert(*dinfo.value_for_display("Third Thing") == TestDisplay.third);
    assert(dinfo.value_for_display("first") is null);        // the key is not a display name
    assert(dinfo.value_for_display("Nope") is null);
    assert(dinfo.value_for_display("") is null);             // must not match the unlabelled member
    assert(dinfo.value_for_display(null) is null);
    assert(enum_info!TestPlain.value_for_display("x") is null);

    // key order and value order disagree here, so an identity index mapping would return the wrong member
    enum TestOrder { @display_name("Zed Label") zed = 1, @display_name("Ay Label") ay = 9 }
    assert(*enum_info!TestOrder.value_for_display("Ay Label") == TestOrder.ay);
    assert(*enum_info!TestOrder.value_for_display("Zed Label") == TestOrder.zed);

    const(char)[][3] keys = [ "alpha", "beta", "gamma" ];
    int[3] vals = [ 1, 2, 3 ];
    const(char)[][3] disp = [ "Alpha!", null, "Gamma!" ];
    VoidEnumInfo* plain = make_enum_info("RT", keys[], vals[]);
    VoidEnumInfo* named = make_enum_info("RT", keys[], vals[], disp[]);
    assert(!plain.has_display_names && named.has_display_names);
    assert(named.value_for("beta").asLong == 2);
    assert(named.key_for_raw(3) == "gamma");
    assert(named.display_by_decl_index(0) == "Alpha!");
    assert(named.display_by_decl_index(1) is null);
    assert(named.display_by_decl_index(2) == "Gamma!");
    assert(named.value_for_display("Gamma!").asLong == 3);
    assert(named.value_for_display("Alpha!").asLong == 1);
    assert(named.value_for_display("beta").isNull);          // the key is not a display name
    assert(named.value_for_display("").isNull);
    assert(plain.value_for_display("Alpha!").isNull);        // no display names at all
    assert(enum_info_equal(*named, *named) && !enum_info_equal(*plain, *named));
    assert(enum_info_size(*named) > enum_info_size(*plain));
    free((cast(void*)plain)[0 .. enum_info_size(*plain)]);
    free((cast(void*)named)[0 .. enum_info_size(*named)]);

    const(char)[][3] alias_keys = [ "zeta", "alpha", "beta" ];
    int[3] alias_values = [ 1, 1, 2 ];
    VoidEnumInfo* aliases = make_enum_info("Alias", alias_keys[], alias_values[]);
    assert(aliases.count == 3 && aliases.value_count == 2);
    assert(aliases.key_for_raw(1) == "zeta");
    assert(aliases.key_by_decl_index(1) == "alpha");
    assert(aliases.value_for("alpha").asLong == 1);
    free((cast(void*)aliases)[0 .. enum_info_size(*aliases)]);

    enum many_count = ubyte.max;
    char[2][many_count] key_data;
    const(char)[][many_count] many_keys;
    int[many_count] many_values;
    foreach (i; 0 .. many_count)
    {
        key_data[i][0] = cast(char)('a' + i/16);
        key_data[i][1] = cast(char)('a' + i%16);
        many_keys[i] = key_data[i][];
        many_values[i] = cast(int)i;
    }
    VoidEnumInfo* many = make_enum_info("Many", many_keys[], many_values[]);
    assert(many && many.count == many_count && many.value_count == many_count);
    assert(many.value_for(many_keys[254]).asLong == 254);
    free((cast(void*)many)[0 .. enum_info_size(*many)]);
}
