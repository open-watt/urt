// WPA2-PSK AP authenticator: the multi-station manager for one BSS. Owns the
// PMK (from the passphrase) and the group key, and routes EAPOL frames to a
// pool of per-station FourwayAuthContext handshakes (urt.driver.wpa.fourway)
// keyed by STA MAC. Driver adapters (Linux nl80211_ap, BL808) own a singleton
// WpaApAuthenticator and translate its hooks to their key-install / TX paths.
//
// The mirror of WpaStaSupplicant on the STA side. WPA2-PSK / CCMP only.
module urt.driver.wpa.authenticator;

import urt.crypto.random : crypto_random_bytes;
import urt.result : Result, InternalResult;

import urt.driver.wpa.crypto : wpa_pmk_len;
import urt.driver.wpa.eapol : eapol_key_rsc_len;
import urt.driver.wpa.fourway : FourwayAuthContext, wpa_gtk_max_len;

nothrow @nogc:


enum size_t wpa_gtk_len_ccmp = 16;


// Driver-facing hook set: function pointers, mirroring WpaSupplicantHooks on the
// STA side. The manager adapts these into each station's FourwayAuthHooks
// delegates.
struct WpaApHooks
{
    bool function(const(ubyte)[6] sta, const(ubyte)[] eapol_payload) nothrow @nogc send_eapol;
    bool function(const(ubyte)[6] sta, const(ubyte)[] tk) nothrow @nogc install_pairwise_key;
    bool function(const(ubyte)[6] sta, ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc) nothrow @nogc install_group_key;
    void function(const(ubyte)[6] sta, bool success, ushort reason) nothrow @nogc handshake_complete;
}


// Multi-station authenticator for one BSS. Owns the PMK (from the passphrase)
// and the group key, and routes EAPOL frames to per-station contexts by MAC.
struct WpaApAuthenticator
{
    // Upper bound on concurrent associations; the driver enforces its own
    // max_clients on top of this. Sized for a small embedded AP.
    enum size_t max_stations = 8;

    WpaApHooks hooks;

    ubyte[wpa_pmk_len] pmk;
    bool have_pmk;
    ubyte[6] ap_mac;
    const(ubyte)[] ap_rsn_ie;
    ubyte[wpa_gtk_max_len] gtk;
    size_t gtk_len;
    ubyte gtk_key_id;
    ubyte[eapol_key_rsc_len] gtk_rsc;

nothrow @nogc:

    // Compute the PMK from passphrase+SSID and generate the BSS group key.
    // ap_rsn_ie must stay valid for the lifetime of the authenticator.
    Result configure(const(char)[] passphrase, const(char)[] ssid,
                     const(ubyte)[6] ap_mac_, const(ubyte)[] ap_rsn_ie_)
    {
        import urt.crypto.pbkdf2 : wpa2_psk_to_pmk;

        have_pmk = false;
        auto r = wpa2_psk_to_pmk(passphrase, ssid, pmk);
        if (!r)
            return r;

        ap_mac = ap_mac_;
        ap_rsn_ie = ap_rsn_ie_;
        gtk_key_id = 1;
        gtk_rsc[] = 0;
        gtk_len = wpa_gtk_len_ccmp;
        if (!crypto_random_bytes(gtk[0 .. gtk_len]).succeeded)
            return InternalResult.failed;

        have_pmk = true;
        return Result.success;
    }

    // A station associated -> arm and kick off its 4-way handshake.
    bool station_join(const(ubyte)[6] sta_mac)
    {
        if (!have_pmk)
            return false;
        size_t idx = find(sta_mac);
        if (idx == max_stations)
            idx = alloc();
        if (idx == max_stations)
            return false;

        FourwayAuthContext* c = &_sta[idx];
        *c = FourwayAuthContext.init;
        c.hooks.send_eapol = &fwd_send_eapol;
        c.hooks.install_pairwise_key = &fwd_install_pairwise;
        c.hooks.install_group_key = &fwd_install_group;
        c.hooks.handshake_complete = &fwd_complete;
        c.configure(pmk, ap_mac, sta_mac, ap_rsn_ie, gtk[0 .. gtk_len], gtk_key_id, gtk_rsc);
        _active[idx] = true;
        return c.begin();
    }

    void station_leave(const(ubyte)[6] sta_mac)
    {
        size_t idx = find(sta_mac);
        if (idx != max_stations)
        {
            _active[idx] = false;
            _sta[idx] = FourwayAuthContext.init;
        }
    }

    bool handle_eapol(const(ubyte)[6] sta_mac, const(ubyte)[] frame)
    {
        size_t idx = find(sta_mac);
        if (idx == max_stations)
            return false;
        return _sta[idx].handle_eapol(frame);
    }

    void tick(ulong now_us)
    {
        foreach (i; 0 .. max_stations)
            if (_active[i])
                _sta[i].tick(now_us);
    }

    bool needs_tick() const pure
    {
        import urt.driver.wpa.fourway : FourwayAuthState;
        foreach (i; 0 .. max_stations)
        {
            if (!_active[i])
                continue;
            if (_sta[i].state == FourwayAuthState.awaiting_msg2 ||
                _sta[i].state == FourwayAuthState.awaiting_msg4)
                return true;
        }
        return false;
    }

private:

    // Adapt the per-station delegate hooks onto the driver function pointers.
    bool fwd_send_eapol(const(ubyte)[6] sta, const(ubyte)[] eapol)
        => hooks.send_eapol !is null && hooks.send_eapol(sta, eapol);
    bool fwd_install_pairwise(const(ubyte)[6] sta, const(ubyte)[] tk)
        => hooks.install_pairwise_key !is null && hooks.install_pairwise_key(sta, tk);
    bool fwd_install_group(const(ubyte)[6] sta, ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
        => hooks.install_group_key !is null && hooks.install_group_key(sta, key_idx, gtk, rsc);
    void fwd_complete(const(ubyte)[6] sta, bool success, ushort reason)
    {
        if (hooks.handshake_complete !is null)
            hooks.handshake_complete(sta, success, reason);
    }

    FourwayAuthContext[max_stations] _sta;
    bool[max_stations] _active;

    size_t find(const(ubyte)[6] mac)
    {
        foreach (i; 0 .. max_stations)
            if (_active[i] && _sta[i].sta_mac[] == mac[])
                return i;
        return max_stations;
    }

    size_t alloc()
    {
        foreach (i; 0 .. max_stations)
            if (!_active[i])
                return i;
        return max_stations;
    }
}
