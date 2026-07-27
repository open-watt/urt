module urt.driver.i2c;

import urt.atomic;
import urt.result : Result, InternalResult;
import urt.time;

// num_i2c is a compile-time upper bound used to remove unsupported backends. i2c_count() returns the actual number of usable controllers.
version (Espressif)
    public import urt.driver.esp32.i2c;
else
{
    enum uint num_i2c = 0;
    uint i2c_count() nothrow @nogc => 0;
}

nothrow @nogc:


enum I2cAddressMode : ubyte
{
    seven_bit,
    ten_bit,
}

enum I2cError : ubyte
{
    none,
    nack,
    timeout,
    arbitration_lost,
    bus,
}

enum I2cCallbackContext : ubyte
{
    task,
    interrupt,
}

enum I2cOperationState : uint
{
    idle,
    pending,
    complete,
    cancelled,
    error,
}

struct I2cBusConfig
{
    uint frequency = 100_000;
    ubyte sda_gpio = ubyte.max;
    ubyte scl_gpio = ubyte.max;
    bool internal_pullups;
}

struct I2cTransfer
{
    // The operation and both buffers must remain alive and unmoved until completion. The write buffer must not be modified while pending.
    ushort address;
    I2cAddressMode address_mode;
    const(void)[] write_data;
    void[] read_data;
    Duration timeout = 100.msecs;
}

struct I2cOperation
{
nothrow @nogc:
    // Completion is published and the callback runs immediately in the backend's completion context. The receiver must marshal work that is unsafe in
    // that context, and the callback must not block. An interrupt callback returns whether the platform should yield to a task woken by the callback;
    // task-context backends ignore the result. Other threads must first observe is_done, which performs an acquire load, before reading the result or
    // reusing the operation, its buffers, or its bus. Completion state is published and bus ownership is released before the callback begins.
    alias Callback = bool function(ref I2cOperation operation, I2cCallbackContext context) nothrow @nogc;

    void* user_data;
    Callback callback;

    I2cOperationState state() const
        => cast(I2cOperationState)atomicLoad!(MemoryOrder.acquire)(_state);

    I2cError error() const
    {
        assert(state != I2cOperationState.pending);
        return _error;
    }

    bool is_pending() const
        => state == I2cOperationState.pending;

    bool is_done() const
        => state >= I2cOperationState.complete;

    void reset()
    {
        assert(state != I2cOperationState.pending);
        assert(_bus is null);
        _error = I2cError.none;
        atomicStore!(MemoryOrder.release)(_state, I2cOperationState.idle);
    }

private:
    shared uint _state;
    I2cError _error;
    I2cBus* _bus;
}

struct I2cBus
{
nothrow @nogc:
    ubyte port = ubyte.max;
    void* driver_data;
    uint frequency;

private:
    I2cOperation* _operation;
}

bool is_open(ref const I2cBus bus)
{
    return bus.port != ubyte.max;
}

Result i2c_open(ref I2cBus bus, ubyte port, ref const I2cBusConfig config)
{
    static if (num_i2c == 0)
        return InternalResult.unsupported;
    else
    {
        if (port >= i2c_count() || config.sda_gpio == ubyte.max || config.scl_gpio == ubyte.max || config.sda_gpio == config.scl_gpio ||
            config.frequency == 0)
            return InternalResult.invalid_parameter;
        if (bus.is_open)
            return InternalResult.already_exists;
        if (!i2c_hw_open(bus, port, config))
            return InternalResult.failed;
        bus.port = port;
        bus.frequency = config.frequency;
        return Result.success;
    }
}

void i2c_close(ref I2cBus bus)
{
    assert(bus._operation is null, "an I2C bus cannot close while an operation is pending");
    if (bus._operation !is null)
        return;

    static if (num_i2c != 0)
    {
        if (bus.is_open)
            i2c_hw_close(bus);
    }
    bus.port = ubyte.max;
    bus.driver_data = null;
    bus.frequency = 0;
}

Result i2c_submit(ref I2cBus bus, ref I2cOperation operation, ref const I2cTransfer transfer)
{
    static if (num_i2c == 0)
        return InternalResult.unsupported;
    else
    {
        if (!bus.is_open || operation.state != I2cOperationState.idle || bus._operation !is null ||
            (transfer.write_data.length == 0 && transfer.read_data.length == 0) || transfer.timeout <= Duration.zero)
            return InternalResult.invalid_parameter;

        final switch (transfer.address_mode)
        {
            case I2cAddressMode.seven_bit:
                if (transfer.address > 0x7F)
                    return InternalResult.invalid_parameter;
                break;
            case I2cAddressMode.ten_bit:
                if (transfer.address > 0x3FF)
                    return InternalResult.invalid_parameter;
                break;
        }

        operation._error = I2cError.none;
        operation._bus = &bus;
        bus._operation = &operation;
        atomicStore!(MemoryOrder.release)(operation._state, I2cOperationState.pending);
        Result result = i2c_hw_submit(bus, operation, transfer);
        if (!result)
        {
            bus._operation = null;
            operation._bus = null;
            operation._error = I2cError.bus;
            atomicStore!(MemoryOrder.release)(operation._state, I2cOperationState.idle);
        }
        return result;
    }
}

Result i2c_cancel(ref I2cBus bus, ref I2cOperation operation)
{
    static if (num_i2c == 0)
        return InternalResult.unsupported;
    else
    {
        if (!bus.is_open || !operation.is_pending || operation._bus !is &bus)
            return InternalResult.invalid_parameter;
        return i2c_hw_cancel(bus, operation);
    }
}

package bool i2c_complete(ref I2cOperation operation, I2cError error, I2cCallbackContext context)
{
    I2cOperationState state = error == I2cError.none
        ? I2cOperationState.complete : I2cOperationState.error;
    return i2c_complete(operation, state, error, context);
}

package bool i2c_complete(ref I2cOperation operation, I2cOperationState completion_state, I2cError error, I2cCallbackContext context)
{
    if (!operation.is_pending)
        return false;
    assert(completion_state == I2cOperationState.complete || completion_state == I2cOperationState.cancelled ||
           completion_state == I2cOperationState.error);

    I2cBus* bus = operation._bus;
    assert(bus !is null && bus._operation is &operation);
    if (bus !is null && bus._operation is &operation)
        bus._operation = null;
    operation._bus = null;
    operation._error = error;
    atomicStore!(MemoryOrder.release)(operation._state, completion_state);
    return operation.callback ? operation.callback(operation, context) : false;
}


unittest
{
    static assert(is(typeof(num_i2c) == uint));
    i2c_count();

    I2cBus bus;
    I2cOperation operation;
    bus._operation = &operation;
    operation._bus = &bus;
    atomicStore!(MemoryOrder.release)(operation._state, I2cOperationState.pending);

    assert(!i2c_complete(operation, I2cError.nack, I2cCallbackContext.task));
    assert(operation.state == I2cOperationState.error);
    assert(operation.error == I2cError.nack);
    assert(operation._bus is null);
    assert(bus._operation is null);
    assert(!i2c_complete(operation, I2cError.none, I2cCallbackContext.task));

    operation.reset();
    bus._operation = &operation;
    operation._bus = &bus;
    atomicStore!(MemoryOrder.release)(operation._state, I2cOperationState.pending);
    assert(!i2c_complete(operation, I2cOperationState.cancelled, I2cError.none, I2cCallbackContext.task));
    assert(operation.state == I2cOperationState.cancelled);
}
