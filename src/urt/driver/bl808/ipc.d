/// BL808 inter-processor communication
///
/// Initializes XRAM ring buffers and provides typed send/receive
/// for peripheral commands and network frames.
module urt.driver.bl808.ipc;

import urt.driver.bl808.xram;

@nogc nothrow:

/// Global ring buffer handles (initialized by ipc_init)
__gshared XramRing[RingId.max] rings;

/// Initialize all XRAM ring buffers from the shared memory layout.
/// Call once at startup after M0 has initialized the XRAM region.
void ipc_init()
{
    // TODO: read ring layout from XRAM_BASE
    // The M0 firmware sets up ring_pos structures at fixed offsets.
    // For now this is a placeholder — actual offsets need to be
    // determined by examining the running M0 firmware's XRAM layout.
}

/// Send a peripheral command (GPIO/SPI/PWM/Flash)
bool peri_send(PeriType type, const(ubyte)[] payload)
{
    PeriHeader hdr;
    hdr.type = type;
    hdr.err = 0;
    hdr.len = cast(ushort) payload.length;

    auto written = rings[RingId.peripheral].write((cast(ubyte*)&hdr)[0 .. 4]);
    if (written != PeriHeader.sizeof)
        return false;

    if (payload.length > 0)
    {
        written = rings[RingId.peripheral].write(payload);
        if (written != payload.length)
            return false;
    }
    return true;
}

/// Receive a peripheral response header. Returns false if ring is empty.
bool peri_recv(ref PeriHeader hdr)
{
    return PeriHeader.sizeof == rings[RingId.peripheral].read((cast(ubyte*)&hdr)[0 .. 4]);
}
