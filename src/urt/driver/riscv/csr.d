// RISC-V machine-mode primitives: global interrupt masking through mstatus.MIE, wfi, and the time
// and cycle counters.
module urt.driver.riscv.csr;

@nogc nothrow:

bool irq_disable()
{
    size_t prev;
    asm @nogc nothrow { "csrrci %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

bool irq_enable()
{
    size_t prev;
    asm @nogc nothrow { "csrrsi %0, mstatus, 0x8" : "=r" (prev); }
    return (prev & 0x8) != 0;
}

void wait_for_interrupt()
{
    asm @nogc nothrow { "wfi"; }
}

ulong mtime_read()
{
    version (RISCV64)
    {
        ulong t;
        asm @nogc nothrow { "rdtime %0" : "=r" (t); }
        return t;
    }
    else
    {
        uint hi, lo, again;
        do
        {
            asm @nogc nothrow { "rdtimeh %0" : "=r" (hi); }
            asm @nogc nothrow { "rdtime  %0" : "=r" (lo); }
            asm @nogc nothrow { "rdtimeh %0" : "=r" (again); }
        }
        while (hi != again);
        return (ulong(hi) << 32) | lo;
    }
}

// For profiling, not timekeeping: it stops in wfi and follows clock scaling.
ulong mcycle_read()
{
    version (RISCV64)
    {
        ulong c;
        asm @nogc nothrow { "rdcycle %0" : "=r" (c); }
        return c;
    }
    else
    {
        uint hi, lo, again;
        do
        {
            asm @nogc nothrow { "rdcycleh %0" : "=r" (hi); }
            asm @nogc nothrow { "rdcycle  %0" : "=r" (lo); }
            asm @nogc nothrow { "rdcycleh %0" : "=r" (again); }
        }
        while (hi != again);
        return (ulong(hi) << 32) | lo;
    }
}
