// Minimal lwIP compat shim.
//
// The kept vendor sources (ipc_host.c, bl_defs.h) reference a couple of
// lwIP types as opaque holders. We don't link lwIP -- the D side allocates
// objects whose layout starts with these fields, and passes pointers
// through as `host_id` opaquely.
//
// Anything beyond struct pbuf / struct netif / err_t means a vendor source
// is touching lwIP for real, which means it shouldn't be in our kept set.

#ifndef VENDOR_COMPAT_LWIP_PBUF_H
#define VENDOR_COMPAT_LWIP_PBUF_H

#include <stdint.h>

typedef uint8_t  u8_t;
typedef uint16_t u16_t;
typedef uint32_t u32_t;
typedef int8_t   s8_t;
typedef int16_t  s16_t;
typedef int32_t  s32_t;
typedef int8_t   err_t;

// Only fields read by ipc_host.c's TX-confirm path. Layout-compatible with
// however the D side wraps a TX buffer.
struct pbuf
{
    struct pbuf *next;
    void        *payload;
    u16_t        tot_len;
    u16_t        len;
    u8_t         type;
    u8_t         flags;
    u16_t        ref;
};

struct netif;  // pointer-only use in struct bl_vif

#endif
