// BK7231 platform package (ARM968E-S, ARMv5TE)
//
// Provides sys_init() as the single entry point for all
// hardware initialization. Called from start.S before main().
module urt.driver.bk7231;

public import urt.driver.bk7231.uart;
public import urt.driver.bk7231.irq;
public import urt.driver.bk7231.timer;

import urt.driver.uart : UartConfig;
import urt.driver.bk7231.irq : irq_enable;

@nogc nothrow:

private extern(C) void __register_frame_info(const void*, void*);
private extern(C) extern const ubyte __eh_frame_start;
private ubyte[48] __eh_frame_object;

extern(C) void sys_init()
{
    __register_frame_info(&__eh_frame_start, &__eh_frame_object);

    // Polling-mode UART first so the vendor bring-up below is visible if it faults.
    uart_hw_init(0, UartConfig.init);

    // Vendor driver layer, in entry_main() order. Pre-scheduler: driver_init is
    // drv_model_init + g_dd_init, func_init_basic is intc_init + hal_flash_init,
    // and neither touches rtos_*.
    bk_misc_init_start_type();
    driver_init();
    bk_misc_check_start_type();
    func_init_basic();

    // After intc_init, which owns the interrupt controller this timer registers with.
    timer_hw_init();

    // Reset left I+F masked; the irq_disable/irq_enable pairs only ever restore, so this is the
    // one unconditional enable. The WLAN MAC lives on FIQ.
    irq_enable();
}

extern(C) nothrow @nogc
{
    void bk_misc_init_start_type();
    void bk_misc_check_start_type();
    uint driver_init();
    uint func_init_basic();
}
