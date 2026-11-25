module urt.meta.enuminfo;

import urt.algorithm : binary_search, qsort;
import urt.string.string : compare_string_keys, find_slab_key, pack_strings, string_slab_entry_size;
import urt.traits :EnumType, is_enum, Unqual;
import urt.mem;
import urt.meta : Iota, STATIC_MAP;
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
    ushort count;
    ushort stride;
    uint type_hash;
    bool bitfield;

    const(char)[] key_for(const void* value, int function(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(_values[0 .. count*stride], stride, value, pred);
        if (i < count)
            return get_key(_lookup_tables[count + i]);
        return null;
    }

    const(char)[] key_for(const void* value, int delegate(const void* a, const void* b) pure nothrow @nogc pred) const pure
    {
        size_t i = binary_search(_values[0 .. count*stride], stride, value, pred);
        if (i < count)
            return get_key(_lookup_tables[count + i]);
        return null;
    }

    const(char)[] key_by_decl_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_key(_lookup_tables[count*2 + i]);
    }

    const(char)[] key_by_sorted_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_key(i);
    }

    bool has_display_names() const pure
        => _display !is null;

    const(char)[] display_by_decl_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_display(_lookup_tables[count*2 + i]);
    }

    const(char)[] display_by_sorted_index(size_t i) const pure
    {
        assert(i < count, "Declaration index out of range");
        return get_display(i);
    }

    Variant value_for(const(char)[] key) const pure
    {
        size_t i = find_slab_key(key, _keys[0 .. count], _string_buffer);
        if (i >= count)
            return Variant();
        i = _lookup_tables[i];
        return _get_value(_values + i*stride, &this);
    }

    Variant value_for_display(const(char)[] display) const pure
    {
        size_t i = display_value_index(display);
        return i < count ? _get_value(_values + i*stride, &this) : Variant();
    }

    bool contains(const(char)[] key) const pure
    {
        size_t i = find_slab_key(key, _keys[0 .. count], _string_buffer);
        return i < count;
    }

    const(char)[] key_for_raw(long value) const
    {
        foreach (i; 0 .. count)
        {
            if (_get_value(_values + i*stride, &this).asLong == value)
                return get_key(_lookup_tables[count + i]);
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
        foreach (i; 0 .. count)
        {
            long m = _get_value(_values + i*stride, &this).asLong;
            if (m == 0 || (residue & m) != m)
                continue;
            residue &= ~m;
            const(char)[] key = get_key(_lookup_tables[count + i]);
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

    const void* _values;
    const ushort* _keys;
    const ushort* _display;
    const char* _string_buffer;

    // these tables map between indices of keys and values
    const ubyte* _lookup_tables;

    const GetFun _get_value;

    this(ubyte count, ushort stride, uint type_hash, inout void* values, inout ushort* keys, inout ushort* display, inout char* strings, inout ubyte* lookup, GetFun get_value, bool bitfield = false) inout pure
    {
        this.count = count;
        this.stride = stride;
        this.type_hash = type_hash;
        this.bitfield = bitfield;
        this._keys = keys;
        this._display = display;
        this._values = values;
        this._string_buffer = strings;
        this._lookup_tables = lookup;
        this._get_value = get_value;
    }

    size_t display_value_index(const(char)[] display) const pure
    {
        if (_display is null || display.length == 0)
            return count;

        import urt.string.uni : uni_compare;
        size_t best = count;
        foreach (i; 0 .. count)
        {
            // Retain the lexical tie-break for ambiguous display names.
            if (get_display(i) == display && (best == count || uni_compare(get_key(i), get_key(best)) < 0))
                best = i;
        }
        return best < count ? _lookup_tables[best] : count;
    }

    const(char)[] get_key(size_t i) const pure
    {
        const(char)* s = _string_buffer + _keys[i];
        return s[0 .. s.key_length];
    }

    const(char)[] get_display(size_t i) const pure
    {
        // offset 0 marks no display name; a real string never starts there, it needs its length prefix first
        if (_display is null || _display[i] == 0)
            return null;
        const(char)* s = _string_buffer + _display[i];
        return s[0 .. s.key_length];
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

            static assert (EnumInfo.sizeof == EnumInfo.sizeof, "Template EnumInfo must not add any members!");

            static if (is(E T == enum))
                alias V = T;
            else
                static assert(false, E.string ~ " is not an enum type!");

            // keys and values are sorted for binary search
            union {
                VoidEnumInfo _base;
                struct {
                    ubyte[VoidEnumInfo._values.offsetof] _pad;
                    const E* _values; // shadows the _values in _base with a typed version
                }
            }
            alias _base this;

            inout(VoidEnumInfo*) make_void() inout pure
                => &_base;

            this(ubyte count, uint type_hash, inout(E)* values, inout ushort* keys, inout ushort* display, inout char* strings, inout ubyte* lookup, bool bitfield = false) inout pure
            {
                _base = inout(VoidEnumInfo)(count, E.sizeof, type_hash, values, keys, display, strings, lookup, cast(GetFun)&get_value!V, bitfield);
            }

            const(E)[] values() const pure
                => _values[0 .. count];

            const(char)[] key_for(V value) const pure
            {
                size_t i = binary_search(values[0 .. count], value);
                if (i < count)
                    return get_key(_lookup_tables[count + i]);
                return null;
            }

            const(char)[] display_for(V value) const pure
            {
                size_t i = binary_search(values[0 .. count], value);
                if (i < count)
                    return get_display(_lookup_tables[count + i]);
                return null;
            }

            const(char)[] key_by_decl_index(size_t i) const pure
                => _base.key_by_decl_index(i);

            const(char)[] key_by_sorted_index(size_t i) const pure
                => _base.key_by_sorted_index(i);

            const(E)* value_for(const(char)[] key) const pure
            {
                size_t i = find_slab_key(key, _keys[0 .. count], _string_buffer);
                if (i >= count)
                    return null;
                return _values + _lookup_tables[i];
            }

            const(E)* value_for_display(const(char)[] display) const pure
            {
                size_t i = _base.display_value_index(display);
                return i < count ? _values + i : null;
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
    // keys and display names are reached by ushort offsets carrying ushort length prefixes

    __gshared immutable enum_info = immutable(EnumInfo!E)(
        num_items,
        fnv1a(cast(ubyte[])E.stringof),
        _values.ptr,
        _keys.ptr,
        has_display ? _display.ptr : null,
        _strings.ptr,
        _lookup.ptr,
        is_bitfield_enum!E
    );

private:
    import urt.algorithm : binary_search, compare, qsort;
    import urt.hash : fnv1a;

    // keys and values are sorted for binary search
    __gshared immutable E[num_items] _values = [ STATIC_MAP!(GetValue, iota) ];

    enum size_t num_display = has_display ? num_items : 0;
    enum slab_text = () {
        string[num_items + num_display] text;
        foreach (i; 0 .. num_items)
            text[i] = by_key[i].k;
        static if (has_display)
            foreach (i, display; display_by_sorted)
                text[num_items + i] = display;
        return text;
    }();
    enum slab = pack_strings!(slab_text.length)(slab_text[], false, num_items, ushort.max);

    __gshared immutable ushort[num_items] _keys = slab.offsets[0 .. num_items];
    __gshared immutable ushort[num_display] _display = slab.offsets[num_items .. $];
    align(2) __gshared immutable char[slab.cache.length] _strings = () {
        char[slab.cache.length] cache;
        cache[] = slab.cache[];
        return cache;
    }();

    // these tables map between indices of keys and values
    __gshared immutable ubyte[num_items * 3] _lookup = [ STATIC_MAP!(GetKeyRedirect, iota),
                                                         STATIC_MAP!(GetValRedirect, iota),
                                                         STATIC_MAP!(GetKeyOrig, iota) ];

    // a whole bunch of nonsense to build the tables...
    struct KI
    {
        string k;
        ubyte i;
    }
    struct VI
    {
        E v;
        ubyte i;
    }

    alias iota = Iota!(enum_members.length);
    enum enum_members = __traits(allMembers, E);
    enum by_key = (){ KI[num_items] r = [ STATIC_MAP!(MakeKI, iota) ]; r.qsort!((ref a, ref b) => compare_string_keys(a.k, b.k)); return r; }();
    enum by_value = (){ VI[num_items] r = [ STATIC_MAP!(MakeVI, iota) ]; r.qsort!((ref a, ref b) => compare(a.v, b.v)); return r; }();
    enum inv_key = (){ KI[num_items] bk = by_key; ubyte[num_items] r; foreach (ubyte i, ref ki; bk) r[ki.i] = i; return r; }();
    enum inv_val = (){ VI[num_items] bv = by_value; ubyte[num_items] r; foreach (ubyte i, ref vi; bv) r[vi.i] = i; return r; }();

    enum string[num_items] displays = [ STATIC_MAP!(GetDisplay, iota) ];
    enum display_by_sorted = (){ string[num_items] r; foreach (i; 0 .. num_items) r[i] = displays[by_key[i].i]; return r; }();
    enum has_display = (){ foreach (d; display_by_sorted) { if (d.length != 0) return true; } return false; }();

    enum MakeKI(ushort i) = KI(trim_key!(enum_members[i]), i);
    enum MakeVI(ushort i) = VI(__traits(getMember, E, enum_members[i]), i);
    enum GetDisplay(size_t i) = get_display_attr!(__traits(getAttributes, __traits(getMember, E, enum_members[i])));
    enum GetValue(size_t i) = by_value[i].v;
    enum GetKeyRedirect(size_t i) = inv_val[by_key[i].i];
    enum GetValRedirect(size_t i) = inv_key[by_value[i].i];
    enum GetKeyOrig(size_t i) = inv_key[i];
}

VoidEnumInfo* make_enum_info(T)(const(char)[] name, const(char)[][] keys, T[] values, const(char)[][] display_names = null)
{
    import urt.algorithm;
    import urt.hash : fnv1a;
    import urt.mem.temp;
    import urt.string;
    import urt.util;

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

    size_t count = keys.length;

    struct VI(T)
    {
        T v;
        ubyte i;
    }

    // first we'll sort the keys and values for binary searching
    // we need to associate their original indices for the lookup tables
    auto ksort = talloc_array!(VI!(const(char)[]))(count);
    auto vsort = talloc_array!(VI!T)(count);
    foreach (i; 0 .. count)
    {
        ksort[i] = VI!(const(char)[])(keys[i], cast(ubyte)i);
        vsort[i] = VI!T(values[i], cast(ubyte)i);
    }
    ksort.qsort!((ref a, ref b) => compare_string_keys(a.v, b.v));
    vsort.qsort!((ref a, ref b) => compare(a.v, b.v));

    // build the reverse lookup tables
    ubyte[] inv_k = talloc_array!ubyte(count);
    ubyte[] inv_v = talloc_array!ubyte(count);
    foreach (i, ref ki; ksort)
        inv_k[ki.i] = cast(ubyte)i;
    foreach (i, ref vi; vsort)
        inv_v[vi.i] = cast(ubyte)i;

    // count the string memory
    size_t total_string;
    foreach (i; 0 .. count)
        total_string += string_slab_entry_size(keys[i].length);
    if (any_display)
    {
        foreach (d; display_names)
        {
            if (d.length != 0)
                total_string += string_slab_entry_size(d.length);
        }
    }
    // keys and display names are reached by ushort offsets carrying ushort length prefixes
    assert(total_string <= ushort.max, "Enum key and display name data too large");

    // calculate the total size
    size_t total_size = VoidEnumInfo.sizeof + T.sizeof*count;
    total_size += (total_size & 1) + ushort.sizeof*count*(any_display ? 2 : 1) + count*3;
    total_size += (total_size & 1) + total_string;

    // allocate a buffer and assign all the sub-buffers
    void[] info = alloc(total_size);
    VoidEnumInfo* result = cast(VoidEnumInfo*)info.ptr;
    T* value_ptr = cast(T*)&result[1];
    char* str_data = cast(char*)&value_ptr[count];
    if (cast(size_t)str_data & 1)
        *str_data++ = 0; // align to 2 bytes
    ushort* key_ptr = cast(ushort*)str_data;
    ushort* disp_ptr = any_display ? &key_ptr[count] : null;
    ubyte* lookup = any_display ? cast(ubyte*)&disp_ptr[count] : cast(ubyte*)&key_ptr[count];
    str_data = cast(char*)&lookup[count*3];
    if (cast(size_t)str_data & 1)
        *str_data++ = 0; // align to 2 bytes
    char* str_ptr = str_data + 2;

    // populate the enum info data
    foreach (i; 0 .. count)
    {
        value_ptr[i] = vsort[i].v;

        // write the string data and store the key offset
        const(char)[] key = ksort[i].v;
        key_ptr[i] = cast(ushort)(str_ptr - str_data);
        write_string(str_ptr, key);
        if (key.length & 1)
            (str_ptr++)[key.length] = 0; // align to 2 bytes
        str_ptr += 2 + key.length;

        if (disp_ptr !is null)
        {
            const(char)[] d = display_names[ksort[i].i];
            if (d.length == 0)
                disp_ptr[i] = 0;
            else
            {
                disp_ptr[i] = cast(ushort)(str_ptr - str_data);
                write_string(str_ptr, d);
                if (d.length & 1)
                    (str_ptr++)[d.length] = 0; // align to 2 bytes
                str_ptr += 2 + d.length;
            }
        }

        lookup[i] = inv_v[ksort[i].i];
        lookup[count + i] = inv_k[vsort[i].i];
        lookup[count*2 + i] = inv_k[i];
    }

    VoidEnumInfo value = VoidEnumInfo(cast(ubyte)keys.length, cast(ushort)T.sizeof, fnv1a(cast(ubyte[])name), cast(void*)value_ptr, key_ptr, disp_ptr, str_data, lookup, cast(GetFun)&get_value!T);
    return result.emplace(value);
}

size_t enum_info_size(ref const VoidEnumInfo info) pure nothrow @nogc
{
    size_t total_string;
    foreach (i; 0 .. info.count)
    {
        size_t l = info.key_by_sorted_index(i).length;
        total_string += string_slab_entry_size(l);
        size_t dl = info.display_by_sorted_index(i).length;
        if (dl != 0)
            total_string += string_slab_entry_size(dl);
    }
    size_t total = VoidEnumInfo.sizeof + info.stride*info.count;
    total += (total & 1) + ushort.sizeof*info.count*(info._display ? 2 : 1) + info.count*3;
    total += (total & 1) + total_string;
    return total;
}

bool enum_info_equal(ref const VoidEnumInfo a, ref const VoidEnumInfo b) pure nothrow @nogc
{
    if (a.count != b.count || a.stride != b.stride || a.bitfield != b.bitfield || a.type_hash != b.type_hash)
        return false;
    if ((cast(const(ubyte)*)a._values)[0 .. a.count*a.stride] != (cast(const(ubyte)*)b._values)[0 .. b.count*b.stride])
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

    assert(!enum_info!TestPlain.has_display_names);
    assert(enum_info!TestPlain.display_by_decl_index(0) is null);

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

    enum TestEmptyKey { _, a }
    auto empty_key = &enum_info!TestEmptyKey;
    assert(empty_key.key_by_decl_index(0).ptr !is null);
    assert(*empty_key.value_for("") == TestEmptyKey._);
    assert(*empty_key.value_for("a") == TestEmptyKey.a);

    enum TestLengthOrder
    {
        @display_name("Shared") alphabet = 7,
        @display_name("Shared") z = 2,
        bee = 4,
    }
    auto order = &enum_info!TestLengthOrder;
    assert(order.key_by_sorted_index(0) == "z");
    assert(order.key_by_sorted_index(1) == "bee");
    assert(order.key_by_sorted_index(2) == "alphabet");
    assert(order.key_by_decl_index(0) == "alphabet");
    assert(*order.value_for("alphabet") == TestLengthOrder.alphabet);
    assert(order.make_void().value_for("z").asLong == 2);
    assert(*order.value_for_display("Shared") == TestLengthOrder.alphabet);
    assert(order.make_void().value_for_display("Shared").asLong == 7);

    const(char)[][3] length_keys = ["alphabet", "z", "bee"];
    int[3] length_values = [7, 2, 4];
    VoidEnumInfo* runtime_order = make_enum_info("LengthOrder", length_keys[], length_values[]);
    scope(exit) free((cast(void*)runtime_order)[0 .. enum_info_size(*runtime_order)]);
    assert(runtime_order.key_by_sorted_index(0) == "z");
    assert(runtime_order.key_by_decl_index(0) == "alphabet");
    assert(runtime_order.value_for("alphabet").asLong == 7);
    assert(enum_info_equal(*named, *named) && !enum_info_equal(*plain, *named));
    assert(enum_info_size(*named) > enum_info_size(*plain));
    free((cast(void*)plain)[0 .. enum_info_size(*plain)]);
    free((cast(void*)named)[0 .. enum_info_size(*named)]);
}
