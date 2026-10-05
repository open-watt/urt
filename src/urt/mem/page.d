module urt.mem.page;

import urt.atomic;
import urt.sync.critical;

nothrow @nogc:


struct Page
{
nothrow @nogc:

    inout(void)[] data() inout @property
        => (cast(inout(void)*)&this + offset)[0 .. length];

    size_t headroom() const @property
        => offset - Page.sizeof;

    size_t tailroom() const @property
        => capacity - offset - length;

    Page* next() @property
        => cast(Page*)(cast(size_t)(cast(Page**)&this)[-1] & ~page_next_flags);

    void next(Page* value) @property
    {
        Page** link = (cast(Page**)&this) - 1;
        *link = cast(Page*)(cast(size_t)value | (cast(size_t)*link & page_next_flags));
    }

    ushort offset;
    ushort length;
    ushort capacity;
}

static assert(Page.sizeof == 6);

// Waits for a page to be freed after an allocation failed. wake runs from page_pool_wake().
struct PageWaiter
{
    PageWaiter* next;
    void delegate() nothrow @nogc wake;
    uint pass;
    bool queued;
}

// Read before the allocation attempt that may fail, and pass to page_wait().
uint page_free_generation()
    => atomicLoad(_free_generation);

// Queues waiter, or returns false without queuing when a page has been freed since generation; the caller then
// retries its allocation instead of waiting.
bool page_wait(PageWaiter* waiter, uint generation)
{
    auto guard = _wait_lock.acquire();
    if (waiter.queued)
        return true;
    atomicFetchAdd(_waiting, 1);
    if (atomicLoad(_free_generation) != generation)
    {
        atomicFetchSub(_waiting, 1);
        return false;
    }
    waiter.queued = true;
    waiter.pass = _wake_pass;
    waiter.next = null;
    if (_wait_tail)
        _wait_tail.next = waiter;
    else
        _wait_head = waiter;
    _wait_tail = waiter;
    return true;
}

void page_unwait(PageWaiter* waiter)
{
    auto guard = _wait_lock.acquire();
    if (!waiter.queued)
        return;
    PageWaiter* prev = null;
    PageWaiter* w = _wait_head;
    while (w !is waiter)
    {
        prev = w;
        w = w.next;
    }
    if (prev)
        prev.next = waiter.next;
    else
        _wait_head = waiter.next;
    if (_wait_tail is waiter)
        _wait_tail = prev;
    waiter.next = null;
    waiter.queued = false;
    atomicFetchSub(_waiting, 1);
}

// Installed once, before any page can be freed concurrently. Called from the freeing or allocating context, which may be
// an ISR or another thread, at most once until the next page_pool_wake(); it must guarantee that page_pool_wake() runs.
void page_pool_wake_hook(void function() nothrow @nogc hook)
{
    _wake_hook = hook;
    atomicStore(_wake_signalled, false);
}

// Refills the pool where an allocation ran it low, then wakes the waiters queued before this call, oldest first; a wake
// that queues again waits for the next pass.
void page_pool_wake()
{
    atomicStore(_wake_signalled, false);
    if (_maintain)
        _maintain();
    uint pass;
    {
        auto guard = _wait_lock.acquire();
        pass = ++_wake_pass;
    }
    for (;;)
    {
        PageWaiter* w;
        {
            auto guard = _wait_lock.acquire();
            w = _wait_head;
            if (!w || w.pass == pass)
                return;
            _wait_head = w.next;
            if (_wait_tail is w)
                _wait_tail = null;
            w.next = null;
            w.queued = false;
            atomicFetchSub(_waiting, 1);
        }
        w.wake();
    }
}

// The bytes of a chain read as one series: the contiguous span at offset, up to length, ending where its page does.
const(void)[] page_chain_span(const(Page)* chain, size_t offset, size_t length)
{
    for (const(Page)* page = chain; page; page = (cast(Page*)page).next)
    {
        if (offset < page.length)
        {
            immutable size_t n = page.length - offset < length ? page.length - offset : length;
            return page.data[offset .. offset + n];
        }
        offset -= page.length;
    }
    return null;
}

package(urt):

void page_freed()
{
    atomicFetchAdd(_free_generation, 1);
    if (atomicLoad(_waiting) != 0)
        page_pool_signal();
}

// Safe from any context; asks for page_pool_wake() once until it runs, and is dropped while no hook can ask.
void page_pool_signal()
{
    if (!_wake_hook || atomicExchange(&_wake_signalled, true))
        return;
    _wake_hook();
}

// The pool's refill, run by page_pool_wake() on the main thread.
void page_pool_maintenance(void function() nothrow @nogc maintain)
{
    _maintain = maintain;
}

enum size_t page_next_flags = 1;

size_t page_required_capacity(size_t bytes, size_t alignment, size_t headroom, size_t tailroom)
{
    debug assert(alignment != 0 && (alignment & (alignment - 1)) == 0);
    return Page.sizeof + headroom + alignment - 1 + bytes + tailroom;
}

bool page_initialise(Page* page, size_t storage_capacity, size_t bytes, size_t alignment, size_t headroom, size_t tailroom)
{
    debug assert(alignment != 0 && (alignment & (alignment - 1)) == 0);
    if (!page || storage_capacity > ushort.max)
        return false;
    size_t base = cast(size_t)page;
    size_t start = base + Page.sizeof + headroom;
    size_t aligned = (start + alignment - 1) & ~(alignment - 1);
    size_t offset = aligned - base;
    if (offset + bytes + tailroom > storage_capacity)
        return false;

    page.offset = cast(ushort)offset;
    page.length = cast(ushort)bytes;
    page.capacity = cast(ushort)storage_capacity;
    page.next = null;
    return true;
}


private:

__gshared Critical _wait_lock;
__gshared PageWaiter* _wait_head;
__gshared PageWaiter* _wait_tail;
__gshared void function() nothrow @nogc _wake_hook;
__gshared void function() nothrow @nogc _maintain;
__gshared uint _wake_pass;
shared bool _wake_signalled;
shared uint _free_generation;
shared uint _waiting;

unittest
{
    __gshared uint hooks;
    static void hook() nothrow @nogc { ++hooks; }

    static struct Probe
    {
    nothrow @nogc:
        PageWaiter waiter;
        uint woken;
        bool requeue;
        PageWaiter* cancel;

        void wake()
        {
            ++woken;
            if (requeue)
                assert(page_wait(&waiter, page_free_generation()));
            if (cancel)
                page_unwait(cancel);
        }
    }

    page_pool_wake_hook(null);
    page_pool_signal();
    page_pool_wake_hook(&hook);
    scope (exit) page_pool_wake_hook(null);
    page_pool_signal();
    assert(hooks == 1, "a request with no hook to ask does not stand in the way of the next");
    page_pool_wake();
    hooks = 0;

    Probe a, b, c;
    a.waiter.wake = &a.wake;
    b.waiter.wake = &b.wake;
    c.waiter.wake = &c.wake;

    page_freed();
    assert(hooks == 0);

    // a page freed between the failed allocation and the wait is not lost
    uint generation = page_free_generation();
    page_freed();
    assert(!page_wait(&a.waiter, generation) && !a.waiter.queued && atomicLoad(_waiting) == 0);

    generation = page_free_generation();
    assert(page_wait(&a.waiter, generation));
    assert(page_wait(&b.waiter, generation));
    assert(page_wait(&a.waiter, generation));
    assert(atomicLoad(_waiting) == 2);
    page_freed();
    page_freed();
    assert(hooks == 1);
    page_pool_wake();
    assert(a.woken == 1 && b.woken == 1 && _wait_head is null && atomicLoad(_waiting) == 0);

    a.requeue = true;
    assert(page_wait(&a.waiter, page_free_generation()));
    page_pool_wake();
    assert(a.woken == 2 && a.waiter.queued && atomicLoad(_waiting) == 1);
    page_freed();
    assert(hooks == 2);
    a.requeue = false;
    page_pool_wake();
    assert(a.woken == 3 && _wait_head is null && atomicLoad(_waiting) == 0);

    a.cancel = &c.waiter;
    generation = page_free_generation();
    assert(page_wait(&a.waiter, generation));
    assert(page_wait(&b.waiter, generation));
    assert(page_wait(&c.waiter, generation));
    page_unwait(&b.waiter);
    page_pool_wake();
    assert(a.woken == 4 && b.woken == 1 && c.woken == 0);
    assert(_wait_head is null && _wait_tail is null && atomicLoad(_waiting) == 0);
}
