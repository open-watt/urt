// BK7231 hardware TRNG (driver/irda/irda.h: TRNG_BASE 0x00802480). The vendor enables the
// block per read and disables it again to save ~300uA; same here.
module urt.driver.bk7231.trng;

version (Beken):

import core.volatile;

nothrow @nogc:

bool trng_read(ubyte[] dst)
{
    enum uint ctrl = 0x0080_2480;
    enum uint data = 0x0080_2484;
    enum uint en = 1;

    volatileStore(cast(uint*)cast(size_t)ctrl, volatileLoad(cast(uint*)cast(size_t)ctrl) | en);
    while (dst.length)
    {
        uint v = volatileLoad(cast(uint*)cast(size_t)data);
        size_t n = dst.length < 4 ? dst.length : 4;
        foreach (i; 0 .. n)
            dst[i] = cast(ubyte)(v >> (8 * i));
        dst = dst[n .. $];
    }
    volatileStore(cast(uint*)cast(size_t)ctrl, volatileLoad(cast(uint*)cast(size_t)ctrl) & ~en);
    return true;
}
