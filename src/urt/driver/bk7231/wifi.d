module urt.driver.bk7231.wifi;

version (Beken):

import urt.driver.bk7231.pbuf : beken_ethernet_input_handler;
import urt.driver.irq : irq_disable, irq_enable;
import urt.driver.wifi;
import urt.driver.wpa : wpa2_psk_ccmp_rsn_ie, wpa_max_eapol_len;
import urt.driver.wpa.supplicant : WpaStaSupplicant, WpaKeyMgmt;
import urt.log;
import urt.mem : memcpy;
import urt.mem.pagepool : Page, page_alloc, page_free;
import urt.result : Result;
import urt.time : MonoTime, Duration, getTime, seconds;

nothrow @nogc:


enum uint num_wifi = 1;
enum ubyte wifi_max_ap_clients = 0;

void wifi_hw_set_ready_callback(WifiReadyCallback cb)
{
    _ready_cb = cb;
    if (cb && needs_service_wake())
        cb();
}

bool wifi_hw_open(ubyte port, ref const WifiConfig cfg)
{
    if (port >= num_wifi || _open || cfg.channel > 14 || cfg.tx_power != 0 || cfg.country != ubyte[2].init || (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
        return false;

    _mode = WifiMode.none;
    _sta_status = StaStatus.idle;
    _events.clear();
    _open = true;
    ++_service_epoch;

    if (!_initialized)
    {
        _sta_vif = no_vif;
        _channel = 1;
        mr_kmsg_init();
        cfg_param_init();
        char[6] mac = void;
        wifi_get_mac_address(mac.ptr, bk_role_null);
        version (BK7231N)
            manual_cal_load_bandgap_calm();
        rwnxl_init();
        // Calibration polls the ADC FIFO and deadlocks if the vendor ISR drains it concurrently.
        immutable bool irqs = irq_disable();
        calibration_main();
        uint tab_in_flash = manual_cal_load_txpwr_tab_flash();
        manual_cal_load_default_txpwr_tab(tab_in_flash);
        manual_cal_load_lpf_iq_tag_flash();
        manual_cal_load_xtal_tag_flash();
        rwnx_cal_initial_calibration();
        if (irqs)
            irq_enable();
        _initialized = true;
        mac_start();
    }
    else if (_mac_state == MacState.stopped)
        mac_start();

    if (cfg.channel)
    {
        if (bk_wlan_set_channel(cfg.channel) != 0)
        {
            wifi_hw_close(port);
            return false;
        }
        _channel = cfg.channel;
    }
    beken_ethernet_input_handler(&ethernet_input);
    if (_ready_cb && needs_service_wake())
        _ready_cb();
    return true;
}

void wifi_hw_close(ubyte port)
{
    if (!_open)
        return;

    ++_service_epoch;
    if (_mode == WifiMode.monitor)
    {
        bk_wlan_stop_monitor();
        release_raw_rx_pages();
    }
    _scanning = false;
    stop_sta();
    _sta_state = StaState.offline;
    beken_ethernet_input_handler(null);
    _mode = WifiMode.none;
    _open = false;
    _rx_cb = null;
    _raw_rx_cb = null;
    _event_cb = null;
    request_mac_reset();
    if (!_servicing)
        mac_reset();
}

bool wifi_hw_set_mode(ubyte port, WifiMode mode)
{
    if (!_open || mode == WifiMode.ap || mode == WifiMode.apsta)
        return false;
    if (mode == _mode)
        return true;
    if (_mac_state != MacState.ready)
        return false;
    if (_scanning)
    {
        wifi_hw_scan_stop(port);
        return false;
    }

    ++_service_epoch;
    if (_mode == WifiMode.monitor)
    {
        bk_wlan_stop_monitor();
        release_raw_rx_pages();
    }
    if (_mode == WifiMode.sta)
    {
        stop_sta();
        if (_sta_state >= StaState.idle)
            push_event(WifiEventRecord(WifiEvent.sta_stopped));
        _sta_state = StaState.offline;
    }
    _mode = WifiMode.none;
    if (_mac_state == MacState.reset_pending)
        return false;

    final switch (mode)
    {
        case WifiMode.none:
            break;

        case WifiMode.monitor:
            if (!prepare_raw_rx_pages())
                return false;
            bk_wlan_register_monitor_cb(&monitor_callback);
            ow_rw_monitor_start(_channel);
            break;

        case WifiMode.sta:
            if (!sta_vif_up())
                return false;
            if (_sta_state >= StaState.idle)
                push_event(WifiEventRecord(WifiEvent.sta_started));
            break;

        case WifiMode.ap:
        case WifiMode.apsta:
            assert(false);
    }

    _mode = mode;
    return true;
}

bool wifi_hw_sta_configure(ubyte port, ref const WifiStaConfig cfg)
{
    if (!_open || _sta_state > StaState.idle)
        return false;
    if (cfg.ssid.length == 0 || cfg.ssid.length > 32 || cfg.password.length > 63 || (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
    {
        _sta_status = StaStatus.configuration_rejected;
        return false;
    }

    bool same = cast(const(ubyte)[])cfg.ssid[] == _sta_ssid_buf[0 .. _sta_ssid_len] && cast(const(ubyte)[])cfg.password[] == _sta_pass_buf[0 .. _sta_pass_len];
    bool reuse_pmk = same && _supp.pmk_ready && _supp.profile.key_mgmt == WpaKeyMgmt.wpa2_psk;

    _sta_ssid_buf[0 .. cfg.ssid.length] = cast(const(ubyte)[])cfg.ssid[];
    _sta_ssid_len = cast(ubyte)cfg.ssid.length;
    _sta_pass_buf[0 .. cfg.password.length] = cast(const(ubyte)[])cfg.password[];
    _sta_pass_len = cast(ubyte)cfg.password.length;
    _sta_bssid = cfg.bssid;

    WifiStaConfig local = cfg;
    local.ssid = cast(const(char)[])_sta_ssid_buf[0 .. _sta_ssid_len];
    local.password = cast(const(char)[])_sta_pass_buf[0 .. _sta_pass_len];
    Result r = reuse_pmk ? _supp.configure_precomputed(local, _supp.pmk[]) : _supp.configure_deferred(local);
    if (!r)
    {
        _sta_ssid_len = 0;
        _sta_pass_len = 0;
        _sta_status = cfg.pmf_required ? StaStatus.unsupported_security : StaStatus.configuration_rejected;
        return false;
    }
    _supp.hooks.send_eapol = &sta_send_eapol;
    _supp.hooks.install_pairwise_key = &sta_install_pairwise;
    _supp.hooks.install_group_key = &sta_install_group;
    _supp.hooks.auth_done = &sta_auth_done;
    _supp.fourway.hooks.deferred_group_install = true;
    return true;
}

const(char)[] wifi_hw_sta_status_message(ubyte port)
{
    return sta_status_message(_sta_status);
}

bool wifi_hw_sta_connect(ubyte port)
{
    if (!_open || _mac_state != MacState.ready || _mode != WifiMode.sta || _scanning || _sta_state != StaState.idle || _sta_ssid_len == 0)
        return false;

    if (!_supp.pmk_ready)
    {
        _sta_state = StaState.deriving;
        _sta_status = StaStatus.deriving_key;
        return true;
    }
    _sta_status = StaStatus.connecting;
    return sta_scan();
}

bool wifi_hw_sta_disconnect(ubyte port)
{
    if (!_open)
        return false;

    stop_sta();
    _sta_status = StaStatus.disconnected;
    return true;
}

bool wifi_hw_ap_configure(ubyte port, ref const WifiApConfig cfg)
    => false;

bool wifi_hw_ap_set_max_clients(ubyte port, ubyte max_clients)
    => false;

size_t wifi_hw_ap_get_clients(ubyte port, WifiStaInfo[] buf)
    => 0;

bool wifi_hw_scan_start(ubyte port, ref const WifiScanConfig cfg)
{
    bool has_bssid;
    foreach (b; cfg.bssid)
        has_bssid |= b != 0;
    if (!_open || _mac_state != MacState.ready || _mode == WifiMode.monitor || _scanning || (_sta_state != StaState.offline && _sta_state != StaState.idle) || cfg.ssid.length || has_bssid || cfg.channel || cfg.passive || cfg.dwell_ms || (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
        return false;

    if (ow_rw_scan(no_vif, null, 0) != 0)
        return false;
    _scanning = true;
    arm_deadline(10.seconds);
    return true;
}

void wifi_hw_scan_stop(ubyte port)
{
    if (_scanning)
    {
        _scanning = false;
        request_mac_reset();
    }
}

size_t wifi_hw_scan_get_results(ubyte port, WifiScanResult[] buf)
{
    if (!_open || buf.length == 0)
        return 0;

    ubyte avail = bk_wlan_get_scan_ap_result_numbers();
    if (avail == 0)
        return 0;

    StaScanResult[8] scratch;
    size_t count = avail < buf.length ? avail : buf.length;
    if (count > scratch.length)
        count = scratch.length;

    bk_wlan_get_scan_ap_result(scratch.ptr, cast(ubyte)count);

    foreach (i; 0 .. count)
    {
        const(StaScanResult)* r = &scratch[i];
        WifiScanResult* d = &buf[i];
        *d = WifiScanResult.init;
        d.bssid[] = r.bssid[];
        d.channel = cast(ubyte)r.channel;
        d.rssi = cast(byte)r.level;
        d.auth = scan_auth(r.security);
        d.band = WifiBand._2_4ghz;

        size_t n = 0;
        while (n < r.ssid.length && r.ssid[n] != 0)
            ++n;
        d.ssid_len = cast(ubyte)n;
        d.ssid_buf[0 .. n] = r.ssid[0 .. n];
    }

    return count;
}

bool wifi_hw_tx(ubyte port, WifiVif vif, const(ubyte)[] data)
{
    if (!_open || _mac_state != MacState.ready || vif != WifiVif.sta || _sta_state != StaState.connected || data.length < 14 || data.length > max_frame)
        return false;

    return ow_rw_transfer(_sta_vif, cast(ubyte*)data.ptr, cast(uint)data.length) == 0;
}

void wifi_hw_set_rx_callback(ubyte port, WifiRxCallback cb)
{
    _rx_cb = cb;
}

uint wifi_hw_take_rx_drops(ubyte port)
    => take_drop_count(_rx_drops);

bool wifi_hw_raw_tx(ubyte port, const(ubyte)[] frame)
{
    if (!_open || _mac_state != MacState.ready || frame.length < 10 || frame.length > max_raw_frame)
        return false;
    return rwm_raw_frame_with_cb(cast(ubyte*)frame.ptr, cast(int)frame.length, null, null) != 0;
}

void wifi_hw_set_raw_rx_callback(ubyte port, WifiRawRxCallback cb)
{
    _raw_rx_cb = cb;
    if (!cb)
        discard_raw_rx();
}

uint wifi_hw_take_raw_rx_drops(ubyte port)
    => take_drop_count(_raw_rx_drops);

bool wifi_hw_get_mac(ubyte port, WifiVif vif, ref ubyte[6] mac)
{
    if (!_open || vif != WifiVif.sta)
        return false;
    wifi_get_mac_address(cast(char*)mac.ptr, bk_role_sta);
    return true;
}

ubyte wifi_hw_get_channel(ubyte port)
    => _channel;

bool wifi_hw_set_channel(ubyte port, ubyte primary)
{
    if (!_open || primary == 0 || primary > 14)
        return false;
    if (bk_wlan_set_channel(primary) != 0)
        return false;
    _channel = primary;
    return true;
}

byte wifi_hw_get_rssi(ubyte port)
    => _rssi;

bool wifi_hw_get_sta_link_info(ubyte port, ref WifiStaLinkInfo info)
{
    if (!_open || _sta_state != StaState.connected)
        return false;
    info = WifiStaLinkInfo.init;
    info.bssid[] = _supp.profile.bssid[];
    info.rssi = _rssi;
    info.band = WifiBand._2_4ghz;
    info.phy_mode = WifiPhyMode.n;
    info.bandwidth = WifiBandwidth.bw_20mhz;
    info.nss = 1;
    return true;
}

bool wifi_hw_get_capability(ubyte port, WifiBand band, ref WifiCapability caps)
{
    if (!_open || band != WifiBand._2_4ghz)
        return false;
    caps = WifiCapability.init;
    caps.band = band;
    caps.phy_mode = WifiPhyMode.n;
    caps.bandwidth = WifiBandwidth.bw_20mhz;
    caps.nss = 1;
    return true;
}

bool wifi_hw_set_tx_power(ubyte port, byte power_dbm)
    => false;

void wifi_hw_set_event_callback(ubyte port, WifiEventCallback cb)
{
    _event_cb = cb;
}

uint wifi_hw_take_event_drops(ubyte port)
    => take_drop_count(_event_drops);

bool wifi_hw_service(ubyte port, size_t budget)
{
    if (!_open)
        return false;

    assert(!_servicing);
    _servicing = true;
    scope(exit)
    {
        _servicing = false;
        if (_mac_state == MacState.reset_pending)
            mac_reset();
    }
    if (_mac_state == MacState.reset_pending)
        mac_reset();
    MonoTime now = getTime();
    if (_deadline && now >= _deadline)
    {
        if (_mac_state == MacState.retry)
            mac_start();
        else
            firmware_timeout();
    }
    uint epoch = _service_epoch;
    size_t served;
    ke_evt_core_scheduler();
    if (epoch != _service_epoch)
        return _open && needs_service_wake();
    while (served < budget && ow_rw_receive())
    {
        ++served;
        if (epoch != _service_epoch)
            return _open && needs_service_wake();
    }
    ke_evt_none_core_scheduler();
    if (epoch != _service_epoch)
        return _open && needs_service_wake();

    if (_sta_state == StaState.deriving)
        sta_derive_slice();

    while (served < budget)
    {
        immutable bool prev = irq_disable();
        bool have = _rx_pending != 0;
        int arg = 0;
        if (have)
        {
            arg = _rx_args[_rx_tail];
            _rx_tail = (_rx_tail + 1) % _rx_args.length;
            --_rx_pending;
        }
        if (prev)
            irq_enable();
        if (!have)
            break;
        rxl_cntrl_evt(arg);
        if (epoch != _service_epoch)
            return _open && needs_service_wake();
        ++served;
    }

    while (served < budget)
    {
        Page* page = pop_raw_rx();
        if (!page)
            break;

        uint pool_epoch = _raw_rx_epoch;
        if (_raw_rx_cb)
        {
            RawRxInfo* info = raw_rx_info(page);
            Wifi wifi = Wifi(port);
            _raw_rx_cb(wifi, cast(const(ubyte)[])page.data, info.rssi, info.channel);
        }
        else
            ++_raw_rx_drops;
        if (pool_epoch == _raw_rx_epoch)
            release_raw_rx_page(page);
        else
            page_free(page);
        if (epoch != _service_epoch)
            return _open && needs_service_wake();
        ++served;
    }

    while (served < budget && !_events.empty)
    {
        WifiEventRecord event = _events.pop();
        if (_event_cb)
        {
            Wifi wifi = Wifi(port);
            WifiStaDisconnectInfo disconnect_info;
            const(void)* data = null;
            if (event.event == WifiEvent.sta_disconnected)
            {
                disconnect_info.reason = event.reason;
                disconnect_info.message = sta_status_message(event.status);
                data = &disconnect_info;
            }
            _event_cb(wifi, event.event, data);
            if (epoch != _service_epoch)
                return _open && needs_service_wake();
        }
        ++served;
    }
    return (budget && served == budget) || !_events.empty || _rx_pending != 0 || _raw_rx_head !is null || _sta_state == StaState.deriving;
}

private:
enum ubyte bk_role_null = 0;
enum ubyte bk_role_sta = 2;

enum uint max_frame = 1600;
enum uint max_raw_frame = 2346;
enum ubyte max_raw_rx_pending = 4;

enum ubyte no_vif = 0xFF;
enum ushort reason_deauth_leaving = 3;
enum ushort reason_too_many_stations = 5;
enum ushort status_too_many_stations = 17;

enum OwRwMsg : int
{
    other = 0,
    add_if_cfm,
    scanu_start_cfm,
    beacon_lose_ind,
    auth_fail_ind,
    assoc_fail_ind,
    disassoc_ind,
    connect_cfm,
    connect_ind,
    disconnect_ind,
    key_add_cfm,
    control_port_cfm,
    reset_cfm,
    config_cfm,
    channel_config_cfm,
    start_cfm,
}

enum StaState : ubyte
{
    offline,
    starting,
    idle,
    deriving,
    scanning,
    associating,
    keying,
    installing,
    control_port,
    connected,
}

enum MacState : ubyte
{
    stopped,
    retry,
    reset_pending,
    reset,
    configure,
    channels,
    start,
    ready,
}

enum StaStatus : ubyte
{
    idle,
    vif_add_failed,
    unsupported_security,
    configuration_rejected,
    deriving_key,
    connecting,
    disconnected,
    scan_failed,
    network_not_found,
    connect_request_failed,
    connected,
    beacon_lost,
    auth_failed,
    association_refused,
    association_failed,
    key_install_failed,
    control_port_failed,
    firmware_timeout,
    mac_request_failed,
}

enum WifiAuth[7] scan_auths = [
    WifiAuth.open,
    WifiAuth.wep,
    WifiAuth.wpa_psk,
    WifiAuth.wpa_psk,
    WifiAuth.wpa2_psk,
    WifiAuth.wpa2_psk,
    WifiAuth.wpa2_psk,
];

struct StaScanResult
{
    ubyte[6] bssid;
    char[32] ssid;
    char on_channel;
    char channel;
    ushort beacon_int;
    ushort caps;
    int level;
    int security;
    ubyte[8] tsf;
    uint ie_len;
}

struct WifiLinkInfo
{
    byte rssi;
}

static assert(StaScanResult.sizeof == 64);
static assert(WifiLinkInfo.sizeof == 1);

struct KeMsg;

struct WifiEventRecord
{
    WifiEvent event;
    StaStatus status;
    ushort reason;
}

struct EventQueue
{
nothrow @nogc:

    enum ubyte capacity = 16;

    bool empty() const pure => _count == 0;

    void clear()
    {
        _head = _count = 0;
    }

    bool push(WifiEventRecord event)
    {
        if (_count == capacity)
            return false;
        _events[(_head + _count) % capacity] = event;
        ++_count;
        return true;
    }

    WifiEventRecord pop()
    {
        WifiEventRecord event = _events[_head];
        _head = cast(ubyte)((_head + 1) % capacity);
        --_count;
        return event;
    }

private:
    WifiEventRecord[capacity] _events;
    ubyte _head;
    ubyte _count;
}

struct RawRxInfo
{
    byte rssi;
    ubyte channel;
}

alias MonitorDataCallback = extern(C) void function(ubyte* data, int len, WifiLinkInfo* info) nothrow @nogc;

immutable const(char)[][StaStatus.max + 1] sta_status_messages = [
    "idle",
    "vif add failed",
    "unsupported security",
    "configuration rejected",
    "deriving key",
    "connecting",
    "disconnected",
    "scan failed",
    "network not found",
    "connect request failed",
    "connected",
    "beacon lost",
    "auth failed",
    "association refused",
    "association failed",
    "key install failed",
    "control port failed",
    "firmware timeout; recovering MAC",
    "MAC request failed; recovering",
];

__gshared
{
    MonoTime _deadline;
    uint _service_epoch;
    MacState _mac_state;
    WifiMode _mode;
    bool _initialized;
    bool _open;
    bool _servicing;
    bool _scanning;
    ubyte _channel;

    WpaStaSupplicant _supp;
    StaState _sta_state;
    StaStatus _sta_status;
    byte _rssi;
    ubyte _sta_vif;
    ubyte _sta_ap_idx;
    ubyte _key_pending;

    ubyte[32] _sta_ssid_buf;
    ubyte _sta_ssid_len;
    ubyte[64] _sta_pass_buf;
    ubyte _sta_pass_len;
    ubyte[6] _sta_bssid;

    EventQueue _events;
    uint _event_drops;
    WifiEventCallback _event_cb;
    WifiReadyCallback _ready_cb;

    WifiRxCallback _rx_cb;
    uint _rx_drops;
    int[2] _rx_args;
    ubyte _rx_tail;
    ubyte _rx_pending;

    WifiRawRxCallback _raw_rx_cb;
    Page* _raw_rx_head;
    Page* _raw_rx_tail;
    Page* _raw_rx_free;
    uint _raw_rx_epoch;
    uint _raw_rx_drops;
}

extern(C) nothrow @nogc
{
    ubyte bk_wlan_get_scan_ap_result_numbers();
    void bk_wlan_get_scan_ap_result(StaScanResult* table, ubyte count);
    int bk_wlan_set_channel(int channel);
    void ow_rw_monitor_start(ubyte channel);
    int bk_wlan_stop_monitor();
    void bk_wlan_register_monitor_cb(MonitorDataCallback fn);
    void wifi_get_mac_address(char* mac, ubyte role);

    int ow_rw_receive();
    void ke_evt_core_scheduler();
    void ke_evt_none_core_scheduler();
    void rxl_cntrl_evt(int dummy);
    void mr_kmsg_init();

    uint cfg_param_init();
    version (BK7231N)
        void manual_cal_load_bandgap_calm();
    void rwnxl_init();
    void calibration_main();
    uint manual_cal_load_txpwr_tab_flash();
    uint manual_cal_load_default_txpwr_tab(uint is_ready_flash);
    void manual_cal_load_lpf_iq_tag_flash();
    void manual_cal_load_xtal_tag_flash();
    void rwnx_cal_initial_calibration();

    int ow_rw_mac_step(uint step);
    void ow_rw_mac_quiesce();
    int ow_rw_add_if(const(ubyte)* mac);
    int ow_rw_scan(ubyte vif_idx, const(ubyte)* ssid, ubyte ssid_len);
    int ow_rw_transfer(ubyte vif_idx, ubyte* buf, uint len);
    byte ow_rw_get_rssi();
    int ow_rw_connect(ubyte vif_idx, const(ubyte)* ssid, ubyte ssid_len, const(ubyte)* bssid, const(ubyte)* ie, ushort ie_len, int psk, byte* rssi, ubyte* channel);
    int ow_rw_disconnect(ubyte vif_idx, ushort reason);
    int ow_rw_key_add_ccmp(ubyte vif_idx, ubyte sta_idx, ubyte key_idx, const(ubyte)* key, ubyte len, const(ubyte)* rsc);
    int ow_rw_control_port(ubyte sta_idx, int open);
    int ow_rw_classify(const(KeMsg)* m);
    void ow_rw_add_if_cfm(const(KeMsg)* m, ubyte* status, ubyte* vif_idx);
    void ow_rw_scanu_start_cfm(const(KeMsg)* m, ubyte* status, ubyte* vif_idx);
    void ow_rw_connect_cfm(const(KeMsg)* m, ubyte* status);
    void ow_rw_connect_ind(const(KeMsg)* m, ushort* status, ubyte* vif_idx, ubyte* ap_idx, ubyte* bssid);
    void ow_rw_disconnect_ind(const(KeMsg)* m, ubyte* vif_idx, ushort* reason);
    void ow_rw_fail_ind(const(KeMsg)* m, ushort* status);
    void ow_rw_key_add_cfm(const(KeMsg)* m, ubyte* status);
    int rwm_raw_frame_with_cb(ubyte* buffer, int len, void* cb, void* param);
}

void ethernet_input(uint iface, Page* pages)
{
    if (!pages)
        return;

    Page* frame_page = pages;
    if (pages.next)
    {
        size_t length;
        for (Page* page = pages; page; page = page.next)
            length += page.length;
        frame_page = length <= max_frame ? page_alloc(length, ubyte.alignof) : null;
        if (frame_page)
        {
            ubyte* output = cast(ubyte*)frame_page.data.ptr;
            for (Page* page = pages; page; page = page.next)
            {
                memcpy(output, page.data.ptr, page.length);
                output += page.length;
            }
        }
        free_pages(pages);
    }

    if (!frame_page || frame_page.length < 14 || frame_page.length > max_frame || _mac_state != MacState.ready || _sta_state < StaState.keying || iface != _sta_vif)
    {
        if (frame_page)
            page_free(frame_page);
        ++_rx_drops;
        return;
    }

    const(ubyte)[] frame = cast(const(ubyte)[])frame_page.data;
    _rssi = ow_rw_get_rssi();
    if (frame[12] == 0x88 && frame[13] == 0x8E)
        _supp.receive_eapol(frame[14 .. $]);
    else if (_sta_state == StaState.connected && _rx_cb)
    {
        Wifi w = Wifi(0);
        _rx_cb(w, WifiVif.sta, frame);
    }
    else
        ++_rx_drops;

    page_free(frame_page);
}

void free_pages(Page* pages)
{
    while (pages)
    {
        Page* next = pages.next;
        pages.next = null;
        page_free(pages);
        pages = next;
    }
}

RawRxInfo* raw_rx_info(Page* page)
    => cast(RawRxInfo*)(cast(ubyte*)page.data.ptr - RawRxInfo.sizeof);

bool prepare_raw_rx_pages()
{
    release_raw_rx_pages();
    foreach (_; 0 .. max_raw_rx_pending)
    {
        Page* page = page_alloc(max_raw_frame, ubyte.alignof, RawRxInfo.sizeof);
        if (!page)
            break;
        page.next = _raw_rx_free;
        _raw_rx_free = page;
    }
    return _raw_rx_free !is null;
}

Page* take_raw_rx_page()
{
    immutable bool prev = irq_disable();
    Page* page = _raw_rx_free;
    if (page)
    {
        _raw_rx_free = page.next;
        page.next = null;
    }
    if (prev)
        irq_enable();
    return page;
}

void release_raw_rx_page(Page* page)
{
    immutable bool prev = irq_disable();
    page.next = _raw_rx_free;
    _raw_rx_free = page;
    if (prev)
        irq_enable();
}

Page* pop_raw_rx()
{
    immutable bool prev = irq_disable();
    Page* page = _raw_rx_head;
    if (page)
    {
        _raw_rx_head = page.next;
        page.next = null;
        if (!_raw_rx_head)
            _raw_rx_tail = null;
    }
    if (prev)
        irq_enable();
    return page;
}

void discard_raw_rx()
{
    Page* page;
    while ((page = pop_raw_rx()) !is null)
        release_raw_rx_page(page);
}

void release_raw_rx_pages()
{
    Page* pages;
    immutable bool prev = irq_disable();
    ++_raw_rx_epoch;
    if (_raw_rx_tail)
    {
        _raw_rx_tail.next = _raw_rx_free;
        pages = _raw_rx_head;
    }
    else
        pages = _raw_rx_free;
    _raw_rx_head = null;
    _raw_rx_tail = null;
    _raw_rx_free = null;
    if (prev)
        irq_enable();
    free_pages(pages);
}

extern(C) void monitor_callback(ubyte* data, int len, WifiLinkInfo* info)
{
    if (!_open || _mode != WifiMode.monitor || !_raw_rx_cb || !data || len <= 0 || len > max_raw_frame)
    {
        ++_raw_rx_drops;
        if (_ready_cb)
            _ready_cb();
        return;
    }

    Page* page = take_raw_rx_page();
    if (!page)
    {
        ++_raw_rx_drops;
        if (_ready_cb)
            _ready_cb();
        return;
    }
    memcpy(page.data.ptr, data, len);
    RawRxInfo* rx_info = raw_rx_info(page);
    rx_info.rssi = info ? info.rssi : 0;
    rx_info.channel = _channel;

    page.length = cast(ushort)len;
    immutable bool prev = irq_disable();
    if (_raw_rx_tail)
        _raw_rx_tail.next = page;
    else
        _raw_rx_head = page;
    _raw_rx_tail = page;
    if (prev)
        irq_enable();
    if (_ready_cb)
        _ready_cb();
}

const(char)[] sta_status_message(StaStatus status)
    => sta_status_messages[status];

WifiAuth scan_auth(int security)
    => cast(uint)security < scan_auths.length ? scan_auths[security] : WifiAuth.wpa_wpa2_psk;

public MonoTime wifi_hw_service_deadline(ubyte port)
    => _open ? _deadline : MonoTime.init;

void arm_deadline(Duration timeout)
{
    _deadline = getTime() + timeout;
    if (_ready_cb)
        _ready_cb();
}

void mac_submit_step()
{
    if (ow_rw_mac_step(_mac_state - MacState.reset) == 0)
        arm_deadline(2.seconds);
    else
    {
        request_mac_reset();
        _sta_status = StaStatus.mac_request_failed;
    }
}

void mac_start()
{
    _mac_state = MacState.reset;
    mac_submit_step();
}

void request_mac_reset()
{
    if (_mac_state != MacState.reset_pending)
        _events.clear();
    _mac_state = MacState.reset_pending;
    if (_ready_cb)
        _ready_cb();
}

void mac_reset()
{
    ow_rw_mac_quiesce();
    ++_service_epoch;
    _mac_state = _open ? MacState.retry : MacState.stopped;
    _sta_vif = no_vif;
    _scanning = false;
    _key_pending = 0;
    _rx_pending = 0;
    _rx_tail = 0;
    _supp.disconnected(reason_deauth_leaving);
    _rssi = 0;
    if (_sta_state >= StaState.idle)
        push_event(WifiEventRecord(WifiEvent.sta_stopped));
    _sta_state = StaState.offline;
    _deadline = MonoTime.init;
    if (_open)
        arm_deadline(1.seconds);
}

void firmware_timeout()
{
    request_mac_reset();
    _sta_status = StaStatus.firmware_timeout;
    if (_sta_state >= StaState.deriving)
        push_event(WifiEventRecord(WifiEvent.sta_disconnected, _sta_status));
    if (_scanning)
        push_event(WifiEventRecord(WifiEvent.scan_done));
    mac_reset();
}

void stop_sta()
{
    if (_sta_state != StaState.offline)
        request_mac_reset();
    _supp.disconnected(reason_deauth_leaving);
    _sta_state = _sta_state >= StaState.idle ? StaState.idle : StaState.offline;
    _rssi = 0;
    _key_pending = 0;
}

bool sta_vif_up()
{
    if (_sta_state != StaState.offline)
        return true;
    ubyte[6] mac = void;
    wifi_get_mac_address(cast(char*)mac.ptr, bk_role_sta);
    if (ow_rw_add_if(mac.ptr) != 0)
        return false;
    _sta_state = StaState.starting;
    arm_deadline(2.seconds);
    return true;
}

void sta_derive_slice()
{
    import urt.driver.bk7231.timer : mtime_read;
    enum ulong slice_ticks = 26_000_000 / 1000 * 4;
    ulong until = mtime_read() + slice_ticks;
    bool done;
    do
        done = _supp.pmk_step(8);
    while (!done && mtime_read() < until);
    if (!done)
        return;

    _sta_status = StaStatus.connecting;
    if (!sta_scan())
        sta_failed(StaStatus.scan_failed, 0);
}

bool sta_scan()
{
    if (ow_rw_scan(_sta_vif, _sta_ssid_buf.ptr, _sta_ssid_len) != 0)
    {
        _sta_state = StaState.idle;
        _sta_status = StaStatus.scan_failed;
        return false;
    }
    arm_deadline(10.seconds);
    _sta_state = StaState.scanning;
    return true;
}

void sta_join()
{
    ubyte[6] mac = void;
    bool psk = _supp.profile.key_mgmt == WpaKeyMgmt.wpa2_psk;
    wifi_get_mac_address(cast(char*)mac.ptr, bk_role_sta);
    _key_pending = 0;
    _supp.begin_association(mac, psk ? wpa2_psk_ccmp_rsn_ie[] : null);

    bool any_bssid = true;
    foreach (b; _sta_bssid)
        any_bssid &= b == 0;
    const(ubyte)* bssid = any_bssid ? null : _sta_bssid.ptr;
    const(ubyte)* ie = psk ? wpa2_psk_ccmp_rsn_ie.ptr : null;
    ushort ie_length = psk ? cast(ushort)wpa2_psk_ccmp_rsn_ie.length : 0;
    int rc = ow_rw_connect(_sta_vif, _sta_ssid_buf.ptr, _sta_ssid_len, bssid, ie, ie_length, psk, &_rssi, &_channel);
    if (rc != 0)
    {
        StaStatus status = rc == -2 ? StaStatus.network_not_found : StaStatus.connect_request_failed;
        sta_failed(status, 0);
        return;
    }
    _sta_state = StaState.associating;
    arm_deadline(15.seconds);
}

void sta_failed(StaStatus status, ushort reason)
{
    request_mac_reset();
    _supp.disconnected(reason);
    _sta_state = StaState.idle;
    _rssi = 0;
    _key_pending = 0;
    _sta_status = status;
    push_event(WifiEventRecord(WifiEvent.sta_disconnected, status, reason));
}

void sta_start_failed()
{
    _sta_state = StaState.offline;
    _rssi = 0;
    _mode = WifiMode.none;
    _sta_status = StaStatus.vif_add_failed;
    push_event(WifiEventRecord(WifiEvent.sta_start_failed, _sta_status));
}

bool sta_send_eapol(const(ubyte)[] eapol)
{
    if (_sta_vif == no_vif || eapol.length > wpa_max_eapol_len)
        return false;
    ubyte[14 + wpa_max_eapol_len] frame = void;
    frame[0 .. 6] = _supp.fourway.bssid[];
    frame[6 .. 12] = _supp.own_mac[];
    frame[12] = 0x88;
    frame[13] = 0x8E;
    frame[14 .. 14 + eapol.length] = eapol[];
    return ow_rw_transfer(_sta_vif, frame.ptr, cast(uint)(eapol.length + 14)) == 0;
}

bool sta_install_pairwise(const(ubyte)[] tk, const(ubyte)[] rsc)
    => sta_install_key(_sta_ap_idx, 0, tk, rsc);

bool sta_install_group(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
    => sta_install_key(no_vif, key_idx, gtk, rsc);

bool sta_install_key(ubyte sta_idx, ubyte key_idx, const(ubyte)[] key, const(ubyte)[] rsc)
{
    if (key.length != 16 || rsc.length != 6 || ow_rw_key_add_ccmp(_sta_vif, sta_idx, key_idx, key.ptr, cast(ubyte)key.length, rsc.ptr) != 0)
        return false;
    ++_key_pending;
    arm_deadline(2.seconds);
    return true;
}

bool sta_auth_done(ushort reason)
{
    if (reason != 0)
    {
        writeDebug("wifi: sta auth failed reason=", reason);
        ow_rw_disconnect(_sta_vif, reason);
        sta_failed(StaStatus.auth_failed, reason);
        return true;
    }
    if (_key_pending)
    {
        _sta_state = StaState.installing;
        return true;
    }
    return sta_auth_complete();
}

bool sta_auth_complete()
{
    if (ow_rw_control_port(_sta_ap_idx, 1) != 0)
    {
        ow_rw_disconnect(_sta_vif, reason_deauth_leaving);
        sta_failed(StaStatus.control_port_failed, 0);
        return false;
    }
    _sta_state = StaState.control_port;
    arm_deadline(2.seconds);
    return true;
}

void sta_connected()
{
    _sta_state = StaState.connected;
    _sta_status = StaStatus.connected;
    _deadline = MonoTime.init;
    push_event(WifiEventRecord(WifiEvent.sta_connected));
}

bool mac_confirmation(OwRwMsg kind)
{
    if (kind < OwRwMsg.reset_cfm)
        return false;
    if (_mac_state >= MacState.reset && _mac_state <= MacState.start && kind == OwRwMsg.reset_cfm + _mac_state - MacState.reset)
    {
        if (++_mac_state == MacState.ready)
        {
            _deadline = MonoTime.init;
            if (_mode == WifiMode.sta && !sta_vif_up())
                sta_start_failed();
        }
        else
            mac_submit_step();
    }
    return true;
}

extern(C) void ow_wifi_message(KeMsg* m)
{
    if (_mac_state == MacState.reset_pending || !_open)
        return;
    OwRwMsg kind = cast(OwRwMsg)ow_rw_classify(m);
    if (mac_confirmation(kind))
        return;
    if (_mac_state != MacState.ready)
        return;
    final switch (kind)
    {
        case OwRwMsg.add_if_cfm:
        {
            ubyte status, idx;
            ow_rw_add_if_cfm(m, &status, &idx);
            if (_sta_state == StaState.starting)
            {
                _deadline = MonoTime.init;
                if (status == 0)
                {
                    _sta_vif = idx;
                    _sta_state = StaState.idle;
                    if (_mode == WifiMode.sta)
                        push_event(WifiEventRecord(WifiEvent.sta_started));
                }
                else
                    sta_start_failed();
            }
            break;
        }
        case OwRwMsg.scanu_start_cfm:
        {
            ubyte status, vif;
            ow_rw_scanu_start_cfm(m, &status, &vif);
            if (_scanning && vif == no_vif)
            {
                _deadline = MonoTime.init;
                _scanning = false;
                push_event(WifiEventRecord(WifiEvent.scan_done));
            }
            else if (_sta_state == StaState.scanning && vif == _sta_vif)
            {
                if (status == 0)
                    sta_join();
                else
                    sta_failed(StaStatus.scan_failed, status);
            }
            break;
        }
        case OwRwMsg.beacon_lose_ind:
            if (_sta_state >= StaState.keying)
                sta_failed(StaStatus.beacon_lost, 0);
            break;
        case OwRwMsg.auth_fail_ind:
        {
            ushort status;
            ow_rw_fail_ind(m, &status);
            if (_sta_state == StaState.associating)
            {
                StaStatus failure = status == reason_too_many_stations ? StaStatus.association_refused : StaStatus.auth_failed;
                sta_failed(failure, status);
            }
            break;
        }
        case OwRwMsg.assoc_fail_ind:
        {
            ushort status;
            ow_rw_fail_ind(m, &status);
            if (_sta_state == StaState.associating)
            {
                StaStatus failure = status == status_too_many_stations ? StaStatus.association_refused : StaStatus.association_failed;
                sta_failed(failure, status);
            }
            break;
        }
        case OwRwMsg.disassoc_ind:
        {
            ushort status;
            ow_rw_fail_ind(m, &status);
            if (_sta_state >= StaState.keying)
                sta_failed(StaStatus.disconnected, status);
            break;
        }
        case OwRwMsg.connect_cfm:
        {
            ubyte status;
            ow_rw_connect_cfm(m, &status);
            if (status != 0 && _sta_state == StaState.associating)
                sta_failed(StaStatus.connect_request_failed, status);
            break;
        }
        case OwRwMsg.connect_ind:
        {
            ushort status;
            ubyte vif, ap_idx;
            ubyte[6] bssid = void;
            ow_rw_connect_ind(m, &status, &vif, &ap_idx, bssid.ptr);
            if (vif != _sta_vif || _sta_state != StaState.associating)
                break;
            if (status != 0)
            {
                writeDebug("wifi: sta assoc failed status=", status);
                sta_failed(StaStatus.association_failed, status);
                break;
            }
            _sta_ap_idx = ap_idx;
            _sta_state = StaState.keying;
            arm_deadline(10.seconds);
            _supp.associated(bssid);
            break;
        }
        case OwRwMsg.disconnect_ind:
        {
            ushort reason;
            ubyte vif;
            ow_rw_disconnect_ind(m, &vif, &reason);
            writeDebug("wifi: sta disconnect ind reason=", reason);
            if (vif == _sta_vif && _sta_state >= StaState.associating)
                sta_failed(StaStatus.disconnected, reason);
            break;
        }
        case OwRwMsg.key_add_cfm:
        {
            ubyte status;
            ow_rw_key_add_cfm(m, &status);
            if (_key_pending == 0 || (_sta_state != StaState.installing && _sta_state != StaState.connected))
                break;
            --_key_pending;
            if (_sta_state == StaState.connected)
            {
                _deadline = MonoTime.init;
                _supp.fourway.group_key_installed(status == 0);
            }
            else if (status != 0)
            {
                ow_rw_disconnect(_sta_vif, reason_deauth_leaving);
                sta_failed(StaStatus.key_install_failed, status);
            }
            else if (_key_pending == 0)
                sta_auth_complete();
            break;
        }
        case OwRwMsg.control_port_cfm:
            if (_sta_state == StaState.control_port)
                sta_connected();
            break;
        case OwRwMsg.other:
        case OwRwMsg.reset_cfm:
        case OwRwMsg.config_cfm:
        case OwRwMsg.channel_config_cfm:
        case OwRwMsg.start_cfm:
            break;
    }
}

void push_event(WifiEventRecord event)
{
    if (!_events.push(event))
        ++_event_drops;
    else if (_ready_cb)
        _ready_cb();
}

uint take_drop_count(ref uint count)
{
    immutable bool prev = irq_disable();
    uint result = count;
    count = 0;
    if (prev)
        irq_enable();
    return result;
}

bool needs_service_wake()
    => _mac_state == MacState.reset_pending || _deadline || _rx_pending || _raw_rx_head || !_events.empty || _sta_state == StaState.deriving;

extern(C) int ethernetif_init(void* netif)
    => 0;

extern(C) int lwip_netif_init(void* netif)
    => 0;

extern(C) int lwip_netif_uap_init(void* netif)
    => 0;

// The vendor invokes this wake from interrupt context, so it may only signal service.
extern(C) void __wrap_app_set_sema()
{
    if (_ready_cb)
        _ready_cb();
}

extern(C) void __wrap_bmsg_null_sender()
{
    if (_ready_cb)
        _ready_cb();
}

extern(C) void __wrap_bmsg_rx_sender(void* arg)
{
    immutable bool prev = irq_disable();
    if (_rx_pending < 2)
    {
        _rx_args[(_rx_tail + _rx_pending) % _rx_args.length] = cast(int)cast(size_t)arg;
        ++_rx_pending;
    }
    else
        ++_rx_drops;
    if (prev)
        irq_enable();
    if (_ready_cb)
        _ready_cb();
}

extern(C) int __wrap_bmsg_is_empty()
    => _rx_pending == 0 ? 1 : 0;

extern(C) void ow_log_vendor(const(char)* msg, size_t len) nothrow @nogc
{
    const(char)[] s = msg[0 .. len];
    while (s.length && (s[$-1] == '\r' || s[$-1] == '\n'))
        s = s[0 .. $-1];
    if (s.length)
        writeDebug(s);
}

unittest
{
    EventQueue events;
    foreach (i; 0 .. EventQueue.capacity)
    {
        WifiEventRecord event = WifiEventRecord(WifiEvent.sta_disconnected, StaStatus.disconnected, cast(ushort)i);
        assert(events.push(event));
    }
    assert(!events.push(WifiEventRecord(WifiEvent.scan_done)));

    foreach (i; 0 .. EventQueue.capacity)
    {
        WifiEventRecord event = events.pop();
        assert(event.event == WifiEvent.sta_disconnected);
        assert(event.status == StaStatus.disconnected);
        assert(event.reason == i);
    }
    assert(events.empty);

    assert(events.push(WifiEventRecord(WifiEvent.scan_done)));
    assert(events.pop().event == WifiEvent.scan_done);
    assert(events.empty);

    import urt.mem.pagepool : page_pool_init, page_pool_deinit;

    static void close_rx(Wifi wifi, const(ubyte)[] frame, byte rssi, ubyte channel) nothrow @nogc
    {
        wifi_hw_close(0);
    }

    static void reopened_rx(Wifi wifi, const(ubyte)[] frame, byte rssi, ubyte channel) nothrow @nogc
    {
        assert(false, "old service invocation dispatched a new session's RX");
    }

    static void reopen_rx(Wifi wifi, const(ubyte)[] frame, byte rssi, ubyte channel) nothrow @nogc
    {
        wifi_hw_close(0);
        WifiConfig cfg;
        assert(wifi_hw_open(0, cfg));
        assert(prepare_raw_rx_pages());
        _mode = WifiMode.monitor;
        _raw_rx_cb = &reopened_rx;
        ubyte[24] packet;
        monitor_callback(packet.ptr, cast(int)packet.length, null);
    }

    assert(page_pool_init());
    scope(exit) page_pool_deinit();
    _mac_state = MacState.ready;
    _initialized = true;
    foreach (callback; [&close_rx, &reopen_rx])
    {
        WifiConfig cfg;
        assert(wifi_hw_open(0, cfg));
        assert(prepare_raw_rx_pages());
        _mode = WifiMode.monitor;
        _raw_rx_cb = callback;
        ubyte[24] packet;
        monitor_callback(packet.ptr, cast(int)packet.length, null);
        wifi_hw_service(0, 32);
        if (callback == &close_rx)
            assert(!_open && _raw_rx_free is null && _raw_rx_head is null);
        else
        {
            assert(_open && _raw_rx_head && !_raw_rx_head.next);
            size_t count = 1;
            for (Page* page = _raw_rx_free; page; page = page.next)
                ++count;
            assert(count == max_raw_rx_pending);
            wifi_hw_close(0);
        }
    }
    _mode = WifiMode.none;
    _open = true;
    struct ReceiveGate
    {
        static uint packets;
        static void receive(Wifi wifi, WifiVif vif, const(ubyte)[] frame) nothrow @nogc
        {
            ++packets;
        }
    }
    _mac_state = MacState.ready;
    _sta_vif = 0;
    _rx_cb = &ReceiveGate.receive;
    foreach (state; [StaState.keying, StaState.control_port, StaState.connected])
    {
        _sta_state = state;
        Page* frame = page_alloc(14, ubyte.alignof);
        assert(frame);
        (cast(ubyte[])frame.data)[] = 0;
        ethernet_input(0, frame);
        assert(ReceiveGate.packets == (state == StaState.connected ? 1 : 0));
    }
    _rx_cb = null;
    _sta_state = StaState.idle;
    foreach (step; 0 .. 4)
    {
        mac_start();
        foreach (prior; 0 .. step)
            assert(mac_confirmation(cast(OwRwMsg)(OwRwMsg.reset_cfm + prior)));
        assert(_mac_state == MacState.reset + step && wifi_hw_service_deadline(0));
        assert(mac_confirmation(step == 3 ? OwRwMsg.reset_cfm : OwRwMsg.start_cfm));
        assert(_mac_state == MacState.reset + step);

        _deadline = getTime();
        wifi_hw_service(0, 32);
        assert(_mac_state == MacState.retry);
        assert(_sta_status == StaStatus.firmware_timeout);
        assert(mac_confirmation(OwRwMsg.start_cfm));
        assert(_mac_state != MacState.ready);
        _deadline = getTime();
        wifi_hw_service(0, 32);
        assert(_mac_state == MacState.reset);
        foreach (confirmation; OwRwMsg.reset_cfm .. OwRwMsg.start_cfm + 1)
            assert(mac_confirmation(cast(OwRwMsg)confirmation));
        assert(_mac_state == MacState.ready && !wifi_hw_service_deadline(0));
    }
    foreach (state; [StaState.scanning, StaState.associating, StaState.keying, StaState.installing, StaState.control_port, StaState.connected])
    {
        mac_start();
        foreach (confirmation; OwRwMsg.reset_cfm .. OwRwMsg.start_cfm + 1)
            mac_confirmation(cast(OwRwMsg)confirmation);
        _sta_state = state;
        _sta_vif = 0;
        _key_pending = state == StaState.connected ? 1 : 0;
        _deadline = getTime();
        wifi_hw_service(0, 32);
        assert(_mac_state == MacState.retry && _sta_vif == no_vif);
        assert(_sta_state == StaState.offline && !_key_pending);
    }

    foreach (state; [StaState.offline, StaState.starting])
    {
        _sta_state = state;
        firmware_timeout();
        assert(_events.empty);
    }

    _mode = WifiMode.sta;
    mac_start();
    foreach (confirmation; OwRwMsg.reset_cfm .. OwRwMsg.start_cfm + 1)
        mac_confirmation(cast(OwRwMsg)confirmation);
    assert(_mac_state == MacState.ready && _sta_state == StaState.starting);
    WifiScanConfig scan;
    MonoTime vif_deadline = _deadline;
    assert(!wifi_hw_scan_start(0, scan));
    assert(_deadline == vif_deadline && !_scanning);

    _sta_state = StaState.keying;
    _key_pending = 2;
    assert(sta_auth_done(0));
    assert(_sta_state == StaState.installing && _key_pending == 2);
    wifi_hw_close(0);
    assert(!wifi_hw_service_deadline(0));
    _initialized = false;
}
