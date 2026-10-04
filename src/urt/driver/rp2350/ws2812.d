// WS2812 chains on PIO0, one state machine each. The program is the pico-examples ws2812 one:
// ten cycles a bit at 8 MHz, high for 2 cycles then 5 more for a one, so the hardware keeps the timing.
//     out x, 1       side 0 [2]
//     jmp !x 3       side 1 [1]
//     jmp 0          side 1 [4]
//     nop            side 0 [4]
module urt.driver.rp2350.ws2812;

import urt.driver.gpio : GpioLine;
import urt.driver.rp2350 : clk_sys_hz, gpio_route, mmio_read, mmio_write, reset_io_bank0, reset_pads_bank0, reset_pio0, reset_pulse, unreset_wait;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_ws2812 = 4;

Result ws2812_hw_open(uint chain, GpioLine line)
{
    if (line.chip != 0 || line.line >= 32)
        return InternalResult.unsupported;
    if (!_loaded)
    {
        unreset_wait(reset_io_bank0 | reset_pads_bank0);
        reset_pulse(reset_pio0);
        foreach (i, word; program)
            mmio_write(pio0_base + instr_mem + i * 4, word);
        _loaded = true;
    }
    mmio_write(pio0_base + ctrl, mmio_read(pio0_base + ctrl) & ~(1u << chain));
    mmio_write(sm(chain, clkdiv), clock_div);
    mmio_write(sm(chain, execctrl), (program.length - 1) << 12);
    // a restart keeps the FIFO, so words queued before a close would lead the next frame; a join change clears it
    enum uint shift = shift_fjoin_tx | 24 << 25 | shift_autopull;
    mmio_write(sm(chain, shiftctrl), shift | shift_fjoin_rx);
    mmio_write(sm(chain, shiftctrl), shift);
    mmio_write(sm(chain, pinctrl), 1 << 29 | 1 << 26 | line.line << 10 | line.line << 5);
    mmio_write(sm(chain, instr), set_pindirs_out);
    mmio_write(sm(chain, instr), jmp_start);
    gpio_route(line.line, funcsel_pio0, false);
    mmio_write(pio0_base + ctrl, mmio_read(pio0_base + ctrl) | 1u << (4 + chain) | 1u << (8 + chain) | 1u << chain);
    _lines[chain] = cast(ubyte)line.line;
    return Result.success;
}

bool ws2812_hw_send(uint chain, const(uint)[] grb)
{
    foreach (pixel; grb)
    {
        if (!wait(fstat, 1u << (16 + chain), false))
            return false;
        mmio_write(pio0_base + txf + chain * 4, pixel << 8);
    }
    return true;
}

// A send only queues words. Once the FIFO is empty the state machine holds the last word; TXSTALL is raised
// while it sits stalled for want of another, so cleared then it returns only when the last bit has left.
void ws2812_hw_close(uint chain)
{
    wait(fstat, 1u << (24 + chain), true);
    mmio_write(pio0_base + fdebug, 1u << (24 + chain));
    wait(fdebug, 1u << (24 + chain), true);
    mmio_write(pio0_base + ctrl, mmio_read(pio0_base + ctrl) & ~(1u << chain));
    gpio_route(_lines[chain], funcsel_null, false);
}


private:

static immutable ushort[4] program = [ 0x6221, 0x1123, 0x1400, 0xA442 ];

enum ulong pio0_base = 0x5020_0000;
enum uint ctrl      = 0x000;
enum uint fstat     = 0x004;
enum uint fdebug    = 0x008;
enum uint txf       = 0x010;
enum uint instr_mem = 0x048;
enum uint clkdiv    = 0x0C8;
enum uint execctrl  = 0x0CC;
enum uint shiftctrl = 0x0D0;
enum uint instr     = 0x0D8;
enum uint pinctrl   = 0x0DC;
enum uint sm_stride = 0x18;

enum uint shift_fjoin_tx = 1 << 30;
enum uint shift_fjoin_rx = 1u << 31;
enum uint shift_autopull = 1 << 17;
enum ushort set_pindirs_out = 0xE081;
enum ushort jmp_start = 0x0000;
enum uint funcsel_pio0 = 6;
enum uint funcsel_null = 0x1F;

// clk_sys over 8 MHz, as 16.8 fixed point
enum uint clock_div = cast(uint)(ulong(clk_sys_hz) * 256 / 8_000_000) << 8;

__gshared bool _loaded;
__gshared ubyte[num_ws2812] _lines;

// A stalled state machine must not hang the main loop; a chain's longest frame is well inside this.
bool wait(uint reg, uint bit, bool set)
{
    import urt.time : getTime, msecs;
    immutable deadline = getTime() + 2.msecs;
    while (((mmio_read(pio0_base + reg) & bit) != 0) != set)
    {
        if (getTime() > deadline)
            return false;
    }
    return true;
}

ulong sm(uint chain, uint reg)
    => pio0_base + reg + chain * sm_stride;


unittest
{
    static assert(clock_div == (18 << 16 | 192 << 8), "150 MHz over 8 MHz is 18.75");
}
