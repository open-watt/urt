#include "include.h"
#include "rw_pub.h"
#include "rw_msg_rx.h"
#include "ke_msg.h"
#include "mm_task.h"
#include "me_task.h"
#include "sm_task.h"
#include "scanu_task.h"
#include "scanu.h"
#include "mac_frame.h"
#include "mac_common.h"
#include "mem_pub.h"
#include "str_pub.h"
#include "sa_station.h"
#include "rw_ieee80211.h"

enum
{
    OW_RW_OTHER = 0,
    OW_RW_ADD_IF_CFM,
    OW_RW_SCANU_START_CFM,
    OW_RW_CONNECT_CFM,
    OW_RW_CONNECT_IND,
    OW_RW_DISCONNECT_IND,
    OW_RW_KEY_ADD_CFM,
    OW_RW_CONTROL_PORT_CFM,
};

extern void ke_msg_send(void const *param_ptr);
int __wrap_bmsg_ioctl_sender(void *arg)
{
    ke_msg_send(arg);
    return 0;
}

int ow_rw_mac_init(void)
{
    if (rwm_mgmt_is_vif_first_used() != NULL)
        return 0;
    if (rw_msg_send_reset())
        return -1;
    if (rw_msg_send_me_config_req())
        return -1;
    if (rw_msg_send_me_chan_config_req())
        return -1;
    return rw_msg_send_start();
}

int ow_rw_add_if(const uint8_t mac[6], int ap)
{
    return rw_msg_send_add_if(mac, ap ? NL80211_IFTYPE_AP : NL80211_IFTYPE_STATION, 0, NULL);
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
    os_memcpy(p.ssids[0].array, ssid, ssid_len);
    os_memset(&p.bssid, 0xff, sizeof(p.bssid));
    return rw_msg_send_scanu_req(&p);
}

int ow_rw_connect(uint8_t vif_idx, const uint8_t *ssid, uint8_t ssid_len, const uint8_t *bssid,
                  const uint8_t *ie, uint16_t ie_len, int psk, uint8_t *channel)
{
    CONNECT_PARAM_T c;
    struct mac_scan_result *bss;
    os_memset(&c, 0, sizeof(c));

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

    *channel = (uint8_t)rw_ieee80211_get_chan_id(c.chan.freq);
    return rw_msg_send_sm_connect_req(&c, NULL);
}

int ow_rw_disconnect(uint8_t vif_idx, uint16_t reason)
{
    struct sm_disconnect_req *req = ke_msg_alloc(SM_DISCONNECT_REQ, TASK_SM, TASK_API,
                                                  sizeof(struct sm_disconnect_req));
    if (!req)
        return -1;
    req->reason_code = reason;
    req->vif_idx = vif_idx;
    return rw_msg_send(req, SM_DISCONNECT_CFM, NULL);
}

int ow_rw_key_add_ccmp(uint8_t vif_idx, uint8_t sta_idx, uint8_t key_idx, const uint8_t *key, uint8_t len)
{
    KEY_PARAM_T k;
    os_memset(&k, 0, sizeof(k));
    if (len > sizeof(k.key.array))
        return -1;
    k.cipher_suite = MAC_RSNIE_CIPHER_CCMP;
    k.sta_idx = sta_idx;
    k.inst_nbr = vif_idx;
    k.key_idx = key_idx;
    k.key.length = len;
    os_memcpy(k.key.array, key, len);
    return rw_msg_send_key_add(&k, NULL);
}

int ow_rw_control_port(uint8_t sta_idx, int open)
{
    return rw_msg_me_set_control_port_req(open ? 1 : 0, sta_idx);
}

int ow_rw_classify(const struct ke_msg *m)
{
    switch (m->id)
    {
    case MM_ADD_IF_CFM:     return OW_RW_ADD_IF_CFM;
    case SCANU_START_CFM:   return OW_RW_SCANU_START_CFM;
    case SM_CONNECT_CFM:    return OW_RW_CONNECT_CFM;
    case SM_CONNECT_IND:    return OW_RW_CONNECT_IND;
    case SM_DISCONNECT_IND: return OW_RW_DISCONNECT_IND;
    case MM_KEY_ADD_CFM:    return OW_RW_KEY_ADD_CFM;
    case ME_SET_CONTROL_PORT_CFM: return OW_RW_CONTROL_PORT_CFM;
    default:                return OW_RW_OTHER;
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

void ow_rw_connect_ind(const struct ke_msg *m, uint16_t *status, uint8_t *vif_idx, uint8_t *ap_idx,
                       uint8_t bssid[6], uint16_t *aid)
{
    const struct sm_connect_indication *c = (const struct sm_connect_indication *)m->param;
    *status = c->status_code;
    *vif_idx = c->vif_idx;
    *ap_idx = c->ap_idx;
    os_memcpy(bssid, &c->bssid, 6);
    *aid = c->aid;
}

void ow_rw_disconnect_ind(const struct ke_msg *m, uint8_t *vif_idx, uint16_t *reason)
{
    const struct sm_disconnect_ind *c = (const struct sm_disconnect_ind *)m->param;
    *vif_idx = c->vif_idx;
    *reason = c->reason_code;
}

void ow_rw_key_add_cfm(const struct ke_msg *m, uint8_t *status, uint8_t *hw_key_idx)
{
    const struct mm_key_add_cfm *c = (const struct mm_key_add_cfm *)m->param;
    *status = c->status;
    *hw_key_idx = c->hw_key_idx;
}

uint16_t ow_rw_msg_id(const struct ke_msg *m)
{
    return m->id;
}
