// The SoC's single I2C master ("SM0"), on its fixed pins GPIO3 (SDA) and GPIO4 (SCL).
module urt.driver.mt7621.i2c;

import urt.driver.i2c : I2cAddressMode, I2cBus, I2cBusConfig, I2cCallbackContext, I2cError, I2cOperation, I2cTransfer, i2c_complete;
import urt.driver.mt7621 : mmio_read, mmio_write, sysctl_base, sysc_rstctrl;
import urt.result : Result, InternalResult;
import urt.time;

nothrow @nogc:

enum uint num_i2c = 1;
enum I2cBusConfig test_i2c_config = I2cBusConfig(100_000, 3, 4);

uint i2c_count()
    => num_i2c;

bool i2c_hw_open(ref I2cBus bus, uint port, ref const I2cBusConfig config)
{
    if (port != 0 || config.sda_gpio != 3 || config.scl_gpio != 4)
        return false;
    mmio_write(sysctl_base + sysc_gpio_mode, mmio_read(sysctl_base + sysc_gpio_mode) & ~gpio_mode_i2c_as_gpio);
    uint div = periph_hz / config.frequency - 1;
    _clk_div = div < 99 ? 99 : div > ctl0_clk_div_max ? ctl0_clk_div_max : div;
    reset();
    return true;
}

void i2c_hw_close(ref I2cBus bus)
{
    mmio_write(i2c_base + sm0ctl0, 0);
}

// TODO: synchronous; a 256-byte EEPROM read at 100 kHz holds the caller for about 25 ms.
Result i2c_hw_submit(ref I2cBus bus, ref I2cOperation operation, ref const I2cTransfer transfer)
{
    immutable deadline = getTime() + transfer.timeout;
    I2cError error = transact(transfer, deadline);
    if (error == I2cError.timeout)
        reset();
    i2c_complete(operation, error, I2cCallbackContext.thread);
    return Result.success;
}

Result i2c_hw_cancel(ref I2cBus, ref I2cOperation)
    => InternalResult.unsupported;


private:

enum uint i2c_base = 0xBE00_0900;
enum uint periph_hz = 50_000_000;

enum uint sm0cfg2 = 0x28;
enum uint sm0ctl0 = 0x40;
enum uint sm0ctl1 = 0x44;
enum uint sm0d0   = 0x50;
enum uint sm0d1   = 0x54;

enum uint ctl0_scl_stretch  = 1 << 0;
enum uint ctl0_en           = 1 << 1;
enum uint ctl0_clk_div_max  = 0x7FF;
enum uint ctl1_tri          = 1 << 0;
enum uint ctl1_start        = 1 << 4;
enum uint ctl1_write        = 2 << 4;
enum uint ctl1_stop         = 3 << 4;
enum uint ctl1_read_last    = 4 << 4;
enum uint ctl1_read         = 5 << 4;

enum uint sysc_gpio_mode        = 0x60;
enum uint gpio_mode_i2c_as_gpio = 1 << 2;
enum uint rst_i2c               = 1 << 16;

__gshared uint _clk_div = 499;

void reset()
{
    mmio_write(sysctl_base + sysc_rstctrl, mmio_read(sysctl_base + sysc_rstctrl) | rst_i2c);
    mmio_write(sysctl_base + sysc_rstctrl, mmio_read(sysctl_base + sysc_rstctrl) & ~rst_i2c);
    mmio_write(i2c_base + sm0ctl0, (_clk_div << 16) | ctl0_en | ctl0_scl_stretch);
    mmio_write(i2c_base + sm0cfg2, 0);
}

bool wait_idle(MonoTime deadline)
{
    while (mmio_read(i2c_base + sm0ctl1) & ctl1_tri)
    {
        if (getTime() > deadline)
            return false;
    }
    return true;
}

bool command(uint cmd, size_t bytes, MonoTime deadline)
{
    mmio_write(i2c_base + sm0ctl1, cmd | ctl1_tri | (bytes ? cast(uint)(bytes - 1) << 8 : 0));
    return wait_idle(deadline);
}

// The ACK bits of the last command, one per byte from bit 16.
bool acked(size_t bytes)
    => ((mmio_read(i2c_base + sm0ctl1) >> 16) & ((1u << bytes) - 1)) == (1u << bytes) - 1;

// A 10-bit target is selected by a write header and its low byte; a read then re-addresses with the header alone.
I2cError address_phase(ref const I2cTransfer transfer, bool read, MonoTime deadline)
{
    immutable ten = transfer.address_mode == I2cAddressMode.ten_bit;
    immutable uint header = ten ? 0xF0 | ((transfer.address >> 7) & 6) : transfer.address << 1;
    if (!ten || !read || !transfer.write_data.length)
    {
        immutable error = address_bytes(ten ? header | (transfer.address & 0xFF) << 8 : header | read, ten ? 2 : 1, deadline);
        if (error != I2cError.none)
            return error;
    }
    return ten && read ? address_bytes(header | 1, 1, deadline) : I2cError.none;
}

I2cError address_bytes(uint bytes, size_t len, MonoTime deadline)
{
    if (!command(ctl1_start, 0, deadline))
        return I2cError.timeout;
    mmio_write(i2c_base + sm0d0, bytes);
    if (!command(ctl1_write, len, deadline))
        return I2cError.timeout;
    return acked(len) ? I2cError.none : I2cError.nack;
}

I2cError transact(ref const I2cTransfer transfer, MonoTime deadline)
{
    if (!wait_idle(deadline))
        return I2cError.timeout;

    I2cError error = I2cError.none;
    if (transfer.write_data.length)
    {
        error = address_phase(transfer, false, deadline);
        auto data = cast(const(ubyte)[])transfer.write_data;
        for (size_t j = 0; error == I2cError.none && j < data.length; j += 8)
        {
            immutable n = data.length - j < 8 ? data.length - j : 8;
            uint[2] w;
            foreach (k; 0 .. n)
                w[k >> 2] |= data[j + k] << ((k & 3) * 8);
            mmio_write(i2c_base + sm0d0, w[0]);
            mmio_write(i2c_base + sm0d1, w[1]);
            if (!command(ctl1_write, n, deadline))
                return I2cError.timeout;
            if (!acked(n))
                error = I2cError.nack;
        }
    }
    if (error == I2cError.none && transfer.read_data.length)
    {
        error = address_phase(transfer, true, deadline);
        auto data = cast(ubyte[])transfer.read_data;
        for (size_t j = 0; error == I2cError.none && j < data.length; j += 8)
        {
            immutable n = data.length - j < 8 ? data.length - j : 8;
            if (!command(j + n < data.length ? ctl1_read : ctl1_read_last, n, deadline))
                return I2cError.timeout;
            immutable uint[2] w = [mmio_read(i2c_base + sm0d0), mmio_read(i2c_base + sm0d1)];
            foreach (k; 0 .. n)
                data[j + k] = cast(ubyte)(w[k >> 2] >> ((k & 3) * 8));
        }
    }
    if (error == I2cError.timeout)
        return error;
    return command(ctl1_stop, 0, deadline) ? error : I2cError.timeout;
}
