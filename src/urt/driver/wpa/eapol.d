// WPA/WPA2 EAPOL-Key frame codec.
//
// Wire format (802.1X EAPOL + IEEE 802.11i Key Descriptor v2):
//   4-byte IEEE 802.1X header:
//     ver (1), type (1), body_length (2 BE)
//     [type 3 = EAPOL-Key; ver 1 = 2001, ver 2 = 2004 (used today)]
//   95-byte fixed key-descriptor body:
//     descriptor_type (1)            -- 2 = RSN (WPA2)
//     key_info (2 BE)                -- version | flags | key index
//     key_length (2 BE)              -- 16 for CCMP pairwise; 0 for group msg
//     replay_counter (8 BE)          -- echo back AP's value
//     key_nonce (32)                 -- ANonce on msg 1, SNonce on msg 2
//     key_iv (16)                    -- zero in v2 (AES-CMAC/HMAC-SHA1)
//     key_rsc (8)                    -- group key seq, BE
//     key_id (8, reserved)           -- zero
//     key_mic (16)                   -- HMAC-SHA1(KCK, frame_with_zero_mic)
//     key_data_length (2 BE)
//   N-byte key_data:
//     msg 2: STA's RSN IE
//     msg 3: GTK KDE + group RSC + IGTK KDE if PMF, AES-key-wrapped with KEK
module urt.driver.wpa.eapol;

public import urt.driver.dot1x.eapol;

import urt.digest.hmac : HMACContext, hmac_init, hmac_update, hmac_finalise;
import urt.digest.sha : SHA1Context;

nothrow @nogc:


private ushort be_u16(const(ubyte)* p) pure
{
    return cast(ushort)((cast(ushort)p[0] << 8) | p[1]);
}


enum ubyte key_desc_type_rc4_hmac_md5 = 1; // WPA (no longer issued)
enum ubyte key_desc_type_rsn          = 2; // WPA2 / RSN

// key_info bitfield (host order):
enum ushort key_info_ver_hmac_md5_rc4   = 0x0001;
enum ushort key_info_ver_hmac_sha1_aes  = 0x0002;
enum ushort key_info_ver_aes_cmac       = 0x0003;
enum ushort key_info_ver_mask           = 0x0007;
enum ushort key_info_type_pairwise      = 0x0008;
enum ushort key_info_keyidx_shift       = 4;
enum ushort key_info_keyidx_mask        = 0x0030;
enum ushort key_info_install            = 0x0040;
enum ushort key_info_key_ack            = 0x0080;
enum ushort key_info_key_mic            = 0x0100;
enum ushort key_info_secure             = 0x0200;
enum ushort key_info_error              = 0x0400;
enum ushort key_info_request            = 0x0800;
enum ushort key_info_encr_key_data      = 0x1000;
enum ushort key_info_smk_message        = 0x2000;

enum size_t key_desc_fixed_len     = 95;  // descriptor body without key_data
enum size_t eapol_key_fixed_len    = eapol_hdr_len + key_desc_fixed_len; // 99
enum size_t eapol_key_nonce_len    = 32;
enum size_t eapol_key_mic_len      = 16;
enum size_t eapol_key_replay_len   = 8;
enum size_t eapol_key_rsc_len      = 8;
enum size_t eapol_key_iv_len       = 16;
enum size_t eapol_key_max_len      = 256;  // scratch bound for MIC verify

// Offsets within an EAPOL-Key frame, measured from the start of the 802.1X
// header (so the byte that holds the version is at offset 0).
enum size_t off_version       = 0;
enum size_t off_type          = 1;
enum size_t off_body_len      = 2;  // BE u16
enum size_t off_desc_type     = 4;
enum size_t off_key_info      = 5;  // BE u16
enum size_t off_key_length    = 7;  // BE u16
enum size_t off_replay        = 9;
enum size_t off_nonce         = 17;
enum size_t off_iv            = 49;
enum size_t off_rsc           = 65;
enum size_t off_key_id        = 73;
enum size_t off_mic           = 81;
enum size_t off_key_data_len  = 97;  // BE u16
enum size_t off_key_data      = 99;


struct EapolKeyFrame
{
    ubyte version_;
    ubyte type;
    ushort body_length;     // bytes after the 4-byte 802.1X header
    ubyte descriptor_type;
    ushort key_info;
    ushort key_length;
    ubyte[eapol_key_replay_len] replay_counter;
    ubyte[eapol_key_nonce_len] key_nonce;
    ubyte[eapol_key_iv_len] key_iv;
    ubyte[eapol_key_rsc_len] key_rsc;
    ubyte[8] key_id;
    ubyte[eapol_key_mic_len] key_mic;
    ushort key_data_length;
    const(ubyte)[] key_data;    // borrowed slice into the source frame

nothrow @nogc:
    @property ushort version_bits() const => cast(ushort)(key_info & key_info_ver_mask);
    @property bool   pairwise()      const => (key_info & key_info_type_pairwise) != 0;
    @property ubyte  key_index()     const => cast(ubyte)((key_info & key_info_keyidx_mask) >> key_info_keyidx_shift);
    @property bool   install()       const => (key_info & key_info_install) != 0;
    @property bool   key_ack()       const => (key_info & key_info_key_ack) != 0;
    @property bool   key_mic_set()   const => (key_info & key_info_key_mic) != 0;
    @property bool   secure()        const => (key_info & key_info_secure) != 0;
    @property bool   error()         const => (key_info & key_info_error) != 0;
    @property bool   request()       const => (key_info & key_info_request) != 0;
    @property bool   encr_key_data() const => (key_info & key_info_encr_key_data) != 0;
}


// Parse an EAPOL-Key frame from the wire. `frame` is the full 802.1X payload
// (starting at the version byte; the ethernet header has already been
// consumed by the driver). Returns false on malformed input.
bool decode_eapol_key(const(ubyte)[] frame, ref EapolKeyFrame out_)
{
    if (frame.length < eapol_key_fixed_len)
        return false;

    if (frame[off_type] != eapol_type_key)
        return false;

    ushort body_len = be_u16(frame.ptr +off_body_len);
    // body_len counts the bytes after the 802.1X header (descriptor + data).
    if (cast(size_t)body_len + eapol_hdr_len > frame.length)
        return false;

    out_.version_        = frame[off_version];
    out_.type            = frame[off_type];
    out_.body_length     = body_len;
    out_.descriptor_type = frame[off_desc_type];
    out_.key_info        = be_u16(frame.ptr +off_key_info);
    out_.key_length      = be_u16(frame.ptr +off_key_length);
    out_.replay_counter[] = frame[off_replay .. off_replay + eapol_key_replay_len];
    out_.key_nonce[]      = frame[off_nonce  .. off_nonce  + eapol_key_nonce_len];
    out_.key_iv[]         = frame[off_iv     .. off_iv     + eapol_key_iv_len];
    out_.key_rsc[]        = frame[off_rsc    .. off_rsc    + eapol_key_rsc_len];
    out_.key_id[]         = frame[off_key_id .. off_key_id + 8];
    out_.key_mic[]        = frame[off_mic    .. off_mic    + eapol_key_mic_len];

    ushort kd_len = be_u16(frame.ptr +off_key_data_len);
    out_.key_data_length = kd_len;
    if (off_key_data + cast(size_t)kd_len > frame.length)
        return false;
    out_.key_data = frame[off_key_data .. off_key_data + kd_len];

    return true;
}


// Build an EAPOL-Key frame into `dst`. Returns the number of bytes written,
// or 0 if the buffer is too small. MIC field is zero-filled; the caller is
// expected to compute the MIC over the written buffer and patch it in via
// the patch_mic() helper.
size_t encode_eapol_key(ubyte[] dst,
                        ubyte eapol_version,
                        ubyte descriptor_type,
                        ushort key_info,
                        ushort key_length,
                        const(ubyte)[eapol_key_replay_len] replay,
                        const(ubyte)[eapol_key_nonce_len] nonce,
                        const(ubyte)[eapol_key_rsc_len] rsc,
                        const(ubyte)[] key_data)
{
    size_t total = eapol_key_fixed_len + key_data.length;
    if (dst.length < total)
        return 0;

    dst[off_version] = eapol_version;
    dst[off_type]    = eapol_type_key;

    // body_length excludes the 4-byte 802.1X header.
    ushort body_len = cast(ushort)(key_desc_fixed_len + key_data.length);
    dst[off_body_len]     = cast(ubyte)(body_len >> 8);
    dst[off_body_len + 1] = cast(ubyte)(body_len & 0xff);

    dst[off_desc_type] = descriptor_type;
    dst[off_key_info]     = cast(ubyte)(key_info >> 8);
    dst[off_key_info + 1] = cast(ubyte)(key_info & 0xff);
    dst[off_key_length]     = cast(ubyte)(key_length >> 8);
    dst[off_key_length + 1] = cast(ubyte)(key_length & 0xff);

    dst[off_replay .. off_replay + eapol_key_replay_len] = replay[];
    dst[off_nonce  .. off_nonce  + eapol_key_nonce_len]  = nonce[];
    dst[off_iv     .. off_iv     + eapol_key_iv_len]     = 0;
    dst[off_rsc    .. off_rsc    + eapol_key_rsc_len]    = rsc[];
    dst[off_key_id .. off_key_id + 8] = 0;
    dst[off_mic    .. off_mic    + eapol_key_mic_len]    = 0;

    dst[off_key_data_len]     = cast(ubyte)(key_data.length >> 8);
    dst[off_key_data_len + 1] = cast(ubyte)(key_data.length & 0xff);

    if (key_data.length > 0)
        dst[off_key_data .. off_key_data + key_data.length] = key_data[];

    return total;
}


// Patch the MIC field into an already-encoded EAPOL-Key frame.
void patch_mic(ubyte[] frame, const(ubyte)[eapol_key_mic_len] mic)
{
    if (frame.length < off_mic + eapol_key_mic_len)
        return;
    frame[off_mic .. off_mic + eapol_key_mic_len] = mic[];
}


void eapol_key_compute_mic(const(ubyte)[] kck, const(ubyte)[] frame, ref ubyte[eapol_key_mic_len] out_mic)
{
    HMACContext!SHA1Context h;
    hmac_init(h, kck);
    hmac_update(h, frame);
    ubyte[SHA1Context.DigestLen] digest = hmac_finalise(h);
    out_mic[] = digest[0 .. eapol_key_mic_len];
}


bool eapol_key_verify_mic(const(ubyte)[] kck, const(ubyte)[] frame, const(ubyte)[eapol_key_mic_len] expected)
{
    if (frame.length < off_mic + eapol_key_mic_len || frame.length > eapol_key_max_len)
        return false;

    ubyte[eapol_key_max_len] scratch = void;
    scratch[0 .. frame.length] = frame[];
    scratch[off_mic .. off_mic + eapol_key_mic_len] = 0;

    ubyte[eapol_key_mic_len] computed;
    eapol_key_compute_mic(kck, scratch[0 .. frame.length], computed);

    ubyte diff = 0;
    foreach (i; 0 .. eapol_key_mic_len)
        diff |= computed[i] ^ expected[i];
    return diff == 0;
}


int eapol_key_replay_compare(const(ubyte)[eapol_key_replay_len] a, const(ubyte)[eapol_key_replay_len] b)
{
    foreach (i; 0 .. eapol_key_replay_len)
        if (int d = a[i] - b[i])
            return d;
    return 0;
}


bool parse_gtk_kde(const(ubyte)[] data, ubyte[] out_gtk, ref size_t out_len, ref ubyte out_key_id)
{
    size_t off = 0;
    while (off + 2 <= data.length)
    {
        ubyte id  = data[off];
        ubyte len = data[off + 1];
        if (off + 2 + len > data.length)
            return false;

        if (id == 0xDD && len >= 6)
        {
            // Vendor-specific IE: OUI(3) + KDE type(1) + payload
            if (data[off + 2] == 0x00 && data[off + 3] == 0x0F && data[off + 4] == 0xAC
                && data[off + 5] == 0x01)
            {
                // GTK KDE payload: key_id/tx/reserved(1), reserved(1), GTK(N).
                size_t body_off = off + 6;
                size_t body_end = off + 2 + len;
                if (body_end - body_off < 2)
                    return false;
                out_key_id = data[body_off] & 0x03;
                size_t gtk_len = body_end - body_off - 2;
                if (gtk_len > out_gtk.length)
                    return false;
                out_gtk[0 .. gtk_len] = data[body_off + 2 .. body_end];
                out_len = gtk_len;
                return true;
            }
        }

        off += 2 + len;
    }
    return false;
}


size_t encode_gtk_kde(ubyte[] dst, ubyte key_id, const(ubyte)[] gtk)
{
    size_t total = 8 + gtk.length;
    if (dst.length < total || gtk.length + 6 > 0xFF)
        return 0;
    dst[0] = 0xDD;
    dst[1] = cast(ubyte)(6 + gtk.length);
    dst[2] = 0x00; dst[3] = 0x0F; dst[4] = 0xAC; dst[5] = 0x01;
    dst[6] = key_id & 0x03;
    dst[7] = 0x00;
    dst[8 .. total] = gtk[];
    return total;
}
