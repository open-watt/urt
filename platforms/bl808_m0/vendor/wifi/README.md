# BL808 M0 WiFi vendor material

Closed binaries and the minimum vendor C needed to drive them. The OpenWatt
M0 image links these in; all sequencing, lifetime management, and event
dispatch lives in `urt.driver.bl808.wifi`.

## Provenance

Extracted from [sipeed/M1s_BL808_SDK](https://github.com/sipeed/M1s_BL808_SDK)
at commit `bf7e689cf49d57dd529e2492e5264ef602ed5b3c` (2023-02-18).

The SDK is a Sipeed fork of Bouffalo's `bl_iot_sdk`, frozen at this commit.
We re-fetch only when chasing a specific upstream change.

## Layout

```
lib/                              -- closed binary archives (verbatim)
  libwifi.a                       (5.6 MB) -- WiFi MAC / LMAC / scan / AP / STA
  libbl606p_phyrf.a               (1.5 MB) -- PHY/RF driver, RF calibration

include/                          -- API contract with the blobs
  lmac_msg.h, lmac_mac.h          -- LMAC<->host message format
  lmac_types.h
  ipc_shared.h, ipc_compat.h      -- shared-memory descriptor layout
  reg_ipc_app.h, reg_access.h
  bl_defs.h                       -- struct bl_hw central state
  bl_cmds.h, bl_irqs.h, bl_msg_tx.h, bl_utils.h, bl_rx.h
  bl_mod_params.h, bl_strs.h
  bl60x_fw_api.h, bl_phy_api.h, rd.h
  ipc_host.h
  cfg80211.h, ieee80211.h, nl80211.h, errno.h  -- Linux-style helper headers
  list.h, utils_list.h, utils_tlv_bl.h
  bl_os_adapter/                  -- g_bl_ops_funcs struct + opaque handles
    bl_os_adapter.h, bl_os_log.h, bl_os_private.h
    bl_os_system.h, bl_os_type.h
  lwip/pbuf.h                     -- LOCAL stub, see below

src/                              -- vendor C we keep and compile
  ipc_host.c        (12 KB)       -- shared-memory ring management
  bl_cmds.c         (9 KB)        -- command/reply correlation
  bl_irqs.c         (2 KB)        -- IRQ bottom-half
  bl_msg_tx.c       (38 KB)       -- RPC stubs (alloc msg, fill fields, send)
  utils_list.c      (10 KB)       -- linked-list implementation
```

## What we do NOT pull in

Dropped from the SDK entirely (and re-implemented in D where needed):

- `wifi_mgmr*.c` (~5 KLoC) -- state machine, CLI, profile loading. The
  `BuiltinWiFi`/`BuiltinWlan`/`BuiltinAp` BaseObject classes replace this.
- `bl_main.c` -- init sequencing. Handled by `urt.driver.bl808.wifi`.
- `bl_rx.c` -- event dispatch + callback registration. D switch instead.
- `bl_tx.c` -- TX path. Was lwIP-pbuf entangled; rewritten in D.
- `bl_utils.c` -- mostly RX-path helpers; the three functions we need
  (`bl_ipc_init`, `bl_utils_pbuf_alloc`, `bl_utils_pbuf_free`,
  `bl_utils_idx_lookup`) are provided by D as `extern(C)`.
- `wifi_netif.c`, `wifi_pkt_hooks.c` -- lwIP shims.
- `stateMachine*.c` -- generic FSM library.
- `wifi_hosal/` -- HAL glue we replace with D.
- AOS yloop, FreeRTOS, lwIP, wpa_supplicant -- entirely.

## OS dependency

`libwifi.a` does NOT reference any FreeRTOS symbol directly. All OS
primitives are funnelled through a single function-pointer table
`g_bl_ops_funcs` (defined in `bl_os_adapter/bl_os_adapter.h`). We supply
that table from D backed by urt -- no FreeRTOS in the build.

## Patches applied to upstream

Tracked in `PATCHES.md`.

## The lwIP shim

`include/lwip/pbuf.h` is OURS, not from the SDK. It provides a minimal
layout-compatible `struct pbuf` so `ipc_host.c` compiles without dragging
in lwIP. The D side allocates packet wrappers whose first fields match
this layout.

## Resync procedure

To pull a newer snapshot from upstream:

1. Clone `sipeed/M1s_BL808_SDK` (or `bouffalolab/bl_iot_sdk` for newer
   LMAC versions -- different protocol, expect breakage) into
   `third_party/bouffalo_wifi/` (gitignored).
2. Diff `components/network/wifi_manager/bl60x_wifi_driver/` and
   `components/network/wifi/` against this directory.
3. Re-apply the patches listed above.
4. Rebuild and smoke-test STA association before merging.
