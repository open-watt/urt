// Awkward vendor header material only: the efuse command enum. CMD_EFUSE_READ_BYTE
// sits directly beside CMD_EFUSE_WRITE_BYTE and efuse writes are permanent, so the
// value is taken from the SDK header rather than hardcoded on the D side.
#include "include.h"
#include "sys_ctrl_pub.h"

extern UINT32 sctrl_ctrl(UINT32 cmd, void *param);

// 0 on success; *out is 0xFF when the cell is unprogrammed.
int ow_efuse_read_byte(unsigned char addr, unsigned char *out)
{
    EFUSE_OPER_ST oper;
    oper.addr = addr;
    oper.data = 0xFF;
    int r = (int)sctrl_ctrl(CMD_EFUSE_READ_BYTE, &oper);
    *out = oper.data;
    return r;
}

unsigned char ow_efuse_uid_addr(void)  { return EFUSE_UID_ADDR; }
unsigned char ow_efuse_uid_len(void)   { return EFUSE_UID_LEN; }
unsigned char ow_efuse_mac_addr(void)  { return EFUSE_MAC_START_ADDR; }
unsigned char ow_efuse_mac_len(void)   { return EFUSE_MAC_LEN; }
