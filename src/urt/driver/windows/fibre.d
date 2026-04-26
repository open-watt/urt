module urt.driver.windows.fibre;

version (Windows):

import urt.fibre : cothread_t, coentry_t;
import urt.mem;
import urt.internal.sys.windows.winbase;

nothrow @nogc:


version (X86_64)
{
    import urt.system : NT_TIB, __readgsqword;

    void* GetCurrentFiber()
        => cast(void*)__readgsqword(NT_TIB.FiberData.offsetof);

    void* GetFiberData()
        => *cast(void**)__readgsqword(NT_TIB.FiberData.offsetof);
}
else version (X86)
{
    import urt.system : NT_TIB, __readfsdword;

    void* GetCurrentFiber()
        => cast(void*)__readfsdword(NT_TIB.FiberData.offsetof);

    void* GetFiberData()
        => *cast(void**)__readfsdword(NT_TIB.FiberData.offsetof);
}

struct co_fibre_data
{
    void* fiber;
    void* user_data;
    uint stack_size;
    coentry_t coentry;
}
co_fibre_data thread_fiber_data;

inout(co_fibre_data)* co_get_fibre_data(inout cothread_t fibre) pure
    => cast(co_fibre_data*)fibre;

cothread_t co_active()
{
    if(!thread_fiber_data.fiber)
        thread_fiber_data.fiber = ConvertThreadToFiber(&thread_fiber_data);
    return GetFiberData();
}

void* co_data()
    => (cast(co_fibre_data*)GetFiberData()).user_data;

cothread_t co_derive(void[] memory, coentry_t entry, void* data)
{
    // Windows fibers do not allow users to supply their own memory
    return null;
}

cothread_t co_create(size_t stack_size, coentry_t entry, void* data)
{
    assert(stack_size <= uint.max, "Stack size too large");

    co_active();

    extern(Windows) static void co_thunk(void* codata)
    {
        (cast(co_fibre_data*)codata).coentry();
        assert(false, "Error: returned from fibre!");
    }

    auto fdata = defaultAllocator().allocT!co_fibre_data();
    fdata.user_data = data;
    fdata.coentry = entry;
    fdata.stack_size = cast(uint)stack_size;
    fdata.fiber = CreateFiber(stack_size, &co_thunk, fdata);
    return fdata;
}

void co_delete(cothread_t cothread)
{
    auto fdata = cast(co_fibre_data*)cothread;
    DeleteFiber(fdata.fiber);
    defaultAllocator().freeT(fdata);
}

void co_switch(cothread_t cothread)
{
    auto fdata = cast(co_fibre_data*)cothread;
    SwitchToFiber(fdata.fiber);
}
