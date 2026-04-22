/// BL808 crash handler.
///
/// Called from _trap_exception in start.S. Prints exception info,
/// register dump, and stack backtrace to UART0.
/// Requires -frame-pointer=all for reliable backtrace.
module sys.bl808.exception;

import sys.baremetal.exception : walk_fp_chain;
import sys.bl808.uart;

private:

immutable const(char)*[16] exception_names = [
    "Instruction address misaligned",
    "Instruction access fault",
    "Illegal instruction",
    "Breakpoint",
    "Load address misaligned",
    "Load access fault",
    "Store address misaligned",
    "Store access fault",
    "Environment call from U-mode",
    "Environment call from S-mode",
    "Reserved",
    "Environment call from M-mode",
    "Instruction page fault",
    "Load page fault",
    "Reserved",
    "Store page fault",
];

immutable const(char)*[31] rnames = [
    "ra ", "sp ", "gp ", "tp ",
    "t0 ", "t1 ", "t2 ",
    "s0 ", "s1 ",
    "a0 ", "a1 ", "a2 ", "a3 ",
    "a4 ", "a5 ", "a6 ", "a7 ",
    "s2 ", "s3 ", "s4 ", "s5 ",
    "s6 ", "s7 ", "s8 ", "s9 ",
    "s10", "s11",
    "t3 ", "t4 ", "t5 ", "t6 ",
];

public:

/// regs[] layout matches the save order in _trap_exception:
///  [0]=ra [1]=sp [2]=gp [3]=tp [4]=t0 [5]=t1 [6]=t2
///  [7]=s0/fp [8]=s1 [9]=a0...[16]=a7 [17]=s2...[26]=s11 [27]=t3...[30]=t6
extern(C) void _crash_handler(ulong* regs, ulong mcause, ulong mepc, ulong mtval) @nogc nothrow
{
    uart0_print("\n\n*** CRASH ***\nException: ");

    ulong cause = mcause & 0x7FFF_FFFF_FFFF_FFFF;
    if (cause < 16)
        uart0_print(exception_names[cast(uint) cause]);
    else
        uart0_print("Unknown exception");

    uart0_print(" (cause=");
    uart0_hex(mcause);
    uart0_print(")\n  mepc  = ");
    uart0_hex(mepc);
    uart0_print("\n  mtval = ");
    uart0_hex(mtval);
    uart0_print("\n\nRegisters:\n");

    foreach (i; 0 .. 31)
    {
        uart0_print("  ");
        uart0_print(rnames[i]);
        uart0_print(" = ");
        uart0_hex(regs[i]);
        if ((i % 4) == 3 || i == 30)
            uart0_putc('\n');
    }

    // Stack backtrace via the shared fp-chain walker.
    uart0_print("\nBacktrace:\n  [0] ");
    uart0_hex(mepc);
    uart0_print("  (faulting PC)\n");

    void*[32] addrs = void;
    const n = walk_fp_chain(cast(size_t) regs[7], addrs[]); // s0 = frame pointer

    foreach (depth, addr; addrs[0 .. n])
    {
        uart0_print("  [");
        const d = depth + 1;
        if (d < 10)
            uart0_putc(cast(char)('0' + d));
        else
        {
            uart0_putc(cast(char)('0' + d / 10));
            uart0_putc(cast(char)('0' + d % 10));
        }
        uart0_print("] ");
        uart0_hex(cast(ulong) addr);
        uart0_putc('\n');
    }

    uart0_print("\n*** HALTED ***\n");
}
