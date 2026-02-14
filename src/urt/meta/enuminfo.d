module urt.meta.enuminfo;

import urt.algorithm : binary_search, qsort;
import urt.traits :EnumType, is_enum, Unqual;
import urt.meta : Iota, STATIC_MAP;
import urt.variant;

nothrow @nogc:


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

    Variant value_for(const(char)[] key) const pure
    {
        size_t i = binary_search!key_compare(_keys[0 .. count], key, _string_buffer);
        if (i == count)
            return Variant();
        i = _lookup_tables[i];
        return _get_value(_values + i*stride);
    }

    bool contains(const(char)[] key) const pure
    {
        size_t i = binary_search!key_compare(_keys[0 .. count], key, _string_buffer);
        return i < count;
    }

private:
    alias GetFun = Variant function(const(void)*) pure;

    const void* _values;
    const ushort* _keys;
    const char* _string_buffer;

    // these tables map between indices of keys and values
    const ubyte* _lookup_tables;

    GetFun _get_value;

    this(ubyte count, ushort stride, uint type_hash, inout void* values, inout ushort* keys, inout char* strings, inout ubyte* lookup, GetFun get_value) inout pure
    {
        this.count = count;
        this.stride = stride;
        this.type_hash = type_hash;
        this._keys = keys;
        this._values = values;
        this._string_buffer = strings;
        this._lookup_tables = lookup;
        this._get_value = get_value;
    }

    const(char)[] get_key(size_t i) const pure
    {
        const(char)* s = _string_buffer + _keys[i];
        return s[0 .. s.key_length];
    }
}

template EnumInfo(E)
{
    alias UE = Unqual!E;

    static if (is(UE == void))
        alias EnumInfo = VoidEnumInfo;
    else
    {
        struct EnumInfo
        {
            import urt.algorithm : binary_search;
        nothrow @nogc:

            static assert (EnumInfo.sizeof == EnumInfo.sizeof, "Template EnumInfo must not add any members!");

            static if (is(UE T == enum))
                alias V = T;
            else
                static assert(false, E.string ~ " is not an enum type!");

            // keys and values are sorted for binary search
            union {
                VoidEnumInfo _base;
                struct {
                    ubyte[VoidEnumInfo._values.offsetof] _pad;
                    const UE* _values; // shadows the _values in _base with a typed version
                }
            }
            alias _base this;

            inout(VoidEnumInfo*) make_void() inout pure
                => &_base;

            this(ubyte count, uint type_hash, inout UE* values, inout ushort* keys, inout char* strings, inout ubyte* lookup) inout pure
            {
                _base = inout(VoidEnumInfo)(count, UE.sizeof, type_hash, values, keys, strings, lookup, cast(VoidEnumInfo.GetFun)&get_value!UE);
            }

            const(UE)[] values() const pure
                => _values[0 .. count];

            const(char)[] key_for(V value) const pure
            {
                size_t i = binary_search(values[0 .. count], value);
                if (i < count)
                    return get_key(_lookup_tables[count + i]);
                return null;
            }

            const(char)[] key_by_decl_index(size_t i) const pure
                => _base.key_by_decl_index(i);

            const(char)[] key_by_sorted_index(size_t i) const pure
                => _base.key_by_sorted_index(i);

            const(UE)* value_for(const(char)[] key) const pure
            {
                size_t i = binary_search!key_compare(_keys[0 .. count], key, _string_buffer);
                if (i == count)
                    return null;
                return _values + _lookup_tables[i];
            }

            bool contains(const(char)[] key) const pure
                => _base.contains(key);
        }
    }
}

template enum_info(E)
    if (is(Unqual!E == enum))
{
    alias UE = Unqual!E;

    enum ubyte num_items = enum_members.length;
    static assert(num_items <= ubyte.max, "Too many enum items!");

    __gshared immutable enum_info = immutable(EnumInfo!UE)(
        num_items,
        fnv1a(cast(ubyte[])UE.stringof),
        _values.ptr,
        _keys.ptr,
        _strings.ptr,
        _lookup.ptr
    );

private:
    import urt.algorithm : binary_search, compare, qsort;
    import urt.hash : fnv1a;
    import urt.string.uni : uni_compare;

    // keys and values are sorted for binary search
    __gshared immutable UE[num_items] _values = [ STATIC_MAP!(GetValue, iota) ];

    // keys are stored as offsets info the string buffer
    __gshared immutable ushort[num_items] _keys = () {
        ushort[num_items] key_offsets;
        size_t offset = 2;
        foreach (i; 0 .. num_items)
        {
            const(char)[] key = by_key[i].k;
            key_offsets[i] = cast(ushort)offset;
            offset += 2 + key.length;
            if (key.length & 1)
                offset += 1; // align to 2 bytes
        }
        return key_offsets;
    }();

    // build the string buffer
    __gshared immutable char[total_strings] _strings = () {
        char[total_strings] str_data;
        char* ptr = str_data.ptr;
        foreach (i; 0 .. num_items)
        {
            const(char)[] key = by_key[i].k;
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
                *ptr++ = 0; // align to 2 bytes
        }
        return str_data;
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
        UE v;
        ubyte i;
    }

    alias iota = Iota!(enum_members.length);
    enum enum_members = __traits(allMembers, E);
    enum by_key = (){ KI[num_items] r = [ STATIC_MAP!(MakeKI, iota) ]; r.qsort!((ref a, ref b) => uni_compare(a.k, b.k)); return r; }();
    enum by_value = (){ VI[num_items] r = [ STATIC_MAP!(MakeVI, iota) ]; r.qsort!((ref a, ref b) => compare(a.v, b.v)); return r; }();
    enum inv_key = (){ KI[num_items] bk = by_key; ubyte[num_items] r; foreach (ubyte i, ref ki; bk) r[ki.i] = i; return r; }();
    enum inv_val = (){ VI[num_items] bv = by_value; ubyte[num_items] r; foreach (ubyte i, ref vi; bv) r[vi.i] = i; return r; }();

    // calculate the total size of the string buffer
    enum total_strings = () {
        size_t total = 0;
        static foreach (k; enum_members)
            total += 2 + k.length + (k.length & 1);
        return total;
    }();

    enum MakeKI(ushort i) = KI(trim_key!(enum_members[i]), i);
    enum MakeVI(ushort i) = VI(__traits(getMember, E, enum_members[i]), i);
    enum GetValue(size_t i) = by_value[i].v;
    enum GetKeyRedirect(size_t i) = inv_val[by_key[i].i];
    enum GetValRedirect(size_t i) = inv_key[by_value[i].i];
    enum GetKeyOrig(size_t i) = inv_key[i];
}

VoidEnumInfo* make_enum_info(T)(const(char)[] name, const(char)[][] keys, T[] values)
{
    import urt.algorithm;
    import urt.hash : fnv1a;
    import urt.mem.allocator;
    import urt.string;
    import urt.string.uni;
    import urt.util;

    assert(keys.length == values.length, "keys and values must have the same length");
    assert(keys.length <= ubyte.max, "Too many enum items!");

    size_t count = keys.length;

    struct VI(T)
    {
        T v;
        ubyte i;
    }

    // first we'll sort the keys and values for binary searching
    // we need to associate their original indices for the lookup tables
    auto ksort = tempAllocator().allocArray!(VI!(const(char)[]))(count);
    auto vsort = tempAllocator().allocArray!(VI!T)(count);
    foreach (i; 0 .. count)
    {
        ksort[i] = VI!(const(char)[])(keys[i], cast(ubyte)i);
        vsort[i] = VI!T(values[i], cast(ubyte)i);
    }
    ksort.qsort!((ref a, ref b) => uni_compare(a.v, b.v));
    vsort.qsort!((ref a, ref b) => compare(a.v, b.v));

    // build the reverse lookup tables
    ubyte[] inv_k = tempAllocator().allocArray!ubyte(count);
    ubyte[] inv_v = tempAllocator().allocArray!ubyte(count);
    foreach (i, ref ki; ksort)
        inv_k[ki.i] = cast(ubyte)i;
    foreach (i, ref vi; vsort)
        inv_v[vi.i] = cast(ubyte)i;

    // count the string memory
    size_t total_string;
    foreach (i; 0 .. count)
        total_string += 2 + keys[i].length + (keys[i].length & 1);

    // calculate the total size
    size_t total_size = VoidEnumInfo.sizeof + T.sizeof*count;
    total_size += (total_size & 1) + ushort.sizeof*count + count*3;
    total_size += (total_size & 1) + total_string;

    // allocate a buffer and assign all the sub-buffers
    void[] info = defaultAllocator().alloc(total_size);
    VoidEnumInfo* result = cast(VoidEnumInfo*)info.ptr;
    T* value_ptr = cast(T*)&result[1];
    char* str_data = cast(char*)&value_ptr[count];
    if (cast(size_t)str_data & 1)
        *str_data++ = 0; // align to 2 bytes
    ushort* key_ptr = cast(ushort*)str_data;
    ubyte* lookup = cast(ubyte*)&key_ptr[count];
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
        writeString(str_ptr, key);
        if (key.length & 1)
            (str_ptr++)[key.length] = 0; // align to 2 bytes
        str_ptr += 2 + key.length;

        lookup[i] = inv_v[ksort[i].i];
        lookup[count + i] = inv_k[vsort[i].i];
        lookup[count*2 + i] = inv_k[i];
    }

    // build and return the object
    return new(*result) VoidEnumInfo(cast(ubyte)keys.length, cast(ushort)T.sizeof, fnv1a(cast(ubyte[])name), value_ptr, key_ptr, str_data, lookup, cast(VoidEnumInfo.GetFun)&get_value!T);
}


private:

Variant get_value(E)(const(void)* ptr)
    => Variant(*cast(const(E)*)ptr);

import urt.string : trim;
enum trim_key(string key) = key.trim!(c => c == '_');

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
