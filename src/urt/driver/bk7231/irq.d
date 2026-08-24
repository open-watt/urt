// BK7231 interrupt controller (shared by BK7231N and BK7231T)
//
// ARM968E-S uses a custom Beken interrupt controller (not ARM GIC/NVIC).
// The BK7231N ICU (Interrupt Control Unit) is at 0x0080_2000.
module urt.driver.bk7231.irq;

import core.volatile;

import urt.driver.irq : IrqHandler;

@nogc nothrow:

enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_clic = false;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = false;
enum bool has_irq_diagnostics = false;
enum bool has_global_irq_state = true;
enum bool has_smp = false;
enum uint irq_max = 32;

// ARMv5 CPSR: I=bit7 masks IRQ, F=bit6 masks FIQ. The WLAN MAC interrupts are FIQs, so
// the global enable covers both; the reported state is the I bit.
bool irq_disable()
{
    uint cpsr;
    asm @nogc nothrow { "mrs %0, cpsr" : "=r" (cpsr); }
    bool was_enabled = (cpsr & 0x80) == 0;
    asm @nogc nothrow { "msr cpsr_c, %0" :: "r" (cpsr | 0xC0); }
    return was_enabled;
}

bool irq_enable()
{
    uint cpsr;
    asm @nogc nothrow { "mrs %0, cpsr" : "=r" (cpsr); }
    bool was_enabled = (cpsr & 0x80) == 0;
    asm @nogc nothrow { "msr cpsr_c, %0" :: "r" (cpsr & ~0xC0); }
    return was_enabled;
}

bool irq_set_enable(uint irq_num)
{
    auto en = cast(uint*)(cast(size_t)(icu_base + icu_int_enable));
    uint mask = volatileLoad(en);
    bool prev = (mask & (1u << irq_num)) != 0;
    volatileStore(en, mask | (1u << irq_num));
    return prev;
}

bool irq_clear_enable(uint irq_num)
{
    auto en = cast(uint*)(cast(size_t)(icu_base + icu_int_enable));
    uint mask = volatileLoad(en);
    bool prev = (mask & (1u << irq_num)) != 0;
    volatileStore(en, mask & ~(1u << irq_num));
    return prev;
}



// The Beken ICU has no vector table; the vendor intc_irq() decodes the status
// register and calls handlers registered through intc_service_register, whose
// ISR type takes no argument. Each line gets a generated trampoline that
// recovers its own number and dispatches to the installed IrqHandler.
IrqHandler irq_set_handler(uint irq, IrqHandler handler)
{
    if (irq >= irq_max)
        return null;

    IrqHandler prev = _handlers[irq];
    _handlers[irq] = handler;

    if (handler && !_registered[irq])
    {
        intc_service_register(cast(ubyte)irq, irq_priority[irq], cast(VendorIsr)_trampolines[irq]);
        _registered[irq] = true;
    }
    return prev;
}


private:

// driver/include/intc_pub.h PRI_IRQ_*; the vendor's intended service order.
immutable ubyte[irq_max] irq_priority = [
    26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11,
     0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
];

alias VendorIsr = extern(C) void function() nothrow @nogc;
extern(C) void intc_service_register(ubyte int_num, ubyte int_pri, VendorIsr isr);

__gshared IrqHandler[irq_max] _handlers;
__gshared bool[irq_max] _registered;

void irq_trampoline(uint irq)() nothrow @nogc
{
    IrqHandler h = _handlers[irq];
    if (h)
        h(irq);
}

__gshared immutable typeof(&irq_trampoline!0)[irq_max] _trampolines = () {
    typeof(&irq_trampoline!0)[irq_max] t;
    static foreach (i; 0 .. irq_max)
        t[i] = &irq_trampoline!i;
    return t;
}();

enum uint icu_base = 0x0080_2000;

// ICU register offsets (from SDK icu.h)
enum
{
    icu_peri_clk_pwd = 2 * 4,   // 0x08: peripheral clock power-down (1=off)
    icu_clk_gating   = 3 * 4,   // 0x0C: peripheral clock gating
    icu_int_enable   = 16 * 4,  // 0x40: interrupt enable mask (FIQ [31:16] | IRQ [15:0])
    icu_global_int   = 17 * 4,  // 0x44: global IRQ/FIQ enable
    icu_int_raw      = 18 * 4,  // 0x48: raw interrupt status
    icu_int_status   = 19 * 4,  // 0x4C: masked interrupt status
    icu_arm_wakeup   = 20 * 4,  // 0x50: ARM wakeup enable
}

// IRQ bit positions in icu_int_enable / icu_int_status
enum : uint
{
    IRQ_UART1 = 1 << 0,
    IRQ_UART2 = 1 << 1,
    IRQ_I2C1  = 1 << 2,
    IRQ_IRDA  = 1 << 3,
    IRQ_I2C2  = 1 << 5,
    IRQ_SPI   = 1 << 6,
    IRQ_GPIO  = 1 << 7,
    IRQ_TIMER = 1 << 8,
    IRQ_PWM   = 1 << 9,
    IRQ_ADC   = 1 << 11,
    IRQ_SDIO  = 1 << 12,
    IRQ_SEC   = 1 << 13,
    IRQ_LA    = 1 << 14,
    IRQ_DMA   = 1 << 15,
}
