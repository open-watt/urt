module sys.baremetal.can;

import urt.result : Result, InternalResult;

version (Espressif)
    public import sys.esp32.can;
else
{
    enum uint num_can = 0;
    enum bool has_can_fd = false;
}

nothrow @nogc:


enum CanError : ubyte
{
    none        = 0,
    bit         = 1 << 0, // bit error (dominant/recessive mismatch)
    stuff       = 1 << 1, // bit stuffing violation
    crc         = 1 << 2, // CRC mismatch
    form        = 1 << 3, // fixed-form bit field violation
    ack         = 1 << 4, // no ACK from any receiver
    overrun     = 1 << 5, // RX FIFO overflow
}

enum CanBusState : ubyte
{
    error_active,   // TEC/REC < 128, normal operation
    error_warning,  // TEC or REC >= 96
    error_passive,  // TEC or REC >= 128, can't send active error frames
    bus_off,        // TEC >= 256, node disconnected from bus
}

struct CanConfig
{
    uint bitrate = 500_000;     // nominal bitrate (bits/s)
    uint data_bitrate;          // FD data phase bitrate (0 = classic CAN only)
    ubyte tx_gpio = ubyte.max;  // GPIO pin for TX (max = platform default)
    ubyte rx_gpio = ubyte.max;  // GPIO pin for RX (max = platform default)

    // Bit timing (0 = auto-calculate from bitrate)
    ubyte sjw;          // synchronization jump width (1-4 TQ)
    ubyte tseg1;        // time segment 1 / prop + phase1 (1-16 TQ)
    ubyte tseg2;        // time segment 2 / phase2 (1-8 TQ)
    ushort brp;         // baud rate prescaler (1-1024)
}

struct CanFrame
{
    uint id;            // 11-bit standard or 29-bit extended
    bool extended;      // true = 29-bit ID, false = 11-bit
    bool rtr;           // remote transmission request
    bool fd;            // CAN FD frame (up to 64 bytes, DLC 9-15 = 12..64)
    bool brs;           // FD bit rate switch (data phase at data_bitrate)
    ubyte dlc;          // data length code (0-8 classic, 0-15 FD)
    ubyte[8] data;      // classic CAN payload (FD >8 bytes needs external buffer)
}

struct CanFilter
{
    uint id;            // ID to match
    uint mask;          // 1-bits = must match, 0-bits = don't care
    bool extended;      // match extended frames only
    bool rtr;           // match RTR frames only
    bool match_all;     // ignore id/mask, accept everything (default)
}

// Called from ISR when a frame has been received.
alias CanRxCallback = void function(Can can, ref const CanFrame frame) nothrow @nogc;

// Called from ISR when a TX mailbox becomes free.
alias CanTxCallback = void function(Can can) nothrow @nogc;

// Called when bus state changes (error active/passive/bus-off).
alias CanBusStateCallback = void function(Can can, CanBusState state) nothrow @nogc;

// Caller-owned transmit operation token.
struct CanTxOp
{
    enum Status : ubyte
    {
        idle,
        pending,
        complete,
        cancelled,
        error,
        arbitration_lost,
    }

    alias Callback = void function(Can* can, ref CanTxOp op) nothrow @nogc;

    Status status;
    void* user_data;
    Callback cb;

    bool is_pending() const => status == Status.pending;
    bool is_done() const => status >= Status.complete;
}

struct Can
{
    ubyte port = ubyte.max;
}

bool is_open(ref const Can can)
{
    return can.port != ubyte.max;
}


// ════════════════════════════════════════════════════════════════════
// Error type
// ════════════════════════════════════════════════════════════════════

CanError can_result(Result result)
{
    return cast(CanError)result.system_code;
}


// ════════════════════════════════════════════════════════════════════
// Implementation
// ════════════════════════════════════════════════════════════════════

// Lifecycle

void can_init()
{
    if (_init_refcount++ == 0)
    {
        // TODO: enable clocks/power for CAN peripheral block
    }
}

void can_deinit()
{
    assert(_init_refcount > 0);
    if (--_init_refcount == 0)
    {
        // TODO: disable clocks/power for CAN peripheral block
    }
}

// Port operations

Result can_open(ref Can can, ubyte port, ref const CanConfig cfg, CanRxCallback rx_cb = null)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
    {
        if (port >= num_can)
            return InternalResult.invalid_parameter;

        if (!can_open(port, cfg))
            return InternalResult.failed;

        can.port = port;
        return Result.success;
    }
}

Result can_reconfigure(ref Can can, ref const CanConfig cfg)
{
    assert(false, "TODO: can_reconfigure (hot reconfigure)");
}

void can_close(ref Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        can_close(can.port);
    can.port = ubyte.max;
}

// Transmit

int can_transmit(ref Can can, ref const CanFrame frame, CanTxOp* op = null)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
    {
        int ret = can_transmit(can.port, frame);
        if (op !is null)
        {
            op.status = ret >= 0 ? CanTxOp.Status.complete : CanTxOp.Status.error;
            if (op.cb !is null)
                op.cb(&can, *op);
        }
        return ret;
    }
}

void can_tx_abort(ref Can can, CanTxOp* op)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
    {
        can_tx_abort(can.port);
        if (op !is null)
        {
            op.status = CanTxOp.Status.cancelled;
            if (op.cb !is null)
                op.cb(&can, *op);
        }
    }
}

// Receive

bool can_receive(ref Can can, out CanFrame frame)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        return can_receive(can.port, frame);
}

size_t can_rx_available(ref const Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        return can_rx_available(can.port);
}

void can_rx_flush(ref Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        can_rx_flush(can.port);
}

// Filters

Result can_filter_set(ref Can can, ubyte slot, ref const CanFilter filter)
{
    assert(false, "TODO: can_filter_set");
}

Result can_filter_clear(ref Can can, ubyte slot)
{
    assert(false, "TODO: can_filter_clear");
}

void can_filter_clear_all(ref Can can)
{
    assert(false, "TODO: can_filter_clear_all");
}

// Bus status

CanBusState can_bus_state(ref const Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        return can_bus_state(can.port);
}

ubyte can_tx_error_count(ref const Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        return can_tx_error_count(can.port);
}

ubyte can_rx_error_count(ref const Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        return can_rx_error_count(can.port);
}

CanError can_check_errors(ref Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        return can_check_errors(can.port);
}

// Bus recovery

Result can_bus_recover(ref Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
    {
        if (can_bus_recover(can.port))
            return Result.success;
        return InternalResult.failed;
    }
}

// Callbacks

void can_set_rx_callback(ref Can can, CanRxCallback cb)
{
    assert(false, "TODO: can_set_rx_callback");
}

void can_set_tx_callback(ref Can can, CanTxCallback cb)
{
    assert(false, "TODO: can_set_tx_callback");
}

void can_set_bus_state_callback(ref Can can, CanBusStateCallback cb)
{
    assert(false, "TODO: can_set_bus_state_callback");
}

// Poll (for polled mode - check HW FIFOs and invoke callbacks)

void can_poll(ref Can can)
{
    static if (num_can == 0)
        assert(false, "no CAN on this platform");
    else
        can_poll(can.port);
}


// ════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════

unittest
{
    static if (num_can > 0)
    {
        Can c;
        CanConfig cfg;

        can_init();

        // Out-of-range port
        auto r = can_open(c, cast(ubyte)num_can, cfg);
        assert(!r);
        assert(!c.is_open);

        // Open/close each valid port
        foreach (p; 0 .. num_can)
        {
            Can port;
            auto r2 = can_open(port, cast(ubyte)p, cfg);
            assert(r2, "can_open failed");
            assert(port.is_open);
            assert(port.port == p);

            can_poll(port);

            assert(can_check_errors(port) == CanError.none);

            can_close(port);
            assert(!port.is_open);
        }

        can_deinit();
    }
}


private:

__gshared ubyte _init_refcount;
