// SPI master driver. One device per bus: the wiring, clock, mode, and
// optional chip-select are fixed at open. cs_gpio = ubyte.max means no
// chip-select line; the device is permanently selected.
//
// Transfers are simultaneous full-duplex: write and read start on the
// same clock edge, and the transaction runs for max(write, read) bytes.
// SPI is master-clocked so a transfer's duration is bounded by its
// length; there is no timeout. The transfer itself is DMA, and
// completion is signalled from the controller's interrupt -- see the
// callback contract on SpiOperation.
//
// Some boards multiplex the data pins with other functions (e.g. push
// buttons behind a display's MOSI). spi_suspend releases the MOSI pin
// to software GPIO control so it can be re-initialized and sampled;
// spi_resume routes it back to the peripheral and restores it as an
// output. No operation may be pending across either call.
//
// num_spi is a compile-time upper bound used to remove unsupported backends. spi_count() returns the actual number of usable controllers.
//
// Each backend exports:
//   uint spi_count();
//   bool spi_hw_open(ref SpiBus, uint port, ref const SpiBusConfig);
//   void spi_hw_close(ref SpiBus);
//   Result spi_hw_submit(ref SpiBus, ref SpiOperation, ref const SpiTransfer);
//   Result spi_hw_cancel(ref SpiBus, ref SpiOperation);
//   Result spi_hw_suspend(ref SpiBus);
//   Result spi_hw_resume(ref SpiBus);
module urt.driver.spi;

import urt.atomic;
import urt.attribute : critical;
import urt.result : Result, InternalResult;

version (Espressif)
    public import urt.driver.esp32.spi;
else
{
    enum uint num_spi = 0;
    uint spi_count() nothrow @nogc => 0;
}

nothrow @nogc:


enum SpiMode : ubyte
{
    mode0,  // CPOL=0 CPHA=0
    mode1,  // CPOL=0 CPHA=1
    mode2,  // CPOL=1 CPHA=0
    mode3,  // CPOL=1 CPHA=1
}

enum SpiError : ubyte
{
    none,
    bus,
}

enum SpiCallbackContext : ubyte
{
    thread,
    interrupt,
}

enum SpiOperationState : uint
{
    idle,
    pending,
    complete,
    cancelled,
    error,
}

struct SpiBusConfig
{
    uint frequency = 1_000_000;
    SpiMode mode;
    ubyte sck_gpio = ubyte.max;
    ubyte mosi_gpio = ubyte.max;
    ubyte miso_gpio = ubyte.max;
    ubyte cs_gpio = ubyte.max;
}

struct SpiTransfer
{
    // The operation and both buffers must remain alive and unmoved until completion. The write buffer must not be modified while pending.
    // When both directions are present the buffers must be the same length (the transfer is simultaneous, not write-then-read).
    // Backends may require buffers larger than 4 bytes to reside in DMA-capable RAM (not flash/rodata).
    const(void)[] write_data;
    void[] read_data;
}

struct SpiOperation
{
nothrow @nogc:
    // Completion is published and the callback runs immediately in the backend's completion context, which is the completion interrupt on backends that
    // have one. Such a callback must be @critical and must not block, allocate, or resubmit; spi_submit needs thread context and rejects an interrupt
    // caller. The receiver marshals anything else out. An interrupt callback returns whether the platform should yield to a thread it woke; thread-context
    // backends ignore the result. Other threads must first observe is_done, which performs an acquire load, before reading the result or reusing the
    // operation, its buffers, or its bus. Completion state is published and bus ownership is released before the callback begins.
    alias Callback = bool function(ref SpiOperation operation, SpiCallbackContext context) nothrow @nogc;

    void* user_data;
    Callback callback;

    SpiOperationState state() const
        => cast(SpiOperationState)atomicLoad!(MemoryOrder.acquire)(_state);

    SpiError error() const
    {
        assert(state != SpiOperationState.pending);
        return _error;
    }

    bool is_pending() const
        => state == SpiOperationState.pending;

    bool is_done() const
        => state >= SpiOperationState.complete;

    void reset()
    {
        assert(state != SpiOperationState.pending);
        assert(_bus is null);
        _error = SpiError.none;
        atomicStore!(MemoryOrder.release)(_state, SpiOperationState.idle);
    }

private:
    shared uint _state;
    SpiError _error;
    SpiBus* _bus;
}

struct SpiBus
{
nothrow @nogc:
    ubyte port = ubyte.max;
    void* driver_data;

private:
    SpiOperation* _operation;
}

bool is_open(ref const SpiBus bus)
{
    return bus.port != ubyte.max;
}

Result spi_open(ref SpiBus bus, ubyte port, ref const SpiBusConfig config)
{
    static if (num_spi == 0)
        return InternalResult.unsupported;
    else
    {
        if (port >= spi_count() || config.sck_gpio == ubyte.max ||
            (config.mosi_gpio == ubyte.max && config.miso_gpio == ubyte.max) || config.frequency == 0)
            return InternalResult.invalid_parameter;
        if (bus.is_open)
            return InternalResult.already_exists;
        if (!spi_hw_open(bus, port, config))
            return InternalResult.failed;
        bus.port = port;
        return Result.success;
    }
}

void spi_close(ref SpiBus bus)
{
    assert(bus._operation is null, "an SPI bus cannot close while an operation is pending");
    if (bus._operation !is null)
        return;

    static if (num_spi != 0)
    {
        if (bus.is_open)
            spi_hw_close(bus);
    }
    bus.port = ubyte.max;
    bus.driver_data = null;
}

Result spi_submit(ref SpiBus bus, ref SpiOperation operation, ref const SpiTransfer transfer)
{
    static if (num_spi == 0)
        return InternalResult.unsupported;
    else
    {
        if (!bus.is_open || operation.state != SpiOperationState.idle || bus._operation !is null ||
            (transfer.write_data.length == 0 && transfer.read_data.length == 0) ||
            (transfer.write_data.length != 0 && transfer.read_data.length != 0 &&
             transfer.write_data.length != transfer.read_data.length))
            return InternalResult.invalid_parameter;

        operation._error = SpiError.none;
        operation._bus = &bus;
        bus._operation = &operation;
        atomicStore!(MemoryOrder.release)(operation._state, SpiOperationState.pending);
        Result result = spi_hw_submit(bus, operation, transfer);
        if (!result)
        {
            bus._operation = null;
            operation._bus = null;
            operation._error = SpiError.bus;
            atomicStore!(MemoryOrder.release)(operation._state, SpiOperationState.idle);
        }
        return result;
    }
}

Result spi_cancel(ref SpiBus bus, ref SpiOperation operation)
{
    static if (num_spi == 0)
        return InternalResult.unsupported;
    else
    {
        if (!bus.is_open || !operation.is_pending || operation._bus !is &bus)
            return InternalResult.invalid_parameter;
        return spi_hw_cancel(bus, operation);
    }
}

Result spi_suspend(ref SpiBus bus)
{
    static if (num_spi == 0)
        return InternalResult.unsupported;
    else
    {
        if (!bus.is_open || bus._operation !is null)
            return InternalResult.invalid_parameter;
        return spi_hw_suspend(bus);
    }
}

Result spi_resume(ref SpiBus bus)
{
    static if (num_spi == 0)
        return InternalResult.unsupported;
    else
    {
        if (!bus.is_open || bus._operation !is null)
            return InternalResult.invalid_parameter;
        return spi_hw_resume(bus);
    }
}

@critical package bool spi_complete(ref SpiOperation operation, SpiError error, SpiCallbackContext context)
{
    SpiOperationState state = error == SpiError.none
        ? SpiOperationState.complete : SpiOperationState.error;
    return spi_complete(operation, state, error, context);
}

@critical package bool spi_complete(ref SpiOperation operation, SpiOperationState completion_state, SpiError error, SpiCallbackContext context)
{
    if (!operation.is_pending)
        return false;
    assert(completion_state == SpiOperationState.complete || completion_state == SpiOperationState.cancelled ||
           completion_state == SpiOperationState.error);

    SpiBus* bus = operation._bus;
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
    static assert(is(typeof(num_spi) == uint));
    spi_count();

    // Mode encoding is load-bearing: backends pass the ordinal straight through as CPOL/CPHA.
    static assert(SpiMode.mode0 == 0);
    static assert(SpiMode.mode3 == 3);

    SpiBus bus;
    SpiOperation operation;
    bus._operation = &operation;
    operation._bus = &bus;
    atomicStore!(MemoryOrder.release)(operation._state, SpiOperationState.pending);

    assert(!spi_complete(operation, SpiError.bus, SpiCallbackContext.thread));
    assert(operation.state == SpiOperationState.error);
    assert(operation.error == SpiError.bus);
    assert(operation._bus is null);
    assert(bus._operation is null);
    assert(!spi_complete(operation, SpiError.none, SpiCallbackContext.thread));

    operation.reset();
    bus._operation = &operation;
    operation._bus = &bus;
    atomicStore!(MemoryOrder.release)(operation._state, SpiOperationState.pending);
    assert(!spi_complete(operation, SpiOperationState.cancelled, SpiError.none, SpiCallbackContext.thread));
    assert(operation.state == SpiOperationState.cancelled);
}
