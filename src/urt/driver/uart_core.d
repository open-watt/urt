// The buffering, delivery and bounded progress every UART backend shares. The backend supplies tx_idle, and tx_fill,
// which moves TX bytes into the FIFO inside section() and arms TX while more waits. On a part the ISR side runs in the
// interrupt and section() holds interrupts off; on a host it runs in the backend's I/O thread, which takes section() too.
module urt.driver.uart_core;

import urt.driver.irq : irq_critical, irq_max;
import urt.driver.uart : Uart, UartBurst, UartCallbackContext, UartConfig, UartCounters, UartError, UartRxCallback,
    UartRxTiming, UartTxCallback, uart_frame_bits;
import urt.sync.spinlock : Spinlock;
import urt.mem.pagepool;
import urt.time : Duration, MonoTime, getTime, msecs, nsecs;

nothrow @nogc:

enum tx_drain_limit = 250.msecs;
enum uint puts_stall_spins = 1_000_000;     // tens of milliseconds of register reads: no clock on a fault path

// A received page holds its character time in its headroom, its bytes from its start, and a tag per frame that ends on
// it from its end down, each (ticks << 16) | offset: when the frame's last stop bit ended, and where its bytes end. The gap
// interrupt comes a fixed time after that stop bit, so the tag is its time less the gap. Each tag lowers the page's
// capacity, so its tailroom is the room left; a page no frame ends on has none.
enum uint rx_tag_size = 8;

// How full a received page must be, in percent, to call for larger pages; and how little of a small page a large page's
// take must need to go back to small pages.
enum uint rx_fill_threshold = 80;
enum uint rx_resize_takes = 3;
enum uint rx_reserve_pages = 2;

// The frames of a taken chain, read as one series of bytes: each ends at a tag, and bytes after the last tag are a frame
// still arriving. A frame that ended before the chain's first byte shows as an empty first one.
uint uart_burst_count(const(Page)* chain)
{
    uint count;
    UartBurst burst;
    for (BurstWalk walk = BurstWalk(chain); walk.next(burst); )
        ++count;
    return count;
}

UartBurst uart_burst(const(Page)* chain, uint index)
{
    UartBurst burst;
    BurstWalk walk = BurstWalk(chain);
    foreach (i; 0 .. index + 1)
    {
        immutable bool found = walk.next(burst);
        assert(found, "no such burst");
    }
    return burst;
}

private uint rx_tags(const(Page)* page)
    => cast(uint)(page_payload_size(page_category(page)) - page.capacity) / rx_tag_size;

private ulong rx_tag(const(Page)* page, uint index)
    => (cast(const(ulong)*)(cast(const(ubyte)*)page + page_payload_size(page_category(page))))[-1 - cast(int)index];

// the tags of a chain in series order
private struct TagWalk
{
nothrow @nogc:
    const(Page)* page;
    uint index;
    size_t base;

    bool next(out size_t at, out ulong time, out uint ticks)
    {
        while (page && index >= rx_tags(page))
        {
            base += page.length;
            page = (cast(Page*)page).next;
            index = 0;
        }
        if (!page)
            return false;
        immutable ulong tag = rx_tag(page, index++);
        ticks = rx_char_ticks(page);
        at = base + cast(ushort)tag;
        time = tag >> 16;
        return true;
    }
}

private struct BurstWalk
{
nothrow @nogc:
    TagWalk tags;
    size_t total;
    size_t from;

    this(const(Page)* chain)
    {
        tags.page = chain;
        for (const(Page)* page = chain; page; page = (cast(Page*)page).next)
            total += page.length;
    }

    bool next(out UartBurst burst)
    {
        size_t at;
        ulong time;
        uint ticks;
        burst.offset = from;
        if (!tags.next(at, time, ticks))
        {
            burst.length = total - from;
            from = total;
            return burst.length != 0;
        }
        burst.length = at - from;
        burst.gap = true;
        burst.end = rx_rebuild(time);
        burst.start = burst.end - Duration(cast(long)burst.length * ticks);
        from = at;
        TagWalk ahead = tags;
        if (ahead.next(at, time, ticks))
            burst.quiet = rx_rebuild(time) - Duration(cast(long)(at - from) * ticks) - burst.end;
        return true;
    }
}

// a page's character time, stamped when it opened; a frame takes the time of the page it ends on
private uint rx_char_ticks(const(Page)* page)
    => *cast(const(uint)*)(cast(const(ubyte)*)page + page.offset - uint.sizeof);

private MonoTime rx_rebuild(ulong tag48)
{
    enum ulong mask = (ulong(1) << 48) - 1;
    immutable ulong now = getTime().ticks;
    immutable ulong high = (now >> 48) - (tag48 > (now & mask));
    return MonoTime(high << 48 | tag48);
}

struct UartPorts(uint count, uint first, alias tx_idle, alias tx_fill)
{
nothrow @nogc:

    // Pages carry everything the port moves, so it opens only once the page pool is up. A host names the port its
    // callbacks report.
    bool acquire(uint id, ref const UartConfig cfg, ubyte port = ubyte.max)
    {
        if (!page_pool_num_categories())
            return false;
        immutable uint frame = uart_frame_bits(cfg);
        immutable ubyte category = cfg.baud_rate / frame / 50 > rx_room(0) / 2 ? largest() : 0;
        {
            auto guard = section();
            Port* p = &_port[id];
            *p = Port.init;
            p.open = true;
            p.port = port != ubyte.max ? port : cast(ubyte)(id + first);
            p.tx_starved = true;
            p.char_ticks = char_ticks(cfg);
            p.format = line_format(cfg);
            p.rx_category = category;
        }
        page_pool_reserve(category, rx_reserve_pages);
        return true;
    }

    void start(uint id, UartRxCallback rx_cb, UartTxCallback tx_cb, UartRxTiming timing)
    {
        _port[id].rx_cb = rx_cb;
        _port[id].tx_cb = tx_cb;
        retime(id, timing);
    }

    // After the backend applies cfg to the open port: the line's character time and RX timing follow it.
    // A change in how the line is read ends the frame arriving at that moment, and what follows lands in a page of its own,
    // so each page's character time holds for every frame ending on it.
    void reconfigure(uint id, ref const UartConfig cfg, UartRxTiming timing)
    {
        auto guard = section();
        Port* p = &_port[id];
        immutable uint ticks = char_ticks(cfg);
        immutable ubyte format = line_format(cfg);
        if (ticks != p.char_ticks || format != p.format)
        {
            if (p.rx_frame_open)
            {
                p.rx_frame_open = false;
                end_frame(p, getTime().ticks);
            }
            if (p.rx_page && (p.rx_page.length || rx_tags(p.rx_page)))
                close_page(p);
            else if (p.rx_page)
            {
                page_release_isr(p.rx_page);
                p.rx_page = null;
            }
        }
        p.char_ticks = ticks;
        p.format = format;
        retime(id, timing);
    }

    // After the backend reprograms the port: queued TX picks up again.
    void kick(uint id)
    {
        auto guard = section();
        tx_fill(id);
    }

    void retime(uint id, UartRxTiming timing)
    {
        Port* p = &_port[id];
        p.latency_us = timing.latency_us;
        p.gap = timing.gap;
        p.gap_ticks = timing.gap * p.char_ticks / 10;
    }

    // What the driver held, sent or received or not, is released.
    void release(uint id)
    {
        Port* p = &_port[id];
        Page*[4] held;
        ubyte category;
        {
            auto guard = section();
            if (!p.open)
                return;
            held = [ p.tx_queue, p.tx_fill, p.rx_closed, p.rx_page ];
            category = p.rx_category;
            *p = Port.init;
        }
        foreach (chain; held)
        {
            while (chain)
            {
                Page* next = chain.next;
                chain.next = null;
                page_release(chain);
                chain = next;
            }
        }
        page_pool_reserve(category, -cast(int)rx_reserve_pages);
    }

    // TX: the chain becomes the driver's; it goes out behind what was written or sent before it, and each page is
    // released as it is sent.
    bool send(uint id, Page* chain)
    {
        Port* p = &_port[id];
        if (!p.open)
            return false;
        Page* last = chain;
        while (last.next)
            last = last.next;
        auto guard = section();
        if (p.tx_fill)
        {
            enqueue(p, p.tx_fill, p.tx_fill);
            p.tx_fill = null;
        }
        enqueue(p, chain, last);
        p.tx_starved = false;
        tx_fill(id);
        return true;
    }

    // TX from thread context: copies into the page the line takes next, filling it while the line is busy; the ISR
    // takes it when it runs dry.
    size_t write(uint id, const(void)[] data)
    {
        Port* p = &_port[id];
        if (!p.open)
            return 0;
        Page* page;
        {
            auto guard = section();
            page = p.tx_fill;
            p.tx_fill = null;
        }
        Page* full;
        Page* full_last;
        const(ubyte)[] bytes = cast(const(ubyte)[])data;
        size_t total;
        while (bytes.length)
        {
            if (!page || !page.tailroom)
            {
                if (page)
                {
                    if (full_last)
                        full_last.next = page;
                    else
                        full = page;
                    full_last = page;
                }
                page = page_alloc(0, 1, 0, page_payload_size(0) - Page.sizeof);
                if (!page)
                    break;
            }
            immutable size_t n = bytes.length < page.tailroom ? bytes.length : page.tailroom;
            (cast(ubyte*)page)[page.offset + page.length .. page.offset + page.length + n] = bytes[0 .. n];
            page.length += cast(ushort)n;
            bytes = bytes[n .. $];
            total += n;
        }
        auto guard = section();
        if (full)
            enqueue(p, full, full_last);
        p.tx_fill = page;
        if (p.tx_starved)
        {
            p.tx_starved = false;
            tx_fill(id);
        }
        return total;
    }

    // Bytes written or sent that have not yet reached the transmitter FIFO.
    size_t tx_pending(uint id)
    {
        Port* p = &_port[id];
        auto guard = section();
        size_t bytes = p.tx_fill ? p.tx_fill.length : 0;
        for (Page* page = p.tx_queue; page; page = page.next)
            bytes += page.length;
        return bytes;
    }

    bool tx_queued(uint id)
        => _port[id].tx_queue !is null || _port[id].tx_fill !is null;

    // In the ISR or with interrupts off: the next unsent bytes, empty when nothing waits; the written page is taken once
    // the sent ones run out.
    const(ubyte)[] tx_bytes(uint id)
    {
        Port* p = &_port[id];
        while (p.tx_queue && !p.tx_queue.length)
            dequeue_sent(p);
        if (!p.tx_queue && p.tx_fill)
        {
            p.tx_queue = p.tx_tail = p.tx_fill;
            p.tx_fill = null;
        }
        if (!p.tx_queue)
        {
            p.tx_starved = true;
            return null;
        }
        return cast(const(ubyte)[])p.tx_queue.data;
    }

    // In the ISR or with interrupts off: the FIFO took n of tx_bytes; a finished page is released, and its room signalled.
    bool tx_advance(uint id, size_t n)
    {
        Port* p = &_port[id];
        Page* head = p.tx_queue;
        head.offset += cast(ushort)n;
        head.length -= cast(ushort)n;
        p.counters.tx_bytes += n;
        if (head.length)
            return false;
        dequeue_sent(p);
        return p.tx_cb ? p.tx_cb(Uart(p.port), UartCallbackContext.interrupt) : false;
    }

    // Feeds the FIFO itself, so it drains with interrupts masked too, then waits out the last character.
    void drain(uint id)
    {
        immutable deadline = getTime() + tx_drain_limit;
        while (getTime() < deadline)
        {
            auto guard = section();
            tx_fill(id);
            if (!tx_queued(id))
                break;
        }
        while (!tx_idle(id) && getTime() < deadline)
        {}
    }

    // RX, the consumer's side: every page received since the last take, the one still filling included, oldest first.
    // The caller frees them; how full they came back sizes the pages to come.
    Page* rx_take(uint id)
    {
        Port* p = &_port[id];
        Page* closed;
        Page* active;
        {
            auto guard = section();
            if (!p.open)
                return null;
            closed = p.rx_closed;
            active = p.rx_page;
            if (closed && active)
                p.rx_closed_tail.next = active;
            p.rx_closed = p.rx_closed_tail = p.rx_page = null;
        }
        resize(p, closed, active);
        return closed ? closed : active;
    }


    UartRxTiming timing(uint id)
        => UartRxTiming(_port[id].latency_us, _port[id].gap);

    UartCounters counters(uint id)
    {
        auto guard = section();
        return _port[id].counters;
    }

    UartError take_errors(uint id)
    {
        auto guard = section();
        immutable errors = _port[id].errors;
        _port[id].errors = UartError.none;
        return errors;
    }

    // ISR side. A byte with no page to take it is dropped rather than left in the FIFO, where its level interrupt would
    // storm, and reported as an overrun.
    bool receive(uint id, ubyte b)
    {
        Port* p = &_port[id];
        if (!p.open)
            return false;
        Page* page = p.rx_page;
        if (page && !page.tailroom)
        {
            close_page(p);
            page = null;
        }
        if (!page && (page = open_page(p)) is null)
            return false;
        p.rx_frame_open = true;
        ++p.counters.rx_bytes;
        (cast(ubyte*)page)[page.offset + page.length] = b;
        ++page.length;
        return true;
    }

    // ISR side, in the receive timeout's interrupt: the frame before it ended the gap time ago, and whether there was one,
    // for the consumer to hear of. With no room on the page, the tag opens the next one, at its start.
    bool gap(uint id)
    {
        Port* p = &_port[id];
        if (!p.rx_frame_open)
            return false;
        p.rx_frame_open = false;
        end_frame(p, getTime().ticks - p.gap_ticks);
        return true;
    }

    void error(uint id, UartError errors)
    {
        record(&_port[id], errors);
    }

    // interrupts held off on a part; on a host, the lock the I/O thread shares
    auto section()
    {
        static if (irq_max > 0)
            return irq_critical();
        else
            return _lock.acquire();
    }

    bool notify(uint id)
    {
        Port* p = &_port[id];
        return p.rx_cb ? p.rx_cb(Uart(p.port), UartCallbackContext.interrupt) : false;
    }

private:
    struct Port
    {
        Page* tx_queue;
        Page* tx_tail;
        Page* tx_fill;              // written bytes the line takes once tx_queue runs dry; null while a write holds it
        Page* rx_page;
        Page* rx_closed;
        Page* rx_closed_tail;
        UartRxCallback rx_cb;
        UartTxCallback tx_cb;
        UartCounters counters;
        uint char_ticks;
        uint gap_ticks;
        uint latency_us;
        ubyte gap;
        ubyte port;
        UartError errors;
        ubyte rx_category;
        ubyte rx_up;
        ubyte rx_down;
        ubyte format;               // data bits, parity and stop bits: with char_ticks, how the line is read
        bool open;
        bool tx_starved;            // the line ran dry; the next write or send restarts it
        bool rx_frame_open;         // bytes arrived since the last gap
    }

    Port[count] _port;
    static if (irq_max == 0)
        Spinlock _lock;

    static ubyte line_format(ref const UartConfig cfg)
        => cast(ubyte)((cfg.data_bits - 5) | cfg.parity << 2 | cfg.stop_bits << 5);

    static uint char_ticks(ref const UartConfig cfg)
        => cast(uint)nsecs(ulong(uart_frame_bits(cfg)) * 1_000_000_000 / cfg.baud_rate).ticks;

    static ubyte largest()
        => cast(ubyte)(page_pool_num_categories() - 1);

    // the tailroom that fills a page of category with the character time ahead of the bytes
    static size_t rx_room(ubyte category)
        => page_payload_size(category) - page_required_capacity(0, uint.alignof, uint.sizeof, 0);

    static void enqueue(Port* p, Page* chain, Page* last)
    {
        if (p.tx_queue)
            p.tx_tail.next = chain;
        else
            p.tx_queue = chain;
        p.tx_tail = last;
    }

    static void dequeue_sent(Port* p)
    {
        Page* head = p.tx_queue;
        p.tx_queue = head.next;
        if (!p.tx_queue)
            p.tx_tail = null;
        head.next = null;
        page_release_isr(head);
    }

    static void record(Port* p, UartError errors)
    {
        p.errors = cast(UartError)(p.errors | errors);
        p.counters.framing += (errors & UartError.framing) != 0;
        p.counters.parity += (errors & UartError.parity) != 0;
        p.counters.overrun += (errors & UartError.overrun) != 0;
        p.counters.noise += (errors & UartError.noise) != 0;
        p.counters.breaks += (errors & UartError.break_) != 0;
    }

    static Page* open_page(Port* p)
    {
        Page* page = page_alloc_isr(0, uint.alignof, uint.sizeof, rx_room(p.rx_category));
        if (!page)
        {
            record(p, UartError.overrun);
            return null;
        }
        *cast(uint*)(cast(ubyte*)page + page.offset - uint.sizeof) = p.char_ticks;
        p.rx_page = page;
        return page;
    }

    static void close_page(Port* p)
    {
        Page* page = p.rx_page;
        p.rx_page = null;
        if (p.rx_closed)
            p.rx_closed_tail.next = page;
        else
            p.rx_closed = page;
        p.rx_closed_tail = page;
    }

    static void end_frame(Port* p, ulong end)
    {
        Page* page = p.rx_page;
        if (page && page.tailroom < rx_tag_size)
        {
            close_page(p);
            page = null;
        }
        if (!page && (page = open_page(p)) is null)
            return;
        page.capacity -= cast(ushort)rx_tag_size;
        *cast(ulong*)(cast(ubyte*)page + page.capacity) = (end & ((ulong(1) << 48) - 1)) << 16 | page.length;
    }

    static size_t rx_used(const(Page)* page)
        => page.length + rx_tags(page) * rx_tag_size;

    // A page that filled before the take calls for larger pages at once; takes that keep filling most of a page do so
    // after a few; on large pages, takes a small page would have held go back to small ones.
    static void resize(Port* p, Page* closed, Page* active)
    {
        immutable ubyte large = largest();
        ubyte category = p.rx_category;
        bool filled;
        for (Page* page = closed; page && page !is active; page = page.next)
            filled |= rx_used(page) * 100 >= rx_room(page_category(page)) * rx_fill_threshold;
        if (filled)
            category = large;
        else if (active)
        {
            immutable size_t used = rx_used(active);
            if (used * 100 >= rx_room(category) * rx_fill_threshold)
            {
                p.rx_down = 0;
                if (++p.rx_up >= rx_resize_takes)
                    category = large;
            }
            else
            {
                p.rx_up = 0;
                if (category != 0 && used * 100 <= rx_room(0) * rx_fill_threshold && ++p.rx_down >= rx_resize_takes)
                    category = 0;
            }
        }
        if (category == p.rx_category)
            return;
        p.rx_up = p.rx_down = 0;
        page_pool_reserve(category, rx_reserve_pages);
        page_pool_reserve(p.rx_category, -cast(int)rx_reserve_pages);
        p.rx_category = category;
    }
}


unittest
{
    import urt.driver.uart : FlowControl;

    static struct Model
    {
        static __gshared bool stalled, busy;
        static __gshared ubyte[4096] wire;
        static __gshared size_t sent;
        static __gshared UartPorts!(2, 1, idle, fill) ports;
        static __gshared size_t rx_calls, tx_calls;

    nothrow @nogc:
        static void fill(uint id)
        {
            while (!stalled)
            {
                const(ubyte)[] bytes = ports.tx_bytes(id);
                if (!bytes.length)
                    break;
                immutable size_t n = bytes.length < 16 ? bytes.length : 16;
                wire[sent .. sent + n] = bytes[0 .. n];
                sent += n;
                ports.tx_advance(id, n);
            }
        }

        static bool idle(uint id)
            => !busy;

        static bool rx_cb(Uart u, UartCallbackContext)
        {
            assert(u.port == 2);
            ++rx_calls;
            return false;
        }

        static bool tx_cb(Uart u, UartCallbackContext context)
        {
            assert(u.port == 2 && context == UartCallbackContext.interrupt);
            ++tx_calls;
            return false;
        }
    }
    alias ports = Model.ports;
    alias rx_room_of = UartPorts!(2, 1, Model.idle, Model.fill).rx_room;

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();
    immutable ubyte large = cast(ubyte)(page_pool_num_categories() - 1);
    enum bool counted = __traits(compiles, page_pool_stats(0));
    uint in_use()
    {
        static if (counted)
            return page_pool_stats(0).pages_in_use + page_pool_stats(large).pages_in_use;
        else
            return 0;
    }
    immutable uint baseline = in_use();

    Page* make(const(char)[] text)
    {
        Page* page = page_alloc(text.length);
        (cast(char[])page.data)[] = text[];
        return page;
    }

    Page* refused = make("x");
    assert(!ports.send(1, refused) && ports.write(1, "x") == 0, "a closed port takes nothing, and the caller keeps the page");
    page_free(refused);
    assert(ports.rx_take(1) is null && ports.tx_pending(1) == 0);

    UartConfig cfg;
    cfg.baud_rate = 9600;
    assert(ports.acquire(1, cfg));
    ports.start(1, &Model.rx_cb, &Model.tx_cb, UartRxTiming(80, 35));
    assert(ports.timing(1).latency_us == 80);

    // TX: lent pages go out in order and are released as they go, each signalling room
    Page* chain = make("hello ");
    chain.next = make("world");
    assert(ports.send(1, chain) && Model.wire[0 .. 11] == "hello world" && Model.tx_calls == 2, "a running line takes the chain");
    assert(in_use() == baseline, "sent pages are released");

    // written bytes go out at once on an idle line, and gather in one page behind a busy one
    assert(ports.write(1, "abc") == 3 && Model.wire[11 .. 14] == "abc" && in_use() == baseline);
    Model.stalled = true;
    foreach (i; 0 .. 100)
        assert(ports.write(1, "0123") == 4);
    assert(ports.tx_pending(1) == 400 && (!counted || in_use() == baseline + 2), "short writes share pages");
    assert(ports.send(1, make("|lent|")) && ports.write(1, "tail") == 4 && ports.tx_pending(1) == 410);
    Model.busy = true;
    immutable t1 = getTime();
    ports.drain(1);
    assert(getTime() - t1 >= tx_drain_limit && getTime() - t1 < tx_drain_limit + 100.msecs, "a drain against a stalled line is bounded");
    Model.stalled = false;
    Model.busy = false;
    ports.drain(1);
    assert(ports.tx_pending(1) == 0 && in_use() == baseline);
    foreach (i; 0 .. 100)
        assert(Model.wire[14 + i * 4 .. 18 + i * 4] == "0123");
    assert(Model.wire[414 .. 424] == "|lent|tail", "what was written goes out before what was sent after it");

    // RX: a frame ends at its gap, tagged with when its last stop bit ended; bytes after the last tag are a frame arriving
    immutable Duration gap_time = Duration(ports._port[1].gap_ticks);
    Duration chars(size_t n) => Duration(cast(long)n * ports._port[1].char_ticks);
    foreach (ch; "one")
        assert(ports.receive(1, ch));
    ports.notify(1);
    immutable MonoTime before_gap = getTime();
    ports.gap(1);
    ports.notify(1);
    immutable MonoTime after_gap = getTime();
    foreach (ch; "two")
        ports.receive(1, ch);
    ports.gap(1);
    ports.notify(1);
    ports.receive(1, '+');
    ports.notify(1);
    Page* page = ports.rx_take(1);
    assert(page && !page.next && rx_tags(page) == 2 && uart_burst_count(page) == 3);
    UartBurst one = uart_burst(page, 0);
    assert(one.offset == 0 && one.length == 3 && one.gap && cast(const(char)[])page_chain_span(page, 0, 3) == "one");
    assert(one.end + gap_time >= before_gap && one.end + gap_time <= after_gap, "a frame ends the gap time before its gap");
    assert(one.end - one.start == chars(3), "and began its length before that");
    UartBurst two = uart_burst(page, 1);
    assert(two.offset == 3 && two.length == 3 && two.gap && one.end + one.quiet == two.start, "the quiet reaches the next frame's start");
    UartBurst open = uart_burst(page, 2);
    assert(open.offset == 6 && open.length == 1 && !open.gap && !open.end && !two.quiet, "a frame still arriving has no times yet");
    page_free(page);

    ports.gap(1);
    ports.notify(1);
    ports.receive(1, 'r');
    ports.notify(1);
    page = ports.rx_take(1);
    assert(uart_burst_count(page) == 2 && rx_tags(page) == 1);
    UartBurst ends = uart_burst(page, 0);
    assert(ends.length == 0 && ends.gap && ends.end, "a gap after the take ends the frame taken, and keeps its time");
    UartBurst r = uart_burst(page, 1);
    assert(r.offset == 0 && r.length == 1 && !r.gap && cast(const(char)[])page_chain_span(page, 0, 1) == "r");
    page_free(page);
    ports.gap(1);
    page = ports.rx_take(1);
    assert(uart_burst_count(page) == 1 && uart_burst(page, 0).gap && !uart_burst(page, 0).length);
    page_free(page);
    ports.gap(1);
    assert(ports.rx_take(1) is null, "a gap with no frame before it is nothing");
    assert(Model.rx_calls == 6 && ports.take_errors(1) == UartError.none);

    // a frame crossing pages is one frame, read as a series; a page that fills before the take calls for large pages at
    // once, and quiet takes return to small ones
    immutable size_t room = rx_room_of(0);
    foreach (i; 0 .. room + 10)
        ports.receive(1, cast(ubyte)i);
    ports.gap(1);
    ports.receive(1, 'n');
    page = ports.rx_take(1);
    assert(page && page.next && !page.next.next && page_category(page) == 0 && !rx_tags(page));
    assert(uart_burst_count(page) == 2, "a frame a page boundary cuts is still one");
    UartBurst whole = uart_burst(page, 0);
    assert(whole.offset == 0 && whole.length == room + 10 && whole.gap && whole.end - whole.start == chars(room + 10));
    size_t at = 0, pieces;
    while (at < whole.length)
    {
        const(ubyte)[] span = cast(const(ubyte)[])page_chain_span(page, at, whole.length - at);
        assert(span.length && span[0] == cast(ubyte)at);
        at += span.length;
        ++pieces;
    }
    assert(pieces == 2, "its bytes come in a span per page");
    UartBurst n = uart_burst(page, 1);
    assert(n.offset == room + 10 && n.length == 1 && cast(const(char)[])page_chain_span(page, n.offset, 1) == "n");
    page_free(page.next);
    page_free(page);
    foreach (take; 0 .. rx_resize_takes)
    {
        ports.receive(1, 's');
        page = ports.rx_take(1);
        assert(page_category(page) == large);
        page_free(page);
    }
    ports.receive(1, 's');
    page = ports.rx_take(1);
    assert(page_category(page) == 0, "takes a small page would have held go back to small pages");
    page_free(page);

    // a change in how the line is read ends the frame arriving, and each frame keeps the character time it arrived at
    ports.receive(1, 'A');
    ports.gap(1);
    immutable uint slow_ticks = ports._port[1].char_ticks;
    ports.receive(1, 'a');
    UartConfig flow = cfg;
    flow.flow_control = FlowControl.hardware;
    ports.reconfigure(1, flow, UartRxTiming(80, 35));
    assert(ports._port[1].rx_frame_open, "flow control changes nothing a frame is read by");
    UartConfig fast = cfg;
    fast.baud_rate *= 2;
    immutable MonoTime changed = getTime();
    ports.reconfigure(1, fast, UartRxTiming(80, 35));
    assert(!ports.gap(1), "the change ended the frame");
    ports.receive(1, 'B');
    assert(ports.gap(1) && !ports.gap(1), "a gap reports the frame it ends, once");
    page = ports.rx_take(1);
    assert(page_category(page) == 0, "a page closed for a new line rate is not a full one");
    assert(uart_burst_count(page) == 3);
    UartBurst a = uart_burst(page, 0), cut = uart_burst(page, 1), b = uart_burst(page, 2);
    assert(a.end - a.start == Duration(slow_ticks) && cut.length == 1 && cut.gap && cut.end >= changed,
           "the frame arriving at the change ends at the change");
    assert(b.end - b.start == Duration(ports._port[1].char_ticks), "and what follows keeps the new character time");
    page_free(page.next);
    page_free(page);
    ports.reconfigure(1, cfg, UartRxTiming(80, 35));

    ports.error(1, UartError.parity);
    ports.error(1, UartError.framing);
    assert(ports.take_errors(1) == (UartError.parity | UartError.framing) && ports.take_errors(1) == UartError.none);

    Page* hoard;
    while (Page* taken = page_alloc_isr(0, uint.alignof, uint.sizeof, room))
    {
        taken.next = hoard;
        hoard = taken;
    }
    immutable uint overruns = ports.counters(1).overrun;
    assert(!ports.receive(1, 'z') && ports.take_errors(1) == UartError.overrun && ports.counters(1).overrun == overruns + 1,
           "a byte with no page to land in is an overrun, and counted");
    while (hoard)
    {
        Page* next = hoard.next;
        hoard.next = null;
        page_free(hoard);
        hoard = next;
    }

    Model.stalled = true;
    ports.send(1, make("unsent"));
    ports.write(1, "unsent");
    ports.receive(1, 'x');
    Model.stalled = false;
    ports.release(1);
    assert(in_use() == baseline && ports.rx_take(1) is null && ports.tx_pending(1) == 0, "a released port holds nothing");
}
