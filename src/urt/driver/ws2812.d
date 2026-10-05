// WS2812 pixel chains. One data line carries a chain of pixels, each a 24-bit colour; a chain is sent
// whole whenever a pixel changes and latches after the line has been low for ws2812_latch.
// Several users may share a chain, each owning its own pixels.
//
// A backend exports:
//   enum uint num_ws2812;                      // chains it can drive at once
//   Result ws2812_hw_open(uint chain, GpioLine line);
//   bool ws2812_hw_send(uint chain, const(uint)[] grb);   // one pixel per word, in the low 24 bits; false if cut short
//   void ws2812_hw_close(uint chain);
module urt.driver.ws2812;

import urt.driver.gpio : GpioLine;
import urt.result : InternalResult, Result;
import urt.time;

version (RP2350)
    public import urt.driver.rp2350.ws2812;
else version (BL808)
    public import urt.driver.bl808.ws2812;
else
    enum uint num_ws2812 = 0;

enum uint ws2812_max_pixels = 16;
enum ws2812_latch = 280.usecs;

nothrow @nogc:


struct Ws2812
{
    ubyte chain = ubyte.max;
}

bool is_open(ref const Ws2812 ws) pure
{
    return ws.chain != ubyte.max;
}

// Joins the chain on line, opening it if this is its first user.
Result ws2812_open(ref Ws2812 ws, GpioLine line)
{
    static if (num_ws2812 == 0)
        return InternalResult.unsupported;
    else
    {
        if (ws.is_open)
            return InternalResult.already_exists;
        foreach (i, ref c; _chains)
        {
            if (c.users && c.line == line)
            {
                ++c.users;
                ws.chain = cast(ubyte)i;
                return Result.success;
            }
        }
        foreach (i, ref c; _chains)
        {
            if (c.users)
                continue;
            Result result = ws2812_hw_open(cast(uint)i, line);
            if (!result)
                return result;
            c = Chain(line, 1);
            ws.chain = cast(ubyte)i;
            return Result.success;
        }
        return InternalResult.failed;
    }
}

// Sets pixel index to 0xRRGGBB and sends the chain; the chain grows to reach index.
Result ws2812_set(ref Ws2812 ws, uint index, uint rgb)
{
    static if (num_ws2812 == 0)
        return InternalResult.unsupported;
    else
    {
        if (!ws.is_open || index >= ws2812_max_pixels)
            return InternalResult.invalid_parameter;
        Chain* c = &_chains[ws.chain];
        immutable uint grb = (rgb >> 8 & 0xFF) << 16 | (rgb >> 16 & 0xFF) << 8 | (rgb & 0xFF);
        if (index < c.length && c.grb[index] == grb && !c.unsent)
            return Result.success;
        c.grb[index] = grb;
        if (index >= c.length)
            c.length = cast(ubyte)(index + 1);
        while (getTime() < c.latched)
        {}
        c.unsent = !ws2812_hw_send(ws.chain, c.grb[0 .. c.length]);
        c.latched = getTime() + usecs(c.length * pixel_us) + ws2812_latch;
        return c.unsent ? InternalResult.failed : Result.success;
    }
}

void ws2812_close(ref Ws2812 ws)
{
    static if (num_ws2812 != 0)
    {
        if (ws.is_open && --_chains[ws.chain].users == 0)
        {
            ws2812_hw_close(ws.chain);
            while (getTime() < _chains[ws.chain].latched)
            {}
        }
    }
    ws = Ws2812();
}


private:

enum uint pixel_us = 30;

struct Chain
{
    GpioLine line;
    ubyte users;
    ubyte length;
    bool unsent;
    MonoTime latched;
    uint[ws2812_max_pixels] grb;
}

static if (num_ws2812 != 0)
    __gshared Chain[num_ws2812] _chains;
