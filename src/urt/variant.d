module urt.variant;

import urt.algorithm : compare;
import urt.array;
import urt.conv;
import urt.kvp;
import urt.lifetime;
import urt.map;
import urt.mem.allocator;
import urt.si.quantity;
import urt.si.unit : ScaledUnit;
import urt.traits;

nothrow @nogc:


enum ValidUserType(T) = (is(T == struct) || is(T == class)) &&
                        is(Unqual!T == T) &&
                        !is(T == Variant) &&
                        !is(T == VariantKVP) &&
                        !is(T == Array!U, U) &&
                        !is(T : const(char)[]) &&
                        !is(T == Quantity!(T, U), T, alias U);


alias VariantKVP = KVP!(const(char)[], Variant);


struct Variant
{
nothrow @nogc:
    this(this) @disable;
    this(ref Variant rh)
    {
        if (rh.type == Type.Map || rh.type == Type.Array)
        {
            Array!Variant arr = rh.nodeArray;
            takeNodeArray(arr);
            flags = rh.flags;
        }
        else
        {
            assert((rh.flags & Flags.NeedDestruction) == 0);
            __pack = rh.__pack;
        }
    }

    version (EnableMoveSemantics) {
    this(Variant rh)
    {
        value.ul = rh.value.ul;
        count = rh.count;
        alloc = rh.alloc;
        flags = rh.flags;

        rh.value.ul = 0;
        rh.count = 0;
        rh.flags = Flags.Null;
    }
    }

    this(typeof(null))
    {
    }

    this(bool b)
    {
        flags = b ? Flags.True : Flags.False;
    }

    this(I)(I i)
        if (is_some_int!I)
    {
        static if (is_signed_int!I)
            value.l = i;
        else
            value.ul = i;

        static if (is(I == ubyte) || is(I == ushort))
            flags = cast(Flags)(Flags.NumberUint | Flags.IntFlag | Flags.Int64Flag);
        else static if (is(I == byte) || is(I == short) || is(I == int))
        {
            flags = Flags.NumberInt;
            if (i >= 0)
                flags |= Flags.UintFlag | Flags.Uint64Flag;
        }
        else static if (is(I == uint))
        {
            flags = Flags.NumberUint;
            if (i <= int.max)
                flags |= Flags.IntFlag;
        }
        else static if (is(I == long))
        {
            flags = Flags.NumberInt64;
            if (i >= 0)
            {
                flags |= Flags.Uint64Flag;
                if (i <= int.max)
                    flags |= Flags.IntFlag | Flags.UintFlag;
                else if (i <= uint.max)
                    flags |= Flags.UintFlag;
            }
            else if (i >= int.min)
                flags |= Flags.IntFlag;
        }
        else static if (is(I == ulong))
        {
            flags = Flags.NumberUint64;
            if (i <= int.max)
                flags |= Flags.IntFlag | Flags.UintFlag | Flags.Int64Flag;
            else if (i <= uint.max)
                flags |= Flags.UintFlag | Flags.Int64Flag;
            else if (i <= long.max)
                flags |= Flags.Int64Flag;
        }
    }

    this(F)(F f)
        if (is_some_float!F)
    {
        static if (is(F == float))
            flags = Flags.NumberFloat;
        else
            flags = Flags.NumberDouble;
        value.d = f;
    }

    this(E)(E e)
        if (is(E == enum))
    {
        static if (is(E T == enum))
        {
            this(T(e));
            // TODO: do we keep a record of the enum keys for stringification?
        }
    }

    this(U, ScaledUnit _U)(Quantity!(U, _U) q)
    {
        this(q.value);
        if (q.unit.pack)
        {
            flags |= Flags.IsQuantity;
            count = q.unit.pack;
        }
    }

    this(const(char)[] s) // TODO: (S)(S s)
//        if (is(S : const(char)[]))
    {
        if (s.length < embed.length)
        {
            flags = Flags.ShortString;
            embed[0 .. s.length] = s[];
            embed[$-1] = cast(ubyte)s.length;
            return;
        }
        flags = Flags.String;
        value.s = s.ptr;
        count = cast(uint)s.length;
    }

    this(Variant[] a)
    {
        flags = Flags.Array;
        nodeArray = a[];
    }
    this(T)(T[] a)
        if (!is(T == Variant) && !is(T == VariantKVP) && !is(T : dchar))
    {
        flags = Flags.Array;
        nodeArray.reserve(a.length);
        foreach (ref i; a)
            nodeArray.emplaceBack(i);
    }

    this(Array!Variant a)
    {
        takeNodeArray(a);
        flags = Flags.Array;
    }

    this(VariantKVP[] map...)
    {
        flags = Flags.Map;
        nodeArray.reserve(map.length * 2);
        foreach (ref VariantKVP kvp; map)
        {
            nodeArray.emplaceBack(kvp.key);
            move(kvp.value, nodeArray.pushBack());
        }
    }

    this(K, V)(ref Map!(K, V) map)
    {
        flags = Flags.Map;
        nodeArray.reserve(map.length * 2);
        foreach (ref k, ref v; map)
        {
            nodeArray.emplaceBack(k);
            move(v, nodeArray.pushBack());
        }
    }

    // TODO: should we have a formal ENUM type which can store the key/values?

    this(T)(auto ref T thing)
        if (ValidUserType!T)
    {
        alias dummy = MakeTypeDetails!T;

        flags = Flags.User;
        static if (is(T == class))
        {
            count = UserTypeId!T;
            alloc = type_detail_index!T();
            ptr = cast(void*)thing;
        }
        else static if (EmbedUserType!T)
        {
            alloc = UserTypeId!T;
            flags |= Flags.Embedded;

            if (TypeDetailsFor!T.destroy) // TODO: we should check the same condition that determined if there is a destruct function...
                flags |= Flags.NeedDestruction;

            emplace(cast(T*)embed.ptr, forward!thing);
        }
        else
        {
            count = UserTypeId!T;
            alloc = type_detail_index!T();

            if (TypeDetailsFor!T.destroy) // TODO: we should check the same condition that determined if there is a destruct function...
                flags |= Flags.NeedDestruction;

            ptr = defaultAllocator().alloc(T.sizeof, T.alignof).ptr;
            emplace(cast(T*)ptr, forward!thing);
        }
    }

    ~this()
    {
        destroy!false();
    }

    void opAssign(ref Variant value)
    {
        if (&this is &value)
            return; // TODO: should this be an assert instead of a graceful handler?
        destroy!false();
        new(this) Variant(value);
    }
    version (EnableMoveSemantics) {
    void opAssign(Variant value)
    {
        destroy!false();
        new(this) Variant(__rvalue(value)); // TODO: value.move
    }
    }

    // TODO: since this is a catch-all, the error messages will be a bit shit
    //       maybe we can find a way to constrain it to valid inputs?
    void opAssign(T)(auto ref T value)
    {
        this = Variant(value);
    }

    // TODO: do we want Variant to support +=, ~=, etc...?
    //       or maybe rather, we SHOULDN'T allow variant to support [$]/length()/etc...

    // support indexing for arrays and maps...
    alias opDollar = length;

    ref inout(Variant) opIndex(size_t i) inout pure
    {
        assert(isArray());
        assert(i < count);
        return value.n[i];
    }

    ref const(Variant) opIndex(const(char)[] member) const pure
    {
        const(Variant)* m = getMember(member);
        assert(m !is null);
        return *m;
    }
    ref Variant opIndex(const(char)[] member)
    {
        Variant* m = getMember(member);
        if (m)
            return *m;
        nodeArray.emplaceBack(member);
        return nodeArray.pushBack();
    }

    bool opEquals(T)(ref const Variant rhs) const pure
    {
        return opCmp(rhs) == 0;
    }
    bool opEquals(T)(auto ref const T rhs) const
    {
        // TODO: handle short-cut array/map comparisons?
        static if (is(T == typeof(null)))
            return type == Type.Null || ((type == Type.String || type == Type.Array || type == Type.Map) && empty());
        else static if (is(T == bool))
        {
            if (!isBool)
                return false; // do non-zero numbers evaluate true? what about non-zero strings? etc...
            return asBool == rhs;
        }
        else static if (is_some_int!T || is_some_float!T)
        {
            if (!isNumber)
                return false;
            static if (is_some_int!T) if (!canFitInt!T)
                return false;
            if (isQuantity)
                return asQuantity!double() == Quantity!T(rhs);
            return as!T == rhs;
        }
        else static if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
        {
            if (!isNumber)
                return false;
            return asQuantity!double() == rhs;
        }
        else static if (is(T E == enum))
        {
            // TODO: should we also do string key comparisons?
            return opEquals(cast(E)rhs);
        }
        else static if (is(T : const(char)[]))
            return isString && asString() == rhs[];
        else static if (ValidUserType!T)
            return asUser!T == rhs;
        else
            static assert(false, "TODO: variant comparison with '", T.stringof, "' not supported");
    }

    int opCmp(ref const Variant rhs) const pure
    {
        const(Variant)* a, b;
        bool invert = false;
        if (this.type <= rhs.type)
            a = &this, b = &rhs;
        else
            a = &rhs, b = &this, invert = true;

        int r = 0;
        final switch (a.type)
        {
            case Type.Null:
                if (b.type == Type.Null)
                    return 0;
                else if ((b.type == Type.String || b.type == Type.Array || b.type == Type.Map) && b.empty())
                    return 0;
                r = -1; // sort null before other things...
                break;

            case Type.True:
            case Type.False:
                // if both sides are bool
                if (b.type <= Type.False)
                {
                    r = a.asBool - b.asBool;
                    break;
                }
                // TODO: maybe we don't want to accept bool/number comparison?
                goto case; // we will compare bools with numbers...

            case Type.Number:
                if (b.type <= Type.Number)
                {
                    static double asDoubleWithBool(ref const Variant v)
                        => v.isBool() ? double(v.asBool()) : v.asDouble();

                    if (a.isQuantity || b.isQuantity)
                    {
                        // we can't compare different units
                        uint aunit = a.isQuantity ? (a.count & 0xFFFFFF) : 0;
                        uint bunit = b.isQuantity ? (b.count & 0xFFFFFF) : 0;
                        if (aunit != bunit)
                        {
                            r = aunit - bunit;
                            break;
                        }

                        // matching units, but we'll only do quantity comparison if there is some scaling
                        ubyte ascale = a.isQuantity ? (a.count >> 24) : 0;
                        ubyte bscale = b.isQuantity ? (b.count >> 24) : 0;
                        if (ascale || bscale)
                        {
                            Quantity!double aq = a.isQuantity ? a.asQuantity!double() : Quantity!double(asDoubleWithBool(*a));
                            Quantity!double bq = b.isQuantity ? b.asQuantity!double() : Quantity!double(asDoubleWithBool(*b));
                            r = aq.opCmp(bq);
                            break;
                        }
                    }

                    if (a.flags & Flags.FloatFlag || b.flags & Flags.FloatFlag)
                    {
                        // float comparison
                        // TODO: determine if float/bool comparison seems right? is: -1 < false < 0.9 < true < 1.1?
                        double af = asDoubleWithBool(*a);
                        double bf = asDoubleWithBool(*b);
                        r = af < bf ? -1 : af > bf ? 1 : 0;
                        break;
                    }

                    // TODO: this could be further optimised by comparing the value range flags...
                    if ((a.flags & (Flags.Int64Flag | Flags.IsBool)) == 0)
                    {
                        ulong aul = a.asUlong();
                        if ((b.flags & (Flags.Int64Flag | Flags.IsBool)) == 0)
                        {
                            ulong bul = b.asUlong();
                            r = aul < bul ? -1 : aul > bul ? 1 : 0;
                        }
                        else
                            r = 1; // a is in ulong range, rhs is not; a is larger...
                        break;
                    }
                    if ((b.flags & (Flags.Int64Flag | Flags.IsBool)) == 0)
                    {
                        r = -1; // b is in ulong range, lhs is not; b is larger...
                        break;
                    }

                    long al = a.isBool() ? a.asBool() : a.asLong();
                    long bl = b.isBool() ? b.asBool() : b.asLong();
                    r = al < bl ? -1 : al > bl ? 1 : 0;
                }
                else
                    r = -1; // sort numbers before other things...
                break;

            case Type.String:
                if (b.type != Type.String)
                {
                    r = -1;
                    break;
                }
                r = compare(a.asString(), b.asString());
                break;

            case Type.Array:
                if (b.type != Type.Array)
                {
                    r = -1;
                    break;
                }
                r = compare(a.asArray()[], b.asArray()[]);
                break;

            case Type.Map:
                if (b.type != Type.Map)
                {
                    r = -1;
                    break;
                }
                assert(false, "TODO");
                break;

            case Type.User:
                uint at = a.userType;
                uint bt = b.userType;
                if (at != bt)
                {
                    r = at < bt ? -1 : at > bt ? 1 : 0;
                    break;
                }
                alias PureHack = ref TypeDetails function(uint index) pure nothrow @nogc;
                if (flags & Flags.Embedded)
                {
                    ref const TypeDetails td = (cast(PureHack)&find_type_details)(alloc);
                    r = td.cmp(a.embed.ptr, b.embed.ptr, 0);
                }
                else
                {
                    ref const TypeDetails td = (cast(PureHack)&get_type_details)(alloc);
                    r = td.cmp(a.ptr, b.ptr, 0);
                }
                break;
        }
        return invert ? -r : r;
    }
    int opCmp(T)(auto ref const T rhs) const
    {
        // TODO: handle short-cut string, array, map comparisons
        static if (is(T == typeof(null)))
            return type == Type.Null || ((type == Type.String || type == Type.Array || type == Type.Map) && empty()) ? 0 : 1;
        else static if (is(T : const(char)[]))
            return isString() ? compare(asString(), rhs) : (type < Type.String ? -1 : 1);
        static if (ValidUserType!T)
            return compare(asUser!T, rhs);
        else
            return opCmp(Variant(rhs));
    }

    bool opBinary(string op)(ref const Variant rhs) const pure
        if (op == "is")
    {
        // compare that Variant's are identical, not just equivalent!
        assert(false, "TODO");
    }
    bool opBinary(string op, T)(auto ref const T rhs) const
        if (op == "is")
    {
        // TODO: handle short-cut array/map comparisons?
        static if (is(T == typeof(null)))
            return type == Type.Null || ((type == Type.String || type == Type.Array || type == Type.Map) && empty());
        else static if (is(T : const(char)[]))
            return isString && asString().ptr is rhs.ptr && length() == rhs.length;
        else static if (ValidUserType!T)
            return asUser!T is rhs;
        else
            return opBinary!"is"(Variant(rhs));
    }

    bool isNull() const pure
        => flags == Flags.Null;
    bool isFalse() const pure
        => flags == Flags.False;
    bool isTrue() const pure
        => flags == Flags.True;
    bool isBool() const pure
        => (flags & Flags.IsBool) != 0;
    bool isNumber() const pure
        => (flags & Flags.IsNumber) != 0;
    bool isInt() const pure
        => (flags & Flags.IntFlag) != 0;
    bool isUint() const pure
        => (flags & Flags.UintFlag) != 0;
    bool isLong() const pure
        => (flags & Flags.Int64Flag) != 0;
    bool isUlong() const pure
        => (flags & Flags.Uint64Flag) != 0;
    bool isFloat() const pure
        => (flags & Flags.FloatFlag) != 0;
    bool isDouble() const pure
        => (flags & Flags.DoubleFlag) != 0;
    bool isQuantity() const pure
        => (flags & Flags.IsQuantity) != 0;
    bool isString() const pure
        => (flags & Flags.IsString) != 0;
    bool isArray() const pure
        => flags == Flags.Array;
    bool isObject() const pure
        => flags == Flags.Map;
    bool isUserType() const pure
        => (flags & Flags.TypeMask) == Type.User;
    bool isUser(T)() const pure
        if (ValidUserType!(Unqual!T))
    {
        alias U = Unqual!T;
        if ((flags & Flags.TypeMask) != Type.User)
            return false;
        static if (EmbedUserType!U)
            return alloc == UserTypeId!U;
        else
        {
            if (count == UserTypeId!U)
                return true;
            static if (is(T == class))
            {
                immutable(TypeDetails)* td = &get_type_details(alloc);
                while (td.super_type_id)
                {
                    if (td.super_type_id == UserTypeId!U)
                        return true;
                    td = &find_type_details(td.super_type_id);
                }
            }
            return false;
        }
    }

    bool canFitInt(I)() const pure
        if (is_some_int!I)
    {
        if (!isNumber || isFloat)
            return false;
        static if (is(I == ulong))
            return isUlong;
        else static if (is(I == long))
            return isLong;
        else static if (is(I == uint))
            return isUint;
        else static if (is(I == int))
            return isInt;
        else static if (is_signed_int!I)
        {
            if (!isInt)
                return false;
            int i = asInt();
            return i >= I.min && i <= I.max;
        }
        else
            return isUlong && asUlong <= I.max;
    }

    bool asBool() const pure @property
    {
        if (isNull)
            return false;
        assert(isBool());
        return flags == Flags.True;
    }

    int asInt() const pure @property
    {
        if (isNull)
            return 0;
        assert(isInt(), "Value out of range for int");
        return cast(int)value.l;
    }
    uint asUint() const pure @property
    {
        if (isNull)
            return 0;
        assert(isUint(), "Value out of range for uint");
        return cast(uint)value.ul;
    }
    long asLong() const pure @property
    {
        if (isNull)
            return 0;
        assert(isLong(), "Value out of range for long");
        return value.l;
    }
    ulong asUlong() const pure @property
    {
        if (isNull)
            return 0;
        assert(isUlong(), "Value out of range for ulong");
        return value.ul;
    }

    double asDouble() const pure @property
    {
        if (isNull)
            return 0;
        assert(isNumber);
        if ((flags & Flags.DoubleFlag) != 0)
            return value.d;
        if ((flags & Flags.UintFlag) != 0)
            return cast(double)cast(uint)value.ul;
        if ((flags & Flags.IntFlag) != 0)
            return cast(double)cast(int)cast(long)value.ul;
        if ((flags & Flags.Uint64Flag) != 0)
            return cast(double)value.ul;
        return cast(double)cast(long)value.ul;
    }

    float asFloat() const pure @property
    {
        if (isNull)
            return 0;
        assert(isNumber);
        if ((flags & Flags.DoubleFlag) != 0)
            return value.d;
        if ((flags & Flags.UintFlag) != 0)
            return cast(float)cast(uint)value.ul;
        if ((flags & Flags.IntFlag) != 0)
            return cast(float)cast(int)cast(long)value.ul;
        if ((flags & Flags.Uint64Flag) != 0)
            return cast(float)value.ul;
        return cast(float)cast(long)value.ul;
    }

    Quantity!T asQuantity(T = double)() const pure @property
        if (is_some_float!T || isSomeInt!T)
    {
        if (isNull)
            return Quantity!T(0);
        assert(isNumber);
        Quantity!T r;
        r.value = as!T;
        if (isQuantity)
            r.unit.pack = count;
        return r;
    }

    const(char)[] asString() const pure
    {
        if (isNull)
            return null;
        assert(isString);
        if (flags & Flags.Embedded)
            return embed[0 .. embed[$-1]];
        return value.s[0 .. count];
    }

    ref const(Array!Variant) asArray() const pure
    {
        assert(isArray());
        return nodeArray;
    }

    ref Array!Variant asArray() pure
    {
        if (flags == Flags.Null)
            flags = Flags.Array;
        else
            assert(isArray());
        return nodeArray;
    }

    ref inout(T) asUser(T)() inout pure
        if (ValidUserType!(Unqual!T) && UserTypeReturnByRef!T)
    {
        alias U = Unqual!T;
        if (!isUser!U)
            assert(false, "Variant is not a " ~ U.stringof);
        static assert(!is(U == class), "Should be impossible?");
        static if (EmbedUserType!U)
            return *cast(inout(T)*)embed.ptr;
        else
            return *cast(inout(T)*)ptr;
    }
    inout(T) asUser(T)() inout pure
        if (ValidUserType!(Unqual!T) && !UserTypeReturnByRef!T)
    {
        alias U = Unqual!T;
        if (!isUser!U)
            assert(false, "Variant is not a " ~ U.stringof);
        static if (is(U == class))
            return cast(inout(T))ptr;
        else static if (EmbedUserType!U)
        {
            // make a copy on the stack and return by value
            U r = void;
            TypeDetailsFor!U.copy_emplace(embed.ptr, &r, false);
            return r;
        }
        else
            static assert(false, "Should be impossible?");
    }

    auto as(T)() inout pure
        if (!ValidUserType!(Unqual!T) || !UserTypeReturnByRef!T)
    {
        static if (is_some_int!T)
        {
            static if (is_signed_int!T)
            {
                static if (is(T == long))
                    return asLong();
                else
                {
                    int i = asInt();
                    static if (!is(T == int))
                        assert(i >= T.min && i <= T.max, "Value out of range for " ~ T.stringof);
                    return cast(T)i;
                }
            }
            else
            {
                static if (is(T == ulong))
                    return asUlong();
                else
                {
                    uint u = asInt();
                    static if (!is(T == uint))
                        assert(u <= T.max, "Value out of range for " ~ T.stringof);
                    return cast(T)u;
                }
            }
        }
        else static if (is_some_float!T)
        {
            static if (is(T == float))
                return asFloat();
            else
                return asDouble();
        }
        else static if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
        {
            return asQuantity!U();
        }
        else static if (is(T : const(char)[]))
        {
            static if (is(T == struct)) // for String/MutableString/etc
                return T(asString); // TODO: error? shouldn't this NRVO?!
            else
                return asString;
        }
        else static if (ValidUserType!(Unqual!T))
            return asUser!T;
        else
            static assert(false, "TODO!");
    }
    ref inout(T) as(T)() inout pure
        if (ValidUserType!(Unqual!T) && UserTypeReturnByRef!T)
        => asUser!T;

    size_t length() const pure
    {
        if (flags == Flags.Null)
            return 0;
        else if (isString())
            return (flags & Flags.Embedded) ? embed[$-1] : count;
        else if (isArray())
            return count;
        else
            assert(false, "Variant does not have `length`");
    }

    bool empty() const pure
        => isObject() ? count == 0 : length() == 0;

    inout(Variant)* getMember(const(char)[] member) inout pure
    {
        assert(isObject());
        for (uint i = 0; i < count; i += 2)
        {
            if (value.n[i].asString() == member)
                return value.n + i + 1;
        }
        return null;
    }

    // TODO: this seems to interfere with UFCS a lot...
//    ref inout(Variant) opDispatch(string member)() inout pure
//    {
//        inout(Variant)* m = getMember(member);
//        assert(m !is null);
//        return *m;
//    }

    int opApply(int delegate(const(char)[] k, ref Variant v) @nogc dg)
    {
        assert(isObject());
        int r = 0;
        try
        {
            for (uint i = 0; i < count; i += 2)
            {
                r = dg(value.n[i].asString(), value.n[i + 1]);
                if (r != 0)
                    break;
            }
        }
        catch(Exception e)
        {
            assert(false, "Exception in loop body!");
        }
        return r;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        final switch (type)
        {
            case Variant.Type.Null:  // assume type == 0
            case Variant.Type.True:  // assume type == 1
            case Variant.Type.False: // assume type == 2
                __gshared immutable char** values = [ "null", "true", "false" ];
                size_t len = 4 + (type >> 1);
                if (!buffer.ptr)
                    return len;
                if (buffer.length < len)
                    return -1;
                buffer[0 .. len] = values[type][0 .. len];
                return len;

            case Variant.Type.Number:
                if (isQuantity())
                    return asQuantity().toString(buffer);//, format, formatArgs);

                if (isDouble())
                    return asDouble().format_float(buffer);

                // TODO: parse args?
                assert(!format, "TODO");

                if (flags & Flags.Uint64Flag)
                    return asUlong().format_uint(buffer);
                return asLong().format_int(buffer);

            case Variant.Type.String:
                const char[] s = asString();
                if (buffer.ptr)
                {
                    // TODO: should we write out quotes?
                    // a string of a number won't be distinguishable from a number without quotes...
                    if (buffer.length < s.length)
                        return -1;
                    buffer[0 .. s.length] = s[];
                }
                return s.length;

            case Variant.Type.Map:
            case Variant.Type.Array:
                import urt.format.json;

                // should we just format this like JSON or something?
                return write_json(this, buffer);

            case Variant.Type.User:
                if (flags & Flags.Embedded)
                    return find_type_details(alloc).stringify(cast(void*)embed.ptr, buffer, true);
                else
                    return g_type_details[alloc].stringify(cast(void*)ptr, buffer, true);
        }
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.string.ascii : is_numeric;

        if (s.empty || s == "null")
        {
            this = null;
            return s.length;
        }
        if (s == "true")
        {
            this = true;
            return 4;
        }
        if (s == "false")
        {
            this = false;
            return 5;
        }

        if (s[0] == '"')
        {
            for (size_t i = 1; i < s.length; ++i)
            {
                if (s[i] == '"')
                {
                    assert(i == s.length - 1, "String must end with a quote");
                    this = s[1 .. i];
                    return i + 1;
                }
            }
            assert(false, "String has no closing quote");
        }

        if (s[0].is_numeric)
        {
            size_t taken;
            ScaledUnit unit;
            ulong div;
            long i = s.parse_int_with_decimal(div, &taken, 10);
            if (taken < s.length)
            {
                size_t t2 = unit.fromString(s[taken .. $]);
                if (t2 > 0)
                    taken += t2;
            }
            if (taken == s.length)
            {
                if (div != 1)
                    this = double(i) / div;
                else
                    this = i;
                if (unit.pack)
                {
                    flags |= Flags.IsQuantity;
                    count = unit.pack;
                }
                return taken;
            }
        }

        align(64) void[256] buffer = void;
        this = null; // clear the object since we'll probably use the embed buffer...
        foreach (ushort i; 0 .. g_num_type_details)
        {
            ref immutable TypeDetails td = get_type_details(i);
            debug assert(td.alignment <= 64 && td.size <= buffer.sizeof, "Buffer is too small for user type!");
            ptrdiff_t taken = td.stringify(td.embedded ? embed.ptr : buffer.ptr, cast(char[])s, false);
            if (taken > 0)
            {
                flags = Flags.User;
                if (td.destroy)
                    flags |= Flags.NeedDestruction;
                if (td.embedded)
                {
                    flags |= Flags.Embedded;
                    alloc = cast(ushort)td.type_id;
                }
                else
                {
                    void* object = defaultAllocator().alloc(td.size, td.alignment).ptr;
                    td.copy_emplace(buffer.ptr, object, true);
                    if (td.destroy)
                        td.destroy(buffer.ptr);
                    ptr = object;
                    count = td.type_id;
                    alloc = i;
                }
                return taken;
            }
        }

        // what is this?
        assert(false, "Can't parse variant from string");
    }


package:
    union Value
    {
        long l;
        ulong ul;
        double d;
//        int i;   // maybe implement these if the platform has no native 64bit int support
//        uint u;
//        float f; // if there is no hardware double support, then we should use this...

        const(char)* s;

        struct {
            // HACK: on 32bit, `n` must be placed immediately before `count`
            static if (size_t.sizeof == 4)
                uint __placeholder;
            Variant* n;
        }
    }

    union {
        ulong[2] __pack; // for efficient copying...

        struct {
            union {
                Value value;
                void* ptr;
            }
            uint count;
            ushort alloc;
            Flags flags;
        }

        enum EmbedSize = 14;
        char[EmbedSize] embed; // a buffer for locally embedded data
    }

    Type type() const pure
        => cast(Type)(flags & Flags.TypeMask);

    uint userType() const pure
    {
        if (flags & Flags.Embedded)
            return alloc; // short id
        return count; // long id
    }
    inout(void)* userPtr() inout pure
    {
        if (flags & Flags.Embedded)
            return embed.ptr;
        return ptr;
    }

    ref inout(Array!Variant) nodeArray() @property inout pure
        => *cast(inout(Array!Variant)*)&value.n;
    void takeNodeArray(ref Array!Variant arr)
    {
        value.n = arr[].ptr;
        count = cast(uint)arr.length;
        emplace(&arr);
    }

    void destroy(bool reset = true)()
    {
        if (flags & Flags.NeedDestruction)
            doDestroy();

        static if (reset)
            __pack[] = 0;
    }

    private void doDestroy()
    {
        Type t = type();
        if ((t == Type.Map || t == Type.Array) && value.n)
            nodeArray.destroy!false();
        else if (t == Type.User)
        {
            ref const TypeDetails td = (flags & Flags.Embedded) ? find_type_details(alloc) : g_type_details[alloc];
            if (td.destroy)
                td.destroy(userPtr);
            if (!(flags & Flags.Embedded))
                defaultAllocator().free(ptr[0..td.size]);
        }
    }

    enum Type : ushort
    {
        Null        = 0,
        True        = 1,
        False       = 2,
        Number      = 3,
        String      = 4,
        Array       = 5,
        Map         = 6,
        User        = 7
    }

    enum Flags : ushort
    {
        Null            = cast(Flags)Type.Null,
        False           = cast(Flags)Type.False  | Flags.IsBool,
        True            = cast(Flags)Type.True   | Flags.IsBool,
        NumberInt       = cast(Flags)Type.Number | Flags.IsNumber | Flags.IntFlag  | Flags.Int64Flag,
        NumberUint      = cast(Flags)Type.Number | Flags.IsNumber | Flags.UintFlag | Flags.Uint64Flag | Flags.Int64Flag,
        NumberInt64     = cast(Flags)Type.Number | Flags.IsNumber | Flags.Int64Flag,
        NumberUint64    = cast(Flags)Type.Number | Flags.IsNumber | Flags.Uint64Flag,
        NumberFloat     = cast(Flags)Type.Number | Flags.IsNumber | Flags.FloatFlag | Flags.DoubleFlag,
        NumberDouble    = cast(Flags)Type.Number | Flags.IsNumber | Flags.DoubleFlag,
        String          = cast(Flags)Type.String | Flags.IsString,
        ShortString     = cast(Flags)Type.String | Flags.IsString | Flags.Embedded,
        Array           = cast(Flags)Type.Array | Flags.NeedDestruction,
        Map             = cast(Flags)Type.Map | Flags.NeedDestruction,
        User            = cast(Flags)Type.User,

        IsBool          = 1 << (TypeBits + 0),
        IsNumber        = 1 << (TypeBits + 1),
        IsString        = 1 << (TypeBits + 2),
        IntFlag         = 1 << (TypeBits + 3),
        UintFlag        = 1 << (TypeBits + 4),
        Int64Flag       = 1 << (TypeBits + 5),
        Uint64Flag      = 1 << (TypeBits + 6),
        FloatFlag       = 1 << (TypeBits + 7),
        DoubleFlag      = 1 << (TypeBits + 8),
        IsQuantity      = 1 << (TypeBits + 9),
        Embedded        = 1 << (TypeBits + 10),
        NeedDestruction = 1 << (TypeBits + 11),
//        CopyFlag        = 1 << (TypeBits + 12), // maybe we want to know if a thing is a copy, or a reference to an external one?

        TypeMask        = (1 << TypeBits) - 1,
        TypeBits        = 3
    }
}

unittest
{
    import urt.inet;
    import urt.si.quantity : Metres;

    // fabricate some variants
    Variant v;
    v.asArray ~= Variant(42);
    v.asArray ~= Variant(101.1);
    v.asArray ~= Variant(VariantKVP("wow", Variant(true)), VariantKVP("bogus", Variant(false)));
    v.asArray ~= Variant(IPAddrLit!"127.0.0.1");
    v.asArray ~= Variant(Metres(10));

    assert(v.length == 5);
    assert(v[0].asInt == 42);
    assert(v[1].asDouble == 101.1);
    assert(v[2]["wow"].isTrue);
    assert(v[2]["bogus"].asBool == false);
    assert(v[3].asUser!IPAddr == IPAddrLit!"127.0.0.1");
    assert(v[4].asQuantity == Metres(10));
}


private:

import urt.hash : fnv1a;

static assert(Variant.sizeof == 16);
static assert(Variant.Type.max <= Variant.Flags.TypeMask);

template UserTypeId(T)
{
    enum uint Hash = fnv1a(cast(const(ubyte)[])T.stringof); // maybe this isn't a good enough hash?
    static if (!EmbedUserType!T)
        enum uint UserTypeId = Hash;
    else
        enum ushort UserTypeId = cast(ushort)Hash ^ (Hash >> 16);
}
enum bool EmbedUserType(T) = is(T == struct) && T.sizeof <= Variant.embed.sizeof - 2 && T.alignof <= Variant.alignof;
enum bool UserTypeReturnByRef(T) = is(T == struct);

ptrdiff_t newline(char[] buffer, ref ptrdiff_t offset, int level)
{
    if (offset + level >= buffer.length)
        return false;
    buffer[offset++] = '\n';
    buffer[offset .. offset + level] = ' ';
    offset += level;
    return true;
}

template MakeTypeDetails(T)
{
    static assert(is(Unqual!T == T), "Only instantiate for mutable types");

    // this is a hack which populates an array of user type details when the program starts
    // TODO: we can probably NOT do this for class types, and just use RTTI instead...
    shared static this()
    {
        assert(g_num_type_details < g_type_details.length, "Too many user types!");
        g_type_details[g_num_type_details++] = TypeDetailsFor!T;
    }

    alias MakeTypeDetails = void;
}

ushort type_detail_index(T)() pure
    if (ValidUserType!T)
{
    ushort count = (cast(ushort function() pure nothrow @nogc)&num_type_details)();
    foreach (ushort i; 0 .. count)
        if (get_type_details(i).type_id == UserTypeId!T)
            return i;
    assert(false, "Why wasn't the type registered?");
}

struct TypeDetails
{
    uint type_id;
    uint super_type_id;
    ushort size;
    ubyte alignment;
    bool embedded;
    void function(void* src, void* dst, bool move) nothrow @nogc copy_emplace;
    void function(void* val) nothrow @nogc destroy;
    ptrdiff_t function(void* val, char[] buffer, bool format) nothrow @nogc stringify;
    int function(const void* a, const void* b, int type) pure nothrow @nogc cmp;
}
__gshared TypeDetails[8] g_type_details;
__gshared ushort g_num_type_details = 0;

typeof(g_type_details)* type_details() => &g_type_details;
ushort num_type_details() => g_num_type_details;

ref immutable(TypeDetails) find_type_details(uint type_id) pure
{
    auto tds = (cast(immutable(typeof(g_type_details)*) function() pure nothrow @nogc)&type_details)();
    ushort count = (cast(ushort function() pure nothrow @nogc)&num_type_details)();
    foreach (i, ref td; (*tds)[0 .. count])
    {
        if (td.type_id == type_id)
            return td;
    }
    assert(false, "TypeDetails not found!");
}
ref immutable(TypeDetails) get_type_details(uint index) pure
{
    auto tds = (cast(immutable(typeof(g_type_details)*) function() pure nothrow @nogc)&type_details)();
    debug assert(index < g_num_type_details);
    return (*tds)[index];
}

public template TypeDetailsFor(T)
    if (is(Unqual!T == T) && (is(T == struct) || is(T == class)))
{
    static if (is(T == class) && is(T S == super))
    {
        alias Super = Unqual!S;
        static if (!is(Super == Object))
        {
            alias dummy = MakeTypeDetails!Super;
            enum SuperTypeId = UserTypeId!Super;
        }
        else
            enum ushort SuperTypeId = 0;
    }
    else
        enum ushort SuperTypeId = 0;

    static if (!is(T == class))
    {
        static void move_emplace_impl(void* src, void* dst, bool move) nothrow @nogc
        {
            if (move)
                moveEmplace(*cast(T*)src, *cast(T*)dst);
            else
            {
                static if (__traits(compiles, { *cast(T*)dst = *cast(const T*)src; }))
                    *cast(T*)dst = *cast(const T*)src;
                else
                    assert(false, "Can't copy " ~ T.stringof);
            }
        }
        enum move_emplace = &move_emplace_impl;
    }
    else
        enum move_emplace = null;

    static if (!is(T == class) && is(typeof(destroy!(false, T))))
    {
        static void destroy_impl(void* val) nothrow @nogc
        {
            destroy!false(*cast(T*)val);
        }
        enum destroy_fun = &destroy_impl;
    }
    else
        enum destroy_fun = null;

    static ptrdiff_t stringify(void* val, char[] buffer, bool format) nothrow @nogc
    {
        import urt.string.format : toString;
        if (format)
        {
            static if (is(typeof(toString!T)))
                return toString(*cast(const T*)val, buffer);
            else
                return -1;
        }
        else
        {
            static if (is(typeof(parse!T)))
                return buffer.parse!T(*cast(T*)val);
            else
                return -1;
        }
    }

    int compare(const void* pa, const void* pb, int type) pure nothrow @nogc
    {
        ref const T a = *cast(const T*)pa;
        ref const T b = *cast(const T*)pb;
        switch (type)
        {
            case 0:
                static if (is(T == class) || is(T == U*, U) || is(T == V[], V))
                {
                    if (pa is pb)
                        return 0;
                }
                static if (__traits(compiles, { a.opCmp(b); }))
                    return a.opCmp(b);
                else static if (__traits(compiles, { b.opCmp(a); }))
                    return -b.opCmp(a);
                else
                {
                    static if (is(T == class))
                    {
                        ptrdiff_t r = cast(ptrdiff_t)pa - cast(ptrdiff_t)pb;
                        return r < 0 ? -1 : r > 0 ? 1 : 0;
                    }
                    else
                        return a < b ? -1 : a > b ? 1 : 0;
                }
            case 1:
                static if (is(T == class) || is(T == U*, U) || is(T == V[], V))
                {
                    if (pa is pb)
                        return 1;
                }
                static if (__traits(compiles, { a.opEquals(b); }))
                    return a.opEquals(b);
                else static if (__traits(compiles, { b.opEquals(a); }))
                    return b.opEquals(a);
                else static if (!is(T == class) && !is(T == U*, U) && !is(T == V[], V))
                    return a == b ? 1 : 0;
                else
                    return 0;
            case 2:
                return pa is pb ? 1 : 0;
            default:
                assert(false);
        }
    }

    enum TypeDetailsFor = TypeDetails(UserTypeId!T, SuperTypeId, T.sizeof, T.alignof, EmbedUserType!T, move_emplace, destroy_fun, &stringify, &compare);
}
