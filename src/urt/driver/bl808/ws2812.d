// WS2812 chains bit-banged on the D0 core (C906 at 480 MHz), with interrupts off while a chain is sent.
// The loop body (addi + bnez compressed) costs about two cycles, which sets the loop counts below.
module urt.driver.bl808.ws2812;

import core.volatile : volatileStore;

import urt.driver.gpio : GpioLine;
import urt.driver.irq : irq_critical;
import urt.result : InternalResult, Result;

@nogc nothrow:


enum uint num_ws2812 = 1;

Result ws2812_hw_open(uint chain, GpioLine line)
{
    if (line.chip != 0)
        return InternalResult.unsupported;
    _pin = line.line;
    raw_set(_pin, false);
    return Result.success;
}

bool ws2812_hw_send(uint chain, const(uint)[] grb)
{
    auto guard = irq_critical();
    foreach (pixel; grb)
    {
        foreach (i; 0 .. 24)
            send_bit((pixel & (0x80_0000 >> i)) != 0);
    }
    raw_set(_pin, false);
    return true;
}

void ws2812_hw_close(uint chain)
{
    raw_set(_pin, false);
}


private:

// WS2812B: T0H 400ns, T0L 850ns, T1H 800ns, T1L 450ns (+/- 150ns); 2.08ns a cycle, two cycles a loop.
enum uint t0h_loops = 80;
enum uint t0l_loops = 170;
enum uint t1h_loops = 160;
enum uint t1l_loops = 90;

enum uint glb_base          = 0x2000_0000;
enum uint gpio_cfg_base     = glb_base + 0x8C4;
enum uint gpio_fun_swgpio   = 11;
enum uint gpio_output_en    = 1u << 11;
enum uint gpio_output_high  = 1u << 17;

__gshared uint _pin;

pragma(inline, true)
void delay_loops(ulong n)
{
    import ldc.llvmasm;
    __asm!ulong(`
        1: addi $0, $0, -1
           bnez $0, 1b
    `, "=r,0", n);
}

// A direct config write: the bit-bang is cycle-counted, so it skips the read-modify-write and asserts
// that gpio_output_set does.
pragma(inline, true)
void raw_set(uint pin, bool high)
{
    uint cfg = gpio_fun_swgpio | gpio_output_en;
    if (high)
        cfg |= gpio_output_high;
    volatileStore(cast(uint*)(gpio_cfg_base + pin * 4), cfg);
}

void send_bit(bool one)
{
    raw_set(_pin, true);
    delay_loops(one ? t1h_loops : t0h_loops);
    raw_set(_pin, false);
    delay_loops(one ? t1l_loops : t0l_loops);
}
