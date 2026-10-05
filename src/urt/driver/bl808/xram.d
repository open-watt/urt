// BL808 frame channels: a ring per channel and direction in the cores' shared XRAM, each frame built in place
// and announced as {position, length} through the mailbox. Frames carry no header; a channel carries one kind.
// Opening a channel tells the peer, which drops what remained of the last session and answers; the link is up
// from that answer, or from the peer's own open, until either end closes or reopens.
module urt.driver.bl808.xram;

import core.volatile : volatileLoad, volatileStore;

import urt.atomic;
import urt.driver.bl808.ipc;
import urt.driver.irq : irq_critical;

nothrow @nogc:

enum uint xram_channels = 1;
enum uint xram_frames_in_flight = 32;

// Runs in the doorbell interrupt when frames arrive or the peer releases room.
alias XramNotify = void function(uint channel) nothrow @nogc;

// The largest frame a channel carries: a quarter ring, so three are in flight even across a wrap.
size_t xram_mtu()
    => (ring_capacity / 4) & ~7u;

bool xram_open(uint channel, ubyte frame_id, ubyte space_id, XramNotify notify)
{
    if (channel >= xram_channels)
        return false;
    Channel* c = &g_channels[channel];
    {
        auto guard = irq_critical();
        c.rx_head = c.rx_tail = c.answered = 0;
        c.reserving = c.unannounced = c.linked = c.reopened = false;
        c.pending = 0;
        c.frame_id = frame_id;
        c.space_id = space_id;
        c.notify = notify;
    }
    ipc_handle(frame_id, &on_frame);
    ipc_handle(space_id, &on_space);
    ipc_on_space(&on_mailbox_space);
    Ring tx = Ring(tx_ring(channel));
    c.sent = tx.load(produced);
    c.requested = tx.load(space_requested);

    auto guard = irq_critical();
    drop_received(channel);
    signal(c, Signal.open);
    return true;
}

void xram_close(uint channel)
{
    if (channel >= xram_channels)
        return;
    Channel* c = &g_channels[channel];
    auto guard = irq_critical();
    c.pending = 0;
    signal(c, Signal.close);
    c.notify = null;
    c.reserving = c.unannounced = c.linked = c.reopened = false;
}

// The peer's session: 0 while the link is down, and a new number each time the peer opens. A reopened peer's
// earlier frames are dropped here, so call this before receiving.
uint xram_link(uint channel)
{
    if (channel >= xram_channels)
        return 0;
    Channel* c = &g_channels[channel];
    auto guard = irq_critical();
    if (c.reopened)
    {
        c.reopened = false;
        drop_received(channel);
        link_up(c);
        signal(c, Signal.ack);
    }
    return c.linked ? c.epoch : 0;
}

// Room for two frames of the channel's MTU and a few spare frames: a producer that waits for this leaves room
// for any frame that cannot wait. When there is none, notify runs once the peer releases some.
bool xram_writable(uint channel)
{
    uint start;
    return channel < xram_channels && fits(channel, 2 * xram_mtu(), spare_frames, start);
}

// A frame of up to max_length bytes, 8-aligned in XRAM, to build in place; null when the ring has no room,
// and notify runs once the peer releases some. One reservation at a time per channel.
void[] xram_reserve(uint channel, size_t max_length)
{
    uint start;
    if (channel >= xram_channels || max_length == 0 || max_length > xram_mtu() || !fits(channel, max_length, 0, start))
        return null;
    Channel* c = &g_channels[channel];
    c.start = start;
    c.reserved = cast(uint)max_length;
    c.reserving = true;
    return Ring(tx_ring(channel)).data[offset_of(start) .. offset_of(start) + max_length];
}

// Announces the reserved frame, trimmed to length.
bool xram_post(uint channel, size_t length)
{
    if (channel >= xram_channels)
        return false;
    Channel* c = &g_channels[channel];
    if (!c.reserving || length == 0 || length > c.reserved)
        return false;
    Ring tx = Ring(tx_ring(channel));
    ipc_shared_clean(tx.data[offset_of(c.start) .. offset_of(c.start) + length]);
    c.sent = cursor(frames_of(c.sent) + 1, advance(c.start, round8(length)));
    tx.store(produced, c.sent);

    auto guard = irq_critical();
    c.reserving = false;
    c.announce = [c.start, cast(uint)length];
    c.unannounced = !ipc_send(c.frame_id, c.announce[]);
    return true;
}

void xram_abandon(uint channel)
{
    if (channel < xram_channels)
        g_channels[channel].reserving = false;
}

// The next frame, read in place and valid until xram_release; null when none has arrived.
const(void)[] xram_receive(uint channel)
{
    if (channel >= xram_channels)
        return null;
    Channel* c = &g_channels[channel];
    if (!c.linked)
        return null;
    if (c.rx_tail == atomicLoad(c.rx_head))
        return null;
    immutable uint[2] entry = c.rx_queue[c.rx_tail % xram_frames_in_flight];
    immutable uint offset = offset_of(entry[0]);
    if (offset + entry[1] > ring_capacity)
        return null;
    const(ubyte)[] frame = Ring(rx_ring(channel)).data[offset .. offset + entry[1]];
    ipc_shared_invalidate(frame);
    return frame;
}

void xram_release(uint channel)
{
    if (channel >= xram_channels)
        return;
    Channel* c = &g_channels[channel];
    if (c.rx_tail == atomicLoad(c.rx_head))
        return;
    immutable uint[2] entry = c.rx_queue[c.rx_tail % xram_frames_in_flight];
    ++c.rx_tail;

    Ring rx = Ring(rx_ring(channel));
    c.released = cursor(frames_of(c.released) + 1, advance(entry[0], round8(entry[1])));
    rx.store(consumed, c.released);
    signal_space(channel);
}


private:

// Each ring: the sender's words on one cache line, the receiver's on the next, then the frames. Each side's
// cursor is one word, its frame count over its position, so the peer reads both at once. Positions run modulo
// twice the capacity, so a wrap never breaks the offset sequence and a full ring is told from an empty one. A
// sender out of room bumps its request; the receiver signals space until it has answered the latest. Each side
// keeps its own words in RAM and only writes them through, so an interrupt never invalidates a store D0 has
// yet to clean.
enum size_t cache_line = 64;
enum uint produced = 0, space_requested = 4, consumed = cache_line;
enum uint spare_frames = 4;
enum size_t ring_header = 2 * cache_line;
enum uint ring_stride = cast(uint)((ipc_shared_size / (xram_channels * 2)) & ~(cache_line - 1));
enum uint ring_capacity = cast(uint)(ring_stride - ring_header);

static assert(2 * ring_capacity <= ushort.max + 1);

// A one-byte message on the frame id; announcements are eight.
enum Signal : ubyte { open = 1, ack = 2, close = 4 }

struct Channel
{
    XramNotify notify;
    uint start;
    uint reserved;
    uint sent;
    uint requested;
    uint released;
    uint answered;
    uint epoch;
    uint[2] announce;
    uint[2][xram_frames_in_flight] rx_queue;
    shared uint rx_head;
    uint rx_tail;
    ubyte frame_id, space_id;
    ubyte pending;
    bool reserving, unannounced, linked, reopened;
}

__gshared Channel[xram_channels] g_channels;

// Ring 2c carries M0 to D0 on channel c, ring 2c + 1 D0 to M0.
version (BL808_M0)
{
    uint tx_ring(uint channel) => channel * 2;
    uint rx_ring(uint channel) => channel * 2 + 1;
}
else
{
    uint tx_ring(uint channel) => channel * 2 + 1;
    uint rx_ring(uint channel) => channel * 2;
}

enum uint span = 2 * ring_capacity;

uint round8(size_t length) pure
    => cast(uint)(length + 7) & ~7u;

uint advance(uint position, uint length) pure
{
    immutable uint p = position + length;
    return p >= span ? p - span : p;
}

uint distance(uint from, uint to) pure
    => to >= from ? to - from : to + span - from;

uint offset_of(uint position) pure
    => position >= ring_capacity ? position - ring_capacity : position;

uint cursor(uint frames, uint position) pure
    => frames << 16 | position;

uint frames_of(uint cursor) pure
    => cursor >> 16;

uint position_of(uint cursor) pure
    => cursor & 0xFFFF;

// The request goes up before the second look, and the receiver looks at it after releasing room, so one of
// the two sees the other.
bool fits(uint channel, size_t length, uint spare, out uint start)
{
    Channel* c = &g_channels[channel];
    if (!c.linked || c.pending || c.reserving || c.unannounced)
        return false;
    Ring tx = Ring(tx_ring(channel));
    if (room(c, tx, length, spare, start))
        return true;
    tx.store(space_requested, ++c.requested);
    return room(c, tx, length, spare, start);
}

// The position a frame of length starts at, past any skip to the ring's start, if it fits.
bool room(Channel* c, ref Ring tx, size_t length, uint spare, out uint start)
{
    immutable uint freed = tx.load(consumed);
    if (((frames_of(c.sent) - frames_of(freed)) & 0xFFFF) + spare >= xram_frames_in_flight)
        return false;
    immutable uint head = position_of(c.sent), size = round8(length);
    immutable uint at = offset_of(head);
    immutable uint skip = ring_capacity - at < size ? ring_capacity - at : 0;
    start = advance(head, skip);
    return ring_capacity - distance(position_of(freed), head) >= skip + size;
}

Channel* channel_of(ubyte id, bool frame)
{
    foreach (ref c; g_channels)
        if (c.notify !is null && (frame ? c.frame_id : c.space_id) == id)
            return &c;
    return null;
}

// Discards the peer's frames not yet received, and tells it of the room if it waits on them.
void drop_received(uint channel)
{
    Channel* c = &g_channels[channel];
    c.rx_tail = atomicLoad(c.rx_head);
    Ring rx = Ring(rx_ring(channel));
    c.released = rx.load(produced);
    rx.store(consumed, c.released);
    signal_space(channel);
}

// Tells a sender waiting on room that it has some; a full mailbox leaves it to on_mailbox_space.
void signal_space(uint channel)
{
    Channel* c = &g_channels[channel];
    immutable uint request = Ring(rx_ring(channel)).load(space_requested);
    if (request != c.answered && ipc_send(c.space_id, null))
        c.answered = request;
}

void link_up(Channel* c)
{
    if (c.linked)
        return;
    c.linked = true;
    if (++c.epoch == 0)
        c.epoch = 1;
}

// Under irq_critical. Signals the mailbox cannot take now go in the order sent once it has room.
void signal(Channel* c, Signal s)
{
    ubyte[1] message = [s];
    if (c.pending || !ipc_send(c.frame_id, message[]))
        c.pending |= s;
}

void on_frame(ubyte id, const(void)[] payload)
{
    Channel* c = channel_of(id, true);
    if (c is null)
        return;
    if (payload.length == 1)
    {
        switch (*cast(const(ubyte)*)payload.ptr)
        {
            case Signal.open:
                c.linked = false;
                c.reopened = true;
                break;
            case Signal.ack:
                if (!c.reopened)
                    link_up(c);
                break;
            case Signal.close:
                c.linked = c.reopened = false;
                break;
            default:
                return;
        }
        c.notify(cast(uint)(c - g_channels.ptr));
        return;
    }
    if (payload.length != 2 * uint.sizeof)
        return;
    // a ring or more behind the consumed position is a frame dropped when this session began
    immutable uint[2] entry = *cast(const(uint[2])*)payload.ptr;
    if (entry[0] >= span || entry[1] > ring_capacity || distance(position_of(c.released), entry[0]) >= ring_capacity)
        return;
    immutable uint head = atomicLoad(c.rx_head);
    if (head - c.rx_tail >= xram_frames_in_flight)
        return;
    c.rx_queue[head % xram_frames_in_flight] = entry;
    atomicStore(c.rx_head, head + 1);
    c.notify(cast(uint)(c - g_channels.ptr));
}

void on_space(ubyte id, const(void)[])
{
    if (Channel* c = channel_of(id, false))
        c.notify(cast(uint)(c - g_channels.ptr));
}

void on_mailbox_space()
{
    foreach (i, ref c; g_channels)
    {
        if (c.notify)
            signal_space(cast(uint)i);
        if (!c.pending && !c.unannounced)
            continue;
        foreach (s; [Signal.open, Signal.ack, Signal.close])
        {
            if (!(c.pending & s))
                continue;
            ubyte[1] message = [s];
            if (!ipc_send(c.frame_id, message[]))
                break;
            c.pending &= ~s;
        }
        if (!c.pending && c.unannounced && ipc_send(c.frame_id, c.announce[]))
            c.unannounced = false;
        if (c.notify && !c.pending && !c.unannounced)
            c.notify(cast(uint)i);
    }
}

struct Ring
{
nothrow @nogc:
    ubyte* base;

    this(uint index)
    {
        base = cast(ubyte*)ipc_shared().ptr + index * ring_stride;
    }

    ubyte[] data()
        => (base + ring_header)[0 .. ring_capacity];

    uint load(uint offset)
    {
        uint* p = cast(uint*)(base + offset);
        ipc_shared_invalidate(p[0 .. 1]);
        immutable uint v = volatileLoad(p);
        atomic_fence();
        return v;
    }

    void store(uint offset, uint value)
    {
        uint* p = cast(uint*)(base + offset);
        atomic_fence();
        volatileStore(p, value);
        ipc_shared_clean(p[0 .. 1]);
        atomic_fence();
    }
}
