// BL808 clocks.
module urt.driver.bl_common.clock;

version (BL808):

nothrow @nogc:

enum uint xclk_hz = 40_000_000;         // the crystal
