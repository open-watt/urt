// BL808 PWM: two blocks of four channels, each channel with a positive and a negative output. A port is
// block * 4 + channel. Pin n reaches output n % 8 of either block (function 16 or 17): channel (n % 8) / 2,
// negative on odd pins, whose polarity is flipped so both show the channel's duty. The channels of a block
// share its counter, so they must agree on period and clock.
module urt.driver.bl808.pwm;

import core.volatile : volatileLoad, volatileStore;

import urt.driver.bl808.clock : xclk_hz;
import urt.driver.bl_common.gpio : gpio_release, gpio_set_function;
import urt.driver.gpio : GpioLine;
import urt.driver.pwm : PwmConfig;
import urt.result : InternalResult, Result;

nothrow @nogc:

enum uint num_hw_pwm = 8;

bool pwm_hw_reaches(uint port, GpioLine line)
    => line.chip == 0 && line.line < 46 && line.line % 8 / 2 == port % 4;

bool pwm_hw_shares(uint a, uint b)
    => a / 4 == b / 4;

Result pwm_hw_open(uint port, ref const PwmConfig config)
{
    ushort div;
    if (!pwm_hw_reaches(port, config.output) || config.period > 0xFFFF || !clock_divider(config.frequency, config.period, div))
        return InternalResult.invalid_parameter;

    Block* b = &_blocks[port / 4];
    immutable uint base = block_base(port);
    if (b.users && (b.period != config.period || b.div != div))
        return InternalResult.failed;

    if (!b.users)
    {
        write(cgen_cfg1, read(cgen_cfg1) | cgen_pwm);
        if (!stop(base))
            return InternalResult.failed;
        write(base + config0, (read(base + config0) & ~(clk_sel_mask | 0xFFFF)) | clk_sel_xclk | div);
        write(base + period_reg, config.period);
        b.period = cast(ushort)config.period;
        b.div = div;
    }
    ++b.users;

    immutable uint ch = port % 4;
    immutable bool negative = config.output.line & 1;
    _pins[port] = cast(ubyte)config.output.line;
    set_threshold(base, ch, config.initial_duty);
    uint c1 = read(base + config1) & ~(0xFu << ch * 4 | 3u << (16 + ch * 2));
    if (negative)
        c1 |= enable_n << ch * 4 | (config.inverted ? polarity_n : 0) << ch * 2;
    else
        c1 |= enable_p << ch * 4 | (config.inverted ? 0 : polarity_p) << ch * 2;
    write(base + config1, c1);
    if (b.users == 1 && !start(base))
    {
        write(base + config1, read(base + config1) & ~enables(ch));
        --b.users;
        return InternalResult.failed;
    }
    gpio_set_function(config.output.line, function_pwm0 + port / 4);
    return Result.success;
}

Result pwm_hw_set_duty(uint port, uint duty)
{
    set_threshold(block_base(port), port % 4, duty);
    return Result.success;
}

void pwm_hw_close(uint port)
{
    immutable uint base = block_base(port);
    immutable uint ch = port % 4;
    set_threshold(base, ch, 0);
    write(base + config1, read(base + config1) & ~enables(ch));
    gpio_release(_pins[port]);
    if (--_blocks[port / 4].users == 0)
        stop(base);
}

private:

enum uint cgen_cfg1 = 0x2000_0584;
enum uint cgen_pwm = 1 << 20;

enum uint pwm_base = 0x2000_A440;
enum uint block_stride = 0x40;
enum uint config0    = 0x00;
enum uint config1    = 0x04;
enum uint period_reg = 0x08;
enum uint thresholds = 0x10;

enum uint stop_en = 1 << 27;
enum uint stop_status = 1 << 29;
enum uint clk_sel_mask = 3u << 30;
enum uint clk_sel_xclk = 0;
enum uint enable_p = 1 << 0;
enum uint enable_n = 1 << 2;
enum uint polarity_p = 1 << 16;
enum uint polarity_n = 1 << 17;
enum uint function_pwm0 = 16;

struct Block
{
    ushort period;
    ushort div;
    ubyte users;
}

__gshared Block[2] _blocks;
__gshared ubyte[num_hw_pwm] _pins;

uint block_base(uint port)
    => pwm_base + port / 4 * block_stride;

uint enables(uint ch) pure
    => (enable_p | enable_n) << ch * 4;

uint read(uint reg)
    => volatileLoad(cast(uint*)reg);

void write(uint reg, uint value)
{
    volatileStore(cast(uint*)reg, value);
}

// the block acknowledges within a few of its clocks; one that never does is left for software PWM
enum uint ack_polls = 100_000;

bool stop(uint base)
{
    write(base + config0, read(base + config0) | stop_en);
    foreach (i; 0 .. ack_polls)
        if (read(base + config0) & stop_status)
            return true;
    return false;
}

bool start(uint base)
{
    write(base + config0, read(base + config0) & ~stop_en);
    foreach (i; 0 .. ack_polls)
        if (!(read(base + config0) & stop_status))
            return true;
    return false;
}

// active while the counter lies between the low and high thresholds
void set_threshold(uint base, uint ch, uint duty)
{
    write(base + thresholds + ch * 4, duty << 16);
}

// XCLK over frequency * period, as a whole divider of 1 to 65535
bool clock_divider(uint frequency, uint period, out ushort div) pure
{
    immutable ulong divider = ulong(xclk_hz) / (ulong(frequency) * period);
    if (divider < 1 || divider > 0xFFFF)
        return false;
    div = cast(ushort)divider;
    return true;
}

unittest
{
    assert(pwm_hw_reaches(0, GpioLine(0, 8)) && pwm_hw_reaches(4, GpioLine(0, 8)), "GPIO8 is channel 0 of either block");
    assert(pwm_hw_reaches(3, GpioLine(0, 31)) && !pwm_hw_reaches(2, GpioLine(0, 31)), "GPIO31 is channel 3");
    assert(pwm_hw_shares(0, 3) && !pwm_hw_shares(3, 4));
    assert((~enables(2) & (enables(0) | enables(1) | enables(3))) == (enables(0) | enables(1) | enables(3)), "closing a channel keeps the others enabled");

    ushort div;
    assert(clock_divider(4000, 256, div) && div == 39, "4 kHz at period 256 is a divider of 39");
    assert(!clock_divider(1, 256, div), "1 Hz at period 256 is beyond the divider");
    assert(!clock_divider(1_000_000, 256, div), "1 MHz at period 256 needs a divider below one");
}
