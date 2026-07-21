// Linux GPIO via legacy /sys/class/gpio sysfs. Targets SBCs (Pi, Orange
// Pi, BeagleBone) where the kernel exposes pins as files. Pin numbering
// is the kernel's flat global GPIO number; each board documents its
// mapping.
//
// Sysfs is deprecated since Linux 4.8 in favour of gpio-cdev
// (/dev/gpiochipN ioctl) but ships in every shipping kernel. cdev
// backend is a future TODO.
//
// Limitations: no pull config (sysfs doesn't expose it; pulls come from
// device tree or external resistors), no peripheral muxing (kernel
// owns it), and one open/close per op (~10us each, fine for management
// rates).
module urt.driver.posix.gpio;

import urt.driver.gpio : Pull, DriveMode, GpioEdge;
import urt.file : File, FileOpenMode, save_file, open, close, read;
import urt.mem.temp : tconcat;
import urt.result : Result;
import urt.time : getTime, MonoTime, SysTime, msecs, get_sys_time, unix_time_ns, from_unix_time_ns;

import sys = urt.internal.sys.posix;
import sock = urt.socket;
import urt.inet : IPAddr, InetAddress;

nothrow @nogc:


enum uint num_gpio = 256;
enum bool has_pull_up = false;
enum bool has_pull_down = false;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = false;


// Walks /sys/class/gpio/gpiochip<N>/{base,ngpio} for N in 0..64 (covers
// real SBCs incl. Pi 5 where chips are at 0 and 4) and returns
// max(base+ngpio). 0 means no GPIO chips registered in sysfs.
uint gpio_count()
{
    uint max_pin = 0;
    foreach (i; 0 .. 64)
    {
        uint base, ngpio;
        if (!read_uint_file(tconcat("/sys/class/gpio/gpiochip", i, "/base"), base))
            continue;
        if (!read_uint_file(tconcat("/sys/class/gpio/gpiochip", i, "/ngpio"), ngpio))
            continue;
        uint top = base + ngpio;
        if (top > max_pin)
            max_pin = top;
    }
    return max_pin;
}

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(mode == DriveMode.push_pull, "posix gpio: open-drain not supported via sysfs");
    save_file("/sys/class/gpio/export", tconcat(pin));   // EBUSY = already exported
    // "low" / "high" atomically set direction=out plus initial value.
    save_file(tconcat("/sys/class/gpio/gpio", pin, "/direction"), initial ? "high" : "low");
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    save_file("/sys/class/gpio/export", tconcat(pin));
    save_file(tconcat("/sys/class/gpio/gpio", pin, "/direction"), "in");
}

void gpio_output_set(uint pin, bool value)
{
    save_file(tconcat("/sys/class/gpio/gpio", pin, "/value"), value ? "1" : "0");
}

void gpio_output_toggle(uint pin)
{
    auto path = tconcat("/sys/class/gpio/gpio", pin, "/value");
    bool current;
    if (!read_bool_file(path, current))
        return;
    save_file(path, current ? "0" : "1");
}

bool gpio_input_read(uint pin)
{
    bool v;
    return read_bool_file(tconcat("/sys/class/gpio/gpio", pin, "/value"), v) && v;
}

void gpio_set_pull(uint pin, Pull pull)
{
}

void gpio_release(uint pin)
{
    save_file("/sys/class/gpio/unexport", tconcat(pin));
}


// Realtime edge sampler with two linux backends chosen at runtime by gpio_sampler_open: gpio-cdev
// v2 (portable default; the kernel timestamps in the edge ISR, so jittered under load), and the
// pigpiod daemon over its socket interface (127.0.0.1:8888) when running - the DMA sampler stamps
// from the free-running system timer, immune to IRQ latency, and its notify socket is a pollable fd
// like the cdev line fd. No Pi 5 (RP1) support, so we connect-to-detect. Both expose one surface:
// an fd for the reactor, decode() (advances the slice, call in a loop until it returns 0; pigpio
// reassembles reports split across reactor reads, cdev events are kernel-aligned), drain(), close().
//
// pigpio ticks are 32-bit microseconds since boot (wrap ~71.6 min) from a non-POSIX clock;
// correlate() anchors tick->wall via min-RTT get_current_tick probes.
// TODO: a native-tick ClockDomain (MONOTONIC base) instead of the unix ns decode() projects here.

enum bool has_gpio_sampler = true;

enum Backend : ubyte
{
    cdev,
    pigpio,
}

struct GpioSampler
{
nothrow @nogc:
    @disable this(this);        // decode is a delegate bound to this instance; must not be copied

    int fd = -1;                // cdev: the line fd. pigpio: the notification socket (reactor-watched).
    Backend backend;

    size_t delegate(ref const(void)[] data, GpioEdge[] events) nothrow @nogc decode;

    bool valid() const pure
        => fd >= 0;

    size_t drain(GpioEdge[] events)
    {
        size_t count = 0;
        ubyte[2048] buf = void;
        size_t rec = backend == Backend.pigpio ? gpioReport.sizeof : gpio_v2_line_event.sizeof;
        while (count < events.length)
        {
            // read at most what `events` can still hold, so we never decode past it and drop the rest
            size_t want = (events.length - count) * rec;
            if (want > buf.length)
                want = buf.length;
            sys.ssize_t r = sys.read(fd, buf.ptr, want);
            if (r <= 0)
                break;
            const(void)[] data = buf[0 .. cast(size_t)r];
            count += decode(data, events[count .. $]);
        }
        return count;
    }

    void close()
    {
        final switch (backend)
        {
            case Backend.cdev:
                if (fd >= 0)
                    sys.close(fd);
                break;

            case Backend.pigpio:
                if (fd >= 0)
                    sock.close(sock.Socket(fd));
                if (_cmd_fd >= 0)
                    sock.close(sock.Socket(_cmd_fd));
                _cmd_fd = -1;
                break;
        }
        fd = -1;
    }

    // Correlate the native sample clock to wall, for the binding to pin its ClockDomain anchor:
    // returns a (tick, wall) pair and err_ns (the +/- on it). pigpio min-RTT-filters a get_current_tick
    // RPC; cdev reads CLOCK_MONOTONIC and CLOCK_REALTIME back-to-back.
    bool correlate(out ulong tick, out SysTime wall, out ulong err_ns)
    {
        final switch (backend)
        {
            case Backend.pigpio: return correlate_pigpio(tick, wall, err_ns);
            case Backend.cdev:   return correlate_cdev(tick, wall, err_ns);
        }
    }

    const(char)[] backend_name() const pure
        => backend == Backend.pigpio ? "pigpio" : "cdev";

    // pigpio's fd is a TCP socket, so a 0-byte read is a daemon disconnect, not "drained"
    bool socket_backed() const pure
        => backend == Backend.pigpio;

    // both backends emit microsecond ticks (pigpio STC us; cdev CLOCK_MONOTONIC ns decimated to us)
    uint clock_hz() const pure
        => 1_000_000;

private:

    // pigpio state, main-thread only (reactor reads the socket, update() runs correlate()), so unlocked
    int _cmd_fd = -1;
    ubyte _gpio;
    ubyte _carry_len;
    ubyte[gpioReport.sizeof] _carry = void;
    bool _have_tick;
    ushort _last_seqno;
    uint _last_tick;
    ulong _tick_wraps;

    size_t decode_cdev(ref const(void)[] data, GpioEdge[] events)
    {
        size_t n = 0;
        while (n < events.length && data.length >= gpio_v2_line_event.sizeof)
        {
            auto ev = cast(const(gpio_v2_line_event)*)data.ptr;
            events[n++] = GpioEdge(ev.timestamp_ns / 1000, ev.id == GPIO_V2_LINE_EVENT_RISING_EDGE);   // CLOCK_MONOTONIC ns -> us
            data = data[gpio_v2_line_event.sizeof .. $];
        }
        return n;
    }

    size_t decode_pigpio(ref const(void)[] data, GpioEdge[] events)
    {
        if (events.length == 0)
            return 0;

        size_t n = 0;

        if (_carry_len)
        {
            while (_carry_len < gpioReport.sizeof && data.length)
            {
                _carry[_carry_len++] = (cast(const(ubyte)[])data)[0];
                data = data[1 .. $];
            }
            if (_carry_len < gpioReport.sizeof)
                return n;
            gpioReport rep = void;
            (cast(ubyte*)&rep)[0 .. gpioReport.sizeof] = _carry[0 .. gpioReport.sizeof];
            emit(rep, events, n);
            _carry_len = 0;
        }

        while (n < events.length && data.length >= gpioReport.sizeof)
        {
            emit(*cast(const(gpioReport)*)data.ptr, events, n);
            data = data[gpioReport.sizeof .. $];
        }

        // a genuine partial tail is stashed; full records left in `data` are for the next call
        if (data.length && data.length < gpioReport.sizeof)
        {
            _carry_len = cast(ubyte)data.length;
            _carry[0 .. _carry_len] = cast(const(ubyte)[])data;
            data = data[$ .. $];
        }
        return n;
    }

    // n advances only for real level-change reports; callers guarantee n < events.length.
    void emit(ref const gpioReport r, GpioEdge[] events, ref size_t n)
    {
        _last_seqno = r.seqno;      // TODO: seqno gaps -> series mark_gap (daemon queue overflow)

        ulong tick = unwrap(r.tick);
        if (r.flags != 0)
            return;                 // ALIVE keepalive / WDOG / EVENT: not a level change

        bool level = ((r.level >> _gpio) & 1) != 0;
        events[n++] = GpioEdge(tick, level);
    }

    ulong unwrap(uint tick)
    {
        if (_have_tick && tick < _last_tick)
            ++_tick_wraps;
        _last_tick = tick;
        _have_tick = true;
        return (_tick_wraps << 32) + tick;
    }

    // Unwrap a correlation-probe tick WITHOUT disturbing the edge-stream unwrap state: a probe reads
    // the STC out of band, so feeding it to unwrap() would advance _last_tick and false-wrap a
    // buffered edge decoded afterwards.
    ulong peek_unwrap(uint tick) const
    {
        ulong wraps = _tick_wraps;
        if (_have_tick && tick < _last_tick)
            ++wraps;
        return (wraps << 32) + tick;
    }

    bool correlate_pigpio(out ulong tick, out SysTime wall, out ulong err_ns)
    {
        if (_cmd_fd < 0)
            return false;

        ulong best_rtt = ulong.max, best_tick, best_wall;
        foreach (_; 0 .. 32)
        {
            ulong w0 = unix_time_ns(get_sys_time());
            uint t;
            if (!pigpio_cmd(_cmd_fd, PI_CMD_TICK, 0, 0, t))
                break;
            ulong w1 = unix_time_ns(get_sys_time());
            ulong rtt = w1 - w0;
            if (rtt < best_rtt)
            {
                best_rtt = rtt;
                best_tick = peek_unwrap(t);
                best_wall = w0 + rtt / 2;
            }
        }
        if (best_rtt == ulong.max)
            return false;
        tick = best_tick;
        wall = from_unix_time_ns(best_wall);
        err_ns = best_rtt;
        return true;
    }

    bool correlate_cdev(out ulong tick, out SysTime wall, out ulong err_ns)
    {
        MonoTime m0 = getTime();
        wall = get_sys_time();
        MonoTime m1 = getTime();
        tick = ((m0.ticks + m1.ticks) / 2) / 1000;   // us
        err_ns = m1.ticks - m0.ticks;
        return true;
    }
}

Result gpio_sampler_open(uint chip, uint line, out GpioSampler sampler, Pull pull = Pull.none, uint debounce_us = 0)
{
    // pigpio only knows the single Broadcom bank (chip 0); it also falls back to cdev when the
    // daemon isn't running (connect refused) or the handshake fails
    if (chip == 0 && pigpio_open(line, sampler, pull, debounce_us))
        return Result.success;
    return cdev_open(chip, line, sampler, pull, debounce_us);
}


private:

Result cdev_open(uint chip, uint line, out GpioSampler sampler, Pull pull, uint debounce_us)
{
    import urt.internal.stdc.errno : errno;

    int cfd = sys.open(tconcat("/dev/gpiochip", chip, "\0").ptr, sys.O_RDONLY | sys.O_CLOEXEC);
    if (cfd < 0)
        return Result(errno ? cast(uint)errno : 1);

    gpio_v2_line_request req;
    req.offsets[0] = line;
    req.consumer[0 .. 8] = "openwatt";
    // default event clock is CLOCK_MONOTONIC (matches getTime); we decimate ns -> us in decode
    req.config.flags = GPIO_V2_LINE_FLAG_INPUT | GPIO_V2_LINE_FLAG_EDGE_RISING |
                       GPIO_V2_LINE_FLAG_EDGE_FALLING;
    if (pull == Pull.up)
        req.config.flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_UP;
    else if (pull == Pull.down)
        req.config.flags |= GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN;
    if (debounce_us)
    {
        req.config.num_attrs = 1;
        req.config.attrs[0].attr.id = GPIO_V2_LINE_ATTR_ID_DEBOUNCE;
        req.config.attrs[0].attr.debounce_period_us = debounce_us;
        req.config.attrs[0].mask = 1;
    }
    req.num_lines = 1;
    req.event_buffer_size = 1024;

    int r = ioctl(cfd, GPIO_V2_GET_LINE_IOCTL, &req);
    sys.close(cfd);
    if (r < 0 || req.fd < 0)
        return Result(errno ? cast(uint)errno : 1);

    int fl = sys.fcntl(req.fd, sys.F_GETFL, 0);
    sys.fcntl(req.fd, sys.F_SETFL, fl | sys.O_NONBLOCK);

    sampler.backend = Backend.cdev;
    sampler.fd = req.fd;
    sampler.decode = &sampler.decode_cdev;
    return Result.success;
}


// pigpio daemon socket interface (abyz.me.uk/rpi/pigpio/sif.html). Command codes verified against
// pigpio.h; the gpioReport layout and NTFY flags against the C interface reference.

enum ushort PIGPIO_PORT = 8888;

enum : uint
{
    PI_CMD_MODES = 0,
    PI_CMD_PUD   = 2,
    PI_CMD_TICK  = 16,
    PI_CMD_NB    = 19,
    PI_CMD_NC    = 21,
    PI_CMD_FG    = 97,
    PI_CMD_NOIB  = 99,
}

enum uint PI_INPUT = 0;
enum uint PI_PUD_OFF = 0, PI_PUD_DOWN = 1, PI_PUD_UP = 2;    // pigpio order; urt Pull is none/up/down

struct PigpioMsg
{
    uint cmd, p1, p2, p3;       // p3 is the result on responses
}
static assert(PigpioMsg.sizeof == 16);

struct gpioReport
{
    ushort seqno;
    ushort flags;
    uint tick;
    uint level;
}
static assert(gpioReport.sizeof == 12);

bool pigpio_open(uint line, out GpioSampler sampler, Pull pull, uint debounce_us)
{
    auto addr = InetAddress(IPAddr.loopback, PIGPIO_PORT);

    sock.Socket cmd;
    if (sock.create_socket(sock.AddressFamily.ipv4, sock.SocketType.stream, sock.Protocol.tcp, cmd).failed)
        return false;
    if (sock.connect(cmd, addr).failed)
    {
        sock.close(cmd);
        return false;
    }
    sock.set_socket_option(cmd, sock.SocketOption.non_blocking, true);

    uint res;
    uint pud = pull == Pull.up ? PI_PUD_UP : pull == Pull.down ? PI_PUD_DOWN : PI_PUD_OFF;
    if (!pigpio_cmd(cmd.handle, PI_CMD_MODES, line, PI_INPUT, res) || cast(int)res < 0 ||
        !pigpio_cmd(cmd.handle, PI_CMD_PUD, line, pud, res) || cast(int)res < 0)
    {
        sock.close(cmd);
        return false;
    }
    if (debounce_us)
    {
        uint steady = debounce_us > 300_000 ? 300_000 : debounce_us;
        if (!pigpio_cmd(cmd.handle, PI_CMD_FG, line, steady, res) || cast(int)res < 0)
        {
            sock.close(cmd);
            return false;
        }
    }

    // notifications need their own socket: NOIB opens the stream on it, NB (on the cmd socket) starts
    // reports for our line
    sock.Socket ntfy;
    if (sock.create_socket(sock.AddressFamily.ipv4, sock.SocketType.stream, sock.Protocol.tcp, ntfy).failed)
    {
        sock.close(cmd);
        return false;
    }
    if (sock.connect(ntfy, addr).failed)
    {
        sock.close(ntfy);
        sock.close(cmd);
        return false;
    }

    uint handle;
    if (!pigpio_cmd(ntfy.handle, PI_CMD_NOIB, 0, 0, handle) || cast(int)handle < 0 ||
        !pigpio_cmd(cmd.handle, PI_CMD_NB, handle, 1u << line, res) || cast(int)res < 0)
    {
        sock.close(ntfy);
        sock.close(cmd);
        return false;
    }
    sock.set_socket_option(ntfy, sock.SocketOption.non_blocking, true);

    sampler.backend = Backend.pigpio;
    sampler.fd = ntfy.handle;
    sampler._cmd_fd = cmd.handle;
    sampler._gpio = cast(ubyte)line;
    sampler.decode = &sampler.decode_pigpio;
    return true;
}

// a request/response exchange, deadline-bounded so a wedged daemon can't stall the main loop
bool pigpio_cmd(int fd, uint cmd, uint p1, uint p2, out uint res)
{
    PigpioMsg m = PigpioMsg(cmd, p1, p2, 0);
    auto bytes = (cast(ubyte*)&m)[0 .. PigpioMsg.sizeof];
    if (!pigpio_io(fd, bytes, true) || !pigpio_io(fd, bytes, false))
        return false;
    res = m.p3;
    return true;
}

bool pigpio_io(int fd, ubyte[] buf, bool sending)
{
    auto s = sock.Socket(fd);
    MonoTime deadline = getTime() + msecs(200);
    while (buf.length)
    {
        size_t moved;
        Result r = sending ? sock.send(s, buf, sock.MsgFlags.dont_wait, &moved)
                           : sock.recv(s, buf, sock.MsgFlags.dont_wait, &moved);
        if (!r.failed && moved)
            buf = buf[moved .. $];
        else if (!r.failed || sock.socket_result(r) == sock.SocketResult.would_block)
        {
            if (getTime() >= deadline)
                return false;
        }
        else
            return false;
    }
    return true;
}


bool read_bool_file(const(char)[] path, out bool value)
{
    File f;
    if (!f.open(path, FileOpenMode.ReadExisting))
        return false;
    ubyte[2] buf;
    size_t n;
    auto r = f.read(buf, n);
    f.close();
    if (!r || n == 0)
        return false;
    value = buf[0] == '1';
    return true;
}

// linux/gpio.h uapi v2 (verified against kernel headers 2026-07-15)

extern(C) int ioctl(int fd, size_t request, ...);

struct gpio_v2_line_attribute
{
    uint id;
    uint padding;
    union
    {
        ulong flags;
        ulong values;
        uint debounce_period_us;
    }
}
static assert(gpio_v2_line_attribute.sizeof == 16);

struct gpio_v2_line_config_attribute
{
    gpio_v2_line_attribute attr;
    ulong mask;
}
static assert(gpio_v2_line_config_attribute.sizeof == 24);

struct gpio_v2_line_config
{
    ulong flags;
    uint num_attrs;
    uint[5] padding;
    gpio_v2_line_config_attribute[10] attrs;
}
static assert(gpio_v2_line_config.sizeof == 272);

struct gpio_v2_line_request
{
    uint[64] offsets;
    char[32] consumer;
    gpio_v2_line_config config;
    uint num_lines;
    uint event_buffer_size;
    uint[5] padding;
    int fd;
}
static assert(gpio_v2_line_request.sizeof == 592);

struct gpio_v2_line_event
{
    ulong timestamp_ns;
    uint id;
    uint offset;
    uint seqno;
    uint line_seqno;
    uint[6] padding;
}
static assert(gpio_v2_line_event.sizeof == 48);

enum : ulong
{
    GPIO_V2_LINE_FLAG_INPUT                = 1UL << 2,
    GPIO_V2_LINE_FLAG_EDGE_RISING          = 1UL << 4,
    GPIO_V2_LINE_FLAG_EDGE_FALLING         = 1UL << 5,
    GPIO_V2_LINE_FLAG_BIAS_PULL_UP         = 1UL << 8,
    GPIO_V2_LINE_FLAG_BIAS_PULL_DOWN       = 1UL << 9,
    GPIO_V2_LINE_FLAG_EVENT_CLOCK_REALTIME = 1UL << 11,
}

enum uint GPIO_V2_LINE_ATTR_ID_DEBOUNCE  = 3;
enum uint GPIO_V2_LINE_EVENT_RISING_EDGE = 1;

enum uint GPIO_V2_GET_LINE_IOCTL = 0xC0000000u | (cast(uint)gpio_v2_line_request.sizeof << 16) | (0xB4 << 8) | 0x07;
static assert(GPIO_V2_GET_LINE_IOCTL == 0xC250B407);

bool read_uint_file(const(char)[] path, out uint value)
{
    File f;
    if (!f.open(path, FileOpenMode.ReadExisting))
        return false;
    ubyte[16] buf;
    size_t n;
    auto r = f.read(buf, n);
    f.close();
    if (!r)
        return false;
    uint v = 0;
    foreach (c; buf[0 .. n])
    {
        if (c < '0' || c > '9')
            break;
        v = v * 10 + (c - '0');
    }
    value = v;
    return true;
}
