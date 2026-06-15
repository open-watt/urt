module urt.driver.bl808_m0.wifi_wpa;

version (BL808_M0):

import urt.driver.bl808_m0.wifi;
import urt.driver.bl808_m0.wifi_lmac;
import urt.driver.wifi;
import urt.driver.wpa.eapol;
import urt.driver.wpa.authenticator;

nothrow @nogc:
package:

// ====================================================================
// WPA callback table and AP authenticator
// ====================================================================

struct wpa_funcs
{
nothrow @nogc:
    extern(C) bool   function() wpa_sta_init;
    extern(C) bool   function() wpa_sta_deinit;
    extern(C) void   function(void* parm) wpa_sta_config;
    extern(C) void   function(void* parm) wpa_sta_connect;
    extern(C) void   function(ubyte reason_code) wpa_sta_disconnected_cb;
    extern(C) int    function(ubyte* src_addr, ubyte* buf, uint len) wpa_sta_rx_eapol;
    extern(C) void*  function(void* parm) wpa_ap_init;
    extern(C) bool   function(void* data) wpa_ap_deinit;
    extern(C) bool   function(void** sm, ubyte* mac, ubyte* wpa_ie, ubyte wpa_ie_len) wpa_ap_join;
    extern(C) void   function(void* wpa_sm, ubyte sta_idx) wpa_ap_sta_associated;
    extern(C) bool   function(void* sm) wpa_ap_remove;
    extern(C) bool   function(void* hapd_data, void* sm, ubyte* data, size_t data_len) wpa_ap_rx_eapol;
    extern(C) int    function(const(ubyte)* wpa_ie, size_t wpa_ie_len, void* data) wpa_parse_wpa_ie;
    extern(C) void   function(void* tlv_pack_cb) wpa_reg_diag_tlv_cb;
    extern(C) ubyte* function(ubyte* bssid, ubyte* mac, ubyte* passphrase, uint sae_msg_type, size_t* sae_msg_len) wpa3_build_sae_msg;
    extern(C) int    function(ubyte* buf, size_t len, uint type, ushort status) wpa3_parse_sae_msg;
    extern(C) void   function() wpa3_clear_sae;
}

extern(C) int bl_wifi_register_wpa_cb_internal(const(wpa_funcs)* cb);
extern(C) bool bl_wifi_auth_done_internal(ubyte sta_idx, ushort reason_code);
private __gshared ubyte _ap_hapd_sentinel;
private __gshared WpaApAuthenticator _ap_auth;

// Per-STA handle round-tripped through the firmware's wpa_funcs callbacks: we
// return &_ap_slots[i] as the `sm` from _wpa_ap_join and the firmware hands it
// back on associate / rx-eapol / remove. Carries the STA's firmware sta_idx so
// the key-install and auth-done primitives can be addressed by MAC.
private struct ApStaSlot
{
    ubyte[6] mac;
    ubyte sta_idx;
    bool in_use;
}
private __gshared ApStaSlot[WpaApAuthenticator.max_stations] _ap_slots;

// AP RSN IE advertised in the beacon and echoed in EAPOL-Key msg 3: WPA2-PSK,
// CCMP pairwise + group, PSK AKM. Must outlive the authenticator -> immutable.
private static immutable ubyte[22] _ap_rsn_ie = [
    0x30, 0x14,
    0x01, 0x00,
    0x00, 0x0f, 0xac, 0x04,
    0x01, 0x00,
    0x00, 0x0f, 0xac, 0x04,
    0x01, 0x00,
    0x00, 0x0f, 0xac, 0x02,
    0x00, 0x00,
];

void ap_auth_reset()
{
    _ap_auth = WpaApAuthenticator.init;
    foreach (ref s; _ap_slots)
        s = ApStaSlot.init;
}

bool ap_auth_has_pmk()
    => _ap_auth.have_pmk;

void ap_auth_tick()
{
    import urt.driver.bl618.timer : mtime_read;
    _ap_auth.tick(mtime_read());
}

// Compute the PMK + GTK and bind the driver hooks for a secured BSS. Called at
// AP bring-up; open APs never configure an authenticator.
bool ap_auth_configure()
{
    size_t ssid_len;
    while (ssid_len < _ap_ssid_buf.length && _ap_ssid_buf[ssid_len] != 0) ++ssid_len;
    size_t pass_len;
    while (pass_len < _ap_pw_buf.length && _ap_pw_buf[pass_len] != 0) ++pass_len;
    if (ssid_len == 0 || pass_len < 8)
        return false;

    ap_auth_reset();
    _ap_auth.hooks.send_eapol = &ap_hook_send_eapol;
    _ap_auth.hooks.install_pairwise_key = &ap_hook_install_pairwise;
    _ap_auth.hooks.install_group_key = &ap_hook_install_group;
    _ap_auth.hooks.handshake_complete = &ap_hook_complete;

    auto ssid = cast(const(char)[])_ap_ssid_buf[0 .. ssid_len];
    auto pass = cast(const(char)[])_ap_pw_buf[0 .. pass_len];
    return _ap_auth.configure(pass, ssid, _vif_mac_ap, _ap_rsn_ie[]).succeeded;
}

private ApStaSlot* ap_slot_alloc(const(ubyte)[6] mac)
{
    foreach (ref s; _ap_slots)
        if (s.in_use && s.mac[] == mac[])
            return &s;
    foreach (ref s; _ap_slots)
        if (!s.in_use)
        {
            s = ApStaSlot.init;
            s.mac[] = mac[];
            s.in_use = true;
            return &s;
        }
    return null;
}

private void ap_slot_free(ApStaSlot* s)
{
    if (s !is null)
        *s = ApStaSlot.init;
}

private bool ap_slot_idx(const(ubyte)[6] mac, out ubyte sta_idx)
{
    foreach (ref s; _ap_slots)
        if (s.in_use && s.mac[] == mac[])
        {
            sta_idx = s.sta_idx;
            return true;
        }
    return false;
}

private bool ap_hook_send_eapol(const(ubyte)[6] sta, const(ubyte)[] eapol)
{
    ubyte[14 + 256] frame = void;
    if (eapol.length > frame.length - 14)
        return false;
    frame[0 .. 6] = sta[];
    frame[6 .. 12] = _vif_mac_ap[];
    frame[12] = 0x88;
    frame[13] = 0x8e;
    frame[14 .. 14 + eapol.length] = eapol[];
    return wifi_hw_tx(0, WifiVif.ap, frame[0 .. 14 + eapol.length]);
}

private bool ap_hook_install_pairwise(const(ubyte)[6] sta, const(ubyte)[] tk)
{
    ubyte sta_idx;
    if (!ap_slot_idx(sta, sta_idx))
        return false;
    return bl_wifi_set_sta_key_internal(
        cast(ubyte)_bl_hw.vif_index_ap, sta_idx,
        wpa_alg_ccmp, 0, 1,
        null, 0, tk.ptr, tk.length,
        true) == 0;
}

private bool ap_hook_install_group(const(ubyte)[6] sta, ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
{
    if (_bl_hw.ap_bcmc_idx < 0)
        return false;
    return bl_wifi_set_sta_key_internal(
        cast(ubyte)_bl_hw.vif_index_ap, cast(ubyte)_bl_hw.ap_bcmc_idx,
        wpa_alg_ccmp, key_idx, 1,
        rsc.ptr, rsc.length, gtk.ptr, gtk.length,
        false) == 0;
}

private void ap_hook_complete(const(ubyte)[6] sta, bool success, ushort reason)
{
    ubyte sta_idx;
    if (!ap_slot_idx(sta, sta_idx))
        return;
    enum ushort reason_mic_failure = 14;
    enum ushort reason_4way_timeout = 15;
    ushort code = success ? 0
        : (reason == cast(ushort)WpaHandshakeReason.mic_failed ? reason_mic_failure : reason_4way_timeout);
    bl_wifi_auth_done_internal(sta_idx, code);
}

extern(C) void* _wpa_ap_init(void* parm)
    => &_ap_hapd_sentinel;

extern(C) bool _wpa_ap_deinit(void*)
    => true;

extern(C) bool _wpa_ap_join(void** sm, ubyte* mac, ubyte* wpa_ie, ubyte wpa_ie_len)
{
    bool encrypted = wpa_ie !is null && wpa_ie_len > 0;
    if (!encrypted || mac is null)
    {
        if (sm) *sm = null;
        return !encrypted;          // open station accepted; encrypted-without-MAC rejected
    }
    ApStaSlot* slot = ap_slot_alloc(mac[0 .. 6]);
    if (slot is null)
    {
        if (sm) *sm = null;
        return false;               // station table full
    }
    if (sm) *sm = slot;
    return true;
}

extern(C) void _wpa_ap_sta_associated(void* sm, ubyte sta_idx)
{
    auto slot = cast(ApStaSlot*)sm;
    if (slot is null)
        return;
    slot.sta_idx = sta_idx;
    _ap_auth.station_join(slot.mac);    // derive ANonce, send msg 1
}

extern(C) bool _wpa_ap_remove(void* sm)
{
    auto slot = cast(ApStaSlot*)sm;
    if (slot is null)
        return false;
    _ap_auth.station_leave(slot.mac);
    ap_slot_free(slot);
    return true;
}

extern(C) bool _wpa_ap_rx_eapol(void*, void* sm, ubyte* data, size_t len)
{
    auto slot = cast(ApStaSlot*)sm;
    if (slot is null || data is null)
        return true;
    _ap_auth.handle_eapol(slot.mac, data[0 .. len]);
    return true;
}
extern(C) int _wpa_parse_wpa_ie(const(ubyte)* ie, size_t len, void* data)
{
    if (ie is null || data is null || len < 22)
        return -1;

    enum int wpa_proto_rsn = 1 << 1;
    enum int wpa_key_mgmt_psk = 1 << 1;
    enum int wifi_cipher_type_ccmp = 4;
    enum int wifi_cipher_type_tkip = 3;

    bool is_rsn = ie[0] == 0x30;
    if (!is_rsn || ie[1] + 2 > len)
        return -1;

    size_t p = 2;
    if (p + 2 > len) return -1;
    p += 2; // version
    if (p + 4 > len) return -1;
    int group = ie[p + 3] == 2 ? wifi_cipher_type_tkip :
        (ie[p + 3] == 4 ? wifi_cipher_type_ccmp : 0);
    p += 4;
    if (p + 2 > len) return -1;
    ushort pair_count = cast(ushort)(ie[p] | (ie[p + 1] << 8));
    p += 2;
    int pairwise;
    foreach (_; 0 .. pair_count)
    {
        if (p + 4 > len) return -1;
        if (ie[p + 3] == 4) pairwise = wifi_cipher_type_ccmp;
        else if (ie[p + 3] == 2 && pairwise == 0) pairwise = wifi_cipher_type_tkip;
        p += 4;
    }
    if (p + 2 > len) return -1;
    ushort akm_count = cast(ushort)(ie[p] | (ie[p + 1] << 8));
    p += 2;
    int key_mgmt;
    foreach (_; 0 .. akm_count)
    {
        if (p + 4 > len) return -1;
        if (ie[p + 3] == 2) key_mgmt |= wpa_key_mgmt_psk;
        p += 4;
    }
    int caps;
    if (p + 2 <= len)
        caps = cast(int)(ie[p] | (ie[p + 1] << 8));

    auto out_ = cast(int*)data;
    out_[0] = wpa_proto_rsn;
    out_[1] = pairwise;
    out_[2] = group;
    out_[3] = key_mgmt;
    out_[4] = caps;
    out_[5] = 0; // num_pmkid
    out_[6] = 0; // pmkid pointer on rv32
    out_[7] = 0; // mgmt_group_cipher

    return pairwise != 0 && group != 0 && key_mgmt != 0 ? 0 : -1;
}

extern(C) void _wpa_reg_diag_tlv_cb(void*)
{
}

extern(C) ubyte* _wpa3_build_sae_msg(ubyte*, ubyte*, ubyte*, uint, size_t* len)
{
    if (len)
        *len = 0;
    return null;
}

extern(C) int _wpa3_parse_sae_msg(ubyte*, size_t, uint, ushort)
    => -1;

extern(C) void _wpa3_clear_sae()
{
}

// ====================================================================
// STA WPA adapter
// ====================================================================

import urt.driver.wpa.supplicant : WpaKeyMgmt, WpaStaSupplicant, WpaSupplicantState;
import urt.driver.wpa.fourway : WpaHandshakeReason, wpa_handshake_reason_message;

private __gshared WpaStaSupplicant _sta_supplicant;
private __gshared ubyte[32] _sta_rsn_ie_buf;
private __gshared size_t _sta_rsn_ie_len;
private __gshared ubyte _sta_vif_idx;
private __gshared ubyte _sta_sta_idx;
private __gshared ubyte[6] _sta_own_mac;
private __gshared ubyte[6] _sta_bssid;

private bool mac_nonzero(const(ubyte)[] mac)
{
    foreach (b; mac)
        if (b != 0)
            return true;
    return false;
}

// libwifi extern bindings used by the supplicant hooks.
// wpa_alg_t values (from supplicant_api.h:42): WIFI_WPA_ALG_CCMP = 3.
private enum int wpa_alg_ccmp = 3;
// wifi_appie_wpa_rsn = 0 (from supplicant_api.h:35).
private enum ubyte wifi_appie_wpa_rsn = 0;
extern(C) int bl_wifi_set_appie_internal(ubyte vif_idx, ubyte appie_type,
                                          ubyte* ie, ushort len, bool sta);
extern(C) bool bl_wifi_sta_is_ap_notify_completed_rsne_internal();
extern(C) int bl_wifi_set_sta_key_internal(ubyte vif_idx, ubyte sta_idx,
                                            int alg, int key_idx, int set_tx,
                                            const(ubyte)* seq, size_t seq_len,
                                            const(ubyte)* key, size_t key_len,
                                            bool pairwise);


struct WifiConnectParmView
{
nothrow @nogc:
    private const(ubyte)* p;

    this(const(void)* parm) { p = cast(const(ubyte)*)parm; }

    @property ubyte vif_idx() const => p[0];
    @property ubyte sta_idx() const => p[1];
    @property const(ubyte)[] mac()   const => p[2 .. 8];
    @property const(ubyte)[] bssid() const => p[8 .. 14];
    @property uint ssid_len()  const => *cast(const(uint)*)(p + 16);
    @property const(ubyte)[] ssid() const
    {
        size_t n = ssid_len;
        if (n > 32) n = 32;
        return p[20 .. 20 + n];
    }
    @property ubyte  proto()           const => p[52];
    @property ushort key_mgmt()        const => cast(ushort)(p[54] | (p[55] << 8));
    @property ubyte  pairwise_cipher() const => p[56];
    @property ubyte  group_cipher()    const => p[57];
    @property const(char)[] passphrase() const
    {
        size_t n;
        while (n < 64 && p[58 + n] != 0) ++n;
        return cast(const(char)[])p[58 .. 58 + n];
    }
    @property bool  pmf_required() const => p[123] != 0;
}


private const(ubyte)[] build_wpa2_psk_rsn_ie()
{
    static immutable ubyte[8] short_template = [
        0x30, 0x06,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x04,
    ];
    static immutable ubyte[22] full_template = [
        0x30, 0x14,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x04,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x04,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x02,
        0x00, 0x00,
    ];

    const(ubyte)[] template_ = bl_wifi_sta_is_ap_notify_completed_rsne_internal()
        ? full_template[]
        : short_template[];
    _sta_rsn_ie_buf[0 .. template_.length] = template_[];
    _sta_rsn_ie_len = template_.length;
    return _sta_rsn_ie_buf[0 .. template_.length];
}


extern(C) bool _wpa_sta_init_real()
{
    _sta_supplicant.state = WpaSupplicantState.idle;
    return true;
}

extern(C) bool _wpa_sta_deinit_real()
{
    _sta_supplicant.disconnected(0);
    return true;
}

extern(C) void _wpa_sta_config_real(void* parm)
{
    auto v = WifiConnectParmView(parm);
    _sta_vif_idx = v.vif_idx;
    _sta_sta_idx = v.sta_idx;
    _sta_own_mac[] = v.mac[];
    _sta_bssid[] = v.bssid[];

    WifiStaConfig cfg;
    cfg.ssid = v.ssid.length != 0
        ? cast(const(char)[])v.ssid
        : cast(const(char)[])_sta_cfg_ssid_buf[0 .. _sta_cfg_ssid_len];
    cfg.password = v.passphrase.length != 0
        ? v.passphrase
        : cast(const(char)[])_sta_cfg_pw_buf[0 .. _sta_cfg_pw_len];
    cfg.bssid = _sta_bssid;
    cfg.pmf_required = v.pmf_required;

    _sta_supplicant.hooks.send_eapol = &_sta_hook_send_eapol;
    _sta_supplicant.hooks.install_pairwise_key = &_sta_hook_install_pairwise;
    _sta_supplicant.hooks.install_group_key = &_sta_hook_install_group;
    _sta_supplicant.hooks.auth_done = &_sta_hook_auth_done;

    auto cfg_result = _sta_pending_pmk_hex_len == 64
        ? _sta_supplicant.configure_precomputed(cfg, _sta_pending_pmk[])
        : _sta_supplicant.configure(cfg);
    if (!cfg_result.succeeded)
    {
        if (_sta_supplicant.last_reason != 0)
            _sta_hook_auth_done(_sta_supplicant.last_reason);
        return;
    }

    auto ie = build_wpa2_psk_rsn_ie();
    bl_wifi_set_appie_internal(v.vif_idx, wifi_appie_wpa_rsn,
                               cast(ubyte*)ie.ptr, cast(ushort)ie.length, true);

    _sta_supplicant.begin_association(_sta_own_mac, ie);
    _sta_pending_keys = false;
    _sta_pending_auth = false;
    _sta_pending_auth_reason = 0;
    _sta_pending_tk_len = 0;
    _sta_pending_gtk_len = 0;
}

extern(C) void _wpa_sta_connect_real(void* parm)
{
    auto v = WifiConnectParmView(parm);
    if (mac_nonzero(v.bssid))
        _sta_bssid[] = v.bssid[];

    if (_bl_hw.sta_idx < 0 && _sta_sta_idx < _bl_hw.sta_table.length)
    {
        _sta_ap_idx = _sta_sta_idx;
        _bl_hw.sta_idx = _sta_sta_idx;
        auto sta = &_bl_hw.sta_table[_sta_sta_idx];
        sta.sta_addr.array_ = _sta_bssid;
        sta.is_used = 1;
        sta.sta_idx = _sta_sta_idx;
        sta.vif_idx = _sta_vif_idx;
        sta.vlan_idx = _sta_vif_idx;
        sta.qos = 1;
        if (_sta_vif_idx < _bl_hw.vif_table.length)
            _bl_hw.vif_table[_sta_vif_idx].variant.sta.ap = sta;
    }

    _sta_supplicant.associated(_sta_bssid);
}

extern(C) void _wpa_sta_disconnected_cb_real(ubyte reason)
{
    _sta_supplicant.disconnected(reason);
    _sta_pending_keys = false;
    _sta_pending_auth = false;
}

extern(C) int _wpa_sta_rx_eapol_real(ubyte* src_addr, ubyte* buf, uint len)
{
    int rc = _sta_supplicant.receive_eapol(buf[0 .. len]);
    return rc;
}

bool sta_wpa_owns_eapol_key(WifiVif rx_vif, const(ubyte)* eth, uint eth_len)
{
    if (rx_vif != WifiVif.sta || eth is null || eth_len < 14 + eapol_hdr_len)
        return false;
    if (_sta_supplicant.profile.key_mgmt != WpaKeyMgmt.wpa2_psk)
        return false;

    auto state = _sta_supplicant.state;
    if (state != WpaSupplicantState.associated &&
        state != WpaSupplicantState.keying &&
        state != WpaSupplicantState.completed)
        return false;

    if (eth[0 .. 6] != _sta_own_mac[] || eth[6 .. 12] != _sta_bssid[])
        return false;

    EapolKeyFrame key;
    return decode_eapol_key(eth[14 .. eth_len], key) &&
        key.descriptor_type == key_desc_type_rsn;
}


bool _sta_hook_send_eapol(const(ubyte)[] eapol)
{
    ubyte[14 + 256] frame = void;
    if (eapol.length > frame.length - 14)
        return false;
    frame[0 .. 6] = _sta_bssid[];
    frame[6 .. 12] = _sta_own_mac[];
    frame[12] = 0x88;
    frame[13] = 0x8E;
    frame[14 .. 14 + eapol.length] = eapol[];
    bool ok = wifi_hw_tx(0, WifiVif.sta, frame[0 .. 14 + eapol.length]);
    return ok;
}

bool _sta_hook_install_pairwise(const(ubyte)[] tk, const(ubyte)[] rsc)
{
    if (tk.length > _sta_pending_tk.length || rsc.length > _sta_pending_pair_rsc.length)
        return false;
    _sta_pending_tk_len = cast(ubyte)tk.length;
    _sta_pending_pair_rsc_len = cast(ubyte)rsc.length;
    _sta_pending_tk[0 .. tk.length] = tk[];
    if (rsc.length)
        _sta_pending_pair_rsc[0 .. rsc.length] = rsc[];
    _sta_pending_keys = true;
    return true;
}

private bool sta_install_pending_pairwise()
{
    if (_sta_pending_tk_len == 0)
        return false;
    int ret = bl_wifi_set_sta_key_internal(
        _sta_vif_idx, _sta_sta_idx,
        wpa_alg_ccmp, 0, 1,
        _sta_pending_pair_rsc_len ? _sta_pending_pair_rsc.ptr : null, _sta_pending_pair_rsc_len,
        _sta_pending_tk.ptr, _sta_pending_tk_len,
        true);
    return ret == 0;
}

bool _sta_hook_install_group(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
{
    if (gtk.length > _sta_pending_gtk.length || rsc.length > _sta_pending_group_rsc.length)
        return false;
    _sta_pending_gtk_idx = key_idx;
    _sta_pending_gtk_len = cast(ubyte)gtk.length;
    _sta_pending_group_rsc_len = cast(ubyte)rsc.length;
    _sta_pending_gtk[0 .. gtk.length] = gtk[];
    if (rsc.length)
        _sta_pending_group_rsc[0 .. rsc.length] = rsc[];
    _sta_pending_keys = true;
    return true;
}

private bool sta_install_pending_group()
{
    if (_sta_pending_gtk_len == 0)
        return false;
    int ret = bl_wifi_set_sta_key_internal(
        _sta_vif_idx, _sta_sta_idx,
        wpa_alg_ccmp, cast(int)_sta_pending_gtk_idx, 0,
        _sta_pending_group_rsc_len ? _sta_pending_group_rsc.ptr : null, _sta_pending_group_rsc_len,
        _sta_pending_gtk.ptr, _sta_pending_gtk_len,
        false);
    return ret == 0;
}

bool _sta_hook_auth_done(ushort reason)
{
    _sta_pending_auth = true;
    _sta_pending_auth_reason = reason;
    _sta_last_auth_reason = reason;
    _sta_status_message = wpa_handshake_reason_message(reason);
    return true;
}

void sta_flush_pending_auth()
{
    if (!_sta_pending_auth)
        return;
    if (_sta_pending_auth_reason == 0)
    {
        if (!_sta_pending_keys)
            return;
        if (!sta_install_pending_pairwise() || !sta_install_pending_group())
            return;
    }
    _sta_pending_keys = false;
    _sta_pending_auth = false;
    ushort reason = _sta_pending_auth_reason;
    bool ok = bl_wifi_auth_done_internal(_sta_sta_idx, reason);
    if (ok && reason == 0)
    {
        if (_current_channel == 0)
            _current_channel = _sta_candidate_channel != 0 ? _sta_candidate_channel : _configured_channel;
        queue_event(WifiEvent.sta_connected, null);
    }
}

__gshared wpa_funcs _wpa_stub_table = wpa_funcs(
    &_wpa_sta_init_real, &_wpa_sta_deinit_real,
    &_wpa_sta_config_real, &_wpa_sta_connect_real,
    &_wpa_sta_disconnected_cb_real, &_wpa_sta_rx_eapol_real,
    &_wpa_ap_init, &_wpa_ap_deinit, &_wpa_ap_join, &_wpa_ap_sta_associated,
    &_wpa_ap_remove, &_wpa_ap_rx_eapol, &_wpa_parse_wpa_ie, &_wpa_reg_diag_tlv_cb,
    &_wpa3_build_sae_msg, &_wpa3_parse_sae_msg, &_wpa3_clear_sae);


