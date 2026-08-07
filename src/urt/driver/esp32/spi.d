module urt.driver.esp32.spi;

import urt.attribute : critical;
import urt.driver.spi : SpiBus, SpiBusConfig, SpiCallbackContext, SpiError, SpiOperation, SpiTransfer, spi_complete;
import urt.result : Result, InternalResult;

nothrow @nogc:


// SPI1 drives the flash; only the general-purpose controllers are exposed. spi_count() returns the actual number for the active chip variant.
enum uint num_spi = 2;

uint spi_count() => ow_spi_count();

bool spi_hw_open(ref SpiBus bus, uint port, ref const SpiBusConfig config)
{
    if (port >= spi_count())
        return false;
<<<<<<< HEAD
    bus.driver_data = ow_spi_open(port, config.sck_gpio, gpio_arg(config.mosi_gpio), gpio_arg(config.miso_gpio),
        gpio_arg(config.cs_gpio), config.frequency, config.mode);
=======
    bus.driver_data = ow_spi_open(port, config.sck_gpio, gpio_arg(config.mosi_gpio), gpio_arg(config.miso_gpio), gpio_arg(config.cs_gpio), config.frequency, config.mode);
>>>>>>> ow/spi-master
    return bus.driver_data !is null;
}

void spi_hw_close(ref SpiBus bus)
{
    if (bus.driver_data !is null)
        ow_spi_close(bus.driver_data);
}

Result spi_hw_submit(ref SpiBus bus, ref SpiOperation operation, ref const SpiTransfer transfer)
{
<<<<<<< HEAD
    int result = ow_spi_submit(bus.driver_data, transfer.write_data.ptr, transfer.write_data.length,
        cast(void*)transfer.read_data.ptr, transfer.read_data.length, &operation_complete, &operation);
=======
    int result = ow_spi_submit(bus.driver_data, transfer.write_data.ptr, transfer.write_data.length, cast(void*)transfer.read_data.ptr, transfer.read_data.length, &operation_complete, &operation);
>>>>>>> ow/spi-master
    return result == 0 ? Result.success : InternalResult.failed;
}

Result spi_hw_cancel(ref SpiBus, ref SpiOperation)
{
    return InternalResult.unsupported;
}

Result spi_hw_suspend(ref SpiBus bus)
{
    return ow_spi_suspend(bus.driver_data) == 0 ? Result.success : InternalResult.failed;
}

Result spi_hw_resume(ref SpiBus bus)
{
    return ow_spi_resume(bus.driver_data) == 0 ? Result.success : InternalResult.failed;
}

private:

extern(C) alias SpiCompletion = bool function(void*, int);

int gpio_arg(ubyte gpio)
    => gpio == ubyte.max ? -1 : gpio;

@critical extern(C) bool operation_complete(void* context, int result)
{
    return spi_complete(*cast(SpiOperation*)context, result == 0 ? SpiError.none : SpiError.bus, SpiCallbackContext.interrupt);
}

extern(C)
{
    uint ow_spi_count();
    void* ow_spi_open(uint port, int sck_gpio, int mosi_gpio, int miso_gpio, int cs_gpio, uint frequency, ubyte mode);
    void ow_spi_close(void* bus);
<<<<<<< HEAD
    int ow_spi_submit(void* bus, const(void)* write_data, size_t write_length, void* read_data, size_t read_length,
        SpiCompletion callback, void* callback_context);
=======
    int ow_spi_submit(void* bus, const(void)* write_data, size_t write_length, void* read_data, size_t read_length, SpiCompletion callback, void* callback_context);
>>>>>>> ow/spi-master
    int ow_spi_suspend(void* bus);
    int ow_spi_resume(void* bus);
}
