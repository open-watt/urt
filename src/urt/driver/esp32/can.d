// ESP32 CAN (TWAI) driver.
//
// ESP-IDF v6 exposes received frames only from its ISR callback. The C shim copies them into a bounded ring there, then this layer presents the
// portable can_receive() API to main-thread consumers.
//
// Controller count per chip (ESP-IDF v6.0):
//   ESP32, S2, S3, C3, H2: 1    C5, C6: 2    P4: 3    C2, C61: 0
module urt.driver.esp32.can;

import urt.atomic : atomicLoad, atomicStore, MemoryOrder;
import urt.driver.can : Can, CanBusState, CanCallbackContext, CanConfig, CanError, CanFrame, CanRxCallback;
import urt.result : Result, InternalResult;

nothrow @nogc:


// SOC_TWAI_CONTROLLER_NUM per chip variant (ESP-IDF v6.0 soc_caps.h)
version (ESP32)         enum uint num_can = 1;
else version (ESP32_S2) enum uint num_can = 1;
else version (ESP32_S3) enum uint num_can = 1;
else version (ESP32_P4) enum uint num_can = 3;
else version (ESP32_C3) enum uint num_can = 1;
else version (ESP32_C5) enum uint num_can = 2;
else version (ESP32_C6) enum uint num_can = 2;
else version (ESP32_H2) enum uint num_can = 1;
else                    enum uint num_can = 0; // C2, C61

// SOC_TWAI_FD_SUPPORTED (ESP-IDF v6.0 soc_caps.h)
version (ESP32_C5) enum bool has_can_fd = true;
else               enum bool has_can_fd = false;


static if (num_can > 0):


Result can_hw_open(uint port, ref const CanConfig cfg, CanRxCallback rx_cb)
{
    if (port >= num_can || cfg.tx_gpio == ubyte.max || cfg.rx_gpio == ubyte.max)
        return InternalResult.invalid_parameter;
    if (_handles[port] !is null)
    {
        if (_configs[port] != cfg)
            return InternalResult.already_exists;
        can_hw_set_rx_callback(port, rx_cb);
        return Result.success;
    }
    can_hw_set_rx_callback(port, rx_cb);
    _handles[port] = ow_can_open(port, cfg.bitrate, cfg.tx_gpio, cfg.rx_gpio, cfg.sjw, cfg.tseg1, cfg.tseg2, cfg.brp, &rx_ready_trampoline);
    if (_handles[port] is null)
    {
        can_hw_set_rx_callback(port, null);
        return InternalResult.failed;
    }
    _configs[port] = cfg;
    return Result.success;
}

void can_hw_close(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return;
    can_hw_set_rx_callback(port, null);
    ow_can_close(_handles[port]);
    _handles[port] = null;
    _configs[port] = CanConfig.init;
}

bool can_hw_transmit(uint port, ref const CanFrame frame)
{
    if (port >= num_can || _handles[port] is null || frame.dlc > 8)
        return false;
    ubyte flags = (frame.extended ? 1 : 0) | (frame.rtr ? 2 : 0) | (frame.fd ? 4 : 0) | (frame.brs ? 8 : 0);
    return ow_can_transmit(_handles[port], frame.id, flags, frame.dlc, frame.data.ptr);
}

bool can_hw_receive(uint port, out CanFrame frame)
{
    if (port >= num_can || _handles[port] is null)
        return false;
    OwCanFrame raw;
    if (!ow_can_receive(_handles[port], &raw))
        return false;
    frame.id = raw.id;
    frame.extended = (raw.flags & 1) != 0;
    frame.rtr = (raw.flags & 2) != 0;
    frame.fd = (raw.flags & 4) != 0;
    frame.brs = (raw.flags & 8) != 0;
    frame.dlc = raw.dlc;
    if (raw.dlc > 0)
        frame.data[0 .. raw.dlc] = raw.data[0 .. raw.dlc];
    return true;
}

CanError can_hw_check_errors(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return CanError.none;
    return cast(CanError)ow_can_check_errors(_handles[port]);
}

uint can_hw_take_rx_drops(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    return ow_can_take_rx_drops(_handles[port]);
}

CanBusState can_hw_bus_state(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return CanBusState.bus_off;
    return cast(CanBusState)ow_can_bus_state(_handles[port]);
}

ubyte can_hw_tx_error_count(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    uint count = ow_can_tx_error_count(_handles[port]);
    return count > 255 ? 255 : cast(ubyte)count;
}

ubyte can_hw_rx_error_count(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    uint count = ow_can_rx_error_count(_handles[port]);
    return count > 255 ? 255 : cast(ubyte)count;
}

size_t can_hw_rx_available(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    return ow_can_rx_available(_handles[port]);
}

void can_hw_rx_flush(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return;
    ow_can_rx_flush(_handles[port]);
}

Result can_hw_tx_abort(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return InternalResult.invalid_parameter;

    // ESP-IDF's node API has no queue-clear operation. Disabling and re-enabling preserves queued frame pointers, so releasing their
    // caller-owned slots here would permit the driver to transmit through reused storage.
    return InternalResult.unsupported;
}

bool can_hw_bus_recover(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return false;
    return ow_can_bus_recover(_handles[port]);
}

void can_hw_set_rx_callback(uint port, CanRxCallback cb)
{
    if (port < num_can)
        atomicStore!(MemoryOrder.release)(_rx_callback_bits[port], cast(size_t)cb);
}

private:

struct twai_node_t {}
alias twai_node_handle_t = twai_node_t*;

struct OwCanFrame
{
    uint id;
    ubyte flags;
    ubyte dlc;
    ubyte[8] data;
}

__gshared twai_node_handle_t[num_can] _handles;
__gshared CanConfig[num_can] _configs;
shared size_t[num_can] _rx_callback_bits;

extern(C) bool rx_ready_trampoline(uint port) nothrow @nogc
{
    if (port >= num_can)
        return false;
    auto cb = cast(CanRxCallback)atomicLoad!(MemoryOrder.acquire)(_rx_callback_bits[port]);
    return cb !is null ? cb(Can(cast(ubyte)port), CanCallbackContext.interrupt) : false;
}

extern(C) nothrow @nogc
{
    twai_node_handle_t ow_can_open(uint port, uint bitrate, int tx_gpio, int rx_gpio, ubyte sjw, ubyte tseg1, ubyte tseg2, ushort brp,
                                   bool function(uint) nothrow @nogc rx_cb);
    void ow_can_close(twai_node_handle_t handle);
    bool ow_can_transmit(twai_node_handle_t handle, uint id, ubyte flags, ubyte dlc, const(ubyte)* data);
    bool ow_can_receive(twai_node_handle_t handle, OwCanFrame* frame);
    uint ow_can_check_errors(twai_node_handle_t handle);
    uint ow_can_take_rx_drops(twai_node_handle_t handle);
    uint ow_can_bus_state(twai_node_handle_t handle);
    uint ow_can_tx_error_count(twai_node_handle_t handle);
    uint ow_can_rx_error_count(twai_node_handle_t handle);
    size_t ow_can_rx_available(twai_node_handle_t handle);
    void ow_can_rx_flush(twai_node_handle_t handle);
    bool ow_can_bus_recover(twai_node_handle_t handle);
}
