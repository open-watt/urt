module urt.driver.wpa.fourway;

import urt.crypto.aes_keywrap : aes_unwrap, aes_wrap;
import urt.crypto.random : crypto_random_bytes;
import urt.driver.wpa.crypto;
import urt.result : Result, InternalResult;

import urt.driver.wpa.eapol;

nothrow @nogc:

enum size_t wpa_kck_len      = 16;
enum size_t wpa_kek_len      = 16;
enum size_t wpa_tk_len_ccmp  = 16;
enum size_t wpa_gtk_max_len  = 32;
enum size_t wpa_max_eapol_len = 256;     // typical handshake frame is ~120 bytes

enum FourwayState : ubyte
{
    idle,
    awaiting_msg1,
    awaiting_msg3,
    completed,
    failed,
}

enum WpaHandshakeReason : ushort
{
    none,
    random_failed,
    ptk_failed,
    encode_failed,
    tx_failed,
    mic_failed,
    nonce_mismatch,
    malformed_key_data,
    gtk_unwrap_failed,
    gtk_missing,
    pairwise_install_failed,
    group_install_failed,
    pmf_required_unsupported,
    timeout,
    pmk_not_ready,
}

struct FourwayHooks
{
    // EAPOL payload only; the driver supplies the Ethernet header.
    bool delegate(const(ubyte)[] eapol_payload) nothrow @nogc send_eapol;

    bool delegate(const(ubyte)[] tk) nothrow @nogc install_pairwise_key;

    // RSC contains the six least-significant replay-counter bytes.
    bool delegate(ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc) nothrow @nogc install_group_key;

    void delegate(bool success, ushort reason) nothrow @nogc handshake_complete;
    // Deferred GTK rekeys finish through group_key_installed().
    bool deferred_group_install;
}

struct FourwayContext
{
    FourwayHooks hooks;

    // Caller owns the RSN IE storage through the handshake.
    const(ubyte)[] sta_rsn_ie;
    ubyte[wpa_pmk_len] pmk;
    ubyte[6] own_mac;
    ubyte[6] bssid;

    ubyte[wpa_nonce_len] anonce;
    ubyte[wpa_nonce_len] snonce;
    ubyte[wpa_ptk_len_ccmp] ptk;
    ubyte[eapol_key_replay_len] last_replay;
    ubyte reply_version;
    FourwayState state;

    ubyte[wpa_gtk_max_len] installed_gtk;
    ubyte installed_gtk_len;
    ubyte installed_gtk_id;
    bool group_reply_valid;
    bool group_install_pending;

nothrow @nogc:

    void configure(const(ubyte)[wpa_pmk_len] pmk_, const(ubyte)[6] own_mac_, const(ubyte)[6] bssid_, const(ubyte)[] sta_rsn_ie_)
    {
        pmk = pmk_;
        own_mac = own_mac_;
        bssid = bssid_;
        sta_rsn_ie = sta_rsn_ie_;
        state = FourwayState.idle;
    }

    void begin_association()
    {
        state = FourwayState.awaiting_msg1;
        last_replay[] = 0;
        installed_gtk_len = 0;
        group_reply_valid = false;
        group_install_pending = false;
    }

    void reset(WpaHandshakeReason reason)
    {
        reset(cast(ushort)reason);
    }

    void reset(ushort reason)
    {
        group_reply_valid = false;
        group_install_pending = false;
        if (state != FourwayState.idle && state != FourwayState.failed)
        {
            state = FourwayState.failed;
            if (hooks.handshake_complete)
                hooks.handshake_complete(false, reason);
        }
        else
            state = FourwayState.idle;
    }

    @property const(ubyte)[] kck() const => ptk[0 .. wpa_kck_len];
    @property const(ubyte)[] kek() const => ptk[wpa_kck_len .. wpa_kck_len + wpa_kek_len];
    @property const(ubyte)[] tk()  const => ptk[wpa_kck_len + wpa_kek_len .. $];

    bool handle_eapol(const(ubyte)[] frame)
    {
        EapolKeyFrame f;
        if (!decode_eapol_key(frame, f))
            return false;
        if (f.descriptor_type != key_desc_type_rsn)
            return false;
        if (f.version_bits != key_info_ver_hmac_sha1_aes)
            return false;
        if (!f.key_ack || f.error || f.request || (f.key_info & key_info_smk_message))
            return false;
        if (!f.pairwise)
            return handle_group(frame, f);

        if (!f.key_mic_set)
            return handle_msg1(frame, f);
        else
            return handle_msg3(frame, f);
    }

    void group_key_installed(bool success)
    {
        if (!group_install_pending)
            return;
        group_install_pending = false;
        if (!success)
            reset(WpaHandshakeReason.group_install_failed);
        else if (!send_reply(false))
            reset(WpaHandshakeReason.tx_failed);
    }

private:

    bool send_reply(bool pairwise)
    {
        ushort flags = key_info_ver_hmac_sha1_aes | key_info_key_mic | key_info_secure;
        if (pairwise)
            flags |= key_info_type_pairwise;
        ubyte[eapol_key_fixed_len] reply;
        ubyte[wpa_nonce_len] nonce;
        ubyte[eapol_key_rsc_len] rsc;
        ubyte[eapol_key_mic_len] mic;
        auto length = encode_eapol_key(reply[], reply_version, key_desc_type_rsn, flags, 0, last_replay, nonce, rsc, null);
        assert(length == reply.length);
        eapol_key_compute_mic(kck, reply[], mic);
        patch_mic(reply[], mic);
        return hooks.send_eapol(reply[]);
    }

    bool handle_group(const(ubyte)[] frame, ref const EapolKeyFrame f)
    {
        if (state != FourwayState.completed || !f.key_mic_set || !f.secure || f.install)
            return false;
        if (!eapol_key_verify_mic(kck, frame, f.key_mic))
            return true;
        int replay = eapol_key_replay_compare(f.replay_counter, last_replay);
        if (replay < 0)
            return true;
        if (replay == 0)
        {
            if (group_reply_valid && !group_install_pending)
                send_reply(false);
            return true;
        }

        size_t gtk_len;
        ubyte[wpa_gtk_max_len] gtk;
        ubyte gtk_id;
        if (!read_gtk(f, gtk, gtk_len, gtk_id))
            return true;
        bool same_key = gtk_len == installed_gtk_len && gtk[0 .. gtk_len] == installed_gtk[0 .. installed_gtk_len];
        if (group_install_pending && (!same_key || gtk_id != installed_gtk_id))
            return true;

        reply_version = f.version_;
        group_reply_valid = true;
        last_replay = f.replay_counter;

        // Repeated GTK material must not reset hardware replay counters.
        if (!same_key)
        {
            group_install_pending = hooks.deferred_group_install;
            if (!hooks.install_group_key(gtk_id, gtk[0 .. gtk_len], f.key_rsc[0 .. 6]))
            {
                reset(WpaHandshakeReason.group_install_failed);
                return true;
            }
            installed_gtk[0 .. gtk_len] = gtk[0 .. gtk_len];
            installed_gtk_len = cast(ubyte)gtk_len;
            installed_gtk_id = gtk_id;
        }
        if (!group_install_pending && !send_reply(false))
            reset(WpaHandshakeReason.tx_failed);
        return true;
    }

    bool read_gtk(ref const EapolKeyFrame f, ref ubyte[wpa_gtk_max_len] gtk, ref size_t gtk_len, ref ubyte gtk_id)
    {
        ubyte[256] plain;
        if (!f.encr_key_data || f.key_data.length < 24 || f.key_data.length > plain.length + 8 || f.key_data.length % 8)
        {
            reset(WpaHandshakeReason.malformed_key_data);
            return false;
        }
        auto unwrapped = plain[0 .. f.key_data.length - 8];
        if (!aes_unwrap(kek, f.key_data, unwrapped).succeeded)
        {
            reset(WpaHandshakeReason.gtk_unwrap_failed);
            return false;
        }
        if (!parse_gtk_kde(unwrapped, gtk[], gtk_len, gtk_id))
        {
            reset(WpaHandshakeReason.gtk_missing);
            return false;
        }
        return true;
    }

    bool handle_msg1(const(ubyte)[] /*frame*/, ref const EapolKeyFrame f)
    {
        if (state != FourwayState.awaiting_msg1 && state != FourwayState.awaiting_msg3)
            return false;

        anonce = f.key_nonce;
        last_replay = f.replay_counter;

        if (!crypto_random_bytes(snonce[]).succeeded)
        {
            reset(WpaHandshakeReason.random_failed);
            return true;
        }

        auto r = wpa2_pmk_to_ptk(pmk, bssid, own_mac, anonce, snonce, ptk[]);
        if (!r.succeeded)
        {
            reset(WpaHandshakeReason.ptk_failed);
            return true;
        }

        ushort key_info = key_info_type_pairwise | key_info_key_mic | key_info_ver_hmac_sha1_aes;
        ubyte[8] zero_rsc = 0;

        ubyte[wpa_max_eapol_len] out_buf = void;
        size_t out_len = encode_eapol_key(out_buf[], eapol_version_2004, key_desc_type_rsn, key_info, f.key_length, last_replay, snonce, zero_rsc, sta_rsn_ie);
        if (out_len == 0)
        {
            reset(WpaHandshakeReason.encode_failed);
            return true;
        }

        ubyte[eapol_key_mic_len] mic;
        eapol_key_compute_mic(kck, out_buf[0 .. out_len], mic);
        patch_mic(out_buf[0 .. out_len], mic);

        if (!hooks.send_eapol(out_buf[0 .. out_len]))
        {
            reset(WpaHandshakeReason.tx_failed);
            return true;
        }

        state = FourwayState.awaiting_msg3;
        return true;
    }

    bool handle_msg3(const(ubyte)[] frame, ref const EapolKeyFrame f)
    {
        if (!f.install || !f.secure)
            return false;
        if (state != FourwayState.awaiting_msg3)
        {
            if (state != FourwayState.completed || group_reply_valid)
                return false;
            if (eapol_key_replay_compare(f.replay_counter, last_replay) < 0 || f.key_nonce != anonce || !eapol_key_verify_mic(kck, frame, f.key_mic))
                return true;
            last_replay = f.replay_counter;
            send_reply(true);
            return true;
        }

        if (eapol_key_replay_compare(f.replay_counter, last_replay) <= 0)
            return true;

        if (!eapol_key_verify_mic(kck, frame, f.key_mic))
        {
            reset(WpaHandshakeReason.mic_failed);
            return true;
        }

        last_replay = f.replay_counter;

        foreach (i; 0 .. wpa_nonce_len)
        {
            if (f.key_nonce[i] != anonce[i])
            {
                reset(WpaHandshakeReason.nonce_mismatch);
                return true;
            }
        }

        size_t gtk_len;
        ubyte[wpa_gtk_max_len] gtk = void;
        ubyte[6] gtk_rsc;
        ubyte gtk_key_id;
        gtk_rsc[] = f.key_rsc[0 .. 6];
        if (!read_gtk(f, gtk, gtk_len, gtk_key_id))
            return true;

        reply_version = eapol_version_2004;
        if (!send_reply(true))
        {
            reset(WpaHandshakeReason.tx_failed);
            return true;
        }
        // BL808 chooses queued TX encryption from the installed keys; queue msg 4 before installing PTK/GTK.
        if (!hooks.install_pairwise_key(tk))
        {
            reset(WpaHandshakeReason.pairwise_install_failed);
            return true;
        }
        if (!hooks.install_group_key(gtk_key_id, gtk[0 .. gtk_len], gtk_rsc[]))
        {
            reset(WpaHandshakeReason.group_install_failed);
            return true;
        }
        installed_gtk[0 .. gtk_len] = gtk[0 .. gtk_len];
        installed_gtk_len = cast(ubyte)gtk_len;
        installed_gtk_id = gtk_key_id;

        state = FourwayState.completed;
        if (hooks.handshake_complete)
            hooks.handshake_complete(true, 0);
        return true;
    }
}

const(char)[] wpa_handshake_reason_message(ushort reason) pure nothrow @nogc
{
    switch (cast(WpaHandshakeReason)reason)
    {
        case WpaHandshakeReason.none:                    return null;
        case WpaHandshakeReason.random_failed:           return "WPA handshake failed: random nonce generation failed";
        case WpaHandshakeReason.ptk_failed:              return "WPA handshake failed: PTK derivation failed";
        case WpaHandshakeReason.encode_failed:           return "WPA handshake failed: EAPOL frame encode failed";
        case WpaHandshakeReason.tx_failed:               return "WPA handshake failed: EAPOL transmit failed";
        case WpaHandshakeReason.mic_failed:              return "WPA handshake failed: key MIC verification failed";
        case WpaHandshakeReason.nonce_mismatch:          return "WPA handshake failed: AP nonce changed during handshake";
        case WpaHandshakeReason.malformed_key_data:      return "WPA handshake failed: malformed AP key data";
        case WpaHandshakeReason.gtk_unwrap_failed:       return "WPA handshake failed: GTK unwrap failed";
        case WpaHandshakeReason.gtk_missing:             return "WPA handshake failed: AP did not provide GTK";
        case WpaHandshakeReason.pairwise_install_failed: return "WPA handshake failed: pairwise key install failed";
        case WpaHandshakeReason.group_install_failed:    return "WPA handshake failed: group key install failed";
        case WpaHandshakeReason.pmf_required_unsupported:return "WPA PMF-required networks are not supported yet";
        case WpaHandshakeReason.timeout:                 return "WPA handshake failed: timed out waiting for peer";
        default:                                        return "WPA handshake failed";
    }
}

private enum ulong retx_interval_us = 500_000;
private enum uint  retx_max         = 3;

enum FourwayAuthState : ubyte
{
    idle,
    awaiting_msg2,       // sent msg 1, waiting for the STA's SNonce
    awaiting_msg4,       // sent msg 3, waiting for the STA's confirm
    completed,
    failed,
}

struct FourwayAuthHooks
{
    bool delegate(const(ubyte)[6] sta, const(ubyte)[] eapol_payload) nothrow @nogc send_eapol;
    bool delegate(const(ubyte)[6] sta, const(ubyte)[] tk) nothrow @nogc install_pairwise_key;
    bool delegate(const(ubyte)[6] sta, ubyte key_idx, const(ubyte)[] gtk, const(ubyte)[] rsc) nothrow @nogc install_group_key;
    void delegate(const(ubyte)[6] sta, bool success, ushort reason) nothrow @nogc handshake_complete;
}

struct FourwayAuthContext
{
    FourwayAuthHooks hooks;

    ulong next_retx_us;
    size_t last_tx_len;
    uint retx_count;
    ubyte[wpa_max_eapol_len] last_tx;

    // Caller owns the RSN IE storage through the handshake.
    const(ubyte)[] ap_rsn_ie;
    size_t gtk_len;
    ubyte[wpa_gtk_max_len] gtk;
    ubyte[eapol_key_rsc_len] gtk_rsc;

    ubyte[wpa_pmk_len] pmk;
    ubyte[6] ap_mac;
    ubyte[6] sta_mac;
    ubyte[wpa_nonce_len] anonce;
    ubyte[wpa_nonce_len] snonce;
    ubyte[wpa_ptk_len_ccmp] ptk;
    ubyte[eapol_key_replay_len] replay;
    ubyte gtk_key_id;
    FourwayAuthState state;

nothrow @nogc:

    void configure(const(ubyte)[wpa_pmk_len] pmk_, const(ubyte)[6] ap_mac_, const(ubyte)[6] sta_mac_, const(ubyte)[] ap_rsn_ie_, const(ubyte)[] gtk_, ubyte gtk_key_id_, const(ubyte)[eapol_key_rsc_len] gtk_rsc_)
    {
        pmk = pmk_;
        ap_mac = ap_mac_;
        sta_mac = sta_mac_;
        ap_rsn_ie = ap_rsn_ie_;
        gtk_len = gtk_.length <= gtk.length ? gtk_.length : gtk.length;
        gtk[0 .. gtk_len] = gtk_[0 .. gtk_len];
        gtk_key_id = gtk_key_id_;
        gtk_rsc = gtk_rsc_;
        state = FourwayAuthState.idle;
        replay[] = 0;
        last_tx_len = 0;
        retx_count = 0;
        next_retx_us = 0;
    }

    @property const(ubyte)[] kck() const => ptk[0 .. wpa_kck_len];
    @property const(ubyte)[] kek() const => ptk[wpa_kck_len .. wpa_kck_len + wpa_kek_len];
    @property const(ubyte)[] tk()  const => ptk[wpa_kck_len + wpa_kek_len .. $];

    bool begin()
    {
        if (!crypto_random_bytes(anonce[]).succeeded)
        {
            fail(WpaHandshakeReason.random_failed);
            return false;
        }
        replay[] = 0;
        inc_replay();                       // replay = 1 for msg 1
        state = FourwayAuthState.awaiting_msg2;
        if (!send_msg1())
        {
            fail(WpaHandshakeReason.tx_failed);
            return false;
        }
        return true;
    }

    bool handle_eapol(const(ubyte)[] frame)
    {
        EapolKeyFrame f;
        if (!decode_eapol_key(frame, f))
            return false;
        if (f.descriptor_type != key_desc_type_rsn)
            return false;
        if (f.version_bits != key_info_ver_hmac_sha1_aes)
            return false;
        if (!f.pairwise)
            return false;
        if (f.key_ack)              // STA->AP frames never carry the ACK bit
            return false;
        if (!f.key_mic_set)         // msg 2 and msg 4 always carry a MIC
            return false;

        // Ethernet padding is outside the EAPOL MIC.
        size_t pdu = eapol_hdr_len + f.body_length;
        if (pdu <= frame.length)
            frame = frame[0 .. pdu];

        if (!f.secure)
            return handle_msg2(frame, f);
        else
            return handle_msg4(frame, f);
    }

    void tick(ulong now_us)
    {
        if (state != FourwayAuthState.awaiting_msg2 && state != FourwayAuthState.awaiting_msg4)
            return;
        if (last_tx_len == 0)
            return;
        if (next_retx_us == 0)              // arm on the first tick after a send
        {
            next_retx_us = now_us + retx_interval_us;
            return;
        }
        if (now_us < next_retx_us)
            return;
        if (retx_count >= retx_max)
        {
            fail(WpaHandshakeReason.timeout);
            return;
        }
        if (hooks.send_eapol)
            hooks.send_eapol(sta_mac, last_tx[0 .. last_tx_len]);
        ++retx_count;
        next_retx_us = now_us + retx_interval_us;
    }

    void reset()
    {
        state = FourwayAuthState.idle;
        last_tx_len = 0;
        next_retx_us = 0;
    }

private:

    bool send_msg1()
    {
        ushort key_info = key_info_type_pairwise | key_info_key_ack | key_info_ver_hmac_sha1_aes;
        ubyte[eapol_key_rsc_len] zero_rsc = 0;

        ubyte[wpa_max_eapol_len] buf = void;
        size_t len = encode_eapol_key(buf[], eapol_version_2004, key_desc_type_rsn, key_info, wpa_tk_len_ccmp, replay, anonce, zero_rsc, null);
        if (len == 0)
            return false;
        return tx(buf[0 .. len]);
    }

    bool handle_msg2(const(ubyte)[] frame, ref const EapolKeyFrame f)
    {
        if (state != FourwayAuthState.awaiting_msg2)
            return false;
        if (eapol_key_replay_compare(f.replay_counter, replay) != 0)
            return true;        // not the reply to our outstanding msg 1

        snonce = f.key_nonce;
        if (!wpa2_pmk_to_ptk(pmk, ap_mac, sta_mac, anonce, snonce, ptk[]).succeeded)
        {
            fail(WpaHandshakeReason.ptk_failed);
            return true;
        }
        if (!eapol_key_verify_mic(kck, frame, f.key_mic))
        {
            fail(WpaHandshakeReason.mic_failed);
            return true;
        }

        state = FourwayAuthState.awaiting_msg4;
        if (!send_msg3())
        {
            fail(WpaHandshakeReason.encode_failed);
            return true;
        }
        return true;
    }

    bool send_msg3()
    {
        ubyte[wpa_max_eapol_len] plain = void;
        if (ap_rsn_ie.length + 8 + gtk_len + 8 > plain.length)
            return false;
        size_t plen = ap_rsn_ie.length;
        plain[0 .. plen] = ap_rsn_ie[];
        size_t kde = encode_gtk_kde(plain[plen .. $], gtk_key_id, gtk[0 .. gtk_len]);
        if (kde == 0)
            return false;
        plen += kde;
        if ((plen & 7) != 0)
        {
            plain[plen++] = 0xDD;           // pad KDE
            while ((plen & 7) != 0)
                plain[plen++] = 0x00;
        }

        ubyte[wpa_max_eapol_len] wrapped = void;
        size_t wlen = plen + 8;
        if (wlen > wrapped.length)
            return false;
        if (!aes_wrap(kek, plain[0 .. plen], wrapped[0 .. wlen]).succeeded)
            return false;

        inc_replay();                       // replay = 2 for msg 3
        ushort key_info = key_info_type_pairwise | key_info_install | key_info_key_ack |
            key_info_key_mic | key_info_secure | key_info_encr_key_data | key_info_ver_hmac_sha1_aes;

        ubyte[wpa_max_eapol_len] buf = void;
        size_t len = encode_eapol_key(buf[], eapol_version_2004, key_desc_type_rsn, key_info, wpa_tk_len_ccmp, replay, anonce, gtk_rsc, wrapped[0 .. wlen]);
        if (len == 0)
            return false;

        ubyte[eapol_key_mic_len] mic;
        eapol_key_compute_mic(kck, buf[0 .. len], mic);
        patch_mic(buf[0 .. len], mic);
        return tx(buf[0 .. len]);
    }

    bool handle_msg4(const(ubyte)[] frame, ref const EapolKeyFrame f)
    {
        if (state != FourwayAuthState.awaiting_msg4)
            return false;
        if (eapol_key_replay_compare(f.replay_counter, replay) != 0)
            return true;
        if (!eapol_key_verify_mic(kck, frame, f.key_mic))
        {
            fail(WpaHandshakeReason.mic_failed);
            return true;
        }

        if (hooks.install_pairwise_key && !hooks.install_pairwise_key(sta_mac, tk))
        {
            fail(WpaHandshakeReason.pairwise_install_failed);
            return true;
        }
        if (hooks.install_group_key && !hooks.install_group_key(sta_mac, gtk_key_id, gtk[0 .. gtk_len], gtk_rsc[]))
        {
            fail(WpaHandshakeReason.group_install_failed);
            return true;
        }

        last_tx_len = 0;
        state = FourwayAuthState.completed;
        if (hooks.handshake_complete)
            hooks.handshake_complete(sta_mac, true, 0);
        return true;
    }

    bool tx(const(ubyte)[] eapol)
    {
        if (eapol.length <= last_tx.length)
        {
            last_tx[0 .. eapol.length] = eapol[];
            last_tx_len = eapol.length;
        }
        retx_count = 0;
        next_retx_us = 0;                   // tick() re-arms the deadline
        if (hooks.send_eapol is null)
            return false;
        return hooks.send_eapol(sta_mac, eapol);
    }

    void inc_replay()
    {
        foreach_reverse (i; 0 .. replay.length)
        {
            if (++replay[i] != 0)
                break;
        }
    }

    void fail(WpaHandshakeReason reason)
    {
        state = FourwayAuthState.failed;
        last_tx_len = 0;
        if (hooks.handshake_complete)
            hooks.handshake_complete(sta_mac, false, cast(ushort)reason);
    }
}

unittest
{
    import urt.crypto.pbkdf2 : wpa2_psk_to_pmk;

    static immutable ubyte[22] rsn_ie = [
        0x30, 0x14,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x04,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x04,
        0x01, 0x00,
        0x00, 0x0f, 0xac, 0x02,
        0x00, 0x00,
    ];
    static immutable ubyte[16] test_gtk = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
        0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF,
    ];

    static struct Harness
    {
        enum ubyte to_sta = 1, to_ap = 2;

        FourwayAuthContext ap;
        FourwayContext sta;

        size_t[8] qlen;
        size_t qhead, qtail;
        ubyte[256][8] qbuf;
        ubyte[8] qtag;

        size_t sta_gtk_len;
        uint group_installs;
        uint pairwise_installs;
        ubyte[wpa_tk_len_ccmp] sta_tk, ap_tk;
        ubyte[wpa_gtk_max_len] sta_gtk;
        bool sta_done, sta_ok, ap_done, ap_ok;

    nothrow @nogc:

        void push(ubyte tag, const(ubyte)[] p)
        {
            assert(qtail < qbuf.length && p.length <= qbuf[0].length);
            qtag[qtail] = tag;
            qbuf[qtail][0 .. p.length] = p[];
            qlen[qtail] = p.length;
            ++qtail;
        }

        bool sta_send(const(ubyte)[] p)
        {
            push(to_ap, p);
            return true;
        }

        bool sta_pair(const(ubyte)[] t)
        {
            ++pairwise_installs;
            sta_tk[] = t[0 .. wpa_tk_len_ccmp];
            return true;
        }

        bool sta_grp(ubyte idx, const(ubyte)[] g, const(ubyte)[] rsc)
        {
            ++group_installs;
            sta_gtk_len = g.length;
            sta_gtk[0 .. g.length] = g[];
            return true;
        }

        void sta_complete(bool ok, ushort r)
        {
            sta_done = true;
            sta_ok = ok;
        }

        bool ap_send(const(ubyte)[6] s, const(ubyte)[] p)
        {
            push(to_sta, p);
            return true;
        }

        bool ap_pair(const(ubyte)[6] s, const(ubyte)[] t)
        {
            ap_tk[] = t[0 .. wpa_tk_len_ccmp];
            return true;
        }

        bool ap_grp(const(ubyte)[6] s, ubyte idx, const(ubyte)[] g, const(ubyte)[] rsc) => true;

        void ap_complete(const(ubyte)[6] s, bool ok, ushort r)
        {
            ap_done = true;
            ap_ok = ok;
        }

        void run()
        {
            uint guard = 0;
            while (qhead < qtail)
            {
                ubyte tag = qtag[qhead];
                const(ubyte)[] frame = qbuf[qhead][0 .. qlen[qhead]];
                ++qhead;
                if (tag == to_sta)
                    sta.handle_eapol(frame);
                else
                    ap.handle_eapol(frame);
                assert(++guard < 32);
            }
        }

        size_t group_frame(ref ubyte[256] frame, ubyte counter, ubyte value)
        {
            ubyte[16] gtk = value;
            ubyte[24] plain;
            assert(encode_gtk_kde(plain[], 2, gtk[]) == plain.length);
            ubyte[32] wrapped;
            assert(aes_wrap(ap.kek, plain[], wrapped[]).succeeded);
            ubyte[eapol_key_replay_len] replay;
            replay[$ - 1] = counter;
            ubyte[wpa_nonce_len] nonce;
            ubyte[eapol_key_rsc_len] rsc;
            rsc[0] = 17;
            ushort flags = key_info_ver_hmac_sha1_aes | key_info_key_ack | key_info_key_mic | key_info_secure | key_info_encr_key_data;
            size_t length = encode_eapol_key(frame[], eapol_version_2004, key_desc_type_rsn, flags, 0, replay, nonce, rsc, wrapped[]);
            ubyte[eapol_key_mic_len] mic;
            eapol_key_compute_mic(ap.kck, frame[0 .. length], mic);
            patch_mic(frame[0 .. length], mic);
            return length;
        }
    }

    ubyte[6] ap_mac  = [0x02, 0x00, 0x00, 0x00, 0x00, 0xAA];
    ubyte[6] sta_mac = [0x02, 0x00, 0x00, 0x00, 0x00, 0xBB];

    ubyte[wpa_pmk_len] pmk;
    assert(wpa2_psk_to_pmk("password123", "testnet", pmk).succeeded);

    Harness h;

    h.sta.configure(pmk, sta_mac, ap_mac, rsn_ie[]);
    h.sta.hooks.send_eapol = &h.sta_send;
    h.sta.hooks.install_pairwise_key = &h.sta_pair;
    h.sta.hooks.install_group_key = &h.sta_grp;
    h.sta.hooks.handshake_complete = &h.sta_complete;
    h.sta.begin_association();

    ubyte[eapol_key_rsc_len] gtk_rsc = 0;
    h.ap.configure(pmk, ap_mac, sta_mac, rsn_ie[], test_gtk[], 1, gtk_rsc);
    h.ap.hooks.send_eapol = &h.ap_send;
    h.ap.hooks.install_pairwise_key = &h.ap_pair;
    h.ap.hooks.install_group_key = &h.ap_grp;
    h.ap.hooks.handshake_complete = &h.ap_complete;

    assert(h.ap.begin());
    h.run();

    assert(h.sta_done && h.sta_ok);
    assert(h.ap_done && h.ap_ok);
    assert(h.sta.state == FourwayState.completed);
    assert(h.ap.state == FourwayAuthState.completed);
    assert(h.sta_tk == h.ap_tk);                            // both derived the same PTK
    assert(h.sta_gtk_len == 16 && h.sta_gtk[0 .. 16] == test_gtk[]);  // GTK delivered

    assert(h.group_installs == 1);
    h.qhead = h.qtail = 0;
    assert(h.ap.send_msg3());
    h.run();
    assert(h.sta.state == FourwayState.completed && h.group_installs == 1 && h.pairwise_installs == 1);
    EapolKeyFrame reply;
    assert(decode_eapol_key(h.qbuf[1][0 .. h.qlen[1]], reply));
    assert(reply.replay_counter == h.ap.replay);
    assert(eapol_key_verify_mic(h.ap.kck, h.qbuf[1][0 .. h.qlen[1]], reply.key_mic));
    h.qbuf[0][off_mic] ^= 1;
    assert(h.sta.handle_eapol(h.qbuf[0][0 .. h.qlen[0]]));
    assert(h.qtail == 2);
    h.qhead = h.qtail = 0;
    h.sta.hooks.deferred_group_install = true;
    ubyte[256] group;
    size_t length = h.group_frame(group, 4, 0xAA);
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.sta.group_install_pending && h.group_installs == 2 && h.qtail == 0);
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.group_installs == 2 && h.qtail == 0);
    h.sta.group_key_installed(true);
    assert(h.qtail == 1 && !h.sta.group_install_pending);
    assert(decode_eapol_key(h.qbuf[0][0 .. h.qlen[0]], reply));
    assert(!reply.pairwise && reply.key_mic_set && reply.secure && reply.replay_counter[$ - 1] == 4);
    assert(eapol_key_verify_mic(h.ap.kck, h.qbuf[0][0 .. h.qlen[0]], reply.key_mic));
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.group_installs == 2 && h.qtail == 2);
    length = h.group_frame(group, 5, 0xAA);
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.group_installs == 2 && h.qtail == 3);
    length = h.group_frame(group, 4, 0xBB);
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.group_installs == 2 && h.qtail == 3);
    length = h.group_frame(group, 6, 0xBB);
    group[off_mic] ^= 1;
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.group_installs == 2 && h.qtail == 3 && h.sta.state == FourwayState.completed);
    group[off_mic] ^= 1;
    assert(h.sta.handle_eapol(group[0 .. length]));
    assert(h.group_installs == 3 && h.qtail == 3);
    h.sta.group_key_installed(false);
    assert(h.sta.state == FourwayState.failed && !h.sta.group_install_pending && h.qtail == 3);
}
