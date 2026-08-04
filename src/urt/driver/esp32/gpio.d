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

import urt.atomic : MemoryOrder, atomicLoad, atomicStore;
import urt.attribute : critical;
import urt.driver.gpio : DriveMode, GpioCallbackContext, GpioInterrupt, GpioInterruptCallback, GpioInterruptConfig, GpioInterruptTrigger, Pull;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_gpio = 64;
enum bool has_pull_up = true;
enum bool has_pull_down = true;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = false;
enum bool has_gpio_sampler = false;   // TODO: RMT capture
version (ESP32) enum uint num_gpio_interrupts = 2;
else enum uint num_gpio_interrupts = 0;


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

@critical void gpio_output_set(uint pin, bool value)
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

Result gpio_interrupt_hw_open(uint port, ref const GpioInterruptConfig config)
{
    if (config.input.chip != 0)
        return InternalResult.unsupported;
    return ow_gpio_interrupt_open(port, config.input.line, cast(uint)config.trigger) == 0 ? Result.success : InternalResult.failed;
}

void gpio_interrupt_hw_set_callback(uint port, GpioInterruptCallback callback)
{
    if (callback is null)
    {
        ow_gpio_interrupt_set_callback(port, null);
        atomicStore!(MemoryOrder.release)(_interrupt_callbacks[port], 0);
    }
    else
    {
        atomicStore!(MemoryOrder.release)(_interrupt_callbacks[port], cast(size_t)callback);
        ow_gpio_interrupt_set_callback(port, &gpio_interrupt);
    }
}

void gpio_interrupt_hw_close(uint port)
{
    gpio_interrupt_hw_set_callback(port, null);
    ow_gpio_interrupt_close(port);
}


private:

shared size_t[num_gpio_interrupts] _interrupt_callbacks;

@critical extern(C) bool gpio_interrupt(uint port) nothrow @nogc
{
    if (port >= num_gpio_interrupts)
        return false;
    GpioInterruptCallback callback = cast(GpioInterruptCallback)atomicLoad!(MemoryOrder.acquire)(_interrupt_callbacks[port]);
    return callback !is null ? callback(GpioInterrupt(cast(ubyte)port), GpioCallbackContext.interrupt) : false;
}

extern(C) alias OwGpioInterruptCallback = bool function(uint port) nothrow @nogc;

extern(C) nothrow @nogc
{
    void ow_gpio_output_init(int pin, int initial);
    void ow_gpio_input_init(int pin, int pull);
    void ow_gpio_output_set(int pin, int value);
    int  ow_gpio_input_read(int pin);
    void ow_gpio_set_pull(int pin, int pull);
    void ow_gpio_release(int pin);
    uint ow_gpio_count();
    int ow_gpio_interrupt_open(uint port, uint input_gpio, uint trigger);
    void ow_gpio_interrupt_set_callback(uint port, OwGpioInterruptCallback callback);
    void ow_gpio_interrupt_close(uint port);
}
