module urt.driver.adc;

import urt.result : InternalResult, Result;

version (Espressif)
    public import urt.driver.esp32.adc;
else
    enum uint num_adc = 0;

nothrow @nogc:


enum AdcAttenuation : ubyte
{
    db0,
    db2_5,
    db6,
    db12,
}

enum AdcCalibrationSource : byte
{
    unavailable = -1,
    factory_reference,
    factory_two_point,
    default_reference,
}

struct AdcConfig
{
    ubyte unit;
}

struct AdcInputConfig
{
    ubyte channel;
    AdcAttenuation attenuation;
    ubyte bit_width;
    ushort default_reference_mv = 1100;
}

struct Adc
{
    void* handle;
    ubyte unit = ubyte.max;
}

struct AdcInput
{
    void* calibration;
    ubyte channel = ubyte.max;
    AdcAttenuation attenuation;
    ubyte bit_width;
    AdcCalibrationSource calibration_source = AdcCalibrationSource.unavailable;
}

bool is_open(ref const Adc adc)
{
    return adc.handle !is null;
}

bool is_open(ref const AdcInput input)
{
    return input.channel != ubyte.max;
}

Result adc_open(ref Adc adc, ref const AdcConfig config)
{
    static if (num_adc == 0)
        return InternalResult.unsupported;
    else
    {
        if (adc.is_open)
            return InternalResult.already_exists;
        if (config.unit >= num_adc)
            return InternalResult.invalid_parameter;
        return adc_hw_open(adc, config);
    }
}

Result adc_input_open(ref Adc adc, ref AdcInput input, ref const AdcInputConfig config)
{
    static if (num_adc == 0)
        return InternalResult.unsupported;
    else
    {
        if (!adc.is_open || input.is_open || config.bit_width == 0)
            return InternalResult.invalid_parameter;
        return adc_hw_input_open(adc, input, config);
    }
}

Result adc_read_raw(ref Adc adc, ref const AdcInput input, out uint value)
{
    static if (num_adc == 0)
        return InternalResult.unsupported;
    else
    {
        if (!adc.is_open || !input.is_open)
            return InternalResult.invalid_parameter;
        return adc_hw_read_raw(adc, input, value);
    }
}

Result adc_raw_to_mv(ref const AdcInput input, uint raw, out uint millivolts)
{
    static if (num_adc == 0)
        return InternalResult.unsupported;
    else
    {
        if (!input.is_open)
            return InternalResult.invalid_parameter;
        return adc_hw_raw_to_mv(input, raw, millivolts);
    }
}

Result adc_read_mv(ref Adc adc, ref const AdcInput input, out uint millivolts)
{
    uint raw;
    Result result = adc_read_raw(adc, input, raw);
    if (!result)
        return result;
    return adc_raw_to_mv(input, raw, millivolts);
}

void adc_input_close(ref AdcInput input)
{
    static if (num_adc != 0)
    {
        if (input.is_open)
            adc_hw_input_close(input);
    }
    input = AdcInput();
}

void adc_close(ref Adc adc)
{
    static if (num_adc != 0)
    {
        if (adc.is_open)
            adc_hw_close(adc);
    }
    adc = Adc();
}
