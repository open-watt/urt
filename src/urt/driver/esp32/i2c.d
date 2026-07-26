module urt.driver.esp32.i2c;

import urt.driver.i2c : I2cBus, I2cBusConfig, I2cCallbackContext, I2cError, I2cOperation, I2cTransfer, i2c_complete;
import urt.result : Result, InternalResult;
import urt.time : Duration;

nothrow @nogc:


// Conservative compile-time upper bound. i2c_count() returns the HP controllers exposed by the ESP-IDF master driver.
enum uint num_i2c = 2;

uint i2c_count() => ow_i2c_count();

bool i2c_hw_open(ref I2cBus bus, uint port, ref const I2cBusConfig config)
{
    if (port >= i2c_count())
        return false;
    bus.driver_data = ow_i2c_open(port, config.sda_gpio, config.scl_gpio, config.internal_pullups);
    return bus.driver_data !is null;
}

void i2c_hw_close(ref I2cBus bus)
{
    if (bus.driver_data !is null)
        ow_i2c_close(bus.driver_data);
}

Result i2c_hw_submit(ref I2cBus bus, ref I2cOperation operation, ref const I2cTransfer transfer)
{
    int result = ow_i2c_submit(bus.driver_data, transfer.address, transfer.address_mode, bus.frequency,
        transfer.write_data.ptr, transfer.write_data.length, cast(void*)transfer.read_data.ptr, transfer.read_data.length,
        timeout_ms(transfer.timeout), &operation_complete, &operation);
    return result == 0 ? Result.success : InternalResult.failed;
}

Result i2c_hw_cancel(ref I2cBus, ref I2cOperation)
{
    return InternalResult.unsupported;
}

private:

extern(C) alias I2cCompletion = bool function(void*, int);

int timeout_ms(Duration timeout)
{
    long value = timeout.as!"msecs";
    if (value < 1)
        return 1;
    if (value > int.max)
        return int.max;
    return cast(int)value;
}

extern(C) bool operation_complete(void* context, int result)
{
    I2cError error;
    switch (result)
    {
        case 0: error = I2cError.none; break;
        case 1: error = I2cError.nack; break;
        case 2: error = I2cError.timeout; break;
        case 3: error = I2cError.arbitration_lost; break;
        default: error = I2cError.bus; break;
    }
    return i2c_complete(*cast(I2cOperation*)context, error, I2cCallbackContext.task);
}

extern(C)
{
    uint ow_i2c_count();
    void* ow_i2c_open(uint port, int sda_gpio, int scl_gpio, bool internal_pullups);
    void ow_i2c_close(void* bus);
    int ow_i2c_submit(void* bus, ushort address, ubyte address_mode, uint frequency, const(void)* write_data, size_t write_length,
        void* read_data, size_t read_length, int timeout_ms, I2cCompletion callback, void* callback_context);
}
