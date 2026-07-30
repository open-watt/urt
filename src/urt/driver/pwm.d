module urt.driver.pwm;

import urt.driver.gpio : GpioLine;
import urt.result : InternalResult, Result;

version (Espressif)
    public import urt.driver.esp32.pwm;
else
    enum uint num_pwm = 0;

nothrow @nogc:


struct PwmConfig
{
    GpioLine output;
    uint frequency;
    uint period; // Duty values range from zero through period.
    uint initial_duty;
    bool inverted;
}

struct Pwm
{
    ubyte port = ubyte.max;
    uint period;
}

bool is_open(ref const Pwm pwm)
{
    return pwm.port != ubyte.max;
}

Result pwm_open(ref Pwm pwm, ubyte port, ref const PwmConfig config)
{
    static if (num_pwm == 0)
        return InternalResult.unsupported;
    else
    {
        if (pwm.is_open)
            return InternalResult.already_exists;
        if (port >= num_pwm || config.output.line == uint.max || config.frequency == 0 || config.period == 0 || config.initial_duty > config.period)
            return InternalResult.invalid_parameter;

        Result result = pwm_hw_open(port, config);
        if (!result)
            return result;

        pwm.port = port;
        pwm.period = config.period;
        return Result.success;
    }
}

Result pwm_set_duty(ref Pwm pwm, uint duty)
{
    static if (num_pwm == 0)
        return InternalResult.unsupported;
    else
    {
        if (!pwm.is_open || duty > pwm.period)
            return InternalResult.invalid_parameter;
        return pwm_hw_set_duty(pwm.port, duty);
    }
}

void pwm_close(ref Pwm pwm)
{
    static if (num_pwm != 0)
    {
        if (pwm.is_open)
            pwm_hw_close(pwm.port);
    }
    pwm.port = ubyte.max;
    pwm.period = 0;
}


unittest
{
    Pwm pwm;
    assert(!pwm.is_open);
}
