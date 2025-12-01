module urt.internal.lifetime;

import urt.lifetime : forward;

/+
emplaceRef is a package function for druntime internal use. It works like
emplace, but takes its argument by ref (as opposed to "by pointer").
This makes it easier to use, easier to be safe, and faster in a non-inline
build.
Furthermore, emplaceRef optionally takes a type parameter, which specifies
the type we want to build. This helps to build qualified objects on mutable
buffer, without breaking the type system with unsafe casts.
+/
void emplaceRef(T, UT, Args...)(ref UT chunk, auto ref Args args)
{
    static if (args.length == 0)
    {
        static assert(is(typeof({static T i;})),
            "Cannot emplace a " ~ T.stringof ~ " because " ~ T.stringof ~
            ".this() is annotated with @disable.");
        static if (is(T == class)) static assert(!__traits(isAbstractClass, T),
            T.stringof ~ " is abstract and it can't be emplaced");
        emplaceInitializer(chunk);
    }
    else static if (
        !is(T == struct) && Args.length == 1 /* primitives, enums, arrays */
        ||
        Args.length == 1 && is(typeof({T t = forward!(args[0]);})) /* conversions */
        ||
        is(typeof(T(forward!args))) /* general constructors */)
    {
        static struct S
        {
            T payload;
            this()(auto ref Args args)
            {
                static if (__traits(compiles, payload = forward!args))
                    payload = forward!args;
                else
                    payload = T(forward!args);
            }
        }
        if (__ctfe)
        {
            static if (__traits(compiles, chunk = T(forward!args)))
                chunk = T(forward!args);
            else static if (args.length == 1 && __traits(compiles, chunk = forward!(args[0])))
                chunk = forward!(args[0]);
            else assert(0, "CTFE emplace doesn't support "
                ~ T.stringof ~ " from " ~ Args.stringof);
        }
        else
        {
            S* p = () @trusted { return cast(S*) &chunk; }();
            static if (UT.sizeof > 0)
                emplaceInitializer(*p);
            p.__ctor(forward!args);
        }
    }
    else static if (is(typeof(chunk.__ctor(forward!args))))
    {
        // This catches the rare case of local types that keep a frame pointer
        emplaceInitializer(chunk);
        chunk.__ctor(forward!args);
    }
    else
    {
        //We can't emplace. Try to diagnose a disabled postblit.
        static assert(!(Args.length == 1 && is(Args[0] : T)),
            "Cannot emplace a " ~ T.stringof ~ " because " ~ T.stringof ~
            ".this(this) is annotated with @disable.");

        //We can't emplace.
        static assert(false,
            T.stringof ~ " cannot be emplaced from " ~ Args[].stringof ~ ".");
    }
}

// ditto
static import urt.traits;
void emplaceRef(UT, Args...)(ref UT chunk, auto ref Args args)
    if (is(UT == urt.traits.Unqual!UT))
{
    emplaceRef!(UT, UT)(chunk, forward!args);
}

/+
Emplaces T.init.
In contrast to `emplaceRef(chunk)`, there are no checks for disabled default
constructors etc.
+/
void emplaceInitializer(T)(scope ref T chunk) nothrow pure @trusted
    if (!is(T == const) && !is(T == immutable) && !is(T == inout))
{
    import core.internal.traits : hasElaborateAssign;

    static if (__traits(isZeroInit, T))
    {
        import urt.mem : memset;
        memset(cast(void*) &chunk, 0, T.sizeof);
    }
    else static if (__traits(isScalar, T) ||
                    T.sizeof <= 16 && !hasElaborateAssign!T && __traits(compiles, (){ T chunk; chunk = T.init; }))
    {
        chunk = T.init;
    }
    else static if (__traits(isStaticArray, T))
    {
        // For static arrays there is no initializer symbol created. Instead, we emplace elements one-by-one.
        foreach (i; 0 .. T.length)
        {
            emplaceInitializer(chunk[i]);
        }
    }
    else
    {
        import urt.mem : memcpy;
        const initializer = __traits(initSymbol, T);
        memcpy(cast(void*)&chunk, initializer.ptr, initializer.length);
    }
}
