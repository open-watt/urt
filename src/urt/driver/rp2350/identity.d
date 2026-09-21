module urt.driver.rp2350.identity;

import urt.driver.rp2350.bootrom : rom_chip_info;

nothrow @nogc:

ulong chip_unique_id()
{
    uint[4] info;
    if (!rom_chip_info(info))
        return 0;
    ulong id = ulong(info[3]) << 32 | info[2];
    return id ? id : 1;
}
