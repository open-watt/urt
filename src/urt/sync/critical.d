module urt.sync.critical;

import urt.atomic;

nothrow @nogc:

version (Windows) version = OwnerTracked;
version (Posix)   version = OwnerTracked;


// Scope-based "nothing else touches the protected state right now" guard.
// Critical sections are SHORT by contract - a handful of instructions.
// Long-held sections will starve other threads/cores; for long sections
// use a Mutex.
//
// Reentrant on every platform. Zero-init is the valid initial state on
// every platform, so a __gshared Critical needs no init() call. Place a
// Critical as a field of the object it protects (or __gshared if it
// protects global state).

struct Critical
{
nothrow @nogc:
    @disable this(this);

    bool init()
        => true;

    void destroy()
    {
    }

    CriticalGuard acquire() return
    {
        CriticalGuard g = void;
        version (OwnerTracked)
        {
            auto self = _current_id();
            if (atomicLoad(_owner) == self)
            {
                // already own it -- just bump the recursion count
                ++_count;
            }
            else
            {
                version (Windows)
                {
                    AcquireSRWLockExclusive(&_srw);
                    atomicStore(_owner, self);
                }
                else
                {
                    while (!cas(&_owner, cast(size_t)0, self))
                        pause();
                }
                _count = 1;
            }
            g._critical = &this;
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos : vPortEnterCritical;
            vPortEnterCritical(&_mux);
            g._critical = &this;
        }
        else
        {
            // bare-metal: always disable IRQs for same-core ISR protection.
            // On SMP targets, also acquire a per-instance owner-tracked
            // spinlock for cross-core protection.
            import urt.driver.irq : irq_global_disable, has_smp;
            g._prev = irq_global_disable();

            static if (has_smp)
            {
                import urt.driver.irq : cpu_id;
                uint self = cpu_id() + 1;   // +1 so 0 stays "unowned"
                if (atomicLoad(_owner) == self)
                {
                    ++_count;
                }
                else
                {
                    while (!cas(&_owner, cast(uint)0, self))
                        pause();
                    _count = 1;
                }
                g._critical = &this;
            }
        }
        return g;
    }

private:
    version (OwnerTracked)
    {
        version (Windows)
            SRWLOCK _srw;       // waiters block here; owner/count layer reentrancy on top
        shared size_t _owner;   // current thread id, or 0 when unowned
        int _count;             // recursion depth (touched only by owner)
    }
    else version (FreeRTOS)
    {
        import urt.internal.sys.freertos : portMUX_TYPE;
        portMUX_TYPE _mux;
    }
    else
    {
        // bare-metal: state only present on SMP targets.
        import urt.driver.irq : has_smp;
        static if (has_smp)
        {
            shared uint _owner;   // (cpu_id + 1) of owner, or 0 when unowned
            uint _count;          // recursion depth (touched only by owner)
        }
        // (single-core: nothing per-instance -- the IRQ-disable is global
        // on this core, and there are no other cores to spin against.)
    }

    void _leave()
    {
        version (OwnerTracked)
        {
            if (--_count == 0)
            {
                atomicStore!(MemoryOrder.release)(_owner, cast(size_t)0);
                version (Windows)
                    ReleaseSRWLockExclusive(&_srw);
            }
        }
        else version (FreeRTOS)
        {
            import urt.internal.sys.freertos : vPortExitCritical;
            vPortExitCritical(&_mux);
        }
        else
        {
            // bare-metal: drop the spinlock on SMP; the guard destructor
            // restores IRQs via _prev.
            import urt.driver.irq : has_smp;
            static if (has_smp)
            {
                if (--_count == 0)
                    atomicStore!(MemoryOrder.release)(_owner, cast(uint)0);
            }
        }
    }
}


struct CriticalGuard
{
nothrow @nogc:
    @disable this();
    @disable this(this);

    ~this()
    {
        version (OwnerTracked)  _critical._leave();
        else version (FreeRTOS) _critical._leave();
        else
        {
            import urt.driver.irq : irq_global_set, has_smp;
            static if (has_smp)
                _critical._leave();
            irq_global_set(_prev);
        }
    }

private:
    version (OwnerTracked)  Critical* _critical;
    else version (FreeRTOS) Critical* _critical;
    else
    {
        import urt.driver.irq : has_smp;
        static if (has_smp)
            Critical* _critical;
        bool _prev;
    }
}


unittest
{
    Critical c;
    assert(c.init());

    // basic acquire/release
    int x;
    {
        auto g = c.acquire();
        x = 42;
    }
    assert(x == 42);

    // reentrant: nested acquire on the same thread/core
    {
        auto g1 = c.acquire();
        {
            auto g2 = c.acquire();
            x = 100;
        }
        // still held by g1 here
        x = 101;
    }
    assert(x == 101);

    // re-acquirable after release
    {
        auto g = c.acquire();
        x = 7;
    }
    assert(x == 7);

    c.destroy();
}


private:

version (Windows)
{
    // SRWLOCK is a single pointer-sized opaque value; zero-init is valid.
    struct SRWLOCK { void* Ptr; }

    extern(Windows) nothrow @nogc:
    uint GetCurrentThreadId();
    void AcquireSRWLockExclusive(SRWLOCK*);
    void ReleaseSRWLockExclusive(SRWLOCK*);

    size_t _current_id()
        => GetCurrentThreadId();
}
else version (Posix)
{
    extern(C) nothrow @nogc void* pthread_self();

    size_t _current_id()
        => cast(size_t)pthread_self();
}
