module urt.driver.rp2350.fault;

import urt.driver.reset : ResetMark, reset_record_mark, system_reset;
import urt.driver.rp2350.uart : uart0_hw_puts;

nothrow @nogc:

// Runs in fault context: no allocations or managed logging.
extern(C) void fault_report(uint vector, const(uint)* frame)
{
    reset_record_mark(ResetMark.crashed);
    static immutable string[16] names = [
        "?", "reset", "NMI", "hard fault", "MemManage", "BusFault", "UsageFault",
        "SecureFault", "?", "?", "?", "SVCall", "DebugMon", "?", "PendSV", "SysTick",
    ];

    uart0_hw_puts("\r\n*** ");
    uart0_hw_puts(vector < names.length ? names[vector] : "exception");

    put_reg(" pc=", frame[6]);
    put_reg(" lr=", frame[5]);
    put_reg(" psr=", frame[7]);
    put_reg(" cfsr=", volatile_load(0xE000ED28));
    put_reg(" hfsr=", volatile_load(0xE000ED2C));
    put_reg(" mmfar=", volatile_load(0xE000ED34));
    put_reg(" bfar=", volatile_load(0xE000ED38));
    put_reg(" sp=", cast(uint)frame);
    uart0_hw_puts(" ***\r\n");
    system_reset();
}


private:

uint volatile_load(size_t addr)
{
    import core.volatile : volatileLoad;
    return volatileLoad(cast(uint*)addr);
}

void put_reg(string label, uint value)
{
    static immutable char[16] digits = "0123456789abcdef";
    char[8] buf = void;
    foreach_reverse (i; 0 .. 8)
    {
        buf[i] = digits[value & 0xF];
        value >>= 4;
    }
    uart0_hw_puts(label);
    uart0_hw_puts(buf[]);
}
