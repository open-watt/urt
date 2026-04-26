// BK7231 GPIO. Per-pin config registers at GPIO_BASE + pin*4 (function/
// input/output/pull). A 2-bit perial-mode field per pin in GPIO_FUNC_CFG
// selects the peripheral when GMODE_FUNC_EN is set; only pins 0..15 have
// a perial-mode field.
//
// Pin numbering: linear 0..31.
//
// Software GPIO primitives are unimplemented (need full per-pin config
// bit definitions from the BK7231 reference manual). gpio_set_function
// works and is sufficient for UART pin mux today.
module urt.driver.bk7231.gpio;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.gpio : Pull, DriveMode;

@nogc nothrow:


enum uint num_gpio = 32;
enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = true;


uint gpio_count() => num_gpio;


void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    cast(void) pin; cast(void) initial; cast(void) mode;
    assert(false, "bk7231 gpio: gpio_output_init not yet implemented");
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    cast(void) pin; cast(void) pull;
    assert(false, "bk7231 gpio: gpio_input_init not yet implemented");
}

void gpio_output_set(uint pin, bool value)
{
    cast(void) pin; cast(void) value;
    assert(false, "bk7231 gpio: gpio_output_set not yet implemented");
}

void gpio_output_toggle(uint pin)
{
    cast(void) pin;
    assert(false, "bk7231 gpio: gpio_output_toggle not yet implemented");
}

bool gpio_input_read(uint pin)
{
    cast(void) pin;
    assert(false, "bk7231 gpio: gpio_input_read not yet implemented");
    return false;
}

void gpio_set_pull(uint pin, Pull pull)
{
    cast(void) pin; cast(void) pull;
    assert(false, "bk7231 gpio: gpio_set_pull not yet implemented");
}

void gpio_release(uint pin)
{
    cast(void) pin;
    assert(false, "bk7231 gpio: gpio_release not yet implemented");
}

void gpio_set_function(uint pin, uint function_id, Pull pull = Pull.none, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < 16, "bk7231 gpio: perial-mode field only exists for pins 0..15");
    assert(function_id < 4, "bk7231 gpio: perial mode is 2-bit (0..3)");
    assert(mode == DriveMode.push_pull, "bk7231 gpio: open-drain not supported");

    uint cfg = GMODE_FUNC_EN | GMODE_OUTPUT_EN;
    if (pull == Pull.up)
        cfg |= GMODE_PULL_EN | GMODE_PULL_UP;
    else if (pull == Pull.down)
        cfg |= GMODE_PULL_EN;
    reg_write(GPIO_BASE + pin * 4, cfg);

    uint func_cfg = reg_read(GPIO_FUNC_CFG);
    func_cfg &= ~(0x3u << (pin * 2));
    func_cfg |= (function_id & 0x3u) << (pin * 2);
    reg_write(GPIO_FUNC_CFG, func_cfg);
}


private:

enum uint GPIO_BASE     = 0x0080_2800;
enum uint GPIO_FUNC_CFG = GPIO_BASE + 32 * 4;

// Bit positions inferred from SDK gpio_enable_second_function value 0x78.
enum uint GMODE_FUNC_EN   = 1u << 3;
enum uint GMODE_OUTPUT_EN = 1u << 4;
enum uint GMODE_PULL_EN   = 1u << 5;
enum uint GMODE_PULL_UP   = 1u << 6;

uint reg_read(uint addr)
{
    return volatileLoad(cast(uint*)(cast(size_t)addr));
}

void reg_write(uint addr, uint val)
{
    volatileStore(cast(uint*)(cast(size_t)addr), val);
}
