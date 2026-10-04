// BL808 inter-core mailbox: one small ring of short records per direction at the base of XRAM, each send
// ringing the other core's IPC doorbell. A record is a 4-byte header, the id in [5:0] and the payload length
// in [15:8], then its payload, padded to 8 bytes and never split by the end of the ring. The rest of XRAM is
// the shared region, laid out by whoever uses it. D0 caches XRAM and M0 does not, so D0 alone cleans and
// invalidates around each access.
module urt.driver.bl808.ipc;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.irq : irq_critical, irq_handler_set, irq_line_enable;

nothrow @nogc:

enum uint ipc_ids = 64;
enum size_t ipc_max_payload = 60;

// Runs in the doorbell interrupt; payload is a view into XRAM, valid only for the call.
alias IpcHandler = void function(ubyte id, const(void)[] payload) nothrow @nogc;

// Runs in the doorbell interrupt once the peer has drained the ring this core sends on.
alias IpcSpaceHandler = void function() nothrow @nogc;

// Id 0 is the ring's own skip marker. Never blocks: false when the ring has no room, and the peer's next
// drain calls the space handler.
bool ipc_send(ubyte id, const(void)[] payload)
{
    if (id == 0 || id >= ipc_ids || payload.length > ipc_max_payload)
        return false;
    immutable uint size = record_size(payload.length);

    auto guard = irq_critical();
    immutable uint head = load(tx, producer_offset);
    immutable uint used = head - load(tx, consumer_offset);
    immutable uint at = head % ring_capacity;
    immutable uint skip = ring_capacity - at < size ? ring_capacity - at : 0;
    if (ring_capacity - used < skip + size)
        return false;

    ubyte* data = ring_data(tx);
    uint start = head;
    if (skip)
    {
        write_header(at, 0, 0);
        clean(data + at, header_size);
        start += skip;
    }
    immutable uint pos = start % ring_capacity;
    data[pos + header_size .. pos + header_size + payload.length] = cast(const(ubyte)[])payload;
    write_header(pos, id, payload.length);
    clean(data + pos, size);

    store(tx, producer_offset, start + size);
    ring_peer(bit_records);
    return true;
}

void ipc_handle(ubyte id, IpcHandler handler)
{
    if (id == 0 || id >= ipc_ids)
        return;
    {
        auto guard = irq_critical();
        g_handlers[id] = handler;
    }
    arm();
}

void ipc_on_space(IpcSpaceHandler handler)
{
    {
        auto guard = irq_critical();
        g_space = handler;
    }
    arm();
}

// The XRAM above both mailbox rings, 64-aligned; laid out by its users.
enum size_t ipc_shared_size = xram_size - shared_offset;

void[] ipc_shared()
    => (cast(void*)(xram_base + shared_offset))[0 .. ipc_shared_size];

// D0 makes its writes to the shared region visible to M0, and M0's to itself; both do nothing on M0.
void ipc_shared_clean(const(void)[] range)
{
    clean(range.ptr, range.length);
}

void ipc_shared_invalidate(const(void)[] range)
{
    invalidate(range.ptr, range.length);
}

// M0 zeroes all of XRAM before it releases D0; D0 never resets it.
version (BL808_M0)
{
    void ipc_reset()
    {
        for (size_t a = xram_base; a < xram_base + xram_size; a += uint.sizeof)
            volatileStore(cast(uint*)a, 0);
    }
}

private:

enum size_t xram_base = 0x4000_0000;
enum size_t xram_size = 16 * 1024;
enum size_t cache_line = 64;

enum uint header_size = 4;
enum uint ring_capacity = 512;
enum uint producer_offset = 0x00;
enum uint consumer_offset = 0x40;
enum uint data_offset = 0x80;
enum uint ring_stride = data_offset + ring_capacity;
enum size_t shared_offset = 2 * ring_stride;

static assert(record_size(ipc_max_payload) <= cache_line, "a record must fit one cache line");
static assert(shared_offset % cache_line == 0);

enum uint bit_records = 1 << 0;
enum uint bit_space = 1 << 1;

// IPC blocks: the owner's pending bits, set by the peer writing word 0.
enum size_t ipc_m0 = 0x2000_A800;
enum size_t ipc_d0 = 0x3000_5000;
enum uint ipc_set = 0, ipc_status = 9, ipc_clear = 10, ipc_unmask = 11;

// Ring 0 carries M0 to D0, ring 1 D0 to M0.
version (BL808_M0)
{
    enum size_t local_ipc = ipc_m0, peer_ipc = ipc_d0;
    enum uint local_irq = 16 + 3;
    enum uint tx = 0, rx = 1;
    enum bool cached = false;
}
else
{
    enum size_t local_ipc = ipc_d0, peer_ipc = ipc_m0;
    enum uint local_irq = 16 + 38;
    enum uint tx = 1, rx = 0;
    enum bool cached = true;
}

__gshared IpcHandler[ipc_ids] g_handlers;
__gshared IpcSpaceHandler g_space;
__gshared bool g_armed;

uint record_size(size_t payload) pure
    => cast(uint)(header_size + payload + 7) & ~7u;

void arm()
{
    auto guard = irq_critical();
    if (g_armed)
        return;
    irq_handler_set(local_irq, &doorbell_isr);
    irq_line_enable(local_irq);
    volatileStore(ipc_reg(local_ipc, ipc_unmask), bit_records | bit_space);
    g_armed = true;
}

uint* ipc_reg(size_t block, uint word)
    => cast(uint*)(block + word * 4);

uint* counter(uint ring, uint offset)
    => cast(uint*)(xram_base + ring * ring_stride + offset);

ubyte* ring_data(uint ring)
    => cast(ubyte*)(xram_base + ring * ring_stride + data_offset);

void write_header(uint pos, ubyte id, size_t length)
{
    volatileStore(cast(uint*)(ring_data(tx) + pos), uint(id) | cast(uint)length << 8);
}

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

void ring_peer(uint bits)
{
    fence();
    volatileStore(ipc_reg(peer_ipc, ipc_set), bits);
}

void doorbell_isr(uint)
{
    immutable uint pending = volatileLoad(ipc_reg(local_ipc, ipc_status));
    volatileStore(ipc_reg(local_ipc, ipc_clear), pending);

    if (pending & bit_records)
    {
        uint tail = load(rx, consumer_offset);
        immutable uint head = load(rx, producer_offset);
        ubyte* data = ring_data(rx);
        while (tail != head)
        {
            immutable uint pos = tail % ring_capacity;
            invalidate(data + pos, header_size);
            immutable uint header = volatileLoad(cast(uint*)(data + pos));
            immutable ubyte id = header & 0x3F;
            if (id == 0)
            {
                tail += ring_capacity - pos;
                continue;
            }
            immutable size_t length = (header >> 8) & 0xFF;
            invalidate(data + pos, record_size(length));
            if (IpcHandler h = g_handlers[id])
                h(id, (data + pos + header_size)[0 .. length]);
            tail += record_size(length);
        }
        store(rx, consumer_offset, tail);
        ring_peer(bit_space);
    }
    if ((pending & bit_space) && g_space)
        g_space();
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
