module urt.async;

import urt.fibre;
import urt.lifetime;
import urt.mem.allocator;
import urt.mem.freelist;
import urt.meta.tuple;
import urt.traits;

public import urt.fibre : yield, sleep, aborting, YieldResult;

nothrow @nogc:


Promise!(ReturnType!Fun)* async(alias Fun, size_t stack_size = default_stack_size, Args...)(auto ref Args args)
    if (is(typeof(&Fun) == R function(auto ref Args) nothrow @nogc, R))
{
    return async!stack_size(&Fun, forward!args);
}

// TODO: nice to rework this; maybe make stack_size a not-template-arg, and receive a function call/closure object which stores the args
Promise!(ReturnType!Fun)* async(size_t stack_size = default_stack_size, Fun, Args...)(Fun fun, auto ref Args args)
    if (is_some_function!Fun)
{
    alias Result = ReturnType!Fun;
    Promise!Result* r = cast(Promise!Result*)defaultAllocator().alloc(Promise!Result.sizeof, Promise!Result.alignof);

    // this shim is used as the entry-point for the async call
    // the function arguments must be copied to the fibre's stack:
    // 1 - we copy the args to this shim object in the calling stack
    // 2 - the shim becomes the entrypoint to the fibre
    // 3 - the shim's entrypoint copies the args from the shim object (calling stack) to the fibre stack
    // 4 - the shim then calls the async function with the args on the fibre stack
    struct Shim
    {
        Tuple!Args calling_args = void;
        Fun fn = void;
        Promise!Result* promise = void;

        static void entry(void* user_data) nothrow @nogc
        {
            Shim* this_ = cast(Shim*)user_data;

            ref Promise!Result r = *this_.promise;
            Tuple!Args args = this_.calling_args.move;
            static if (is(Result == void))
                this_.fn(args.expand);
            else
                r.value = this_.fn(args.expand);
        }
    }
    auto shim = Shim(Tuple!Args(forward!args), fun, r);

    // TODO: DMD bug causes palcement new to fail on x86! uncomment when the bug is fixed...
//    new(*r) Promise!Result(&shim.entry, &shim, stack_size);
    *r = Promise!Result(&shim.entry, &shim, stack_size);
    r.async.fibre.resume();
    return r;
}

void free_promise(T)(ref Promise!T* promise)
{
    assert(promise.state() != PromiseState.pending, "Promise still pending!");
    defaultAllocator().freeT(promise);
    promise = null;
}

void async_update()
{
    AsyncWait* wait = waiting;
    while (wait)
    {
        AsyncWait* t = wait;
        wait = wait.next;

        if (t.event)
        {
            t.event.update();
            if (!t.event.ready())
                continue;
        }
        t.call.fibre.resume();
    }
}


enum PromiseState
{
    pending,
    ready,
    failed
}

struct Promise(Result)
{
nothrow @nogc:

    // construct using `async()` functions...
    this() @disable;
    this(ref typeof(this)) @disable; // disable copy constructor
    this(typeof(this)) @disable; // disable move constructor

    // HACK: delete this when the placement new bug is fixed!
    void opAssign(typeof(this) rh)
    {
        this.async = rh.async;
        rh.async = null;
        static if (!is(Result == void))
            this.value = rh.value.move;
    }

    ~this()
    {
        if (async)
        {
            assert(async.fibre.is_finished());
            async.next = free_list;
            free_list = async;
        }
    }

    PromiseState state() const
    {
        if (async.fibre.was_aborted())
            return PromiseState.failed;
        else if (async.fibre.is_finished())
            return PromiseState.ready;
        else
            return PromiseState.pending;
    }

    bool finished() const
        => state() != PromiseState.pending;

    ref Result result()
    {
        assert(state() == PromiseState.ready, "Promise not fulfilled!");
        static if (!is(Result == void))
            return value;
    }

    void abort()
    {
        assert(state() == PromiseState.pending, "Promise already fulfilled!");
        async.fibre.abort();
    }

private:
    AsyncCall* async;
    static if (!is(Result == void))
        Result value;

    this(void function(void*) nothrow @nogc entry, void* user_data, size_t stack_size = default_stack_size)
    {
        if (free_list)
        {
            async = free_list;
            free_list = async.next;

            // TODO: if we end up with a pool of mixed stack sizes; maybe we want to find the smallest one that fits the requested stack...
            assert(async.fibre.stack_size >= stack_size, "Stack size too small!");
            async.fibre.reset();
        }
        else
            async = defaultAllocator().allocT!AsyncCall(stack_size);
        async.set_entry(entry, user_data);

        // TODO: HACK, this should be void-init, and then result emplaced at the assignment
        //       ...but palcement new doesn't work with default initialisation yet!
        static if (!is(Result == void))
            value = Result.init;
    }
}


unittest
{
    // Test simple case
    static int fun(int a, int b) nothrow @nogc
    {
        return a + b;
    }

    auto p = async!fun(1, 2);
    assert(p.state() == PromiseState.ready);
    assert(p.result() == 3);
    free_promise(p);
    p = async!fun(10, 20);
    assert(p.state() == PromiseState.ready);
    assert(p.result() == 30);
    free_promise(p);

    // Test with yielding
    __gshared int val = 0;
    static int fun_yield() nothrow @nogc
    {
        val = 1;
        yield();
        val = 2;
        yield();
        val = 3;
        return 4;
    }

    auto p_yield = async(&fun_yield);
    assert(p_yield.state() == PromiseState.pending);
    assert(val == 1);
    async_update();
    assert(p_yield.state() == PromiseState.pending);
    assert(val == 2);
    async_update();
    assert(p_yield.state() == PromiseState.ready);
    assert(val == 3);
    assert(p_yield.result() == 4);
    free_promise(p_yield);

    // aborting a pending promise runs the fibre out through its own abort path
    __gshared bool unwound = false;
    static int fun_abort() nothrow @nogc
    {
        val = 1;
        if (yield() == YieldResult.aborted)
        {
            unwound = true;
            return -1;
        }
        return 0;
    }

    auto p_abort = async(&fun_abort);
    assert(p_abort.state() == PromiseState.pending);
    assert(waiting !is null);
    p_abort.abort();
    assert(p_abort.state() == PromiseState.failed);
    assert(unwound);
    assert(waiting is null, "aborted fibre left a wait entry behind");
    free_promise(p_abort);
}


private:

import urt.util : InPlace, Default;

struct AsyncCall
{
    Fibre fibre = void;
    union {
        AsyncCall* next;
        void* user_data;
    }
    void function(void*) nothrow @nogc user_entry;

nothrow @nogc:
    this() @disable;
    this(ref typeof(this)) @disable; // disable copy constructor
    this(typeof(this)) @disable;     // disable move constructor

    void set_entry(void function(void*) nothrow @nogc entry, void* user_data)
    {
        this.user_entry = entry;
        this.user_data = user_data;
    }

    this(size_t stack_size)
    {
        new(fibre) Fibre(&this.entry, &do_yield, cast(void*)&this, stack_size);
    }

    static void entry(void* p)
    {
        AsyncCall* this_ = cast(AsyncCall*)p;
        this_.user_entry(this_.user_data);
    }
}

struct AsyncWait
{
nothrow @nogc:

    AsyncWait* next;
    AsyncCall* call;
    AwakenEvent event;

    void resume()
    {
        AsyncCall* call = this.call;

        if (waiting == &this)
            waiting = this.next;
        else
        {
            for (AsyncWait* t = waiting; t; t = t.next)
            {
                if (t.next == &this)
                {
                    t.next = this.next;
                    break;
                }
            }
        }
        waiting_pool.free(&this);

        call.fibre.resume();
    }
}


__gshared FreeList!AsyncWait waiting_pool;
__gshared AsyncWait* waiting;   // list of active yielded/waiting fibres
__gshared AsyncCall* free_list;  // free-list of AsyncCall objects

shared static ~this()
{
    assert(!waiting, "There are non-terminated fibres... unclean shutdown.");

    while (free_list)
    {
        AsyncCall* t = free_list;
        free_list = free_list.next;
        defaultAllocator().freeT(t);
    }
}

ResumeHandler do_yield(ref Fibre yielding, AwakenEvent awaken_event)
{
    AsyncWait* wait = waiting_pool.alloc();
    wait.call = cast(AsyncCall*)yielding.user_data;
    wait.event = awaken_event;
    wait.next = waiting;
    waiting = wait;

    return &wait.resume;
}
