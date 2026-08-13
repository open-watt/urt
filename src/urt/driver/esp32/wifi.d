// ESP32 WiFi driver -- D wrapper over C shim + direct ESP-IDF calls
//
// The C shim (ow_shim.c) handles:
//   - ow_wifi_init/deinit: WIFI_INIT_CONFIG_DEFAULT macro, netif creation,
//     event handler registration
//   - ow_wifi_sta_config/ap_config: wifi_config_t struct construction
//   - ow_wifi_set_rx_callback: RX trampolines that queue frames for D AND
//     forward to esp_netif_receive (so lwIP still works)
//
// Everything else (mode, connect, disconnect, tx, mac, channel, power)
// calls ESP-IDF directly.
//
// ESP32 has one WiFi port (port 0).
module urt.driver.esp32.wifi;

import urt.atomic : MemoryOrder, atomicExchange, atomicFetchAdd, atomicLoad, atomicStore;
import urt.driver.wifi;

nothrow @nogc:


version (ESP32)         enum uint num_wifi = 1;
else version (ESP32_S2) enum uint num_wifi = 1;
else version (ESP32_S3) enum uint num_wifi = 1;
else version (ESP32_C2) enum uint num_wifi = 1;
else version (ESP32_C3) enum uint num_wifi = 1;
else version (ESP32_C5) enum uint num_wifi = 1;
else version (ESP32_C6) enum uint num_wifi = 1;
else                    enum uint num_wifi = 0; // H2 (BT/802.15.4 only), P4 (needs external)

version (ESP32_C5) version = DualBandRadio;

enum ubyte wifi_max_ap_clients = 10;


static if (num_wifi > 0):


bool wifi_hw_open(uint port, ref const WifiConfig cfg)
{
    if (port >= num_wifi || _opened)
        return false;

    reset_queues();
    if (ow_wifi_init() != 0)
        return false;

    ow_wifi_set_sta_callback(&sta_event_trampoline);
    ow_wifi_set_ap_callback(&ap_event_trampoline);

    if (cfg.tx_power != 0)
        esp_wifi_set_max_tx_power(cfg.tx_power);

    if (esp_wifi_start() != ESP_OK)
    {
        ow_wifi_deinit();
        return false;
    }

    version (DualBandRadio)
    {
        int band_mode = cfg.band == WifiBand._2_4ghz ? WIFI_BAND_MODE_2G_ONLY
                      : cfg.band == WifiBand._5ghz   ? WIFI_BAND_MODE_5G_ONLY
                      :                                WIFI_BAND_MODE_AUTO;
        if (esp_wifi_set_band_mode(band_mode) != ESP_OK)
        {
            esp_wifi_stop();
            ow_wifi_deinit();
            return false;
        }
    }

    _opened = true;
    return true;
}

void wifi_hw_close(uint port)
{
    if (!_opened)
        return;
    _event_cb = null;
    _rx_cb = null;
    _raw_rx_cb = null;
    ow_wifi_set_rx_callback(null);
    ow_wifi_set_sta_callback(null);
    ow_wifi_set_ap_callback(null);
    ow_wifi_set_promiscuous_callback(null);
    ow_wifi_set_promiscuous(0, 0);
    reset_queues();
    esp_wifi_stop();
    ow_wifi_deinit();
    _opened = false;
}

bool wifi_hw_set_mode(uint port, WifiMode mode)
{
    // ESP-IDF treats promiscuous as a flag orthogonal to STA/AP, so monitor
    // here means "STA mode (radio on, channel controllable) with promiscuous
    // enabled later via wifi_hw_set_raw_rx_callback". The driver brings the
    // radio up in STA so esp_wifi_set_channel is accepted; without STA, the
    // channel setter rejects the call with WIFI_NOT_INIT_OR_NOT_STARTED.
    int hw_mode = mode == WifiMode.monitor
        ? 1   // STA -- minimum mode that lets us set channel + enable promisc
        : (mode == WifiMode.none   ? 0
        :  mode == WifiMode.sta    ? 1
        :  mode == WifiMode.ap     ? 2
        :                            3);  // apsta
    return esp_wifi_set_mode(hw_mode) == ESP_OK;
}

bool wifi_hw_sta_configure(uint port, ref const WifiStaConfig cfg)
{
    _sta_status_message = null;

    if (cfg.ssid.length > 32)
    {
        _sta_status_message = "STA SSID is too long";
        return false;
    }
    if (cfg.password.length > 64)
    {
        _sta_status_message = "STA password is too long";
        return false;
    }
    if (cfg.pmf_required)
    {
        _sta_status_message = "STA PMF required is not supported";
        return false;
    }

    // Stack buffers for null-termination (SSID max 32, password max 64)
    char[33] ssid_z = 0;
    char[65] pw_z = 0;

    if (cfg.ssid.length > 0 && cfg.ssid.length <= 32)
        ssid_z[0 .. cfg.ssid.length] = cfg.ssid[];
    if (cfg.password.length > 0 && cfg.password.length <= 64)
        pw_z[0 .. cfg.password.length] = cfg.password[];

    bool has_bssid = cfg.bssid != typeof(cfg.bssid).init;

    if (ow_wifi_sta_config(
        cfg.ssid.length > 0 ? ssid_z.ptr : null,
        cfg.password.length > 0 ? pw_z.ptr : null,
        has_bssid ? cfg.bssid.ptr : null) == 0)
    {
        _sta_status_message = "STA config rejected by ESP-IDF";
        return false;
    }

    return true;
}

const(char)[] wifi_hw_sta_status_message(uint port)
{
    if (_sta_status_message.length != 0)
        return _sta_status_message;
    return esp_wifi_sta_reason_message(
        atomicLoad!(MemoryOrder.acquire)(_sta_disconnect_reason));
}

bool wifi_hw_sta_connect(uint port)
{
    _sta_status_message = null;
    atomicStore!(MemoryOrder.release)(_sta_disconnect_reason, 0);
    auto rc = esp_wifi_connect();
    if (rc == ESP_OK)
        return true;
    _sta_status_message = esp_wifi_error_message(rc);
    return false;
}

bool wifi_hw_sta_disconnect(uint port)
{
    return esp_wifi_disconnect() == ESP_OK;
}

bool wifi_hw_ap_configure(uint port, ref const WifiApConfig cfg)
{
    char[33] ssid_z = 0;
    char[65] pw_z = 0;

    if (cfg.ssid.length > 0 && cfg.ssid.length <= 32)
        ssid_z[0 .. cfg.ssid.length] = cfg.ssid[];
    if (cfg.password.length > 0 && cfg.password.length <= 64)
        pw_z[0 .. cfg.password.length] = cfg.password[];

    return ow_wifi_ap_config(
        cfg.ssid.length > 0 ? ssid_z.ptr : null,
        cfg.password.length > 0 ? pw_z.ptr : null,
        cfg.channel, cfg.max_clients, cfg.hidden ? 1 : 0) != 0;
}

bool wifi_hw_ap_set_max_clients(uint port, ubyte max_clients)
{
    if (port != 0 || max_clients > wifi_max_ap_clients)
        return false;
    return ow_wifi_ap_set_max_clients(max_clients) != 0;
}

size_t wifi_hw_ap_get_clients(uint port, WifiStaInfo[] buf)
{
    // TODO: esp_wifi_ap_get_sta_list
    return 0;
}

// Scanning

bool wifi_hw_scan_start(uint port, ref const WifiScanConfig cfg)
{
    assert(false, "TODO: esp_wifi_scan_start");
}

void wifi_hw_scan_stop(uint port)
{
    assert(false, "TODO: esp_wifi_scan_stop");
}

size_t wifi_hw_scan_get_results(uint port, WifiScanResult[] buf)
{
    assert(false, "TODO: esp_wifi_scan_get_ap_records");
}

// Frame TX/RX

bool wifi_hw_tx(uint port, WifiVif vif, const(ubyte)[] data)
{
    if (data.length == 0)
        return false;
    return esp_wifi_internal_tx(cast(int)vif, cast(void*)data.ptr, cast(ushort)data.length) == ESP_OK;
}

void wifi_hw_set_rx_callback(uint port, WifiRxCallback cb)
{
    _rx_cb = cb;
    ow_wifi_set_rx_callback(cb !is null ? &rx_trampoline : null);
}

uint wifi_hw_take_rx_drops(uint port)
{
    if (port >= num_wifi)
        return 0;
    return atomicExchange!(MemoryOrder.relaxed)(&_wifi_rx_drops, 0u);
}

uint wifi_hw_take_event_drops(uint port)
{
    if (port >= num_wifi)
        return 0;
    return atomicExchange!(MemoryOrder.relaxed)(&_wifi_evt_drops, 0u);
}

// Raw 802.11 TX/RX

bool wifi_hw_raw_tx(uint port, const(ubyte)[] frame)
{
    if (frame.length == 0 || frame.length > 1500)
        return false;
    // ifx = 0 (WIFI_IF_STA): always present in our monitor + sta + ap modes.
    // en_sys_seq = 1: let the MAC fill the sequence number so injected frames
    // don't collide with the radio's own outgoing sequence space.
    return ow_wifi_raw_tx(0, frame.ptr, cast(int)frame.length, 1) != 0;
}

void wifi_hw_set_raw_rx_callback(uint port, WifiRawRxCallback cb)
{
    _raw_rx_cb = cb;

    if (cb is null)
    {
        ow_wifi_set_promiscuous(0, 0);
        ow_wifi_set_promiscuous_callback(null);
        return;
    }

    ow_wifi_set_promiscuous_callback(&promisc_trampoline);
    // Filter: management + data + control + misc + FCS-fail. The FCSFAIL
    // bit is what lets us see corrupted frames -- the discriminator we need
    // for "is the antenna seeing anything at all" vs "frames are framing
    // correctly but content is wrong".
    enum uint WIFI_PROMIS_FILTER_MASK_ALL_WITH_FCSFAIL = 0xE00000FF;
    ow_wifi_set_promiscuous(1, WIFI_PROMIS_FILTER_MASK_ALL_WITH_FCSFAIL);
}

uint wifi_hw_take_raw_rx_drops(uint port)
{
    if (port >= num_wifi)
        return 0;
    return atomicExchange!(MemoryOrder.relaxed)(&_wifi_raw_rx_drops, 0u);
}

void wifi_hw_set_ready_callback(WifiReadyCallback cb)
{
    atomicStore!(MemoryOrder.seq)(_ready_cb_bits, cast(size_t)cb);

    // Registration is itself a readiness edge. This closes the startup race
    // where ESP-IDF can post STA_START before the frontend installs its
    // callback; an empty service pass is harmless.
    if (cb !is null)
        cb();
}

bool wifi_hw_set_channel(uint port, ubyte primary)
{
    // secondary=0 -> HT20 (no 40 MHz extension). The vast majority of 2.4GHz
    // deployments are HT20; if we ever want HT40 we extend this signature.
    return ow_wifi_set_channel(primary, 0) != 0;
}

// Queries

ubyte wifi_hw_supported_bands(uint port) pure
{
    version (DualBandRadio)
        return cast(ubyte)((1 << WifiBand._2_4ghz) | (1 << WifiBand._5ghz));
    else
        return cast(ubyte)(1 << WifiBand._2_4ghz);
}

bool wifi_hw_get_mac(uint port, WifiVif vif, ref ubyte[6] mac)
{
    // ESP_MAC_WIFI_STA=0, ESP_MAC_WIFI_SOFTAP=1
    return esp_read_mac(mac.ptr, cast(int)vif) == ESP_OK;
}

ubyte wifi_hw_get_channel(uint port)
{
    ubyte primary = void;
    int second = void;
    if (esp_wifi_get_channel(&primary, &second) != ESP_OK)
        return 0;
    return primary;
}

byte wifi_hw_get_rssi(uint port)
{
    WifiStaLinkInfo info;
    return wifi_hw_get_sta_link_info(port, info) ? info.rssi : 0;
}

bool wifi_hw_get_sta_link_info(uint port, ref WifiStaLinkInfo info)
{
    if (port >= num_wifi)
        return false;
    info = WifiStaLinkInfo.init;
    int rssi;
    if (ow_wifi_sta_get_ap_info(info.bssid.ptr, &rssi) == 0)
        return false;
    info.rssi = cast(byte)rssi;
    info.nss = 1; // every ESP32 radio is 1x1

    ubyte channel;
    int secondary;
    if (esp_wifi_get_channel(&channel, &secondary) == ESP_OK)
        info.band = channel >= 36 ? WifiBand._5ghz : WifiBand._2_4ghz;

    // ESP-IDF exposes no live bitrate, only the mode the association settled on, so the bitrates stay
    // unknown and the caller derives a peak from the mode. wifi_phy_mode_t folds bandwidth into the
    // mode and HT40 is the widest it can name, so a VHT80/HE80 link reads back understated.
    int phymode;
    if (esp_wifi_sta_get_negotiated_phymode(&phymode) != ESP_OK)
        return true;
    switch (phymode)
    {
        case WIFI_PHY_MODE_LR:
            info.phy_mode = WifiPhyMode.lr;
            break;
        case WIFI_PHY_MODE_11B:
            info.phy_mode = WifiPhyMode.b;
            break;
        case WIFI_PHY_MODE_11G, WIFI_PHY_MODE_11A:
            info.phy_mode = WifiPhyMode.g;
            break;
        case WIFI_PHY_MODE_HT20:
            info.phy_mode = WifiPhyMode.n;
            break;
        case WIFI_PHY_MODE_HT40:
            info.phy_mode = WifiPhyMode.n;
            info.bandwidth = WifiBandwidth.bw_40mhz;
            break;
        case WIFI_PHY_MODE_VHT20:
            info.phy_mode = WifiPhyMode.ac;
            break;
        case WIFI_PHY_MODE_HE20:
            info.phy_mode = WifiPhyMode.ax;
            break;
        default:
            break;
    }
    return true;
}

bool wifi_hw_set_tx_power(uint port, byte power_dbm)
{
    return esp_wifi_set_max_tx_power(power_dbm) == ESP_OK;
}

// Events

void wifi_hw_set_event_callback(uint port, WifiEventCallback cb)
{
    _event_cb = cb;
}

bool wifi_hw_service(uint port, size_t budget)
{
    if (port >= num_wifi)
        return false;
    // Callback code may initiate shutdown. Keep the entry published until the
    // callback returns, block recursive consumers, and only advance its tail
    // if shutdown did not reset the queues underneath this service pass.
    if (_servicing)
        return queues_pending();

    _servicing = true;
    uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
    Wifi w = Wifi(cast(ubyte)port);
    size_t serviced;
    uint empty_queues;

    while (serviced < budget && empty_queues < 3 &&
           generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
    {
        bool dispatched;
        final switch (_service_cursor)
        {
            case 0:
                dispatched = dispatch_one_event(w);
                break;
            case 1:
                dispatched = dispatch_one_rx(w);
                break;
            case 2:
                dispatched = dispatch_one_raw_rx(w);
                break;
        }
        _service_cursor = cast(ubyte)((_service_cursor + 1) % 3);
        if (dispatched)
        {
            ++serviced;
            empty_queues = 0;
        }
        else
            ++empty_queues;
    }

    _servicing = false;
    return queues_pending();
}

private:

bool dispatch_one_event(Wifi wifi)
{
    uint tail = atomicLoad!(MemoryOrder.relaxed)(_wifi_evt_tail);
    if (tail == atomicLoad!(MemoryOrder.acquire)(_wifi_evt_head))
        return false;
    auto slot = &_wifi_evt_queue[tail & (wifi_evt_cap - 1)];
    WifiQueuedEvent queued = *slot;
    uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
    if (_event_cb !is null)
    {
        const(void)* data;
        if (queued.event == WifiEvent.sta_disconnected)
            data = &queued.disconnect;
        else if (queued.has_mac)
            data = queued.mac.ptr;
        _event_cb(wifi, queued.event, data);
    }
    if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
        atomicStore!(MemoryOrder.release)(_wifi_evt_tail, tail + 1);
    return true;
}

bool dispatch_one_rx(Wifi wifi)
{
    uint tail = atomicLoad!(MemoryOrder.relaxed)(_wifi_rx_tail);
    if (tail == atomicLoad!(MemoryOrder.acquire)(_wifi_rx_head))
        return false;
    auto slot = &_wifi_rx_queue[tail & (wifi_rx_cap - 1)];
    version (UseInternalIPStack)
    {
        ubyte[wifi_rx_frame_max] frame = void;
        size_t length = slot.length;
        WifiVif vif = cast(WifiVif)slot.vif;
        void* eb = slot.eb;
        if (_rx_cb !is null)
            frame[0 .. length] = slot.data[0 .. length];
        slot.eb = null;
        atomicStore!(MemoryOrder.release)(_wifi_rx_tail, tail + 1);
        ow_wifi_free_rx_buffer(eb);
        if (_rx_cb !is null)
            _rx_cb(wifi, vif, frame[0 .. length]);
    }
    else
    {
        uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
        if (_rx_cb !is null)
            _rx_cb(wifi, cast(WifiVif)slot.vif, slot.data[0 .. slot.length]);
        if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
            atomicStore!(MemoryOrder.release)(_wifi_rx_tail, tail + 1);
    }
    return true;
}

bool dispatch_one_raw_rx(Wifi wifi)
{
    uint tail = atomicLoad!(MemoryOrder.relaxed)(_wifi_raw_rx_tail);
    if (tail == atomicLoad!(MemoryOrder.acquire)(_wifi_raw_rx_head))
        return false;
    auto slot = &_wifi_raw_rx_queue[tail & (wifi_raw_rx_cap - 1)];
    uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
    if (_raw_rx_cb !is null)
        _raw_rx_cb(wifi, slot.data[0 .. slot.length], slot.rssi, slot.channel);
    if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
        atomicStore!(MemoryOrder.release)(_wifi_raw_rx_tail, tail + 1);
    return true;
}

enum int ESP_OK = 0;

// ESP-IDF band modes (from esp_wifi_types_generic.h)
enum : int
{
    WIFI_BAND_MODE_2G_ONLY = 1,
    WIFI_BAND_MODE_5G_ONLY = 2,
    WIFI_BAND_MODE_AUTO    = 3,
}

// ESP-IDF event IDs (from esp_wifi_types.h)
enum : int
{
    WIFI_EVENT_STA_START          = 2,
    WIFI_EVENT_STA_STOP           = 3,
    WIFI_EVENT_STA_CONNECTED      = 4,
    WIFI_EVENT_STA_DISCONNECTED   = 5,
    WIFI_EVENT_AP_START           = 12,
    WIFI_EVENT_AP_STOP            = 13,
    WIFI_EVENT_AP_STACONNECTED    = 14,
    WIFI_EVENT_AP_STADISCONNECTED = 15,
}

// wifi_phy_mode_t (from esp_wifi_types_generic.h)
enum : int
{
    WIFI_PHY_MODE_LR    = 0,
    WIFI_PHY_MODE_11B   = 1,
    WIFI_PHY_MODE_11G   = 2,
    WIFI_PHY_MODE_11A   = 3,
    WIFI_PHY_MODE_HT20  = 4,
    WIFI_PHY_MODE_HT40  = 5,
    WIFI_PHY_MODE_HE20  = 6,
    WIFI_PHY_MODE_VHT20 = 7,
}

__gshared bool _opened;
__gshared WifiEventCallback _event_cb;
__gshared WifiRxCallback _rx_cb;
__gshared WifiRawRxCallback _raw_rx_cb;
shared size_t _ready_cb_bits;
shared int _sta_disconnect_reason;
__gshared const(char)[] _sta_status_message;
__gshared ubyte _service_cursor;
__gshared bool _servicing;
shared uint _queue_generation;

// ESP-IDF serialises each source onto one producer task: system events use
// the default event task, while Ethernet and promiscuous RX use the WiFi
// driver task. Each queue therefore has one producer and the OpenWatt reactor
// is its sole consumer.
struct WifiQueuedEvent
{
    WifiEvent event;
    ubyte[6] mac;
    bool has_mac;
    WifiStaDisconnectInfo disconnect;
}
enum size_t wifi_evt_cap = 8;
__gshared WifiQueuedEvent[wifi_evt_cap] _wifi_evt_queue;
shared uint _wifi_evt_head;
shared uint _wifi_evt_tail;
shared uint _wifi_evt_drops;

enum size_t wifi_rx_frame_max = 1518;
version (UseInternalIPStack)
{
    // Descriptors retain ESP-IDF RX buffers, so queue depth is cheap and
    // backpressure is governed by the driver's configured RX-buffer pool.
    struct WifiQueuedRx
    {
        const(ubyte)* data;
        void* eb;
        ushort length;
        ubyte vif;
    }
    enum size_t wifi_rx_cap = 32;
}
else
{
    // lwIP consumes the ESP-IDF buffer immediately, so this fallback owns a
    // small aligned copy ring instead.
    align(4) struct WifiQueuedRx
    {
        ubyte[wifi_rx_frame_max] data;
        ushort length;
        ubyte vif;
    }
    enum size_t wifi_rx_cap = 8;
}
__gshared WifiQueuedRx[wifi_rx_cap] _wifi_rx_queue;
shared uint _wifi_rx_head;
shared uint _wifi_rx_tail;
shared uint _wifi_rx_drops;

// sig_len is a 12-bit ESP-IDF field and includes the FCS.
enum size_t wifi_raw_rx_frame_max = 4095;
align(4) struct WifiQueuedRawRx
{
    ubyte[wifi_raw_rx_frame_max] data;
    ushort length;
    byte rssi;
    ubyte channel;
}
// Two maximum-sized monitor frames consume 8.2 KiB. Promiscuous capture is a
// sampled diagnostic stream; overruns are reported through raw RX drops.
enum size_t wifi_raw_rx_cap = 2;
__gshared WifiQueuedRawRx[wifi_raw_rx_cap] _wifi_raw_rx_queue;
shared uint _wifi_raw_rx_head;
shared uint _wifi_raw_rx_tail;
shared uint _wifi_raw_rx_drops;

void reset_queues() nothrow @nogc
{
    atomicFetchAdd!(MemoryOrder.acq_rel)(_queue_generation, 1u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_evt_head, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_evt_tail, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_evt_drops, 0u);
    version (UseInternalIPStack)
    {
        uint tail = atomicLoad!(MemoryOrder.relaxed)(_wifi_rx_tail);
        uint head = atomicLoad!(MemoryOrder.acquire)(_wifi_rx_head);
        while (tail != head)
        {
            auto slot = &_wifi_rx_queue[tail & (wifi_rx_cap - 1)];
            void* eb = slot.eb;
            slot.eb = null;
            ow_wifi_free_rx_buffer(eb);
            ++tail;
        }
    }
    atomicStore!(MemoryOrder.relaxed)(_wifi_rx_head, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_rx_tail, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_rx_drops, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_raw_rx_head, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_raw_rx_tail, 0u);
    atomicStore!(MemoryOrder.relaxed)(_wifi_raw_rx_drops, 0u);
    _service_cursor = 0;
}

bool queues_pending() nothrow @nogc
{
    return atomicLoad!(MemoryOrder.acquire)(_wifi_evt_head) !=
               atomicLoad!(MemoryOrder.relaxed)(_wifi_evt_tail) ||
           atomicLoad!(MemoryOrder.acquire)(_wifi_rx_head) !=
               atomicLoad!(MemoryOrder.relaxed)(_wifi_rx_tail) ||
           atomicLoad!(MemoryOrder.acquire)(_wifi_raw_rx_head) !=
               atomicLoad!(MemoryOrder.relaxed)(_wifi_raw_rx_tail);
}

void notify_ready() nothrow @nogc
{
    auto cb = cast(WifiReadyCallback)
        atomicLoad!(MemoryOrder.seq)(_ready_cb_bits);
    if (cb !is null)
        cb();
}

void push_wifi_evt(WifiEvent event, const ubyte* mac = null,
                   const WifiStaDisconnectInfo* disconnect = null) nothrow @nogc
{
    uint head = atomicLoad!(MemoryOrder.relaxed)(_wifi_evt_head);
    uint tail = atomicLoad!(MemoryOrder.acquire)(_wifi_evt_tail);
    if (head - tail >= wifi_evt_cap)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_evt_drops, 1u);
        notify_ready();
        return;
    }
    auto slot = &_wifi_evt_queue[head & (wifi_evt_cap - 1)];
    slot.event = event;
    slot.has_mac = mac !is null;
    if (mac !is null)
        slot.mac[] = mac[0 .. 6];
    if (disconnect !is null)
        slot.disconnect = *disconnect;
    atomicStore!(MemoryOrder.release)(_wifi_evt_head, head + 1);
    notify_ready();
}

extern(C) void sta_event_trampoline(int event_id, void*, int data_len) nothrow @nogc
{
    if (event_id == WIFI_EVENT_STA_START)
        push_wifi_evt(WifiEvent.sta_started);
    else if (event_id == WIFI_EVENT_STA_STOP)
        push_wifi_evt(WifiEvent.sta_stopped);
    else if (event_id == WIFI_EVENT_STA_CONNECTED)
    {
        atomicStore!(MemoryOrder.release)(_sta_disconnect_reason, 0);
        push_wifi_evt(WifiEvent.sta_connected);
    }
    else if (event_id == WIFI_EVENT_STA_DISCONNECTED)
    {
        atomicStore!(MemoryOrder.release)(_sta_disconnect_reason, data_len);
        WifiStaDisconnectInfo info;
        info.reason = data_len;
        info.message = esp_wifi_sta_reason_message(data_len);
        push_wifi_evt(WifiEvent.sta_disconnected, null, &info);
    }
}

const(char)[] esp_wifi_error_message(int rc) nothrow @nogc
{
    switch (rc)
    {
        case ESP_OK:
            return null;
        default:
            return "ESP-IDF rejected STA request";
    }
}

const(char)[] esp_wifi_sta_reason_message(int reason) nothrow @nogc
{
    switch (reason)
    {
        case 0:
            return null;
        case 1:
            return "Disconnected: unspecified reason";
        case 2:
            return "Authentication expired";
        case 4:
            return "Association expired";
        case 5:
            return "AP has too many clients";
        case 6:
            return "Not authenticated";
        case 7:
            return "Not associated";
        case 8:
            return "Association left";
        case 9:
            return "Association requires authentication";
        case 13:
            return "Invalid 802.11 information element";
        case 14:
            return "WPA MIC failure";
        case 15:
            return "WPA 4-way handshake timed out";
        case 16:
            return "WPA group key update timed out";
        case 17:
            return "WPA information element changed during handshake";
        case 18:
            return "WPA group cipher is invalid";
        case 19:
            return "WPA pairwise cipher is invalid";
        case 20:
            return "WPA AKM suite is invalid";
        case 21:
            return "Unsupported RSN information element version";
        case 22:
            return "Invalid RSN capabilities";
        case 23:
            return "802.1X authentication failed";
        case 24:
            return "Cipher suite rejected";
        case 200:
            return "AP beacon timed out";
        case 201:
            return "Target AP not found";
        case 202:
            return "Authentication failed";
        case 203:
            return "Association failed";
        case 204:
            return "WPA handshake timed out";
        case 205:
            return "Connection failed";
        case 207:
            return "Roaming";
        default:
            return "Disconnected by WiFi driver";
    }
}

extern(C) void ap_event_trampoline(int event_id, void* event_data, int) nothrow @nogc
{
    if (event_id == WIFI_EVENT_AP_START)
        push_wifi_evt(WifiEvent.ap_started);
    else if (event_id == WIFI_EVENT_AP_STOP)
        push_wifi_evt(WifiEvent.ap_stopped);
    else if (event_id == WIFI_EVENT_AP_STACONNECTED && event_data !is null)
        push_wifi_evt(WifiEvent.ap_sta_connected, cast(ubyte*)event_data);
    else if (event_id == WIFI_EVENT_AP_STADISCONNECTED && event_data !is null)
        push_wifi_evt(WifiEvent.ap_sta_disconnected, cast(ubyte*)event_data);
}

// RX trampoline -- called from C shim's esp_wifi_internal_reg_rxcb handler.
// The C shim also forwards to esp_netif_receive so lwIP still gets frames.
extern(C) int rx_trampoline(const(ubyte)* data, int len, int iface,
                            void* eb) nothrow @nogc
{
    if (_rx_cb is null)
        return 0;
    if (data is null || len <= 0 || iface < 0 || iface > 1)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_rx_drops, 1u);
        notify_ready();
        return 0;
    }
    if (len > wifi_rx_frame_max)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_rx_drops, 1u);
        notify_ready();
        return 0;
    }
    version (UseInternalIPStack)
    {
        if (eb is null)
        {
            atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_rx_drops, 1u);
            notify_ready();
            return 0;
        }
    }

    uint head = atomicLoad!(MemoryOrder.relaxed)(_wifi_rx_head);
    uint tail = atomicLoad!(MemoryOrder.acquire)(_wifi_rx_tail);
    if (head - tail >= wifi_rx_cap)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_rx_drops, 1u);
        notify_ready();
        return 0;
    }

    auto slot = &_wifi_rx_queue[head & (wifi_rx_cap - 1)];
    slot.length = cast(ushort)len;
    slot.vif = cast(ubyte)iface;
    version (UseInternalIPStack)
    {
        slot.data = data;
        slot.eb = eb;
    }
    else
        slot.data[0 .. len] = data[0 .. len];
    atomicStore!(MemoryOrder.release)(_wifi_rx_head, head + 1);
    notify_ready();
    version (UseInternalIPStack)
        return 1;
    else
        return 0;
}

// Promiscuous trampoline -- called from C shim for every 802.11 frame the
// radio decodes (including FCS-fail frames when the filter bit is set).
extern(C) void promisc_trampoline(int type, int rssi, int channel,
                                  int rate, int fcs_fail, int len,
                                  const(ubyte)* payload) nothrow @nogc
{
    if (_raw_rx_cb is null || len <= 0 || payload is null)
        return;
    // The raw callback cannot surface bad-FCS frames without confusing
    // subscribers that assume valid framing. This is deliberate filtering,
    // not queue loss, so it does not contribute to the drop counter.
    if (fcs_fail)
        return;
    if (len > wifi_raw_rx_frame_max)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_raw_rx_drops, 1u);
        notify_ready();
        return;
    }

    uint head = atomicLoad!(MemoryOrder.relaxed)(_wifi_raw_rx_head);
    uint tail = atomicLoad!(MemoryOrder.acquire)(_wifi_raw_rx_tail);
    if (head - tail >= wifi_raw_rx_cap)
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_wifi_raw_rx_drops, 1u);
        notify_ready();
        return;
    }

    auto slot = &_wifi_raw_rx_queue[head & (wifi_raw_rx_cap - 1)];
    slot.length = cast(ushort)len;
    slot.rssi = cast(byte)rssi;
    slot.channel = cast(ubyte)channel;
    slot.data[0 .. len] = payload[0 .. len];
    atomicStore!(MemoryOrder.release)(_wifi_raw_rx_head, head + 1);
    notify_ready();
}

// C shim functions (ow_shim.c) -- needed for macros, complex structs, netif
extern(C) nothrow @nogc
{
    int ow_wifi_init();
    void ow_wifi_deinit();
    int ow_wifi_sta_config(const(char)* ssid, const(char)* password, const(ubyte)* bssid);
    int ow_wifi_ap_config(const(char)* ssid, const(char)* password, ubyte channel, ubyte max_conn, ubyte hidden);
    int ow_wifi_ap_set_max_clients(ubyte max_conn);
    int ow_wifi_set_rx_callback(
        int function(const(ubyte)*, int, int, void*) nothrow @nogc cb);
    void ow_wifi_free_rx_buffer(void* eb);
    void ow_wifi_set_sta_callback(void function(int, void*, int) nothrow @nogc);
    void ow_wifi_set_ap_callback(void function(int, void*, int) nothrow @nogc);
    int ow_wifi_set_promiscuous(int enable, uint filter_mask);
    void ow_wifi_set_promiscuous_callback(
        void function(int type, int rssi, int channel,
                      int rate, int fcs_fail, int len,
                      const(ubyte)* payload) nothrow @nogc cb);
    int ow_wifi_set_channel(int primary, int secondary);
    int ow_wifi_raw_tx(int ifx, const(ubyte)* frame, int len, int en_sys_seq);
    int ow_wifi_sta_get_ap_info(ubyte* bssid, int* rssi);
}

// Direct ESP-IDF calls
extern(C) nothrow @nogc
{
    int esp_wifi_set_mode(int mode);
    int esp_wifi_start();
    int esp_wifi_stop();
    int esp_wifi_connect();
    int esp_wifi_disconnect();
    int esp_wifi_set_max_tx_power(byte power);
    int esp_wifi_set_band_mode(int band_mode);
    int esp_wifi_get_channel(ubyte* primary, int* second);
    int esp_wifi_sta_get_negotiated_phymode(int* phymode);
    int esp_read_mac(ubyte* mac, int type);
    int esp_wifi_internal_tx(int ifx, void* buffer, ushort len);
}
