// RISC-V machine timer compare (the CLINT's mtimecmp, T-Head's CORET). It is level-sensitive: the
// timer interrupt pends while mtime >= mtimecmp, so a deadline already passed raises at once.
module urt.driver.riscv.clint;

import core.volatile;

@nogc nothrow:

// The high word parks at its maximum first, so the pair never briefly matches an earlier deadline.
void mtimecmp_write(size_t mtimecmp, ulong deadline)
{
    auto lo = cast(uint*)mtimecmp;
    auto hi = cast(uint*)(mtimecmp + 4);
    volatileStore(hi, 0xFFFF_FFFF);
    volatileStore(lo, cast(uint)deadline);
    volatileStore(hi, cast(uint)(deadline >> 32));
}
