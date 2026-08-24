// WPA STA-side supplicant. Holds the per-association keying state and bridges
// libwifi's wpa_funcs callbacks to the 4-way handshake state machine. Driver
// adapters (BL808, ESP32, ...) own a singleton WpaStaSupplicant and translate
// vendor-blob callbacks into method calls.
//
// Currently implements WPA2-PSK (CCMP, key descriptor v2). WPA3-SAE and
// EAP-TLS are planned extensions: factor an AKM trait out of the fourway
// dependency when the second AKM lands.
module urt.driver.wpa.supplicant;

import urt.crypto.pbkdf2 : wpa2_psk_to_pmk, Pbkdf2Sha1;
import urt.driver.wpa.crypto : wpa_nonce_len, wpa_pmk_len;
import urt.driver.wifi : WifiAuth, WifiStaConfig;
import urt.result : Result, InternalResult;

import urt.driver.wpa.fourway;

nothrow @nogc:


enum WpaSupplicantState : ubyte
{
    idle,
    deriving,      // PMK derivation in flight; pmk_step() drives it to configured
    configured,
    associating,
    associated,    // assoc done, waiting for first EAPOL key frame
    keying,        // 4-way handshake in progress
    completed,
    failed,
}

enum WpaKeyMgmt : ubyte
{
    none,
    wpa2_psk,
    sae,
    enterprise,
}

struct WpaStaProfile
{
    const(char)[] ssid;
    const(char)[] passphrase;
    ubyte[6] bssid;
    bool pmf_required;
    WpaKeyMgmt key_mgmt;
}

// Driver-side hooks the supplicant calls during the 4-way handshake. The
// adapter populates these to bridge to libwifi (or whatever owns the link).
struct WpaSupplicantHooks
{
    bool function(ubyte key_idx, const(ubyte)[] key, const(ubyte)[] rsc) nothrow @nogc install_group_key;
    bool function(const(ubyte)[] tk, const(ubyte)[] rsc) nothrow @nogc install_pairwise_key;
    bool function(const(ubyte)[] eapol) nothrow @nogc send_eapol;
    bool function(ushort reason_code) nothrow @nogc auth_done;
}

struct WpaStaSupplicant
{
    WpaSupplicantState state;
    WpaStaProfile profile;
    WpaSupplicantHooks hooks;
    ubyte[wpa_pmk_len] pmk;
    ubyte[6] own_mac;
    ushort last_reason;
    uint rx_eapol_count;
    uint tx_eapol_count;

    // 4-way handshake state. The supplicant pumps EAPOL frames into this and
    // installs keys via the driver hooks when the handshake completes.
    FourwayContext fourway;

nothrow @nogc:

    // configure() derives the PMK synchronously (~1.7s of PBKDF2 on a 120MHz ARM9). Drivers
    // that cannot stall use this instead and call pmk_step() in slices until it returns true.
    // cfg.ssid / cfg.password must stay valid until then.
    Result configure_deferred(ref const WifiStaConfig cfg)
    {
        profile.ssid = cfg.ssid;
        profile.passphrase = cfg.password;
        profile.bssid = cfg.bssid;
        profile.pmf_required = cfg.pmf_required;
        profile.key_mgmt = infer_key_mgmt(cfg);
        _pmk_pending = false;
        _pmk_valid = false;

        if (profile.pmf_required)
        {
            state = WpaSupplicantState.failed;
            last_reason = cast(ushort)WpaHandshakeReason.pmf_required_unsupported;
            return InternalResult.unsupported;
        }

        if (profile.key_mgmt == WpaKeyMgmt.wpa2_psk)
        {
            if (profile.passphrase.length < 8 || profile.passphrase.length > 63 ||
                profile.ssid.length == 0 || profile.ssid.length > 32)
            {
                state = WpaSupplicantState.failed;
                return InternalResult.invalid_parameter;
            }
            Result r = start_derivation();
            if (r.failed)
            {
                state = WpaSupplicantState.failed;
                return r;
            }
            state = WpaSupplicantState.deriving;
            return Result.success;
        }

        state = WpaSupplicantState.configured;
        return Result.success;
    }

    // A usable PMK is in place (or the profile needs none).
    bool pmk_ready() const pure
        => !_pmk_pending && (_pmk_valid || profile.key_mgmt != WpaKeyMgmt.wpa2_psk);

    // Only a derivation that configure_deferred() started advances; a cancelled one stays cancelled
    // until the profile is configured again.
    bool pmk_step(uint iterations)
    {
        if (state != WpaSupplicantState.deriving || !_pmk_pending)
            return pmk_ready;
        if (_kdf.step(iterations))
        {
            _pmk_pending = false;
            _pmk_valid = true;
            state = WpaSupplicantState.configured;
        }
        return !_pmk_pending;
    }

    Result configure(ref const WifiStaConfig cfg)
    {
        profile.ssid = cfg.ssid;
        profile.passphrase = cfg.password;
        profile.bssid = cfg.bssid;
        profile.pmf_required = cfg.pmf_required;
        profile.key_mgmt = infer_key_mgmt(cfg);
        _pmk_pending = false;
        _pmk_valid = false;

        if (profile.pmf_required)
        {
            state = WpaSupplicantState.failed;
            last_reason = cast(ushort)WpaHandshakeReason.pmf_required_unsupported;
            return InternalResult.unsupported;
        }

        if (profile.key_mgmt == WpaKeyMgmt.wpa2_psk)
        {
            auto r = wpa2_psk_to_pmk(profile.passphrase, profile.ssid, pmk);
            if (!r)
            {
                state = WpaSupplicantState.failed;
                return r;
            }
            _pmk_valid = true;
        }

        state = WpaSupplicantState.configured;
        return Result.success;
    }

    Result configure_precomputed(ref const WifiStaConfig cfg, const(ubyte)[] pmk_)
    {
        if (pmk_.length != wpa_pmk_len)
        {
            state = WpaSupplicantState.failed;
            return InternalResult.failed;
        }

        profile.ssid = cfg.ssid;
        profile.passphrase = cfg.password;
        profile.bssid = cfg.bssid;
        profile.pmf_required = cfg.pmf_required;
        profile.key_mgmt = infer_key_mgmt(cfg);
        _pmk_pending = false;
        _pmk_valid = false;

        if (profile.pmf_required)
        {
            state = WpaSupplicantState.failed;
            last_reason = cast(ushort)WpaHandshakeReason.pmf_required_unsupported;
            return InternalResult.unsupported;
        }

        if (profile.key_mgmt == WpaKeyMgmt.wpa2_psk)
        {
            pmk[] = pmk_[0 .. wpa_pmk_len];
            _pmk_valid = true;
        }

        state = WpaSupplicantState.configured;
        return Result.success;
    }

    void begin_association(const(ubyte)[6] local_mac, const(ubyte)[] sta_rsn_ie)
    {
        own_mac = local_mac;
        last_reason = 0;
        rx_eapol_count = 0;
        tx_eapol_count = 0;

        if (state != WpaSupplicantState.configured || !pmk_ready)
        {
            state = WpaSupplicantState.failed;
            last_reason = cast(ushort)WpaHandshakeReason.pmk_not_ready;
            return;
        }
        state = WpaSupplicantState.associating;

        if (profile.key_mgmt == WpaKeyMgmt.wpa2_psk)
        {
            fourway.configure(pmk, own_mac, profile.bssid, sta_rsn_ie);
            fourway.hooks.send_eapol = &fourway_send_eapol;
            fourway.hooks.install_pairwise_key = &fourway_install_pairwise;
            fourway.hooks.install_group_key = &fourway_install_group;
            fourway.hooks.handshake_complete = &fourway_complete;
        }
    }

    void associated(const(ubyte)[6] ap_mac)
    {
        if (state == WpaSupplicantState.failed)
        {
            if (hooks.auth_done)
                hooks.auth_done(last_reason);
            return;
        }

        profile.bssid = ap_mac;
        if (profile.key_mgmt == WpaKeyMgmt.none)
        {
            state = WpaSupplicantState.completed;
            if (hooks.auth_done)
                hooks.auth_done(0);
            return;
        }

        state = WpaSupplicantState.associated;
        fourway.bssid = ap_mac;     // in case bssid wasn't known at begin_association
        fourway.begin_association();
        state = WpaSupplicantState.keying;
    }

    int receive_eapol(const(ubyte)[] frame)
    {
        ++rx_eapol_count;
        if (profile.key_mgmt != WpaKeyMgmt.wpa2_psk)
            return -1;
        return fourway.handle_eapol(frame) ? 0 : -1;
    }

    void disconnected(ushort reason_code)
    {
        _pmk_pending = false;
        last_reason = reason_code;
        fourway.hooks.handshake_complete = null;
        state = WpaSupplicantState.failed;
        fourway.reset(reason_code);
    }

private:
    Pbkdf2Sha1 _kdf;
    bool _pmk_pending;
    bool _pmk_valid;

    Result start_derivation()
    {
        _pmk_valid = false;
        Result r = _kdf.begin(cast(const(ubyte)[])profile.passphrase, cast(const(ubyte)[])profile.ssid, 4096, pmk[]);
        _pmk_pending = !r.failed;
        return r;
    }

    bool fourway_send_eapol(const(ubyte)[] eapol)
    {
        if (hooks.send_eapol is null) return false;
        ++tx_eapol_count;
        return hooks.send_eapol(eapol);
    }

    bool fourway_install_pairwise(const(ubyte)[] tk)
    {
        if (hooks.install_pairwise_key is null) return false;
        ubyte[6] empty_rsc = 0;
        return hooks.install_pairwise_key(tk, empty_rsc[]);
    }

    bool fourway_install_group(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc)
    {
        if (hooks.install_group_key is null) return false;
        return hooks.install_group_key(key_idx, gtk, rsc);
    }

    void fourway_complete(bool success, ushort reason)
    {
        state = success ? WpaSupplicantState.completed : WpaSupplicantState.failed;
        last_reason = reason;
        if (hooks.auth_done)
            hooks.auth_done(reason);
    }
}


WpaKeyMgmt infer_key_mgmt(ref const WifiStaConfig cfg)
{
    if (cfg.password.length == 0)
        return WpaKeyMgmt.none;

    // WPA2-PSK is the only AKM implemented, so a passphrase means WPA2-PSK.
    return WpaKeyMgmt.wpa2_psk;
}

unittest
{
    ubyte[6] mac = [2, 0, 0, 0, 0, 1];
    WifiStaConfig cfg;
    cfg.ssid = "ssid";
    cfg.password = "passphrase";

    // deferred derivation lands on the same PMK as the synchronous path
    WpaStaSupplicant sync_, deferred;
    assert(sync_.configure(cfg));
    assert(deferred.configure_deferred(cfg));
    assert(deferred.state == WpaSupplicantState.deriving);
    assert(!deferred.pmk_ready);
    while (!deferred.pmk_step(512)) {}
    assert(deferred.state == WpaSupplicantState.configured);
    assert(deferred.pmk_ready && deferred.pmk == sync_.pmk);

    // a rejected profile never derives, and cannot associate
    WifiStaConfig bad = cfg;
    bad.password = "12345";
    WpaStaSupplicant rejected;
    assert(rejected.configure_deferred(bad).failed);
    assert(rejected.state == WpaSupplicantState.failed);
    assert(!rejected.pmk_step(8192));
    assert(!rejected.pmk_ready);
    rejected.begin_association(mac, null);
    assert(rejected.state == WpaSupplicantState.failed);
    assert(rejected.last_reason == WpaHandshakeReason.pmk_not_ready);

    // a cancelled derivation stays cancelled until reconfigured
    WpaStaSupplicant cancelled;
    assert(cancelled.configure_deferred(cfg));
    assert(!cancelled.pmk_step(8));
    cancelled.disconnected(3);
    assert(cancelled.state == WpaSupplicantState.failed);
    assert(!cancelled.pmk_step(8192));
    assert(!cancelled.pmk_ready);
    assert(cancelled.configure_deferred(cfg));
    while (!cancelled.pmk_step(512)) {}
    assert(cancelled.pmk == sync_.pmk);

    // a synchronous configure supersedes a derivation in flight
    WpaStaSupplicant superseded;
    assert(superseded.configure_deferred(cfg));
    assert(superseded.configure(cfg));
    assert(superseded.pmk_ready && superseded.pmk == sync_.pmk);
    assert(superseded.pmk_step(8192));
    assert(superseded.state == WpaSupplicantState.configured);
}
