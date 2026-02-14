module urt.meta;

import urt.traits : is_callable, is_enum, EnumType, Unqual;

nothrow @nogc:

alias Alias(alias a) = a;
alias Alias(T) = T;

alias AliasSeq(TList...) = TList;

template Iota(ptrdiff_t start, ptrdiff_t end)
{
    static assert(start <= end, "start must be less than or equal to end");
    alias Iota = AliasSeq!();
    static foreach (i; start .. end)
        Iota = AliasSeq!(Iota, i);
}
alias Iota(size_t end) = Iota!(0, end);

auto make_delegate(Fun)(Fun fun) pure
    if (is_callable!Fun)
{
    import urt.traits : is_function_pointer, ReturnType, Parameters;

    static if (is_function_pointer!fun)
    {
        struct Hack
        {
            static if (is(Fun : R function(Args) pure nothrow @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure nothrow @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) pure nothrow @nogc)&this)(args);
            else static if (is(Fun : R function(Args) nothrow @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) nothrow @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) nothrow @nogc)&this)(args);
            else static if (is(Fun : R function(Args) pure @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) pure @nogc)&this)(args);
            else static if (is(Fun : R function(Args) pure nothrow, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure nothrow => (cast(ReturnType!Fun function(Parameters!Fun args) pure nothrow)&this)(args);
            else static if (is(Fun : R function(Args) pure, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) pure => (cast(ReturnType!Fun function(Parameters!Fun args) pure)&this)(args);
            else static if (is(Fun : R function(Args) nothrow, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) nothrow => (cast(ReturnType!Fun function(Parameters!Fun args) nothrow)&this)(args);
            else static if (is(Fun : R function(Args) @nogc, R, Args...))
                ReturnType!Fun call(Parameters!Fun args) @nogc => (cast(ReturnType!Fun function(Parameters!Fun args) @nogc)&this)(args);
            else static if (is(Fun : R function(Args), R, Args...))
                ReturnType!Fun call(Parameters!Fun args) => (cast(ReturnType!Fun function(Parameters!Fun args))&this)(args);
        }
        Hack hack;
        auto dg = &hack.call;
        dg.ptr = fun;
        return dg;
    }
    else static if (is(Fun == delegate))
        return fun;
    else
        static assert(false, "Unsupported type for make_delegate");
}

ulong bit_mask(size_t bits) pure
{
    return (1UL << bits) - 1;
}

template bit_mask(size_t bits, bool signed = false)
{
    static assert(bits <= 64, "bit_mask only supports up to 64 bits");
    static if (bits == 64)
        enum IntForWidth!(64, signed) bit_mask = ~0UL;
    else
        enum IntForWidth!(bits, signed) bit_mask = (1UL << bits) - 1;
}

template IntForWidth(size_t bits, bool signed = false)
{
    static if (bits <= 8 && !signed)
        alias IntForWidth = ubyte;
    else static if (bits <= 8 && signed)
        alias IntForWidth = byte;
    else static if (bits <= 16 && !signed)
        alias IntForWidth = ushort;
    else static if (bits <= 16 && signed)
        alias IntForWidth = short;
    else static if (bits <= 32 && !signed)
        alias IntForWidth = uint;
    else static if (bits <= 32 && signed)
        alias IntForWidth = int;
    else static if (bits <= 64 && !signed)
        alias IntForWidth = ulong;
    else static if (bits <= 64 && signed)
        alias IntForWidth = long;
}

alias TypeForOp(string op, U) = typeof(mixin(op ~ "U()"));
alias TypeForOp(string op, A, B) = typeof(mixin("A()" ~ op ~ "B()"));

template STATIC_MAP(alias fun, args...)
{
    alias STATIC_MAP = AliasSeq!();
    static foreach (arg; args)
        STATIC_MAP = AliasSeq!(STATIC_MAP, fun!arg);
}

template STATIC_UNROLL(alias array)
{
    static if (is(typeof(array) : T[], T))
    {
        alias STATIC_UNROLL = AliasSeq!();
        static foreach (i; 0 .. array.length)
            STATIC_UNROLL = AliasSeq!(STATIC_UNROLL, array[i]);
    }
    else
        static assert(false, "STATIC_UNROLL requires an array");
}

template STATIC_FILTER(alias filter, args...)
{
    alias STATIC_FILTER = AliasSeq!();
    static foreach (arg; args)
        static if (filter!arg)
            STATIC_FILTER = AliasSeq!(STATIC_FILTER, arg);
}

template static_index_of(args...)
    if (args.length >= 1)
{
    enum static_index_of = {
        static foreach (idx, arg; args[1 .. $])
            static if (is_same!(args[0], arg))
                // `if (__ctfe)` is redundant here but avoids the "Unreachable code" warning.
                if (__ctfe) return idx;
        return -1;
    }();
}

template INTERLEAVE_SEPARATOR(alias sep, Args...)
{
    alias INTERLEAVE_SEPARATOR = AliasSeq!();
    static foreach (i, A; Args)
        static if (i > 0)
            INTERLEAVE_SEPARATOR = AliasSeq!(INTERLEAVE_SEPARATOR, sep, A);
        else
            INTERLEAVE_SEPARATOR = AliasSeq!(A);
}



private:

template is_same(alias a, alias b)
{
    static if (!is(typeof(&a && &b)) // at least one is an rvalue
               && __traits(compiles, { enum is_same = a == b; })) // c-t comparable
        enum is_same = a == b;
    else
        enum is_same = __traits(isSame, a, b);
}
// TODO: remove after https://github.com/dlang/dmd/pull/11320 and https://issues.dlang.org/show_bug.cgi?id=21889 are fixed
template is_same(A, B)
{
    enum is_same = is(A == B);
}
