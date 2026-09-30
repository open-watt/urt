// BL808 inter-core byte rings in XRAM, 16K at 0x40000000 from both cores.
//
// Each channel is a pair of single-producer single-consumer rings, one per direction. A ring is
// 4K: the producer's byte counter on its own cache line, the consumer's on the next, then data.
// Counters run free; the ring index is the counter modulo the capacity. A write rings the peer's
// IPC doorbell with the channel's data bit, a read rings it with the space bit, so neither side
// polls. D0 caches XRAM and M0 does not, so D0 alone cleans and invalidates around each access.
module urt.driver.bl_common.xram;

version (BL808):

import core.volatile : volatileLoad, volatileStore;

import urt.driver.irq : irq_handler_set, irq_line_enable;

nothrow @nogc:

enum uint xram_channels = 2;

enum XramEvent : ubyte
{
    data  = 1 << 0,
    space = 1 << 1,
}

// Called from the doorbell interrupt.
alias XramNotify = void function(uint channel, XramEvent events) nothrow @nogc;

// M0 zeroes every ring before it releases D0; D0 never resets them.
void xram_reset()
{
    foreach (r; 0 .. xram_channels * 2)
    {
        volatileStore(counter(r, producer_offset), 0);
        volatileStore(counter(r, consumer_offset), 0);
    }
}

bool xram_open(uint channel, XramNotify notify)
{
    if (channel >= xram_channels || !notify)
        return false;
    g_notify[channel] = notify;
    if (!g_irq_armed)
    {
        irq_handler_set(local_irq, &doorbell_isr);
        irq_line_enable(local_irq);
        g_irq_armed = true;
    }
    volatileStore(ipc_reg(local_ipc, ipc_unmask), channel_bits(channel));
    return true;
}

void xram_close(uint channel)
{
    if (channel >= xram_channels)
        return;
    volatileStore(ipc_reg(local_ipc, ipc_mask), channel_bits(channel));
    g_notify[channel] = null;
}

size_t xram_rx_pending(uint channel)
{
    uint r = rx_ring(channel);
    return load(r, producer_offset) - load(r, consumer_offset);
}

size_t xram_tx_space(uint channel)
{
    uint r = tx_ring(channel);
    return capacity - (load(r, producer_offset) - load(r, consumer_offset));
}

size_t xram_write(uint channel, const(void)[] data)
{
    uint r = tx_ring(channel);
    uint tail = load(r, producer_offset);
    uint used = tail - load(r, consumer_offset);
    size_t put = data.length < capacity - used ? data.length : capacity - used;
    if (put == 0)
        return 0;

    ubyte* ring = ring_data(r);
    uint at = tail % capacity;
    size_t first = capacity - at < put ? capacity - at : put;
    ring[at .. at + first] = (cast(const(ubyte)[])data)[0 .. first];
    ring[0 .. put - first] = (cast(const(ubyte)[])data)[first .. put];
    clean(ring + at, first);
    clean(ring, put - first);

    store(r, producer_offset, tail + cast(uint)put);
    ring_peer(channel, XramEvent.data);
    return put;
}

size_t xram_read(uint channel, void[] buffer)
{
    uint r = rx_ring(channel);
    uint head = load(r, consumer_offset);
    uint avail = load(r, producer_offset) - head;
    size_t got = buffer.length < avail ? buffer.length : avail;
    if (got == 0)
        return 0;

    ubyte* ring = ring_data(r);
    uint at = head % capacity;
    size_t first = capacity - at < got ? capacity - at : got;
    invalidate(ring + at, first);
    invalidate(ring, got - first);
    (cast(ubyte[])buffer)[0 .. first] = ring[at .. at + first];
    (cast(ubyte[])buffer)[first .. got] = ring[0 .. got - first];

    store(r, consumer_offset, head + cast(uint)got);
    ring_peer(channel, XramEvent.space);
    return got;
}


private:

enum size_t xram_base = 0x4000_0000;
enum uint ring_size = 4096;
enum uint producer_offset = 0x00;
enum uint consumer_offset = 0x40;
enum uint data_offset = 0x80;
enum uint capacity = ring_size - data_offset;
enum size_t cache_line = 64;

static assert(xram_channels * 2 * ring_size <= 16 * 1024);

// IPC blocks: the owner's pending bits, set by the peer writing word 0.
enum size_t ipc_m0 = 0x2000_A800;
enum size_t ipc_d0 = 0x3000_5000;
enum uint ipc_set = 0, ipc_status = 9, ipc_clear = 10, ipc_unmask = 11, ipc_mask = 12;

// Ring 2c carries M0 to D0 on channel c, ring 2c+1 D0 to M0.
version (BL808_M0)
{
    enum size_t local_ipc = ipc_m0, peer_ipc = ipc_d0;
    enum uint local_irq = 16 + 3;
    uint tx_ring(uint channel) => channel * 2;
    uint rx_ring(uint channel) => channel * 2 + 1;
    enum bool cached = false;
}
else
{
    enum size_t local_ipc = ipc_d0, peer_ipc = ipc_m0;
    enum uint local_irq = 16 + 38;
    uint tx_ring(uint channel) => channel * 2 + 1;
    uint rx_ring(uint channel) => channel * 2;
    enum bool cached = true;
}

__gshared XramNotify[xram_channels] g_notify;
__gshared bool g_irq_armed;

uint channel_bits(uint channel)
    => (XramEvent.data | XramEvent.space) << (channel * 2);

uint* ipc_reg(size_t block, uint word)
    => cast(uint*)(block + word * 4);

uint* counter(uint ring, uint offset)
    => cast(uint*)(xram_base + ring * ring_size + offset);

ubyte* ring_data(uint ring)
    => cast(ubyte*)(xram_base + ring * ring_size + data_offset);

uint load(uint ring, uint offset)
{
    invalidate(counter(ring, offset), uint.sizeof);
    uint v = volatileLoad(counter(ring, offset));
    fence();
    return v;
}

void store(uint ring, uint offset, uint value)
{
    fence();
    volatileStore(counter(ring, offset), value);
    clean(counter(ring, offset), uint.sizeof);
}

void ring_peer(uint channel, XramEvent events)
{
    fence();
    volatileStore(ipc_reg(peer_ipc, ipc_set), uint(events) << (channel * 2));
}

void doorbell_isr(uint)
{
    uint pending = volatileLoad(ipc_reg(local_ipc, ipc_status));
    volatileStore(ipc_reg(local_ipc, ipc_clear), pending);
    foreach (c; 0 .. xram_channels)
    {
        XramEvent events = cast(XramEvent)((pending >> (c * 2)) & 3);
        if (events && g_notify[c])
            g_notify[c](c, events);
    }
}

void fence()
{
    asm nothrow @nogc { "fence rw, rw" ::: "memory"; }
}

void clean(const(void)* p, size_t length)
{
    static if (cached)
    {
        for (size_t a = cast(size_t)p & ~(cache_line - 1); a < cast(size_t)p + length; a += cache_line)
            asm nothrow @nogc { "th.dcache.cva %0" :: "r" (a) : "memory"; }
        asm nothrow @nogc { "th.sync.s" ::: "memory"; }
    }
}

void invalidate(const(void)* p, size_t length)
{
    static if (cached)
    {
        for (size_t a = cast(size_t)p & ~(cache_line - 1); a < cast(size_t)p + length; a += cache_line)
            asm nothrow @nogc { "th.dcache.iva %0" :: "r" (a) : "memory"; }
        asm nothrow @nogc { "th.sync.s" ::: "memory"; }
    }
}
