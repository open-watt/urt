module urt.driver.mt7621.fault;

import urt.driver.reset : ResetMark, reset_record_mark, system_reset;
import urt.driver.mt7621.uart : uart0_hw_puts;

nothrow @nogc:

// Runs from the exception vector with EXL set: no allocations or managed logging.
extern(C) void fault_report(uint cause, uint epc, uint badvaddr, uint sp, uint ra)
{
    if (_faulting)
        system_reset();
    _faulting = true;
    reset_record_mark(ResetMark.crashed);
    uart0_hw_puts("\r\n*** exception");
    put_reg(" cause=", cause);
    put_reg(" epc=", epc);
    put_reg(" badvaddr=", badvaddr);
    put_reg(" sp=", sp);
    put_reg(" ra=", ra);
    uart0_hw_puts(" ***\r\n");
    if ((sp & 3) == 0 && sp >= 0x8000_1000 && sp + 64 * 4 <= cast(uint)&_stack_top)
    {
        foreach (row; 0 .. 8)
        {
            put_reg("stack ", sp + row * 32);
            uart0_hw_puts(":");
            foreach (col; 0 .. 8)
                put_reg(" ", (cast(const(uint)*)sp)[row * 8 + col]);
            uart0_hw_puts("\r\n");
        }
    }

    system_reset();
}


private:

extern(C) extern __gshared ubyte _stack_top;
__gshared bool _faulting;

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
