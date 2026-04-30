// GPIO_CFG register at GLB_BASE + 0x8C4 + pin*4:
//   bits[4:0] = function (11 = SWGPIO)
//   bit[6]    = input enable
//   bit[11]   = output enable
//   bit[17]   = output value
//   bit[18]   = input value (read-only)
//   bit[24]   = pull-up enable
//   bit[25]   = pull-down enable
//
// Pin numbering: linear 0..46.
//
// Also contains M1s Dock WS2812 LED helpers; will move to a portable
// baremetal/ws2812 driver once the GPIO API is on other SoCs.
module urt.driver.bl808.gpio;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.gpio : Pull, DriveMode;

@nogc nothrow:


enum uint num_gpio = 47;
enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = true;


uint gpio_count() => num_gpio;


void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    assert(mode == DriveMode.push_pull, "bl808 gpio: open-drain not supported");
    uint cfg = GPIO_FUN_SWGPIO | GPIO_OUTPUT_EN;
    if (initial)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO | GPIO_INPUT_EN | (uint(pull) << 24));
}

void gpio_output_set(uint pin, bool value)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    uint cfg = gpio_cfg_read(pin) & ~GPIO_OUTPUT_HIGH;
    if (value)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void gpio_output_toggle(uint pin)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    gpio_cfg_write(pin, gpio_cfg_read(pin) ^ GPIO_OUTPUT_HIGH);
}

bool gpio_input_read(uint pin)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    return (gpio_cfg_read(pin) & GPIO_INPUT_VALUE) != 0;
}

void gpio_set_pull(uint pin, Pull pull)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    uint cfg = gpio_cfg_read(pin) & ~(GPIO_PULL_UP | GPIO_PULL_DOWN);
    gpio_cfg_write(pin, cfg | (uint(pull) << 24));
}

void gpio_release(uint pin)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO);
}

void gpio_set_function(uint pin, uint function_id, Pull pull = Pull.none, DriveMode mode = DriveMode.push_pull)
{
    assert(pin < num_gpio, "gpio: pin out of range");
    assert(function_id <= GPIO_FUN_MASK, "gpio: function_id out of range (5-bit field)");
    assert(mode == DriveMode.push_pull, "bl808 gpio: open-drain not supported");
    uint cfg = (function_id & GPIO_FUN_MASK) | GPIO_INPUT_EN | (uint(pull) << 24);
    gpio_cfg_write(pin, cfg);
}


void ws2812_send(uint pin, ubyte r, ubyte g, ubyte b)
{
    gpio_output_init(pin);
    ws2812_byte(pin, g);   // GRB order
    ws2812_byte(pin, r);
    ws2812_byte(pin, b);
    ws2812_raw_set(pin, false);
    delay_loops(WS_RESET_US * 200);
}

void led_set(ubyte r, ubyte g, ubyte b)
{
    ws2812_send(WS2812_PIN, r, g, b);
}

void led_red()   { led_set(32, 0,  0);  }
void led_green() { led_set(0,  32, 0);  }
void led_blue()  { led_set(0,  0,  32); }
void led_white() { led_set(16, 16, 16); }
void led_off()   { led_set(0,  0,  0);  }


private:

enum uint GLB_BASE      = 0x2000_0000;
enum uint GPIO_CFG_BASE = GLB_BASE + 0x8C4;

enum uint GPIO_FUN_SWGPIO   = 11;
enum uint GPIO_FUN_MASK     = 0x1Fu;
enum uint GPIO_INPUT_EN     = 1u << 6;
enum uint GPIO_OUTPUT_EN    = 1u << 11;
enum uint GPIO_OUTPUT_HIGH  = 1u << 17;
enum uint GPIO_INPUT_VALUE  = 1u << 18;
enum uint GPIO_PULL_UP      = 1u << 24;
enum uint GPIO_PULL_DOWN    = 1u << 25;

// Pull values map directly to GPIO_CFG bits[25:24]: none=0, up=bit24, down=bit25.
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


// WS2812B spec: T0H=400ns, T0L=850ns, T1H=800ns, T1L=450ns (+/- 150ns).
// At 480MHz: 1 cycle ~= 2.08ns. Loop body (addi + bnez compressed) ~= 2
// cycles, so divide by 2.
enum uint WS2812_PIN   = 8;          // M1s Dock board
enum uint WS_T0H_LOOPS = 80;
enum uint WS_T0L_LOOPS = 170;
enum uint WS_T1H_LOOPS = 160;
enum uint WS_T1L_LOOPS = 90;
enum uint WS_RESET_US  = 60;         // >50us required by spec

pragma(inline, true)
void delay_loops(ulong n)
{
    import ldc.llvmasm;
    __asm!ulong(`
        1: addi $0, $0, -1
           bnez $0, 1b
    `, "=r,0", n);
}

void ws2812_raw_set(uint pin, bool high)
{
    uint cfg = GPIO_FUN_SWGPIO | GPIO_OUTPUT_EN;
    if (high)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

void ws2812_bit(uint pin, bool one)
{
    if (one)
    {
        ws2812_raw_set(pin, true);
        delay_loops(WS_T1H_LOOPS);
        ws2812_raw_set(pin, false);
        delay_loops(WS_T1L_LOOPS);
    }
    else
    {
        ws2812_raw_set(pin, true);
        delay_loops(WS_T0H_LOOPS);
        ws2812_raw_set(pin, false);
        delay_loops(WS_T0L_LOOPS);
    }
}

void ws2812_byte(uint pin, ubyte b)
{
    foreach (i; 0 .. 8)
        ws2812_bit(pin, (b & (0x80 >> i)) != 0);
}
