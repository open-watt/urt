module urt.meta.nullable;

import urt.string.format : formatValue, FormatArg;
import urt.traits;


template Nullable(T)
    if (is(T == class) || is(T == U[], U) || is(T == U*, U))
{
    struct Nullable
    {
        enum T null_value = null;
        T value = null_value;

        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value !is null_value;

        bool opEquals(typeof(null)) const
            => value is null;
        bool opEquals(T v) const
            => value == v;

        void opAssign(U)(U v)
            if (is(U : T))
        {
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value is null)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is_boolean!T)
{
    struct Nullable
    {
        enum ubyte null_value = 0xFF;
        private ubyte _value = null_value;

        this(typeof(null))
        {
            _value = null_value;
        }
        this(T v)
        {
            _value = v;
        }

        bool value() const
            => _value == 1;

        bool opCast(T : bool)() const
            => _value != null_value;

        bool opEquals(typeof(null)) const
            => _value == null_value;
        bool opEquals(T v) const
            => _value == cast(ubyte)v;

        void opAssign(typeof(null))
        {
            _value = null_value;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            assert(v != null_value);
            _value = cast(ubyte)v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value == null_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is_some_int!T)
{
    struct Nullable
    {
        enum T null_value = is_signed_int!T ? T.min : T.max;
        T value = null_value;

        this(typeof(null))
        {
            value = null_value;
        }
        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value != null_value;

        bool opEquals(typeof(null)) const
            => value == null_value;
        bool opEquals(T v) const
            => value != null_value && value == v;

        void opAssign(typeof(null))
        {
            value = null_value;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            assert(v != null_value);
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value == null_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is_some_float!T)
{
    struct Nullable
    {
        enum T null_value = T.nan;
        T value = null_value;

        this(typeof(null))
        {
            value = null_value;
        }
        this(T v)
        {
            value = v;
        }

        bool opCast(T : bool)() const
            => value !is null_value;

        bool opEquals(typeof(null)) const
            => value is null_value;
        bool opEquals(T v) const
            => value == v; // because nan doesn't compare with anything

        void opAssign(typeof(null))
        {
            value = null_value;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            value = v;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (value is null_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is(T == struct))
{
    import urt.lifetime : moveEmplace;

    struct Nullable
    {
        T value = void;
        bool is_value = false;

        this(typeof(null))
        {
            is_value = false;
        }
        this(T v)
        {
            moveEmplace(v, value);
            is_value = true;
        }

        ~this()
        {
            if (is_value)
                value.destroy();
        }

        bool opCast(T : bool)() const
            => is_value;

        bool opEquals(typeof(null)) const
            => !is_value;
        bool opEquals(T v) const
            => is_value && value == v;

        void opAssign(typeof(null))
        {
            if (is_value)
                value.destroy();
            is_value = false;
        }
        void opAssign(U)(U v)
            if (is(U : T))
        {
            if (!is_value)
                moveEmplace(v, value);
            else
                value = v;
            is_value = true;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (!is_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}

template Nullable(T)
    if (is(T == enum))
{
    struct Nullable
    {
        T value;
        bool is_value;

        this(typeof(null))
        {
            is_value = false;
        }
        this(T v)
        {
            value = v;
            is_value = true;
        }

        bool opCast(T : bool)() const
            => is_value;

        bool opEquals(typeof(null)) const
            => !is_value;
        bool opEquals(T v) const
            => is_value && value == v;

        void opAssign(typeof(null))
        {
            is_value = false;
        }
        void opAssign(T v)
        {
            value = v;
            is_value = true;
        }

        ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const nothrow @nogc
        {
            if (!is_value)
                return formatValue(null, buffer, format, formatArgs);
            else
                return formatValue(value, buffer, format, formatArgs);
        }
    }
}


unittest
{
    import urt.mem : alloc, free;
    import urt.string.format : format;

    static struct S { int x; }

    Nullable!S s;
    assert(!s);
    s = S(42);
    assert(s);
    assert(s.value.x == 42);
    s = null;
    assert(!s);

    static class Base
    {
        override ptrdiff_t toString(char[] buffer) const nothrow @nogc
            => formatValue("base", buffer);
    }

    static class Derived : Base
    {
        override ptrdiff_t toString(char[] buffer) const nothrow @nogc
            => formatValue("derived", buffer);
    }

    static class Inherited : Base {}

    static class WrongContract
    {
        static int dyn_cast(T)(WrongContract source) nothrow @nogc
            => 0;
    }
    static class WrongDerived : WrongContract {}

    static assert(!__traits(compiles, _d_cast!(Derived, Base)(cast(Base)null)));
    static assert(!__traits(compiles, _d_cast!(Error, Throwable)(cast(Throwable)null)));
    static assert(!__traits(compiles, _d_cast!(WrongDerived, WrongContract)(cast(WrongContract)null)));

    Derived value = alloc!Derived();
    assert(value);
    scope(exit) free(value);

    assert(_d_cast!(Derived, Derived)(value) is cast(void*)value);
    assert(_d_cast!(Base, Derived)(value) is cast(void*)value);
    assert(_d_cast!(const(Base), const(Derived))(value) is cast(void*)value);
    assert(_d_cast!(Base, Derived)(null) is null);

    char[32] buffer;
    Nullable!Base nullable;
    assert(format(buffer, "{0}", nullable) == "null");
    nullable = value;
    assert(format(buffer, "{0}", nullable) == "derived");
    assert(format(buffer, "{0}", value) == "derived");
    nullable = null;
    assert(format(buffer, "{0}", nullable) == "null");

    Inherited inherited = alloc!Inherited();
    assert(inherited);
    scope(exit) free(inherited);
    assert(format(buffer, "{0}", inherited) == "base");

    static class Root
    {
        alias dyn_cast = checked_cast;

        static T checked_cast(T)(Root source) nothrow @nogc
            if (is(typeof(T.cast_key) == uint))
        {
            return cast(T)source.query(T.cast_key);
        }

        static const(T) checked_cast(T)(const(Root) source) nothrow @nogc
            if (is(typeof(T.cast_key) == uint))
        {
            return cast(const(T))source.query(T.cast_key);
        }

        protected inout(void)* query(uint key) inout nothrow @nogc
            => null;
    }

    static class Leaf : Root
    {
        enum uint cast_key = 1;

        protected override inout(void)* query(uint key) inout nothrow @nogc
            => key == cast_key ? cast(inout(void)*)this : null;
    }

    static class Sibling : Root {}

    Leaf leaf = alloc!Leaf();
    assert(leaf);
    scope(exit) free(leaf);
    Root root = leaf;
    assert(Root.dyn_cast!Leaf(root) is leaf);
    assert(cast(Leaf)root is leaf);
    assert(_d_cast!(Root, Leaf)(leaf) is cast(void*)leaf);
    const(Root) const_root = root;
    assert(cast(const(Leaf))const_root is leaf);
    static assert(is(typeof(Root.dyn_cast!Leaf(const_root)) == const(Leaf)));

    Sibling sibling = alloc!Sibling();
    assert(sibling);
    scope(exit) free(sibling);
    root = sibling;
    assert(cast(Leaf)root is null);
    root = null;
    assert(cast(Leaf)root is null);
    static assert(!__traits(compiles, _d_cast!(Sibling, Root)(root)));
}
