// ESP32 WiFi driver -- D wrapper over C shim + direct ESP-IDF calls
//
// The C shim (ow_shim.c) handles:
//   - ow_wifi_init/deinit: WIFI_INIT_CONFIG_DEFAULT macro, netif creation,
//     event handler registration
//   - ow_wifi_sta_config/ap_config: wifi_config_t struct construction
//   - ow_wifi_set_rx_callback: RX trampolines that forward to D AND to
//     esp_netif_receive (so lwIP still works)
//
// Everything else (mode, connect, disconnect, tx, mac, channel, power)
// calls ESP-IDF directly.
//
// ESP32 has one WiFi port (port 0).
module urt.driver.esp32.wifi;

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


static if (num_wifi > 0):


bool wifi_hw_open(uint port, ref const WifiConfig cfg)
{
    if (_opened)
        return false;

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

    _opened = true;
    return true;
}

void wifi_hw_close(uint port)
{
    if (!_opened)
        return;
    ow_wifi_set_rx_callback(null);
    ow_wifi_set_sta_callback(null);
    ow_wifi_set_ap_callback(null);
    esp_wifi_stop();
    ow_wifi_deinit();
    _opened = false;
    _event_cb = null;
    _rx_cb = null;
    _raw_rx_cb = null;
    _evt_sta_connected = false;
    _evt_sta_disconnected = false;
    _evt_ap_started = false;
    _evt_ap_stopped = false;
}

bool wifi_hw_set_mode(uint port, WifiMode mode)
{
    if (mode == WifiMode.monitor)
        return false;

    // Map to ESP-IDF wifi_mode_t: 0=none,1=sta,2=ap,3=apsta
    static immutable ubyte[5] mode_map = [0, 0, 1, 2, 3];
    return esp_wifi_set_mode(mode_map[mode]) == ESP_OK;
}

bool wifi_hw_sta_configure(uint port, ref const WifiStaConfig cfg)
{
    // Stack buffers for null-termination (SSID max 32, password max 64)
    char[33] ssid_z = 0;
    char[65] pw_z = 0;

    if (cfg.ssid.length > 0 && cfg.ssid.length <= 32)
        ssid_z[0 .. cfg.ssid.length] = cfg.ssid[];
    if (cfg.password.length > 0 && cfg.password.length <= 64)
        pw_z[0 .. cfg.password.length] = cfg.password[];

    bool has_bssid = cfg.bssid != typeof(cfg.bssid).init;

    return ow_wifi_sta_config(
        cfg.ssid.length > 0 ? ssid_z.ptr : null,
        cfg.password.length > 0 ? pw_z.ptr : null,
        has_bssid ? cfg.bssid.ptr : null) != 0;
}

bool wifi_hw_sta_connect(uint port)
{
    _evt_sta_connected = false;
    _evt_sta_disconnected = false;
    return esp_wifi_connect() == ESP_OK;
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

size_t wifi_hw_ap_get_clients(uint port, WifiStaInfo[] buf)
{
    // TODO: esp_wifi_ap_get_sta_list
    return 0;
}

// Scanning

bool wifi_hw_scan_start(uint port, ref const WifiScanConfig cfg)
{
    // TODO: esp_wifi_scan_start
    return false;
}

void wifi_hw_scan_stop(uint port)
{
    // TODO: esp_wifi_scan_stop
}

size_t wifi_hw_scan_get_results(uint port, WifiScanResult[] buf)
{
    // TODO: esp_wifi_scan_get_ap_records
    return 0;
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

// Raw 802.11 TX/RX

bool wifi_hw_raw_tx(uint port, const(ubyte)[] frame)
{
    // TODO: esp_wifi_80211_tx
    return false;
}

void wifi_hw_set_raw_rx_callback(uint port, WifiRawRxCallback cb)
{
    // TODO: esp_wifi_set_promiscuous + esp_wifi_set_promiscuous_rx_cb
    _raw_rx_cb = cb;
}

// Queries

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
    // TODO: esp_wifi_sta_get_ap_info -> rssi
    return -127;
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

// Poll -- check ISR-set flags and deliver events to D callback.
// Called from main loop since ESP events arrive on the event task.
void wifi_hw_poll(uint port)
{
    if (_event_cb is null)
        return;

    Wifi w = Wifi(0);

    if (_evt_sta_connected)
    {
        _evt_sta_connected = false;
        _event_cb(w, WifiEvent.sta_connected, null);
    }
    if (_evt_sta_disconnected)
    {
        _evt_sta_disconnected = false;
        _event_cb(w, WifiEvent.sta_disconnected, null);
    }
    if (_evt_ap_started)
    {
        _evt_ap_started = false;
        _event_cb(w, WifiEvent.ap_started, null);
    }
    if (_evt_ap_stopped)
    {
        _evt_ap_stopped = false;
        _event_cb(w, WifiEvent.ap_stopped, null);
    }
    if (_evt_ap_sta_connected)
    {
        _evt_ap_sta_connected = false;
        _event_cb(w, WifiEvent.ap_sta_connected, _evt_ap_sta_mac.ptr);
    }
    if (_evt_ap_sta_disconnected)
    {
        _evt_ap_sta_disconnected = false;
        _event_cb(w, WifiEvent.ap_sta_disconnected, _evt_ap_sta_mac.ptr);
    }
}


private:

enum int ESP_OK = 0;

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

__gshared bool _opened;
__gshared WifiEventCallback _event_cb;
__gshared WifiRxCallback _rx_cb;
__gshared WifiRawRxCallback _raw_rx_cb;

// Flags set from ESP event task, polled from main loop
__gshared bool _evt_sta_connected;
__gshared bool _evt_sta_disconnected;
__gshared bool _evt_ap_started;
__gshared bool _evt_ap_stopped;
__gshared bool _evt_ap_sta_connected;
__gshared bool _evt_ap_sta_disconnected;
__gshared ubyte[6] _evt_ap_sta_mac;

// Event trampolines -- called from ESP event task via C shim
extern(C) void sta_event_trampoline(int event_id, void*, int) nothrow @nogc
{
    if (event_id == WIFI_EVENT_STA_CONNECTED)
        _evt_sta_connected = true;
    else if (event_id == WIFI_EVENT_STA_DISCONNECTED)
        _evt_sta_disconnected = true;
}

extern(C) void ap_event_trampoline(int event_id, void* event_data, int) nothrow @nogc
{
    if (event_id == WIFI_EVENT_AP_START)
        _evt_ap_started = true;
    else if (event_id == WIFI_EVENT_AP_STOP)
        _evt_ap_stopped = true;
    else if (event_id == WIFI_EVENT_AP_STACONNECTED && event_data !is null)
    {
        _evt_ap_sta_mac[] = (cast(ubyte*)event_data)[0 .. 6];
        _evt_ap_sta_connected = true;
    }
    else if (event_id == WIFI_EVENT_AP_STADISCONNECTED && event_data !is null)
    {
        _evt_ap_sta_mac[] = (cast(ubyte*)event_data)[0 .. 6];
        _evt_ap_sta_disconnected = true;
    }
}

// RX trampoline -- called from C shim's esp_wifi_internal_reg_rxcb handler.
// The C shim also forwards to esp_netif_receive so lwIP still gets frames.
extern(C) void rx_trampoline(const(ubyte)* data, int len, int iface) nothrow @nogc
{
    if (_rx_cb !is null && len > 0)
        _rx_cb(Wifi(0), cast(WifiVif)iface, data[0 .. len]);
}

// C shim functions (ow_shim.c) -- needed for macros, complex structs, netif
extern(C) nothrow @nogc
{
    int ow_wifi_init();
    void ow_wifi_deinit();
    int ow_wifi_sta_config(const(char)* ssid, const(char)* password, const(ubyte)* bssid);
    int ow_wifi_ap_config(const(char)* ssid, const(char)* password, ubyte channel, ubyte max_conn, ubyte hidden);
    int ow_wifi_set_rx_callback(void function(const(ubyte)*, int, int) nothrow @nogc cb);
    void ow_wifi_set_sta_callback(void function(int, void*, int) nothrow @nogc);
    void ow_wifi_set_ap_callback(void function(int, void*, int) nothrow @nogc);
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
    int esp_wifi_get_channel(ubyte* primary, int* second);
    int esp_read_mac(ubyte* mac, int type);
    int esp_wifi_internal_tx(int ifx, void* buffer, ushort len);
}
