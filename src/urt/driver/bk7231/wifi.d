module urt.driver.bk7231.wifi;

version (Beken):

import urt.driver.bk7231.pbuf : beken_ethernet_input_handler;
import urt.driver.irq : irq_disable, irq_enable;
import urt.driver.wifi;
import urt.driver.wpa : wpa2_psk_ccmp_rsn_ie;
import urt.driver.wpa.supplicant : WpaStaSupplicant, WpaKeyMgmt;
import urt.log;
import urt.mem : memcpy;
import urt.mem.pagepool : Page, page_alloc, page_free;
import urt.result : Result;

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
    _sta_status = StaStatus.idle;
    _events.clear();
    _open = true;

    if (!_mac_ready)
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
        if (ow_rw_mac_init() != 0)
        {
            writeWarning("wifi: MAC start failed");
            _open = false;
            return false;
        }
        _mac_ready = true;
    }

    if (cfg.channel)
    {
        if (cfg.channel > 14 || bk_wlan_set_channel(cfg.channel) != 0)
        {
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
        release_raw_rx_pages();
    }
    if (_scanning)
        ow_rw_scan_cancel();
    stop_sta();
    _sta_active = false;
    beken_ethernet_input_handler(null);
    _mode = WifiMode.none;
    _scanning = false;
    _scan_cancelled = false;
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
    if (_scanning)
    {
        wifi_hw_scan_stop(port);
        return false;
    }

    if (_monitor)
    {
        bk_wlan_stop_monitor();
        _monitor = false;
        release_raw_rx_pages();
    }
    if (_mode == WifiMode.sta)
    {
        stop_sta();
        if (_sta_active)
            push_event(WifiEventRecord(WifiEvent.sta_stopped));
        _sta_active = false;
    }
    _mode = WifiMode.none;

    final switch (mode)
    {
        case WifiMode.none:
            break;

        case WifiMode.monitor:
            if (!prepare_raw_rx_pages())
                return false;
            bk_wlan_register_monitor_cb(&monitor_callback);
            if (bk_wlan_start_monitor() != 0)
            {
                release_raw_rx_pages();
                return false;
            }
            _monitor = true;
            break;

        case WifiMode.sta:
            if (!sta_vif_up())
                return false;
            if (_sta_vif != no_vif)
            {
                _sta_active = true;
                push_event(WifiEventRecord(WifiEvent.sta_started));
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
    if (!_open || _sta_state != StaState.idle)
        return false;
    if (cfg.ssid.length == 0 || cfg.ssid.length > 32 || cfg.password.length > 63 ||
        (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
    {
        _sta_status = StaStatus.configuration_rejected;
        return false;
    }

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
        _sta_ssid_len = 0;
        _sta_pass_len = 0;
        _sta_status = cfg.pmf_required ? StaStatus.unsupported_security : StaStatus.configuration_rejected;
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
    return sta_status_message(_sta_status);
}

bool wifi_hw_sta_connect(ubyte port)
{
    if (!_open || !_mac_ready || _mode != WifiMode.sta || !_sta_active || _scanning ||
        _sta_state != StaState.idle || _sta_ssid_len == 0)
        return false;

    if (!_supp.pmk_ready)
    {
        _sta_state = StaState.deriving;
        _sta_status = StaStatus.deriving_key;
        return true;
    }
    _sta_state = StaState.scanning;
    _sta_status = StaStatus.connecting;
    if (_sta_vif == no_vif)
        return sta_vif_up();
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
    if (!_open || _mode == WifiMode.monitor || _scanning || _sta_state != StaState.idle ||
        cfg.ssid.length || has_bssid ||
        cfg.channel || cfg.passive || cfg.dwell_ms ||
        (cfg.band != WifiBand.any && cfg.band != WifiBand._2_4ghz))
        return false;

    if (ow_rw_scan(no_vif, null, 0) != 0)
        return false;
    _scanning = true;
    _scan_cancelled = false;
    return true;
}

void wifi_hw_scan_stop(ubyte port)
{
    if (_scanning && !_scan_cancelled && ow_rw_scan_cancel() == 0)
        _scan_cancelled = true;
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
    if (!_open || vif != WifiVif.sta || !_sta_active || _sta_state != StaState.connected ||
        _sta_vif == no_vif ||
        data.length < 14 || data.length > max_frame)
        return false;

    return ow_rw_transfer(_sta_vif, cast(ubyte*)data.ptr, cast(uint)data.length) == 0;
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
    if (!_open || frame.length < 10 || frame.length > max_raw_tx_frame)
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
{
    uint n = _raw_rx_drops;
    _raw_rx_drops = 0;
    return n;
}

bool wifi_hw_get_mac(ubyte port, WifiVif vif, ref ubyte[6] mac)
{
    if (!_open || vif != WifiVif.sta)
        return false;
    wifi_get_mac_address(cast(char*)mac.ptr, bk_role_sta);
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

bool wifi_hw_service(ubyte port, size_t budget)
{
    if (!_open)
        return false;

    ke_evt_core_scheduler();
    rwnx_recv_msg();
    ke_evt_none_core_scheduler();

    if (_sta_state == StaState.deriving)
        sta_derive_slice();

    size_t served;
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
        ++served;
    }

    while (served < budget)
    {
        Page* page = pop_raw_rx();
        if (!page)
            break;

        if (_raw_rx_cb)
        {
            RawRxInfo* info = raw_rx_info(page);
            Wifi wifi = Wifi(port);
            _raw_rx_cb(wifi, cast(const(ubyte)[])page.data, info.rssi, info.channel);
        }
        else
            ++_raw_rx_drops;
        release_raw_rx_page(page);
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
        }
        ++served;
    }
    return !_events.empty || _rx_pending != 0 || _raw_rx_pending != 0 ||
        _sta_state == StaState.deriving;
}

private:
enum ubyte bk_role_null = 0;
enum ubyte bk_role_sta = 2;

enum uint max_frame = 1600;
enum uint max_raw_tx_frame = 2346;
enum uint monitor_frame_length = 30;
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
    scan_cancel_cfm,
    beacon_lose_ind,
    auth_fail_ind,
    assoc_fail_ind,
    disassoc_ind,
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
        _head = _tail = _count = 0;
    }

    bool push(WifiEventRecord event)
    {
        if (_count == capacity)
            return false;
        _events[_tail] = event;
        _tail = cast(ubyte)((_tail + 1) % capacity);
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
    ubyte _tail;
    ubyte _count;
}

struct RawRxInfo
{
    byte rssi;
    ubyte channel;
}

alias MonitorDataCallback = extern(C) void function(ubyte* data, int len, WifiLinkInfo* info) nothrow @nogc;

__gshared
{
    bool _open;
    bool _mac_ready;
    bool _sta_active;
    bool _monitor;
    bool _scanning;
    bool _scan_cancelled;
    ubyte _channel;
    byte _rssi;
    WifiMode _mode;
    StaStatus _sta_status;

    WpaStaSupplicant _supp;
    StaState _sta_state;
    ubyte _sta_vif;
    bool _sta_vif_pending;
    ubyte _sta_ap_idx;
    ubyte _key_pending;
    bool _auth_pending;
    ubyte _sta_ssid_len;
    ubyte _sta_pass_len;
    ubyte[32] _sta_ssid_buf;
    ubyte[64] _sta_pass_buf;
    ubyte[6] _sta_bssid;

    EventQueue _events;
    int[2] _rx_args;
    ubyte _rx_tail;
    ubyte _rx_pending;
    Page* _raw_rx_head;
    Page* _raw_rx_tail;
    Page* _raw_rx_free;
    ubyte _raw_rx_pending;
    uint _rx_drops;
    uint _raw_rx_drops;
    uint _event_drops;

    WifiRxCallback _rx_cb;
    WifiRawRxCallback _raw_rx_cb;
    WifiEventCallback _event_cb;
    WifiReadyCallback _ready_cb;
}

extern(C) nothrow @nogc
{
    ubyte bk_wlan_get_scan_ap_result_numbers();
    void bk_wlan_get_scan_ap_result(StaScanResult* table, ubyte count);
    int bk_wlan_set_channel(int channel);
    int bk_wlan_start_monitor();
    int bk_wlan_stop_monitor();
    void bk_wlan_register_monitor_cb(MonitorDataCallback fn);
    void wifi_get_mac_address(char* mac, ubyte role);

    void rwnx_recv_msg();
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

    int ow_rw_mac_init();
    int ow_rw_add_if(const(ubyte)* mac, int ap);
    int ow_rw_scan(ubyte vif_idx, const(ubyte)* ssid, ubyte ssid_len);
    int ow_rw_scan_cancel();
    int ow_rw_transfer(ubyte vif_idx, ubyte* buf, uint len);
    byte ow_rw_get_rssi();
    int ow_rw_connect(ubyte vif_idx, const(ubyte)* ssid, ubyte ssid_len,
        const(ubyte)* bssid, const(ubyte)* ie, ushort ie_len, int psk,
        byte* rssi, ubyte* channel);
    int ow_rw_disconnect(ubyte vif_idx, ushort reason);
    int ow_rw_key_add_ccmp(ubyte vif_idx, ubyte sta_idx, ubyte key_idx,
        const(ubyte)* key, ubyte len);
    int ow_rw_control_port(ubyte sta_idx, int open);
    int ow_rw_classify(const(KeMsg)* m);
    void ow_rw_add_if_cfm(const(KeMsg)* m, ubyte* status, ubyte* vif_idx);
    void ow_rw_scanu_start_cfm(const(KeMsg)* m, ubyte* status, ubyte* vif_idx);
    void ow_rw_connect_cfm(const(KeMsg)* m, ubyte* status);
    void ow_rw_connect_ind(const(KeMsg)* m, ushort* status, ubyte* vif_idx,
        ubyte* ap_idx, ubyte* bssid, ushort* aid);
    void ow_rw_disconnect_ind(const(KeMsg)* m, ubyte* vif_idx, ushort* reason);
    void ow_rw_fail_ind(const(KeMsg)* m, ushort* status);
    void ow_rw_key_add_cfm(const(KeMsg)* m, ubyte* status, ubyte* hw_key_idx);
    void __real_rwnx_handle_recv_msg(KeMsg* m);
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

    if (!frame_page || frame_page.length < 14 || frame_page.length > max_frame || iface != _sta_vif)
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
    else if (_rx_cb)
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
        Page* page = page_alloc(monitor_frame_length, ubyte.alignof, RawRxInfo.sizeof);
        if (!page)
            break;
        page.next = _raw_rx_free;
        _raw_rx_free = page;
    }
    if (_raw_rx_free)
        return true;
    return false;
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
        --_raw_rx_pending;
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
    _raw_rx_pending = 0;
    if (prev)
        irq_enable();
    free_pages(pages);
}

extern(C) void monitor_callback(ubyte* data, int len, WifiLinkInfo* info)
{
    if (!_raw_rx_cb || !data || len <= 0)
    {
        ++_raw_rx_drops;
        return;
    }

    Page* page = take_raw_rx_page();
    if (!page)
    {
        ++_raw_rx_drops;
        return;
    }
    // The SDK reports the over-air length for a 30-byte synthetic header.
    memcpy(page.data.ptr, data, monitor_frame_length);
    RawRxInfo* rx_info = raw_rx_info(page);
    rx_info.rssi = info ? info.rssi : 0;
    rx_info.channel = _channel;

    page.length = monitor_frame_length;
    immutable bool prev = irq_disable();
    if (_raw_rx_tail)
        _raw_rx_tail.next = page;
    else
        _raw_rx_head = page;
    _raw_rx_tail = page;
    ++_raw_rx_pending;
    if (prev)
        irq_enable();
    if (_ready_cb)
        _ready_cb();
}

const(char)[] sta_status_message(StaStatus status)
{
    final switch (status)
    {
        case StaStatus.idle:                   return "idle";
        case StaStatus.vif_add_failed:         return "vif add failed";
        case StaStatus.unsupported_security:   return "unsupported security";
        case StaStatus.configuration_rejected: return "configuration rejected";
        case StaStatus.deriving_key:           return "deriving key";
        case StaStatus.connecting:             return "connecting";
        case StaStatus.disconnected:           return "disconnected";
        case StaStatus.scan_failed:            return "scan failed";
        case StaStatus.network_not_found:      return "network not found";
        case StaStatus.connect_request_failed: return "connect request failed";
        case StaStatus.connected:              return "connected";
        case StaStatus.beacon_lost:            return "beacon lost";
        case StaStatus.auth_failed:             return "auth failed";
        case StaStatus.association_refused:     return "association refused";
        case StaStatus.association_failed:      return "association failed";
        case StaStatus.key_install_failed:      return "key install failed";
        case StaStatus.control_port_failed:     return "control port failed";
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
    _rssi = 0;
    _key_pending = 0;
    _auth_pending = false;
}

bool sta_vif_up()
{
    if (_sta_vif != no_vif || _sta_vif_pending)
        return true;
    ubyte[6] mac = void;
    wifi_get_mac_address(cast(char*)mac.ptr, bk_role_sta);
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
    _sta_status = StaStatus.connecting;
    if (_sta_vif == no_vif)
    {
        if (!sta_vif_up())
            sta_start_failed();
    }
    else if (!sta_scan())
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
    _sta_state = StaState.scanning;
    return true;
}

void sta_join()
{
    bool psk = _supp.profile.key_mgmt == WpaKeyMgmt.wpa2_psk;
    ubyte[6] mac = void;
    wifi_get_mac_address(cast(char*)mac.ptr, bk_role_sta);
    _key_pending = 0;
    _auth_pending = false;
    _supp.begin_association(mac, psk ? wpa2_psk_ccmp_rsn_ie[] : null);

    bool any_bssid = true;
    foreach (b; _sta_bssid)
        any_bssid &= b == 0;
    const(ubyte)* bssid = any_bssid ? null : _sta_bssid.ptr;
    const(ubyte)* ie = psk ? wpa2_psk_ccmp_rsn_ie.ptr : null;
    ushort ie_length = psk ? cast(ushort)wpa2_psk_ccmp_rsn_ie.length : 0;
    int rc = ow_rw_connect(_sta_vif, _sta_ssid_buf.ptr, _sta_ssid_len,
        bssid, ie, ie_length, psk, &_rssi, &_channel);
    if (rc != 0)
    {
        StaStatus status = rc == -2
            ? StaStatus.network_not_found : StaStatus.connect_request_failed;
        sta_failed(status, 0);
        return;
    }
    _sta_state = StaState.associating;
}

void sta_failed(StaStatus status, ushort reason)
{
    _supp.disconnected(reason);
    _sta_state = StaState.idle;
    _rssi = 0;
    _key_pending = 0;
    _auth_pending = false;
    _sta_status = status;
    push_event(WifiEventRecord(WifiEvent.sta_disconnected, status, reason));
}

void sta_start_failed()
{
    _sta_state = StaState.idle;
    _sta_active = false;
    _rssi = 0;
    _mode = WifiMode.none;
    _sta_status = StaStatus.vif_add_failed;
    push_event(WifiEventRecord(WifiEvent.sta_start_failed, _sta_status));
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
    return ow_rw_transfer(_sta_vif, frame.ptr, cast(uint)(eapol.length + 14)) == 0;
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
        sta_failed(StaStatus.auth_failed, reason);
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
        sta_failed(StaStatus.control_port_failed, 0);
        return false;
    }
    _sta_state = StaState.control_port;
    return true;
}

void sta_connected()
{
    _sta_state = StaState.connected;
    _sta_status = StaStatus.connected;
    push_event(WifiEventRecord(WifiEvent.sta_connected));
}

// The vendor handler must finalise scan results before the host consumes its confirmation.
extern(C) void __wrap_rwnx_handle_recv_msg(KeMsg* m)
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
                        push_event(WifiEventRecord(WifiEvent.sta_started));
                        if (_sta_state == StaState.scanning && !sta_scan())
                            sta_failed(StaStatus.scan_failed, 0);
                    }
                }
                else if (_open && _mode == WifiMode.sta)
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
                bool cancelled = _scan_cancelled;
                _scanning = false;
                _scan_cancelled = false;
                if (!cancelled)
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
        case OwRwMsg.scan_cancel_cfm:
            _scanning = false;
            _scan_cancelled = false;
            break;
        case OwRwMsg.beacon_lose_ind:
            if (_sta_state != StaState.idle)
                sta_failed(StaStatus.beacon_lost, 0);
            break;
        case OwRwMsg.auth_fail_ind:
        {
            ushort status;
            ow_rw_fail_ind(m, &status);
            if (_sta_state != StaState.idle)
            {
                StaStatus failure = status == reason_too_many_stations
                    ? StaStatus.association_refused : StaStatus.auth_failed;
                sta_failed(failure, status);
            }
            break;
        }
        case OwRwMsg.assoc_fail_ind:
        {
            ushort status;
            ow_rw_fail_ind(m, &status);
            if (_sta_state != StaState.idle)
            {
                StaStatus failure = status == status_too_many_stations
                    ? StaStatus.association_refused : StaStatus.association_failed;
                sta_failed(failure, status);
            }
            break;
        }
        case OwRwMsg.disassoc_ind:
        {
            ushort status;
            ow_rw_fail_ind(m, &status);
            if (_sta_state != StaState.idle)
                sta_failed(StaStatus.disconnected, status);
            break;
        }
        case OwRwMsg.connect_cfm:
        {
            ubyte status;
            ow_rw_connect_cfm(m, &status);
            if (status != 0 && _sta_state == StaState.associating)
                sta_failed(StaStatus.connect_request_failed, 0);
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
                sta_failed(StaStatus.association_failed, status);
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
                sta_failed(StaStatus.disconnected, reason);
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
                sta_failed(StaStatus.key_install_failed, status);
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

void push_event(WifiEventRecord event)
{
    if (!_events.push(event))
        ++_event_drops;
    else if (_ready_cb)
        _ready_cb();
}

extern(C) int ethernetif_init(void* netif)
{
    return 0;
}

extern(C) int lwip_netif_init(void* netif)
{
    return 0;
}

extern(C) int lwip_netif_uap_init(void* netif)
{
    return 0;
}

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

unittest
{
    EventQueue events;
    foreach (i; 0 .. EventQueue.capacity)
    {
        WifiEventRecord event = WifiEventRecord(
            WifiEvent.sta_disconnected, StaStatus.disconnected, cast(ushort)i);
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
}
