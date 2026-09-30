// Bouffalo GPIO controller (BL618, BL808 D0, BL808 M0).
//
// Same register layout across all three; only the pin count differs.
//
// GPIO_CFG register at GLB_BASE + 0x8C4 + pin*4:
//   bit[0]     = input enable
//   bit[1]     = schmitt trigger
//   bit[4]     = pull-up enable
//   bit[5]     = pull-down enable
//   bit[6]     = output enable
//   bits[12:8] = function (11 = SWGPIO)
//   bits[19:16] = interrupt mode, bit[20] = interrupt clear, bit[21] = pending, bit[22] = masked
//   bit[24]    = output value
//   bit[28]    = input value (read-only)
module urt.driver.bl_common.gpio;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.gpio : DriveMode, GpioInterruptConfig, GpioInterruptTrigger, Pull, gpio_interrupt_dispatch;
import urt.driver.irq : irq_critical, irq_handler_set, irq_line_enable;
import urt.result : InternalResult, Result;

@nogc nothrow:


version (BL808)       enum uint num_gpio = 46;
else version (BL618)  enum uint num_gpio = 35;
else static assert(false, "bl_common/gpio.d included on a non-Bouffalo target");

enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = true;
enum bool has_gpio_sampler = false;


uint gpio_count() => num_gpio;


void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    assert(mode == DriveMode.push_pull, "bouffalo gpio: open-drain not supported");
    uint cfg = GPIO_FUN_SWGPIO << 8 | GPIO_OUTPUT_EN | GPIO_INT_MASK;
    if (initial)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO << 8 | GPIO_INPUT_EN | GPIO_SCHMITT | GPIO_INT_MASK | (uint(pull) << 4));
}

void gpio_output_set(uint pin, bool value)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    uint cfg = gpio_cfg_read(pin) & ~GPIO_OUTPUT_HIGH;
    if (value)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void gpio_output_toggle(uint pin)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    gpio_cfg_write(pin, gpio_cfg_read(pin) ^ GPIO_OUTPUT_HIGH);
}

bool gpio_input_read(uint pin)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    return (gpio_cfg_read(pin) & GPIO_INPUT_VALUE) != 0;
}

void gpio_set_pull(uint pin, Pull pull)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    uint cfg = gpio_cfg_read(pin) & ~(GPIO_PULL_UP | GPIO_PULL_DOWN);
    gpio_cfg_write(pin, cfg | (uint(pull) << 4));
}

void gpio_release(uint pin)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO << 8 | GPIO_INT_MASK);
}

void gpio_set_function(uint pin, uint function_id, Pull pull = Pull.none, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "bouffalo gpio: pin out of range");
    assert(function_id <= GPIO_FUN_MASK, "bouffalo gpio: function_id out of range (5-bit field)");
    assert(mode == DriveMode.push_pull, "bouffalo gpio: open-drain not supported");
    uint cfg = (function_id & GPIO_FUN_MASK) << 8 | GPIO_INPUT_EN | GPIO_SCHMITT | GPIO_INT_MASK | (uint(pull) << 4);
    gpio_cfg_write(pin, cfg);
}


// Pin interrupts reach M0 on one CLIC line; its handler finds the pending pins.
version (BL808_M0)
{
    enum uint num_gpio_interrupts = 8;

    Result gpio_interrupt_hw_open(uint port, ref const GpioInterruptConfig config)
    {
        if (config.input.chip != 0 || config.input.line >= num_gpio)
            return InternalResult.unsupported;
        return line_irq_open(config.input.line, config.trigger, cast(ubyte)port);
    }

    void gpio_interrupt_hw_close(uint port, uint line)
    {
        line_irq_close(line);
    }

    // Owners below link_owner are GpioInterrupt ports; link_owner | slot is an event link.
    enum ubyte link_owner = 0x80;

    // A callback may close a line from the ISR, so ownership and the pin's mode change with interrupts off.
    Result line_irq_open(uint line, GpioInterruptTrigger trigger, ubyte owner)
    {
        auto guard = irq_critical();
        if (_owner[line] != no_owner)
            return InternalResult.already_exists;
        _owner[line] = owner;
        uint cfg = gpio_cfg_read(line) & ~(0xFu << 16 | GPIO_INT_MASK);
        gpio_cfg_write(line, cfg | int_mode[trigger] << 16);
        clear_pending(line);
        if (!_irq_hooked)
        {
            irq_handler_set(gpio_irq, &gpio_irq_handler);
            irq_line_enable(gpio_irq);
            _irq_hooked = true;
        }
        return Result.success;
    }

    void line_irq_close(uint line)
    {
        auto guard = irq_critical();
        gpio_cfg_write(line, gpio_cfg_read(line) | GPIO_INT_MASK);
        clear_pending(line);
        _owner[line] = no_owner;
    }
}


private:

enum uint GLB_BASE      = 0x2000_0000;
enum uint GPIO_CFG_BASE = GLB_BASE + 0x8C4;

enum uint GPIO_FUN_SWGPIO   = 11;
enum uint GPIO_FUN_MASK     = 0x1Fu;
enum uint GPIO_INPUT_EN     = 1u << 0;
enum uint GPIO_SCHMITT      = 1u << 1;
enum uint GPIO_PULL_UP      = 1u << 4;
enum uint GPIO_PULL_DOWN    = 1u << 5;
enum uint GPIO_OUTPUT_EN    = 1u << 6;
enum uint GPIO_OUTPUT_HIGH  = 1u << 24;
enum uint GPIO_INT_CLEAR    = 1u << 20;
enum uint GPIO_INT_PENDING  = 1u << 21;
enum uint GPIO_INT_MASK     = 1u << 22;
enum uint GPIO_INPUT_VALUE  = 1u << 28;

// Pull values map directly to GPIO_CFG bits[5:4]: none=0, up=bit4, down=bit5.
static assert(Pull.none == 0 && Pull.up == 1 && Pull.down == 2);

pragma(inline, true)
uint gpio_cfg_read(uint pin)
{
    return volatileLoad(cast(uint*)(GPIO_CFG_BASE + pin * 4));
}

pragma(inline, true)
void gpio_cfg_write(uint pin, uint value)
{
    volatileStore(cast(uint*)(GPIO_CFG_BASE + pin * 4), value);
}

version (BL808_M0)
{
    enum uint gpio_irq = 16 + 44;
    enum ubyte no_owner = 0xFF;

    // sync modes, sampled on the 32 kHz clock: falling 0, rising 1, low 2, high 3, both edges 4
    static immutable ubyte[GpioInterruptTrigger.max + 1] int_mode = [ 1, 0, 4, 3, 2 ];

    __gshared ubyte[num_gpio] _owner = no_owner;
    __gshared bool _irq_hooked;

    void clear_pending(uint line)
    {
        uint cfg = gpio_cfg_read(line);
        gpio_cfg_write(line, cfg | GPIO_INT_CLEAR);
        gpio_cfg_write(line, cfg & ~GPIO_INT_CLEAR);
    }

    void gpio_irq_handler(uint)
    {
        foreach (line; 0 .. num_gpio)
        {
            if (!(gpio_cfg_read(line) & GPIO_INT_PENDING))
                continue;
            clear_pending(line);
            immutable owner = _owner[line];
            if (owner == no_owner)
                continue;
            if (owner & link_owner)
            {
                import urt.driver.bl_common.event : link_fire;
                link_fire(owner & ~link_owner);
            }
            else
                gpio_interrupt_dispatch(owner);
        }
    }
}
