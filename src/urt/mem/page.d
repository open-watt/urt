module urt.mem.page;

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

package(urt):

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
