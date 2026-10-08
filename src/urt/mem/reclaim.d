module urt.mem.reclaim;

import urt.sync.critical;
import urt.thread : is_main_thread;

nothrow @nogc:


// Cache-pressure protocol: subsystems holding reclaimable memory (freelists, caches)
// register a handler; on allocation failure the allocator walks handlers most-willing
// first. After each reclaim step it retries the allocation. A handler returning `more`
// is called again if the retry fails; `exhausted` advances to the next provider.
// Willingness reflects rebuild cost, not importance.
// Handlers must not block, must not allocate, and should free whole heap blocks
// (individual pages returned to an internal freelist don't help the heap).
// Handlers registered !thread_safe are only invoked from the main thread.

enum ReclaimResult : ubyte
{
    exhausted,
    more,
}

alias ReclaimHandler = ReclaimResult delegate(size_t bytes_needed) nothrow @nogc;
alias ReclaimFunction = ReclaimResult function(size_t bytes_needed) nothrow @nogc;
alias ReclaimRetry = bool function(void* context) nothrow @nogc;

bool register_reclaimer(ReclaimHandler handler, ubyte willingness, bool thread_safe)
{
    assert(handler.ptr !is null);
    return add_reclaimer(Reclaimer(handler.funcptr, handler.ptr, willingness, thread_safe));
}

bool register_reclaimer(ReclaimFunction handler, ubyte willingness, bool thread_safe)
    => add_reclaimer(Reclaimer(handler, null, willingness, thread_safe));

bool unregister_reclaimer(ReclaimHandler handler)
{
    assert(handler.ptr !is null);
    return remove_reclaimer(Reclaimer(handler.funcptr, handler.ptr, 0, false));
}

bool unregister_reclaimer(ReclaimFunction handler)
    => remove_reclaimer(Reclaimer(handler, null, 0, false));

// Reentry returns rather than recursing. A handler returning `more` must make progress
// before doing so.
void reclaim_memory(size_t bytes_needed, ReclaimRetry retry = null, void* retry_context = null)
{
    auto guard = _lock.acquire();

    if (_walking)
        return;
    _walking = true;
    scope (exit) _walking = false;

    bool main_thread = is_main_thread();
    foreach (ref r; _reclaimers[0 .. _num_reclaimers])
    {
        if (!r.thread_safe && !main_thread)
            continue;
        ReclaimResult result;
        do
        {
            result = r.reclaim(bytes_needed);
            if (retry && retry(retry_context))
                return;
        }
        while (result == ReclaimResult.more);
    }
}


private:

struct Reclaimer
{
nothrow @nogc:
    ReclaimFunction fn;
    void* context;
    ubyte willingness;
    bool thread_safe;

    ReclaimResult reclaim(size_t bytes_needed)
    {
        if (context !is null)
        {
            ReclaimHandler dg;
            dg.ptr = context;
            dg.funcptr = fn;
            return dg(bytes_needed);
        }
        return fn(bytes_needed);
    }

    bool matches(ref const Reclaimer other) const
        => fn is other.fn && context is other.context;
}

bool add_reclaimer(Reclaimer r)
{
    auto guard = _lock.acquire();

    if (_num_reclaimers == _reclaimers.length)
        return false;
    foreach (ref e; _reclaimers[0 .. _num_reclaimers])
    {
        if (e.matches(r))
            return false;
    }

    size_t i = _num_reclaimers;
    while (i > 0 && _reclaimers[i - 1].willingness < r.willingness)
    {
        _reclaimers[i] = _reclaimers[i - 1];
        --i;
    }
    _reclaimers[i] = r;
    ++_num_reclaimers;
    return true;
}

bool remove_reclaimer(Reclaimer r)
{
    auto guard = _lock.acquire();

    foreach (i; 0 .. _num_reclaimers)
    {
        if (_reclaimers[i].matches(r))
        {
            foreach (j; i .. _num_reclaimers - 1)
                _reclaimers[j] = _reclaimers[j + 1];
            --_num_reclaimers;
            return true;
        }
    }
    return false;
}

__gshared Critical _lock;
__gshared bool _walking;
__gshared Reclaimer[8] _reclaimers;
__gshared uint _num_reclaimers;


unittest
{
    auto registered = _reclaimers;
    const registered_count = _num_reclaimers;
    _num_reclaimers = 0;
    scope(exit)
    {
        _reclaimers = registered;
        _num_reclaimers = registered_count;
    }

    static size_t[3] handler_arg;
    static int[3] provider_calls;
    static int calls;

    static ReclaimResult make_handler(int idx)(size_t needed)
    {
        handler_arg[idx] = needed;
        ++calls;
        int n = provider_calls[idx]++;
        return idx == 1 && n == 0 ? ReclaimResult.more : ReclaimResult.exhausted;
    }

    ReclaimFunction h0 = (size_t n) => make_handler!0(n);
    ReclaimFunction h1 = (size_t n) => make_handler!1(n);
    ReclaimFunction h2 = (size_t n) => make_handler!2(n);

    assert(register_reclaimer(h0, 50, true));
    assert(register_reclaimer(h1, 200, true));
    assert(register_reclaimer(h2, 100, true));
    assert(!register_reclaimer(h0, 10, true));

    // willingness order: h1 (200), h2 (100), h0 (50); `more` repeats h1
    calls = 0;
    provider_calls[] = 0;
    reclaim_memory(500);
    assert(provider_calls[1] == 2 && provider_calls[2] == 1 && provider_calls[0] == 1);
    assert(handler_arg[1] == 500 && handler_arg[2] == 500);
    assert(calls == 4);

    // each reclaim step gets a speculative retry before repeating or advancing
    calls = 0;
    provider_calls[] = 0;
    static int retries;
    static int retry_on;
    static bool retry(void*)
    {
        ++retries;
        return retries == retry_on;
    }
    retries = 0;
    retry_on = 2;
    reclaim_memory(150, &retry);
    assert(provider_calls[1] == 2 && provider_calls[2] == 0);
    assert(calls == 2 && retries == 2);

    // reentry returns false
    static bool reentered;
    static ReclaimResult reenter(size_t n)
    {
        reentered = true;
        reclaim_memory(n);
        return ReclaimResult.exhausted;
    }
    assert(register_reclaimer(&reenter, 255, true));
    calls = 0;
    retries = 0;
    retry_on = 1;
    reclaim_memory(10_000, &retry);
    assert(reentered && calls == 0);
    assert(unregister_reclaimer(&reenter));

    assert(unregister_reclaimer(h0));
    assert(unregister_reclaimer(h1));
    assert(unregister_reclaimer(h2));
    assert(!unregister_reclaimer(h0));
    reclaim_memory(100);

    // every handler kind must receive its argument intact: a plain function, a
    // capturing delegate, and a non-capturing lambda inferred as a function
    static size_t fn_arg, lambda_arg;
    static ReclaimResult take_fn(size_t needed)
    {
        fn_arg = needed;
        return ReclaimResult.exhausted;
    }
    static ReclaimResult take_lambda(size_t needed)
    {
        lambda_arg = needed;
        return ReclaimResult.exhausted;
    }

    static struct Ctx
    {
    nothrow @nogc:
        size_t arg;
        ReclaimResult take(size_t needed)
        {
            arg = needed;
            return ReclaimResult.exhausted;
        }
    }
    Ctx ctx;
    ReclaimFunction nocapture = (size_t n) => take_lambda(n);

    assert(register_reclaimer(&take_fn, 30, true));
    assert(register_reclaimer(&ctx.take, 20, true));
    assert(register_reclaimer(nocapture, 10, true));
    reclaim_memory(1000);
    assert(fn_arg == 1000);
    assert(ctx.arg == 1000);
    assert(lambda_arg == 1000);
    assert(unregister_reclaimer(&take_fn));
    assert(unregister_reclaimer(&ctx.take));
    assert(unregister_reclaimer(nocapture));
}
