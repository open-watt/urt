module urt.driver.bk7231.sdk_stubs;

version (Beken):
version (unittest):

extern(C) nothrow @nogc:

__gshared void* pxCurrentTCB;
__gshared uint ulCriticalNesting;

void bk_misc_check_start_type()
{
}

void bk_misc_init_start_type()
{
}

int bk_wlan_set_channel(int)
{
    return 0;
}

int bk_wlan_stop_monitor()
{
    return 0;
}

void bk_trap_dabt()
{
}

void bk_trap_pabt()
{
}

void bk_trap_resv()
{
}

void bk_trap_udef()
{
}

void calibration_main()
{
}

uint cfg_param_init()
{
    return 0;
}

uint driver_init()
{
    return 0;
}

uint func_init_basic()
{
    return 0;
}

void intc_fiq()
{
}

void intc_irq()
{
}

void intc_service_register(ubyte, ubyte, void function() nothrow @nogc)
{
}

void ke_evt_core_scheduler()
{
}

void ke_evt_none_core_scheduler()
{
}

void manual_cal_load_bandgap_calm()
{
}

uint manual_cal_load_default_txpwr_tab(uint)
{
    return 0;
}

void manual_cal_load_lpf_iq_tag_flash()
{
}

uint manual_cal_load_txpwr_tab_flash()
{
    return 0;
}

void manual_cal_load_xtal_tag_flash()
{
}

void mr_kmsg_init()
{
}

int ow_rw_add_if(void*, int)
{
    return 0;
}

int ow_rw_disconnect(ubyte, ushort)
{
    return 0;
}

byte ow_rw_get_rssi()
{
    return 0;
}

int ow_rw_mac_init()
{
    return 0;
}

int ow_rw_scan(ubyte, void*, ubyte)
{
    return 0;
}

int ow_rw_scan_cancel()
{
    return 0;
}

int ow_rw_transfer(ubyte, void*, uint)
{
    return 0;
}

void rwnx_cal_initial_calibration()
{
}

void rwnx_recv_msg()
{
}

void rwnxl_init()
{
}

void rxl_cntrl_evt(int)
{
}

void set_printf_port(ubyte)
{
}

void vTaskSwitchContext()
{
}

void wifi_get_mac_address(void*, ubyte)
{
}
