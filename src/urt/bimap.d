module urt.bimap;

import urt.algorithm : binary_search, compare, qsort;
import urt.array : Array, array_allocate, array_free, array_grow_trivial, array_insert_trivial, move_to;
import urt.kvp : KVP;
import urt.mem.alloc : alloc, alloc_array, free, MemFlags, realloc;
import urt.string : as_dstring, write_string;
import urt.traits : is_trivial, Unqual;
import urt.util : align_up, next_power_of_2;

nothrow @nogc:


enum BiMapResult : ubyte
{
    inserted,
    existing,
    exhausted,
}

struct BiMap(K, V = void, bool has_reverse = true, bool has_ack = false)
{
    static assert(!is(K == void) && is_trivial!K);
    static if (is(V == void))
        static assert(has_reverse);
    else
    {
        static assert(is_trivial!V);
        static assert(has_reverse || !has_ack);
    }

nothrow @nogc:

    static if (is_bimap_string!K)
        alias KeyType = const(char)[];
    else
        alias KeyType = K;
    static if (is(V == void))
        alias ValueType = ushort;
    else static if (is_bimap_string!V)
        alias ValueType = const(char)[];
    else
        alias ValueType = V;

    @disable this(this);

    ~this()
    {
        clear();
    }

    ushort key_count() const pure
    {
        static if (has_reverse)
            return nk;
        else
            return n;
    }

    ushort value_count() const pure
    {
        static if (has_reverse)
            return nv;
        else
            return n;
    }

    bool empty() const pure
        => key_count == 0;

    void clear()
    {
        bimap_release_values(k, key_count);
        static if (is_bimap_string!K)
            bimap_release_values(k_strings, k_slen);
        static if (!is(V == void))
        {
            bimap_release_values(v, value_count);
            static if (is_bimap_string!V)
                bimap_release_values(v_strings, v_slen);
        }
        static if (has_reverse)
        {
            ubyte* bytes;
            ushort* shorts;
            index_pointers(bytes, shorts);
            bimap_indexes_clear(bytes, shorts, vs, nk, nv, has_ack);
            index_pointer(bytes, shorts);
        }
        else
            n = 0;
        k = null;
        static if (is_bimap_string!K)
        {
            k_strings = null;
            k_slen = 0;
        }
        static if (!is(V == void))
        {
            v = null;
            static if (is_bimap_string!V)
            {
                v_strings = null;
                v_slen = 0;
            }
        }
    }

    static if (is(V == void))
    {
        bool find(KeyType key, out ushort ordinal, out bool acknowledged) const pure
        {
            bool found;
            ushort key_index = key_offset(key, found);
            const(ubyte)* bytes;
            const(ushort)* shorts;
            index_pointers(bytes, shorts);
            return found && bimap_indexes_forward(bytes, shorts, nk, nv, key_index, has_ack, ordinal,
                acknowledged);
        }

        bool find(KeyType key, out ushort ordinal) const pure
        {
            bool acknowledged;
            return find(key, ordinal, acknowledged);
        }

        bool reverse(uint ordinal, out KeyType key) const pure
        {
            ushort key_index;
            const(ubyte)* bytes;
            const(ushort)* shorts;
            index_pointers(bytes, shorts);
            if (!bimap_indexes_reverse(bytes, shorts, vs, nk, nv, ordinal, has_ack, key_index))
                return false;
            static if (is_bimap_string!K)
                key = bimap_string_at(k_strings, k[key_index]);
            else
                key = cast(K)k[key_index];
            return true;
        }

        BiMapResult introduce(KeyType key, out ushort ordinal, out bool acknowledged)
        {
            bool found;
            ushort key_index = key_offset(key, found);
            if (found)
            {
                const(ubyte)* bytes;
                const(ushort)* shorts;
                index_pointers(bytes, shorts);
                bimap_indexes_forward(bytes, shorts, nk, nv, key_index, has_ack, ordinal, acknowledged);
                return BiMapResult.existing;
            }

            ordinal = nv;
            acknowledged = !has_ack;
            return insert_ordinal(key, key_index, false, ordinal);
        }

        BiMapResult adopt(KeyType key, uint ordinal)
        {
            bool found;
            ushort key_index = key_offset(key, found);
            return insert_ordinal(key, key_index, found, ordinal);
        }

        static if (has_ack)
        {
            bool acknowledge(KeyType key, uint ordinal)
            {
                bool found;
                ushort key_index = key_offset(key, found);
                ubyte* bytes;
                ushort* shorts;
                index_pointers(bytes, shorts);
                return found && bimap_indexes_acknowledge(bytes, shorts, nk, nv, key_index, ordinal, true);
            }
        }
    }
    else
    {
        pragma(inline, true) bool find(KeyType key, out ValueType value, out ushort key_index, out bool acknowledged) const pure
        {
            bool found;
            key_index = key_offset(key, found);
            if (!found)
                return false;
            static if (has_reverse)
            {
                const(ubyte)* bytes;
                const(ushort)* shorts;
                index_pointers(bytes, shorts);
                ushort value_index;
                if (!bimap_indexes_forward(bytes, shorts, nk, nv, key_index, has_ack, value_index,
                    acknowledged))
                    return false;
                static if (is_bimap_string!V)
                    value = bimap_string_at(v_strings, v[value_index]);
                else
                    value = cast(V)v[value_index];
            }
            else
            {
                static if (is_bimap_string!V)
                    value = bimap_string_at(v_strings, v[key_index]);
                else
                    value = cast(V)v[key_index];
                acknowledged = true;
            }
            return true;
        }

        pragma(inline, true) bool find(KeyType key, out ValueType value, out bool acknowledged) const pure
        {
            ushort key_index;
            return find(key, value, key_index, acknowledged);
        }

        pragma(inline, true) bool find(KeyType key, out ValueType value, out ushort key_index) const pure
        {
            bool acknowledged;
            return find(key, value, key_index, acknowledged);
        }

        pragma(inline, true) bool find(KeyType key, out ValueType value) const pure
        {
            bool acknowledged;
            return find(key, value, acknowledged);
        }

        static if (has_reverse)
        {
            pragma(inline, true) bool reverse(ValueType value, out KeyType key) const pure
            {
                bool found;
                ushort value_index = value_offset(value, found);
                if (!found)
                    return false;
                ushort key_index;
                const(ubyte)* bytes;
                const(ushort)* shorts;
                index_pointers(bytes, shorts);
                if (!bimap_indexes_reverse(bytes, shorts, vs, nk, nv, value_index, has_ack, key_index))
                    return false;
                static if (is_bimap_string!K)
                    key = bimap_string_at(k_strings, k[key_index]);
                else
                    key = cast(K)k[key_index];
                return true;
            }
        }

        BiMapResult insert(KeyType key, ValueType value)
        {
            bool key_found;
            ushort key_index = key_offset(key, key_found);
            static if (has_reverse)
            {
                bool value_found;
                ushort value_index = value_offset(value, value_found);
                static if (is_bimap_string!K)
                {
                    if (!key_found && !bimap_string_fits(k_slen, key))
                        return BiMapResult.exhausted;
                }
                static if (is_bimap_string!V)
                {
                    if (!value_found && !bimap_string_fits(v_slen, value))
                        return BiMapResult.exhausted;
                }
                ushort old_nk = nk;
                ushort old_nv = nv;
                ubyte* bytes;
                ushort* shorts;
                index_pointers(bytes, shorts);
                BiMapResult result;
                if (__ctfe)
                {
                    result = bimap_indexes_insert(bytes, shorts, vs, nk, nv, key_index, value_index,
                        key_found, value_found, has_ack);
                    index_pointer(bytes, shorts);
                }
                else
                    result = bimap_indexes_insert(map_b, vs, nk, nv, key_index, value_index,
                        key_found, value_found, has_ack);
                if (result != BiMapResult.inserted)
                    return result;

                if (!key_found)
                {
                    static if (is_bimap_string!K)
                        bimap_insert_string(k, k_strings, k_slen, old_nk, key_index, key);
                    else
                        bimap_insert_value(k, old_nk, key_index, key);
                }
                if (!value_found)
                {
                    static if (is_bimap_string!V)
                        bimap_insert_string(v, v_strings, v_slen, old_nv, value_index, value);
                    else
                        bimap_insert_value(v, old_nv, value_index, value);
                }
                return BiMapResult.inserted;
            }
            else
            {
                if (key_found)
                    return BiMapResult.existing;
                if (n == ushort.max)
                    return BiMapResult.exhausted;
                static if (is_bimap_string!K)
                {
                    if (!bimap_string_fits(k_slen, key))
                        return BiMapResult.exhausted;
                }
                static if (is_bimap_string!V)
                {
                    if (!bimap_string_fits(v_slen, value))
                        return BiMapResult.exhausted;
                }
                ushort old_n = n;
                ++n;
                static if (is_bimap_string!K)
                    bimap_insert_string(k, k_strings, k_slen, old_n, key_index, key);
                else
                    bimap_insert_value(k, old_n, key_index, key);
                static if (is_bimap_string!V)
                    bimap_insert_string(v, v_strings, v_slen, old_n, key_index, value);
                else
                    bimap_insert_value(v, old_n, key_index, value);
                return BiMapResult.inserted;
            }
        }

        static if (has_ack)
        {
            bool acknowledge(KeyType key, ValueType value)
            {
                bool key_found;
                bool value_found;
                ushort key_index = key_offset(key, key_found);
                ushort value_index = value_offset(value, value_found);
                ubyte* bytes;
                ushort* shorts;
                index_pointers(bytes, shorts);
                return key_found && value_found && bimap_indexes_acknowledge(bytes, shorts, nk, nv,
                    key_index, value_index, true);
            }
        }
    }


package(urt):
    static if (is_bimap_string!K)
    {
        ushort* k;
        char* k_strings;
        ushort k_slen;
    }
    else
        K* k;
    static if (!is(V == void))
    {
        static if (is_bimap_string!V)
        {
            ushort* v;
            char* v_strings;
            ushort v_slen;
        }
        else
            V* v;
    }
    static if (has_reverse)
    {
        ushort nk;
        ushort nv;
        ushort vs;
        union
        {
            ubyte* map_b;
            ushort* map_s;
        }
    }
    else
        ushort n;

private:
    static if (has_reverse)
    {
        void index_pointers(out ubyte* bytes, out ushort* shorts) pure
        {
            if (__ctfe)
            {
                if (bimap_indexes_is_wide(nk, nv, has_ack))
                    shorts = map_s;
                else
                    bytes = map_b;
            }
            else
            {
                bytes = map_b;
                shorts = map_s;
            }
        }

        void index_pointers(out const(ubyte)* bytes, out const(ushort)* shorts) const pure
        {
            if (__ctfe)
            {
                if (bimap_indexes_is_wide(nk, nv, has_ack))
                    shorts = map_s;
                else
                    bytes = map_b;
            }
            else
            {
                bytes = map_b;
                shorts = map_s;
            }
        }

        void index_pointer(ubyte* bytes, ushort* shorts) pure
        {
            if (bimap_indexes_is_wide(nk, nv, has_ack))
                map_s = shorts;
            else
                map_b = bytes;
        }
    }

    pragma(inline, true) ushort key_offset(KeyType key, out bool found) const pure
    {
        static if (is_bimap_string!K)
            size_t first = binary_search!(bimap_string_compare, true)(k[0 .. key_count], key, k_strings);
        else
            size_t first = binary_search!(void, true)(k[0 .. key_count], key);
        static if (is_bimap_string!K)
            found = first < key_count && bimap_string_compare(k[first], key, k_strings) == 0;
        else
            found = first < key_count && !(k[first] < key) && !(key < k[first]);
        return cast(ushort)first;
    }

    static if (!is(V == void) && has_reverse)
    {
        pragma(inline, true) ushort value_offset(ValueType value, out bool found) const pure
        {
            static if (is_bimap_string!V)
                size_t first = binary_search!(bimap_string_compare, true)(v[0 .. value_count], value, v_strings);
            else
                size_t first = binary_search!(void, true)(v[0 .. value_count], value);
            static if (is_bimap_string!V)
                found = first < value_count && bimap_string_compare(v[first], value, v_strings) == 0;
            else
                found = first < value_count && !(v[first] < value) && !(value < v[first]);
            return cast(ushort)first;
        }
    }

    static if (is(V == void))
    {
        BiMapResult insert_ordinal(KeyType key, ushort key_index, bool key_found, uint ordinal)
        {
            static if (is_bimap_string!K)
            {
                if (!key_found && !bimap_string_fits(k_slen, key))
                    return BiMapResult.exhausted;
            }
            ushort old_nk = nk;
            ubyte* bytes;
            ushort* shorts;
            index_pointers(bytes, shorts);
            BiMapResult result;
            if (__ctfe)
            {
                result = bimap_indexes_insert(bytes, shorts, vs, nk, nv, key_index, key_found,
                    ordinal, has_ack);
                index_pointer(bytes, shorts);
            }
            else
                result = bimap_indexes_insert(map_b, vs, nk, nv, key_index, key_found, ordinal,
                    has_ack);
            if (result != BiMapResult.inserted)
                return result;

            if (!key_found)
            {
                static if (is_bimap_string!K)
                    bimap_insert_string(k, k_strings, k_slen, old_nk, key_index, key);
                else
                    bimap_insert_value(k, old_nk, key_index, key);
            }
            return BiMapResult.inserted;
        }
    }
}

template StaticBiMap(alias entries)
{
    alias Data = StaticBiMapData!entries;
    alias Types = StaticBiMapTypes!entries;
    alias K = Types.Key;
    alias V = Types.Value;
    alias Map = BiMap!(K, V);
    enum size_t source_count = Data.source_count;

private:
    static if (is_bimap_string!K)
        alias StoredK = ushort;
    else
        alias StoredK = K;
    static if (source_count <= size_t(ubyte.max) + 1)
        alias DeclarationIndex = ubyte;
    else
        alias DeclarationIndex = ushort;
    static if (!is(V == void))
    {
        static if (is_bimap_string!V)
            alias StoredV = ushort;
        else
            alias StoredV = V;
    }

    struct Sizes
    {
        ushort nk;
        ushort nv;
        ushort k_slen;
        ushort v_slen;
    }

    enum Sizes sizes = () {
        Sizes result = { nk: Data.key_count, nv: Data.value_count };
        static if (is_bimap_string!K)
        {
            size_t key_length;
            foreach (i; 0 .. Data.key_count)
            {
                ushort source = Data.result.key_sources[i];
                static if (Types.has_values)
                    key_length += static_bimap_string_length(entries[source].key);
                else
                    key_length += static_bimap_string_length(entries[source]);
            }
            assert(key_length <= ushort.max);
            result.k_slen = cast(ushort)key_length;
        }
        static if (is_bimap_string!V)
        {
            size_t value_length;
            foreach (i; 0 .. Data.value_count)
                value_length += static_bimap_string_length(entries[Data.result.value_sources[i]].value);
            assert(value_length <= ushort.max);
            result.v_slen = cast(ushort)value_length;
        }
        return result;
    }();

    enum ushort key_count = sizes.nk;
    enum ushort value_count = sizes.nv;
    enum ushort key_string_length = sizes.k_slen;
    enum ushort value_string_length = sizes.v_slen;
    enum size_t string_length = size_t(key_string_length) + value_string_length;

    struct Build
    {
        StoredK[key_count] keys;
        static if (!is(V == void))
            StoredV[value_count] values;
        char[string_length] strings;
        ushort[key_count] k2v;
        ushort[value_count] v2k;
        DeclarationIndex[key_count] k2decl;
    }

    enum Build built = () {
        Build result;
        static_bimap_copy(Data.result.key_sources[0 .. key_count], result.k2decl[]);
        size_t key_string_used;
        foreach (i; 0 .. key_count)
        {
            ushort source = Data.result.key_sources[i];
            static if (is_bimap_string!K)
            {
                static if (Types.has_values)
                    result.keys[i] = static_bimap_write_string(result.strings[0 .. key_string_length], key_string_used, entries[source].key);
                else
                    result.keys[i] = static_bimap_write_string(result.strings[0 .. key_string_length], key_string_used, entries[source]);
            }
            else static if (Types.has_values)
                result.keys[i] = entries[source].key;
            else
                result.keys[i] = entries[source];
        }
        static if (!is(V == void))
        {
            size_t value_string_used;
            foreach (i; 0 .. value_count)
            {
                ushort source = Data.result.value_sources[i];
                static if (is_bimap_string!V)
                    result.values[i] = static_bimap_write_string(result.strings[key_string_length .. $], value_string_used, entries[source].value);
                else
                    result.values[i] = entries[source].value;
            }
        }
        static if (Types.has_values)
            static_bimap_build_indexes(result.k2v, result.v2k, Data.result.key_sources[0 .. key_count], Data.result.source_to_key, Data.result.value_sources[0 .. value_count], Data.result.source_to_value);
        else
            static_bimap_build_indexes(result.k2v, result.v2k, Data.result.key_sources[0 .. key_count], Data.result.source_to_key);
        return result;
    }();

    enum bool maps_wide = bimap_indexes_is_wide(key_count, value_count, false);

    __gshared immutable StoredK[key_count] _keys = built.keys;

    static if (!is(V == void))
        __gshared immutable StoredV[value_count] _values = built.values;

    static if (is_bimap_string!K || is_bimap_string!V)
        align(2) __gshared immutable char[string_length] _strings = built.strings;

    static if (maps_wide)
        __gshared immutable ushort[key_count + value_count] _maps = () { ushort[key_count + value_count] result; static_bimap_concat(built.k2v, built.v2k, result[0 .. key_count], result[key_count .. $]); return result; }();
    else
        __gshared immutable ubyte[key_count + value_count] _maps = () { ubyte[key_count + value_count] result; static_bimap_concat(built.k2v, built.v2k, result[0 .. key_count], result[key_count .. $]); return result; }();

    static if (is_bimap_string!K)
        enum key_initializer = "k: _keys.ptr, k_strings: _strings.ptr, k_slen: key_string_length,";
    else
        enum key_initializer = "k: _keys.ptr,";
    static if (is(V == void))
        enum value_initializer = "";
    else static if (is_bimap_string!V)
        enum value_initializer = "v: _values.ptr, v_strings: _strings.ptr + key_string_length, v_slen: value_string_length,";
    else
        enum value_initializer = "v: _values.ptr,";
    static if (maps_wide)
        enum indexes_initializer = "nk: key_count, nv: value_count, vs: key_count, map_s: _maps.ptr,";
    else
        enum indexes_initializer = "nk: key_count, nv: value_count, vs: key_count, map_b: _maps.ptr,";

public:
    enum k2decl = built.k2decl;
    mixin("__gshared immutable Map map = {" ~ key_initializer ~ value_initializer ~ indexes_initializer ~ " };");
}

package(urt) struct BiMapSynthesisStorage(K, V)
{
    void[] memory;
    void* map;
    static if (is_bimap_string!K)
    {
        ushort* k;
        char* k_strings;
        ushort k_slen;
        ushort key_data_slen;
    }
    else
        K* k;
    static if (!is(V == void))
    {
        static if (is_bimap_string!V)
        {
            ushort* v;
            char* v_strings;
            ushort v_slen;
        }
        else
            V* v;
    }
    void* tail;
}

package(urt) ushort[] bimap_synthesis_scratch(size_t count, out void[] memory)
{
    memory = alloc(count*ushort.sizeof, ushort.alignof, MemFlags.fastest);
    assert(count == 0 || memory.ptr !is null);
    return (cast(ushort*)memory.ptr)[0 .. count];
}

auto synthesise_bimap(bool keys_unique = false, E)(const(E)[] entries, ushort[] sources = null)
{
    alias Types = BiMapSynthesisTypes!E;
    alias K = Types.Key;
    alias V = Types.Value;
    alias Map = BiMap!(K, V);
    enum unique_key_path = keys_unique && (!Types.has_values || !is(K == V));
    enum scratch_arrays = unique_key_path ? (Types.has_values ? 5 : 2) : 1;
    void[] allocated_scratch;
    if (sources is null)
        sources = bimap_synthesis_scratch(entries.length*scratch_arrays, allocated_scratch);
    scope(exit) free(allocated_scratch);
    static if (Types.has_values)
    {
        const(K)* keys = entries.length ? &entries[0].key : null;
        const(V)* values = entries.length ? &entries[0].value : null;
        auto storage = synthesise_bimap_storage!(keys_unique, K, V)(keys, E.sizeof, values, E.sizeof, entries.length, sources);
    }
    else
        auto storage = synthesise_bimap_storage!(keys_unique, K, void)(entries.ptr, K.sizeof, null, 0, entries.length, sources);
    return cast(const(Map)*)storage.map;
}

package(urt) pragma(inline, true) auto synthesise_bimap_storage(bool keys_unique = false, K, V)(const(K)* keys, size_t key_stride, const(V)* values, size_t value_stride, size_t count, ushort[] sources = null, size_t user_header_size = 0, ushort extra_key_strings = 0, size_t tail_size = 0)
{
    alias Map = BiMap!(K, V);
    alias Storage = BiMapSynthesisStorage!(K, V);
    enum has_values = !is(V == void);
    enum unique_key_path = keys_unique && (!has_values || !is(K == V));
    enum scratch_arrays = unique_key_path ? (has_values ? 5 : 2) : 1;
    static assert(is_trivial!K && (!has_values || is_trivial!V));
    assert(count <= ushort.max);
    assert(sources.length >= count*scratch_arrays);
    ushort[] scratch = sources;
    sources = sources[0 .. count];

    ushort[] source_to_key;
    static if (unique_key_path)
    {
        ushort[] extra = scratch[count .. count*scratch_arrays];
        source_to_key = extra[0 .. count];
    }
    ushort nk = bimap_synthesis_order!unique_key_path(keys, key_stride, sources, null, source_to_key);
    static if (keys_unique && !unique_key_path)
        assert(nk == count);
    ushort key_data_slen;
    static if (is_bimap_string!K)
        key_data_slen = bimap_synthesis_string_size!unique_key_path(keys, key_stride, sources);
    assert(extra_key_strings <= ushort.max - key_data_slen);
    ushort k_slen = cast(ushort)(key_data_slen + extra_key_strings);

    ushort nv = nk;
    ushort v_slen;
    ushort[] value_sources;
    ushort[] source_to_value;
    static if (has_values)
    {
        static if (unique_key_path)
        {
            ushort[] value_order = extra[count .. count*2];
            value_sources = extra[count*2 .. count*3];
            source_to_value = extra[count*3 .. count*4];
            nv = bimap_synthesis_order!false(values, value_stride, value_order, value_sources, source_to_value);
            value_sources = value_sources[0 .. nv];
        }
        else
        {
            nv = bimap_synthesis_order!false(values, value_stride, sources);
            value_sources = sources;
        }
        static if (is_bimap_string!V)
            v_slen = bimap_synthesis_string_size!unique_key_path(values, value_stride, value_sources);
    }

    static if (is_bimap_string!K)
        alias StoredK = ushort;
    else
        alias StoredK = K;
    static if (!has_values)
    {
        enum value_size = 0;
        enum value_alignment = 1;
    }
    else static if (is_bimap_string!V)
    {
        enum value_size = ushort.sizeof;
        enum value_alignment = ushort.alignof;
    }
    else
    {
        enum value_size = V.sizeof;
        enum value_alignment = V.alignof;
    }
    BiMapSynthesisLayout layout = BiMapSynthesisLayout(nk, nv, k_slen, v_slen, Map.sizeof, Map.alignof,
        StoredK.sizeof, StoredK.alignof, value_size, value_alignment, has_values,
        is_bimap_string!K || is_bimap_string!V, user_header_size, tail_size);
    void[] memory = alloc(layout.size, layout.alignment);
    if (memory.ptr is null)
        return Storage();
    ubyte* base = cast(ubyte*)memory.ptr;
    Map* map = cast(Map*)(base + layout.map);
    Storage storage = { memory: memory, map: map };

    static if (is_bimap_string!K)
    {
        map.k = cast(ushort*)(base + layout.keys);
        map.k_strings = cast(char*)(base + layout.key_strings);
        map.k_slen = k_slen;
        storage.k = map.k;
        storage.k_strings = map.k_strings;
        storage.k_slen = k_slen;
        storage.key_data_slen = key_data_slen;
    }
    else
    {
        map.k = cast(K*)(base + layout.keys);
        storage.k = map.k;
    }
    static if (has_values)
    {
        static if (is_bimap_string!V)
        {
            map.v = cast(ushort*)(base + layout.values);
            map.v_strings = cast(char*)(base + layout.value_strings);
            map.v_slen = v_slen;
            storage.v = map.v;
            storage.v_strings = map.v_strings;
            storage.v_slen = v_slen;
        }
        else
        {
            map.v = cast(V*)(base + layout.values);
            storage.v = map.v;
        }
    }
    if (layout.maps_wide)
        map.map_s = cast(ushort*)(base + layout.k2v);
    else
        map.map_b = cast(ubyte*)(base + layout.k2v);
    map.vs = nk;
    static if (unique_key_path)
    {
        map.nk = nk;
        map.nv = nv;
    }
    else
        bimap_synthesis_initialize(map.map_b, map.map_s, map.vs, map.nk, map.nv, nk, nv);

    static if (has_values)
    {
        static if (is_bimap_string!V)
            bimap_synthesis_write_strings!unique_key_path(values, value_stride, value_sources, map.v, map.v_strings, v_slen);
        else
            bimap_synthesis_write_values!unique_key_path(values, value_stride, value_sources, map.v);
        static if (!unique_key_path)
            bimap_synthesis_order!unique_key_path(keys, key_stride, sources);
    }
    static if (is_bimap_string!K)
        bimap_synthesis_write_strings!unique_key_path(keys, key_stride, sources, map.k, map.k_strings, key_data_slen);
    else
        bimap_synthesis_write_values!unique_key_path(keys, key_stride, sources, map.k);

    static if (unique_key_path)
    {
        static if (has_values)
            bimap_synthesis_build_cross_indexes(map.map_b, map.map_s, map.vs, map.nk, map.nv, sources,
                source_to_key, value_sources, source_to_value);
        else
            bimap_synthesis_build_ordinal_indexes(map.map_b, map.map_s, map.vs, map.nk, map.nv,
                source_to_key);
    }
    else
    {
        ushort ordinal;
        foreach (source; 0 .. count)
        {
            bool key_found;
            ushort key_index = map.key_offset(bimap_synthesis_value(keys, key_stride, cast(ushort)source), key_found);
            assert(key_found);
            static if (has_values)
            {
                bool value_found;
                ushort value_index = map.value_offset(bimap_synthesis_value(values, value_stride, cast(ushort)source), value_found);
                assert(value_found);
                bimap_synthesis_link(map.map_b, map.map_s, map.vs, map.nk, map.nv, key_index,
                    value_index);
            }
            else if (bimap_synthesis_link_ordinal(map.map_b, map.map_s, map.vs, map.nk, map.nv,
                key_index, ordinal))
                ++ordinal;
        }
    }
    storage.tail = base + layout.tail;
    return storage;
}

void release_synthesised_bimap(K, V)(const(BiMap!(K, V))* map)
{
    if (map is null)
        return;
    alias Map = BiMap!(K, V);
    static if (is_bimap_string!K)
        alias StoredK = ushort;
    else
        alias StoredK = K;
    static if (is(V == void))
    {
        enum value_size = 0;
        enum value_alignment = 1;
    }
    else static if (is_bimap_string!V)
    {
        enum value_size = ushort.sizeof;
        enum value_alignment = ushort.alignof;
    }
    else
    {
        enum value_size = V.sizeof;
        enum value_alignment = V.alignof;
    }
    static if (is_bimap_string!K)
        ushort k_slen = map.k_slen;
    else
        ushort k_slen;
    static if (is_bimap_string!V)
        ushort v_slen = map.v_slen;
    else
        ushort v_slen;
    BiMapSynthesisLayout layout = BiMapSynthesisLayout(map.key_count, map.value_count, k_slen, v_slen,
        Map.sizeof, Map.alignof, StoredK.sizeof, StoredK.alignof, value_size, value_alignment,
        !is(V == void), is_bimap_string!K || is_bimap_string!V);
    .free((cast(void*)map)[0 .. layout.size]);
}


private:

enum is_bimap_string(T) = is(T : const(char)[]);

template BiMapSynthesisTypes(E)
{
    alias Element = Unqual!E;
    static if (is(Element == KVP!(K, V), K, V))
    {
        alias Key = K;
        alias Value = V;
        enum has_values = true;
    }
    else
    {
        alias Key = Element;
        alias Value = void;
        enum has_values = false;
    }
}

struct BiMapSynthesisLayout
{
    size_t keys;
    size_t map;
    size_t values;
    size_t key_strings;
    size_t value_strings;
    size_t k2v;
    size_t tail;
    size_t tail_size;
    size_t size;
    size_t alignment;
    bool maps_wide;

    this(ushort nk, ushort nv, ushort k_slen, ushort v_slen, size_t map_size, size_t map_alignment,
        size_t key_size, size_t key_alignment, size_t value_size, size_t value_alignment,
        bool has_values, bool has_strings, size_t user_header_size = 0, size_t requested_tail_size = 0) pure nothrow @nogc
    {
        size_t endpoint_alignment = key_alignment > value_alignment ? key_alignment : value_alignment;
        alignment = map_alignment > endpoint_alignment ? map_alignment : endpoint_alignment;
        map = align_up(user_header_size, map_alignment);
        assert(map == user_header_size);
        size = map + map_size;
        keys = align_up(size, key_alignment);
        size = keys + size_t(nk) * key_size;
        if (has_values)
        {
            values = align_up(size, value_alignment);
            size = values + size_t(nv) * value_size;
        }
        maps_wide = bimap_indexes_is_wide(nk, nv, false);
        size_t map_width = maps_wide ? ushort.sizeof : ubyte.sizeof;
        k2v = align_up(size, map_width);
        size = k2v + size_t(nk + nv) * map_width;
        tail = size;
        tail_size = requested_tail_size;
        size += tail_size;
        if (has_strings)
        {
            key_strings = align_up(size, ushort.alignof);
            value_strings = key_strings + k_slen;
            size = value_strings + v_slen;
        }
    }
}

const(char)[] bimap_string_at(const(char)* strings, ushort offset) pure nothrow @nogc
{
    if (offset == 0)
        return null;
    if (__ctfe)
    {
        version (LittleEndian)
            ushort length = cast(ushort)(strings[offset - 2] | (strings[offset - 1] << 8));
        else
            ushort length = cast(ushort)(strings[offset - 1] | (strings[offset - 2] << 8));
        return strings[offset .. offset + length];
    }
    return as_dstring(strings + offset);
}

int bimap_string_compare(ushort offset, const(char)[] value, const(char)* strings) pure nothrow @nogc
    => compare(bimap_string_at(strings, offset), value);

void bimap_indexes_clear(ref ubyte* map_b, ref ushort* map_s, ref ushort vs, ref ushort nk,
    ref ushort nv, bool has_ack)
{
    if (!__ctfe)
        bimap_indexes_release(map_b, map_s, nk, nv, has_ack);
    map_b = null;
    vs = 0;
    nk = 0;
    nv = 0;
}

bool bimap_indexes_forward(const(ubyte)* bytes, const(ushort)* shorts, ushort nk, ushort nv, uint key_index,
    bool has_ack, out ushort value_index, out bool acknowledged) pure
{
    if (key_index >= nk)
        return false;
    ushort packed = bimap_indexes_k2v_at(bytes, shorts, nk, nv, key_index, has_ack);
    value_index = bimap_indexes_unpack(packed, has_ack);
    acknowledged = bimap_indexes_is_acknowledged(packed, has_ack);
    return true;
}

bool bimap_indexes_reverse(const(ubyte)* bytes, const(ushort)* shorts, uint vs, ushort nk, ushort nv,
    uint value_index, bool has_ack, out ushort key_index) pure
{
    if (value_index >= nv)
        return false;
    key_index = bimap_indexes_v2k_at(bytes, shorts, vs, nk, nv, value_index, has_ack);
    return key_index != bimap_indexes_invalid(bimap_indexes_is_wide(nk, nv, has_ack));
}

bool bimap_indexes_acknowledge(ubyte* bytes, ushort* shorts, ushort nk, ushort nv, uint key_index,
    uint value_index, bool has_ack)
{
    if (key_index >= nk || value_index >= nv)
        return false;
    ushort packed = bimap_indexes_k2v_at(bytes, shorts, nk, nv, key_index, has_ack);
    if (bimap_indexes_unpack(packed, has_ack) != value_index)
        return false;
    if (has_ack)
        bimap_indexes_set_k2v(bytes, shorts, nk, nv, key_index, cast(ushort)(packed | 1), has_ack);
    return true;
}

BiMapResult bimap_indexes_insert(ref ubyte* map_b, ref ushort* map_s, ref ushort vs, ref ushort nk,
    ref ushort nv, ushort key_index, ushort value_index, bool key_found, bool value_found, bool has_ack)
{
    if (key_found && value_found)
        return BiMapResult.existing;
    uint new_nk = uint(nk) + (key_found ? 0 : 1);
    uint new_nv = uint(nv) + (value_found ? 0 : 1);
    if (new_nk > ushort.max || new_nv > bimap_indexes_max_values(has_ack) ||
        bimap_indexes_allocation_for(new_nk > new_nv ? new_nk : new_nv) == 0)
        return BiMapResult.exhausted;

    ushort old_nk = nk;
    ushort old_nv = nv;
    bimap_indexes_reallocate(map_b, map_s, vs, old_nk, old_nv, new_nk, new_nv, has_ack);
    nk = cast(ushort)new_nk;
    nv = cast(ushort)new_nv;
    ubyte* bytes = map_b;
    ushort* shorts = map_s;
    if (!value_found)
        bimap_indexes_adjust_forward(bytes, shorts, old_nk, nk, nv, value_index, has_ack);
    if (!key_found)
        bimap_indexes_adjust_reverse(bytes, shorts, vs, old_nv, nk, nv, key_index, has_ack);
    if (!key_found)
        bimap_indexes_insert_k2v(bytes, shorts, old_nk, nk, nv, key_index,
            bimap_indexes_pack(value_index, has_ack, false), has_ack);
    if (!value_found)
        bimap_indexes_insert_v2k(bytes, shorts, vs, old_nv, nk, nv, value_index, key_index, has_ack);
    return BiMapResult.inserted;
}

BiMapResult bimap_indexes_insert(ref ubyte* map_b, ref ushort* map_s, ref ushort vs, ref ushort nk,
    ref ushort nv, ushort key_index, bool key_found, uint ordinal, bool has_ack)
{
    if (ordinal >= bimap_indexes_max_values(has_ack))
        return BiMapResult.exhausted;
    bool value_found;
    if (ordinal < nv)
    {
        value_found = bimap_indexes_v2k_at(map_b, map_s, vs, nk, nv, ordinal, has_ack) !=
            bimap_indexes_invalid(bimap_indexes_is_wide(nk, nv, has_ack));
    }
    if (key_found && value_found)
        return BiMapResult.existing;

    uint new_nk = uint(nk) + (key_found ? 0 : 1);
    uint new_nv = ordinal >= nv ? ordinal + 1 : nv;
    if (new_nk > ushort.max || new_nv > bimap_indexes_max_values(has_ack) ||
        bimap_indexes_allocation_for(new_nk > new_nv ? new_nk : new_nv) == 0)
        return BiMapResult.exhausted;

    ushort old_nk = nk;
    ushort old_nv = nv;
    bimap_indexes_reallocate(map_b, map_s, vs, old_nk, old_nv, new_nk, new_nv, has_ack);
    nk = cast(ushort)new_nk;
    nv = cast(ushort)new_nv;
    ubyte* bytes = map_b;
    ushort* shorts = map_s;
    if (!key_found)
        bimap_indexes_adjust_reverse(bytes, shorts, vs, old_nv, nk, nv, key_index, has_ack);
    ushort missing = bimap_indexes_invalid(bimap_indexes_is_wide(new_nk, new_nv, has_ack));
    for (uint i = old_nv; i < new_nv; ++i)
        bimap_indexes_set_v2k(bytes, shorts, vs, nk, nv, i, missing, has_ack);
    if (!key_found)
        bimap_indexes_insert_k2v(bytes, shorts, old_nk, nk, nv, key_index,
            bimap_indexes_pack(cast(ushort)ordinal, has_ack, false), has_ack);
    if (!value_found)
        bimap_indexes_set_v2k(bytes, shorts, vs, nk, nv, ordinal, key_index, has_ack);
    return BiMapResult.inserted;
}

BiMapResult bimap_indexes_insert(ref ubyte* maps, ref ushort vs, ref ushort nk, ref ushort nv,
    ushort key_index, ushort value_index, bool key_found, bool value_found, bool has_ack)
{
    if (key_found && value_found)
        return BiMapResult.existing;
    uint new_nk = uint(nk) + (key_found ? 0 : 1);
    uint new_nv = uint(nv) + (value_found ? 0 : 1);
    if (new_nk > ushort.max || new_nv > bimap_indexes_max_values(has_ack) ||
        bimap_indexes_allocation_for(new_nk > new_nv ? new_nk : new_nv) == 0)
        return BiMapResult.exhausted;

    ushort old_nk = nk;
    ushort old_nv = nv;
    bimap_indexes_reallocate_runtime(maps, vs, old_nk, old_nv, new_nk, new_nv, has_ack);
    nk = cast(ushort)new_nk;
    nv = cast(ushort)new_nv;
    if (!value_found)
        bimap_indexes_adjust_forward_runtime(maps, old_nk, nk, nv, value_index, has_ack);
    if (!key_found)
        bimap_indexes_adjust_reverse_runtime(maps, vs, old_nv, nk, nv, key_index, has_ack);
    if (!key_found)
        bimap_indexes_insert_k2v_runtime(maps, old_nk, nk, nv, key_index,
            bimap_indexes_pack(value_index, has_ack, false), has_ack);
    if (!value_found)
        bimap_indexes_insert_v2k_runtime(maps, vs, old_nv, nk, nv, value_index, key_index, has_ack);
    return BiMapResult.inserted;
}

BiMapResult bimap_indexes_insert(ref ubyte* maps, ref ushort vs, ref ushort nk, ref ushort nv,
    ushort key_index, bool key_found, uint ordinal, bool has_ack)
{
    if (ordinal >= bimap_indexes_max_values(has_ack))
        return BiMapResult.exhausted;
    bool value_found;
    if (ordinal < nv)
    {
        value_found = bimap_indexes_v2k_at_runtime(maps, vs, nk, nv, ordinal, has_ack) !=
            bimap_indexes_invalid(bimap_indexes_is_wide(nk, nv, has_ack));
    }
    if (key_found && value_found)
        return BiMapResult.existing;

    uint new_nk = uint(nk) + (key_found ? 0 : 1);
    uint new_nv = ordinal >= nv ? ordinal + 1 : nv;
    if (new_nk > ushort.max || new_nv > bimap_indexes_max_values(has_ack) ||
        bimap_indexes_allocation_for(new_nk > new_nv ? new_nk : new_nv) == 0)
        return BiMapResult.exhausted;

    ushort old_nk = nk;
    ushort old_nv = nv;
    bimap_indexes_reallocate_runtime(maps, vs, old_nk, old_nv, new_nk, new_nv, has_ack);
    nk = cast(ushort)new_nk;
    nv = cast(ushort)new_nv;
    if (!key_found)
        bimap_indexes_adjust_reverse_runtime(maps, vs, old_nv, nk, nv, key_index, has_ack);
    ushort missing = bimap_indexes_invalid(bimap_indexes_is_wide(new_nk, new_nv, has_ack));
    for (uint i = old_nv; i < new_nv; ++i)
        bimap_indexes_set_v2k_runtime(maps, vs, nk, nv, i, missing, has_ack);
    if (!key_found)
        bimap_indexes_insert_k2v_runtime(maps, old_nk, nk, nv, key_index,
            bimap_indexes_pack(cast(ushort)ordinal, has_ack, false), has_ack);
    if (!value_found)
        bimap_indexes_set_v2k_runtime(maps, vs, nk, nv, ordinal, key_index, has_ack);
    return BiMapResult.inserted;
}

static ushort bimap_indexes_allocation_for(uint count) pure
{
    if (count == 0)
        return 0;
    if (count <= 4)
        return 4;
    uint allocation = next_power_of_2(count);
    return allocation <= ushort.max ? cast(ushort)allocation : 0;
}

private:

static uint bimap_indexes_max_values(bool has_ack) pure
    => has_ack ? ushort.max >> 1 : ushort.max;

static bool bimap_indexes_is_wide(uint key_count, uint value_count, bool has_ack) pure
    => key_count >= 256 || (has_ack ? value_count >= 128 : value_count >= 256);

static ushort bimap_indexes_invalid(bool wide) pure
    => wide ? ushort.max : ubyte.max;

static ushort bimap_indexes_pack(ushort value, bool has_ack, bool acknowledged) pure
    => has_ack ? cast(ushort)((value << 1) | (acknowledged ? 1 : 0)) : value;

static ushort bimap_indexes_unpack(ushort value, bool has_ack) pure
    => has_ack ? value >> 1 : value;

static bool bimap_indexes_is_acknowledged(ushort value, bool has_ack) pure
    => !has_ack || (value & 1) != 0;

ushort bimap_indexes_k2v_at(const(ubyte)* bytes, const(ushort)* shorts, uint nk, uint nv, uint index,
    bool has_ack) pure
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        return shorts[index];
    return bytes[index];
}

ushort bimap_indexes_v2k_at(const(ubyte)* bytes, const(ushort)* shorts, uint vs, uint nk, uint nv,
    uint index, bool has_ack) pure
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        return shorts[vs + index];
    return bytes[vs + index];
}

void bimap_indexes_set_k2v(ubyte* bytes, ushort* shorts, uint nk, uint nv, uint index, ushort value,
    bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        shorts[index] = value;
    else
        bytes[index] = cast(ubyte)value;
}

void bimap_indexes_set_v2k(ubyte* bytes, ushort* shorts, uint vs, uint nk, uint nv, uint index,
    ushort value, bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        shorts[vs + index] = value;
    else
        bytes[vs + index] = cast(ubyte)value;
}

void bimap_indexes_adjust_forward(ubyte* bytes, ushort* shorts, uint length, uint nk, uint nv,
    ushort inserted, bool has_ack)
{
    bool wide = bimap_indexes_is_wide(nk, nv, has_ack);
    foreach (i; 0 .. length)
    {
        ushort packed = wide ? shorts[i] : bytes[i];
        ushort value_index = bimap_indexes_unpack(packed, has_ack);
        if (value_index >= inserted)
        {
            ushort adjusted = bimap_indexes_pack(cast(ushort)(value_index + 1), has_ack,
                bimap_indexes_is_acknowledged(packed, has_ack));
            if (wide)
                shorts[i] = adjusted;
            else
                bytes[i] = cast(ubyte)adjusted;
        }
    }
}

void bimap_indexes_adjust_reverse(ubyte* bytes, ushort* shorts, uint vs, uint length, uint nk, uint nv,
    ushort inserted, bool has_ack)
{
    bool wide = bimap_indexes_is_wide(nk, nv, has_ack);
    ushort missing = bimap_indexes_invalid(wide);
    if (wide)
    {
        ushort* values = shorts + vs;
        foreach (ref key_index; values[0 .. length])
            if (key_index != missing && key_index >= inserted)
                ++key_index;
        return;
    }
    ubyte* values = bytes + vs;
    foreach (ref key_index; values[0 .. length])
        if (key_index != missing && key_index >= inserted)
            ++key_index;
}

void bimap_indexes_reallocate(ref ubyte* bytes, ref ushort* shorts, ref ushort vs, uint old_nk,
    uint old_nv, uint new_nk, uint new_nv, bool has_ack)
{
    ushort old_vs = vs;
    ushort new_capacity = bimap_indexes_allocation_for(new_nk > new_nv ? new_nk : new_nv);
    assert(new_capacity != 0);
    bool old_wide = bimap_indexes_is_wide(old_nk, old_nv, has_ack);
    bool new_wide = bimap_indexes_is_wide(new_nk, new_nv, has_ack);
    if (old_vs == new_capacity && old_wide == new_wide)
        return;

    if (__ctfe)
    {
        if (new_wide)
        {
            ushort[] values = bimap_alloc_array!ushort(new_capacity * 2);
            foreach (i; 0 .. old_nk)
                values[i] = old_wide ? shorts[i] : bimap_indexes_widened(bytes[i]);
            foreach (i; 0 .. old_nv)
                values[new_capacity + i] = old_wide ? shorts[old_vs + i] : bimap_indexes_widened(bytes[old_vs + i]);
            shorts = values.ptr;
        }
        else
        {
            ubyte[] values = bimap_alloc_array!ubyte(new_capacity * 2);
            foreach (i; 0 .. old_nk)
                values[i] = bytes[i];
            foreach (i; 0 .. old_nv)
                values[new_capacity + i] = bytes[old_vs + i];
            bytes = values.ptr;
        }
        vs = new_capacity;
        return;
    }

    if (old_wide != new_wide)
    {
        assert(new_wide);
        ushort* values = cast(ushort*)array_allocate(new_capacity * 2, ushort.sizeof, uint.alignof, uint.sizeof);
        foreach (i; 0 .. old_nk)
            values[i] = bimap_indexes_widened(bytes[i]);
        foreach (i; 0 .. old_nv)
            values[new_capacity + i] = bimap_indexes_widened(bytes[old_vs + i]);
        if (bytes !is null)
            array_free(bytes, ubyte.sizeof, uint.sizeof);
        shorts = values;
        vs = new_capacity;
        return;
    }

    if (new_wide)
    {
        uint total_capacity = shorts is null ? 0 : (cast(uint*)shorts)[-1];
        shorts = cast(ushort*)array_grow_trivial(shorts, old_vs * 2, total_capacity, new_capacity * 2,
            ushort.sizeof, uint.alignof, uint.sizeof, shorts !is null);
        if (old_nv)
            shorts[old_vs .. old_vs + old_nv].move_to!true(shorts[new_capacity .. new_capacity + old_nv]);
    }
    else
    {
        uint total_capacity = bytes is null ? 0 : (cast(uint*)bytes)[-1];
        bytes = cast(ubyte*)array_grow_trivial(bytes, old_vs * 2, total_capacity, new_capacity * 2,
            ubyte.sizeof, uint.alignof, uint.sizeof, bytes !is null);
        if (old_nv)
            bytes[old_vs .. old_vs + old_nv].move_to!true(bytes[new_capacity .. new_capacity + old_nv]);
    }
    vs = new_capacity;
}

static ushort bimap_indexes_widened(ubyte value) pure
    => value == ubyte.max ? ushort.max : value;

void bimap_indexes_release(ubyte* bytes, ushort* shorts, uint nk, uint nv, bool has_ack)
{
    if (bytes is null)
        return;
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        array_free(shorts, ushort.sizeof, uint.sizeof);
    else
        array_free(bytes, ubyte.sizeof, uint.sizeof);
}

void bimap_indexes_insert_k2v(ubyte* bytes, ushort* shorts, uint length, uint nk, uint nv, uint index,
    ushort value, bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
    {
        if (index < length)
            shorts[index .. length].move_to!true(shorts[index + 1 .. length + 1]);
        shorts[index] = value;
    }
    else
    {
        if (index < length)
            bytes[index .. length].move_to!true(bytes[index + 1 .. length + 1]);
        bytes[index] = cast(ubyte)value;
    }
}

void bimap_indexes_insert_v2k(ubyte* bytes, ushort* shorts, uint vs, uint length, uint nk, uint nv,
    uint index, ushort value, bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
    {
        ushort* values = shorts + vs;
        if (index < length)
            values[index .. length].move_to!true(values[index + 1 .. length + 1]);
        values[index] = value;
    }
    else
    {
        ubyte* values = bytes + vs;
        if (index < length)
            values[index .. length].move_to!true(values[index + 1 .. length + 1]);
        values[index] = cast(ubyte)value;
    }
}

ushort bimap_indexes_v2k_at_runtime(const(ubyte)* maps, uint vs, uint nk, uint nv, uint index,
    bool has_ack) pure
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        return (cast(const(ushort)*)maps)[vs + index];
    return maps[vs + index];
}

void bimap_indexes_set_v2k_runtime(ubyte* maps, uint vs, uint nk, uint nv, uint index, ushort value,
    bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
        (cast(ushort*)maps)[vs + index] = value;
    else
        maps[vs + index] = cast(ubyte)value;
}

void bimap_indexes_adjust_forward_runtime(ubyte* maps, uint length, uint nk, uint nv, ushort inserted,
    bool has_ack)
{
    bool wide = bimap_indexes_is_wide(nk, nv, has_ack);
    foreach (i; 0 .. length)
    {
        ushort packed = wide ? (cast(ushort*)maps)[i] : maps[i];
        ushort value_index = bimap_indexes_unpack(packed, has_ack);
        if (value_index >= inserted)
        {
            ushort adjusted = bimap_indexes_pack(cast(ushort)(value_index + 1), has_ack,
                bimap_indexes_is_acknowledged(packed, has_ack));
            if (wide)
                (cast(ushort*)maps)[i] = adjusted;
            else
                maps[i] = cast(ubyte)adjusted;
        }
    }
}

void bimap_indexes_adjust_reverse_runtime(ubyte* maps, uint vs, uint length, uint nk, uint nv,
    ushort inserted, bool has_ack)
{
    bool wide = bimap_indexes_is_wide(nk, nv, has_ack);
    ushort missing = bimap_indexes_invalid(wide);
    if (wide)
    {
        ushort* values = cast(ushort*)maps + vs;
        foreach (ref key_index; values[0 .. length])
            if (key_index != missing && key_index >= inserted)
                ++key_index;
        return;
    }
    ubyte* values = maps + vs;
    foreach (ref key_index; values[0 .. length])
        if (key_index != missing && key_index >= inserted)
            ++key_index;
}

void bimap_indexes_reallocate_runtime(ref ubyte* maps, ref ushort vs, uint old_nk, uint old_nv,
    uint new_nk, uint new_nv, bool has_ack)
{
    ushort old_vs = vs;
    ushort new_capacity = bimap_indexes_allocation_for(new_nk > new_nv ? new_nk : new_nv);
    assert(new_capacity != 0);
    bool old_wide = bimap_indexes_is_wide(old_nk, old_nv, has_ack);
    bool new_wide = bimap_indexes_is_wide(new_nk, new_nv, has_ack);
    if (old_vs == new_capacity && old_wide == new_wide)
        return;

    if (old_wide != new_wide)
    {
        assert(new_wide);
        ushort* values = cast(ushort*)array_allocate(new_capacity * 2, ushort.sizeof, uint.alignof, uint.sizeof);
        foreach (i; 0 .. old_nk)
            values[i] = bimap_indexes_widened(maps[i]);
        foreach (i; 0 .. old_nv)
            values[new_capacity + i] = bimap_indexes_widened(maps[old_vs + i]);
        if (maps !is null)
            array_free(maps, ubyte.sizeof, uint.sizeof);
        maps = cast(ubyte*)values;
        vs = new_capacity;
        return;
    }

    if (new_wide)
    {
        ushort* values = cast(ushort*)maps;
        uint total_capacity = values is null ? 0 : (cast(uint*)values)[-1];
        values = cast(ushort*)array_grow_trivial(values, old_vs * 2, total_capacity, new_capacity * 2,
            ushort.sizeof, uint.alignof, uint.sizeof, values !is null);
        if (old_nv)
            values[old_vs .. old_vs + old_nv].move_to!true(values[new_capacity .. new_capacity + old_nv]);
        maps = cast(ubyte*)values;
    }
    else
    {
        uint total_capacity = maps is null ? 0 : (cast(uint*)maps)[-1];
        maps = cast(ubyte*)array_grow_trivial(maps, old_vs * 2, total_capacity, new_capacity * 2,
            ubyte.sizeof, uint.alignof, uint.sizeof, maps !is null);
        if (old_nv)
            maps[old_vs .. old_vs + old_nv].move_to!true(maps[new_capacity .. new_capacity + old_nv]);
    }
    vs = new_capacity;
}

void bimap_indexes_insert_k2v_runtime(ubyte* maps, uint length, uint nk, uint nv, uint index,
    ushort value, bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
    {
        ushort* values = cast(ushort*)maps;
        if (index < length)
            values[index .. length].move_to!true(values[index + 1 .. length + 1]);
        values[index] = value;
    }
    else
    {
        if (index < length)
            maps[index .. length].move_to!true(maps[index + 1 .. length + 1]);
        maps[index] = cast(ubyte)value;
    }
}

void bimap_indexes_insert_v2k_runtime(ubyte* maps, uint vs, uint length, uint nk, uint nv, uint index,
    ushort value, bool has_ack)
{
    if (bimap_indexes_is_wide(nk, nv, has_ack))
    {
        ushort* values = cast(ushort*)maps + vs;
        if (index < length)
            values[index .. length].move_to!true(values[index + 1 .. length + 1]);
        values[index] = value;
    }
    else
    {
        ubyte* values = maps + vs;
        if (index < length)
            values[index .. length].move_to!true(values[index + 1 .. length + 1]);
        values[index] = cast(ubyte)value;
    }
}

void bimap_reallocate_values(T)(ref T* values, uint old_count, uint new_count)
{
    uint old_allocation = bimap_values_allocation_for(old_count);
    uint new_allocation = bimap_values_allocation_for(new_count);
    if (old_allocation == new_allocation)
        return;
    if (__ctfe)
    {
        T[] memory = bimap_alloc_array!T(new_allocation);
        if (values !is null)
        {
            foreach (i; 0 .. old_count)
                memory[i] = values[i];
        }
        values = memory.ptr;
        return;
    }
    void[] old_memory = values is null ? null : (cast(void*)values)[0 .. old_allocation * T.sizeof];
    void[] memory = .realloc(old_memory, new_allocation * T.sizeof, T.alignof);
    values = cast(T*)memory.ptr;
}

static uint bimap_values_allocation_for(uint count) pure
{
    if (count == 0)
        return 0;
    if (count <= 4)
        return 4;
    return next_power_of_2(count);
}

void bimap_release_values(T)(T* values, uint count)
{
    if (__ctfe || values is null)
        return;
    enum prefix = T.sizeof < 4 ? 4 : T.sizeof;
    array_free(values, T.sizeof, prefix);
}

T[] bimap_alloc_array(T)(uint count) @trusted
{
    if (__ctfe)
    {
        static T[] allocate(size_t size) nothrow => new T[size];
        alias Allocate = T[] function(size_t) nothrow @nogc;
        return (cast(Allocate)&allocate)(count);
    }
    return alloc_array!T(count);
}

void bimap_insert_value(T)(ref T* values, uint length, uint index, T value)
{
    if (__ctfe)
    {
        bimap_reallocate_values(values, length, length + 1);
        if (index < length)
            values[index .. length].move_to!true(values[index + 1 .. length + 1]);
        values[index] = value;
        return;
    }
    enum alignment = T.alignof < 4 ? 4 : T.alignof;
    enum prefix = T.sizeof < 4 ? 4 : T.sizeof;
    uint capacity = values is null ? 0 : (cast(uint*)values)[-1];
    values = cast(T*)array_insert_trivial(values, length, capacity, index, &value, T.sizeof, alignment, prefix, values !is null);
}

bool bimap_string_fits(ushort used, const(char)[] value) pure
{
    if (value.length == 0)
        return true;
    size_t required = 2 + value.length + (value.length & 1);
    return required <= ushort.max - used;
}

void bimap_insert_string(ref ushort* offsets, ref char* strings, ref ushort used, uint length, uint index, const(char)[] value)
{
    if (value.length == 0)
    {
        bimap_insert_value(offsets, length, index, cast(ushort)0);
        return;
    }
    uint required = cast(uint)(2 + value.length + (value.length & 1));
    uint new_used = used + required;
    if (__ctfe)
        bimap_reallocate_values(strings, used, new_used);
    else
    {
        Array!char array;
        array.assume_ownership(strings, used);
        array.extend!false(required);
        strings = array.release_ownership();
    }
    ushort offset = cast(ushort)(used + 2);
    if (__ctfe)
    {
        version (LittleEndian)
        {
            strings[used] = cast(char)(value.length & 0xFF);
            strings[used + 1] = cast(char)(value.length >> 8);
        }
        else
        {
            strings[used] = cast(char)(value.length >> 8);
            strings[used + 1] = cast(char)(value.length & 0xFF);
        }
        strings[offset .. offset + value.length] = value[];
    }
    else
        write_string(strings + offset, value);
    if (value.length & 1)
        strings[new_used - 1] = 0;
    bimap_insert_value(offsets, length, index, offset);
    used = cast(ushort)new_used;
}

template StaticBiMapTypes(alias entries)
{
    alias Types = BiMapSynthesisTypes!(typeof(entries[0]));
    alias Key = Types.Key;
    alias Value = Types.Value;
    enum has_values = Types.has_values;
}

package(urt) template StaticBiMapData(alias entries)
{
package(urt):
    enum size_t source_count = entries.length;
    static assert(source_count != 0);
    static assert(source_count <= ushort.max);
    alias Types = StaticBiMapTypes!entries;
    alias K = Types.Key;
    alias V = Types.Value;

    struct Result
    {
        ushort[source_count] key_sources;
        ushort[source_count] source_to_key;
        static if (Types.has_values)
        {
            ushort[source_count] value_sources;
            ushort[source_count] source_to_value;
        }
        ushort nk;
        ushort nv;
    }

    enum Result result = () {
        K[source_count] keys;
        ushort[source_count] key_sources;
        static if (Types.has_values)
        {
            V[source_count] values;
            ushort[source_count] value_sources;
        }
        static foreach (source; 0 .. source_count)
        {{
            static if (Types.has_values)
            {
                keys[source] = entries[source].key;
                values[source] = entries[source].value;
            }
            else
                keys[source] = entries[source];
        }}
        static_bimap_iota(key_sources);
        bimap_synthesis_qsort(keys.ptr, K.sizeof, key_sources);
        static if (Types.has_values)
        {
            static_bimap_iota(value_sources);
            bimap_synthesis_qsort(values.ptr, V.sizeof, value_sources);
        }

        Result sorted;
        sorted.nk = bimap_synthesis_deduplicate(keys.ptr, K.sizeof, key_sources, sorted.key_sources, sorted.source_to_key);
        static if (Types.has_values)
            sorted.nv = bimap_synthesis_deduplicate(values.ptr, V.sizeof, value_sources, sorted.value_sources, sorted.source_to_value);
        else
            sorted.nv = sorted.nk;
        return sorted;
    }();

    enum ushort key_count = result.nk;
    enum ushort value_count = result.nv;
}

void static_bimap_iota(ushort[] values) pure
{
    foreach (i, ref value; values)
        value = cast(ushort)i;
}

package(urt) ushort bimap_synthesis_order(bool unique, T)(const(T)* values, size_t stride, ushort[] sources, ushort[] unique_sources = null, ushort[] source_to_unique = null) pure
{
    if (!__ctfe)
        return bimap_synthesis_order(unique, sources, unique_sources, source_to_unique,
            (ushort a, ushort b) => compare(bimap_synthesis_value(values, stride, a), bimap_synthesis_value(values, stride, b)));
    static_bimap_iota(sources);
    bimap_synthesis_qsort(values, stride, sources);
    static if (unique)
    {
        assert(bimap_synthesis_unique(values, stride, sources));
        assert(unique_sources is null || unique_sources.length == sources.length);
        assert(source_to_unique is null || source_to_unique.length == sources.length);
        foreach (i, source; sources)
        {
            if (unique_sources !is null)
                unique_sources[i] = source;
            if (source_to_unique !is null)
                source_to_unique[source] = cast(ushort)i;
        }
        return cast(ushort)sources.length;
    }
    else
        return bimap_synthesis_deduplicate(values, stride, sources, unique_sources, source_to_unique);
}

ushort bimap_synthesis_order(bool unique, ushort[] sources, ushort[] unique_sources, ushort[] source_to_unique,
    scope int delegate(ushort a, ushort b) pure nothrow @nogc value_compare) pure
{
    static_bimap_iota(sources);
    qsort(sources, (ref ushort a, ref ushort b) {
        int order = value_compare(a, b);
        return order ? order : a < b ? -1 : a > b ? 1 : 0;
    });
    assert(unique_sources is null || unique_sources.length == sources.length);
    assert(source_to_unique is null || source_to_unique.length == sources.length);
    ushort count;
    foreach (i, source; sources)
    {
        bool distinct = i == 0 || value_compare(sources[i - 1], source) != 0;
        if (unique)
            assert(distinct);
        if (distinct)
        {
            if (unique_sources !is null)
                unique_sources[count] = source;
            ++count;
        }
        if (source_to_unique !is null)
            source_to_unique[source] = cast(ushort)(count - 1);
    }
    return count;
}

ref const(T) bimap_synthesis_value(T)(const(T)* values, size_t stride, ushort source) @trusted pure
{
    if (__ctfe)
    {
        assert(stride == T.sizeof);
        return values[source];
    }
    return *cast(const(T)*)(cast(const(ubyte)*)values + source * stride);
}

int bimap_synthesis_compare(T)(const(T)* values, size_t stride, ushort a_source, ushort b_source) pure
{
    int order = compare(bimap_synthesis_value(values, stride, a_source), bimap_synthesis_value(values, stride, b_source));
    return order ? order : compare(a_source, b_source);
}

void bimap_synthesis_qsort(T)(const(T)* values, size_t stride, ushort[] sources) pure
{
    assert(__ctfe);
    if (sources.length <= 1)
        return;

    size_t pivot = sources.length / 2;
    size_t i;
    ptrdiff_t j = sources.length - 1;
    while (i <= j)
    {
        while (bimap_synthesis_compare(values, stride, sources[i], sources[pivot]) < 0)
            ++i;
        while (bimap_synthesis_compare(values, stride, sources[j], sources[pivot]) > 0)
            --j;
        if (i <= j)
        {
            if (i == pivot)
                pivot = j;
            else if (j == pivot)
                pivot = i;
            ushort source = sources[i];
            sources[i] = sources[j];
            sources[j] = source;
            ++i;
            --j;
        }
    }
    if (j >= 0)
        bimap_synthesis_qsort(values, stride, sources[0 .. j + 1]);
    if (i < sources.length)
        bimap_synthesis_qsort(values, stride, sources[i .. $]);
}

ushort bimap_synthesis_deduplicate(T)(const(T)* values, size_t stride, const(ushort)[] sources, ushort[] unique_sources = null, ushort[] source_to_unique = null) pure
{
    assert(unique_sources is null || unique_sources.length == sources.length);
    assert(source_to_unique is null || source_to_unique.length == sources.length);
    ushort count;
    foreach (i, source; sources)
    {
        if (i == 0 || compare(bimap_synthesis_value(values, stride, sources[i - 1]), bimap_synthesis_value(values, stride, source)) != 0)
        {
            if (unique_sources !is null)
                unique_sources[count] = source;
            ++count;
        }
        if (source_to_unique !is null)
            source_to_unique[source] = cast(ushort)(count - 1);
    }
    return count;
}

bool bimap_synthesis_unique(T)(const(T)* values, size_t stride, const(ushort)[] sources) pure
{
    foreach (i; 1 .. sources.length)
        if (compare(bimap_synthesis_value(values, stride, sources[i - 1]), bimap_synthesis_value(values, stride, sources[i])) == 0)
            return false;
    return true;
}

ushort bimap_synthesis_string_size(bool unique, T)(const(T)* values, size_t stride, const(ushort)[] sources) pure
{
    size_t size;
    foreach (i, source; sources)
    {
        static if (!unique)
            if (i && compare(bimap_synthesis_value(values, stride, sources[i - 1]), bimap_synthesis_value(values, stride, source)) == 0)
                continue;
        size += static_bimap_string_length(bimap_synthesis_value(values, stride, source));
    }
    assert(size <= ushort.max);
    return cast(ushort)size;
}

void bimap_synthesis_write_values(bool unique, T)(const(T)* values, size_t stride, const(ushort)[] sources, T* destination)
{
    ushort target;
    foreach (i, source; sources)
    {
        static if (!unique)
            if (i && compare(bimap_synthesis_value(values, stride, sources[i - 1]), bimap_synthesis_value(values, stride, source)) == 0)
                continue;
        destination[target++] = bimap_synthesis_value(values, stride, source);
    }
}

void bimap_synthesis_write_strings(bool unique, T)(const(T)* values, size_t stride, const(ushort)[] sources, ushort* destination, char* strings, ushort string_length)
{
    ushort target;
    size_t used;
    foreach (i, source; sources)
    {
        static if (!unique)
            if (i && compare(bimap_synthesis_value(values, stride, sources[i - 1]), bimap_synthesis_value(values, stride, source)) == 0)
                continue;
        destination[target++] = static_bimap_write_string(strings[0 .. string_length], used, bimap_synthesis_value(values, stride, source));
    }
    assert(used == string_length);
}

void bimap_synthesis_initialize(ubyte* map_b, ushort* map_s, ushort vs, ref ushort map_nk,
    ref ushort map_nv, ushort nk, ushort nv)
{
    map_nk = nk;
    map_nv = nv;
    ushort missing_value = bimap_indexes_invalid(bimap_indexes_is_wide(nk, nv, false));
    ushort missing_key = missing_value;
    foreach (i; 0 .. nk)
        bimap_indexes_set_k2v(map_b, map_s, nk, nv, i, missing_value, false);
    foreach (i; 0 .. nv)
        bimap_indexes_set_v2k(map_b, map_s, vs, nk, nv, i, missing_key, false);
}

bool bimap_synthesis_link(ubyte* map_b, ushort* map_s, ushort vs, ushort nk, ushort nv,
    ushort key_index, ushort value_index)
{
    ushort missing_value = bimap_indexes_invalid(bimap_indexes_is_wide(nk, nv, false));
    ushort missing_key = missing_value;
    bool added = bimap_indexes_k2v_at(map_b, map_s, nk, nv, key_index, false) == missing_value;
    if (added)
        bimap_indexes_set_k2v(map_b, map_s, nk, nv, key_index, value_index, false);
    if (bimap_indexes_v2k_at(map_b, map_s, vs, nk, nv, value_index, false) == missing_key)
        bimap_indexes_set_v2k(map_b, map_s, vs, nk, nv, value_index, key_index, false);
    return added;
}

void bimap_synthesis_build_cross_indexes(ubyte* map_b, ushort* map_s, ushort vs, ushort nk, ushort nv,
    const(ushort)[] key_sources, const(ushort)[] source_to_key, const(ushort)[] value_sources,
    const(ushort)[] source_to_value)
{
    foreach (key_index, source; key_sources)
        bimap_indexes_set_k2v(map_b, map_s, nk, nv, cast(uint)key_index, source_to_value[source], false);
    foreach (value_index, source; value_sources)
        bimap_indexes_set_v2k(map_b, map_s, vs, nk, nv, cast(uint)value_index, source_to_key[source], false);
}

void bimap_synthesis_build_ordinal_indexes(ubyte* map_b, ushort* map_s, ushort vs, ushort nk,
    ushort nv, const(ushort)[] source_to_key)
{
    foreach (source, key_index; source_to_key)
    {
        bimap_indexes_set_k2v(map_b, map_s, nk, nv, key_index, cast(ushort)source, false);
        bimap_indexes_set_v2k(map_b, map_s, vs, nk, nv, cast(uint)source, key_index, false);
    }
}

bool bimap_synthesis_link_ordinal(ubyte* map_b, ushort* map_s, ushort vs, ushort nk, ushort nv,
    ushort key_index, ushort ordinal)
{
    ushort missing_value = bimap_indexes_invalid(bimap_indexes_is_wide(nk, nv, false));
    if (bimap_indexes_k2v_at(map_b, map_s, nk, nv, key_index, false) != missing_value)
        return false;
    bimap_indexes_set_k2v(map_b, map_s, nk, nv, key_index, ordinal, false);
    bimap_indexes_set_v2k(map_b, map_s, vs, nk, nv, ordinal, key_index, false);
    return true;
}

void static_bimap_copy(T)(const(ushort)[] source, T[] destination) pure
{
    assert(source.length == destination.length);
    foreach (i, value; source)
        destination[i] = cast(T)value;
}

void static_bimap_concat(T)(const(ushort)[] first, const(ushort)[] second, T[] first_destination, T[] second_destination) pure
{
    static_bimap_copy(first, first_destination);
    static_bimap_copy(second, second_destination);
}

void static_bimap_build_indexes(ushort[] k2v, ushort[] v2k, const(ushort)[] key_sources, const(ushort)[] source_to_key, const(ushort)[] value_sources = null, const(ushort)[] source_to_value = null) pure
{
    if (value_sources !is null)
    {
        assert(k2v.length == key_sources.length && v2k.length == value_sources.length && source_to_key.length == source_to_value.length);
        foreach (i, source; key_sources)
            k2v[i] = source_to_value[source];
        foreach (i, source; value_sources)
            v2k[i] = source_to_key[source];
        return;
    }

    assert(k2v.length == key_sources.length && v2k.length == key_sources.length);
    ushort ordinal;
    foreach (source, key_index; source_to_key)
    {
        if (key_sources[key_index] != source)
            continue;
        k2v[key_index] = ordinal;
        v2k[ordinal++] = key_index;
    }
    assert(ordinal == key_sources.length);
}

size_t static_bimap_string_length(const(char)[] value) pure
{
    return value.length == 0 ? 0 : 2 + value.length + (value.length & 1);
}

package(urt) ushort static_bimap_write_string(char[] strings, ref size_t used, const(char)[] value) pure
{
    if (value.length == 0)
        return 0;
    ushort offset = cast(ushort)(used + 2);
    version (LittleEndian)
    {
        strings[used] = cast(char)(value.length & 0xFF);
        strings[used + 1] = cast(char)(value.length >> 8);
    }
    else
    {
        strings[used] = cast(char)(value.length >> 8);
        strings[used + 1] = cast(char)(value.length & 0xFF);
    }
    strings[offset .. offset + value.length] = value[];
    used += static_bimap_string_length(value);
    return offset;
}


unittest
{
    static assert(BiMap!(uint, uint).map_b.offsetof - BiMap!(uint, uint).nk.offsetof ==
        align_up(ushort.sizeof * 3, (ubyte*).alignof));
    static if (size_t.sizeof == 4)
        static assert(BiMap!(string).sizeof == 20);
    else
        static assert(BiMap!(string).sizeof == 32);
    enum static_bimap_test_entries = [
        KVP!(uint, uint)(20, 2),
        KVP!(uint, uint)(10, 2),
        KVP!(uint, uint)(20, 1),
        KVP!(uint, uint)(10, 1),
    ];
    enum static_bimap_wide_entries = () {
        KVP!(ushort, ushort)[256] result;
        foreach (ushort i; 0 .. result.length)
            result[i] = KVP!(ushort, ushort)(i, cast(ushort)(255 - i));
        return result;
    }();
    enum static_bimap_wide_key_entries = () {
        KVP!(ushort, ushort)[256] result;
        foreach (ushort i; 0 .. result.length)
            result[i] = KVP!(ushort, ushort)(i, cast(ushort)0);
        return result;
    }();
    enum static_bimap_wide_value_entries = () {
        KVP!(ushort, ushort)[256] result;
        foreach (ushort i; 0 .. result.length)
            result[i] = KVP!(ushort, ushort)(cast(ushort)0, i);
        return result;
    }();
    enum static_bimap_string_entries = [
        KVP!(string, string)("beta", "two"),
        KVP!(string, string)("alpha", "two"),
        KVP!(string, string)("beta", "one"),
        KVP!(string, string)("", ""),
    ];
    enum static_bimap_string_key_entries = [
        KVP!(string, uint)("beta", 2),
        KVP!(string, uint)("alpha", 1),
    ];
    enum static_bimap_string_value_entries = [
        KVP!(uint, string)(2, "beta"),
        KVP!(uint, string)(1, "alpha"),
    ];
    enum static_bimap_ordinal_entries = [ 20u, 10u, 30u ];
    enum static_bimap_string_ordinal_entries = [ "beta", "alpha" ];

    static assert(() {
        BiMap!(ushort, ushort) map;
        foreach (ushort i; 0 .. 256)
        {
            if (map.insert(i, cast(ushort)(255 - i)) != BiMapResult.inserted)
                return false;
        }
        ushort value;
        ushort key;
        return map.find(255, value) && value == 0 && map.reverse(255, key) && key == 0;
    }());

    static assert(bimap_indexes_allocation_for(0) == 0);
    static assert(bimap_indexes_allocation_for(1) == 4);
    static assert(bimap_indexes_allocation_for(5) == 8);
    static assert(bimap_indexes_allocation_for(32768) == 32768);
    static assert(bimap_indexes_allocation_for(32769) == 0);

    {
        alias generated = StaticBiMap!static_bimap_test_entries;
        alias map = generated.map;
        static assert(map.key_count == 2);
        static assert(map.value_count == 2);
        static assert(map.vs == map.key_count);
        static assert(generated.k2decl == [ 1, 0 ]);
        static assert(!__traits(compiles, map.insert(30, 3)));
        static assert(!__traits(compiles, map.clear()));
        uint value;
        assert(map.find(10, value) && value == 2);
        assert(map.find(20, value) && value == 2);
        uint key;
        assert(map.reverse(1, key) && key == 20);
        assert(map.reverse(2, key) && key == 20);
    }

    {
        alias map = StaticBiMap!static_bimap_wide_entries.map;
        static assert(map.key_count == 256);
        static assert(map.value_count == 256);
        ushort value;
        assert(map.find(255, value) && value == 0);
        ushort key;
        assert(map.reverse(255, key) && key == 0);
    }

    {
        alias map = StaticBiMap!static_bimap_wide_key_entries.map;
        static assert(map.key_count == 256);
        static assert(map.value_count == 1);
        ushort value;
        assert(map.find(255, value) && value == 0);
        ushort key;
        assert(map.reverse(0, key) && key == 0);
    }

    {
        alias map = StaticBiMap!static_bimap_wide_value_entries.map;
        static assert(map.key_count == 1);
        static assert(map.value_count == 256);
        ushort value;
        assert(map.find(0, value) && value == 0);
        ushort key;
        assert(map.reverse(255, key) && key == 0);
    }

    {
        alias map = StaticBiMap!static_bimap_string_entries.map;
        static assert(map.key_count == 3);
        static assert(map.value_count == 3);
        const(char)[] value;
        assert(map.find("", value) && value == "");
        assert(map.find("alpha", value) && value == "two");
        assert(map.find("beta", value) && value == "two");
        const(char)[] key;
        assert(map.reverse("one", key) && key == "beta");
        assert(map.reverse("two", key) && key == "beta");
    }

    {
        alias map = StaticBiMap!static_bimap_string_key_entries.map;
        uint value;
        assert(map.find("alpha", value) && value == 1);
        const(char)[] key;
        assert(map.reverse(2, key) && key == "beta");
    }

    {
        alias map = StaticBiMap!static_bimap_string_value_entries.map;
        const(char)[] value;
        assert(map.find(1, value) && value == "alpha");
        uint key;
        assert(map.reverse("beta", key) && key == 2);
    }

    {
        alias generated = StaticBiMap!static_bimap_ordinal_entries;
        alias map = generated.map;
        static assert(generated.k2decl == [ 1, 0, 2 ]);
        ushort ordinal;
        assert(map.find(10, ordinal) && ordinal == 1);
        assert(map.find(20, ordinal) && ordinal == 0);
        uint key;
        assert(map.reverse(2, key) && key == 30);
    }

    {
        alias map = StaticBiMap!static_bimap_string_ordinal_entries.map;
        ushort ordinal;
        assert(map.find("alpha", ordinal) && ordinal == 1);
        const(char)[] key;
        assert(map.reverse(0, key) && key == "beta");
    }

    {
        char[5] alpha = "alpha";
        char[4] beta = "beta";
        char[3] one = "one";
        char[3] two = "two";
        KVP!(const(char)[], const(char)[])[4] entries;
        entries[0].key = beta[];
        entries[0].value = two[];
        entries[1].key = alpha[];
        entries[1].value = two[];
        entries[2].key = beta[];
        entries[2].value = one[];
        entries[3].key = alpha[];
        entries[3].value = one[];
        ushort[4] sources;
        auto map = synthesise_bimap(entries[], sources[]);
        static assert(!__traits(compiles, map.clear()));
        static assert(!__traits(compiles, map.insert("gamma", "three")));
        assert(map.map_b + map.vs == map.map_b + map.key_count);
        alpha[0] = 'z';
        beta[0] = 'z';
        one[0] = 'z';
        two[0] = 'z';
        const(char)[] value;
        assert(map.find("alpha", value) && value == "two");
        assert(map.find("beta", value) && value == "two");
        const(char)[] key;
        assert(map.reverse("one", key) && key == "beta");
        assert(map.reverse("two", key) && key == "beta");
        release_synthesised_bimap(map);
    }

    {
        uint[4] entries = [ 20, 10, 20, 30 ];
        auto map = synthesise_bimap(entries[]);
        assert(map.key_count == 3 && map.value_count == 3);
        ushort ordinal;
        assert(map.find(20, ordinal) && ordinal == 0);
        assert(map.find(10, ordinal) && ordinal == 1);
        assert(map.find(30, ordinal) && ordinal == 2);
        uint key;
        assert(map.reverse(0, key) && key == 20);
        assert(map.reverse(1, key) && key == 10);
        assert(map.reverse(2, key) && key == 30);
        release_synthesised_bimap(map);
    }

    {
        KVP!(string, uint)[3] entries = [ KVP!(string, uint)("zeta", 1), KVP!(string, uint)("alpha", 1), KVP!(string, uint)("beta", 2) ];
        auto map = synthesise_bimap!true(entries[]);
        assert(map.key_count == 3 && map.value_count == 2);
        uint value;
        assert(map.find("alpha", value) && value == 1);
        const(char)[] key;
        assert(map.reverse(1, key) && key == "zeta");
        release_synthesised_bimap(map);
    }

    {
        ushort[256] entries;
        foreach (ushort i; 0 .. entries.length)
            entries[i] = cast(ushort)(255 - i);
        auto map = synthesise_bimap(entries[]);
        assert(map.map_s + map.vs == map.map_s + map.key_count);
        ushort ordinal;
        assert(map.find(255, ordinal) && ordinal == 0);
        ushort key;
        assert(map.reverse(255, key) && key == 0);
        release_synthesised_bimap(map);
    }

    {
        BiMap!(string, string) map;
        assert(map.insert("beta", "two") == BiMapResult.inserted);
        assert(map.insert("alpha", "two") == BiMapResult.inserted);
        assert(map.insert("beta", "one") == BiMapResult.inserted);
        assert(map.insert("", "") == BiMapResult.inserted);
        assert(map.k_slen == 14);
        assert(map.v_slen == 12);
        const(char)[] value;
        assert(map.find("", value) && value == "");
        assert(map.find("alpha", value) && value == "two");
        assert(map.find("beta", value) && value == "two");
        const(char)[] key;
        assert(map.reverse("one", key) && key == "beta");
        assert(map.reverse("two", key) && key == "beta");
    }

    {
        BiMap!(string, string, false, false) map;
        assert(map.insert("beta", "two") == BiMapResult.inserted);
        assert(map.insert("alpha", "one") == BiMapResult.inserted);
        const(char)[] value;
        assert(map.find("alpha", value) && value == "one");
        assert(map.find("beta", value) && value == "two");
    }

    {
        BiMap!(uint, string, false, false) map;
        assert(map.insert(2, "beta") == BiMapResult.inserted);
        assert(map.insert(1, "a\0pha") == BiMapResult.inserted);
        const(char)[] value;
        assert(map.find(1, value) && value == "a\0pha");
        assert(map.find(2, value) && value == "beta");
    }

    {
        BiMap!(string, void, true, true) map;
        ushort ordinal;
        bool acknowledged;
        assert(map.introduce("beta", ordinal, acknowledged) == BiMapResult.inserted);
        assert(ordinal == 0 && !acknowledged);
        assert(map.adopt("alpha", 3) == BiMapResult.inserted);
        assert(map.vs == 4 && map.map_b + map.vs == map.map_b + 4);
        assert(map.find("alpha", ordinal) && ordinal == 3);
        const(char)[] key;
        assert(map.reverse(3, key) && key == "alpha");
    }

    {
        BiMap!(uint, uint) map;
        assert(map.insert(20, 2) == BiMapResult.inserted);
        assert(map.insert(10, 2) == BiMapResult.inserted);
        uint value;
        assert(map.find(10, value) && value == 2);
        assert(map.find(20, value) && value == 2);
        uint key;
        assert(map.reverse(2, key) && key == 20);

        assert(map.insert(20, 1) == BiMapResult.inserted);
        assert(map.find(20, value) && value == 2);
        assert(map.reverse(1, key) && key == 20);
        assert(map.insert(10, 1) == BiMapResult.existing);
        assert(map.find(10, value) && value == 2);
        assert(map.reverse(1, key) && key == 20);
        assert(map.key_count == 2);
        assert(map.value_count == 2);
    }

    {
        static assert(BiMap!(uint, uint, false, false).sizeof < BiMap!(uint, uint).sizeof);
        BiMap!(uint, uint, false, false) map;
        assert(map.insert(20, 2) == BiMapResult.inserted);
        assert(map.insert(10, 2) == BiMapResult.inserted);
        assert(map.insert(20, 1) == BiMapResult.existing);
        uint value;
        assert(map.find(10, value) && value == 2);
        assert(map.find(20, value) && value == 2);
        assert(map.key_count == 2);
        assert(map.value_count == 2);
    }

    {
        BiMap!(uint, uint, true, true) map;
        assert(map.insert(1000, 0) == BiMapResult.inserted);
        assert(map.acknowledge(1000, 0));
        foreach (i; 1 .. 128)
            assert(map.insert(1000, i) == BiMapResult.inserted);
        uint value;
        bool acknowledged;
        assert(map.find(1000, value, acknowledged));
        assert(value == 0 && acknowledged);

        foreach (i; 0 .. 255)
            assert(map.insert(999 - i, 0) == BiMapResult.inserted);
        assert(map.find(1000, value, acknowledged));
        assert(value == 0 && acknowledged);
        uint key;
        assert(map.reverse(0, key) && key == 1000);
        assert(map.vs == 256 && map.map_s + map.vs == map.map_s + 256);
    }

    {
        BiMap!(uint, void, true, true) map;
        static assert(__traits(compiles, map.acknowledge(10, 1)));
        ushort ordinal;
        bool acknowledged;
        assert(map.introduce(40, ordinal, acknowledged) == BiMapResult.inserted);
        assert(ordinal == 0 && !acknowledged);
        assert(map.introduce(10, ordinal, acknowledged) == BiMapResult.inserted);
        assert(ordinal == 1 && !acknowledged);
        assert(map.acknowledge(10, 1));
        assert(map.find(10, ordinal, acknowledged));
        assert(ordinal == 1 && acknowledged);

        assert(map.adopt(30, 0) == BiMapResult.inserted);
        assert(map.find(30, ordinal) && ordinal == 0);
        uint key;
        assert(map.reverse(0, key) && key == 40);

        assert(map.adopt(10, 3) == BiMapResult.inserted);
        assert(map.find(10, ordinal) && ordinal == 1);
        assert(!map.reverse(2, key));
        assert(map.reverse(3, key) && key == 10);

        assert(map.adopt(5, 127) == BiMapResult.inserted);
        assert(!map.reverse(126, key));
        assert(map.reverse(127, key) && key == 5);

        foreach (i; 0 .. 252)
            assert(map.adopt(1000 + i, 0) == BiMapResult.inserted);
        assert(!map.reverse(126, key));
        assert(map.reverse(127, key) && key == 5);
        assert(map.find(10, ordinal, acknowledged));
        assert(ordinal == 1 && acknowledged);

        map.clear();
        assert(map.empty);
        assert(map.key_count == 0 && map.value_count == 0);
    }

    {
        BiMap!(uint, void) map;
        static assert(!__traits(compiles, map.acknowledge(10, 1)));
    }

    {
        uint first;
        uint second;
        BiMap!(uint*, void) map;
        ushort ordinal;
        bool acknowledged;
        assert(map.introduce(&first, ordinal, acknowledged) == BiMapResult.inserted);
        assert(map.introduce(&second, ordinal, acknowledged) == BiMapResult.inserted);
        uint* key;
        assert(map.reverse(0, key) && key is &first);
        assert(map.reverse(1, key) && key is &second);
    }
}
