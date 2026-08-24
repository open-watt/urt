module urt.driver.bk7231.wifi;

version (Beken):

import urt.driver.wifi;
import urt.log;
import urt.mem : memcpy;
import urt.mem.pagepool : Page, page_alloc, page_free;
import urt.result : Result;
import urt.driver.bk7231.pbuf : beken_ethernet_input_handler;
import urt.driver.irq : irq_disable, irq_enable;
import urt.driver.wpa : wpa2_psk_ccmp_rsn_ie;
import urt.driver.wpa.supplicant : WpaStaSupplicant, WpaKeyMgmt;

nothrow @nogc:

enum uint num_wifi = 1;
enum ubyte wifi_max_ap_clients = 0;

void wifi_hw_set_ready_callback(WifiReadyCallback cb)
{
    _ready_cb = cb;
}

bool wifi_hw_open(ubyte port, ref const WifiConfig cfg)
{
    if (port >= num_wifi || _open || cfg.tx_power != 0 || cfg.country != ubyte[2].init ||
        (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
        return false;

    _mode = WifiMode.none;
    _sta_status = "idle";
    _events.clear();
    _open = true;

    if (!_mac_ready)
    {
        _sta_vif = no_vif;
        _channel = 1;
        mr_kmsg_init();
        cfg_param_init();
        char[6] mac = void;
        wifi_get_mac_address(mac.ptr, BK_ROLE_NULL);
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
        if (ow_rw_mac_init() != 0)
        {
            writeWarning("wifi: MAC start failed");
            _open = false;
            return false;
        }
        _mac_ready = true;
    }

    bk_wlan_status_register_cb(&status_callback);
    if (cfg.channel)
    {
        if (cfg.channel > 14 || bk_wlan_set_channel(cfg.channel) != 0)
        {
            bk_wlan_status_register_cb(null);
            _open = false;
            return false;
        }
        _channel = cfg.channel;
    }
    beken_ethernet_input_handler(&ethernet_input);
    return true;
}

void wifi_hw_close(ubyte port)
{
    if (!_open)
        return;

    if (_monitor)
    {
        bk_wlan_stop_monitor();
        _monitor = false;
    }
    stop_sta();
    _sta_active = false;
    beken_ethernet_input_handler(null);
    bk_wlan_status_register_cb(null);

    _mode = WifiMode.none;
    _scanning = false;
    _open = false;
    _rx_cb = null;
    _raw_rx_cb = null;
    _event_cb = null;
}

bool wifi_hw_set_mode(ubyte port, WifiMode mode)
{
    if (!_open || mode == WifiMode.ap || mode == WifiMode.apsta)
        return false;
    if (mode == _mode)
        return true;

    if (_monitor)
    {
        bk_wlan_stop_monitor();
        _monitor = false;
    }
    if (_mode == WifiMode.sta)
    {
        stop_sta();
        if (_sta_active)
            push_event(WifiEvent.sta_stopped);
        _sta_active = false;
    }
    _mode = WifiMode.none;

    final switch (mode)
    {
        case WifiMode.none:
            break;

        case WifiMode.monitor:
            bk_wlan_register_monitor_cb(&monitor_callback);
            if (bk_wlan_start_monitor() != 0)
                return false;
            _monitor = true;
            break;

        case WifiMode.sta:
            if (!sta_vif_up())
                return false;
            if (_sta_vif != no_vif)
            {
                _sta_active = true;
                push_event(WifiEvent.sta_started);
            }
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
    if (!_open)
        return false;
    if (cfg.ssid.length == 0 || cfg.ssid.length > 32 || cfg.password.length > 64)
        return false;

    bool same = cfg.ssid.length == _sta_ssid_len && cfg.password.length == _sta_pass_len &&
                cast(const(ubyte)[])cfg.ssid[] == _sta_ssid_buf[0 .. _sta_ssid_len] &&
                cast(const(ubyte)[])cfg.password[] == _sta_pass_buf[0 .. _sta_pass_len];
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
        _sta_status = "unsupported security";
        return false;
    }
    _supp.hooks.send_eapol = &sta_send_eapol;
    _supp.hooks.install_pairwise_key = &sta_install_pairwise;
    _supp.hooks.install_group_key = &sta_install_group;
    _supp.hooks.auth_done = &sta_auth_done;
    return true;
}

const(char)[] wifi_hw_sta_status_message(ubyte port)
{
    return _sta_status;
}

bool wifi_hw_sta_connect(ubyte port)
{
    if (!_open || !_mac_ready || _mode != WifiMode.sta || !_sta_active || _sta_ssid_len == 0)
        return false;

    if (!_supp.pmk_ready)
    {
        _sta_state = StaState.deriving;
        _sta_status = "deriving key";
        return true;
    }
    _sta_state = StaState.scanning;
    _sta_status = "connecting";
    if (_sta_vif == no_vif)
        return sta_vif_up();
    return sta_scan();
}

bool wifi_hw_sta_disconnect(ubyte port)
{
    if (!_open)
        return false;

    stop_sta();
    _sta_status = "disconnected";
    return true;
}

bool wifi_hw_ap_configure(ubyte port, ref const WifiApConfig cfg)
{
    return false;
}

bool wifi_hw_ap_set_max_clients(ubyte port, ubyte max_clients)
{
    return false;
}

size_t wifi_hw_ap_get_clients(ubyte port, WifiStaInfo[] buf)
{
    return 0;
}

bool wifi_hw_scan_start(ubyte port, ref const WifiScanConfig cfg)
{
    bool has_bssid;
    foreach (b; cfg.bssid)
        has_bssid |= b != 0;
    if (!_open || _scanning || _sta_state == StaState.scanning || cfg.ssid.length || has_bssid ||
        cfg.channel || cfg.passive || cfg.dwell_ms ||
        (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
        return false;

    _scanning = true;
    bk_wlan_start_scan();
    return true;
}

void wifi_hw_scan_stop(ubyte port)
{
    if (_scanning)
    {
        bk_wlan_terminate_sta_rescan();
        _scanning = false;
    }
}

size_t wifi_hw_scan_get_results(ubyte port, WifiScanResult[] buf)
{
    if (!_open || buf.length == 0)
        return 0;

    ubyte avail = bk_wlan_get_scan_ap_result_numbers();
    if (avail == 0)
        return 0;

    sta_scan_res[8] scratch;
    size_t count = avail < buf.length ? avail : buf.length;
    if (count > scratch.length)
        count = scratch.length;

    bk_wlan_get_scan_ap_result(scratch.ptr, cast(ubyte)count);

    foreach (i; 0 .. count)
    {
        const(sta_scan_res)* r = &scratch[i];
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
    if (!_open || vif != WifiVif.sta || !_sta_active || _sta_vif == no_vif ||
        data.length < 14 || data.length > max_frame)
        return false;

    // rwm_transfer returns failure after successfully queueing, so only admission can be checked.
    rwm_transfer(_sta_vif, cast(ubyte*)data.ptr, cast(uint)data.length, 0, null);
    return true;
}

void wifi_hw_set_rx_callback(ubyte port, WifiRxCallback cb)
{
    _rx_cb = cb;
}

uint wifi_hw_take_rx_drops(ubyte port)
{
    uint n = _rx_drops;
    _rx_drops = 0;
    return n;
}

bool wifi_hw_raw_tx(ubyte port, const(ubyte)[] frame)
{
    if (!_open || frame.length == 0)
        return false;
    return rwm_raw_frame_with_cb(cast(ubyte*)frame.ptr, cast(int)frame.length, null, null) == 0;
}

void wifi_hw_set_raw_rx_callback(ubyte port, WifiRawRxCallback cb)
{
    _raw_rx_cb = cb;
}

uint wifi_hw_take_raw_rx_drops(ubyte port)
{
    uint n = _raw_rx_drops;
    _raw_rx_drops = 0;
    return n;
}

bool wifi_hw_get_mac(ubyte port, WifiVif vif, ref ubyte[6] mac)
{
    if (!_open || vif != WifiVif.sta)
        return false;
    wifi_get_mac_address(cast(char*)mac.ptr, BK_ROLE_STA);
    return true;
}

ubyte wifi_hw_get_channel(ubyte port)
{
    return _channel;
}

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
{
    return _rssi;
}

bool wifi_hw_set_tx_power(ubyte port, byte power_dbm)
{
    return false;
}

void wifi_hw_set_event_callback(ubyte port, WifiEventCallback cb)
{
    _event_cb = cb;
}

uint wifi_hw_take_event_drops(ubyte port)
{
    uint n = _event_drops;
    _event_drops = 0;
    return n;
}

// The vendor runs the core and message schedulers on separate threads; both are serviced here.
bool wifi_hw_service(ubyte port, size_t budget)
{
    if (!_open)
        return false;

    for (;;)
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
    }
    ke_evt_core_scheduler();
    rwnx_recv_msg();
    ke_evt_none_core_scheduler();

    if (_sta_state == StaState.deriving)
        sta_derive_slice();

    size_t served = 0;
    while (served < budget && !_events.empty)
    {
        WifiEvent e = _events.pop();
        if (_event_cb)
        {
            Wifi w = Wifi(port);
            _event_cb(w, e, null);
        }
        ++served;
    }
    return !_events.empty || _rx_pending != 0 || _sta_state == StaState.deriving;
}

private:
enum ubyte BK_ROLE_NULL = 0;
enum ubyte BK_ROLE_STA = 2;

enum uint max_frame = 1600;

enum int RW_EVT_STA_SCAN_OVER = 2;
enum int RW_EVT_STA_BEACON_LOSE = 4;
enum int RW_EVT_STA_PASSWORD_WRONG = 5;
enum int RW_EVT_STA_NO_AP_FOUND = 6;
enum int RW_EVT_STA_ASSOC_FULL = 7;
enum int RW_EVT_STA_DISCONNECTED = 8;
enum int RW_EVT_STA_CONNECT_FAILED = 9;
enum ubyte no_vif = 0xFF;
enum ushort reason_deauth_leaving = 3;

enum WifiAuth[7] scan_auths = [
    WifiAuth.open,
    WifiAuth.wep,
    WifiAuth.wpa_psk,
    WifiAuth.wpa_psk,
    WifiAuth.wpa2_psk,
    WifiAuth.wpa2_psk,
    WifiAuth.wpa2_psk,
];

enum OwRwMsg : int
{
    other = 0,
    add_if_cfm,
    scanu_start_cfm,
    connect_cfm,
    connect_ind,
    disconnect_ind,
    key_add_cfm,
    control_port_cfm,
}

enum StaState : ubyte
{
    idle,
    deriving,
    scanning,
    associating,
    keying,
    control_port,
    connected,
}

struct sta_scan_res
{
    ubyte[6]    bssid;
    char[32]    ssid;
    char        on_channel;
    char        channel;
    ushort      beacon_int;
    ushort      caps;
    int         level;
    int         security;
    ubyte[8]    tsf;
    uint        ie_len;
}

struct hal_wifi_link_info_t
{
    byte rssi;
}

struct ke_msg;

struct EventQueue
{
nothrow @nogc:
    enum size_t capacity = 16;

    bool empty() const pure => _count == 0;

    void clear()
    {
        _head = _tail = _count = 0;
    }

    bool push(WifiEvent e)
    {
        if (_count == capacity)
            return false;
        _buf[_tail] = e;
        _tail = (_tail + 1) % capacity;
        ++_count;
        return true;
    }

    WifiEvent pop()
    {
        WifiEvent e = _buf[_head];
        _head = (_head + 1) % capacity;
        --_count;
        return e;
    }

private:
    WifiEvent[capacity] _buf;
    size_t _head, _tail, _count;
}

alias monitor_data_cb_t = extern(C) void function(ubyte* data, int len, hal_wifi_link_info_t* info) nothrow @nogc;
alias status_cb_t = extern(C) void function(void* ctxt) nothrow @nogc;

__gshared
{
    bool                _open;
    bool                _mac_ready;
    bool                _sta_active;
    bool                _monitor;
    bool                _scanning;
    ubyte               _channel;
    byte                _rssi;
    WifiMode            _mode;
    const(char)[]       _sta_status;

    WpaStaSupplicant    _supp;
    StaState            _sta_state;
    ubyte               _sta_vif;
    bool                _sta_vif_pending;
    ubyte               _sta_ap_idx;
    ubyte               _key_pending;
    bool                _auth_pending;
    ubyte               _sta_ssid_len;
    ubyte               _sta_pass_len;
    ubyte[32]           _sta_ssid_buf;
    ubyte[64]           _sta_pass_buf;
    ubyte[6]            _sta_bssid;

    EventQueue          _events;
    int[4]              _rx_args;
    ubyte               _rx_tail;
    ubyte               _rx_pending;
    uint                _rx_drops;
    uint                _raw_rx_drops;
    uint                _event_drops;

    WifiRxCallback      _rx_cb;
    WifiRawRxCallback   _raw_rx_cb;
    WifiEventCallback   _event_cb;
    WifiReadyCallback   _ready_cb;
}

extern(C) nothrow @nogc
{
    void  bk_wlan_start_scan();
    void  bk_wlan_terminate_sta_rescan();
    ubyte bk_wlan_get_scan_ap_result_numbers();
    void  bk_wlan_get_scan_ap_result(sta_scan_res* table, ubyte count);
    int   bk_wlan_set_channel(int channel);
    int   bk_wlan_start_monitor();
    int   bk_wlan_stop_monitor();
    void  bk_wlan_register_monitor_cb(monitor_data_cb_t fn);
    void  bk_wlan_status_register_cb(status_cb_t cb);
    void  wifi_get_mac_address(char* mac, ubyte role);

    uint  rwm_transfer(ubyte vif_idx, ubyte* buf, uint len, int sync, void* args);
    void  rwnx_recv_msg();
    void  ke_evt_core_scheduler();
    void  ke_evt_none_core_scheduler();
    void  rxl_cntrl_evt(int dummy);
    void  mr_kmsg_init();

    uint  cfg_param_init();
    version (BK7231N)
        void manual_cal_load_bandgap_calm();
    void  rwnxl_init();
    void  calibration_main();
    uint  manual_cal_load_txpwr_tab_flash();
    uint  manual_cal_load_default_txpwr_tab(uint is_ready_flash);
    void  manual_cal_load_lpf_iq_tag_flash();
    void  manual_cal_load_xtal_tag_flash();
    void  rwnx_cal_initial_calibration();

    int   ow_rw_mac_init();
    int   ow_rw_add_if(const(ubyte)* mac, int ap);
    int   ow_rw_scan(ubyte vif_idx, const(ubyte)* ssid, ubyte ssid_len);
    int   ow_rw_connect(ubyte vif_idx, const(ubyte)* ssid, ubyte ssid_len, const(ubyte)* bssid,
                        const(ubyte)* ie, ushort ie_len, int psk, ubyte* channel);
    int   ow_rw_disconnect(ubyte vif_idx, ushort reason);
    int   ow_rw_key_add_ccmp(ubyte vif_idx, ubyte sta_idx, ubyte key_idx, const(ubyte)* key, ubyte len);
    int   ow_rw_control_port(ubyte sta_idx, int open);
    int   ow_rw_classify(const(ke_msg)* m);
    void  ow_rw_add_if_cfm(const(ke_msg)* m, ubyte* status, ubyte* vif_idx);
    void  ow_rw_scanu_start_cfm(const(ke_msg)* m, ubyte* status, ubyte* vif_idx);
    void  ow_rw_connect_cfm(const(ke_msg)* m, ubyte* status);
    void  ow_rw_connect_ind(const(ke_msg)* m, ushort* status, ubyte* vif_idx, ubyte* ap_idx, ubyte* bssid, ushort* aid);
    void  ow_rw_disconnect_ind(const(ke_msg)* m, ubyte* vif_idx, ushort* reason);
    void  ow_rw_key_add_cfm(const(ke_msg)* m, ubyte* status, ubyte* hw_key_idx);
    ushort ow_rw_msg_id(const(ke_msg)* m);
    void  __real_rwnx_handle_recv_msg(ke_msg* m);
    int   rwm_raw_frame_with_cb(ubyte* buffer, int len, void* cb, void* param);
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

    if (!frame_page)
    {
        ++_rx_drops;
        return;
    }

    const(ubyte)[] frame = cast(const(ubyte)[])frame_page.data;
    if (frame.length >= 14 && iface == _sta_vif && frame[12] == 0x88 && frame[13] == 0x8E)
        _supp.receive_eapol(frame[14 .. $]);
    else if (_rx_cb && frame.length)
    {
        Wifi w = Wifi(0);
        WifiVif vif = iface == _sta_vif ? WifiVif.sta : WifiVif.ap;
        _rx_cb(w, vif, frame);
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

extern(C) void monitor_callback(ubyte* data, int len, hal_wifi_link_info_t* info)
{
    if (!_raw_rx_cb || !data || len <= 0)
    {
        ++_raw_rx_drops;
        return;
    }

    Wifi w = Wifi(0);
    byte rssi = info ? info.rssi : 0;
    _raw_rx_cb(w, data[0 .. len], rssi, _channel);
}

extern(C) void status_callback(void* ctxt)
{
    if (!ctxt)
        return;

    // hostapd_intf.c passes &val, not the value in the pointer.
    ushort evt = cast(ushort)(*cast(const(int)*)ctxt);

    switch (evt)
    {
        case RW_EVT_STA_SCAN_OVER:
            _scanning = false;
            push_event(WifiEvent.scan_done);
            break;

        case RW_EVT_STA_BEACON_LOSE:
            if (_sta_state != StaState.idle)
                sta_failed("beacon lost", evt);
            break;

        case RW_EVT_STA_PASSWORD_WRONG:
        case RW_EVT_STA_CONNECT_FAILED:
            if (_sta_state != StaState.idle)
                sta_failed("auth failed", evt);
            break;

        case RW_EVT_STA_NO_AP_FOUND:
            if (_sta_state != StaState.idle)
                sta_failed("network not found", evt);
            break;

        case RW_EVT_STA_ASSOC_FULL:
            if (_sta_state != StaState.idle)
                sta_failed("association refused", evt);
            break;

        case RW_EVT_STA_DISCONNECTED:
            if (_sta_state != StaState.idle)
                sta_failed("disconnected", evt);
            break;

        default:
            break;
    }
}

WifiAuth scan_auth(int security)
    => cast(uint)security < scan_auths.length ? scan_auths[security] : WifiAuth.wpa_wpa2_psk;

void stop_sta()
{
    if (_sta_vif != no_vif && _sta_state >= StaState.associating)
        ow_rw_disconnect(_sta_vif, reason_deauth_leaving);
    _supp.disconnected(reason_deauth_leaving);
    _sta_state = StaState.idle;
    _key_pending = 0;
    _auth_pending = false;
}

bool sta_vif_up()
{
    if (_sta_vif != no_vif || _sta_vif_pending)
        return true;
    ubyte[6] mac = void;
    wifi_get_mac_address(cast(char*)mac.ptr, BK_ROLE_STA);
    _sta_vif_pending = ow_rw_add_if(mac.ptr, 0) == 0;
    return _sta_vif_pending;
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

    _sta_state = StaState.scanning;
    _sta_status = "connecting";
    if (_sta_vif == no_vif)
    {
        if (!sta_vif_up())
            sta_failed("vif add failed", 0);
    }
    else
        sta_scan();
}

bool sta_scan()
{
    if (ow_rw_scan(_sta_vif, _sta_ssid_buf.ptr, _sta_ssid_len) != 0)
    {
        _sta_state = StaState.idle;
        _sta_status = "scan failed";
        return false;
    }
    _sta_state = StaState.scanning;
    return true;
}

void sta_join()
{
    bool psk = _supp.profile.key_mgmt == WpaKeyMgmt.wpa2_psk;
    ubyte[6] mac = void;
    wifi_get_mac_address(cast(char*)mac.ptr, BK_ROLE_STA);
    _key_pending = 0;
    _auth_pending = false;
    _supp.begin_association(mac, psk ? wpa2_psk_ccmp_rsn_ie[] : null);

    bool any_bssid = true;
    foreach (b; _sta_bssid)
        any_bssid &= b == 0;
    int rc = ow_rw_connect(_sta_vif, _sta_ssid_buf.ptr, _sta_ssid_len, any_bssid ? null : _sta_bssid.ptr,
                           psk ? wpa2_psk_ccmp_rsn_ie.ptr : null, psk ? cast(ushort)wpa2_psk_ccmp_rsn_ie.length : 0,
                           psk, &_channel);
    if (rc != 0)
    {
        _sta_state = StaState.idle;
        _sta_status = rc == -2 ? "network not found" : "connect request failed";
        push_event(WifiEvent.sta_disconnected);
        return;
    }
    _sta_state = StaState.associating;
}

void sta_failed(const(char)[] status, ushort reason)
{
    _supp.disconnected(reason);
    _sta_state = StaState.idle;
    _key_pending = 0;
    _auth_pending = false;
    _sta_status = status;
    push_event(WifiEvent.sta_disconnected);
}

bool sta_send_eapol(const(ubyte)[] eapol)
{
    if (_sta_vif == no_vif || eapol.length + 14 > max_frame)
        return false;
    ubyte[max_frame] frame = void;
    frame[0 .. 6] = _supp.fourway.bssid[];
    frame[6 .. 12] = _supp.own_mac[];
    frame[12] = 0x88;
    frame[13] = 0x8E;
    frame[14 .. 14 + eapol.length] = eapol[];
    rwm_transfer(_sta_vif, frame.ptr, cast(uint)(eapol.length + 14), 0, null);
    return true;
}

bool sta_install_pairwise(const(ubyte)[] tk, const(ubyte)[] rsc)
{
    if (ow_rw_key_add_ccmp(_sta_vif, _sta_ap_idx, 0, tk.ptr, cast(ubyte)tk.length) != 0)
        return false;
    ++_key_pending;
    return true;
}

bool sta_install_group(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
{
    if (ow_rw_key_add_ccmp(_sta_vif, no_vif, key_idx, gtk.ptr, cast(ubyte)gtk.length) != 0)
        return false;
    ++_key_pending;
    return true;
}

bool sta_auth_done(ushort reason)
{
    if (reason != 0)
    {
        writeDebug("wifi: sta auth failed reason=", reason);
        ow_rw_disconnect(_sta_vif, reason);
        sta_failed("auth failed", reason);
        return true;
    }
    if (_key_pending)
    {
        _auth_pending = true;
        return true;
    }
    return sta_auth_complete();
}

bool sta_auth_complete()
{
    if (ow_rw_control_port(_sta_ap_idx, 1) != 0)
    {
        ow_rw_disconnect(_sta_vif, reason_deauth_leaving);
        sta_failed("control port failed", 0);
        return false;
    }
    _sta_state = StaState.control_port;
    return true;
}

void sta_connected()
{
    _sta_state = StaState.connected;
    _sta_status = "connected";
    push_event(WifiEvent.sta_connected);
}

// The vendor handler must finalise scan results before the host consumes its confirmation.
extern(C) void __wrap_rwnx_handle_recv_msg(ke_msg* m)
{
    __real_rwnx_handle_recv_msg(m);
    final switch (cast(OwRwMsg)ow_rw_classify(m))
    {
        case OwRwMsg.add_if_cfm:
        {
            ubyte status, idx;
            ow_rw_add_if_cfm(m, &status, &idx);
            if (_sta_vif_pending)
            {
                _sta_vif_pending = false;
                if (status == 0)
                {
                    _sta_vif = idx;
                    if (_mode == WifiMode.sta)
                    {
                        _sta_active = true;
                        push_event(WifiEvent.sta_started);
                        if (_sta_state == StaState.scanning)
                            sta_scan();
                    }
                }
                else
                    sta_failed("vif add failed", 0);
            }
            break;
        }
        case OwRwMsg.scanu_start_cfm:
        {
            ubyte status, vif;
            ow_rw_scanu_start_cfm(m, &status, &vif);
            if (_sta_state == StaState.scanning && vif == _sta_vif)
            {
                if (status == 0)
                    sta_join();
                else
                    sta_failed("scan failed", status);
            }
            break;
        }
        case OwRwMsg.connect_cfm:
        {
            ubyte status;
            ow_rw_connect_cfm(m, &status);
            if (status != 0 && _sta_state == StaState.associating)
                sta_failed("connect refused", 0);
            break;
        }
        case OwRwMsg.connect_ind:
        {
            ushort status, aid;
            ubyte vif, ap_idx;
            ubyte[6] bssid = void;
            ow_rw_connect_ind(m, &status, &vif, &ap_idx, bssid.ptr, &aid);
            if (vif != _sta_vif)
                break;
            if (status != 0)
            {
                writeDebug("wifi: sta assoc failed status=", status);
                sta_failed("association failed", status);
                break;
            }
            _sta_ap_idx = ap_idx;
            _sta_state = StaState.keying;
            _supp.associated(bssid);
            break;
        }
        case OwRwMsg.disconnect_ind:
        {
            ubyte vif;
            ushort reason;
            ow_rw_disconnect_ind(m, &vif, &reason);
            writeDebug("wifi: sta disconnect ind reason=", reason);
            if (vif == _sta_vif && _sta_state != StaState.idle)
                sta_failed("disconnected", reason);
            break;
        }
        case OwRwMsg.key_add_cfm:
        {
            ubyte status, hw;
            ow_rw_key_add_cfm(m, &status, &hw);
            if (_key_pending == 0 || _sta_state != StaState.keying)
                break;
            --_key_pending;
            if (status != 0)
            {
                ow_rw_disconnect(_sta_vif, reason_deauth_leaving);
                sta_failed("key install failed", status);
            }
            else if (_key_pending == 0 && _auth_pending)
            {
                _auth_pending = false;
                sta_auth_complete();
            }
            break;
        }
        case OwRwMsg.control_port_cfm:
            if (_sta_state == StaState.control_port)
                sta_connected();
            break;
        case OwRwMsg.other:
            break;
    }
}

void push_event(WifiEvent e)
{
    if (!_events.push(e))
        ++_event_drops;
    else if (_ready_cb)
        _ready_cb();
}

// Vendor netif registration remains inert because frames bypass lwIP.
extern(C) int ethernetif_init(void* netif) { return 0; }
extern(C) int lwip_netif_init(void* netif) { return 0; }
extern(C) int lwip_netif_uap_init(void* netif) { return 0; }

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
    if (prev)
        irq_enable();
    if (_ready_cb)
        _ready_cb();
}

extern(C) int __wrap_bmsg_is_empty()
{
    return _rx_pending == 0 ? 1 : 0;
}

extern(C) void ow_log_vendor(const(char)* msg, size_t len) nothrow @nogc
{
    const(char)[] s = msg[0 .. len];
    while (s.length && (s[$-1] == '\r' || s[$-1] == '\n'))
        s = s[0 .. $-1];
    if (s.length)
        writeDebug(s);
}
