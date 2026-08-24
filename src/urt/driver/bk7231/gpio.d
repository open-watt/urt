// BK7231 GPIO. One 32-bit config register per pin at GPIO_BASE + pin*4, holding
// both the pad level and the mode. Pin numbering is linear 0..31.
//
// The perial-mode mux selecting which peripheral takes a pin in second-function
// mode differs per chip: BK7231N has a 2-bit field per pin split across
// GPIO_FUNC_CFG (0..15) and GPIO_FUNC_CFG_2 (16..31); BK7231T has one bit per
// pin in GPIO_FUNC_CFG.
//
// Mode values are taken verbatim from the vendor gpio_config() switch, and the
// data bits from driver/gpio/gpio.h, rather than re-derived. Note bit 3 is named
// GCFG_OUTPUT_ENABLE_POS there but GMODE_OUTPUT writes 0x00, so it is active-low.
module urt.driver.bk7231.gpio;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.gpio : Pull, DriveMode;

@nogc nothrow:


enum uint num_gpio = 32;
enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = true;
enum bool has_gpio_sampler = false;


uint gpio_count() => num_gpio;

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");
    assert(mode == DriveMode.push_pull, "bk7231 gpio: open-drain not supported");

    reg_write(cfg_reg(pin), GMODE_OUTPUT | (initial ? GCFG_OUTPUT_BIT : 0));
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");

    reg_write(cfg_reg(pin), input_mode(pull));
}

void gpio_output_set(uint pin, bool value)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");

    uint cfg = reg_read(cfg_reg(pin)) & ~GCFG_OUTPUT_BIT;
    reg_write(cfg_reg(pin), cfg | (value ? GCFG_OUTPUT_BIT : 0));
}

void gpio_output_toggle(uint pin)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");

    uint cfg = reg_read(cfg_reg(pin));
    reg_write(cfg_reg(pin), cfg ^ GCFG_OUTPUT_BIT);
}

bool gpio_input_read(uint pin)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");

    return (reg_read(cfg_reg(pin)) & GCFG_INPUT_BIT) != 0;
}

void gpio_set_pull(uint pin, Pull pull)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");

    uint cfg = reg_read(cfg_reg(pin)) & ~(GCFG_PULL_ENABLE_BIT | GCFG_PULL_MODE_BIT);
    reg_write(cfg_reg(pin), cfg | pull_bits(pull));
}

void gpio_release(uint pin)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");

    reg_write(cfg_reg(pin), GMODE_HIGH_Z);
}

void gpio_set_function(uint pin, uint function_id, Pull pull = Pull.none, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "bk7231 gpio: pin out of range");
    assert(mode == DriveMode.push_pull, "bk7231 gpio: open-drain not supported");

    reg_write(cfg_reg(pin), GMODE_SECOND_FUNC | pull_bits(pull));

    // The mux field differs per chip: N has 2 bits per pin split across FUNC_CFG/FUNC_CFG_2,
    // T has 1 bit per pin in FUNC_CFG (vendor gpio.c gpio_enable_second_function).
    version (BK7231N)
    {
        assert(function_id < 4, "bk7231n gpio: perial mode is 2-bit (0..3)");
        uint regist = pin < 16 ? GPIO_FUNC_CFG : GPIO_FUNC_CFG_2;
        uint shift = (pin & 15) * 2;
        uint func_cfg = reg_read(regist);
        func_cfg &= ~(0x3u << shift);
        func_cfg |= (function_id & 0x3u) << shift;
        reg_write(regist, func_cfg);
    }
    else
    {
        assert(function_id < 2, "bk7231t gpio: one mux bit per pin (perial mode 0..1)");
        uint func_cfg = reg_read(GPIO_FUNC_CFG);
        if (function_id)
            func_cfg |= 1u << pin;
        else
            func_cfg &= ~(1u << pin);
        reg_write(GPIO_FUNC_CFG, func_cfg);
    }
}


private:

uint input_mode(Pull pull)
    => GMODE_INPUT | pull_bits(pull);

uint pull_bits(Pull pull)
{
    final switch (pull)
    {
        case Pull.up:   return GCFG_PULL_ENABLE_BIT | GCFG_PULL_MODE_BIT;
        case Pull.down: return GCFG_PULL_ENABLE_BIT;
        case Pull.none: return 0;
    }
}

uint cfg_reg(uint pin) => GPIO_BASE + pin * 4;

enum uint GPIO_BASE     = 0x0080_2800;
enum uint GPIO_FUNC_CFG   = GPIO_BASE + 32 * 4;
enum uint GPIO_FUNC_CFG_2 = GPIO_BASE + 46 * 4;   // BK7231N: pins 16..31, 2 bits each

// driver/gpio/gpio.h
enum uint GCFG_INPUT_BIT       = 1u << 0;
enum uint GCFG_OUTPUT_BIT      = 1u << 1;
enum uint GCFG_PULL_MODE_BIT   = 1u << 4;   // 1 = up
enum uint GCFG_PULL_ENABLE_BIT = 1u << 5;

// driver/gpio/gpio.c, gpio_config()
enum uint GMODE_OUTPUT              = 0x00;
enum uint GMODE_INPUT               = 0x0C;
enum uint GMODE_INPUT_PULLDOWN      = 0x2C;
enum uint GMODE_INPUT_PULLUP        = 0x3C;
enum uint GMODE_SECOND_FUNC         = 0x48;
enum uint GMODE_SECOND_FUNC_PULL_UP = 0x78;
enum uint GMODE_HIGH_Z              = 0x08;

uint reg_read(uint addr)
{
    return volatileLoad(cast(uint*)(cast(size_t)addr));
}

void reg_write(uint addr, uint val)
{
    volatileStore(cast(uint*)(cast(size_t)addr), val);
}
