module urt.mem.freelist;

import urt.atomic;
import urt.driver.irq : irq_critical, irq_max;
import urt.lifetime;
import urt.mem;
import urt.sync.spinlock : Spinlock;

nothrow @nogc:


// An intrusive stack of free blocks; each block's first word links to the next. An atomic stack's push and pop are
// safe from any context, ISRs and other cores included.
struct FreeStack(bool atomic = false)
{
nothrow @nogc:

    void push(void* block)
    {
        push_chain(block, block, 1);
    }

    void push_chain(void* first, void* last, uint count)
    {
        static if (atomic)
            atomic_push_chain(_core, first, last, count);
        else
            stack_push_chain(_core, first, last, count);
    }

    void* pop()
    {
        static if (atomic)
            return atomic_pop(_core);
        else
            return stack_pop(_core);
    }

    // the whole stack, linked through each block's first word
    void* take_all()
    {
        static if (atomic)
            return atomic_take_all(_core);
        else
            return stack_take_all(_core);
    }

    // everything below the top keep blocks, null-terminated; an atomic stack is held for the keep blocks' walk only
    void* take_beyond(uint keep, out uint taken)
    {
        static if (atomic)
            return atomic_take_beyond(_core, keep, taken);
        else
            return stack_take_beyond(_core, keep, taken);
    }

    uint length() const
    {
        static if (atomic)
            return atomic_length(*cast(AtomicStackCore*)&_core);
        else
            return _core.count;
    }

private:
    static if (atomic)
        AtomicStackCore _core;
    else
        StackCore _core;
}


// Growing an empty list allocates, so an atomic list's alloc() from an ISR must not find it empty.
struct FreeList(T, size_t blockSize = 1, bool atomic = false)
{
    static assert(blockSize > 0, "blockSize must be greater than 0");

    static if (is(T == class))
        alias PtrTy = T;
    else
        alias PtrTy = T*;

    struct Node
    {
        union {
            Node* next = null;
            static if (is(T == class))
            {
                align(__traits(classInstanceAlignment, T))
                void[__traits(classInstanceSize, T)] element = void;
            }
            else
                T element = void;
        }
    }

    ~this()
    {
        static if (blockSize == 1)
            count_items(-cast(int)free_nodes(_free.take_all(), Node.sizeof));
        else
            assert(false, "TODO: find the lowest pointer; free it as a block; repeat until all blocks are freed");

        assert(atomicLoad(itemCount) == 0, "Free list has unfreed items!");
    }

    PtrTy alloc(Args...)(auto ref Args args)
    {
        Node* n = cast(Node*)_free.pop();
        if (!n)
        {
            void* rest, rest_last;
            n = cast(Node*)alloc_nodes(Node.sizeof, Node.alignof, blockSize, rest, rest_last);
            if (!n)
                return null;
            if (rest)
                _free.push_chain(rest, rest_last, blockSize - 1);
            count_items(blockSize);
        }
        // TODO: when placement new is available...
//        static if (CanPlacementNew!(T, args))
//            return new(n.element) T(forward!args);
//        else
        {
            emplace(&n.element, forward!args);
            return &n.element;
        }
    }

    void free(PtrTy object)
    {
        static if (is(T == class))
            object.destroy!false();
        else
            (*object).destroy!false();
        _free.push(cast(Node*)object);
    }

private:
    FreeStack!atomic _free;
    static if (atomic)
        shared uint itemCount;
    else
        uint itemCount;

    void count_items(int delta)
    {
        static if (atomic)
            atomicFetchAdd(itemCount, cast(uint)delta);
        else
            itemCount += delta;
    }
}


private:

struct StackCore
{
    void* head;
    uint count;
}

struct AtomicStackCore
{
    StackCore stack;
    static if (irq_max == 0)
        Spinlock lock;
    alias stack this;
}

void stack_push_chain(ref StackCore core, void* first, void* last, uint count)
{
    *cast(void**)last = core.head;
    core.head = first;
    core.count += count;
}

void* stack_pop(ref StackCore core)
{
    void* block = core.head;
    if (block)
    {
        core.head = *cast(void**)block;
        --core.count;
    }
    return block;
}

void* stack_take_all(ref StackCore core)
{
    void* chain = core.head;
    core.head = null;
    core.count = 0;
    return chain;
}

void* stack_take_beyond(ref StackCore core, uint keep, out uint taken)
{
    if (core.count <= keep)
        return null;
    if (keep == 0)
    {
        taken = core.count;
        return stack_take_all(core);
    }
    void* bottom = core.head;
    foreach (_; 1 .. keep)
        bottom = *cast(void**)bottom;
    void* chain = *cast(void**)bottom;
    *cast(void**)bottom = null;
    taken = core.count - keep;
    core.count = keep;
    return chain;
}

auto section(ref AtomicStackCore core)
{
    static if (irq_max > 0)
        return irq_critical();
    else
        return core.lock.acquire();     // TODO: hosted could swap a tagged head with a 16-byte CAS (CMPXCHG16B, CASP) instead of locking
}

void atomic_push_chain(ref AtomicStackCore core, void* first, void* last, uint count)
{
    auto guard = section(core);
    stack_push_chain(core, first, last, count);
}

void* atomic_pop(ref AtomicStackCore core)
{
    auto guard = section(core);
    return stack_pop(core);
}

void* atomic_take_all(ref AtomicStackCore core)
{
    auto guard = section(core);
    return stack_take_all(core);
}

void* atomic_take_beyond(ref AtomicStackCore core, uint keep, out uint taken)
{
    auto guard = section(core);
    return stack_take_beyond(core, keep, taken);
}

uint atomic_length(ref AtomicStackCore core)
{
    auto guard = section(core);
    return core.count;
}

// one allocation of count nodes; the first is returned, the rest come back linked
void* alloc_nodes(size_t node_size, size_t node_align, size_t count, out void* rest, out void* rest_last)
{
    void* block = alloc(node_size * count, node_align, MemFlags.fast).ptr;
    if (!block || count == 1)
        return block;
    foreach (i; 1 .. count - 1)
        *cast(void**)(block + i * node_size) = block + (i + 1) * node_size;
    rest = block + node_size;
    rest_last = block + (count - 1) * node_size;
    return block;
}

uint free_nodes(void* chain, size_t node_size)
{
    uint freed;
    while (chain)
    {
        void* next = *cast(void**)chain;
        free(chain[0 .. node_size]);
        chain = next;
        ++freed;
    }
    return freed;
}


unittest
{
    static struct Block
    {
        Block* next;
        uint id;
    }
    Block[4] blocks;

    void exercise(bool atomic)()
    {
        FreeStack!atomic stack;
        assert(stack.pop() is null && stack.length == 0);
        stack.push(&blocks[0]);
        blocks[1].next = &blocks[2];
        stack.push_chain(&blocks[1], &blocks[2], 2);
        assert(stack.length == 3);
        assert(stack.pop() is &blocks[1] && stack.pop() is &blocks[2] && stack.pop() is &blocks[0]);
        assert(stack.pop() is null && stack.length == 0);
        stack.push(&blocks[3]);
        assert(stack.take_all() is &blocks[3] && stack.length == 0 && stack.pop() is null);

        // the cut keeps the top and hands back the rest in order
        foreach_reverse (ref b; blocks)
            stack.push(&b);
        uint taken;
        assert(stack.take_beyond(4, taken) is null && taken == 0, "nothing below a stack no deeper than keep");
        void* deep = stack.take_beyond(1, taken);
        assert(deep is &blocks[1] && taken == 3 && stack.length == 1);
        assert(blocks[1].next is &blocks[2] && blocks[2].next is &blocks[3] && blocks[3].next is null);
        stack.push_chain(&blocks[1], &blocks[3], 3);
        assert(stack.length == 4);
        assert(stack.pop() is &blocks[1] && stack.pop() is &blocks[2] && stack.pop() is &blocks[3] && stack.pop() is &blocks[0]);
        assert(stack.pop() is null);

        foreach_reverse (ref b; blocks)
            stack.push(&b);
        assert(stack.take_beyond(0, taken) is &blocks[0] && taken == 4 && stack.length == 0 && stack.pop() is null);
        stack.push(&blocks[3]);
        assert(stack.pop() is &blocks[3] && stack.pop() is null, "a stack emptied by the cut works on");
    }
    exercise!false();
    exercise!true();

    static struct Item
    {
        uint value;
        this(uint v) nothrow @nogc { value = v; }
    }
    FreeList!Item list;
    Item* a = list.alloc(1);
    Item* b = list.alloc(2);
    assert(a.value == 1 && b.value == 2 && a !is b);
    list.free(a);
    Item* c = list.alloc(3);
    assert(c is a && c.value == 3, "a freed item is reused");
    list.free(b);
    list.free(c);

    FreeList!(Item, 1, true) shared_list;
    Item* d = shared_list.alloc(4);
    assert(d.value == 4 && atomicLoad(shared_list.itemCount) == 1);
    shared_list.free(d);

    void* rest, rest_last;
    void* first = alloc_nodes(16, 8, 3, rest, rest_last);
    assert(rest is first + 16 && rest_last is first + 32 && *cast(void**)rest is rest_last, "a block links its nodes");
    free(first[0 .. 48]);
}

version (BareMetal) {} else
unittest
{
    import urt.thread : thread_join, thread_spawn;

    enum per_thread = 20_000;
    static struct Hammer
    {
    nothrow @nogc:
        FreeStack!true* stack;
        void run()
        {
            foreach (_; 0 .. per_thread)
            {
                void* block;
                while ((block = stack.pop()) is null) {}
                stack.push(block);
            }
        }
    }

    void*[8][4] storage;
    FreeStack!true stack;
    foreach (ref block; storage)
        stack.push(block.ptr);

    Hammer[3] hammers;
    void*[3] threads;
    foreach (i, ref h; hammers)
    {
        h.stack = &stack;
        threads[i] = thread_spawn(&h.run);
        assert(threads[i], "spawn");
    }
    foreach (t; threads)
        thread_join(t);

    bool[4] seen;
    foreach (_; 0 .. 4)
    {
        void* block = stack.pop();
        foreach (i, ref s; storage)
        {
            if (block is s.ptr)
            {
                assert(!seen[i], "a block is never handed out twice");
                seen[i] = true;
            }
        }
    }
    assert(stack.pop() is null && seen == [true, true, true, true], "every block comes back exactly once");
}
