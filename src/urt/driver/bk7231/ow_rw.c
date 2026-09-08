#include "include.h"
#include "rw_pub.h"
#include "rw_msdu.h"
#include "rw_msg_rx.h"
#include "ke_msg.h"
#include "mm_task.h"
#include "me_task.h"
#include "sm_task.h"
#include "scanu_task.h"
#include "scan_task.h"
#include "scanu.h"
#include "txu_cntrl.h"
#include "mac_frame.h"
#include "mac_common.h"
#include "mem_pub.h"
#include "str_pub.h"
#include "sa_station.h"
#include "rw_ieee80211.h"
#include "sta_mgmt.h"
#include "vif_mgmt.h"
#include "sm.h"
#include "ke_event.h"
#include "ke_task.h"
#include "hal_machw.h"
#include "phy.h"
#include "txl_cntrl.h"
#include "rxl_cntrl.h"
#include "mm.h"
#include <stddef.h>

_Static_assert(sizeof(struct key_info_tag) == 104, "librwnx key ABI");
_Static_assert(sizeof(struct sta_info_tag) == 440 && offsetof(struct sta_info_tag, sta_sec_info) == 40, "librwnx STA key ABI");
_Static_assert(sizeof(struct vif_info_tag) == 840 && offsetof(struct vif_info_tag, key_info) == 392, "librwnx VIF key ABI");

enum
{
    OW_RW_OTHER = 0,
    OW_RW_ADD_IF_CFM,
    OW_RW_SCANU_START_CFM,
    OW_RW_BEACON_LOSE_IND,
    OW_RW_AUTH_FAIL_IND,
    OW_RW_ASSOC_FAIL_IND,
    OW_RW_DISASSOC_IND,
    OW_RW_CONNECT_CFM,
    OW_RW_CONNECT_IND,
    OW_RW_DISCONNECT_IND,
    OW_RW_KEY_ADD_CFM,
    OW_RW_CONTROL_PORT_CFM,
    OW_RW_RESET_CFM,
    OW_RW_CONFIG_CFM,
    OW_RW_CHANNEL_CONFIG_CFM,
    OW_RW_START_CFM,
};

extern bool __real_txu_cntrl_push(struct txdesc *txdesc, uint8_t access_category);
extern uint32_t __real_rwm_upload_data(RW_RXIFO_PTR rx_info);
extern void ke_msg_send(void const *param_ptr);
extern struct co_list rw_msg_rx_head;
extern void rwnx_handle_recv_msg(struct ke_msg *msg);
extern void ow_wifi_message(struct ke_msg *msg);
extern void rwm_flush_rx_list(void);
extern void __real_sta_mgmt_add_key(const struct mm_key_add_req *req, uint8_t hw_key_idx);
extern void __real_vif_mgmt_add_key(const struct mm_key_add_req *req, uint8_t hw_key_idx);

struct OwKeyRequest
{
    struct mm_key_add_req key;
    struct
    {
        uint32_t low;
        uint16_t high;
    } rsc;
};

_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "librwnx replay counter byte order");
_Static_assert(sizeof(struct OwKeyRequest) == 52 && offsetof(struct OwKeyRequest, rsc) == 44, "key request ABI");
_Static_assert(offsetof(struct ke_msg, param) % _Alignof(struct OwKeyRequest) == 0, "key request alignment");
_Static_assert(_Alignof(struct ke_msg) >= _Alignof(struct OwKeyRequest), "message allocation alignment");

static void install_rsc(const struct mm_key_add_req *req, struct key_info_tag *key)
{
    if (ke_param2msg(req)->param_len != sizeof(struct OwKeyRequest))
        return;
    const struct OwKeyRequest *request = (const struct OwKeyRequest *)req;
    uint64_t pn = request->rsc.low | ((uint64_t)request->rsc.high << 32);
    for (unsigned tid = 0; tid < TID_MAX; ++tid)
        key->rx_pn[tid] = pn;
}

void __wrap_sta_mgmt_add_key(const struct mm_key_add_req *req, uint8_t hw_key_idx)
{
    GLOBAL_INT_DECLARATION();
    GLOBAL_INT_DISABLE();
    __real_sta_mgmt_add_key(req, hw_key_idx);
    install_rsc(req, &sta_info_tab[req->sta_idx].sta_sec_info.key_info);
    GLOBAL_INT_RESTORE();
}

void __wrap_vif_mgmt_add_key(const struct mm_key_add_req *req, uint8_t hw_key_idx)
{
    GLOBAL_INT_DECLARATION();
    GLOBAL_INT_DISABLE();
    __real_vif_mgmt_add_key(req, hw_key_idx);
    install_rsc(req, &vif_info_tab[req->inst_nbr].key_info[req->key_idx]);
    GLOBAL_INT_RESTORE();
}

static bool tx_tracking;
static bool tx_admitted;
static int8_t rx_rssi;

int ow_rw_receive(void)
{
    GLOBAL_INT_DECLARATION();
    GLOBAL_INT_DISABLE();
    struct ke_msg *msg = (struct ke_msg *)co_list_pop_front(&rw_msg_rx_head);
    GLOBAL_INT_RESTORE();
    if (!msg)
        return 0;

    rwnx_handle_recv_msg(msg);
    ow_wifi_message(msg);
    ke_msg_free(msg);
    return 1;
}

bool __wrap_txu_cntrl_push(struct txdesc *txdesc, uint8_t access_category)
{
    bool admitted = __real_txu_cntrl_push(txdesc, access_category);
    if (tx_tracking)
        tx_admitted = admitted;
    return admitted;
}

uint32_t __wrap_rwm_upload_data(RW_RXIFO_PTR rx_info)
{
    rx_rssi = rx_info->rssi;
    return __real_rwm_upload_data(rx_info);
}

int __wrap_bmsg_ioctl_sender(void *arg)
{
    ke_msg_send(arg);
    return 0;
}

static void discard_messages(struct co_list *list)
{
    struct ke_msg *msg;
    while ((msg = (struct ke_msg *)co_list_pop_front(list)) != NULL)
        ke_msg_free(msg);
}

void ow_rw_mac_quiesce(void)
{
    GLOBAL_INT_DECLARATION();
    GLOBAL_INT_DISABLE();
    hal_machw_stop();
    phy_stop();
    // Suppress management-frame retries while TX reset retires their callbacks.
    ke_state_set(TASK_SM, SM_IDLE);
    txl_reset();
    rxl_reset();
    if (sm_env.connect_param)
    {
        ke_msg_free(ke_param2msg(sm_env.connect_param));
        sm_env.connect_param = NULL;
    }
    if (sm_env.connect_ind)
    {
        ke_msg_free(ke_param2msg(sm_env.connect_ind));
        sm_env.connect_ind = NULL;
    }
    discard_messages(&sm_env.bss_config);
    scanu_init();
    sr_release_scan_results(sr_get_scan_results());
    rwm_flush_rx_list();
    ke_flush();
    discard_messages(&rw_msg_rx_head);
    GLOBAL_INT_RESTORE();
}

int ow_rw_mac_step(unsigned step)
{
    switch (step)
    {
    case 0: return rw_msg_send_reset();
    case 1: return rw_msg_send_me_config_req();
    case 2: return rw_msg_send_me_chan_config_req();
    case 3: return rw_msg_send_start();
    default: return -1;
    }
}

int ow_rw_add_if(const uint8_t mac[6])
{
    return rw_msg_send_add_if(mac, NL80211_IFTYPE_STATION, 0, NULL);
}

int ow_rw_scan(uint8_t vif_idx, const uint8_t *ssid, uint8_t ssid_len)
{
    SCAN_PARAM_T p;
    os_memset(&p, 0, sizeof(p));
    p.vif_idx = vif_idx;
    p.num_ssids = 1;
    if (ssid_len > sizeof(p.ssids[0].array))
        ssid_len = sizeof(p.ssids[0].array);
    p.ssids[0].length = ssid_len;
    if (ssid_len)
        os_memcpy(p.ssids[0].array, ssid, ssid_len);
    os_memset(&p.bssid, 0xff, sizeof(p.bssid));
    return rw_msg_send_scanu_req(&p);
}

int ow_rw_transfer(uint8_t vif_idx, uint8_t *buf, uint32_t len)
{
    tx_admitted = false;
    tx_tracking = true;
    rwm_transfer(vif_idx, buf, len, 0, NULL);
    tx_tracking = false;
    return tx_admitted ? 0 : -1;
}

int8_t ow_rw_get_rssi(void)
{
    return rx_rssi;
}

int ow_rw_connect(uint8_t vif_idx, const uint8_t *ssid, uint8_t ssid_len, const uint8_t *bssid, const uint8_t *ie, uint16_t ie_len, int psk, int8_t *rssi, uint8_t *channel)
{
    CONNECT_PARAM_T c;
    struct mac_scan_result *bss;
    os_memset(&c, 0, sizeof(c));

    if (ssid_len > sizeof(c.ssid.array))
        return -1;

    c.vif_idx = vif_idx;
    c.ssid.length = ssid_len;
    os_memcpy(c.ssid.array, ssid, ssid_len);

    if (bssid)
    {
        os_memcpy(&c.bssid, bssid, sizeof(c.bssid));
        bss = scanu_search_by_bssid(&c.bssid);
    }
    else
        bss = scanu_search_by_ssid(&c.ssid);
    if (!bss || !bss->chan)
        return -2;
    if (!bssid)
        c.bssid = bss->bssid;

    c.chan = *bss->chan;
    if (c.chan.tx_power == 0)
        c.chan.tx_power = 10;
    c.flags = CONTROL_PORT_HOST | (psk ? WPA_WPA2_IN_USE : 0);
    c.auth_type = MAC_AUTH_ALGO_OPEN;
    if (ie_len > sizeof(c.ie_buf))
        return -1;
    c.ie_len = ie_len;
    if (ie_len)
        os_memcpy(c.ie_buf, ie, ie_len);

    *rssi = bss->rssi;
    *channel = (uint8_t)rw_ieee80211_get_chan_id(c.chan.freq);
    return rw_msg_send_sm_connect_req(&c, NULL);
}

int ow_rw_disconnect(uint8_t vif_idx, uint16_t reason)
{
    struct sm_disconnect_req *req = ke_msg_alloc(SM_DISCONNECT_REQ, TASK_SM, TASK_API, sizeof(struct sm_disconnect_req));
    if (!req)
        return -1;
    req->reason_code = reason;
    req->vif_idx = vif_idx;
    return rw_msg_send(req, SM_DISCONNECT_CFM, NULL);
}

int ow_rw_key_add_ccmp(uint8_t vif_idx, uint8_t sta_idx, uint8_t key_idx, const uint8_t *key, uint8_t len, const uint8_t rsc[6])
{
    if (!key || !rsc || len != 16 || vif_idx >= NX_VIRT_DEV_MAX || (sta_idx != 0xff && sta_idx >= STA_MAX) || key_idx >= MAC_DEFAULT_KEY_COUNT)
        return -1;
    struct OwKeyRequest *req = ke_msg_alloc(MM_KEY_ADD_REQ, TASK_MM, TASK_API, sizeof(struct OwKeyRequest));
    if (!req)
        return -1;
    os_memset(req, 0, sizeof(*req));
    req->key.cipher_suite = MAC_RSNIE_CIPHER_CCMP;
    req->key.sta_idx = sta_idx;
    req->key.inst_nbr = vif_idx;
    req->key.key_idx = key_idx;
    req->key.key.length = len;
    os_memcpy(req->key.key.array, key, len);
    os_memcpy(&req->rsc, rsc, 6);
    ke_msg_send(req);
    return 0;
}

void ow_rw_monitor_start(uint8_t channel)
{
    uint16_t frequency = channel == 14 ? 2484 : 2407 + 5 * channel;
    phy_set_channel(PHY_BAND_2G4, PHY_CHNL_BW_20, frequency, frequency, 0, PHY_PRIM);
    hal_machw_enter_monitor_mode();
    mm_active();
}

int ow_rw_control_port(uint8_t sta_idx, int open)
{
    return rw_msg_me_set_control_port_req(open ? 1 : 0, sta_idx);
}

int ow_rw_classify(const struct ke_msg *m)
{
    switch (m->id)
    {
    case MM_ADD_IF_CFM:
        return OW_RW_ADD_IF_CFM;
    case SCANU_START_CFM:
        return OW_RW_SCANU_START_CFM;
    case SM_BEACON_LOSE_IND:
        return OW_RW_BEACON_LOSE_IND;
    case SM_AUTHEN_FAIL_IND:
        return OW_RW_AUTH_FAIL_IND;
    case SM_ASSOC_FAIL_INID:
        return OW_RW_ASSOC_FAIL_IND;
    case SM_DISASSOC_IND:
        return OW_RW_DISASSOC_IND;
    case SM_CONNECT_CFM:
        return OW_RW_CONNECT_CFM;
    case SM_CONNECT_IND:
        return OW_RW_CONNECT_IND;
    case SM_DISCONNECT_IND:
        return OW_RW_DISCONNECT_IND;
    case MM_KEY_ADD_CFM:
        return OW_RW_KEY_ADD_CFM;
    case ME_SET_CONTROL_PORT_CFM:
        return OW_RW_CONTROL_PORT_CFM;
    case MM_RESET_CFM:
        return OW_RW_RESET_CFM;
    case ME_CONFIG_CFM:
        return OW_RW_CONFIG_CFM;
    case ME_CHAN_CONFIG_CFM:
        return OW_RW_CHANNEL_CONFIG_CFM;
    case MM_START_CFM:
        return OW_RW_START_CFM;
    default:
        return OW_RW_OTHER;
    }
}

void ow_rw_add_if_cfm(const struct ke_msg *m, uint8_t *status, uint8_t *vif_idx)
{
    const struct mm_add_if_cfm *c = (const struct mm_add_if_cfm *)m->param;
    *status = c->status;
    *vif_idx = c->inst_nbr;
}

void ow_rw_scanu_start_cfm(const struct ke_msg *m, uint8_t *status, uint8_t *vif_idx)
{
    const struct scanu_start_cfm *c = (const struct scanu_start_cfm *)m->param;
    *status = c->status;
    *vif_idx = c->vif_idx;
}

void ow_rw_connect_cfm(const struct ke_msg *m, uint8_t *status)
{
    const struct sm_connect_cfm *c = (const struct sm_connect_cfm *)m->param;
    *status = c->status;
}

void ow_rw_connect_ind(const struct ke_msg *m, uint16_t *status, uint8_t *vif_idx, uint8_t *ap_idx, uint8_t bssid[6])
{
    const struct sm_connect_indication *c = (const struct sm_connect_indication *)m->param;
    *status = c->status_code;
    *vif_idx = c->vif_idx;
    *ap_idx = c->ap_idx;
    os_memcpy(bssid, &c->bssid, 6);
}

void ow_rw_disconnect_ind(const struct ke_msg *m, uint8_t *vif_idx, uint16_t *reason)
{
    const struct sm_disconnect_ind *c = (const struct sm_disconnect_ind *)m->param;
    *vif_idx = c->vif_idx;
    *reason = c->reason_code;
}

void ow_rw_fail_ind(const struct ke_msg *m, uint16_t *status)
{
    const struct sm_fail_stat *c = (const struct sm_fail_stat *)m->param;
    *status = c->status;
}

void ow_rw_key_add_cfm(const struct ke_msg *m, uint8_t *status)
{
    const struct mm_key_add_cfm *c = (const struct mm_key_add_cfm *)m->param;
    *status = c->status;
}
