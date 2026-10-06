// Windows serial ports. A port is its COM number, which Windows keeps for a device across replugs and never gives
// another. One I/O thread takes every open port's ISR side over an I/O completion port, under the core's section.
module urt.driver.windows.uart;

version (Windows):

import urt.atomic;
import urt.driver.uart : DriveMode, FlowControl, Parity, StopBits, UartConfig, UartCounters, UartError, UartLine, UartLines,
    UartPortInfo, UartRxCallback, UartRxTiming, UartTxCallback, uart_frame_bits;
import urt.driver.uart_core : UartPorts;
import urt.internal.sys.windows;
import urt.mem.page : Page;
import urt.sync.semaphore : Semaphore;
import urt.thread : Thread, thread_join, thread_spawn;
import urt.time : Duration;

pragma(lib, "advapi32");

nothrow @nogc:

enum num_uarts = 16;
enum uint uart_drive_modes = 1 << DriveMode.interrupt;
enum uint uart_data_bits = 0xF << 5;
enum uint uart_parities = 1 << Parity.none | 1 << Parity.even | 1 << Parity.odd | 1 << Parity.mark | 1 << Parity.space;
enum uint uart_stop_bits = 1 << StopBits.one | 1 << StopBits.one_point_five | 1 << StopBits.two;
enum uint uart_flow_controls = 1 << FlowControl.none | 1 << FlowControl.hardware | 1 << FlowControl.software | 1 << FlowControl.dsr_dtr;
enum bool uart_has_rs485 = false;
enum bool uart_has_pin_select = false;

// A USB adapter delivers in blocks on its own timer (silabser: 512 bytes every 44 ms), so the quiet between frames
// never reaches us.
enum bool uart_reports_rx_gap = false;

// COMn, \\.\COMn, in any case: the port is n, while Windows knows the device.
// TODO: only COM names are found. Virtual port drivers (com0com's CNCA0, some modem drivers) register other names
// TODO: in SERIALCOMM; giving those an id needs a table of names like the Linux backend's, with ids clear of the
// TODO: COM numbers, and uart_hw_enumerate would stop skipping them.
ubyte uart_hw_find(const(char)[] name)
{
    if (name.length > 4 && name[0 .. 4] == `\\.\`)
        name = name[4 .. $];
    if (name.length < 4 || (name[0] | 0x20) != 'c' || (name[1] | 0x20) != 'o' || (name[2] | 0x20) != 'm')
        return ubyte.max;
    uint number;
    foreach (c; name[3 .. $])
    {
        if (c < '0' || c > '9' || number > 25)
            return ubyte.max;
        number = number * 10 + (c - '0');
    }
    if (number == 0 || number >= ubyte.max)
        return ubyte.max;
    wchar[8] device = void;
    wchar[256] target = void;
    return QueryDosDeviceW(com_name(device, number), target.ptr, target.length) ? cast(ubyte)number : ubyte.max;
}

// An open port's place among the core's; a closed one takes a free place when it opens.
uint uart_hw_slot(ubyte port)
{
    uint free = uint.max;
    foreach (i, ref d; _devices)
    {
        if (d.port == port)
            return cast(uint)i;
        if (!d.port && free == uint.max)
            free = cast(uint)i;
    }
    return port && port < ubyte.max ? free : uint.max;
}

// The ports the registry's serial map lists, by the driver that made each.
// TODO: no USB identity yet: vid, pid, manufacturer, product and serial stay empty, and removable is unknown, so the
// TODO: frontend cannot tell two identical adapters apart or follow one across COM numbers. SetupAPI has it:
// TODO: SetupDiGetClassDevsW(GUID_DEVINTERFACE_COMPORT), match each device's PortName (its "Device Parameters" key)
// TODO: to the COM number, then SPDRP_HARDWAREID (USB\VID_xxxx&PID_xxxx), SPDRP_MFG, SPDRP_FRIENDLYNAME, and the
// TODO: parent's instance id for the serial (CM_Get_Parent, CM_Get_Device_IDW). Needs setupapi and cfgmgr32.
bool uart_hw_enumerate(ref uint cursor, out UartPortInfo info)
{
    __gshared char[16] name_buf;
    __gshared char[64] description;
    HKEY key;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, `HARDWARE\DEVICEMAP\SERIALCOMM`w.ptr, 0, KEY_READ, &key) != 0)
        return false;
    scope (exit) RegCloseKey(key);
    while (true)
    {
        wchar[128] value = void;
        wchar[16] data = void;
        DWORD value_length = value.length, data_length = data.sizeof, type;
        if (RegEnumValueW(key, cursor++, value.ptr, &value_length, null, &type, cast(ubyte*)data.ptr, &data_length) != 0)
            return false;
        const(wchar)[] port_name = data[0 .. data_length / wchar.sizeof];
        while (port_name.length && !port_name[$ - 1])
            port_name = port_name[0 .. $ - 1];
        if (type != REG_SZ || !narrow(port_name, name_buf[]))
            continue;
        info.name = name_buf[0 .. port_name.length];
        info.port = uart_hw_find(info.name);
        if (info.port == ubyte.max)
            continue;
        size_t slash;
        foreach (i, c; value[0 .. value_length])
        {
            if (c == '\\')
                slash = i + 1;
        }
        if (narrow(value[slash .. value_length], description[]))
            info.description = description[0 .. value_length - slash];
        return true;
    }
}

bool uart_hw_open(uint port, ref const UartConfig cfg, UartRxCallback rx_cb, UartTxCallback tx_cb)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    Device* d = &_devices[id];
    wchar[16] path = void;
    path[0 .. 4] = `\\.\`w;
    com_name(path[4 .. $], port);
    HANDLE handle = CreateFileW(path.ptr, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
    if (handle == INVALID_HANDLE_VALUE)
        return false;
    if (!configure(handle, cfg) || !_ports.acquire(id, cfg, cast(ubyte)port))
    {
        CloseHandle(handle);
        return false;
    }
    PurgeComm(handle, PURGE_TXCLEAR | PURGE_RXCLEAR);
    *d = Device.init;
    d.port = cast(ubyte)port;
    d.handle = handle;
    d.flow = cfg.flow_control;
    // TODO: FTDI adapters hold reads for their latency timer, 16 ms by default, where Linux sets it to 1 ms on open.
    // TODO: Windows keeps it in the driver's registry (FTDIBUS\...\Device Parameters\LatencyTimer), which needs admin
    // TODO: and a replug; at least report it, and say how to set it, when a port is FTDI's.
    _ports.start(id, rx_cb, tx_cb, UartRxTiming());
    if (!_service.add(id))
    {
        _ports.release(id);
        CloseHandle(handle);
        *d = Device.init;
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
    PurgeComm(d.handle, PURGE_TXABORT | PURGE_RXABORT | PURGE_TXCLEAR | PURGE_RXCLEAR);
    _service.remove(id);
    CloseHandle(d.handle);
    *d = Device.init;
    _ports.release(id);
}

bool uart_hw_reconfigure(uint port, ref const UartConfig cfg)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    Device* d = &_devices[id];
    if (!configure(d.handle, cfg))
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
    poll_comm(id);
    return _ports.counters(id);
}

UartError uart_hw_check_errors(uint port)
{
    immutable uint id = uart_hw_slot(cast(ubyte)port);
    poll_comm(id);
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
    immutable DWORD function_ = line == UartLine.rts ? (asserted ? SETRTS : CLRRTS) : (asserted ? SETDTR : CLRDTR);
    return EscapeCommFunction(d.handle, function_) != 0;
}

// Windows reads back only what the peer presents.
UartLines uart_hw_lines(uint port)
{
    UartLines lines;
    DWORD status;
    if (!GetCommModemStatus(_devices[uart_hw_slot(cast(ubyte)port)].handle, &status))
        return lines;
    lines.valid = true;
    lines.cts = (status & MS_CTS_ON) != 0;
    lines.dsr = (status & MS_DSR_ON) != 0;
    lines.ri = (status & MS_RING_ON) != 0;
    lines.dcd = (status & MS_RLSD_ON) != 0;
    return lines;
}

void uart0_hw_puts(const(char)[] s)
{
    DWORD written;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), s.ptr, cast(DWORD)s.length, &written, null);
}


private:

struct Device
{
    OVERLAPPED read_io;
    OVERLAPPED write_io;
    ubyte[256] rx;
    HANDLE handle = INVALID_HANDLE_VALUE;
    FlowControl flow;
    ubyte port;                 // 0 while the place is free
    bool dead;
    bool reading;
    bool writing;
    bool cancelled;
    shared bool kick;           // TX waits
    shared bool closing;
    shared bool serviced;       // the I/O thread's, from add until it lets go on close
}

__gshared Device[num_uarts] _devices;
__gshared UartPorts!(num_uarts, 0, tx_idle, tx_fill) _ports;
__gshared Service _service;

wchar* com_name(wchar[] buf, uint number)
{
    buf[0 .. 3] = "COM"w;
    size_t n = 3;
    if (number >= 100)
        buf[n++] = cast(wchar)('0' + number / 100);
    if (number >= 10)
        buf[n++] = cast(wchar)('0' + number / 10 % 10);
    buf[n++] = cast(wchar)('0' + number % 10);
    buf[n] = 0;
    return buf.ptr;
}

bool narrow(const(wchar)[] s, char[] buf)
{
    if (s.length > buf.length)
        return false;
    foreach (i, c; s)
    {
        if (c > 0x7F)
            return false;
        buf[i] = cast(char)c;
    }
    return true;
}

// Called inside the core's section: the I/O thread writes.
void tx_fill(uint id)
{
    atomicStore(_devices[id].kick, true);
    _service.wake();
}

bool tx_idle(uint id)
    => !_devices[id].writing && poll_comm(id) == 0;

// What the driver holds to send, and its line errors since last asked, into the core's.
uint poll_comm(uint id)
{
    DWORD errors;
    COMSTAT stat;
    if (!ClearCommError(_devices[id].handle, &errors, &stat))
        return 0;
    UartError seen;
    if (errors & CE_FRAME)
        seen |= UartError.framing;
    if (errors & CE_RXPARITY)
        seen |= UartError.parity;
    if (errors & (CE_OVERRUN | CE_RXOVER))
        seen |= UartError.overrun;
    if (errors & CE_BREAK)
        seen |= UartError.break_;
    if (seen)
    {
        auto guard = _ports.section();
        _ports.error(id, seen);
    }
    return stat.cbOutQue;
}

// RTS idles asserted, "host ready", where flow control leaves it to us: peers that honour RTS stop sending when it
// idles low. A read completes on the first bytes to arrive, or after a second with none.
bool configure(HANDLE handle, ref const UartConfig cfg)
{
    DCB dcb;
    if (!GetCommState(handle, &dcb))
        return false;
    static immutable BYTE[StopBits.max + 1] stop_bits = [ ONESTOPBIT, ONESTOPBIT, ONE5STOPBITS, TWOSTOPBITS ];
    static immutable BYTE[Parity.max + 1] parities = [ NOPARITY, EVENPARITY, ODDPARITY, MARKPARITY, SPACEPARITY ];
    // DCB's flag word: fBinary, fParity, fOutxCtsFlow, fOutxDsrFlow, fDtrControl:2, fDsrSensitivity, ..., fOutX, fInX,
    // ..., fRtsControl:2
    enum uint binary = 1 << 0, parity = 1 << 1, cts_flow = 1 << 2, dsr_flow = 1 << 3, dsr_sensitive = 1 << 6;
    enum uint out_x = 1 << 8, in_x = 1 << 9;
    enum uint dtr_enable = 1 << 4, dtr_handshake = 2 << 4, rts_enable = 1 << 12, rts_handshake = 2 << 12;
    static immutable uint[FlowControl.max + 1] flow_flags = [
        rts_enable,
        cts_flow | rts_handshake | dtr_enable,
        out_x | in_x | rts_enable | dtr_enable,
        dsr_flow | dsr_sensitive | dtr_handshake,
    ];
    dcb.BaudRate = cfg.baud_rate;
    dcb.ByteSize = cfg.data_bits;
    dcb.StopBits = stop_bits[cfg.stop_bits];
    dcb.Parity = parities[cfg.parity];
    dcb._bf = binary | (cfg.parity != Parity.none ? parity : 0) | flow_flags[cfg.flow_control];
    if (cfg.flow_control == FlowControl.software)
    {
        dcb.XonChar = 0x11;
        dcb.XoffChar = 0x13;
        dcb.XonLim = dcb.XoffLim = 200;
    }
    if (!SetCommState(handle, &dcb))
        return false;
    COMMTIMEOUTS timeouts;
    timeouts.ReadIntervalTimeout = DWORD.max;
    timeouts.ReadTotalTimeoutMultiplier = DWORD.max;
    timeouts.ReadTotalTimeoutConstant = 1000;
    return SetCommTimeouts(handle, &timeouts) != 0;
}

struct Service
{
nothrow @nogc:
    enum ULONG_PTR wake_key = ULONG_PTR.max;

    Thread thread;
    Semaphore released;
    HANDLE completions;
    uint open_ports;
    shared bool stop;

    bool add(uint id)
    {
        if (!open_ports && !start())
            return false;
        if (!CreateIoCompletionPort(_devices[id].handle, completions, id, 0))
        {
            if (!open_ports)
                finish();
            return false;
        }
        ++open_ports;
        atomicStore(_devices[id].serviced, true);
        wake();
        return true;
    }

    // The thread cancels the port's reads and writes, and lets go once both are done, before its handle and pages do.
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
        PostQueuedCompletionStatus(completions, 0, wake_key, null);
    }

    bool start()
    {
        completions = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1);
        if (!completions || !released.init(0))
        {
            if (completions)
                CloseHandle(completions);
            completions = null;
            return false;
        }
        atomicStore(stop, false);
        thread = thread_spawn(&run);
        if (thread)
            return true;
        released.destroy();
        CloseHandle(completions);
        completions = null;
        return false;
    }

    void finish()
    {
        atomicStore(stop, true);
        wake();
        thread_join(thread);
        thread = null;
        released.destroy();
        CloseHandle(completions);
        completions = null;
    }

    void run()
    {
        while (!atomicLoad(stop))
        {
            DWORD bytes;
            ULONG_PTR key;
            OVERLAPPED* io;
            immutable BOOL done = GetQueuedCompletionStatus(completions, &bytes, &key, &io, INFINITE);
            if (io)
            {
                Device* d = &_devices[key];
                immutable bool failed = !done && GetLastError() != ERROR_OPERATION_ABORTED;
                if (io is &d.read_io)
                {
                    d.reading = false;
                    if (done && bytes)
                        receive(cast(uint)key, bytes);
                }
                else
                {
                    d.writing = false;
                    if (done && bytes)
                    {
                        auto guard = _ports.section();
                        _ports.tx_advance(cast(uint)key, bytes);
                    }
                    if (done)
                        atomicStore(d.kick, true);
                }
                if (failed && !atomicLoad(d.closing))
                    lose(cast(uint)key);
            }
            service_ports();
        }
    }

    void service_ports()
    {
        foreach (id, ref d; _devices)
        {
            if (!atomicLoad(d.serviced))
                continue;
            if (atomicLoad(d.closing))
            {
                if (d.reading || d.writing)
                {
                    if (!d.cancelled)
                        CancelIoEx(d.handle, null);
                    d.cancelled = true;
                    continue;
                }
                atomicStore(d.serviced, false);
                released.signal();
                continue;
            }
            if (d.dead)
                continue;
            if (!d.reading)
                read(cast(uint)id);
            if (!d.writing && atomicExchange(&d.kick, false))
                write(cast(uint)id);
        }
    }

    void read(uint id)
    {
        Device* d = &_devices[id];
        d.read_io = OVERLAPPED.init;
        if (ReadFile(d.handle, d.rx.ptr, d.rx.length, null, &d.read_io) || GetLastError() == ERROR_IO_PENDING)
            d.reading = true;
        else
            lose(id);
    }

    void write(uint id)
    {
        Device* d = &_devices[id];
        const(ubyte)[] bytes;
        {
            auto guard = _ports.section();
            bytes = _ports.tx_bytes(id);
        }
        if (!bytes.length)
            return;
        d.write_io = OVERLAPPED.init;
        if (WriteFile(d.handle, bytes.ptr, cast(DWORD)bytes.length, null, &d.write_io) || GetLastError() == ERROR_IO_PENDING)
            d.writing = true;
        else
            lose(id);
    }

    void receive(uint id, uint bytes)
    {
        Device* d = &_devices[id];
        auto guard = _ports.section();
        foreach (b; d.rx[0 .. bytes])
            _ports.receive(id, b);
        _ports.notify(id);
    }

    // The device went away: the port reports it, and its reads and writes stop.
    void lose(uint id)
    {
        _devices[id].dead = true;
        auto guard = _ports.section();
        _ports.error(id, UartError.lost);
        _ports.notify(id);
    }
}

enum REG_SZ = 1;
alias REGSAM = DWORD;
enum HKEY HKEY_LOCAL_MACHINE = cast(HKEY)cast(ptrdiff_t)cast(int)0x80000002;

extern(Windows) nothrow @nogc
{
    LONG RegOpenKeyExW(HKEY key, LPCWSTR sub_key, DWORD options, REGSAM desired, HKEY* result);
    LONG RegEnumValueW(HKEY key, DWORD index, LPWSTR value_name, DWORD* value_name_length, DWORD* reserved, DWORD* type,
                       ubyte* data, DWORD* data_length);
    LONG RegCloseKey(HKEY key);
}
