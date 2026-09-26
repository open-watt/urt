// ESP32 EMAC over the ow_shim.c bridge. Frames arrive on the esp_eth receive task and link
// events on the event loop task; both are queued here and delivered by eth_hw_service.
module urt.driver.esp32.ethernet;

import urt.atomic : MemoryOrder, atomicExchange, atomicFetchAdd, atomicLoad, atomicStore;
import urt.driver.ethernet;

nothrow @nogc:


version (UseEthernet)
{
    version (ESP32)          enum uint num_ethernet = 1;
    else version (ESP32_P4)  enum uint num_ethernet = 1;
    else version (ESP32_S31) enum uint num_ethernet = 1;
    else                     enum uint num_ethernet = 0;
}
else
    enum uint num_ethernet = 0;

// The classic ESP32 runs RMII on fixed pads with no 1588 unit; the P4 and S31 route
// the data plane through IO_MUX and timestamp in the MAC, and the S31 adds RGMII.
version (ESP32_P4)       enum bool emac_v2 = true;
else version (ESP32_S31) enum bool emac_v2 = true;
else                     enum bool emac_v2 = false;
version (ESP32_S31) enum bool has_eth_gigabit = num_ethernet > 0;
else                enum bool has_eth_gigabit = false;

enum bool has_eth_timestamp = num_ethernet > 0 && emac_v2;
enum bool has_eth_pin_select = num_ethernet > 0 && emac_v2;
// Insertion needs store-and-forward, so the whole frame has to fit the transmit FIFO.
version (ESP32_P4)       enum size_t emac_tx_fifo = 256;
else version (ESP32_S31) enum size_t emac_tx_fifo = 1024;
else                     enum size_t emac_tx_fifo = 2048;
enum bool has_eth_tx_checksum = num_ethernet > 0 && emac_tx_fifo >= eth_max_frame;


static if (num_ethernet > 0):


uint eth_hw_ports(uint mac)
    => 1;

bool eth_hw_open(uint mac, uint port, ref const EthernetConfig cfg, EthRxCallback rx, EthLinkCallback link, void* context)
{
    if (mac >= num_ethernet || _opened)
        return false;

    ow_eth_config_t c;
    c.phy = cfg.phy;
    c.phy_addr = cfg.phy_address;
    c.mdc_gpio = cfg.mdc_gpio;
    c.mdio_gpio = cfg.mdio_gpio;
    c.phy_reset_gpio = cfg.phy_reset_gpio;
    c.phy_interface = cfg.phy_interface;
    c.clock_mode = cfg.clock_mode;
    c.clock_gpio = cfg.clock_gpio;
    c.clock_loopback_gpio = cfg.clock_loopback_gpio;
    c.data_gpio = cfg.data_gpio;
    c.promiscuous = cfg.promiscuous;
    c.flow_control = cfg.flow_control;
    c.timestamp = cfg.timestamp;
    c.tx_checksum = cfg.tx_checksum;

    reset_queues();
    _timestamps = cfg.timestamp;
    _tx_checksum = cfg.tx_checksum;
    if (ow_eth_open(&c, &eth_rx_trampoline, &eth_link_trampoline) != 0)
        return false;
    _rx_cb = rx;
    _link_cb = link;
    _context = context;
    _opened = true;
    return true;
}

bool eth_hw_close(uint mac, uint port)
{
    if (!is_active(mac))
        return true;
    if (ow_eth_close() != 0)
        return false;
    reset_queues();
    _rx_cb = null;
    _link_cb = null;
    _opened = false;
    return true;
}

bool eth_hw_tx(uint mac, uint port, const(ubyte)[] frame, bool insert_checksum)
    => (insert_checksum ? eth_hw_checksum_insertable(mac, port, frame) : is_active(mac)) && ow_eth_tx(frame.ptr, cast(uint)frame.length, insert_checksum) == 0;

bool eth_hw_checksum_insertable(uint mac, uint port, const(ubyte)[] frame)
    => is_active(mac) && _tx_checksum && engine_checksums(frame);

bool eth_hw_get_hardware_address(uint mac, uint port, ref ubyte[6] address)
{
    return esp_read_mac(address.ptr, ESP_MAC_ETH) == ESP_OK;
}

bool eth_hw_set_address(uint mac, uint port, ref const ubyte[6] address)
{
    return is_active(mac) && ow_eth_set_mac(address.ptr) == 0;
}

bool eth_hw_set_promiscuous(uint mac, uint port, bool enable)
{
    return is_active(mac) && ow_eth_set_promiscuous(enable) == 0;
}

bool eth_hw_get_link(uint mac, uint port, ref EthLinkInfo info)
{
    int speed, full_duplex;
    if (!is_active(mac) || ow_eth_get_link(&speed, &full_duplex) != 0)
        return false;
    info.speed = cast(EthSpeed)speed;
    info.full_duplex = full_duplex != 0;
    return true;
}

bool eth_hw_set_link_mode(uint mac, uint port, bool autonegotiate, EthSpeed speed, bool full_duplex)
{
    return is_active(mac) && ow_eth_set_link_mode(autonegotiate, speed, full_duplex) == 0;
}

void eth_hw_set_ready_callback(EthReadyCallback cb)
{
    atomicStore!(MemoryOrder.seq)(_ready_cb_bits, cast(size_t)cb);
    if (cb !is null)
        cb();
}

uint eth_hw_take_rx_drops(uint mac, uint port)
{
    return is_active(mac) ? atomicExchange!(MemoryOrder.relaxed)(&_rx_drops, 0u) : 0;
}

bool eth_hw_service(uint mac, size_t budget)
{
    if (!is_active(mac))
        return false;
    if (_servicing)
        return queues_pending();

    _servicing = true;
    uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
    size_t serviced;

    while (serviced < budget && generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
    {
        if (!dispatch_link() && !dispatch_one_rx())
            break;
        ++serviced;
    }

    _servicing = false;
    return queues_pending();
}

static if (has_eth_timestamp)
{
    bool eth_hw_get_time(uint mac, ref EthTime time)
    {
        return is_active(mac) && _timestamps && ow_eth_get_time(&time.seconds, &time.nanoseconds) == 0;
    }

    bool eth_hw_set_time(uint mac, ref const EthTime time)
    {
        return is_active(mac) && _timestamps && ow_eth_set_time(time.seconds, time.nanoseconds) == 0;
    }

    bool eth_hw_adjust_frequency(uint mac, int ppb)
    {
        return is_active(mac) && _timestamps && ow_eth_adjust_frequency(ppb) == 0;
    }
}

private:

enum int ESP_OK = 0;
enum int ESP_MAC_ETH = 3;

// Mirrors ow_eth_config_t in ow_shim.c.
struct ow_eth_config_t
{
    ubyte phy;
    byte phy_addr;
    byte mdc_gpio;
    byte mdio_gpio;
    byte phy_reset_gpio;
    ubyte phy_interface;
    ubyte clock_mode;
    byte clock_gpio;
    byte clock_loopback_gpio;
    byte[12] data_gpio;
    bool promiscuous;
    bool flow_control;
    bool timestamp;
    bool tx_checksum;
}

// Each queued frame owns the heap buffer supplied by esp_eth.
struct QueuedRx
{
    ubyte* buffer;
    EthTime timestamp;
    ushort length;
    bool has_timestamp;
}
static assert(QueuedRx.sizeof == 16);
enum size_t rx_cap = 64;
__gshared QueuedRx[rx_cap] _rx_queue;
shared uint _rx_head;
shared uint _rx_tail;
shared uint _rx_drops;

// link transitions coalesce: only the latest state matters to the consumer
shared uint _link_state;
shared uint _link_changed;

__gshared bool _opened;
__gshared bool _servicing;
__gshared bool _timestamps;
__gshared bool _tx_checksum;
__gshared EthRxCallback _rx_cb;
__gshared EthLinkCallback _link_cb;
__gshared void* _context;
shared size_t _ready_cb_bits;
shared uint _queue_generation;

bool is_active(uint mac)
{
    return mac < num_ethernet && _opened;
}

// IDF hides descriptor checksum status; only classify layouts its engine covers.
bool engine_checksums(const(ubyte)[] frame) pure
{
    size_t at = frame.length >= 18 && frame[12] == 0x81 && frame[13] == 0x00 ? 16 : 12;
    if (frame.length < at + 2)
        return false;
    const(ubyte)[] ip = frame[at + 2 .. $];
    if (frame[at] == 0x08 && frame[at + 1] == 0x00)
        return ip.length >= 20 && ip[0] == 0x45 && ((ip[6] & 0x3F) | ip[7]) == 0 && (ip[9] == 6 || ip[9] == 17);
    return frame[at] == 0x86 && frame[at + 1] == 0xDD && ip.length >= 40 && ip[0] >> 4 == 6 && (ip[6] == 6 || ip[6] == 17);
}

// Only called with the MAC stopped, so no producer races the drain.
void reset_queues()
{
    atomicFetchAdd!(MemoryOrder.acq_rel)(_queue_generation, 1u);
    uint head = atomicLoad!(MemoryOrder.acquire)(_rx_head);
    for (uint tail = atomicLoad!(MemoryOrder.relaxed)(_rx_tail); tail != head; ++tail)
        ow_eth_free(_rx_queue[tail & (rx_cap - 1)].buffer);
    atomicStore!(MemoryOrder.relaxed)(_rx_head, 0u);
    atomicStore!(MemoryOrder.relaxed)(_rx_tail, 0u);
    atomicStore!(MemoryOrder.relaxed)(_rx_drops, 0u);
    atomicStore!(MemoryOrder.relaxed)(_link_state, 0u);
    atomicStore!(MemoryOrder.relaxed)(_link_changed, 0u);
}

bool queues_pending()
{
    return atomicLoad!(MemoryOrder.acquire)(_rx_head) != atomicLoad!(MemoryOrder.relaxed)(_rx_tail) || atomicLoad!(MemoryOrder.acquire)(_link_changed) != 0;
}

void notify_ready()
{
    auto cb = cast(EthReadyCallback)atomicLoad!(MemoryOrder.seq)(_ready_cb_bits);
    if (cb !is null)
        cb();
}

bool dispatch_link()
{
    if (atomicExchange!(MemoryOrder.acq_rel)(&_link_changed, 0u) == 0)
        return false;
    if (_link_cb !is null)
        _link_cb(_context, atomicLoad!(MemoryOrder.acquire)(_link_state) != 0 ? EthLinkEvent.up : EthLinkEvent.down);
    return true;
}

// Dequeue before callbacks: close may drain the queue.
bool dispatch_one_rx()
{
    uint tail = atomicLoad!(MemoryOrder.relaxed)(_rx_tail);
    if (tail == atomicLoad!(MemoryOrder.acquire)(_rx_head))
        return false;
    QueuedRx frame = _rx_queue[tail & (rx_cap - 1)];
    atomicStore!(MemoryOrder.release)(_rx_tail, tail + 1);
    if (_rx_cb !is null)
    {
        const(ubyte)[] data = frame.buffer[0 .. frame.length];
        EthRxInfo info = EthRxInfo(frame.timestamp, frame.has_timestamp, engine_checksums(data));
        _rx_cb(_context, data, info);
    }
    ow_eth_free(frame.buffer);
    return true;
}

extern(C) void eth_rx_trampoline(ubyte* buffer, uint length, uint seconds, uint nanoseconds, int has_timestamp)
{
    uint head = atomicLoad!(MemoryOrder.relaxed)(_rx_head);
    uint tail = atomicLoad!(MemoryOrder.acquire)(_rx_tail);
    if (length > ushort.max || head - tail >= rx_cap)
    {
        ow_eth_free(buffer);
        atomicFetchAdd!(MemoryOrder.relaxed)(_rx_drops, 1u);
        notify_ready();
        return;
    }

    auto slot = &_rx_queue[head & (rx_cap - 1)];
    slot.buffer = buffer;
    slot.length = cast(ushort)length;
    slot.timestamp = EthTime(seconds, nanoseconds);
    slot.has_timestamp = has_timestamp != 0;
    atomicStore!(MemoryOrder.release)(_rx_head, head + 1);
    notify_ready();
}

extern(C) void eth_link_trampoline(int up)
{
    atomicStore!(MemoryOrder.release)(_link_state, up != 0 ? 1u : 0u);
    atomicStore!(MemoryOrder.release)(_link_changed, 1u);
    notify_ready();
}

extern(C) nothrow @nogc
{
    int ow_eth_open(const(ow_eth_config_t)* config, void function(ubyte*, uint, uint, uint, int) nothrow @nogc rx, void function(int) nothrow @nogc link);
    int ow_eth_close();
    int ow_eth_tx(const(ubyte)* frame, uint length, bool insert_checksum);
    void ow_eth_free(void* buffer);
    int ow_eth_set_mac(const(ubyte)* mac);
    int ow_eth_set_promiscuous(bool enable);
    int ow_eth_get_link(int* speed, int* full_duplex);
    int ow_eth_set_link_mode(bool autonegotiate, int speed, bool full_duplex);
    int ow_eth_get_time(uint* seconds, uint* nanoseconds);
    int ow_eth_set_time(uint seconds, uint nanoseconds);
    int ow_eth_adjust_frequency(int ppb);

    int esp_read_mac(ubyte* mac, int type);
}

unittest
{
    ubyte[74] frame;
    frame[12] = 0x08;
    frame[14] = 0x45;
    frame[23] = 17;
    assert(engine_checksums(frame[]));
    frame[20] = 0x20;
    assert(!engine_checksums(frame[]));
    frame[20] = 0;
    frame[14] = 0x46;
    assert(!engine_checksums(frame[]));

    frame[] = 0;
    frame[12] = 0x86;
    frame[13] = 0xDD;
    frame[14] = 0x60;
    frame[20] = 17;
    assert(engine_checksums(frame[]));
    frame[14] = 0x40;
    assert(!engine_checksums(frame[]));
    frame[14] = 0x60;
    frame[20] = 0;
    assert(!engine_checksums(frame[]));
    frame[20] = 17;
    foreach (length; 0 .. 54)
        assert(!engine_checksums(frame[0 .. length]));

    for (size_t i = 62; i-- > 14; )
        frame[i + 4] = frame[i];
    frame[12] = 0x81;
    frame[13] = 0x00;
    frame[16] = 0x86;
    frame[17] = 0xDD;
    assert(engine_checksums(frame[]));
    frame[12] = 0x88;
    frame[13] = 0xA8;
    assert(!engine_checksums(frame[]));
    frame[12] = 0x81;
    frame[13] = 0;
    frame[16] = 0x81;
    frame[17] = 0;
    assert(!engine_checksums(frame[]));
}
