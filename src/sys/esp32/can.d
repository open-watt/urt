// ESP32 CAN (TWAI) driver -- thin D layer over ESP-IDF _v2 handle API
//
// Only ow_can_open is a C shim (bitrate table + config construction).
// All other calls go directly to the ESP-IDF twai_*_v2 functions.
//
// Controller count per chip (ESP-IDF v6.0):
//   ESP32, S3, C3, H2: 1    C5, C6: 2    P4: 3    S2, C2, C61: 0
module sys.esp32.can;

import sys.baremetal.can : CanConfig, CanFrame, CanError, CanBusState;

nothrow @nogc:


// SOC_TWAI_CONTROLLER_NUM per chip variant (ESP-IDF v6.0 soc_caps.h)
version (ESP32)         enum uint num_can = 1;
else version (ESP32_S3) enum uint num_can = 1;
else version (ESP32_P4) enum uint num_can = 3;
else version (ESP32_C3) enum uint num_can = 1;
else version (ESP32_C5) enum uint num_can = 2;
else version (ESP32_C6) enum uint num_can = 2;
else version (ESP32_H2) enum uint num_can = 1;
else                    enum uint num_can = 0; // S2, C2, C61

// SOC_TWAI_FD_SUPPORTED (ESP-IDF v6.0 soc_caps.h)
version (ESP32_C5) enum bool has_can_fd = true;
else               enum bool has_can_fd = false;


static if (num_can > 0):


bool can_open(uint port, ref const CanConfig cfg)
{
    if (port >= num_can)
        return false;
    if (_handles[port] !is null)
        return true;
    int tx = cfg.tx_gpio == ubyte.max ? -1 : cast(int)cfg.tx_gpio;
    int rx = cfg.rx_gpio == ubyte.max ? -1 : cast(int)cfg.rx_gpio;
    _handles[port] = ow_can_open(port, cfg.bitrate, tx, rx,
        cfg.sjw, cfg.tseg1, cfg.tseg2, cfg.brp);
    return _handles[port] !is null;
}

void can_close(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return;
    twai_stop_v2(_handles[port]);
    twai_driver_uninstall_v2(_handles[port]);
    _handles[port] = null;
}

int can_transmit(uint port, ref const CanFrame frame)
{
    if (port >= num_can || _handles[port] is null)
        return -1;
    twai_message_t msg;
    msg.flags = cast(uint)frame.extended | (cast(uint)frame.rtr << 1);
    msg.identifier = frame.id;
    msg.data_length_code = frame.dlc;
    if (frame.dlc > 0)
        msg.data[0 .. frame.dlc] = frame.data[0 .. frame.dlc];
    return twai_transmit_v2(_handles[port], &msg, 0) == ESP_OK ? 0 : -1;
}

bool can_receive(uint port, out CanFrame frame)
{
    if (port >= num_can || _handles[port] is null)
        return false;
    twai_message_t msg;
    if (twai_receive_v2(_handles[port], &msg, 0) != ESP_OK)
        return false;
    frame.id = msg.identifier;
    frame.extended = (msg.flags & 1) != 0;
    frame.rtr = (msg.flags & 2) != 0;
    frame.dlc = msg.data_length_code;
    if (msg.data_length_code > 0)
        frame.data[0 .. msg.data_length_code] = msg.data[0 .. msg.data_length_code];
    return true;
}

CanError can_check_errors(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return CanError.none;
    uint alerts;
    twai_read_alerts_v2(_handles[port], &alerts, 0);
    CanError err = CanError.none;
    if (alerts & 0x0200) // TWAI_ALERT_BUS_ERROR
        err |= CanError.bit;
    if (alerts & 0x4800) // TWAI_ALERT_RX_FIFO_OVERRUN | RX_QUEUE_FULL
        err |= CanError.overrun;
    if (alerts & 0x0400) // TWAI_ALERT_TX_FAILED
        err |= CanError.ack;
    return err;
}

CanBusState can_bus_state(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return CanBusState.bus_off;
    twai_status_info_t info;
    if (twai_get_status_info_v2(_handles[port], &info) != ESP_OK)
        return CanBusState.bus_off;
    if (info.state >= 2) // BUS_OFF or RECOVERING
        return CanBusState.bus_off;
    if (info.tx_error_counter >= 128 || info.rx_error_counter >= 128)
        return CanBusState.error_passive;
    if (info.tx_error_counter >= 96 || info.rx_error_counter >= 96)
        return CanBusState.error_warning;
    return CanBusState.error_active;
}

ubyte can_tx_error_count(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    twai_status_info_t info;
    if (twai_get_status_info_v2(_handles[port], &info) != ESP_OK)
        return 0;
    return info.tx_error_counter > 255 ? 255 : cast(ubyte)info.tx_error_counter;
}

ubyte can_rx_error_count(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    twai_status_info_t info;
    if (twai_get_status_info_v2(_handles[port], &info) != ESP_OK)
        return 0;
    return info.rx_error_counter > 255 ? 255 : cast(ubyte)info.rx_error_counter;
}

size_t can_rx_available(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return 0;
    twai_status_info_t info;
    if (twai_get_status_info_v2(_handles[port], &info) != ESP_OK)
        return 0;
    return cast(size_t)info.msgs_to_rx;
}

void can_rx_flush(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return;
    twai_clear_receive_queue_v2(_handles[port]);
}

void can_tx_abort(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return;
    twai_clear_transmit_queue_v2(_handles[port]);
}

bool can_bus_recover(uint port)
{
    if (port >= num_can || _handles[port] is null)
        return false;
    return twai_initiate_recovery_v2(_handles[port]) == ESP_OK;
}

void can_poll(uint port)
{
    // TWAI driver buffers RX internally
}


private:

enum int ESP_OK = 0;

// Opaque ESP-IDF TWAI handle
struct twai_obj_t {}
alias twai_handle_t = twai_obj_t*;

// ESP-IDF twai_message_t (flags union flattened to uint)
struct twai_message_t
{
    uint flags;             // bit 0: extd, bit 1: rtr, bit 2: ss, bit 3: self
    uint identifier;
    ubyte data_length_code;
    ubyte[8] data;
}

// ESP-IDF twai_status_info_t
struct twai_status_info_t
{
    int state;              // 0=STOPPED, 1=RUNNING, 2=BUS_OFF, 3=RECOVERING
    uint msgs_to_tx;
    uint msgs_to_rx;
    uint tx_error_counter;
    uint rx_error_counter;
    uint tx_failed_count;
    uint rx_missed_count;
    uint rx_overrun_count;
    uint arb_lost_count;
    uint bus_error_count;
}

__gshared twai_handle_t[num_can] _handles;

extern(C) nothrow @nogc
{
    // Shim -- bitrate table + config construction + install + start
    twai_handle_t ow_can_open(uint port, uint bitrate, int tx_gpio, int rx_gpio, ubyte sjw, ubyte tseg1, ubyte tseg2, ushort brp);

    // Direct ESP-IDF v2 calls
    int twai_stop_v2(twai_handle_t handle);
    int twai_driver_uninstall_v2(twai_handle_t handle);
    int twai_transmit_v2(twai_handle_t handle, const(twai_message_t)* message, uint ticks_to_wait);
    int twai_receive_v2(twai_handle_t handle, twai_message_t* message, uint ticks_to_wait);
    int twai_read_alerts_v2(twai_handle_t handle, uint* alerts, uint ticks_to_wait);
    int twai_get_status_info_v2(twai_handle_t handle, twai_status_info_t* status_info);
    int twai_initiate_recovery_v2(twai_handle_t handle);
    int twai_clear_receive_queue_v2(twai_handle_t handle);
    int twai_clear_transmit_queue_v2(twai_handle_t handle);
}
