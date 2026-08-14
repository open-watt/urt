module urt.mem.reclaim;

import urt.sync.critical;
import urt.thread : is_main_thread;

nothrow @nogc:


// Cache-pressure protocol: subsystems holding reclaimable memory (freelists, caches)
// register a handler; on allocation failure the allocator walks handlers most-willing
// first until enough is freed. Willingness reflects rebuild cost, not importance.
// Handlers must not block, must not allocate, and should free whole heap blocks
// (individual pages returned to an internal freelist don't help the heap).
// Handlers registered !thread_safe are only invoked from the main thread.

alias ReclaimHandler = size_t delegate(size_t bytes_needed) nothrow @nogc;
alias ReclaimFunction = size_t function(size_t bytes_needed) nothrow @nogc;

bool register_reclaimer(ReclaimHandler handler, ubyte willingness, bool thread_safe)
    => add_reclaimer(Reclaimer(handler.funcptr, handler.ptr, willingness, thread_safe, true));

bool register_reclaimer(ReclaimFunction handler, ubyte willingness, bool thread_safe)
    => add_reclaimer(Reclaimer(handler, null, willingness, thread_safe, false));

bool unregister_reclaimer(ReclaimHandler handler)
    => remove_reclaimer(Reclaimer(handler.funcptr, handler.ptr, 0, false, true));

bool unregister_reclaimer(ReclaimFunction handler)
    => remove_reclaimer(Reclaimer(handler, null, 0, false, false));

// Returns the (approximate) number of bytes released. Reentry from a handler that
// allocates returns 0 rather than recursing.
size_t reclaim_memory(size_t bytes_needed)
{
    auto guard = _lock.acquire();

    if (_walking)
        return 0;
    _walking = true;
    scope (exit) _walking = false;

    bool main_thread = is_main_thread();
    size_t freed = 0;
    foreach (ref r; _reclaimers[0 .. _num_reclaimers])
    {
        if (!r.thread_safe && !main_thread)
            continue;
        size_t remaining = bytes_needed > freed ? bytes_needed - freed : 0;
        freed += r.reclaim(remaining);
        if (freed >= bytes_needed)
            break;
    }
    return freed;
}


private:

struct Reclaimer
{
nothrow @nogc:
    ReclaimFunction fn;
    void* context;
    ubyte willingness;
    bool thread_safe;
    // A delegate's context is null when it captures nothing, so the caller kind cannot
    // be recovered from `context` -- and calling a delegate's funcptr directly passes
    // arguments in the wrong places (extern(D) hands the context register to the last
    // parameter for a plain function).
    bool is_delegate;

    size_t reclaim(size_t bytes_needed)
    {
        if (is_delegate)
        {
            ReclaimHandler dg;
            dg.ptr = context;
            dg.funcptr = fn;
            return dg(bytes_needed);
        }
        return fn(bytes_needed);
    }

    bool matches(ref const Reclaimer other) const
        => fn is other.fn && context is other.context && is_delegate == other.is_delegate;
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
    static size_t[3] freed_arg;
    static int[3] call_order;
    static int calls;

    static size_t make_handler(int idx, size_t frees)(size_t needed)
    {
        freed_arg[idx] = needed;
        call_order[idx] = calls++;
        return frees;
    }

    ReclaimHandler h0 = (size_t n) => make_handler!(0, 100)(n);
    ReclaimHandler h1 = (size_t n) => make_handler!(1, 200)(n);
    ReclaimHandler h2 = (size_t n) => make_handler!(2, 400)(n);

    assert(register_reclaimer(h0, 50, true));
    assert(register_reclaimer(h1, 200, true));
    assert(register_reclaimer(h2, 100, true));
    assert(!register_reclaimer(h0, 10, true));

    // willingness order: h1 (200), h2 (100), h0 (50); stops once covered
    calls = 0;
    size_t freed = reclaim_memory(500);
    assert(freed == 600);
    assert(call_order[1] == 0 && call_order[2] == 1);
    assert(freed_arg[1] == 500 && freed_arg[2] == 300);
    assert(calls == 2);

    // early exit when first handler covers the request
    calls = 0;
    freed = reclaim_memory(150);
    assert(freed == 200 && calls == 1);

    // reentry returns 0
    ReclaimHandler reenter = (size_t n) => reclaim_memory(n);
    assert(register_reclaimer(reenter, 255, true));
    calls = 0;
    freed = reclaim_memory(10_000);
    assert(freed == 700);
    assert(unregister_reclaimer(reenter));

    assert(unregister_reclaimer(h0));
    assert(unregister_reclaimer(h1));
    assert(unregister_reclaimer(h2));
    assert(!unregister_reclaimer(h0));
    assert(reclaim_memory(100) == 0);

    // every handler kind must receive its argument intact: a plain function, a
    // capturing delegate, and a non-capturing delegate (whose context is null, so
    // the kind cannot be inferred from the context pointer)
    static size_t fn_arg, lambda_arg;
    static size_t take_fn(size_t needed)
    {
        fn_arg = needed;
        return 10;
    }
    static size_t take_lambda(size_t needed)
    {
        lambda_arg = needed;
        return 10;
    }

    static struct Ctx
    {
    nothrow @nogc:
        size_t arg;
        size_t take(size_t needed)
        {
            arg = needed;
            return 10;
        }
    }
    Ctx ctx;
    ReclaimHandler nocapture = (size_t n) => take_lambda(n);

    assert(register_reclaimer(&take_fn, 30, true));
    assert(register_reclaimer(&ctx.take, 20, true));
    assert(register_reclaimer(nocapture, 10, true));
    assert(reclaim_memory(1000) == 30);
    assert(fn_arg == 1000);
    assert(ctx.arg == 990);
    assert(lambda_arg == 980);
    assert(unregister_reclaimer(&take_fn));
    assert(unregister_reclaimer(&ctx.take));
    assert(unregister_reclaimer(nocapture));
}
