// Thin C-side wrappers around vendor calls whose request types pull in
// nested header material it would be tedious to mirror in D. Strictly
// struct-construction + a single bl_send_* call -- no policy.
//
// Roughly the role wifi_mgmr served in the upstream SDK, pared down to
// what OpenWatt's D driver actually needs.

#include "bl_msg_tx.h"
#include "cfg80211.h"
#include "nl80211.h"
#include "bl_defs.h"
#include "ipc_host.h"
#include "bl_cmds.h"
#include "bl_os_private.h"

// IPC callbacks live in D (urt.driver.bl808.wifi) with C linkage so the
// vendor cb table can point at them directly.
extern uint8_t  bl_radarind(void *pthis, void *hostid);
extern uint8_t  bl_msgackind(void *pthis, void *hostid);
extern uint8_t  bl_dbgind(void *pthis, void *hostid);
extern int      bl_txdatacfm(void *pthis, void *host_id);
extern void     bl_prim_tbtt_ind(void *pthis);
extern void     bl_sec_tbtt_ind(void *pthis);

// Ported from vendor's bl_utils.c. Allocates the host-side IPC env via
// the OS adapter (-> D's urt heap), wires the cb table, hands both to
// ipc_host_init, then initialises the command manager.
int bl_shim_ipc_init(struct bl_hw *bl_hw, struct ipc_shared_env_tag *shared_mem)
{
    struct ipc_host_cb_tag cb = {
        .send_data_cfm   = bl_txdatacfm,
        .recv_data_ind   = NULL,
        .recv_radar_ind  = bl_radarind,
        .recv_msg_ind    = NULL,           // vendor pattern: events arrive via bl_rx_e2a_handler
        .recv_msgack_ind = bl_msgackind,
        .recv_dbg_ind    = bl_dbgind,
        .prim_tbtt_ind   = bl_prim_tbtt_ind,
        .sec_tbtt_ind    = bl_sec_tbtt_ind,
    };

    bl_hw->ipc_env = bl_os_malloc(sizeof(struct ipc_host_env_tag));
    if (!bl_hw->ipc_env)
        return -1;

    ipc_host_init(bl_hw->ipc_env, &cb, shared_mem, bl_hw);
    bl_cmd_mgr_init(&bl_hw->cmd_mgr);
    return 0;
}

int bl_shim_sta_connect(struct bl_hw *bl_hw,
                        const uint8_t *ssid, uint32_t ssid_len,
                        const uint8_t *bssid_or_null,
                        const char *psk, uint8_t psk_len,
                        const uint8_t *pmk, uint8_t pmk_len,
                        int auth_type,
                        uint16_t freq)
{
    struct sm_connect_cfm cfm = {0};
    struct cfg80211_connect_params sme = {0};

    sme.ssid     = ssid;
    sme.ssid_len = ssid_len;
    if (bssid_or_null)
        sme.bssid = bssid_or_null;
    sme.auth_type = auth_type;
    if (psk_len) {
        sme.key     = (const uint8_t *)psk;
        sme.key_len = psk_len;
    }
    if (pmk_len) {
        sme.pmk     = pmk;
        sme.pmk_len = pmk_len;
    }
    if (freq) {
        sme.channel.center_freq = freq;
        sme.channel.band = 0;   // 2.4 GHz
        sme.channel.flags = 0;
    }

    int r = bl_send_sm_connect_req(bl_hw, &sme, &cfm);
    if (r)
        return -1;
    return cfm.status;
}
