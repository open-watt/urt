// Linux serial ports. One I/O thread takes every open port's ISR side over epoll, under the core's section.
module urt.driver.posix.uart;

version (linux):

import urt.atomic;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartCounters, UartError, UartLine, UartLines,
    UartPortInfo, UartRxCallback, UartRxTiming, UartTxCallback, uart_frame_bits;
import urt.driver.uart_core : UartPorts;
import urt.internal.stdc.errno : EAGAIN, EINTR, errno;
import urt.internal.sys.posix;
import urt.internal.sys.posix.termios;
import urt.mem.page : Page;
import urt.sync.semaphore : Semaphore;
import urt.thread : Thread, thread_join, thread_spawn;
import urt.time : Duration, msecs;

nothrow @nogc:

enum num_uarts = 16;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd | 1 << Parity.mark | 1 << Parity.space;
enum uint uart_stop_bits = 1 << StopBits.one | 1 << StopBits.two;
enum uint uart_flow_controls = 1 << FlowControl.none | 1 << FlowControl.hardware | 1 << FlowControl.software;
enum bool uart_has_rs485 = false;
enum bool uart_has_pin_select = false;

// TODO: a USB adapter delivers in blocks on its own timer, so the quiet between frames never reaches us and the
// TODO: host reports no gap. A board's own UART may do better: the 8250 and PL011 drivers push on their receive
// TODO: timeout, a few characters after the line goes quiet. Explore timing gaps from reads on such ports (the Pi's
// TODO: ttyAMA/ttyS), and report them per port where the read cadence proves it; no test rig yet.
enum bool uart_reports_rx_gap = false;

// Every name for one device, as its by-id and by-path links, finds the same port; a device node made anew, as a USB
// adapter plugged back in, is a new port.
ubyte uart_hw_find(const(char)[] name)
{
    char[256] z = void;
    char[4096] resolved = void;
    if (name.length >= z.length)
        return ubyte.max;
    z[0 .. name.length] = name;
    z[name.length] = 0;
    if (!realpath(z.ptr, resolved.ptr))
        return ubyte.max;
    size_t n;
    while (resolved[n])
        ++n;
    const(char)[] path = resolved[0 .. n];
    stat_t node = void;
    if (path.length >= Known.path.length || stat(resolved.ptr, &node) != 0)
        return ubyte.max;
    foreach (id, ref k; _known)
    {
        if (!k.path_length || k.dead || k.path[0 .. k.path_length] != path)
            continue;
        if (k.node == node.st_ino)
            return cast(ubyte)id;
        k.dead = true;
    }
    immutable ubyte id = next_id();
    if (id == ubyte.max)
        return ubyte.max;
    Known* k = &_known[id];
    k.path[0 .. path.length] = path;
    k.path[path.length] = 0;
    k.path_length = cast(ubyte)path.length;
    k.node = node.st_ino;
    k.dead = false;
    return id;
}

// An open port's place among the core's; a closed one takes a free place when it opens.
uint uart_hw_slot(ubyte port)
{
    uint free = uint.max;
    foreach (i, ref d; _devices)
    {
        if (d.fd >= 0 && d.port == port)
            return cast(uint)i;
        if (d.fd < 0 && free == uint.max)
            free = cast(uint)i;
    }
    return port < ubyte.max && _known[port].path_length && !_known[port].dead ? free : uint.max;
}

// The serial ttys sysfs lists, with the USB identity of those behind an adapter; a tty with no node to open is passed over.
bool uart_hw_enumerate(ref uint cursor, out UartPortInfo info)
{
    __gshared char[64] name_buf, description, manufacturer, product, serial;
    while (true)
    {
        uint index;
        size_t length;
        walk_dir("/sys/class/tty", (const(char)[] name) nothrow @nogc {
            if (length || !is_serial_tty(name) || index++ != cursor)
                return;
            length = make_path(name_buf[], "/dev/", name);
        });
        if (index <= cursor)
            return false;
        ++cursor;
        immutable ubyte port = length ? uart_hw_find(name_buf[0 .. length]) : ubyte.max;
        if (port == ubyte.max)
            continue;
        const(char)[] name = name_buf[5 .. length];
        info.name = name_buf[0 .. length];
        info.port = port;
        info.description = tty_driver(name, description[]);
        info.removable = name.starts_with("ttyUSB") || name.starts_with("ttyACM") || name.starts_with("rfcomm");
        char[384] dir = void;
        immutable size_t dn = usb_device_dir(name, dir[]);
        if (dn)
        {
            info.usb_vid = read_hex(dir[0 .. dn], "idVendor");
            info.usb_pid = read_hex(dir[0 .. dn], "idProduct");
            info.manufacturer = read_line(dir[0 .. dn], "manufacturer", manufacturer[]);
            info.product = read_line(dir[0 .. dn], "product", product[]);
            info.serial = read_line(dir[0 .. dn], "serial", serial[]);
        }
        return true;
    }
}

bool uart_hw_open(uint port, ref const UartConfig cfg, UartRxCallback rx_cb, UartTxCallback tx_cb)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    Device* d = &_devices[id];
    Known* k = &_known[port];
    if (d.fd >= 0)
        return false;
    immutable int fd = open(k.path.ptr, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0)
        return false;
    stat_t node = void;
    if (fstat(fd, &node) != 0 || node.st_ino != k.node)
    {
        k.dead = true;
        close(fd);
        return false;
    }
    if (!configure(fd, cfg) || !_ports.acquire(id, cfg, cast(ubyte)port))
    {
        close(fd);
        return false;
    }
    set_low_latency(fd);
    tcflush(fd, TCIOFLUSH);
    d.port = cast(ubyte)port;
    d.fd = fd;
    d.flow = cfg.flow_control;
    d.icount_valid = ioctl(fd, TIOCGICOUNT, &d.icount) == 0;
    _ports.start(id, rx_cb, tx_cb, UartRxTiming());
    if (!_service.add(id))
    {
        _ports.release(id);
        close(fd);
        d.fd = -1;
        return false;
    }
    return true;
}

// Output the peer's flow control will never take is discarded, so a close cannot block on it.
void uart_hw_close(uint port)
{
    uart_hw_flush(port);
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    Device* d = &_devices[id];
    _service.remove(id);
    tcflush(d.fd, TCIOFLUSH);
    close(d.fd);
    d.fd = -1;
    atomicStore(d.closing, false);
    _ports.release(id);
}

bool uart_hw_reconfigure(uint port, ref const UartConfig cfg)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    Device* d = &_devices[id];
    if (!configure(d.fd, cfg))
        return false;
    d.flow = cfg.flow_control;
    _ports.reconfigure(id, cfg, UartRxTiming());
    _ports.kick(id);
    return true;
}

bool uart_hw_send(uint port, Page* chain)
    => _ports.send(uart_hw_slot(cast(ubyte)port), chain);

size_t uart_hw_write(uint port, const(void)[] data)
    => _ports.write(uart_hw_slot(cast(ubyte)port), data);

Page* uart_hw_rx_take(uint port)
    => _ports.rx_take(uart_hw_slot(cast(ubyte)port));

UartRxTiming uart_hw_rx_timing(uint port)
    => _ports.timing(uart_hw_slot(cast(ubyte)port));

size_t uart_hw_tx_pending(uint port)
    => _ports.tx_pending(uart_hw_slot(cast(ubyte)port));

UartCounters uart_hw_counters(uint port)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    count_line_errors(id);
    return _ports.counters(id);
}

UartError uart_hw_check_errors(uint port)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    count_line_errors(id);
    return _ports.take_errors(id);
}

void uart_hw_flush(uint port)
{
    _ports.drain(uart_hw_slot(cast(ubyte)port));
}

// A line flow control owns is refused.
bool uart_hw_set_line(uint port, UartLine line, bool asserted)
{
    Device* d = &_devices[uart_hw_slot(cast(ubyte)port)];
    if (line == UartLine.rts ? d.flow == FlowControl.hardware : d.flow == FlowControl.dsr_dtr)
        return false;
    int bit = line == UartLine.rts ? TIOCM_RTS : TIOCM_DTR;
    return ioctl(d.fd, asserted ? TIOCMBIS : TIOCMBIC, &bit) == 0;
}

UartLines uart_hw_lines(uint port)
{
    UartLines lines;
    int bits;
    if (ioctl(_devices[uart_hw_slot(cast(ubyte)port)].fd, TIOCMGET, &bits) != 0)
        return lines;
    lines.valid = lines.outputs_valid = true;
    lines.rts = (bits & TIOCM_RTS) != 0;
    lines.dtr = (bits & TIOCM_DTR) != 0;
    lines.cts = (bits & TIOCM_CTS) != 0;
    lines.dsr = (bits & TIOCM_DSR) != 0;
    lines.dcd = (bits & TIOCM_CAR) != 0;
    lines.ri = (bits & TIOCM_RNG) != 0;
    return lines;
}

void uart0_hw_puts(const(char)[] s)
{
    write(2, s.ptr, s.length);
}


private:

// A device a name found, at the index of its port.
struct Known
{
    char[112] path;
    ulong node;                 // the device node's inode: made anew when the device comes back
    ubyte path_length;
    bool dead;                  // gone; never found again, and its port is free for another device once closed
}

// An open port.
struct Device
{
    serial_icounter icount;
    int fd = -1;
    FlowControl flow;
    ubyte port;
    bool icount_valid;
    bool watching_out;
    shared bool kick;           // TX waits
    shared bool closing;
    shared bool serviced;       // the I/O thread's, from add until it lets go on close
}

struct serial_struct
{
    int type, line;
    uint port;
    int irq, flags, xmit_fifo_size, custom_divisor, baud_base;
    ushort close_delay;
    char io_type;
    char reserved_char;
    int hub6;
    ushort closing_wait, closing_wait2;
    ubyte* iomem_base;
    ushort iomem_reg_shift;
    uint port_high;
    c_ulong iomap_base;
}

struct serial_icounter
{
    int cts, dsr, rng, dcd;
    int rx, tx;
    int frame, overrun, parity, brk;
    int buf_overrun;
    int[9] reserved;
}

__gshared Known[ubyte.max] _known;
__gshared Device[num_uarts] _devices;
__gshared ubyte _last_id = ubyte.max;

// The next port no device holds, taken in turn so a port that was let go is the last to be given again.
ubyte next_id()
{
    foreach (_; 0 .. ubyte.max)
    {
        if (++_last_id == ubyte.max)
            _last_id = 0;
        Known* k = &_known[_last_id];
        if (!k.path_length || (k.dead && !is_open(_last_id)))
            return _last_id;
    }
    return ubyte.max;
}

bool is_open(ubyte port)
{
    foreach (ref d; _devices)
    {
        if (d.fd >= 0 && d.port == port)
            return true;
    }
    return false;
}
__gshared UartPorts!(num_uarts, 0, tx_idle, tx_fill) _ports;
__gshared Service _service;

// Called inside the core's section: the I/O thread writes.
void tx_fill(uint id)
{
    atomicStore(_devices[id].kick, true);
    _service.wake();
}

bool tx_idle(uint id)
{
    int queued;
    return ioctl(_devices[id].fd, TIOCOUTQ, &queued) != 0 || queued == 0;
}

// The kernel's counts of line errors since they were last read, into the core's.
void count_line_errors(uint id)
{
    Device* d = &_devices[id];
    serial_icounter now = void;
    if (!d.icount_valid || ioctl(d.fd, TIOCGICOUNT, &now) != 0)
        return;
    UartError errors;
    if (now.frame != d.icount.frame)
        errors |= UartError.framing;
    if (now.parity != d.icount.parity)
        errors |= UartError.parity;
    if (now.overrun != d.icount.overrun || now.buf_overrun != d.icount.buf_overrun)
        errors |= UartError.overrun;
    if (now.brk != d.icount.brk)
        errors |= UartError.break_;
    d.icount = now;
    if (errors)
    {
        auto guard = _ports.section();
        _ports.error(id, errors);
    }
}

// Adapters that batch reads on a timer (FTDI's is 16 ms) shorten it; where a driver has no such setting, nothing
// changes.
void set_low_latency(int fd)
{
    serial_struct ss;
    if (ioctl(fd, TIOCGSERIAL, &ss) != 0 || (ss.flags & ASYNC_LOW_LATENCY))
        return;
    ss.flags |= ASYNC_LOW_LATENCY;
    ioctl(fd, TIOCSSERIAL, &ss);
}

// RTS idles asserted, "host ready", where flow control leaves it to us: peers that honour RTS stop sending when it
// idles low.
bool configure(int fd, ref const UartConfig cfg)
{
    termios tty;
    if (tcgetattr(fd, &tty) != 0)
        return false;

    static immutable uint[Parity.max + 1] parity_flags = [ 0, PARENB, PARENB | PARODD, PARENB | PARODD | CMSPAR, PARENB | CMSPAR ];
    static immutable uint[4] size_flags = [ CS5, CS6, CS7, CS8 ];
    tty.c_cflag &= ~(PARENB | PARODD | CMSPAR | CSTOPB | CSIZE | CRTSCTS);
    tty.c_cflag |= parity_flags[cfg.parity] | size_flags[cfg.data_bits - 5] | CREAD | CLOCAL;
    if (cfg.stop_bits == StopBits.two)
        tty.c_cflag |= CSTOPB;
    tty.c_iflag &= ~(IXON | IXOFF | IXANY | IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL);
    if (cfg.flow_control == FlowControl.hardware)
        tty.c_cflag |= CRTSCTS;
    else if (cfg.flow_control == FlowControl.software)
        tty.c_iflag |= IXON | IXOFF;
    tty.c_lflag &= ~(ICANON | ECHO | ECHOE | ECHONL | ISIG);
    tty.c_oflag &= ~(OPOST | ONLCR);
    tty.c_cc[VTIME] = 0;
    tty.c_cc[VMIN] = 0;
    if (tcsetattr(fd, TCSANOW, &tty) != 0)
        return false;

    termios2 tty2;
    if (ioctl(fd, TCGETS2, &tty2) < 0)
        return false;
    tty2.c_cflag = (tty2.c_cflag & ~CBAUD) | BOTHER;
    tty2.c_ispeed = tty2.c_ospeed = cfg.baud_rate;
    if (ioctl(fd, TCSETS2, &tty2) != 0)
        return false;

    int dtr = TIOCM_DTR, rts = TIOCM_RTS;
    if (cfg.flow_control != FlowControl.hardware)
        ioctl(fd, TIOCMBIS, &rts);
    ioctl(fd, cfg.flow_control == FlowControl.none ? TIOCMBIC : TIOCMBIS, &dtr);
    return true;
}

struct Service
{
nothrow @nogc:
    enum ulong wake_tag = ulong.max;

    Thread thread;
    Semaphore released;
    int epoll = -1;
    int wake_fd = -1;
    uint open_ports;
    shared bool stop;

    bool add(uint id)
    {
        if (!open_ports && !start())
            return false;
        epoll_event ev = epoll_event(EPOLLIN, id);
        if (epoll_ctl(epoll, EPOLL_CTL_ADD, _devices[id].fd, &ev) != 0)
        {
            if (!open_ports)
                finish();
            return false;
        }
        ++open_ports;
        atomicStore(_devices[id].serviced, true);
        return true;
    }

    // The thread lets go of the port before its descriptor and pages do.
    void remove(uint id)
    {
        atomicStore(_devices[id].closing, true);
        wake();
        released.wait(Duration.max);
        if (--open_ports == 0)
            finish();
    }

    void wake()
    {
        ulong one = 1;
        write(wake_fd, &one, one.sizeof);
    }

    bool start()
    {
        epoll = epoll_create1(EPOLL_CLOEXEC);
        wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        epoll_event ev = epoll_event(EPOLLIN, wake_tag);
        if (epoll < 0 || wake_fd < 0 || epoll_ctl(epoll, EPOLL_CTL_ADD, wake_fd, &ev) != 0 || !released.init(0))
        {
            close_fds();
            return false;
        }
        atomicStore(stop, false);
        thread = thread_spawn(&run);
        if (thread)
            return true;
        close_fds();
        return false;
    }

    void finish()
    {
        atomicStore(stop, true);
        wake();
        thread_join(thread);
        thread = null;
        released.destroy();
        close_fds();
    }

    void close_fds()
    {
        if (epoll >= 0)
            close(epoll);
        if (wake_fd >= 0)
            close(wake_fd);
        epoll = wake_fd = -1;
    }

    void run()
    {
        epoll_event[16] events = void;
        while (!atomicLoad(stop))
        {
            immutable int n = epoll_wait(epoll, events.ptr, events.length, -1);
            foreach (ref ev; events[0 .. n > 0 ? n : 0])
            {
                if (ev.data == wake_tag)
                {
                    ulong count;
                    read(wake_fd, &count, count.sizeof);
                    continue;
                }
                immutable uint id = cast(uint)ev.data;
                if (!atomicLoad(_devices[id].serviced) || atomicLoad(_devices[id].closing))
                    continue;
                if (ev.events & EPOLLIN)
                    receive(id);
                if (ev.events & (EPOLLERR | EPOLLHUP))
                    lose(id);
                else if (ev.events & EPOLLOUT)
                    atomicStore(_devices[id].kick, true);
            }
            foreach (id, ref d; _devices)
            {
                if (!atomicLoad(d.serviced))
                    continue;
                if (atomicLoad(d.closing))
                {
                    epoll_ctl(epoll, EPOLL_CTL_DEL, d.fd, null);
                    d.watching_out = false;
                    atomicStore(d.serviced, false);
                    released.signal();
                    continue;
                }
                if (atomicExchange(&d.kick, false))
                    transmit(cast(uint)id);
            }
        }
    }

    void receive(uint id)
    {
        Device* d = &_devices[id];
        ubyte[256] buf = void;
        bool got;
        while (true)
        {
            immutable ssize_t n = read(d.fd, buf.ptr, buf.length);
            if (n > 0)
            {
                auto guard = _ports.section();
                foreach (b; buf[0 .. n])
                    _ports.receive(id, b);
                got = true;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno != EAGAIN)
                lose(id);
            break;
        }
        if (got)
        {
            auto guard = _ports.section();
            _ports.notify(id);
        }
    }

    void transmit(uint id)
    {
        Device* d = &_devices[id];
        while (true)
        {
            const(ubyte)[] bytes;
            {
                auto guard = _ports.section();
                bytes = _ports.tx_bytes(id);
            }
            if (!bytes.length)
            {
                watch_out(id, false);
                return;
            }
            immutable ssize_t n = write(d.fd, bytes.ptr, bytes.length);
            if (n > 0)
            {
                auto guard = _ports.section();
                _ports.tx_advance(id, n);
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
                watch_out(id, true);
            else
                lose(id);
            return;
        }
    }

    void watch_out(uint id, bool want)
    {
        Device* d = &_devices[id];
        if (d.watching_out == want)
            return;
        epoll_event ev = epoll_event(EPOLLIN | (want ? EPOLLOUT : 0), id);
        if (epoll_ctl(epoll, EPOLL_CTL_MOD, d.fd, &ev) == 0)
            d.watching_out = want;
    }

    // The device went away: the port reports it, and is watched no more.
    void lose(uint id)
    {
        _known[_devices[id].port].dead = true;
        epoll_ctl(epoll, EPOLL_CTL_DEL, _devices[id].fd, null);
        auto guard = _ports.section();
        _ports.error(id, UartError.lost);
        _ports.notify(id);
    }
}

bool starts_with(const(char)[] s, const(char)[] prefix) pure
    => s.length >= prefix.length && s[0 .. prefix.length] == prefix;

bool is_serial_tty(const(char)[] name)
{
    foreach (prefix; [ "ttyUSB", "ttyACM", "ttyAMA", "ttyS", "ttyTHS", "rfcomm" ])
    {
        if (name.starts_with(prefix))
            return true;
    }
    char[320] path = void;
    return make_path(path[], "/sys/class/tty/", name, "/device") != 0 && access(path.ptr, F_OK) == 0;
}

// joined, zero-terminated; 0 when they do not fit
size_t make_path(char[] buf, const(char)[][] parts...)
{
    size_t n;
    foreach (part; parts)
    {
        if (n + part.length >= buf.length)
            return 0;
        buf[n .. n + part.length] = part;
        n += part.length;
    }
    buf[n] = 0;
    return n;
}

const(char)[] tty_driver(const(char)[] name, char[] buf)
{
    char[320] path = void;
    char[256] link = void;
    if (!make_path(path[], "/sys/class/tty/", name, "/device/driver"))
        return null;
    immutable ssize_t n = readlink(path.ptr, link.ptr, link.length);
    if (n <= 0)
        return null;
    size_t slash;
    foreach (i, c; link[0 .. n])
    {
        if (c == '/')
            slash = i + 1;
    }
    const(char)[] base = link[slash .. n];
    if (base.length > buf.length)
        return null;
    buf[0 .. base.length] = base;
    return buf[0 .. base.length];
}

// The tty's device is the usb-serial port; the USB device with its identity is a few levels up.
size_t usb_device_dir(const(char)[] tty_name, char[] out_dir)
{
    char[384] dir = void;
    size_t n = make_path(dir[], "/sys/class/tty/", tty_name, "/device");
    foreach (up; 0 .. 5)
    {
        if (!n)
            return 0;
        char[400] probe = void;
        if (make_path(probe[], dir[0 .. n], "/idVendor") && access(probe.ptr, F_OK) == 0)
        {
            if (n > out_dir.length)
                return 0;
            out_dir[0 .. n] = dir[0 .. n];
            return n;
        }
        n = make_path(dir[n .. $], "/..") ? n + 3 : 0;
    }
    return 0;
}

const(char)[] read_line(const(char)[] dir, const(char)[] file, char[] buf)
{
    char[400] path = void;
    if (!make_path(path[], dir, "/", file))
        return null;
    immutable int fd = open(path.ptr, O_RDONLY);
    if (fd < 0)
        return null;
    scope (exit) close(fd);
    ssize_t n = read(fd, buf.ptr, buf.length);
    if (n <= 0)
        return null;
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
        --n;
    return buf[0 .. n];
}

ushort read_hex(const(char)[] dir, const(char)[] file)
{
    char[16] buf = void;
    ushort value;
    foreach (c; read_line(dir, file, buf[]))
    {
        immutable uint digit = c >= '0' && c <= '9' ? c - '0' : (c | 0x20) >= 'a' && (c | 0x20) <= 'f' ? (c | 0x20) - 'a' + 10 : 16;
        if (digit >= 16)
            break;
        value = cast(ushort)(value << 4 | digit);
    }
    return value;
}

void walk_dir(const(char)[] path, scope void delegate(const(char)[] name) nothrow @nogc visit)
{
    char[320] z = void;
    if (!make_path(z[], path))
        return;
    DIR* dir = opendir(z.ptr);
    if (!dir)
        return;
    scope (exit) closedir(dir);
    for (dirent* entry = readdir(dir); entry; entry = readdir(dir))
    {
        size_t n;
        while (n < entry.d_name.length && entry.d_name[n])
            ++n;
        const(char)[] name = entry.d_name[0 .. n];
        if (n && name != "." && name != "..")
            visit(name);
    }
}

version (X86_64)
{
    align(1) struct epoll_event
    {
    align(1):
        uint events;
        ulong data;
    }
}
else
{
    struct epoll_event
    {
        uint events;
        ulong data;
    }
}

enum EPOLL_CLOEXEC = 0x80000;
enum EPOLL_CTL_ADD = 1, EPOLL_CTL_DEL = 2, EPOLL_CTL_MOD = 3;
enum uint EPOLLIN = 0x1, EPOLLOUT = 0x4, EPOLLERR = 0x8, EPOLLHUP = 0x10;
enum EFD_NONBLOCK = 0x800, EFD_CLOEXEC = 0x80000;
enum F_OK = 0;
enum uint TIOCOUTQ = 0x5411, TIOCMGET = 0x5415, TIOCMBIS = 0x5416, TIOCMBIC = 0x5417, TIOCGICOUNT = 0x545D, TIOCGSERIAL = 0x541E, TIOCSSERIAL = 0x541F;
enum int ASYNC_LOW_LATENCY = 1 << 13;
enum int TIOCM_DTR = 0x002, TIOCM_RTS = 0x004, TIOCM_CTS = 0x020, TIOCM_CAR = 0x040, TIOCM_RNG = 0x080, TIOCM_DSR = 0x100;

version (D_LP64)
    alias c_ulong = ulong;
else
    alias c_ulong = uint;

extern(C) nothrow @nogc
{
    int epoll_create1(int flags);
    int epoll_ctl(int epfd, int op, int fd, epoll_event* event);
    int epoll_wait(int epfd, epoll_event* events, int maxevents, int timeout);
    int eventfd(uint initval, int flags);
    int ioctl(int fd, c_ulong request, ...);
    char* realpath(const(char)* path, char* resolved);
    int access(const(char)* path, int mode);
    int posix_openpt(int flags);
    int grantpt(int fd);
    int unlockpt(int fd);
    int ptsname_r(int fd, char* buf, size_t buflen);
}


unittest
{
    import urt.driver.uart;
    import urt.mem.page : page_chain_span;
    import urt.mem.pagepool : page_alloc, page_free, page_pool_deinit, page_pool_init;
    import urt.system : sleep;

    immutable bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();

    // a pseudo-terminal stands in for the wire: what the master writes, the port receives
    immutable int master = posix_openpt(O_RDWR | O_NOCTTY);
    assert(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0);
    scope (exit) close(master);
    char[128] slave = void;
    assert(ptsname_r(master, slave.ptr, slave.length) == 0);
    size_t n;
    while (slave[n])
        ++n;

    __gshared uint rx_events;
    static bool on_rx(Uart, UartCallbackContext) { atomicFetchAdd(*cast(shared uint*)&rx_events, 1); return false; }
    Uart u;
    UartConfig cfg;
    cfg.baud_rate = 9600;

    immutable ubyte stale = uart_find(slave[0 .. n]);
    assert(stale != ubyte.max && uart_find(slave[0 .. n]) == stale, "a name finds the same port every time");
    _known[stale].node ^= 1;
    assert(!uart_open(u, stale, cfg, &on_rx), "a port found before its device was replaced never opens the replacement");
    immutable ubyte port = uart_find(slave[0 .. n]);
    assert(port != ubyte.max && port != stale, "the replacement is a new port");

    assert(uart_open(u, port, cfg, &on_rx));
    scope (exit) uart_close(u);

    assert(write(master, "hello".ptr, 5) == 5);
    Page* chain;
    foreach (_; 0 .. 200)
    {
        sleep(msecs(5));
        if (atomicLoad(*cast(shared uint*)&rx_events) >= 1)
            break;
    }
    chain = uart_rx_take(u);
    assert(chain && uart_burst_count(chain) == 1, "the bytes arrive");
    UartBurst burst = uart_burst(chain, 0);
    assert(burst.length == 5 && !burst.gap && !burst.end && cast(const(char)[])page_chain_span(chain, 0, 5) == "hello", "a host reports no gap");
    page_free(chain);

    assert(uart_write(u, "world") == 5);
    char[16] back = void;
    ssize_t got;
    foreach (_; 0 .. 200)
    {
        sleep(msecs(5));
        immutable ssize_t r = read(master, back.ptr + got, back.length - got);
        if (r > 0)
            got += r;
        if (got >= 5)
            break;
    }
    assert(got == 5 && back[0 .. 5] == "world", "what is written reaches the wire");
    UartCounters counted = uart_counters(u);
    assert(counted.rx_bytes == 5 && counted.tx_bytes == 5);

    UartConfig faster = cfg;
    faster.baud_rate = 115_200;
    assert(uart_reconfigure(u, faster), "an open port takes new settings in place");

    uint cursor;
    UartPortInfo info;
    while (uart_enumerate(cursor, info))
        assert(info.name.length && info.port != ubyte.max);

    int[num_uarts + 4] many;
    ubyte[num_uarts + 4] found;
    foreach (i, ref m; many)
    {
        m = posix_openpt(O_RDWR | O_NOCTTY);
        assert(m >= 0 && grantpt(m) == 0 && unlockpt(m) == 0 && ptsname_r(m, slave.ptr, slave.length) == 0);
        n = 0;
        while (slave[n])
            ++n;
        found[i] = uart_find(slave[0 .. n]);
        foreach (earlier; found[0 .. i])
            assert(found[i] != ubyte.max && found[i] != earlier, "more devices than can be open at once are each a port of their own");
    }
    foreach (m; many)
        close(m);
}
