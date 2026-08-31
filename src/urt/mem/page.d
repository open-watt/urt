module urt.mem.page;

nothrow @nogc:


struct Page
{
nothrow @nogc:

    inout(void)[] data() inout @property
        => (cast(inout(void)*)&this + offset)[0 .. length];

    size_t tailroom() const @property
        => capacity - offset - length;

    Page* next() @property
        => (cast(Page**)&this)[-1];

    void next(Page* value) @property
    {
        (cast(Page**)&this)[-1] = value;
    }

    ushort offset;
    ushort length;
    ushort capacity;
}

static assert(Page.sizeof == 6);

package(urt):

size_t page_required_capacity(size_t bytes, size_t alignment, size_t headroom, size_t tailroom)
{
    if (alignment == 0 || (alignment & (alignment - 1)) != 0)
        return size_t.max;
    if (headroom > size_t.max - Page.sizeof ||
        alignment - 1 > size_t.max - Page.sizeof - headroom)
        return size_t.max;
    size_t required = Page.sizeof + headroom + alignment - 1;
    if (bytes > size_t.max - required || tailroom > size_t.max - required - bytes)
        return size_t.max;
    required += bytes + tailroom;
    return required <= ushort.max ? required : size_t.max;
}

bool page_initialise(Page* page, size_t storage_capacity, size_t bytes, size_t alignment,
                     size_t headroom, size_t tailroom)
{
    if (!page || storage_capacity > ushort.max ||
        page_required_capacity(bytes, alignment, headroom, tailroom) == size_t.max)
        return false;

    size_t base = cast(size_t)page;
    size_t start = base + Page.sizeof + headroom;
    size_t aligned = (start + alignment - 1) & ~(alignment - 1);
    size_t offset = aligned - base;
    if (offset > storage_capacity || bytes > storage_capacity - offset ||
        tailroom > storage_capacity - offset - bytes)
        return false;

    page.offset = cast(ushort)offset;
    page.length = cast(ushort)bytes;
    page.capacity = cast(ushort)(storage_capacity - tailroom);
    page.next = null;
    return true;
}
