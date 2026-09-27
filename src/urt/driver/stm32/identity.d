// The 96-bit factory unique ID, hashed down to 64 bits.
module urt.driver.stm32.identity;

import urt.driver.stm32 : uid_base;
import urt.hash : fnv1a64;

import core.volatile;

@nogc nothrow:

ulong chip_unique_id()
{
    uint[3] uid = void;
    foreach (i, ref w; uid)
        w = volatileLoad(cast(uint*)(uid_base + i * 4));
    ulong id = fnv1a64(cast(const(ubyte)[])uid[]);
    return id ? id : 1;
}
