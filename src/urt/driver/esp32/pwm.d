module urt.driver.esp32.pwm;

import urt.driver.pwm : PwmConfig;
import urt.result : InternalResult, Result;

nothrow @nogc:


enum uint num_hw_pwm = 4;

Result pwm_hw_open(uint port, ref const PwmConfig config)
{
    ubyte resolution = resolution_bits(config.period);
    if (port >= num_hw_pwm || resolution == 0)
        return InternalResult.invalid_parameter;
    if (_open[port])
        return InternalResult.already_exists;

    if (config.output.chip != 0)
        return InternalResult.unsupported;
    if (urt_pwm_open(port, config.output.line, config.frequency, resolution, config.initial_duty, config.inverted) != 0)
        return InternalResult.failed;

    _open[port] = true;
    return Result.success;
}

Result pwm_hw_set_duty(uint port, uint duty)
{
    if (port >= num_hw_pwm || !_open[port])
        return InternalResult.invalid_parameter;
    return urt_pwm_set_duty(port, duty) == 0 ? Result.success : InternalResult.failed;
}

void pwm_hw_close(uint port)
{
    if (port >= num_hw_pwm || !_open[port])
        return;
    urt_pwm_close(port);
    _open[port] = false;
}

private:

__gshared bool[num_hw_pwm] _open;

ubyte resolution_bits(uint period)
{
    if (period < 2 || (period & (period - 1)) != 0)
        return 0;

    ubyte bits;
    while (period > 1)
    {
        period >>= 1;
        ++bits;
    }
    return bits;
}

extern(C) nothrow @nogc
{
    int urt_pwm_open(uint port, uint gpio, uint frequency, uint resolution, uint initial_duty, bool inverted);
    int urt_pwm_set_duty(uint port, uint duty);
    void urt_pwm_close(uint port);
}
