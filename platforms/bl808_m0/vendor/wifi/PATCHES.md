# BL808 M0 WiFi Vendor Patches

This directory is based on `sipeed/M1s_BL808_SDK`
`bf7e689cf49d57dd529e2492e5264ef602ed5b3c`.

Keep this file in sync when changing files under `include/` or `src/`.

## Header / build fixes

- `include/lmac_msg.h`: removed the unused `wifi_mgmr_ext.h` include.
- `include/bl_rx.h`: removed the unused `wifi_mgmr_ext.h` include.
- `include/lmac_msg.h`: split `cfg_start_req_u_tlv_t` into a tagged
  struct type and `extern` declaration. The definition lives in
  `src/bl_globals.c`; the upstream flexible-array variable definition relied
  on old `-fcommon` behaviour.
- `src/ipc_host.c`: fixed `ipc_emb2app_status_get()` and
  `ipc_emb2app_rawstatus_get()` calls to match the no-argument declarations.

## Runtime fixes

- `src/ipc_host.c`: removed high-volume TX descriptor debug prints.
- `src/bl_msg_tx.c`: STA connect requests set `WPA_WPA2_IN_USE` and
  `CONTROL_PORT_NO_ENC` when a PSK/PMK is supplied, so EAPOL can complete
  before data encryption is enabled.
- `src/bl_msg_tx.c`: invalid/out-of-range auth type falls back to open-system
  authentication.
- `src/bl_msg_tx.c`: AP start requests use 11b basic rates only, set
  `DISABLE_HT`, mark WPA/WPA2 when a password is present, and size the rate
  set from the actual local rate array.
- `src/bl_mod_params.c`: `ht_on=false` keeps the firmware in legacy 11bg mode.
  The BL808 AP path emitted malformed HT Operation IEs with HT enabled.
- `src/bl_shim.c`: `bl_shim_sta_connect()` accepts PMK and frequency hints and
  forwards them through `cfg80211_connect_params`.
