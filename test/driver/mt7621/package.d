// The parts of the MT7621 platform package the UART and GPIO backends use.
module urt.driver.mt7621;

import core.volatile;

nothrow @nogc:

enum uint sysctl_base = 0xBE00_0000;

uint mmio_read(uint addr)
    => volatileLoad(cast(uint*)addr);

void mmio_write(uint addr, uint value)
{
    volatileStore(cast(uint*)addr, value);
}
