// Minimal bl_tx.h shim.
//
// The upstream bl_tx.h is heavily lwIP-pbuf entangled (function signatures
// take struct pbuf * / struct netif *). We dropped bl_tx.c and do the TX
// path in D. ipc_host.c still references struct bl_txhdr and bl_tx_resend()
// for its TX-confirm/error paths -- we provide just those declarations.

#ifndef VENDOR_BL_TX_H
#define VENDOR_BL_TX_H

#include "lmac_types.h"
#include "ipc_shared.h"
#include "bl_utils.h"
#include <utils_list.h>

typedef void (*bl_custom_tx_callback_t)(void *cb_arg, bool tx_ok);

struct bl_custom_tx_cfm {
    bl_custom_tx_callback_t cb;
    void *cb_arg;
};

union bl_hw_txstatus {
    struct {
        u32 tx_done            : 1;
        u32 retry_required     : 1;
        u32 sw_retry_required  : 1;
        u32 reserved           : 29;
    };
    u32 value;
};

// Layout must match vendor exactly: ipc_host.c reads custom_cfm.cb /
// cb_arg from the txhdr embedded in the TX buffer.
struct bl_txhdr {
    struct utils_list_hdr item;
    union bl_hw_txstatus  status;
    uint32_t             *p;
    struct hostdesc       host;
    struct bl_custom_tx_cfm custom_cfm;
};

// Provided by D side (urt.driver.bl808.wifi) -- re-queues the head of
// the TX list when LMAC reports a soft retry.
void bl_tx_resend(void);

#endif
