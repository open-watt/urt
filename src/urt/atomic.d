module urt.atomic;

// TODO: these are all just stubs, but we can flesh it out as we need it...

nothrow @nogc @safe:

enum MemoryOrder
{
    relaxed = 0,
    consume = 1,
    acquire = 2,
    release = 3,
    acq_rel = 4,
    seq_cst = 5,
    seq = 5,
}


// DMD lowers to these names...
alias atomicLoad = atomic_load;
alias atomicStore = atomic_store;
alias atomicOp = atomic_op;
alias atomicExchange = atomic_exchange;
alias atomicFetchAdd = atomic_fetch_add;
alias atomicFetchSub = atomic_fetch_sub;


T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(ref const T val) pure @trusted
{
    return val;
}

// Overload for shared
TailShared!T atomic_load(MemoryOrder ms = MemoryOrder.seq, T)(auto ref shared const T val) pure @trusted
{
    return *cast(TailShared!T*)&val;
}

void atomic_store(MemoryOrder ms = MemoryOrder.seq, T, V)(ref shared T val, V newval) pure @trusted
    if (__traits(compiles, { *cast(T*)&val = newval; }))
{
    *cast(T*)&val = newval;
}

TailShared!T atomic_op(string op, T, V1)(ref shared T val, V1 mod) pure @trusted
    if (__traits(compiles, mixin("*cast(T*)&val" ~ op ~ "mod")))
{
    auto ptr = cast(T*)&val;
    mixin("*ptr " ~ op ~ " mod;");
    return *cast(TailShared!T*)ptr;
}

bool cas(T, V1, V2)(shared(T)* here, V1 ifThis, V2 writeThis) pure @trusted
{
    auto ptr = cast(T*)here;
    if (*ptr == ifThis)
    {
        *ptr = writeThis;
        return true;
    }
    return false;
}

T atomic_exchange(MemoryOrder ms = MemoryOrder.seq, T, V)(shared(T)* here, V exchangeWith) pure @trusted
{
    auto ptr = cast(T*)here;
    T old = *ptr;
    *ptr = exchangeWith;
    return old;
}

T atomic_fetch_add(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
    if (__traits(isIntegral, T))
{
    auto ptr = cast(T*)&val;
    T old = *ptr;
    *ptr += mod;
    return old;
}

T atomic_fetch_sub(MemoryOrder ms = MemoryOrder.seq, T)(ref shared T val, T mod) pure @trusted
    if (__traits(isIntegral, T))
{
    auto ptr = cast(T*)&val;
    T old = *ptr;
    *ptr -= mod;
    return old;
}

/// Simplified TailShared — strips shared qualifier for noruntime builds.
template TailShared(U) if (!is(U == shared))
{
    alias TailShared = .TailShared!(shared U);
}

template TailShared(S) if (is(S == shared))
{
    static if (is(S U == shared U))
    {
        static if (is(S : U))
            alias TailShared = U;
        else
            alias TailShared = S;
    }
    else
        static assert(false);
}
