module urt.driver.wifi;

import urt.result : Result, InternalResult;

version (Espressif)
    public import urt.driver.esp32.wifi;
else version (BL808_M0)
    public import urt.driver.bl808_m0.wifi;
else
    enum uint num_wifi = 0;

nothrow @nogc:


static if (!__traits(compiles, wifi_max_ap_clients))
    enum ubyte wifi_max_ap_clients = ubyte.max;

// May be called from task or interrupt context after deferred work becomes
// ready, and synchronously during registration. The callback must be IRQ-safe,
// non-blocking, @nogc, and nothrow. It may only signal or schedule service; it
// must not call wifi_service or re-enter the driver. Calls may be repeated,
// coalesced, or spurious. Registration is backend-global and remains active
// across port close/open cycles until explicitly replaced or cleared.
alias WifiReadyCallback = void function() nothrow @nogc;

void wifi_set_ready_callback(WifiReadyCallback cb)
{
    static if (__traits(compiles, wifi_hw_set_ready_callback(cb)))
        wifi_hw_set_ready_callback(cb);
}


// ====================================================================
// Types
// ====================================================================

enum WifiError : ubyte
{
    none,
    auth_failed,
    no_ap,          // target AP not found
    assoc_failed,   // association rejected
    timeout,
    tx_failed,
    internal,
}

// Virtual interface type within a radio.
enum WifiVif : ubyte
{
    sta,
    ap,
}

enum WifiMode : ubyte
{
    none,      // radio off, no virtual interfaces active
    monitor,   // radio on, raw 802.11 only - no stack
    sta,       // station only
    ap,        // access point only
    apsta,     // concurrent AP + STA
}

enum WifiAuth : ubyte
{
    open,
    wep,
    wpa_psk,
    wpa2_psk,
    wpa_wpa2_psk,
    wpa3_psk,
    wpa2_wpa3_psk,
    wpa2_enterprise,
    wpa3_enterprise,
}

enum WifiBand : ubyte
{
    any,
    _2_4ghz,
    _5ghz,
    _6ghz,
}

enum WifiBandwidth : ubyte
{
    bw_20mhz,
    bw_40mhz,
    bw_80mhz,
    bw_160mhz,
}

enum WifiPhyMode : ubyte
{
    unknown,
    b,      // DSSS/CCK
    a,      // OFDM on 5 GHz
    g,      // ERP-OFDM on 2.4 GHz
    n,      // HT
    ac,     // VHT
    ax,     // HE
    be,     // EHT
    lr,     // Espressif proprietary long range
}

enum WifiEvent : ubyte
{
    sta_connected,
    sta_disconnected,
    ap_started,
    ap_stopped,
    ap_sta_connected,     // a client joined our AP
    ap_sta_disconnected,  // a client left our AP
    scan_done,
    sta_started,
    sta_stopped,
}

static assert(WifiEvent.sta_connected == 0);
static assert(WifiEvent.scan_done == 6);

struct WifiStaDisconnectInfo
{
    int reason;
    const(char)[] message;
}

struct WifiConfig
{
    byte tx_power;       // dBm (0 = platform default)
    ubyte channel;       // fixed channel (0 = auto)
    WifiBand band;
    ubyte[2] country;    // ISO 3166-1 alpha-2 (e.g. "US"), 0 = default
}

struct WifiStaConfig
{
    const(char)[] ssid;
    const(char)[] password;
    ubyte[6] bssid;       // filter by BSSID (all zeros = any)
    WifiBand band;
    bool pmf_required;    // protected management frames
}

struct WifiApConfig
{
    const(char)[] ssid;
    const(char)[] password;
    WifiAuth auth = WifiAuth.wpa2_wpa3_psk;
    ubyte channel;        // 0 = auto
    ubyte max_clients = 4;
    bool hidden;          // suppress SSID broadcast
    WifiBandwidth bandwidth;
}

struct WifiScanConfig
{
    const(char)[] ssid;   // filter by SSID (empty = all)
    ubyte[6] bssid;       // filter by BSSID (all zeros = any)
    ubyte channel;        // scan single channel (0 = all)
    WifiBand band;
    bool passive;         // passive scan (listen only, no probe requests)
    ushort dwell_ms;      // per-channel dwell time (0 = platform default)
}

struct WifiScanResult
{
    ubyte[6] bssid;
    ubyte channel;
    byte rssi;            // dBm
    WifiAuth auth;
    WifiBand band;
    WifiBandwidth bandwidth;
    ubyte ssid_len;
    char[32] ssid_buf;

    const(char)[] ssid() const pure nothrow @nogc
        => ssid_buf[0 .. ssid_len];
}

struct WifiStaInfo
{
    ubyte[6] mac;
    byte rssi;
}

struct WifiCapability
{
    WifiBand band;
    WifiPhyMode phy_mode;
    WifiBandwidth bandwidth;
    ubyte nss;            // spatial streams, 0 = unknown
}

struct WifiStaLinkInfo
{
    uint tx_bitrate;      // kbit/s, 0 = unknown
    uint rx_bitrate;      // kbit/s, 0 = unknown
    ubyte[6] bssid;
    byte rssi;
    WifiBand band;
    WifiPhyMode phy_mode;
    WifiBandwidth bandwidth;
    ubyte nss;            // spatial streams, 0 = unknown
    bool short_gi;
}

// Delivered by wifi_service() when an Ethernet frame is received on a virtual
// interface. Data includes the 14-byte Ethernet header and remains valid only
// until the callback returns.
alias WifiRxCallback = void function(Wifi wifi, WifiVif vif, const(ubyte)[] data) nothrow @nogc;

// Delivered by wifi_service() for a promiscuous/monitor frame. Data starts at
// the 802.11 MAC header and remains valid only until the callback returns.
// Raw and Ethernet RX can be active simultaneously.
alias WifiRawRxCallback = void function(Wifi wifi, const(ubyte)[] frame, byte rssi, ubyte channel) nothrow @nogc;

// Called when a wifi event occurs. Replaces per-event callbacks
// to match the single-callback pattern used by the router layer.
// data points to WifiStaDisconnectInfo for sta_disconnected, six MAC bytes
// for AP station join/leave events, and is null for other events. Its lifetime
// ends when the callback returns.
alias WifiEventCallback = void function(Wifi wifi, WifiEvent event, const(void)* data) nothrow @nogc;

struct Wifi
{
    ubyte port = ubyte.max;
}

bool is_open(ref const Wifi wifi)
{
    return wifi.port != ubyte.max;
}


// ====================================================================
// Error type
// ====================================================================

WifiError wifi_result(Result result)
{
    return cast(WifiError)result.system_code;
}


// ====================================================================
// Implementation
// ====================================================================

// Lifecycle

void wifi_init()
{
    if (_init_refcount++ == 0)
    {
        // TODO: enable clocks/power for WiFi peripheral block
    }
}

void wifi_deinit()
{
    assert(_init_refcount > 0);
    if (--_init_refcount == 0)
    {
        // TODO: disable clocks/power for WiFi peripheral block
    }
}

// Radio operations

ubyte wifi_supported_bands(ubyte port) pure
{
    static if (num_wifi == 0)
        return 0;
    else
    {
        if (port >= num_wifi)
            return 0;
        static if (__traits(compiles, wifi_hw_supported_bands(port)))
            return wifi_hw_supported_bands(port);
        else
            return cast(ubyte)(1 << WifiBand._2_4ghz);
    }
}

bool wifi_band_supported(ubyte port, WifiBand band) pure
{
    ubyte supported = wifi_supported_bands(port);
    return band == WifiBand.any
        ? supported != 0
        : (supported & (1 << band)) != 0;
}

Result wifi_open(ref Wifi wifi, ubyte port, ref const WifiConfig cfg)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (port >= num_wifi)
            return InternalResult.invalid_parameter;
        if (!wifi_band_supported(port, cfg.band))
            return InternalResult.invalid_parameter;

        if (!wifi_hw_open(port, cfg))
            return InternalResult.failed;

        wifi.port = port;
        return Result.success;
    }
}

void wifi_close(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        wifi_hw_close(wifi.port);
    wifi.port = ubyte.max;
}

Result wifi_set_mode(ref Wifi wifi, WifiMode mode)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_set_mode(wifi.port, mode))
            return InternalResult.failed;
        return Result.success;
    }
}

// Station (client) operations

Result wifi_sta_configure(ref Wifi wifi, ref const WifiStaConfig cfg)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_sta_configure(wifi.port, cfg))
            return InternalResult.failed;
        return Result.success;
    }
}

const(char)[] wifi_sta_status_message(ref Wifi wifi)
{
    static if (num_wifi == 0)
        return null;
    else
        return wifi_hw_sta_status_message(wifi.port);
}

// Begin association. Completion is signalled via WifiEvent.sta_connected
// or WifiEvent.sta_disconnected through the event callback.
Result wifi_sta_connect(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_sta_connect(wifi.port))
            return InternalResult.failed;
        return Result.success;
    }
}

Result wifi_sta_disconnect(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_sta_disconnect(wifi.port))
            return InternalResult.failed;
        return Result.success;
    }
}

// Access point operations

Result wifi_ap_configure(ref Wifi wifi, ref const WifiApConfig cfg)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_ap_configure(wifi.port, cfg))
            return InternalResult.failed;
        return Result.success;
    }
}

Result wifi_ap_set_max_clients(ref Wifi wifi, ubyte max_clients)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_ap_set_max_clients(wifi.port, max_clients))
            return InternalResult.failed;
        return Result.success;
    }
}

// Query stations currently connected to our AP.
// Returns the number of entries written (up to buf.length).
size_t wifi_ap_get_clients(ref Wifi wifi, WifiStaInfo[] buf)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        return wifi_hw_ap_get_clients(wifi.port, buf);
}

// Scanning

Result wifi_scan_start(ref Wifi wifi, ref const WifiScanConfig cfg)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_scan_start(wifi.port, cfg))
            return InternalResult.failed;
        return Result.success;
    }
}

void wifi_scan_stop(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        wifi_hw_scan_stop(wifi.port);
}

// Retrieve scan results after WifiEvent.scan_done.
// Returns the number of entries written (up to buf.length).
size_t wifi_scan_get_results(ref Wifi wifi, WifiScanResult[] buf)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        return wifi_hw_scan_get_results(wifi.port, buf);
}

// Frame TX/RX

// Transmit an Ethernet frame (including 14-byte header) on a
// virtual interface.
Result wifi_tx(ref Wifi wifi, WifiVif vif, const(ubyte)[] data)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_tx(wifi.port, vif, data))
            return InternalResult.failed;
        return Result.success;
    }
}

void wifi_set_rx_callback(ref Wifi wifi, WifiRxCallback cb)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        wifi_hw_set_rx_callback(wifi.port, cb);
}

uint wifi_take_rx_drops(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else static if (__traits(compiles, wifi_hw_take_rx_drops(wifi.port)))
        return wifi_hw_take_rx_drops(wifi.port);
    else
        return 0;
}

uint wifi_take_event_drops(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else static if (__traits(compiles, wifi_hw_take_event_drops(wifi.port)))
        return wifi_hw_take_event_drops(wifi.port);
    else
        return 0;
}

// Raw 802.11 frame TX/RX (monitor/promiscuous)

// Transmit a raw 802.11 frame. Data must include the full MAC header.
// Requires monitor mode or promiscuous capability on the platform.
Result wifi_raw_tx(ref Wifi wifi, const(ubyte)[] frame)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_raw_tx(wifi.port, frame))
            return InternalResult.failed;
        return Result.success;
    }
}

void wifi_set_raw_rx_callback(ref Wifi wifi, WifiRawRxCallback cb)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        wifi_hw_set_raw_rx_callback(wifi.port, cb);
}

uint wifi_take_raw_rx_drops(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else static if (__traits(compiles, wifi_hw_take_raw_rx_drops(wifi.port)))
        return wifi_hw_take_raw_rx_drops(wifi.port);
    else
        return 0;
}

// Queries

Result wifi_get_mac(ref Wifi wifi, WifiVif vif, ref ubyte[6] mac)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_get_mac(wifi.port, vif, mac))
            return InternalResult.failed;
        return Result.success;
    }
}

Result wifi_set_channel(ref Wifi wifi, ubyte channel)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_set_channel(wifi.port, channel))
            return InternalResult.failed;
        return Result.success;
    }
}

ubyte wifi_get_channel(ref const Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        return wifi_hw_get_channel(wifi.port);
}

// STA-only: signal strength of current connection.
byte wifi_get_rssi(ref Wifi wifi)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        return wifi_hw_get_rssi(wifi.port);
}

bool wifi_get_sta_link_info(ref Wifi wifi, ref WifiStaLinkInfo info)
{
    static if (num_wifi == 0)
        return false;
    else static if (__traits(compiles, wifi_hw_get_sta_link_info(wifi.port, info)))
        return wifi_hw_get_sta_link_info(wifi.port, info);
    else
        return false;
}

// The best this radio can do on one supported band, as opposed to what a link negotiated. A
// multi-band radio has one capability per band; 'any' is not a band and is therefore rejected.
bool wifi_get_capability(ref Wifi wifi, WifiBand band, ref WifiCapability caps)
{
    static if (num_wifi == 0)
        return false;
    else
    {
        if (band == WifiBand.any || !wifi_band_supported(wifi.port, band))
            return false;
        static if (__traits(compiles, wifi_hw_get_capability(wifi.port, band, caps)))
            return wifi_hw_get_capability(wifi.port, band, caps);
        else
            return false;
    }
}

Result wifi_set_tx_power(ref Wifi wifi, byte power_dbm)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
    {
        if (!wifi_hw_set_tx_power(wifi.port, power_dbm))
            return InternalResult.failed;
        return Result.success;
    }
}

// Events

void wifi_set_event_callback(ref Wifi wifi, WifiEventCallback cb)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        wifi_hw_set_event_callback(wifi.port, cb);
}

// Service deferred backend work in caller context. budget limits the number of
// consumer callbacks delivered in one pass; platform bookkeeping may also run.
// Returns true when work remains, in which case the caller must schedule
// another pass without waiting for a new hardware event. Event, Ethernet RX,
// and raw RX are independent sources, so their callbacks have no cross-source
// order guarantee.

bool wifi_service(ref Wifi wifi, size_t budget = 32)
{
    static if (num_wifi == 0)
        assert(false, "no WiFi on this platform");
    else
        return wifi_hw_service(wifi.port, budget);
}


// ====================================================================
// Tests
// ====================================================================

unittest
{
    static if (num_wifi > 0)
    {
        Wifi w;
        WifiConfig cfg;

        wifi_init();

        // Out-of-range port
        auto r = wifi_open(w, cast(ubyte)num_wifi, cfg);
        assert(!r);
        assert(!w.is_open);

        // Open/close each valid port
        foreach (p; 0 .. num_wifi)
        {
            Wifi port;
            auto r2 = wifi_open(port, cast(ubyte)p, cfg);
            assert(r2, "wifi_open failed");
            assert(port.is_open);
            assert(port.port == p);
            assert(wifi_supported_bands(port.port) != 0);

            wifi_service(port);

            wifi_close(port);
            assert(!port.is_open);
        }

        wifi_deinit();
    }
}


private:

__gshared ubyte _init_refcount;
