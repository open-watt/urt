module urt.driver.esp32.adc;

import urt.driver.adc;
import urt.result : InternalResult, Result;

nothrow @nogc:


version (ESP32)
    enum uint num_adc = 2;
else
    enum uint num_adc = 0;

Result adc_hw_open(ref Adc adc, ref const AdcConfig config)
{
    void* handle;
    if (ow_adc_open(config.unit, &handle) != 0)
        return InternalResult.failed;

    adc.handle = handle;
    adc.unit = config.unit;
    return Result.success;
}

Result adc_hw_input_open(ref Adc adc, ref AdcInput input, ref const AdcInputConfig config)
{
    void* calibration;
    int calibration_source;
    if (ow_adc_input_open(adc.handle, adc.unit, config.channel, config.attenuation, config.bit_width, config.default_reference_mv, &calibration, &calibration_source) != 0)
        return InternalResult.failed;

    input.calibration = calibration;
    input.channel = config.channel;
    input.attenuation = config.attenuation;
    input.bit_width = config.bit_width;
    input.calibration_source = calibration_source < 0 ? AdcCalibrationSource.unavailable : cast(AdcCalibrationSource)calibration_source;
    return Result.success;
}

Result adc_hw_read_raw(ref Adc adc, ref const AdcInput input, out uint value)
{
    return ow_adc_read(adc.handle, adc.unit, input.channel, &value) == 0 ? Result.success : InternalResult.failed;
}

Result adc_hw_raw_to_mv(ref const AdcInput input, uint raw, out uint millivolts)
{
    return ow_adc_raw_to_mv(input.calibration, raw, &millivolts) == 0 ? Result.success : InternalResult.failed;
}

void adc_hw_input_close(ref AdcInput input)
{
    ow_adc_input_close(input.calibration);
}

void adc_hw_close(ref Adc adc)
{
    ow_adc_close(adc.handle);
}


private:

extern(C) nothrow @nogc
{
    int ow_adc_open(uint unit, void** handle);
    int ow_adc_input_open(void* handle, uint unit, uint channel, AdcAttenuation attenuation, uint bit_width, uint default_reference_mv, void** calibration, int* calibration_source);
    int ow_adc_read(void* handle, uint unit, uint channel, uint* raw);
    int ow_adc_raw_to_mv(const(void)* calibration, uint raw, uint* millivolts);
    void ow_adc_input_close(void* calibration);
    void ow_adc_close(void* handle);
}
