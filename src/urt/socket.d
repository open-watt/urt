module urt.socket;

public import urt.endian;
public import urt.inet;
public import urt.mem;
public import urt.result;
public import urt.time;

version (Windows)
{
    // TODO: this is in core.sys.windows.winsock2; why do I need it here?
    pragma(lib, "ws2_32");

    import core.sys.windows.windows;
    import core.sys.windows.winsock2 :
        _bind = bind, _listen = listen, _connect = connect, _accept = accept,
        _send = send, _sendto = sendto, _recv = recv, _recvfrom = recvfrom,
        _shutdown = shutdown;

    version = HasIPv6;

    alias SocketHandle = SOCKET;
}
else version (Posix)
{
    import core.stdc.errno;
    import core.sys.posix.fcntl;
    import core.sys.posix.poll;
    import core.sys.posix.unistd : close, gethostname;
    import urt.internal.os; // use ImportC to import system C headers...
    import core.sys.posix.netinet.in_ : sockaddr_in6;

    alias _bind = urt.internal.os.bind, _listen = urt.internal.os.listen, _connect = urt.internal.os.connect,
        _accept = urt.internal.os.accept, _send = urt.internal.os.send, _sendto = urt.internal.os.sendto,
        _recv = urt.internal.os.recv, _recvfrom = urt.internal.os.recvfrom, _shutdown = urt.internal.os.shutdown;
    alias _poll = core.sys.posix.poll.poll;

    version = HasUnixSocket;
    version = HasIPv6;

    alias SocketHandle = int;
    enum INVALID_SOCKET = -1;

    // for some reason these don't get scraped from the C headers...
    enum AF_UNSPEC = 0;
    enum AF_UNIX = 1;   // Unix domain sockets
    enum AF_INET = 2;   // Internet IP Protocol
    enum AF_IPX = 4;    // Novell IPX
    enum AF_BRIDGE = 7;     // Multiprotocol bridge
    enum AF_INET6 = 10;     // IP version 6
}
else
    static assert(false, "Platform not supported");

nothrow @nogc:


enum SocketResult
{
    success,
    failure,
    would_block,
    no_buffer,
    network_down,
    connection_refused,
    connection_reset,
    connection_aborted,
    connection_closed,
    interrupted,
    invalid_socket,
    invalid_argument,
}

enum SocketType : byte
{
    unknown = -1,
    stream = 0,
    datagram,
    raw,
}

enum Protocol : byte
{
    unknown = -1,
    tcp = 0,
    udp,
    ip,
    icmp,
    raw,
}

enum SocketShutdownMode : ubyte
{
    read,
    write,
    read_write
}

enum SocketOption : ubyte
{
    // not traditionally a 'socket option', but this is way more convenient
    non_blocking,

    // Socket options
    keep_alive,
    linger,
    randomize_port,
    send_buffer_length,
    recv_buffer_length,
    reuse_address,
    no_sig_pPipe,
    error,

    // IP options
    first_ip_option,
    multicast = first_ip_option,
    multicast_loopback,
    multicast_ttl,

    // IPv6 options
    first_ipv6_option,

    // ICMP options
    first_icmp_option = first_ipv6_option,

    // ICMPv6 options
    first_icmpv6_option = first_icmp_option,

    // TCP options
    first_tcp_option = first_icmpv6_option,
    tcp_keep_idle = first_tcp_option,
    tcp_keep_intvl,
    tcp_keep_cnt,
    tcp_keep_alive, // Apple: similar to KeepIdle
    tcp_no_delay,


    // UDP options
    first_udp_option,
}

enum MsgFlags : ubyte
{
    none    = 0,
    oob     = 1 << 0,
    peek    = 1 << 1,
    confirm = 1 << 2,
    no_sig  = 1 << 3,
    //...
}

enum AddressInfoFlags : ubyte
{
    none            = 0,
    passive         = 1 << 0,
    canon_name      = 1 << 1,
    numeric_host    = 1 << 2,
    numeric_serv    = 1 << 3,
    all             = 1 << 4,
    addr_config     = 1 << 5,
    v4_mapped       = 1 << 6,
    fqdn            = 1 << 7,
}

enum PollEvents : ubyte
{
    none    = 0,
    read    = 1 << 0,
    write   = 1 << 1,
    error   = 1 << 2,
    hangup  = 1 << 3,
    invalid = 1 << 4,
}


struct Socket
{
nothrow @nogc:
    enum Socket invalid = Socket();

    bool opCast(T : bool)() const => handle != invalid.handle;

    void opAssign(typeof(null)) { handle = invalid.handle; }

private:
    SocketHandle handle = INVALID_SOCKET;
}


Result create_socket(AddressFamily af, SocketType type, Protocol proto, out Socket socket)
{
    version (HasUnixSocket) {} else
        assert(af != AddressFamily.Unix, "Unix sockets not supported on this platform!");

    socket.handle = .socket(s_addressFamily[af], s_socketType[type], s_protocol[proto]);
    if (socket == Socket.invalid)
        return socket_getlasterror();
    return Result.success;
}

Result close(Socket socket)
{
    version (Windows)
        int result = closesocket(socket.handle);
    else version (Posix)
        int result = close(socket.handle);
    else
        assert(false, "Not implemented!");
    if (result < 0)
        return socket_getlasterror();

//    {
//        LockGuard<SharedMutex> lock(s_noSignalMut);
//        s_noSignal.Erase(socket);
//    }

    return Result.success;
}

Result shutdown(Socket socket, SocketShutdownMode how)
{
    int t = int(how);
    switch (how)
    {
        version (Windows)
        {
            case SocketShutdownMode.read:       t = SD_RECEIVE; break;
            case SocketShutdownMode.write:      t = SD_SEND;    break;
            case SocketShutdownMode.read_write: t = SD_BOTH;    break;
        }
        else version (Posix)
        {
            case SocketShutdownMode.read:       t = SHUT_RD;    break;
            case SocketShutdownMode.write:      t = SHUT_WR;    break;
            case SocketShutdownMode.read_write: t = SHUT_RDWR;  break;
        }
        default:
            assert(false, "Invalid `how`");
    }

    if (_shutdown(socket.handle, t) < 0)
        return socket_getlasterror();
    return Result.success;
}

Result bind(Socket socket, ref const InetAddress address)
{
    ubyte[512] buffer = void;
    size_t addrLen;
    sockaddr* sockAddr = make_sockaddr(address, buffer, addrLen);
    assert(sockAddr, "Invalid socket address");

    if (_bind(socket.handle, sockAddr, cast(int)addrLen) < 0)
        return socket_getlasterror();
    return Result.success;
}

Result listen(Socket socket, uint backlog = -1)
{
    if (_listen(socket.handle, int(backlog & 0x7FFFFFFF)) < 0)
        return socket_getlasterror();
    return Result.success;
}

Result connect(Socket socket, ref const InetAddress address)
{
    ubyte[512] buffer = void;
    size_t addrLen;
    sockaddr* sockAddr = make_sockaddr(address, buffer, addrLen);
    assert(sockAddr, "Invalid socket address");

    if (_connect(socket.handle, sockAddr, cast(int)addrLen) < 0)
        return socket_getlasterror();
    return Result.success;
}

Result accept(Socket socket, out Socket connection, InetAddress* connectingSocketAddress = null)
{
    char[sockaddr_storage.sizeof] buffer = void;
    sockaddr* addr = cast(sockaddr*)buffer.ptr;
    socklen_t size = buffer.sizeof;

    connection.handle = _accept(socket.handle, addr, &size);
    if (connection == Socket.invalid)
        return socket_getlasterror();
    else if (connectingSocketAddress)
        *connectingSocketAddress = make_InetAddress(addr);
    // platforms are inconsistent regarding whether accept inherits the listening socket's blocking mode
    // for consistentency, we always set blocking on the accepted socket
    connection.set_socket_option(SocketOption.non_blocking, false);
    return Result.success;
}

Result send(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.none, size_t* bytesSent = null)
{
    Result r = Result.success;

    ptrdiff_t sent = _send(socket.handle, message.ptr, cast(int)message.length, map_message_flags(flags));
    if (sent < 0)
    {
        r = socket_getlasterror();
        sent = 0;
    }
    if (bytesSent)
        *bytesSent = sent;
    return r;
}

Result sendto(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.none, const InetAddress* address = null, size_t* bytesSent = null)
{
    ubyte[sockaddr_storage.sizeof] tmp = void;
    size_t addrLen;
    sockaddr* sockAddr = null;
    if (address)
    {
        sockAddr = make_sockaddr(*address, tmp, addrLen);
        assert(sockAddr, "Invalid socket address");
    }

    Result r = Result.success;
    ptrdiff_t sent = _sendto(socket.handle, message.ptr, cast(int)message.length, map_message_flags(flags), sockAddr, cast(int)addrLen);
    if (sent < 0)
    {
        r = socket_getlasterror();
        sent = 0;
    }
    if (bytesSent)
        *bytesSent = sent;
    return r;
}

Result recv(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.none, size_t* bytesReceived)
{
    Result r = Result.success;
    ptrdiff_t bytes = _recv(socket.handle, buffer.ptr, cast(int)buffer.length, map_message_flags(flags));
    if (bytes > 0)
        *bytesReceived = bytes;
    else
    {
        *bytesReceived = 0;
        if (bytes == 0)
        {
            // if we request 0 bytes, we receive 0 bytes, and it doesn't imply end-of-stream
            if (buffer.length > 0)
            {
                // a graceful disconnection occurred
                // TODO: !!!
                r = ConnectionClosedResult;
//                r = InternalResult(InternalCode.RemoteDisconnected);
            }
        }
        else
        {
            Result error = socket_getlasterror();
            // TODO: Do we want a better way to distinguish between receiving a 0-length packet vs no-data (which looks like an error)?
            //       Is a zero-length packet possible to detect in TCP streams? Makes more sense for recvfrom...
            SocketResult sr = socket_result(error);
            if (sr != SocketResult.would_block)
                r = error;
        }
    }
    return r;
}

Result recvfrom(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.none, InetAddress* senderAddress = null, size_t* bytesReceived)
{
    char[sockaddr_storage.sizeof] addrBuffer = void;
    sockaddr* addr = cast(sockaddr*)addrBuffer.ptr;
    socklen_t size = addrBuffer.sizeof;

    Result r = Result.success;
    ptrdiff_t bytes = _recvfrom(socket.handle, buffer.ptr, cast(int)buffer.length, map_message_flags(flags), addr, &size);
    if (bytes >= 0)
        *bytesReceived = bytes;
    else
    {
        *bytesReceived = 0;

        Result error = socket_getlasterror();
        SocketResult sockRes = socket_result(error);
        if (sockRes != SocketResult.no_buffer && // buffers full
            sockRes != SocketResult.connection_refused && // posix error
            sockRes != SocketResult.connection_reset) // !!! windows may report this error, but it appears to mean something different on posix
            r = error;
    }
    if (r && senderAddress)
        *senderAddress = make_InetAddress(addr);
    return r;
}

Result set_socket_option(Socket socket, SocketOption option, const(void)* optval, size_t optlen)
{
    Result r = Result.success;

    // check the option appears to be the proper datatype
    const OptInfo* optInfo = &s_socketOptions[option];
    assert(optInfo.rt_type != OptType.unsupported, "Socket option is unsupported on this platform!");
    assert(optlen == s_optTypeRtSize[optInfo.rt_type], "Socket option has incorrect payload size!");

    // special case for non-blocking
    // this is not strictly a 'socket option', but this rather simplifies our API
    if (option == SocketOption.non_blocking)
    {
        bool value = *cast(const(bool)*)optval;
        version (Windows)
        {
            uint opt = value ? 1 : 0;
            r.systemCode = ioctlsocket(socket.handle, FIONBIO, &opt);
        }
        else version (Posix)
        {
            int flags = fcntl(socket.handle, F_GETFL, 0);
            r.systemCode = fcntl(socket.handle, F_SETFL, value ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK));
        }
        else
            assert(false, "Not implemented!");
        return r;
    }

//    // Convenience for socket-level no signal since some platforms only support message flag
//    if (option == SocketOption.NoSigPipe)
//    {
//        LockGuard!SharedMutex lock(s_noSignalMut);
//        s_noSignal.InsertOrAssign(socket.handle, *cast(const(bool)*)optval);
//
//        if (optInfo.platform_type == OptType.unsupported)
//            return r;
//    }

    // determine the option 'level'
    OptLevel level = get_optlevel(option);
    version (HasIPv6) {} else
        assert(level != OptLevel.IPv6 && level != OptLevel.ICMPv6, "Platform does not support IPv6!");

    // platforms don't all agree on option data formats!
    const(void)* arg = optval;
    int itmp = void;
    linger ling = void;
    if (optInfo.rt_type != optInfo.platform_type)
    {
        switch (optInfo.rt_type)
        {
            // TODO: there are more converstions necessary as options/platforms are added
            case OptType.bool_:
            {
                const bool value = *cast(const(bool)*)optval;
                switch (optInfo.platform_type)
                {
                    case OptType.int_:
                        itmp = value ? 1 : 0;
                        arg = &itmp;
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            case OptType.duration:
            {
                const Duration value = *cast(const(Duration)*)optval;
                switch (optInfo.platform_type)
                {
                    case OptType.seconds:
                        itmp = cast(int)value.as!"seconds";
                        arg = &itmp;
                        break;
                    case OptType.milliseconds:
                        itmp = cast(int)value.as!"msecs";
                        arg = &itmp;
                        break;
                    case OptType.linger:
                        itmp = cast(int)value.as!"seconds";
                        ling = linger(!!itmp, cast(ushort)itmp);
                        arg = &ling;
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            default:
                assert(false, "Unexpected!");
        }
    }

    // set the option
    r.systemCode = setsockopt(socket.handle, s_sockOptLevel[level], optInfo.option, cast(const(char)*)arg, s_optTypePlatformSize[optInfo.platform_type]);

    return r;
}

Result set_socket_option(Socket socket, SocketOption option, bool value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.bool_, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, bool.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, int value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.int_, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, int.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, Duration value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.duration, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, Duration.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, IPAddr value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.inet_addr, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, IPAddr.sizeof);
}

Result set_socket_option(Socket socket, SocketOption option, ref MulticastGroup value)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.multicast_group, "Incorrect value type for option");
    return set_socket_option(socket, option, &value, MulticastGroup.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, void* output, size_t outputlen)
{
    Result r = Result.success;

    // check the option appears to be the proper datatype
    const OptInfo* optInfo = &s_socketOptions[option];
    assert(optInfo.rt_type != OptType.unsupported, "Socket option is unsupported on this platform!");
    assert(outputlen == s_optTypeRtSize[optInfo.rt_type], "Socket option has incorrect payload size!");

    assert(option != SocketOption.non_blocking, "Socket option NonBlocking cannot be get");

    // determine the option 'level'
    OptLevel level = get_optlevel(option);
    version (HasIPv6)
        assert(level != OptLevel.ipv6 && level != OptLevel.icmpv6, "Platform does not support IPv6!");

    // platforms don't all agree on option data formats!
    void* arg = output;
    int itmp = 0;
    linger ling = { 0, 0 };
    if (optInfo.rt_type != optInfo.platform_type)
    {
        switch (optInfo.platform_type)
        {
            case OptType.int_:
            case OptType.seconds:
            case OptType.milliseconds:
            {
                arg = &itmp;
                break;
            }
            case OptType.linger:
            {
                arg = &ling;
                break;
            }
            default:
                assert(false, "Unexpected!");
        }
    }

    socklen_t writtenLen = s_optTypePlatformSize[optInfo.platform_type];
    // get the option
    r.systemCode = getsockopt(socket.handle, s_sockOptLevel[level], optInfo.option, cast(char*)arg, &writtenLen);

    if (optInfo.rt_type != optInfo.platform_type)
    {
        switch (optInfo.rt_type)
        {
            // TODO: there are more converstions necessary as options/platforms are added
            case OptType.bool_:
            {
                bool* value = cast(bool*)output;
                switch (optInfo.platform_type)
                {
                    case OptType.int_:
                        *value = !!itmp;
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            case OptType.duration:
            {
                Duration* value = cast(Duration*)output;
                switch (optInfo.platform_type)
                {
                    case OptType.seconds:
                        *value = seconds(itmp);
                        break;
                    case OptType.milliseconds:
                        *value = msecs(itmp);
                        break;
                    case OptType.linger:
                        *value = seconds(ling.l_linger);
                        break;
                    default: assert(false, "Unexpected");
                }
                break;
            }
            default:
                assert(false, "Unexpected!");
        }
    }

    assert(optInfo.rt_type != OptType.inet_addr, "TODO: uncomment this block... for some reason, this block causes DMD to do a bad codegen!");
/+
    // Options expected in network-byte order
    switch (optInfo.rt_type)
    {
        case OptType.INAddress:
        {
            IPAddr* addr = cast(IPAddr*)output;
            addr.address = loadBigEndian(&addr.address());
            break;
        }
        default:
            break;
    }
+/
    return r;
}

Result get_socket_option(Socket socket, SocketOption option, out bool output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.bool_, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, bool.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, out int output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.int_, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, int.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, out Duration output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.duration, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, Duration.sizeof);
}

Result get_socket_option(Socket socket, SocketOption option, out IPAddr output)
{
    const OptInfo* optInfo = &s_socketOptions[option];
    if (optInfo.rt_type == OptType.unsupported)
        return InternalResult.unsupported;
    assert(optInfo.rt_type == OptType.inet_addr, "Incorrect value type for option");
    return get_socket_option(socket, option, &output, IPAddr.sizeof);
}

Result set_keepalive(Socket socket, bool enable, Duration keepIdle, Duration keepInterval, int keepCount)
{
    version (Windows)
    {
        tcp_keepalive alive;
        alive.onoff = enable ? 1 : 0;
        alive.keepalivetime = cast(uint)keepIdle.as!"msecs";
        alive.keepaliveinterval = cast(uint)keepInterval.as!"msecs";

        uint bytesReturned = 0;
        if (WSAIoctl(socket.handle, SIO_KEEPALIVE_VALS, &alive, alive.sizeof, null, 0, &bytesReturned, null, null) < 0)
            return socket_getlasterror();
        return Result.success;
    }
    else
    {
        Result res = set_socket_option(socket, SocketOption.keep_alive, enable);
        if (!enable || res != Result.success)
            return res;
        version (Darwin)
        {
            // OSX doesn't support setting keep-alive interval and probe count.
            return set_socket_option(socket, SocketOption.tcp_keep_alive, keepIdle);
        }
        else
        {
            res = set_socket_option(socket, SocketOption.tcp_keep_idle, keepIdle);
            if (res != Result.success)
                return res;
            res = set_socket_option(socket, SocketOption.tcp_keep_intvl, keepInterval);
            if (res != Result.success)
                return res;
            return set_socket_option(socket, SocketOption.tcp_keep_cnt, keepCount);
        }
    }
}

Result get_peer_name(Socket socket, out InetAddress name)
{
    char[sockaddr_storage.sizeof] buffer;
    sockaddr* addr = cast(sockaddr*)buffer;
    socklen_t bufferLen = buffer.sizeof;

    int fail = getpeername(socket.handle, addr, &bufferLen);
    if (fail == 0)
        name = make_InetAddress(addr);
    else
        return socket_getlasterror();
    return Result.success;
}

Result get_socket_name(Socket socket, out InetAddress name)
{
    char[sockaddr_storage.sizeof] buffer;
    sockaddr* addr = cast(sockaddr*)buffer;
    socklen_t bufferLen = buffer.sizeof;

    int fail = getsockname(socket.handle, addr, &bufferLen);
    if (fail == 0)
        name = make_InetAddress(addr);
    else
        return socket_getlasterror();
    return Result.success;
}

Result get_hostname(char* name, size_t len)
{
    int fail = gethostname(name, cast(int)len);
    if (fail)
        return socket_getlasterror();
    return Result.success;
}

Result get_address_info(const(char)[] nodeName, const(char)[] service, AddressInfo* hints, out AddressInfoResolver result)
{
    import urt.array : findFirst;
    import urt.mem.temp : tstringz;

    size_t colon = nodeName.findFirst(':');
    if (colon < nodeName.length)
    {
        if (!service)
            service = nodeName[colon + 1..$];
        nodeName = nodeName[0 .. colon];
    }

    addrinfo tmpHints;
    if (hints)
    {
        // translate hints...
        tmpHints.ai_flags = map_addrinfo_flags(hints.flags);
        tmpHints.ai_family = s_addressFamily[hints.family];
        tmpHints.ai_socktype = s_socketType[hints.sock_type];
        tmpHints.ai_protocol = s_protocol[hints.protocol];
        tmpHints.ai_canonname = cast(char*)hints.canon_name; // HAX!
        tmpHints.ai_addrlen = 0;
        tmpHints.ai_addr = null;
        tmpHints.ai_next = null;
    }

    addrinfo* res;
    int err = getaddrinfo(nodeName.tstringz, service ? service.tstringz : null, hints ? &tmpHints : null, &res);
    if (err != 0)
        return Result(err);

    // if it was used previously
    if (result.m_internal[0])
        freeaddrinfo(cast(addrinfo*)result.m_internal[0]);

    result.m_internal[0] = res;
    result.m_internal[1] = res;

    return Result.success;
}

Result poll(PollFd[] pollFds, Duration timeout, out uint numEvents)
{
    enum MaxFds = 512;
    assert(pollFds.length <= MaxFds, "Too many fds!");
    version (Windows)
        WSAPOLLFD[MaxFds] fds;
    else version (Posix)
        pollfd[MaxFds] fds;
    for (size_t i = 0; i < pollFds.length; ++i)
    {
        fds[i].fd = pollFds[i].socket.handle;
        fds[i].revents = 0;
        fds[i].events = ((pollFds[i].request_events & PollEvents.read)  ? POLLRDNORM : 0) |
                        ((pollFds[i].request_events & PollEvents.write) ? POLLWRNORM : 0);
    }
    version (Windows)
        int r = WSAPoll(fds.ptr, cast(uint)pollFds.length, timeout.ticks < 0 ? -1 : cast(int)timeout.as!"msecs");
    else version (Posix)
        int r = _poll(fds.ptr, pollFds.length, timeout.ticks < 0 ? -1 : cast(int)timeout.as!"msecs");
    else
        assert(false, "Not implemented!");
    if (r < 0)
    {
        numEvents = 0;
        return socket_getlasterror();
    }
    numEvents = r;
    for (size_t i = 0; i < pollFds.length; ++i)
    {
        pollFds[i].return_events = cast(PollEvents)(
                                    ((fds[i].revents & POLLRDNORM) ? PollEvents.read    : 0) |
                                    ((fds[i].revents & POLLWRNORM) ? PollEvents.write   : 0) |
                                    ((fds[i].revents & POLLERR)    ? PollEvents.error   : 0) |
                                    ((fds[i].revents & POLLHUP)    ? PollEvents.hangup  : 0) |
                                    ((fds[i].revents & POLLNVAL)   ? PollEvents.invalid : 0));
    }
    return Result.success;
}

Result poll(ref PollFd pollFd, Duration timeout, out uint numEvents)
{
    return poll((&pollFd)[0..1], timeout, numEvents);
}

struct AddressInfo
{
    AddressInfoFlags flags;
    AddressFamily family;
    SocketType sock_type;
    Protocol protocol;
    const(char)* canon_name; // Note: this memory is valid until the next call to `next_address`, or until `AddressInfoResolver` is destroyed
    InetAddress address;
}

struct AddressInfoResolver
{
nothrow @nogc:

    // TODO: this should be a MOVE ONLY construction
    // @disable the COPY constructor!
    this(AddressInfoResolver rh)
    {
        m_internal[] = rh.m_internal[];
        rh.m_internal[0] = null;
        rh.m_internal[1] = null;
    }

    ~this()
    {
        if (m_internal[0])
            freeaddrinfo(cast(addrinfo*)m_internal[0]);
    }

    // TODO: this should be a MOVE ONLY assignment!
    // @disable the COPY assignment!
    ref AddressInfoResolver opAssign(AddressInfoResolver rh)
    {
//        if (&rh == &this)
//            return this;
        this.destroy();
        m_internal[0] = rh.m_internal[0];
        m_internal[1] = rh.m_internal[1];
        rh.m_internal[0] = null;
        rh.m_internal[1] = null;
        return this;
    }

    bool next_address(out AddressInfo addressInfo)
    {
        if (!m_internal[1])
            return false;

        addrinfo* info = cast(addrinfo*)(m_internal[1]);
        m_internal[1] = info.ai_next;

        addressInfo.flags = AddressInfoFlags.none; // info.ai_flags is only used for 'hints'
        addressInfo.family = map_address_family(info.ai_family);
        addressInfo.sock_type = cast(int)info.ai_socktype ? map_socket_type(info.ai_socktype) : SocketType.unknown;
        addressInfo.protocol = map_protocol(info.ai_protocol);
        addressInfo.canon_name = info.ai_canonname;
        addressInfo.address = make_InetAddress(info.ai_addr);
        return true;
    }

    void*[2] m_internal = [ null, null ];
}

struct PollFd
{
    Socket socket;
    PollEvents request_events;
    PollEvents return_events;
    void* user_data;
}



Result socket_getlasterror()
{
    version (Windows)
        return Result(WSAGetLastError());
    else
        return Result(errno);
}

Result get_socket_error(Socket socket)
{
    Result r;
    socklen_t optlen = r.systemCode.sizeof;
    int callResult = getsockopt(socket.handle, SOL_SOCKET, SO_ERROR, cast(char*)&r.systemCode, &optlen);
    if (callResult)
        r.systemCode = callResult;
    return r;
}

// TODO: !!!
enum Result ConnectionClosedResult = Result(-12345); 
SocketResult socket_result(Result result)
{
    if (result)
        return SocketResult.success;
    if (result.systemCode == ConnectionClosedResult.systemCode)
        return SocketResult.connection_closed;
    version (Windows)
    {
        if (result.systemCode == WSAEWOULDBLOCK)
            return SocketResult.would_block;
        if (result.systemCode == WSAEINPROGRESS)
            return SocketResult.would_block;
        if (result.systemCode == WSAENOBUFS)
            return SocketResult.no_buffer;
        if (result.systemCode == WSAENETDOWN)
            return SocketResult.network_down;
        if (result.systemCode == WSAECONNREFUSED)
            return SocketResult.connection_refused;
        if (result.systemCode == WSAECONNRESET)
            return SocketResult.connection_reset;
        if (result.systemCode == WSAEINTR)
            return SocketResult.interrupted;
        if (result.systemCode == WSAENOTSOCK)
            return SocketResult.invalid_socket;
        if (result.systemCode == WSAEINVAL)
            return SocketResult.invalid_argument;
    }
    else version (Posix)
    {
        static if (EAGAIN != EWOULDBLOCK)
            if (result.systemCode == EAGAIN)
                return SocketResult.would_block;
        if (result.systemCode == EWOULDBLOCK)
            return SocketResult.would_block;
        if (result.systemCode == EINPROGRESS)
            return SocketResult.would_block;
        if (result.systemCode == ENOMEM)
            return SocketResult.no_buffer;
        if (result.systemCode == ENETDOWN)
            return SocketResult.network_down;
        if (result.systemCode == ECONNREFUSED)
            return SocketResult.connection_refused;
        if (result.systemCode == ECONNRESET)
            return SocketResult.connection_reset;
        if (result.systemCode == EINTR)
            return SocketResult.interrupted;
        if (result.systemCode == EINVAL)
            return SocketResult.invalid_argument;
    }
    return SocketResult.failure;
}


sockaddr* make_sockaddr(ref const InetAddress address, ubyte[] buffer, out size_t addrLen)
{
    sockaddr* sockAddr = cast(sockaddr*)buffer.ptr;

    switch (address.family)
    {
        case AddressFamily.IPv4:
        {
            addrLen = sockaddr_in.sizeof;
            if (buffer.length < sockaddr_in.sizeof)
                return null;

            sockaddr_in* ain = cast(sockaddr_in*)sockAddr;
            memzero(ain, sockaddr_in.sizeof);
            ain.sin_family = s_addressFamily[AddressFamily.IPv4];
            version (Windows)
            {
                ain.sin_addr.S_un.S_un_b.s_b1 = address._a.ipv4.addr.b[0];
                ain.sin_addr.S_un.S_un_b.s_b2 = address._a.ipv4.addr.b[1];
                ain.sin_addr.S_un.S_un_b.s_b3 = address._a.ipv4.addr.b[2];
                ain.sin_addr.S_un.S_un_b.s_b4 = address._a.ipv4.addr.b[3];
            }
            else version (Posix)
                ain.sin_addr.s_addr = address._a.ipv4.addr.address;
            else
                assert(false, "Not implemented!");
            storeBigEndian(&ain.sin_port, ushort(address._a.ipv4.port));
            break;
        }
        case AddressFamily.IPv6:
        {
            version (HasIPv6)
            {
                addrLen = sockaddr_in6.sizeof;
                if (buffer.length < sockaddr_in6.sizeof)
                    return null;

                sockaddr_in6* ain6 = cast(sockaddr_in6*)sockAddr;
                memzero(ain6, sockaddr_in6.sizeof);
                ain6.sin6_family = s_addressFamily[AddressFamily.IPv6];
                storeBigEndian(&ain6.sin6_port, cast(ushort)address._a.ipv6.port);
                storeBigEndian(cast(uint*)&ain6.sin6_flowinfo, address._a.ipv6.flowInfo);
                storeBigEndian(cast(uint*)&ain6.sin6_scope_id, address._a.ipv6.scopeId);
                for (int a = 0; a < 8; ++a)
                {
                    version (Windows)
                        storeBigEndian(&ain6.sin6_addr.in6_u.u6_addr16[a], address._a.ipv6.addr.s[a]);
                    else version (Posix)
                        storeBigEndian(cast(ushort*)ain6.sin6_addr.s6_addr + a, address._a.ipv6.addr.s[a]);
                    else
                        assert(false, "Not implemented!");
                }
            }
            else
                assert(false, "Platform does not support IPv6!");
            break;
        }
        case AddressFamily.Unix:
        {
//            version (HasUnixSocket)
//            {
//                addrLen = sockaddr_un.sizeof;
//                if (buffer.length < sockaddr_un.sizeof)
//                    return null;
//
//                sockaddr_un* aun = cast(sockaddr_un*)sockAddr;
//                memzero(aun, sockaddr_un.sizeof);
//                aun.sun_family = s_addressFamily[AddressFamily.Unix];
//
//                memcpy(aun.sun_path, address.un.path, UNIX_PATH_LEN);
//                break;
//            }
//            else
                assert(false, "Platform does not support unix sockets!");
        }
        default:
        {
            sockAddr = null;
            addrLen = 0;

            assert(false, "Unsupported address family");
            break;
        }
    }

    return sockAddr;
}

InetAddress make_InetAddress(const(sockaddr)* sockAddress)
{
    InetAddress addr;
    addr.family = map_address_family(sockAddress.sa_family);
    switch (addr.family)
    {
        case AddressFamily.IPv4:
        {
            const sockaddr_in* ain = cast(const(sockaddr_in)*)sockAddress;

            addr._a.ipv4.port = loadBigEndian(&ain.sin_port);
            version (Windows)
            {
                addr._a.ipv4.addr.b[0] = ain.sin_addr.S_un.S_un_b.s_b1;
                addr._a.ipv4.addr.b[1] = ain.sin_addr.S_un.S_un_b.s_b2;
                addr._a.ipv4.addr.b[2] = ain.sin_addr.S_un.S_un_b.s_b3;
                addr._a.ipv4.addr.b[3] = ain.sin_addr.S_un.S_un_b.s_b4;
            }
            else version (Posix)
                addr._a.ipv4.addr.address = ain.sin_addr.s_addr;
            else
                assert(false, "Not implemented!");
            break;
        }
        case AddressFamily.IPv6:
        {
            version (HasIPv6)
            {
                const sockaddr_in6* ain6 = cast(const(sockaddr_in6)*)sockAddress;

                addr._a.ipv6.port = loadBigEndian(&ain6.sin6_port);
                addr._a.ipv6.flowInfo = loadBigEndian(cast(const(uint)*)&ain6.sin6_flowinfo);
                addr._a.ipv6.scopeId = loadBigEndian(cast(const(uint)*)&ain6.sin6_scope_id);

                for (int a = 0; a < 8; ++a)
                {
                    version (Windows)
                        addr._a.ipv6.addr.s[a] = loadBigEndian(&ain6.sin6_addr.in6_u.u6_addr16[a]);
                    else version (Posix)
                        addr._a.ipv6.addr.s[a] = loadBigEndian(cast(const(ushort)*)ain6.sin6_addr.s6_addr + a);
                    else
                        assert(false, "Not implemented!");
                }
            }
            else
                assert(false, "Platform does not support IPv6!");
            break;
        }
        case AddressFamily.Unix:
        {
//            version (HasUnixSocket)
//            {
//                const sockaddr_un* aun = cast(const(sockaddr_un)*)sockAddress;
//
//                memcpy(addr.un.path, aun.sun_path, UNIX_PATH_LEN);
//                if (UNIX_PATH_LEN < UnixPathLen)
//                    memzero(addr.un.path + UNIX_PATH_LEN, addr.un.path.sizeof - UNIX_PATH_LEN);
//            }
//            else
                assert(false, "Platform does not support unix sockets!");
            break;
        }
        default:
            assert(false, "Unsupported address family.");
            break;
    }

    return addr;
}


private:

enum OptLevel : ubyte
{
    socket,
    ip,
    ipv6,
    icmp,
    icmpv6,
    tcp,
    udp,
}

enum OptType : ubyte
{
    unsupported,
    bool_,
    int_,
    seconds,
    milliseconds,
    duration,
    inet_addr, // IPAddr + in_addr
    //inet6_addr, // IPv6Addr + in6_addr
    multicast_group, // MulticastGroup + ip_mreq
    //multicast_group_ipv6, // MulticastGroupIPv6? + ipv6_mreq
    linger,
    // etc...
}


__gshared immutable ubyte[] s_optTypeRtSize = [ 0, bool.sizeof, int.sizeof, int.sizeof, int.sizeof, Duration.sizeof, IPAddr.sizeof, MulticastGroup.sizeof, 0 ];
__gshared immutable ubyte[] s_optTypePlatformSize = [ 0, 0, int.sizeof, int.sizeof, int.sizeof, 0, in_addr.sizeof, ip_mreq.sizeof, linger.sizeof ];


struct OptInfo
{
    short option;
    OptType rt_type;
    OptType platform_type;
}

__gshared immutable ushort[AddressFamily.max+1] s_addressFamily = [
    AF_UNSPEC,
    AF_UNIX,
    AF_INET,
    AF_INET6
];
AddressFamily map_address_family(int addressFamily)
{
    if (addressFamily == AF_INET)
        return AddressFamily.IPv4;
    else if (addressFamily == AF_INET6)
        return AddressFamily.IPv6;
    else if (addressFamily == AF_UNIX)
        return AddressFamily.Unix;
    else if (addressFamily == AF_UNSPEC)
        return AddressFamily.Unspecified;
    assert(false, "Unsupported address family");
    return AddressFamily.Unknown;
}

__gshared immutable int[SocketType.max+1] s_socketType = [
    SOCK_STREAM,
    SOCK_DGRAM,
    SOCK_RAW
];
SocketType map_socket_type(int sockType)
{
    if (sockType == SOCK_STREAM)
        return SocketType.stream;
    else if (sockType == SOCK_DGRAM)
        return SocketType.datagram;
    else if (sockType == SOCK_RAW)
        return SocketType.raw;
    assert(false, "Unsupported socket type");
    return SocketType.unknown;
}

__gshared immutable int[Protocol.max+1] s_protocol = [
    IPPROTO_TCP,
    IPPROTO_UDP,
    IPPROTO_IP,
    IPPROTO_ICMP,
    IPPROTO_RAW
];
Protocol map_protocol(int protocol)
{
    if (protocol == IPPROTO_TCP)
        return Protocol.tcp;
    else if (protocol == IPPROTO_UDP)
        return Protocol.udp;
    else if (protocol == IPPROTO_IP)
        return Protocol.ip;
    else if (protocol == IPPROTO_ICMP)
        return Protocol.icmp;
    else if (protocol == IPPROTO_RAW)
        return Protocol.raw;
    assert(false, "Unsupported protocol");
    return Protocol.unknown;
}

version (linux)
{
    __gshared immutable int[OptLevel.max+1] s_sockOptLevel = [
        SOL_SOCKET,
        SOL_IP,
        SOL_IPV6,
        IPPROTO_ICMP,
        SOL_ICMPV6,
        SOL_TCP,
        IPPROTO_UDP,
    ];
}
else
{
    __gshared immutable int[OptLevel.max+1] s_sockOptLevel = [
        SOL_SOCKET,
        IPPROTO_IP,
        IPPROTO_IPV6,
        IPPROTO_ICMP,
        58, // IPPROTO_ICMPV6,
        IPPROTO_TCP,
        IPPROTO_UDP,
    ];
}

version (Windows) // BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.bool_, OptType.bool_ ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.bool_, OptType.int_ ),
        OptInfo( SO_LINGER, OptType.duration, OptType.linger ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
//        OptInfo( SO_RANDOMIZE_PORT, OptType.bool_, OptType.int_ ),  // TODO:  BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
        OptInfo( SO_SNDBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_RCVBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_REUSEADDR, OptType.bool_, OptType.int_ ),
        OptInfo( -1, OptType.bool_, OptType.unsupported ), // NoSignalPipe
        OptInfo( SO_ERROR, OptType.int_, OptType.int_ ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.multicast_group, OptType.multicast_group ),
        OptInfo( IP_MULTICAST_LOOP, OptType.bool_, OptType.int_ ),
        OptInfo( IP_MULTICAST_TTL, OptType.int_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( TCP_NODELAY, OptType.bool_, OptType.int_ ),
    ];
}
else version (linux) // BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.bool_, OptType.bool_ ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.bool_, OptType.int_ ),
        OptInfo( SO_LINGER, OptType.duration, OptType.linger ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( SO_SNDBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_RCVBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_REUSEADDR, OptType.bool_, OptType.int_ ),
        OptInfo( -1, OptType.bool_, OptType.unsupported ), // NoSignalPipe
        OptInfo( SO_ERROR, OptType.int_, OptType.int_ ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.multicast_group, OptType.multicast_group ),
        OptInfo( IP_MULTICAST_LOOP, OptType.bool_, OptType.int_ ),
        OptInfo( IP_MULTICAST_TTL, OptType.int_, OptType.int_ ),
        OptInfo( TCP_KEEPIDLE, OptType.duration, OptType.seconds ),
        OptInfo( TCP_KEEPINTVL, OptType.duration, OptType.seconds ),
        OptInfo( TCP_KEEPCNT, OptType.int_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( TCP_NODELAY, OptType.bool_, OptType.int_ ),
    ];
}
else version (Darwin)
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.bool_, OptType.bool_ ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.bool_, OptType.int_ ),
        OptInfo( SO_LINGER, OptType.Duration, OptType.Linger ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( SO_SNDBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_RCVBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_REUSEADDR, OptType.bool_, OptType.int_ ),
        OptInfo( SO_NOSIGPIPE, OptType.bool_, OptType.int_ ),
        OptInfo( SO_ERROR, OptType.int_, OptType.int_ ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.multicast_group, OptType.multicast_group ),
        OptInfo( IP_MULTICAST_LOOP, OptType.bool_, OptType.int_ ),
        OptInfo( IP_MULTICAST_TTL, OptType.int_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( TCP_KEEPALIVE, OptType.duration, OptType.seconds ),
        OptInfo( TCP_NODELAY, OptType.bool_, OptType.int_ ),
    ];
}
else
    static assert(false, "TODO");

int map_message_flags(MsgFlags flags)
{
    int r = 0;
    if (flags & MsgFlags.oob) r |= MSG_OOB;
    if (flags & MsgFlags.peek) r |= MSG_PEEK;
    version (linux)
    {
        if (flags & MsgFlags.confirm) r |= MSG_CONFIRM;
        if (flags & MsgFlags.no_sig) r |= MSG_NOSIGNAL;
    }
    return r;
}

int map_addrinfo_flags(AddressInfoFlags flags)
{
    int r = 0;
    if (flags & AddressInfoFlags.passive) r |= AI_PASSIVE;
    if (flags & AddressInfoFlags.canon_name) r |= AI_CANONNAME;
    if (flags & AddressInfoFlags.numeric_host) r |= AI_NUMERICHOST;
    if (flags & AddressInfoFlags.numeric_serv) r |= AI_NUMERICSERV;
    if (flags & AddressInfoFlags.all) r |= AI_ALL;
    if (flags & AddressInfoFlags.addr_config) r |= AI_ADDRCONFIG;
    if (flags & AddressInfoFlags.v4_mapped) r |= AI_V4MAPPED;
    version (Windows)
        if (flags & AddressInfoFlags.fqdn) r |= AI_FQDN;
    return r;
}

OptLevel get_optlevel(SocketOption opt)
{
    if (opt < SocketOption.first_ip_option) return OptLevel.socket;
    else if (opt < SocketOption.first_ipv6_option) return OptLevel.ip;
    else if (opt < SocketOption.first_icmp_option) return OptLevel.ipv6;
    else if (opt < SocketOption.first_icmpv6_option) return OptLevel.icmp;
    else if (opt < SocketOption.first_tcp_option) return OptLevel.icmpv6;
    else if (opt < SocketOption.first_udp_option) return OptLevel.tcp;
    else return OptLevel.udp;
}


version (Windows)
{
    pragma(crt_constructor)
    void crt_bootup()
    {
        WSADATA wsaData;
        int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
        // what if this fails???
    }

    pragma(crt_destructor)
    void crt_shutdown()
    {
        WSACleanup();
    }
}





// TODO: REMOVE ME - pushed to druntime...
version (Windows)
{
    // stuff that's missing from the windows headers...

    enum: int {
        AI_NUMERICSERV = 0x0008,
        AI_ALL = 0x0100,
        AI_V4MAPPED = 0x0800,
        AI_FQDN = 0x4000,
    }

    struct pollfd
    {
        SOCKET  fd;         // Socket handle
        SHORT   events;     // Requested events to monitor
        SHORT   revents;    // Returned events indicating status
    }
    alias WSAPOLLFD = pollfd;
    alias PWSAPOLLFD = pollfd*;
    alias LPWSAPOLLFD = pollfd*;

    enum: short {
        POLLRDNORM = 0x0100,
        POLLRDBAND = 0x0200,
        POLLIN = (POLLRDNORM | POLLRDBAND),
        POLLPRI = 0x0400,

        POLLWRNORM = 0x0010,
        POLLOUT = (POLLWRNORM),
        POLLWRBAND = 0x0020,

        POLLERR = 0x0001,
        POLLHUP = 0x0002,
        POLLNVAL = 0x0004
    }

    extern(Windows) int WSAPoll(LPWSAPOLLFD fdArray, uint fds, int timeout);

    struct ip_mreq
    {
        in_addr imr_multiaddr;
        in_addr imr_interface;
    }
}
