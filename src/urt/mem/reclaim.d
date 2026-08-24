module urt.mem.reclaim;

version (Tiny) {} else
    version = MemoryThreats;

version (MemoryThreats)
    import urt.atomic;
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


version (MemoryThreats)
{
    // Memory-threat watermarks: when allocated bytes cross an entry's high watermark the
    // handler fires ONCE, re-arming only after usage falls back below the low watermark.
    // Handlers run inside the allocator on whatever thread allocated: they must not block
    // and must not do work -- post an event to a queue and return. Usage is accounted in
    // requested bytes except on unified CRT heaps, where usable block sizes keep C and D
    // allocation accounting consistent. Watermarks remain a proxy for heap footprint.

    alias MemoryThreatHandler  = void delegate(size_t used) nothrow @nogc;
    alias MemoryThreatFunction = void function(size_t used) nothrow @nogc;

    size_t memory_in_use()
        => atomicLoad(_used);

    bool register_memory_threat(MemoryThreatHandler handler, size_t high, size_t low)
    {
        assert(handler.ptr !is null);
        return add_threat(Threat(handler.funcptr, handler.ptr, high, low, false));
    }

    bool register_memory_threat(MemoryThreatFunction handler, size_t high, size_t low)
        => add_threat(Threat(handler, null, high, low, false));

    bool unregister_memory_threat(MemoryThreatHandler handler)
    {
        assert(handler.ptr !is null);
        return remove_threat(Threat(handler.funcptr, handler.ptr, 0, 0, false));
    }

    bool unregister_memory_threat(MemoryThreatFunction handler)
        => remove_threat(Threat(handler, null, 0, 0, false));

    // Called by urt.mem.alloc on every successful alloc/free (and realloc/expand deltas);
    // must stay one atomic + one compare on the uncrossed path.
    void account_alloc(size_t bytes)
    {
        size_t used = atomicFetchAdd(_used, bytes) + bytes;
        if (used >= atomicLoad(_next_high))
            threat_crossed();
    }

    void account_free(size_t bytes)
    {
        size_t used = atomicFetchSub(_used, bytes) - bytes;
        if (used <= atomicLoad(_max_low))
            threat_rearm();
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

version (MemoryThreats)
{
    struct Threat
    {
nothrow @nogc:
        MemoryThreatFunction fn;
        void* context;
        size_t high;
        size_t low;
        bool fired;

        void fire(size_t used)
        {
            if (context !is null)
            {
                MemoryThreatHandler dg;
                dg.ptr = context;
                dg.funcptr = fn;
                dg(used);
            }
            else
                fn(used);
        }

        bool matches(ref const Threat other) const
            => fn is other.fn && context is other.context;
    }

    __gshared Threat[4] _threats;
    __gshared uint _num_threats;
    shared size_t _used;
    shared size_t _next_high = size_t.max;  // min high among armed entries
    shared size_t _max_low;                 // max low among fired entries

    bool add_threat(Threat t)
    {
        assert(t.low < t.high, "Threat low watermark must be below high");

        auto guard = _lock.acquire();
        if (_num_threats == _threats.length)
            return false;
        foreach (ref e; _threats[0 .. _num_threats])
        {
            if (e.matches(t))
                return false;
        }
        _threats[_num_threats++] = t;
        update_thresholds();
        return true;
    }

    bool remove_threat(Threat t)
    {
        auto guard = _lock.acquire();
        foreach (i; 0 .. _num_threats)
        {
            if (_threats[i].matches(t))
            {
                foreach (j; i .. _num_threats - 1)
                    _threats[j] = _threats[j + 1];
                --_num_threats;
                update_thresholds();
                return true;
            }
        }
        return false;
    }

    // under _lock
    void update_thresholds()
    {
        size_t nh = size_t.max;
        size_t ml = 0;
        foreach (ref t; _threats[0 .. _num_threats])
        {
            if (!t.fired && t.high < nh)
                nh = t.high;
            if (t.fired && t.low > ml)
                ml = t.low;
        }
        atomicStore(_next_high, nh);
        atomicStore(_max_low, ml);
    }

    void threat_crossed()
    {
        auto guard = _lock.acquire();
        size_t used = atomicLoad(_used);
        foreach (ref t; _threats[0 .. _num_threats])
        {
            if (!t.fired && used >= t.high)
            {
                t.fired = true;
                t.fire(used);
            }
        }
        update_thresholds();
    }

    void threat_rearm()
    {
        auto guard = _lock.acquire();
        size_t used = atomicLoad(_used);
        foreach (ref t; _threats[0 .. _num_threats])
        {
            if (t.fired && used <= t.low)
                t.fired = false;
        }
        update_thresholds();
    }
}


unittest
{
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

    version (MemoryThreats)
    {
        // memory-threat watermarks: fires once per episode, re-arms below low
        import urt.mem.alloc : alloc, free;

        static int threat_fires;
        static size_t threat_used;
        static void on_threat(size_t used)
        {
            ++threat_fires;
            threat_used = used;
        }

        size_t base = memory_in_use();
        assert(register_memory_threat(&on_threat, base + 3000, base + 1000));
        assert(!register_memory_threat(&on_threat, base + 5000, base + 1000));

        void[] a = alloc(2000);
        assert(threat_fires == 0);
        void[] b = alloc(2000);
        assert(threat_fires == 1 && threat_used >= base + 3000);
        void[] c = alloc(2000);
        assert(threat_fires == 1);          // still in the same episode

        free(c);
        free(b);
        assert(threat_fires == 1);          // above low: not re-armed yet
        void[] d = alloc(4000);
        assert(threat_fires == 1);          // crossing high again while fired: no refire
        free(d);
        free(a);                            // below low: re-arms
        void[] e = alloc(4000);
        assert(threat_fires == 2);
        free(e);

        assert(unregister_memory_threat(&on_threat));
        assert(!unregister_memory_threat(&on_threat));

        // A delayed low-crossing slow path must not re-arm from its stale observation
        // after another thread has already raised current usage above high.
        base = memory_in_use();
        int fires_before_race = threat_fires;
        assert(register_memory_threat(&on_threat, base + 100, base + 50));
        account_alloc(100);
        assert(threat_fires == fires_before_race + 1);
        threat_rearm();
        account_alloc(1);
        assert(threat_fires == fires_before_race + 1);
        account_free(101);
        account_alloc(100);
        assert(threat_fires == fires_before_race + 2);
        account_free(100);
        assert(unregister_memory_threat(&on_threat));

        // delegate threat: the fired handler must receive the usage value
        static struct Watcher
        {
        nothrow @nogc:
            size_t seen;
            void on(size_t used) { seen = used; }
        }
        Watcher w;
        base = memory_in_use();
        assert(register_memory_threat(&w.on, base + 3000, base + 1000));
        void[] f = alloc(4000);
        assert(w.seen >= base + 3000);
        free(f);
        assert(unregister_memory_threat(&w.on));
    }
}
