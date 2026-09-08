#include <assert.h>
#include <stdlib.h>
#include "../src/urt/driver/bk7231/ow_rw.c"

struct sm_env_tag sm_env;
struct co_list rw_msg_rx_head;
static struct co_list pending;
static unsigned allocations;
static bool stopped;
static ke_state_t observed_sm_state;

static struct ke_msg *message(void)
{
    struct ke_msg *msg = calloc(1, sizeof(*msg) + 64);
    assert(msg);
    ++allocations;
    return msg;
}

void ke_msg_free(const struct ke_msg *msg)
{
    assert(stopped && allocations);
    --allocations;
    free((void *)msg);
}

struct co_list_hdr *co_list_pop_front(struct co_list *list)
{
    struct co_list_hdr *node = list->first;
    if (node)
    {
        list->first = node->next;
        if (!list->first)
            list->last = NULL;
    }
    return node;
}

void hal_machw_stop(void)
{
    stopped = true;
}

void phy_stop(void)
{
    assert(stopped);
}

void ke_state_set(ke_task_id_t task, ke_state_t state)
{
    assert(task == TASK_SM);
    observed_sm_state = state;
}

void txl_reset(void)
{
    assert(stopped && observed_sm_state == SM_IDLE);
    rw_msg_rx_head.first = rw_msg_rx_head.last = &message()->hdr;
}

void rxl_reset(void)
{
    assert(stopped);
}

void scanu_init(void)
{
    assert(stopped);
}

void *sr_get_scan_results(void)
{
    return NULL;
}

void sr_release_scan_results(SCAN_RST_UPLOAD_PTR results)
{
    assert(!results);
}

void rwm_flush_rx_list(void)
{
    assert(stopped);
}

void ke_flush(void)
{
    discard_messages(&pending);
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

int main(void)
{
    for (unsigned attempt = 0; attempt < 100; ++attempt)
    {
        stopped = false;
        observed_sm_state = SM_IDLE + 1;
        sm_env.connect_param = (void *)message()->param;
        sm_env.connect_ind = (void *)message()->param;
        sm_env.bss_config.first = sm_env.bss_config.last = &message()->hdr;
        pending.first = pending.last = &message()->hdr;
        ow_rw_mac_quiesce();
        assert(!allocations);
        assert(!sm_env.connect_param && !sm_env.connect_ind);
        assert(!sm_env.bss_config.first && !pending.first && !rw_msg_rx_head.first);
    }
    return 0;
}
