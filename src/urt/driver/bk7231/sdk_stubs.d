// The standalone test image links without the vendor SDK; these stand in for the
// symbols the driver reaches so the link closes. Never part of a product build.
module urt.driver.bk7231.sdk_stubs;

version (Beken):
version (unittest):

extern(C) nothrow @nogc:

void intc_service_register(ubyte, ubyte, void function() nothrow @nogc) {}
void bk_misc_init_start_type() {}
void bk_misc_check_start_type() {}
uint driver_init() { return 0; }
uint func_init_basic() { return 0; }
