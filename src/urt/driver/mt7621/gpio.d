// MT7621 GPIO0-60. Pads belong to pin groups that switch to GPIO as a whole in GPIOMODE, so claiming a
// line takes its group from the peripheral; the groups urt itself runs on are refused.
module urt.driver.mt7621.gpio;

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.driver.gpio : DriveMode, GpioCallbackContext, GpioInterrupt, GpioInterruptCallback, GpioInterruptConfig, GpioInterruptTrigger, Pull;
import urt.driver.mt7621 : mmio_read, mmio_write, sysctl_base;
import urt.driver.mt7621.irq : irq_disable, irq_enable, irq_set_enable, irq_set_handler;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum uint num_gpio = 61;
enum bool has_pull_up = false;
enum bool has_pull_down = false;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = false;
enum bool has_gpio_sampler = false;
enum uint num_gpio_interrupts = 8;

uint gpio_count()
    => num_gpio;

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(mode == DriveMode.push_pull, "mt7621 gpio: no open-drain");
    claim(pin);
    gpio_output_set(pin, initial);
    reg_set(ctrl, pin, true);
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    assert(pull == Pull.none, "mt7621 gpio: pad pulls are not driven");
    claim(pin);
    reg_set(ctrl, pin, false);
}

void gpio_output_set(uint pin, bool value)
{
    mmio_write(bank(value ? dset : dclr, pin), bit(pin));
}

void gpio_output_toggle(uint pin)
{
    gpio_output_set(pin, !gpio_input_read(pin));
}

bool gpio_input_read(uint pin)
    => (mmio_read(bank(data, pin)) & bit(pin)) != 0;

void gpio_set_pull(uint pin, Pull pull)
{
    assert(pull == Pull.none, "mt7621 gpio: pad pulls are not driven");
}

void gpio_release(uint pin)
{
    reg_set(ctrl, pin, false);
}

Result gpio_interrupt_hw_open(uint port, ref const GpioInterruptConfig config)
{
    if (config.input.chip != 0 || config.input.line >= num_gpio)
        return InternalResult.unsupported;
    if (_port_line[port] != no_line)
        return InternalResult.already_exists;
    Result result = line_irq_open(config.input.line, config.trigger, cast(ubyte)port);
    if (result)
        _port_line[port] = cast(ubyte)config.input.line;
    return result;
}

void gpio_interrupt_hw_set_callback(uint port, GpioInterruptCallback callback)
{
    atomicStore!(MemoryOrder.release)(_callbacks[port], cast(size_t)callback);
}

void gpio_interrupt_hw_close(uint port)
{
    gpio_interrupt_hw_set_callback(port, null);
    if (_port_line[port] != no_line)
        line_irq_close(_port_line[port]);
}

// Owners below link_owner are GpioInterrupt ports; link_owner | slot is an event link.
enum ubyte link_owner = 0x80;

// A callback may close a line from the ISR, so ownership and the trigger registers change with interrupts off.
Result line_irq_open(uint line, GpioInterruptTrigger trigger, ubyte owner)
{
    immutable prior = irq_disable();
    scope (exit) if (prior) irq_enable();
    if (_owner[line] != no_owner)
        return InternalResult.already_exists;
    gpio_input_init(line);
    _owner[line] = owner;
    mmio_write(bank(stat, line), bit(line));
    reg_set(redge, line, trigger == GpioInterruptTrigger.rising || trigger == GpioInterruptTrigger.change);
    reg_set(fedge, line, trigger == GpioInterruptTrigger.falling || trigger == GpioInterruptTrigger.change);
    reg_set(hlvl, line, trigger == GpioInterruptTrigger.high);
    reg_set(llvl, line, trigger == GpioInterruptTrigger.low);
    if (!_irq_hooked)
    {
        irq_set_handler(gpio_irq, &gpio_irq_handler);
        irq_set_enable(gpio_irq);
        _irq_hooked = true;
    }
    return Result.success;
}

void line_irq_close(uint line)
{
    static immutable uint[4] triggers = [redge, fedge, hlvl, llvl];
    immutable prior = irq_disable();
    foreach (r; triggers)
        reg_set(r, line, false);
    mmio_write(bank(stat, line), bit(line));
    if (_owner[line] < link_owner)
        _port_line[_owner[line]] = no_line;
    _owner[line] = no_owner;
    if (prior)
        irq_enable();
}


private:

enum uint gpio_base = 0xBE00_0600;
enum uint gpio_irq  = 12;

enum uint ctrl  = 0x00;
enum uint data  = 0x20;
enum uint dset  = 0x30;
enum uint dclr  = 0x40;
enum uint redge = 0x50;
enum uint fedge = 0x60;
enum uint hlvl  = 0x70;
enum uint llvl  = 0x80;
enum uint stat  = 0x90;

enum ubyte no_owner = 0xFF;
enum ubyte no_line = 0xFF;

enum uint sysc_gpio_mode = 0x60;

struct Group
{
    ubyte first, last, shift, mask;
    bool reserved;
}

// GPIOMODE fields, as Linux's pinctrl-mt7621; value 1 selects GPIO in each. GPIO0 has no group.
static immutable Group[12] groups = [
    Group(1, 2, 1, 1, true),        // uart1: the console
    Group(3, 4, 2, 1),              // i2c
    Group(5, 8, 3, 3),              // uart3
    Group(9, 12, 5, 3),             // uart2
    Group(13, 17, 7, 1),            // jtag
    Group(18, 18, 8, 3),            // wdt
    Group(19, 19, 10, 3),           // pcie
    Group(20, 21, 12, 3, true),     // mdio: the switch and the SFP PHY
    Group(22, 33, 15, 1, true),     // rgmii2
    Group(34, 40, 16, 3, true),     // spi: the boot NOR
    Group(41, 48, 18, 3),           // sdhci
    Group(49, 60, 14, 1, true),     // rgmii1
];

__gshared ubyte[num_gpio] _owner = no_owner;
__gshared ubyte[num_gpio_interrupts] _port_line = no_line;
shared size_t[num_gpio_interrupts] _callbacks;
__gshared bool _irq_hooked;

uint bank(uint reg, uint pin)
    => gpio_base + reg + (pin / 32) * 4;

uint bit(uint pin)
    => 1u << (pin % 32);

void reg_set(uint reg, uint pin, bool on)
{
    immutable a = bank(reg, pin);
    mmio_write(a, on ? mmio_read(a) | bit(pin) : mmio_read(a) & ~bit(pin));
}

void claim(uint pin)
{
    assert(pin < num_gpio, "mt7621 gpio: no such line");
    foreach (ref g; groups)
    {
        if (pin < g.first || pin > g.last)
            continue;
        assert(!g.reserved, "mt7621 gpio: that line's pin group carries a peripheral urt depends on");
        immutable mode = mmio_read(sysctl_base + sysc_gpio_mode);
        mmio_write(sysctl_base + sysc_gpio_mode, (mode & ~(uint(g.mask) << g.shift)) | (1u << g.shift));
        return;
    }
}

void gpio_irq_handler(uint)
{
    foreach (b; 0 .. (num_gpio + 31) / 32)
    {
        uint pending = mmio_read(gpio_base + stat + b * 4);
        mmio_write(gpio_base + stat + b * 4, pending);
        while (pending)
        {
            import urt.internal.bitop : bsf;
            immutable line = b * 32 + bsf(pending);
            pending &= pending - 1;
            if (line >= num_gpio)
                continue;
            immutable owner = _owner[line];
            if (owner == no_owner)
                continue;
            if (owner & link_owner)
            {
                import urt.driver.mt7621.event : link_fire;
                link_fire(owner & ~link_owner);
            }
            else
            {
                auto cb = cast(GpioInterruptCallback)atomicLoad!(MemoryOrder.acquire)(_callbacks[owner]);
                if (cb !is null)
                    cb(GpioInterrupt(owner), GpioCallbackContext.interrupt);
            }
        }
    }
}


unittest
{
    import core.volatile : volatileLoad;
    import urt.driver.gpio : GpioLine, gpio_interrupt_close, gpio_interrupt_open, gpio_interrupt_set_callback, is_open;
    import urt.driver.irq : irq_global_disable, irq_global_enable, irq_global_set;

    // GPIO0 has no pin group, so it is a plain line on every board; interrupting on the level it holds must fire.
    __gshared uint fires;
    __gshared GpioInterrupt irq;
    fires = 0;
    static bool once(GpioInterrupt, GpioCallbackContext) @nogc nothrow
    {
        gpio_interrupt_close(irq);
        ++fires;
        return false;
    }

    immutable was_output = (mmio_read(bank(ctrl, 0)) & bit(0)) != 0;
    gpio_input_init(0);
    GpioInterruptConfig cfg;
    cfg.input = GpioLine(0, 0);
    cfg.trigger = gpio_input_read(0) ? GpioInterruptTrigger.high : GpioInterruptTrigger.low;
    immutable prior = irq_global_disable();
    assert(gpio_interrupt_open(irq, 0, cfg));

    // The port is taken, and so is the line: neither a second line on this port nor a second port on this line opens.
    GpioInterrupt other;
    GpioInterruptConfig other_cfg = cfg;
    other_cfg.input = GpioLine(0, 18);
    assert(!gpio_interrupt_open(other, 0, other_cfg) && !other.is_open && _owner[18] == no_owner);
    assert(!gpio_interrupt_open(other, 1, cfg) && !other.is_open);

    gpio_interrupt_set_callback(irq, &once);
    irq_global_enable();
    foreach (i; 0 .. 100_000)
    {
        if (volatileLoad(&fires))
            break;
    }
    irq_global_set(prior);
    reg_set(ctrl, 0, was_output);
    assert(volatileLoad(&fires) == 1, "GPIO interrupt not delivered through the GIC");
    assert(!irq.is_open && _port_line[0] == no_line && _owner[0] == no_owner, "closing from the callback left the port or line owned");
}
