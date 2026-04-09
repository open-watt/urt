// BK7231 platform package (ARM968E-S, ARMv5TE)
//
// Provides sys_init() as the single entry point for all
// hardware initialization. Called from start.S before main().
module sys.bk7231;

public import sys.bk7231.uart;
public import sys.bk7231.irq;
public import sys.bk7231.timer;

import sys.baremetal.uart : UartConfig;

@nogc nothrow:

private extern(C) void __register_frame_info(const void*, void*);
private extern(C) extern const ubyte __eh_frame_start;
private ubyte[48] __eh_frame_object;

extern(C) void sys_init()
{
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    // Init UART1 (console) at default baud for early output
    uart_hw_init(0, UartConfig.init);

    uart0_hw_puts("BK7231: sys_init\r\n");

    // Init freerunning timer for monotonic clock
    timer_hw_init();

    uart0_hw_puts("BK7231: ready\r\n");
}
