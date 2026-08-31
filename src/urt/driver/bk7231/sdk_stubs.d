// The standalone test image has no vendor SDK to provide these symbols.
module urt.driver.bk7231.sdk_stubs;

version (Beken):
version (unittest):

extern(C) nothrow @nogc:

void intc_service_register(ubyte, ubyte, void function() nothrow @nogc) {}
void bk_misc_init_start_type() {}
void bk_misc_check_start_type() {}
uint driver_init() { return 0; }
uint func_init_basic() { return 0; }
void set_printf_port(ubyte) {}
void intc_irq() {}
void intc_fiq() {}
void bk_trap_udef() {}
void bk_trap_pabt() {}
void bk_trap_dabt() {}
void bk_trap_resv() {}
void vTaskSwitchContext() {}
__gshared void* pxCurrentTCB;
__gshared uint ulCriticalNesting;
