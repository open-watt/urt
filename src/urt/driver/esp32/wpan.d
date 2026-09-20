// ESP32 IEEE 802.15.4 radio over the ow_shim.c event bridge.
module urt.driver.esp32.wpan;

import urt.atomic : MemoryOrder, atomicExchange, atomicFetchAdd, atomicLoad, atomicStore, cas;
import urt.driver.wpan;
import urt.mem.pagepool : Page, page_alloc, page_release;

nothrow @nogc:


version (ESP32_S31)     enum uint num_wpan = 1;
else version (ESP32_C5) enum uint num_wpan = 1;
else version (ESP32_C6) enum uint num_wpan = 1;
else version (ESP32_H2) enum uint num_wpan = 1;
else                    enum uint num_wpan = 0;


static if (num_wpan > 0):


bool wpan_hw_open(uint port, ref const WpanConfig cfg)
{
    if (port >= num_wpan || _opened)
        return false;

    reset_queues();
    _rx_headroom = cfg.rx_headroom;
    foreach (ref slot; _rx_queue)
    {
        slot.page = alloc_rx_page();
        if (slot.page is null)
        {
            reset_queues();
            return false;
        }
    }
    if (ow_wpan_enable(&wpan_rx_trampoline, &wpan_tx_trampoline) != 0)
    {
        reset_queues();
        return false;
    }

    bool ok = esp_ieee802154_set_channel(cfg.channel) == ESP_OK &&
              esp_ieee802154_set_panid(cfg.pan_id) == ESP_OK &&
              esp_ieee802154_set_short_address(cfg.short_address) == ESP_OK &&
              esp_ieee802154_set_promiscuous(cfg.promiscuous) == ESP_OK &&
              esp_ieee802154_set_rx_when_idle(true) == ESP_OK;
    if (ok && cfg.tx_power != 0)
        ok = esp_ieee802154_set_txpower(cfg.tx_power) == ESP_OK;
    if (ok)
    {
        // the driver starts with no extended address; the factory EUI-64 is only in efuse
        ubyte[8] eui = cfg.extended_address;
        if (eui == typeof(eui).init)
            ok = wpan_hw_get_hardware_address(port, eui);
        if (ok)
            ok = set_extended_address(eui);
    }
    if (ok)
        ok = esp_ieee802154_receive() == ESP_OK;
    if (!ok)
    {
        ow_wpan_disable();
        reset_queues();
        return false;
    }

    _opened = true;
    return true;
}

void wpan_hw_close(uint port)
{
    if (port >= num_wpan || !_opened)
        return;
    _rx_cb = null;
    _tx_cb = null;
    ow_wpan_disable();
    reset_queues();
    _opened = false;
}

bool wpan_hw_set_channel(uint port, ubyte channel)
{
    return port < num_wpan && _opened && esp_ieee802154_set_channel(channel) == ESP_OK;
}

ubyte wpan_hw_get_channel(uint port)
{
    return port < num_wpan && _opened ? esp_ieee802154_get_channel() : 0;
}

bool wpan_hw_set_tx_power(uint port, byte power_dbm)
{
    return port < num_wpan && _opened && esp_ieee802154_set_txpower(power_dbm) == ESP_OK;
}

bool wpan_hw_set_promiscuous(uint port, bool enable)
{
    return port < num_wpan && _opened && esp_ieee802154_set_promiscuous(enable) == ESP_OK;
}

bool wpan_hw_set_pan_id(uint port, ushort pan_id)
{
    return port < num_wpan && _opened && esp_ieee802154_set_panid(pan_id) == ESP_OK;
}

bool wpan_hw_set_short_address(uint port, ushort address)
{
    return port < num_wpan && _opened && esp_ieee802154_set_short_address(address) == ESP_OK;
}

// ESP-IDF takes the extended address in on-air (little-endian) order.
bool wpan_hw_set_extended_address(uint port, ref const ubyte[8] address)
{
    return port < num_wpan && _opened && set_extended_address(address);
}

private bool set_extended_address(ref const ubyte[8] address)
{
    ubyte[8] le = void;
    foreach (i; 0 .. 8)
        le[i] = address[7 - i];
    return esp_ieee802154_set_extended_address(le.ptr) == ESP_OK;
}

bool wpan_hw_get_hardware_address(uint port, ref ubyte[8] address)
{
    return port < num_wpan && esp_read_mac(address.ptr, ESP_MAC_IEEE802154) == ESP_OK;
}

bool wpan_hw_get_extended_address(uint port, ref ubyte[8] address)
{
    if (port >= num_wpan || !_opened)
        return false;
    ubyte[8] le = void;
    if (esp_ieee802154_get_extended_address(le.ptr) != ESP_OK)
        return false;
    foreach (i; 0 .. 8)
        address[i] = le[7 - i];
    return true;
}

bool wpan_hw_tx(uint port, const(ubyte)[] frame, bool cca)
{
    if (port >= num_wpan || !_opened || frame.length == 0 || frame.length > wpan_max_frame - wpan_fcs_length)
        return false;
    if (!cas(&_tx_busy, 0u, 1u))
        return false;
    _tx_frame[0] = cast(ubyte)(frame.length + wpan_fcs_length);
    _tx_frame[1 .. 1 + frame.length] = frame[];
    if (esp_ieee802154_transmit(_tx_frame.ptr, cca) != ESP_OK)
    {
        atomicStore!(MemoryOrder.release)(_tx_busy, 0u);
        return false;
    }
    return true;
}

void wpan_hw_set_rx_callback(uint port, WpanRxCallback cb)
{
    if (port < num_wpan && _opened)
        _rx_cb = cb;
}

void wpan_hw_set_tx_callback(uint port, WpanTxCallback cb)
{
    if (port < num_wpan && _opened)
        _tx_cb = cb;
}

void wpan_hw_set_ready_callback(WpanReadyCallback cb)
{
    atomicStore!(MemoryOrder.seq)(_ready_cb_bits, cast(size_t)cb);
    if (cb !is null)
        cb();
}

uint wpan_hw_take_rx_drops(uint port)
{
    return port < num_wpan && _opened ? atomicExchange!(MemoryOrder.relaxed)(&_rx_drops, 0u) : 0;
}

bool wpan_hw_service(uint port, size_t budget)
{
    if (port >= num_wpan || !_opened)
        return false;
    if (_servicing)
        return queues_pending();

    _servicing = true;
    uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
    Wpan w = Wpan(cast(ubyte)port);
    size_t serviced;

    while (serviced < budget && generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
    {
        bool rx_first = _rx_next;
        _rx_next = !_rx_next;
        bool dispatched = rx_first ? dispatch_one_rx(w) || dispatch_one_tx(w)
                                   : dispatch_one_tx(w) || dispatch_one_rx(w);
        if (!dispatched)
            break;
        ++serviced;
    }

    _servicing = false;
    return queues_pending();
}

private:

enum int ESP_OK = 0;
enum int ESP_MAC_IEEE802154 = 4;

struct QueuedRx
{
    Page* page;
    WpanRxInfo info;
}

struct QueuedAck
{
    ubyte[wpan_max_frame] data;
    ubyte length;
    WpanRxInfo info;
}
enum size_t rx_cap = 16;
__gshared QueuedRx[rx_cap] _rx_queue;
shared uint _rx_head;
shared uint _rx_tail;
shared uint _rx_drops;

// One frame in flight; its completion is a single slot rather than a ring.
__gshared ubyte[1 + wpan_max_frame] _tx_frame;
__gshared QueuedAck _tx_ack;
__gshared WpanTxError _tx_error;
shared uint _tx_busy;
shared uint _tx_done;

__gshared bool _opened;
__gshared bool _servicing;
__gshared bool _rx_next;
__gshared ushort _rx_headroom;
__gshared WpanRxCallback _rx_cb;
__gshared WpanTxCallback _tx_cb;
shared size_t _ready_cb_bits;
shared uint _queue_generation;

void reset_queues()
{
    foreach (ref slot; _rx_queue)
    {
        if (slot.page !is null)
            page_release(slot.page);
        slot.page = null;
    }
    _rx_next = false;
    atomicFetchAdd!(MemoryOrder.acq_rel)(_queue_generation, 1u);
    atomicStore!(MemoryOrder.relaxed)(_rx_head, 0u);
    atomicStore!(MemoryOrder.relaxed)(_rx_tail, 0u);
    atomicStore!(MemoryOrder.relaxed)(_rx_drops, 0u);
    atomicStore!(MemoryOrder.relaxed)(_tx_done, 0u);
    atomicStore!(MemoryOrder.relaxed)(_tx_busy, 0u);
}

bool queues_pending()
{
    return atomicLoad!(MemoryOrder.acquire)(_rx_head) != atomicLoad!(MemoryOrder.relaxed)(_rx_tail) ||
           atomicLoad!(MemoryOrder.acquire)(_tx_done) != 0;
}

void notify_ready()
{
    auto cb = cast(WpanReadyCallback)atomicLoad!(MemoryOrder.seq)(_ready_cb_bits);
    if (cb !is null)
        cb();
}

bool dispatch_one_rx(Wpan wpan)
{
    uint tail = atomicLoad!(MemoryOrder.relaxed)(_rx_tail);
    if (tail == atomicLoad!(MemoryOrder.acquire)(_rx_head))
        return false;
    ref slot = _rx_queue[tail & (rx_cap - 1)];
    Page* frame;
    WpanRxInfo info = slot.info;
    if (_rx_cb !is null)
    {
        // Replenish in task context; the ISR only writes into reserved pages.
        Page* replacement = alloc_rx_page();
        if (replacement !is null)
        {
            frame = slot.page;
            slot.page = replacement;
        }
        else
            atomicFetchAdd!(MemoryOrder.relaxed)(_rx_drops, 1u);
    }
    atomicStore!(MemoryOrder.release)(_rx_tail, tail + 1);
    if (frame !is null)
        _rx_cb(wpan, frame, info);
    return true;
}

Page* alloc_rx_page()
    => page_alloc(wpan_max_frame - wpan_fcs_length, 8, _rx_headroom);

bool dispatch_one_tx(Wpan wpan)
{
    if (atomicLoad!(MemoryOrder.acquire)(_tx_done) == 0)
        return false;
    WpanTxError error = _tx_error;
    QueuedAck ack = _tx_ack;
    atomicStore!(MemoryOrder.release)(_tx_done, 0u);
    // released before the callback so it may submit the next frame
    atomicStore!(MemoryOrder.release)(_tx_busy, 0u);
    if (_tx_cb !is null)
        _tx_cb(wpan, error, ack.data[0 .. ack.length], ack.info);
    return true;
}

// Copies out of the driver's buffer; the shim releases it when this returns.
extern(C) void wpan_rx_trampoline(const(ubyte)* frame, byte rssi, ubyte lqi, ubyte channel, int pending)
{
    if (frame is null)
        return;
    uint length = frame[0];
    if (length < wpan_fcs_length || length > wpan_max_frame)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_rx_drops, 1u);
        notify_ready();
        return;
    }
    length -= wpan_fcs_length;

    uint head = atomicLoad!(MemoryOrder.relaxed)(_rx_head);
    uint tail = atomicLoad!(MemoryOrder.acquire)(_rx_tail);
    if (head - tail >= rx_cap)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_rx_drops, 1u);
        notify_ready();
        return;
    }

    auto slot = &_rx_queue[head & (rx_cap - 1)];
    slot.page.length = cast(ushort)length;
    (cast(ubyte[])slot.page.data)[] = frame[1 .. 1 + length];
    slot.info.rssi = rssi;
    slot.info.lqi = lqi;
    slot.info.channel = channel;
    slot.info.ack_pending = pending != 0;
    atomicStore!(MemoryOrder.release)(_rx_head, head + 1);
    notify_ready();
}

extern(C) void wpan_tx_trampoline(int error, const(ubyte)* ack, byte rssi, ubyte lqi, ubyte channel)
{
    _tx_error = error >= 0 && error <= WpanTxError.security ? cast(WpanTxError)error : WpanTxError.internal;
    _tx_ack.length = 0;
    _tx_ack.info = WpanRxInfo.init;
    if (ack !is null)
    {
        uint length = ack[0];
        if (length >= wpan_fcs_length && length <= wpan_max_frame)
        {
            length -= wpan_fcs_length;
            _tx_ack.length = cast(ubyte)length;
            _tx_ack.data[0 .. length] = ack[1 .. 1 + length];
            _tx_ack.info.rssi = rssi;
            _tx_ack.info.lqi = lqi;
            _tx_ack.info.channel = channel;
            _tx_ack.info.ack_pending = false;
        }
    }
    atomicStore!(MemoryOrder.release)(_tx_done, 1u);
    notify_ready();
}

extern(C) nothrow @nogc
{
    int ow_wpan_enable(void function(const(ubyte)*, byte, ubyte, ubyte, int) nothrow @nogc rx,
                       void function(int, const(ubyte)*, byte, ubyte, ubyte) nothrow @nogc tx);
    void ow_wpan_disable();

    int esp_ieee802154_set_channel(ubyte channel);
    ubyte esp_ieee802154_get_channel();
    int esp_ieee802154_set_txpower(byte power);
    int esp_ieee802154_set_promiscuous(bool enable);
    int esp_ieee802154_set_panid(ushort panid);
    int esp_ieee802154_set_short_address(ushort address);
    int esp_ieee802154_get_extended_address(ubyte* ext_addr);
    int esp_ieee802154_set_extended_address(const(ubyte)* ext_addr);
    int esp_ieee802154_set_rx_when_idle(bool enable);
    int esp_ieee802154_receive();
    int esp_ieee802154_transmit(const(ubyte)* frame, bool cca);
    int esp_read_mac(ubyte* mac, int type);
}
