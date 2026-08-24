module urt.driver.wpa;

public import urt.driver.wpa.authenticator;
public import urt.driver.wpa.eapol;
public import urt.driver.wpa.fourway;
public import urt.driver.wpa.supplicant;

// WPA2-PSK / CCMP RSN IE: byte-identical in the STA association request, the AP beacon tail and
// the 4-way MIC input, so every driver shares this one copy.
static immutable ubyte[22] wpa2_psk_ccmp_rsn_ie = [
    0x30, 0x14,
    0x01, 0x00,
    0x00, 0x0f, 0xac, 0x04,
    0x01, 0x00,
    0x00, 0x0f, 0xac, 0x04,
    0x01, 0x00,
    0x00, 0x0f, 0xac, 0x02,
    0x00, 0x00,
];
