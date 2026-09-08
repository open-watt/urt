#include <assert.h>
#include <stdlib.h>
#include "../src/urt/driver/bk7231/ow_rw.c"

// Host build: SDK include flags, -m32 -malign-double -DLWIP_NO_STDINT_H=1 -Wl,--gc-sections.

struct sta_info_tag sta_info_tab[STA_MAX];
struct vif_info_tag vif_info_tab[NX_VIRT_DEV_MAX];
static void *submitted;
static int fail_alloc;

void *ke_msg_alloc(ke_msg_id_t id, ke_task_id_t dest, ke_task_id_t src, uint16_t len)
{
    if (fail_alloc)
        return NULL;
    struct ke_msg *m = calloc(1, sizeof(*m) + len);
    assert(m);
    m->id = id;
    m->dest_id = dest;
    m->src_id = src;
    m->param_len = len;
    return m->param;
}

void ke_msg_send(const void *p)
{
    submitted = (void *)p;
}

void __real_sta_mgmt_add_key(const struct mm_key_add_req *r, uint8_t hw)
{
    memset(&sta_info_tab[r->sta_idx].sta_sec_info.key_info, 0, sizeof(struct key_info_tag));
}

void __real_vif_mgmt_add_key(const struct mm_key_add_req *r, uint8_t hw)
{
    memset(&vif_info_tab[r->inst_nbr].key_info[r->key_idx], 0, sizeof(struct key_info_tag));
}

int portDISABLE_IRQ(void)
{
    return 0;
}
int portDISABLE_FIQ(void)
{
    return 0;
}
void portENABLE_IRQ(void)
{
}
void portENABLE_FIQ(void)
{
}
void *os_memset(void *p, int v, size_t n)
{
    return memset(p, v, n);
}
void *os_memcpy(void *p, const void *q, size_t n)
{
    return memcpy(p, q, n);
}

int main(void)
{
    uint8_t key[16] = {1};
    uint8_t rsc[6] = {1, 2, 3, 4, 5, 6};
    assert(ow_rw_key_add_ccmp(0, 0xff, 2, key, sizeof(key), rsc) == 0);
    struct OwKeyRequest *group = submitted;
    memset(rsc, 0, sizeof(rsc));
    assert(ow_rw_key_add_ccmp(0, 0, 0, key, sizeof(key), rsc) == 0);
    struct OwKeyRequest *pair = submitted;
    __wrap_vif_mgmt_add_key(&group->key, 2);
    __wrap_sta_mgmt_add_key(&pair->key, 24);
    for (unsigned i = 0; i < TID_MAX; ++i)
    {
        assert(vif_info_tab[0].key_info[2].rx_pn[i] == 0x060504030201ULL);
        assert(sta_info_tab[0].sta_sec_info.key_info.rx_pn[i] == 0);
    }
    free(ke_param2msg(group));
    free(ke_param2msg(pair));
    struct mm_key_add_req *legacy = ke_msg_alloc(MM_KEY_ADD_REQ, TASK_MM, TASK_API, sizeof(*legacy));
    legacy->sta_idx = 0;
    __wrap_sta_mgmt_add_key(legacy, 24);
    for (unsigned i = 0; i < TID_MAX; ++i)
        assert(sta_info_tab[0].sta_sec_info.key_info.rx_pn[i] == 0);
    free(ke_param2msg(legacy));
    submitted = NULL;
    fail_alloc = 1;
    assert(ow_rw_key_add_ccmp(0, 0, 0, key, sizeof(key), rsc) == -1);
    assert(!submitted);
    fail_alloc = 0;
    assert(ow_rw_key_add_ccmp(0, 0, 0, key, 15, rsc) == -1);
    assert(ow_rw_key_add_ccmp(NX_VIRT_DEV_MAX, 0, 0, key, 16, rsc) == -1);
    assert(ow_rw_key_add_ccmp(0, STA_MAX, 0, key, 16, rsc) == -1);
    assert(ow_rw_key_add_ccmp(0, 0xff, MAC_DEFAULT_KEY_COUNT, key, 16, rsc) == -1);
    assert(!submitted);
    return 0;
}
