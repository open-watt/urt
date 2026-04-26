// ESP32 software GPIO via ESP-IDF (driver/gpio.h) through ow_shim.c.
//
// Peripheral function routing on ESP32 uses the GPIO matrix per-signal,
// not per-pin function selection, so has_pin_function_muxing = false
// and gpio_set_function is not provided. Peripheral drivers (UART, SPI,
// I2C, etc.) route their own signals via the IDF.
//
// Pin numbering: linear 0..SOC_GPIO_PIN_COUNT-1. The compile-time
// num_gpio is a conservative upper bound; gpio_count() returns the
// actual SOC_GPIO_PIN_COUNT for the active chip variant.
module urt.driver.esp32.gpio;

import urt.driver.gpio : Pull, DriveMode;

nothrow @nogc:


enum uint num_gpio = 64;
enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = false;


uint gpio_count() => ow_gpio_count();

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(mode == DriveMode.push_pull, "esp32 gpio: open-drain not exposed via this API");
    ow_gpio_output_init(int(pin), initial ? 1 : 0);
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    ow_gpio_input_init(int(pin), int(pull));
}

void gpio_output_set(uint pin, bool value)
{
    ow_gpio_output_set(int(pin), value ? 1 : 0);
}

void gpio_output_toggle(uint pin)
{
    ow_gpio_output_set(int(pin), ow_gpio_input_read(int(pin)) ? 0 : 1);
}

bool gpio_input_read(uint pin)
{
    return ow_gpio_input_read(int(pin)) != 0;
}

void gpio_set_pull(uint pin, Pull pull)
{
    ow_gpio_set_pull(int(pin), int(pull));
}

void gpio_release(uint pin)
{
    ow_gpio_release(int(pin));
}


private:

extern(C) nothrow @nogc
{
    void ow_gpio_output_init(int pin, int initial);
    void ow_gpio_input_init(int pin, int pull);
    void ow_gpio_output_set(int pin, int value);
    int  ow_gpio_input_read(int pin);
    void ow_gpio_set_pull(int pin, int pull);
    void ow_gpio_release(int pin);
    uint ow_gpio_count();
}
