// Glue file -- the single definition for vendor globals that were
// originally headed-defined and relied on pre-gcc-10 -fcommon behaviour.
//
// See README.md "Patches applied to upstream" for the full list.

#include "lmac_msg.h"
#include "bl_tx.h"
#include <utils_list.h>

// Header had a bare tentative def; modern gcc refuses to make a var with
// FAM into COMMON. Single definition lives here.
struct cfg_start_req_u_tlv_s cfg_start_req_u_tlv_t;

// Originally in bl_tx.c (dropped -- TX path is implemented in D). These
// symbols are referenced from the bits of ipc_host.c we keep.
struct utils_list tx_list_bl;
int internel_cal_size_tx_desc;   // informational (printed at IPC init)
int internel_cal_size_tx_hdr;
