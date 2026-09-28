// GPIO driver. Software-GPIO primitives plus per-pin function muxing
// for SoCs that support it (BL6xx, BL8xx, BK7231, RP2350, STM32). On
// targets that route via signal matrix (ESP32) or have no pin concept
// (Windows/POSIX without sysfs), has_pin_function_muxing is false and
// gpio_set_function is not declared.
//
// Pin numbering is a flat uint per SoC. STM32 packs port and pin as
// (port * 16 + pin_in_port) so PA9 = 9, PB3 = 19, PE15 = 79. Other
// SoCs use linear pin numbers from 0.
//
// num_gpio is a compile-time upper bound (exact on SoCs with fixed
// pin counts; on hosted targets like Linux SBC it is a static cap and
// gpio_count() returns the actual runtime number).
//
// Function bodies live in <soc>/gpio.d, pulled in by the version
// dispatch below. Each backend exports:
//   uint gpio_count();
//   void gpio_output_init(uint pin, bool initial = false, DriveMode = push_pull);
//   void gpio_input_init(uint pin, Pull = none);
//   void gpio_output_set(uint pin, bool value);
//   void gpio_output_toggle(uint pin);
//   bool gpio_input_read(uint pin);
//   void gpio_set_pull(uint pin, Pull);
//   void gpio_release(uint pin);
//   void gpio_set_function(uint pin, uint function_id, Pull = none, DriveMode = push_pull);
//
// function_id is opaque per chip; peripheral drivers know the right
// value. The peripheral owns I/O direction once muxed.
//
// A backend may also implement the realtime edge sampler by setting has_gpio_sampler = true and exporting:
//   Result gpio_sampler_open(uint chip, uint line, out GpioSampler, Pull, uint debounce_us);
//   GpioSampler.drain(GpioEdge[], out size_t)   non-blocking, events plus source status
//   GpioSampler.close()
//   linux also exposes GpioSampler.fd for readiness registration; the sampler owns all reads so
//     socket closure and device-drained semantics remain backend-specific.
// chip selects the controller on hosted targets (/dev/gpiochipN); SoC backends have a single
// implicit chip (chip == 0), line is the offset on it.
module urt.driver.gpio;

import urt.atomic : MemoryOrder, atomicLoad, atomicOp, atomicStore;
import urt.attribute : critical;
import urt.result : InternalResult, Result;

version (Bouffalo)
    public import urt.driver.bl_common.gpio;
else version (Beken)
    public import urt.driver.bk7231.gpio;
else version (Espressif)
    public import urt.driver.esp32.gpio;
else version (STM32)
    public import urt.driver.stm32.gpio;
else version (linux)
    public import urt.driver.posix.gpio;
else version (MT7621)
    public import urt.driver.mt7621.gpio;
else
{
    enum uint num_gpio = 0;
    enum bool has_pull_up = false;
    enum bool has_pull_down = false;
    enum bool has_open_drain = false;
    enum bool has_pin_function_muxing = false;
    enum bool has_gpio_sampler = false;

    uint gpio_count() nothrow @nogc => 0;
}

version (Espressif) {}
else version (MT7621) {}
else enum uint num_gpio_interrupts = 0;

nothrow @nogc:

enum Pull : ubyte
{
    none,
    up,
    down,
}

enum DriveMode : ubyte
{
    push_pull,
    open_drain,
}

struct GpioLine
{
    uint chip;
    uint line = uint.max;
}

enum GpioInterruptTrigger : ubyte
{
    rising,
    falling,
    change,
    high,
    low,
}

struct GpioInterruptConfig
{
    GpioLine input;
    GpioInterruptTrigger trigger;
}

struct GpioInterrupt
{
    ubyte port = ubyte.max;
}

enum GpioCallbackContext : ubyte
{
    thread,
    interrupt,
}

alias GpioInterruptCallback = bool function(GpioInterrupt interrupt, GpioCallbackContext context) nothrow @nogc;

// Backends retain this plain function pointer in static driver state; an interrupt-context callback must reside in local instruction memory.
bool is_open(ref const GpioInterrupt interrupt)
{
    return interrupt.port != ubyte.max;
}

Result gpio_interrupt_open(ref GpioInterrupt interrupt, ubyte port, ref const GpioInterruptConfig config)
{
    static if (num_gpio_interrupts == 0)
        return InternalResult.unsupported;
    else
    {
        if (interrupt.is_open)
            return InternalResult.already_exists;
        if (port >= num_gpio_interrupts || config.input.line == uint.max || config.trigger > GpioInterruptTrigger.low)
            return InternalResult.invalid_parameter;
        immutable open = atomicLoad!(MemoryOrder.acquire)(_open_ports);
        if (open & (1u << port))
            return InternalResult.already_exists;
        foreach (p; 0 .. num_gpio_interrupts)
        {
            if ((open & (1u << p)) && _port_lines[p] == config.input)
                return InternalResult.already_exists;
        }
        Result result = gpio_interrupt_hw_open(port, config);
        if (!result)
            return result;
        _port_lines[port] = config.input;
        atomicOp!"|="(_open_ports, 1u << port);
        interrupt.port = port;
        return Result.success;
    }
}

void gpio_interrupt_set_callback(ref GpioInterrupt interrupt, GpioInterruptCallback callback)
{
    static if (num_gpio_interrupts == 0)
        assert(false, "no GPIO interrupts on this platform");
    else
    {
        assert(interrupt.is_open, "GPIO interrupt is not open");
        atomicStore!(MemoryOrder.release)(_callbacks[interrupt.port], cast(size_t)callback);
        static if (__traits(compiles, gpio_interrupt_hw_listen(0u, true)))
            gpio_interrupt_hw_listen(interrupt.port, callback !is null);
    }
}

void gpio_interrupt_close(ref GpioInterrupt interrupt)
{
    static if (num_gpio_interrupts != 0)
    {
        if (interrupt.is_open)
        {
            atomicStore!(MemoryOrder.release)(_callbacks[interrupt.port], 0);
            gpio_interrupt_hw_close(interrupt.port, _port_lines[interrupt.port].line);
            atomicOp!"&="(_open_ports, ~(1u << interrupt.port));
        }
    }
    interrupt = GpioInterrupt();
}

// Called by the backend's interrupt for an open port.
@critical bool gpio_interrupt_dispatch(uint port)
{
    if (port >= num_gpio_interrupts)
        return false;
    auto callback = cast(GpioInterruptCallback)atomicLoad!(MemoryOrder.acquire)(_callbacks[port]);
    return callback !is null && callback(GpioInterrupt(cast(ubyte)port), GpioCallbackContext.interrupt);
}

enum GpioDrainStatus : ubyte
{
    drained,
    closed,
    error,
}


// One captured edge from the realtime sampler: a native sample-clock tick with the level in bit 0,
// so a record is 8 bytes and raw values stay monotonic in time. See the sampler contract at the top.
struct GpioEdge
{
nothrow @nogc:
    ulong raw;      // (tick << 1) | level: native sample-clock tick (GpioSampler.clock_hz), level in bit 0

    this(ulong tick, bool level)
    {
        raw = (tick << 1) | ulong(level);
    }

    ulong tick() const pure => raw >> 1;
    bool level() const pure => (raw & 1) != 0;
}


unittest
{
    static assert(is(typeof(num_gpio) == uint));
    static assert(is(typeof(has_pull_up) == bool));
    static assert(is(typeof(has_pull_down) == bool));
    static assert(is(typeof(has_open_drain) == bool));
    static assert(is(typeof(has_pin_function_muxing) == bool));

    // Pull encoding is load-bearing: bl808/bl618 backends shift the
    // ordinal directly into GPIO_CFG bits[25:24].
    static assert(Pull.none == 0);
    static assert(Pull.up   == 1);
    static assert(Pull.down == 2);

    static assert(DriveMode.push_pull  == 0);
    static assert(DriveMode.open_drain == 1);

    // gpio_count() is callable on every backend (returns 0 on fallback).
    gpio_count();

    // A backend nominates a free input-capable line as `test_gpio_line` for these to run on its hardware.
    static if (num_gpio_interrupts != 0 && __traits(compiles, test_gpio_line))
    {
        GpioInterruptConfig cfg;
        cfg.input = GpioLine(0, test_gpio_line);
        cfg.trigger = GpioInterruptTrigger.rising;

        {
            GpioInterruptConfig other = cfg;
            other.input.line = (test_gpio_line + 1) % num_gpio;

            GpioInterrupt a, b;
            assert(gpio_interrupt_open(a, 0, cfg));
            assert(!gpio_interrupt_open(b, 0, other) && !b.is_open, "a second line opened on an owned port");
            assert(!gpio_interrupt_open(b, 1, cfg) && !b.is_open, "a second port opened on an owned line");
            gpio_interrupt_close(a);
            assert(gpio_interrupt_open(b, 0, cfg), "the port did not come back after close");
            gpio_interrupt_close(b);
            assert(atomicLoad(_open_ports) == 0);
        }

        {
            import core.volatile : volatileLoad;
            import urt.driver.irq : irq_global_disable, irq_global_enable, irq_global_set;

            __gshared uint fires;
            __gshared GpioInterrupt irq;
            static bool once(GpioInterrupt, GpioCallbackContext)
            {
                gpio_interrupt_close(irq);
                ++fires;
                return false;
            }

            fires = 0;
            gpio_input_init(test_gpio_line);
            GpioInterruptConfig held = cfg;
            held.trigger = gpio_input_read(test_gpio_line) ? GpioInterruptTrigger.high : GpioInterruptTrigger.low;
            immutable prior = irq_global_disable();
            assert(gpio_interrupt_open(irq, 0, held));
            gpio_interrupt_set_callback(irq, &once);
            irq_global_enable();
            foreach (_; 0 .. 100_000)
            {
                if (volatileLoad(&fires))
                    break;
            }
            irq_global_set(prior);
            assert(volatileLoad(&fires) == 1, "an interrupt on the level the line holds was not delivered once");
            assert(!irq.is_open && atomicLoad(_open_ports) == 0, "closing from the callback left the port open");

            GpioInterrupt again;
            assert(gpio_interrupt_open(again, 0, cfg), "closing from the callback left the line owned");
            gpio_interrupt_close(again);
        }
    }
}


private:

static assert(num_gpio_interrupts <= 32);

// A callback may close its port from the ISR while the foreground opens another.
shared uint _open_ports;
__gshared GpioLine[num_gpio_interrupts] _port_lines;
shared size_t[num_gpio_interrupts] _callbacks;
