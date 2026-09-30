// WS2812 chains on the GPIO block's transmit FIFO. Each 16-bit word is one bit period for a group of 16 pins,
// and the hardware shapes each bit as a code0 or code1 pulse counted in XCLK, so no core keeps the timing.
module urt.driver.bl_common.ws2812;

version (BL808):

import core.volatile : volatileLoad, volatileStore;

import urt.driver.bl_common.clock : xclk_hz;
import urt.driver.gpio : GpioLine;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_ws2812 = 1;

Result ws2812_hw_open(uint chain, GpioLine line)
{
    if (line.chip != 0 || line.line >= 46)
        return InternalResult.unsupported;
    _line = cast(ubyte)line.line;
    write(cfg142, 0);
    write(cfg143, tx_fifo_clr);
    write(cfg142, code1_high << 24 | code0_high << 16 | code_total << 7 | tx_en);
    write(gpio_cfg + _line * 4, func_swgpio << 8 | output_en | mode_buffer << 30);
    return Result.success;
}

void ws2812_hw_send(uint chain, const(uint)[] grb)
{
    immutable ushort bit = cast(ushort)(1 << _line % 16);
    foreach (pixel; grb)
    {
        foreach (i; 0 .. 24)
        {
            while ((read(cfg143) >> 8 & 0xFF) == 0)
            {}
            write(cfg144, pixel & 0x80_0000 >> i ? bit : 0);
        }
    }
}

void ws2812_hw_close(uint chain)
{
    while ((read(cfg143) >> 8 & 0xFF) < fifo_depth)
    {}
    write(gpio_cfg + _line * 4, func_swgpio << 8 | output_en);
    write(cfg142, 0);
}


private:

// WS2812B: 1.25us a bit, high 400ns for a zero and 800ns for a one.
enum uint code_total = xclk_hz / 800_000;
enum uint code0_high = code_total * 8 / 25;
enum uint code1_high = code_total * 16 / 25;

enum uint fifo_depth = 128;

enum uint gpio_cfg = 0x2000_08C4;
enum uint cfg142 = 0x2000_0AFC;
enum uint cfg143 = 0x2000_0B00;
enum uint cfg144 = 0x2000_0B04;

enum uint tx_en = 1 << 0;
enum uint tx_fifo_clr = 1 << 2;
enum uint func_swgpio = 11;
enum uint output_en = 1 << 6;
enum uint mode_buffer = 2;

__gshared ubyte _line;

uint read(uint reg)
    => volatileLoad(cast(uint*)reg);

void write(uint reg, uint value)
{
    volatileStore(cast(uint*)reg, value);
}

static assert(code_total == 50 && code0_high == 16 && code1_high == 32);
