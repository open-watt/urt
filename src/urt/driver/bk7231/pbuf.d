module urt.driver.bk7231.pbuf;

import urt.inet : IPAddr;
import urt.mem : memcpy;
import urt.mem.pagepool : Page, page_alloc, page_free;
import urt.sync.critical : Critical;
import urt.util : byte_reverse;

nothrow @nogc:

alias BekenEthernetInputHandler = void function(uint vif, Page* pages) nothrow @nogc;

void beken_ethernet_input_handler(BekenEthernetInputHandler handler)
{
    _input_handler = handler;
}

extern(C) Pbuf* pbuf_alloc(int layer, ushort length, int type)
{
    if (type != PbufType.ram)
        return null;

    if (cast(uint)layer >= protocol_headrooms.length)
        return null;
    size_t protocol_headroom = protocol_headrooms[layer];

    Page* page = page_alloc(length, uint.alignof, pbuf_headroom + protocol_headroom);
    if (!page)
        return null;

    Pbuf* p = cast(Pbuf*)(cast(ubyte*)page + pbuf_offset);
    (cast(ushort*)p)[-1] = pbuf_offset;
    p.next = null;
    p.payload = page.data.ptr;
    p.tot_len = length;
    p.len = length;
    p.type = cast(ubyte)type;
    p.flags = 0;
    p.refcount = 1;
    return p;
}

extern(C) ubyte pbuf_free(Pbuf* p)
{
    ubyte count;
    while (p)
    {
        Pbuf* next;
        {
            auto guard = _lock.acquire();
            assert(p.refcount > 0);
            if (--p.refcount)
                break;
            next = p.next;
        }

        Page* page = page_from_pbuf(p);
        page.next = null;
        page_free(page);
        p = next;
        ++count;
    }
    return count;
}

extern(C) void pbuf_ref(Pbuf* p)
{
    if (!p)
        return;
    auto guard = _lock.acquire();
    assert(p.refcount < ushort.max);
    ++p.refcount;
}

extern(C) void pbuf_cat(Pbuf* head, Pbuf* tail)
{
    assert(head && tail && head.tot_len <= ushort.max - tail.tot_len);
    for (Pbuf* p = head; ; p = p.next)
    {
        p.tot_len += tail.tot_len;
        if (!p.next)
        {
            set_next(p, tail);
            return;
        }
    }
}

extern(C) void pbuf_chain(Pbuf* head, Pbuf* tail)
{
    pbuf_cat(head, tail);
    pbuf_ref(tail);
}

extern(C) Pbuf* pbuf_dechain(Pbuf* p)
{
    if (!p || !p.next)
        return null;

    Pbuf* tail = p.next;
    tail.tot_len = cast(ushort)(p.tot_len - p.len);
    set_next(p, null);
    p.tot_len = p.len;
    return pbuf_free(tail) ? null : tail;
}

extern(C) Pbuf* pbuf_coalesce(Pbuf* p, int layer)
{
    if (!p || !p.next)
        return p;

    Pbuf* result = pbuf_alloc(layer, p.tot_len, PbufType.ram);
    if (!result)
        return p;

    ubyte* output = cast(ubyte*)result.payload;
    for (Pbuf* input = p; input; input = input.next)
    {
        memcpy(output, input.payload, input.len);
        output += input.len;
    }
    pbuf_free(p);
    return result;
}

extern(C) uint lwip_htonl(uint value)
    => byte_reverse(value);

extern(C) int ip4addr_aton(const(char)* string, uint* address)
{
    if (!string)
        return 0;

    size_t length;
    while (string[length])
        ++length;

    IPAddr result;
    ptrdiff_t parsed = result.fromString(string[0 .. length]);
    if (parsed < 0 || cast(size_t)parsed != length)
        return 0;
    if (address)
        *address = result.address;
    return 1;
}

extern(C) void ethernetif_input(int vif, Pbuf* p)
{
    if (!p)
        return;
    if (!_input_handler)
    {
        pbuf_free(p);
        return;
    }

    Page* pages;
    Page* previous;
    for (Pbuf* current = p; current; current = current.next)
    {
        Page* page = page_from_pbuf(current);
        page.offset = cast(ushort)(cast(ubyte*)current.payload - cast(ubyte*)page);
        page.length = current.len;
        page.next = null;
        if (previous)
            previous.next = page;
        else
            pages = page;
        previous = page;
    }
    _input_handler(cast(uint)vif, pages);
}

private:
enum ushort pbuf_offset = 8;
enum size_t pbuf_headroom = ushort.sizeof + Pbuf.sizeof;
enum ubyte[5] protocol_headrooms = [74, 54, 14, 0, 0];

enum PbufLayer
{
    transport,
    ip,
    link,
    raw_tx,
    raw,
}

enum PbufType
{
    ram,
    rom,
    ref_,
    pool,
}

struct Pbuf
{
    Pbuf* next;
    void* payload;
    ushort tot_len;
    ushort len;
    ubyte type;
    ubyte flags;
    ushort refcount;
}

static assert(Pbuf.sizeof == 16);

__gshared BekenEthernetInputHandler _input_handler;
__gshared Critical _lock;

Page* page_from_pbuf(Pbuf* p)
    => cast(Page*)(cast(ubyte*)p - (cast(ushort*)p)[-1]);

void set_next(Pbuf* p, Pbuf* next)
{
    p.next = next;
    page_from_pbuf(p).next = next ? page_from_pbuf(next) : null;
}

unittest
{
    uint address;
    assert(ip4addr_aton("192.168.4.1".ptr, &address));
    assert((cast(ubyte*)&address)[0 .. 4] == [192, 168, 4, 1]);
    assert(!ip4addr_aton("192.168.4.256".ptr, &address));
    assert(!ip4addr_aton("192.168.4.1x".ptr, &address));
    assert(!ip4addr_aton(null, &address));
}
