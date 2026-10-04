// Every register access a backend makes lands in the chip fixture's register model.
module core.volatile;

import fixture : mmio_read, mmio_write;

nothrow @nogc:

T volatileLoad(T)(const(T)* ptr)
    => cast(T)mmio_read(cast(size_t)ptr);

void volatileStore(T)(T* ptr, T value)
{
    mmio_write(cast(size_t)ptr, value);
}
