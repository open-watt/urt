/// BL808 XRAM inter-processor communication
///
/// D0 ↔ M0 shared memory ring buffers at 0x2202_0000 (16KB).
/// Each ring has 16-bit head/tail cursors in shared memory,
/// requiring volatile access and memory barriers.
///
/// Ring IDs (fixed by M0 firmware):
///   0 = LOG_C906    D0 log output
///   1 = LOG_E902    LP core log
///   2 = NET         Ethernet frames (WiFi bridge)
///   3 = PERIPHERAL  GPIO/SPI/PWM/Flash control
///   4 = RPC         Remote procedure calls
module sys.bl808.xram;

import core.volatile;

@nogc nothrow:

// ================================================================
// Constants
// ================================================================

enum ulong XRAM_BASE = 0x2202_0000;
enum uint  XRAM_SIZE = 16 * 1024;

enum RingId : uint
{
    log_c906    = 0,
    log_e902    = 1,
    net         = 2,
    peripheral  = 3,
    rpc         = 4,
    max         = 5,
}

// ================================================================
// Peripheral message header (4 bytes)
// Used on PERIPHERAL ring for GPIO/SPI/PWM/Flash ops
// ================================================================

struct PeriHeader
{
    ubyte  type;
    ubyte  err;
    ushort len;
}

enum PeriType : ubyte
{
    flash = 0x31,
    pwm   = 0x32,
    spi   = 0x33,
}

// ================================================================
// Net message header (12 bytes)
// Used on NET ring for Ethernet frames and WiFi commands
// ================================================================

struct NetHeader
{
    ubyte[4] magic;     // "ring" = [0x72, 0x69, 0x6e, 0x67]
    ushort   len;
    ubyte    type;      // high nibble: msg type, low nibble: dev type
    ubyte    flag;
    ushort   crc16;
    ushort   reserved;
}

enum NetMsgType : ubyte
{
    command      = 0,
    frame        = 1,
    sniffer_pkt  = 2,
}

// ================================================================
// WiFi operation commands
// ================================================================

enum WifiOp : uint
{
    init_           = 0,
    deinit          = 1,
    connect         = 2,
    disconnect      = 3,
    upload_stream   = 4,
}

struct WifiConnect
{
    char[32] ssid;
    char[63] passwd;
}

// ================================================================
// Shared-memory ring buffer
//
// Layout in XRAM (set by M0 firmware):
//   struct { uint16_t head, tail; uint32_t buffer_size; uint8_t buffer[]; }
//
// Head is advanced by the reader, tail by the writer.
// Both cores access these via volatile loads/stores.
// ================================================================

struct XramRing
{
    @nogc nothrow @trusted:

    ushort* head_ptr;
    ushort* tail_ptr;
    ubyte*  buffer_ptr;
    uint    buffer_size;

    /// Bytes available to read
    uint pending()
    {
        uint h = volatileLoad(head_ptr);
        uint t = volatileLoad(tail_ptr);
        if (t >= h)
            return t - h;
        else
            return buffer_size - h + t;
    }

    /// Bytes available to write
    uint available()
    {
        uint h = volatileLoad(head_ptr);
        uint t = volatileLoad(tail_ptr);
        if (t >= h)
            return buffer_size - t + h - 1;
        else
            return h - t - 1;
    }

    bool empty()
    {
        return volatileLoad(head_ptr) == volatileLoad(tail_ptr);
    }

    void reset()
    {
        volatileStore(head_ptr, cast(ushort) 0);
        volatileStore(tail_ptr, cast(ushort) 0);
        fence();
    }

    /// Read up to dst.length bytes from the ring. Returns bytes read.
    uint read(ubyte[] dst)
    {
        fence(); // ensure we see latest writes from other core

        uint h = volatileLoad(head_ptr);
        uint t = volatileLoad(tail_ptr);
        uint avail = (t >= h) ? (t - h) : (buffer_size - h + t);
        uint len = (dst.length < avail) ? cast(uint) dst.length : avail;

        if (len == 0)
            return 0;

        uint first = buffer_size - h;
        if (len <= first)
        {
            dst[0 .. len] = buffer_ptr[h .. h + len];
            h += len;
            if (h == buffer_size)
                h = 0;
        }
        else
        {
            dst[0 .. first] = buffer_ptr[h .. buffer_size];
            uint second = len - first;
            dst[first .. len] = buffer_ptr[0 .. second];
            h = second;
        }

        fence(); // ensure our reads complete before advancing head
        volatileStore(head_ptr, cast(ushort) h);
        return len;
    }

    /// Write data to the ring. Returns bytes written.
    uint write(const(ubyte)[] src)
    {
        uint h = volatileLoad(head_ptr);
        uint t = volatileLoad(tail_ptr);
        uint space = (t >= h) ? (buffer_size - t + h - 1) : (h - t - 1);
        uint len = (src.length < space) ? cast(uint) src.length : space;

        if (len == 0)
            return 0;

        uint tail_room = buffer_size - t;
        if (len <= tail_room)
        {
            buffer_ptr[t .. t + len] = src[0 .. len];
            t += len;
            if (t == buffer_size)
                t = 0;
        }
        else
        {
            buffer_ptr[t .. buffer_size] = src[0 .. tail_room];
            uint second = len - tail_room;
            buffer_ptr[0 .. second] = src[tail_room .. len];
            t = second;
        }

        fence(); // ensure writes visible before advancing tail
        volatileStore(tail_ptr, cast(ushort) t);
        return len;
    }
}

/// Memory barrier — RISC-V fence instruction
private void fence() @nogc nothrow
{
    version (RISCV64)
        asm @nogc nothrow { "fence rw, rw"; }
    else version (RISCV32)
        asm @nogc nothrow { "fence rw, rw"; }
    else
        asm @nogc nothrow { ""; }
}
