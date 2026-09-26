module urt.driver.mt7621.irq;

import core.volatile;

@nogc nothrow:

// MIPS GIC in legacy (non-EIC) mode: every shared line and the local timer compare are routed to
// CPU pin 0 (Cause.IP2) of VPE 0, and _irq_dispatch demultiplexes from the GIC pending registers.
enum bool has_plic = false;
enum bool has_nvic = false;
enum bool has_clic = false;
enum bool has_per_irq_control = true;
enum bool has_irq_priority = false;
enum bool has_wait_for_interrupt = true;
enum bool has_irq_diagnostics = false;
enum bool has_global_irq_state = true;
enum bool has_smp = false;
enum uint irq_max = 56;

alias IrqHandler = void function(uint irq) @nogc nothrow;

bool irq_disable()
{
    uint status = void;
    asm @nogc nothrow { ".set push; .set noat; di %0; ehb; .set pop" : "=r"(status) :: "memory"; }
    return (status & 1) != 0;
}

bool irq_enable()
{
    uint status = void;
    asm @nogc nothrow { ".set push; .set noat; ei %0; ehb; .set pop" : "=r"(status) :: "memory"; }
    return (status & 1) != 0;
}

void wait_for_interrupt()
{
    asm @nogc nothrow { "wait" ::: "memory"; }
}

bool irq_set_enable(uint irq)
{
    immutable prev = irq_enabled(irq);
    gic_write(gic_sh_smask + irq / 32 * 4, 1u << (irq % 32));
    return prev;
}

bool irq_clear_enable(uint irq)
{
    immutable prev = irq_enabled(irq);
    gic_write(gic_sh_rmask + irq / 32 * 4, 1u << (irq % 32));
    return prev;
}

enum IrqClass : uint
{
    timer,
}

// The timer compare is a GIC local interrupt, masked separately from the shared lines.
bool enable_irq(IrqClass c)
{
    immutable prev = (gic_read(gic_vl_mask) & gic_vl_compare) != 0;
    gic_write(gic_vl_smask, gic_vl_compare);
    return prev;
}

bool disable_irq(IrqClass c)
{
    immutable prev = (gic_read(gic_vl_mask) & gic_vl_compare) != 0;
    gic_write(gic_vl_rmask, gic_vl_compare);
    return prev;
}

IrqHandler irq_set_handler(uint irq, IrqHandler handler)
{
    if (irq >= irq_max)
        return null;
    IrqHandler prev = _handlers[irq];
    _handlers[irq] = handler;
    return prev;
}

extern(C) void irq_init()
{
    uint cmgcr = void;
    asm @nogc nothrow { ".set push; .set noat; mfc0 %0, $15, 3; .set pop" : "=r"(cmgcr); }
    immutable uint gcr = ((cmgcr & ~0x7FFu) << 4) | kseg1;
    volatileStore(cast(uint*)(gcr + gcr_gic_base), gic_phys | gcr_gic_en);

    foreach (w; 0 .. (irq_max + 31) / 32)
    {
        gic_write(gic_sh_pol + w * 4, ~0u);
        gic_write(gic_sh_trig + w * 4, 0);
        gic_write(gic_sh_rmask + w * 4, ~0u);
    }
    foreach (i; 0 .. irq_max)
    {
        gic_write(gic_sh_map_pin + i * 4, gic_map_to_pin | gic_cpu_pin);
        gic_write(gic_sh_map_vp + i * 0x20, 1);
    }

    gic_write(gic_vl_ctl, gic_read(gic_vl_ctl) & ~gic_vl_ctl_eic);
    gic_write(gic_vl_rmask, ~0u);
    gic_write(gic_vl_compare_map, gic_map_to_pin | gic_cpu_pin);

    uint status = void;
    asm @nogc nothrow { ".set push; .set noat; mfc0 %0, $12; .set pop" : "=r"(status); }
    status |= status_im_gic;
    asm @nogc nothrow { ".set push; .set noat; mtc0 %0, $12; ehb; .set pop" :: "r"(status) : "memory"; }
}

// Called from the exception vector for Cause.ExcCode == 0, with EXL set.
extern(C) void _irq_dispatch()
{
    if (gic_read(gic_vl_pend) & gic_read(gic_vl_mask) & gic_vl_compare)
    {
        import urt.driver.mt7621.timer : timer_compare_irq;
        timer_compare_irq();
    }
    foreach (w; 0 .. (irq_max + 31) / 32)
    {
        uint pending = gic_read(gic_sh_pend + w * 4) & gic_read(gic_sh_mask + w * 4);
        while (pending)
        {
            import urt.internal.bitop : bsf;
            immutable bit = bsf(pending);
            pending &= pending - 1;
            immutable irq = w * 32 + bit;
            if (irq < irq_max && _handlers[irq] !is null)
                _handlers[irq](irq);
        }
    }
}

enum uint gic_vl_pend    = 0x8004;
enum uint gic_vl_smask   = 0x8010;
enum uint gic_vl_compare = 1 << 1;

uint gic_read(uint offset)
    => volatileLoad(cast(uint*)(gic_base + offset));

void gic_write(uint offset, uint value)
{
    volatileStore(cast(uint*)(gic_base + offset), value);
}


private:

enum uint kseg1    = 0xA000_0000;
enum uint gic_phys = 0x1FBC_0000;
enum uint gic_base = gic_phys | kseg1;

enum uint gcr_gic_base = 0x80;
enum uint gcr_gic_en   = 1;

enum uint gic_sh_pol     = 0x0100;
enum uint gic_sh_trig    = 0x0180;
enum uint gic_sh_rmask   = 0x0300;
enum uint gic_sh_smask   = 0x0380;
enum uint gic_sh_mask    = 0x0400;
enum uint gic_sh_pend    = 0x0480;
enum uint gic_sh_map_pin = 0x0500;
enum uint gic_sh_map_vp  = 0x2000;

enum uint gic_vl_ctl         = 0x8000;
enum uint gic_vl_mask        = 0x8008;
enum uint gic_vl_rmask       = 0x800C;
enum uint gic_vl_compare_map = 0x8044;
enum uint gic_vl_ctl_eic     = 1 << 0;

enum uint gic_map_to_pin = 1u << 31;
enum uint gic_cpu_pin    = 0;
enum uint status_im_gic  = 1 << (10 + gic_cpu_pin);

__gshared IrqHandler[irq_max] _handlers;

bool irq_enabled(uint irq)
    => (gic_read(gic_sh_mask + irq / 32 * 4) & (1u << (irq % 32))) != 0;
