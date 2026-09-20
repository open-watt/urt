module urt.driver.wpan;

import urt.result : Result, InternalResult;

version (Espressif)
    public import urt.driver.esp32.wpan;
else
    enum uint num_wpan = 0;

nothrow @nogc:


// ====================================================================
// Types
// ====================================================================

// PHY constants for the 2.4GHz O-QPSK PHY, the only one these radios run.
enum ubyte wpan_min_channel = 11;
enum ubyte wpan_max_channel = 26;
enum size_t wpan_max_frame = 127;   // aMaxPhyPacketSize, includes the 2-byte FCS
enum size_t wpan_fcs_length = 2;

enum WpanTxError : ubyte
{
    none,
    cca_busy,
    aborted,
    no_ack,
    invalid_ack,
    coexist,        // rejected by the coexistence arbiter
    security,
    internal,
}

struct WpanConfig
{
    ubyte channel = wpan_min_channel;
    byte tx_power;              // dBm (0 = platform default)
    ushort pan_id = 0xFFFF;     // broadcast PAN = not joined
    ushort short_address = 0xFFFF;
    ubyte[8] extended_address;  // big-endian (display order); all zero = keep the factory EUI-64
    bool promiscuous;
}

struct WpanRxInfo
{
    byte rssi;          // dBm
    ubyte lqi;
    ubyte channel;
    bool ack_pending;   // our ack carried the frame-pending bit
}

// Delivered by wpan_service() for each received frame. Frame is the MAC frame
// starting at the frame control field, without the FCS, and remains valid
// only until the callback returns.
alias WpanRxCallback = void function(Wpan wpan, const(ubyte)[] frame, ref const WpanRxInfo info) nothrow @nogc;

// Delivered by wpan_service() when the frame given to wpan_tx() completes.
// ack is the received acknowledgement (without FCS) when the frame requested
// one and the radio received it, otherwise empty.
alias WpanTxCallback = void function(Wpan wpan, WpanTxError error, const(ubyte)[] ack, ref const WpanRxInfo ack_info) nothrow @nogc;

// Same contract as WifiReadyCallback: may fire from task or interrupt
// context, must only signal or schedule service, never re-enter the driver.
alias WpanReadyCallback = void function() nothrow @nogc;

struct Wpan
{
    ubyte port = ubyte.max;
}

bool is_open(ref const Wpan wpan)
{
    return wpan.port != ubyte.max;
}


// ====================================================================
// Implementation
// ====================================================================

void wpan_set_ready_callback(WpanReadyCallback cb)
{
    static if (num_wpan > 0)
        wpan_hw_set_ready_callback(cb);
}

Result wpan_open(ref Wpan wpan, ubyte port, ref const WpanConfig cfg)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
    {
        if (port >= num_wpan)
            return InternalResult.invalid_parameter;
        if (cfg.channel < wpan_min_channel || cfg.channel > wpan_max_channel)
            return InternalResult.invalid_parameter;
        if (!wpan_hw_open(port, cfg))
            return InternalResult.failed;
        wpan.port = port;
        return Result.success;
    }
}

void wpan_close(ref Wpan wpan)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        wpan_hw_close(wpan.port);
    wpan.port = ubyte.max;
}

Result wpan_set_channel(ref Wpan wpan, ubyte channel)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
    {
        if (channel < wpan_min_channel || channel > wpan_max_channel)
            return InternalResult.invalid_parameter;
        return wpan_hw_set_channel(wpan.port, channel) ? Result.success : InternalResult.failed;
    }
}

ubyte wpan_get_channel(ref Wpan wpan)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_get_channel(wpan.port);
}

Result wpan_set_tx_power(ref Wpan wpan, byte power_dbm)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_set_tx_power(wpan.port, power_dbm) ? Result.success : InternalResult.failed;
}

Result wpan_set_promiscuous(ref Wpan wpan, bool enable)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_set_promiscuous(wpan.port, enable) ? Result.success : InternalResult.failed;
}

Result wpan_set_pan_id(ref Wpan wpan, ushort pan_id)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_set_pan_id(wpan.port, pan_id) ? Result.success : InternalResult.failed;
}

Result wpan_set_short_address(ref Wpan wpan, ushort address)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_set_short_address(wpan.port, address) ? Result.success : InternalResult.failed;
}

// Addresses are big-endian (display order), the reverse of their on-air order.
Result wpan_set_extended_address(ref Wpan wpan, ref const ubyte[8] address)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_set_extended_address(wpan.port, address) ? Result.success : InternalResult.failed;
}

// The factory EUI-64, whatever address the radio currently runs; needs no open radio.
Result wpan_get_hardware_address(ubyte port, ref ubyte[8] address)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
    {
        if (port >= num_wpan)
            return InternalResult.invalid_parameter;
        return wpan_hw_get_hardware_address(port, address) ? Result.success : InternalResult.failed;
    }
}

Result wpan_get_extended_address(ref Wpan wpan, ref ubyte[8] address)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_get_extended_address(wpan.port, address) ? Result.success : InternalResult.failed;
}

// Transmit one MAC frame starting at the frame control field, without FCS.
// One frame is in flight at a time; the next may be submitted from the
// completion callback. The frame is copied before this returns.
Result wpan_tx(ref Wpan wpan, const(ubyte)[] frame, bool cca = true)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
    {
        if (frame.length == 0 || frame.length + wpan_fcs_length > wpan_max_frame)
            return InternalResult.invalid_parameter;
        return wpan_hw_tx(wpan.port, frame, cca) ? Result.success : InternalResult.failed;
    }
}

void wpan_set_rx_callback(ref Wpan wpan, WpanRxCallback cb)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        wpan_hw_set_rx_callback(wpan.port, cb);
}

void wpan_set_tx_callback(ref Wpan wpan, WpanTxCallback cb)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        wpan_hw_set_tx_callback(wpan.port, cb);
}

// Deliver queued frames and completions in caller context; returns true when
// work remains after budget callbacks.
bool wpan_service(ref Wpan wpan, size_t budget = 16)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_service(wpan.port, budget);
}

uint wpan_take_rx_drops(ref Wpan wpan)
{
    static if (num_wpan == 0)
        assert(false, "no 802.15.4 radio on this platform");
    else
        return wpan_hw_take_rx_drops(wpan.port);
}
