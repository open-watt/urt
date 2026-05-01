module urt.socket;

public import urt.endian;
public import urt.inet;
public import urt.mem;
public import urt.result;
public import urt.time;

version (UseInternalIPStack)
    version = SocketCallbacks;
else version (BareMetal)
    version = SocketCallbacks;
else version (Windows)
    version = WinSock;

version (SocketCallbacks)
{
    alias SocketHandle = int;
    enum INVALID_SOCKET = -1;

    struct SocketBackend
    {
    nothrow @nogc:
        SocketResult function(AddressFamily, SocketType, Protocol, out Socket) create;
        SocketResult function(Socket) close;
        SocketResult function(Socket, ref const InetAddress) bind;
        SocketResult function(Socket, uint) listen;
        SocketResult function(Socket, ref const InetAddress) connect;
        SocketResult function(Socket, out Socket, InetAddress*) accept;
        SocketResult function(Socket, SocketShutdownMode) shutdown;
        SocketResult function(Socket, const(InetAddress)*, MsgFlags, const(void[])[], size_t*) sendmsg;
        SocketResult function(Socket, void[], MsgFlags, size_t*) recv;
        SocketResult function(Socket, void[], MsgFlags, InetAddress*, size_t*) recvfrom;
        SocketResult function(Socket, out size_t) pending;
        SocketResult function(PollFd[], Duration, out uint) poll;
        SocketResult function(Socket, SocketOption, const(void)*, size_t) set_option;
        SocketResult function(Socket, SocketOption, void*, size_t) get_option;
        SocketResult function(Socket, out InetAddress) get_peer_name;
        SocketResult function(Socket, out InetAddress) get_socket_name;
        SocketResult function(char*, size_t) get_hostname;
        SocketResult function(const(char)[], const(char)[], AddressInfo*, AddressInfoResolver*) get_address_info;
        bool function(AddressInfoResolver*, out AddressInfo) next_address;
        void function(AddressInfoResolver*) free_address_info;
    }

    __gshared SocketBackend* _socket_backend;

    void register_socket_backend(SocketBackend* backend) nothrow @nogc
    {
        _socket_backend = backend;
    }
}
else version (WinSock)
{
    // TODO: this is in core.sys.windows.winsock2; why do I need it here?
    pragma(lib, "ws2_32");

    import urt.internal.sys.windows;
    import urt.internal.sys.windows.winsock2 :
        _bind = bind, _listen = listen, _connect = connect, _accept = accept,
        _send = send, _sendto = sendto, _recv = recv, _recvfrom = recvfrom,
        _shutdown = shutdown;

    version = HasIPv6;

    alias SocketHandle = SOCKET;

    enum IPV6_RECVPKTINFO = 49;
    enum IPV6_PKTINFO = 50;
}
else version (Posix)
{
    import urt.internal.os; // use ImportC to import system C headers...

    alias _bind = urt.internal.os.bind, _listen = urt.internal.os.listen, _connect = urt.internal.os.connect,
        _accept = urt.internal.os.accept, _send = urt.internal.os.send, _sendto = urt.internal.os.sendto, _sendmsg = urt.internal.os.sendmsg,
        _recv = urt.internal.os.recv, _recvfrom = urt.internal.os.recvfrom, _shutdown = urt.internal.os.shutdown,
        _close = urt.internal.os.close, _poll = urt.internal.os.poll;

    version = BSDSockets;
    version = HasUnixSocket;
    version = HasIPv6;
    version = Errno;

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
else version (lwIP)
{
    // lwIP BSD socket API -- constants and structs match lwIP defaults
    version = BSDSockets;
    version = HasIPv6;
    version = Errno;

    alias SocketHandle = int;
    enum INVALID_SOCKET = -1;

    enum AF_UNSPEC = 0;
    enum AF_UNIX   = 1;
    enum AF_INET   = 2;
    enum AF_INET6  = 10;

    enum SOCK_STREAM = 1;
    enum SOCK_DGRAM  = 2;
    enum SOCK_RAW    = 3;

    enum IPPROTO_IP   = 0;
    enum IPPROTO_ICMP = 1;
    enum IPPROTO_TCP  = 6;
    enum IPPROTO_UDP  = 17;
    enum IPPROTO_IPV6 = 41;
    enum IPPROTO_RAW  = 255;

    enum SOL_SOCKET = 0xFFF;

    enum MSG_PEEK = 0x01;

    enum SHUT_RD   = 0;
    enum SHUT_WR   = 1;
    enum SHUT_RDWR = 2;

    // fcntl constants for non-blocking mode
    enum F_GETFL   = 3;
    enum F_SETFL   = 4;
    enum O_NONBLOCK = 1;

    // socket options
    enum SO_REUSEADDR  = 0x0004;
    enum SO_KEEPALIVE  = 0x0008;
    enum SO_LINGER     = 0x0080;
    enum SO_SNDBUF     = 0x1001;
    enum SO_RCVBUF     = 0x1002;
    enum SO_ERROR      = 0x1007;
    enum TCP_NODELAY   = 0x01;
    enum TCP_KEEPIDLE  = 0x03;
    enum TCP_KEEPINTVL = 0x04;
    enum TCP_KEEPCNT   = 0x05;
    enum IP_ADD_MEMBERSHIP = 3;
    enum IP_MULTICAST_TTL  = 5;
    enum IP_MULTICAST_LOOP = 7;

    alias socklen_t = uint;
    struct in_addr { uint s_addr; }
    struct in6_addr { ubyte[16] s6_addr; }
    struct sockaddr { ubyte sa_len; ubyte sa_family; ubyte[14] sa_data; }
    struct sockaddr_in { ubyte sin_len; ubyte sin_family; ushort sin_port; in_addr sin_addr; ubyte[8] sin_zero; }
    struct sockaddr_in6 { ubyte sin6_len; ubyte sin6_family; ushort sin6_port; uint sin6_flowinfo; in6_addr sin6_addr; uint sin6_scope_id; }
    struct sockaddr_storage { ubyte s2_len; ubyte ss_family; ubyte[2] s2_data1; uint[3] s2_data2; uint[3] s2_data3; }
    struct linger { int l_onoff; int l_linger; }
    struct ip_mreq { in_addr imr_multiaddr; in_addr imr_interface; }
    struct iovec { void* iov_base; size_t iov_len; }
    struct msghdr { void* msg_name; socklen_t msg_namelen; iovec* msg_iov; int msg_iovlen; void* msg_control; socklen_t msg_controllen; int msg_flags; }

    enum POLLRDNORM = 0x10;
    enum POLLWRNORM = 0x80;
    enum POLLERR    = 0x04;
    enum POLLHUP    = 0x200;
    enum POLLNVAL   = 0x08;

    enum AI_PASSIVE     = 0x01;
    enum AI_CANONNAME   = 0x02;
    enum AI_NUMERICHOST = 0x04;
    enum AI_NUMERICSERV = 0x08;
    enum AI_V4MAPPED    = 0x10;
    enum AI_ALL         = 0x20;
    enum AI_ADDRCONFIG  = 0x40;

    struct pollfd { int fd; short events; short revents; }
    struct addrinfo { int ai_flags; int ai_family; int ai_socktype; int ai_protocol; socklen_t ai_addrlen; sockaddr* ai_addr; char* ai_canonname; addrinfo* ai_next; }

    // lwIP socket functions -- actual symbol names are lwip_* prefixed
    extern(C) nothrow @nogc
    {
        int lwip_poll(pollfd*, uint, int);
        SocketHandle lwip_socket(int, int, int);
        int lwip_bind(SocketHandle, const(sockaddr)*, socklen_t);
        int lwip_listen(SocketHandle, int);
        int lwip_connect(SocketHandle, const(sockaddr)*, socklen_t);
        SocketHandle lwip_accept(SocketHandle, sockaddr*, socklen_t*);
        ptrdiff_t lwip_send(SocketHandle, const(void)*, size_t, int);
        ptrdiff_t lwip_sendto(SocketHandle, const(void)*, size_t, int, const(sockaddr)*, socklen_t);
        ptrdiff_t lwip_sendmsg(SocketHandle, const(msghdr)*, int);
        ptrdiff_t lwip_recv(SocketHandle, void*, size_t, int);
        ptrdiff_t lwip_recvfrom(SocketHandle, void*, size_t, int, sockaddr*, socklen_t*);
        int lwip_shutdown(SocketHandle, int);
        int lwip_setsockopt(SocketHandle, int, int, const(void)*, socklen_t);
        int lwip_getsockopt(SocketHandle, int, int, void*, socklen_t*);
        int lwip_getsockname(SocketHandle, sockaddr*, socklen_t*);
        int lwip_getpeername(SocketHandle, sockaddr*, socklen_t*);
        int ow_lwip_getaddrinfo(const(char)*, const(char)*, const(addrinfo)*, addrinfo**);
        void ow_lwip_freeaddrinfo(addrinfo*);
        int lwip_close(int);
        int lwip_fcntl(int, int, int);
        int lwip_ioctl(int, int, void*);
    }

    enum FIONBIO = 0x8004667e; // _IOW('f', 126, unsigned long)
    enum FIONREAD = 0x4004667f; // _IOR('f', 127, unsigned long)

    // Aliases so the rest of the codebase uses POSIX names
    alias _poll = lwip_poll;
    alias socket = lwip_socket;
    alias _bind = lwip_bind;
    alias _listen = lwip_listen;
    alias _connect = lwip_connect;
    alias _accept = lwip_accept;
    alias _send = lwip_send;
    alias _sendto = lwip_sendto;
    alias _sendmsg = lwip_sendmsg;
    alias _recv = lwip_recv;
    alias _recvfrom = lwip_recvfrom;
    alias _shutdown = lwip_shutdown;
    alias setsockopt = lwip_setsockopt;
    alias getsockopt = lwip_getsockopt;
    alias getsockname = lwip_getsockname;
    alias getpeername = lwip_getpeername;
    alias getaddrinfo = ow_lwip_getaddrinfo;
    alias freeaddrinfo = ow_lwip_freeaddrinfo;
    alias _close = lwip_close;
    alias fcntl = lwip_fcntl;
    alias ioctlsocket = lwip_ioctl;

    int gethostname(char*, size_t) nothrow @nogc { return -1; }
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
    network_unreachable,
    host_unreachable,
    connection_refused,
    connection_reset,
    connection_aborted,
    connection_closed,
    address_in_use,
    address_not_available,
    timed_out,
    not_connected,
    already_connected,
    permission_denied,
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
    ip_pktinfo,

    // IPv6 options
    first_ipv6_option,
    ipv6_pktinfo = first_ipv6_option,

    // ICMP options
    first_icmp_option,

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
    peek    = 1 << 0,
    confirm = 1 << 1,
    no_sig  = 1 << 2,
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

    SocketHandle handle = INVALID_SOCKET;
}


Result create_socket(AddressFamily af, SocketType type, Protocol proto, out Socket socket)
{
    version (SocketCallbacks)
        return Result(_socket_backend.create(af, type, proto, socket));
    else
    {
        version (HasUnixSocket) {} else
            assert(af != AddressFamily.unix, "Unix sockets not supported on this platform!");

        socket.handle = .socket(s_addressFamily[af], s_socketType[type], s_protocol[proto]);
        if (socket == Socket.invalid)
            return socket_getlasterror();

        return Result.success;
    }
}

Result close(Socket socket)
{
    version (SocketCallbacks)
        return Result(_socket_backend.close(socket));
    else
    {
        int result;
        version (WinSock)
            result = closesocket(socket.handle);
        else version (BSDSockets)
            result = _close(socket.handle);
        else
            assert(false, "Not implemented!");
        if (result < 0)
            return socket_getlasterror();
        return Result.success;
    }
}

Result shutdown(Socket socket, SocketShutdownMode how)
{
    version (SocketCallbacks)
        return Result(_socket_backend.shutdown(socket, how));
    else
    {
        int t = int(how);
        switch (how)
        {
            version (WinSock)
            {
                case SocketShutdownMode.read:       t = SD_RECEIVE; break;
                case SocketShutdownMode.write:      t = SD_SEND;    break;
                case SocketShutdownMode.read_write: t = SD_BOTH;    break;
            }
            else version (BSDSockets)
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
}

Result bind(Socket socket, ref const InetAddress address)
{
    version (SocketCallbacks)
        return Result(_socket_backend.bind(socket, address));
    else
    {
        ubyte[512] buffer = void;
        size_t addr_len;
        sockaddr* sock_addr = make_sockaddr(address, buffer, addr_len);
        assert(sock_addr, "Invalid socket address");

        if (_bind(socket.handle, sock_addr, cast(int)addr_len) < 0)
            return socket_getlasterror();
        return Result.success;
    }
}

Result listen(Socket socket, uint backlog = -1)
{
    version (SocketCallbacks)
        return Result(_socket_backend.listen(socket, backlog));
    else
    {
        if (_listen(socket.handle, int(backlog & 0x7FFFFFFF)) < 0)
            return socket_getlasterror();
        return Result.success;
    }
}

Result connect(Socket socket, ref const InetAddress address)
{
    version (SocketCallbacks)
        return Result(_socket_backend.connect(socket, address));
    else
    {
        ubyte[512] buffer = void;
        size_t addr_len;
        sockaddr* sock_addr = make_sockaddr(address, buffer, addr_len);
        assert(sock_addr, "Invalid socket address");

        if (_connect(socket.handle, sock_addr, cast(int)addr_len) < 0)
            return socket_getlasterror();
        return Result.success;
    }
}

Result accept(Socket socket, out Socket connection, InetAddress* remote_address = null, InetAddress* local_address = null)
{
    version (SocketCallbacks)
    {
        Result r = Result(_socket_backend.accept(socket, connection, remote_address));
        if (!r)
            return r;
        if (local_address)
            return get_socket_name(connection, *local_address);
        return Result.success;
    }
    else
    {
        char[sockaddr_storage.sizeof] buffer = void;
        sockaddr* addr = cast(sockaddr*)buffer.ptr;
        socklen_t size = buffer.sizeof;

        connection.handle = _accept(socket.handle, addr, &size);
        if (connection == Socket.invalid)
            return socket_getlasterror();
        if (remote_address)
            *remote_address = make_InetAddress(addr);
        if (local_address)
        {
            if (getsockname(connection.handle, addr, &size) < 0)
                return socket_getlasterror();
            *local_address = make_InetAddress(addr);
        }
        // platforms are inconsistent regarding whether accept inherits the listening socket's blocking mode
        // for consistentency, we always set blocking on the accepted socket
        connection.set_socket_option(SocketOption.non_blocking, false);
        return Result.success;
    }
}

Result send(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.none, size_t* bytes_sent = null)
{
    version (SocketCallbacks)
        return sendmsg(socket, null, flags, null, bytes_sent, (&message)[0..1]);
    else
        return send(socket, flags, bytes_sent, (&message)[0..1]);
}

Result send(Socket socket, MsgFlags flags, size_t* bytes_sent, const void[][] buffers...)
{
    version (SocketCallbacks)
        return sendmsg(socket, null, flags, null, bytes_sent, buffers);
    else version (WinSock)
    {
        uint sent;
        WSABUF[32] bufs = void;
        assert(buffers.length <= bufs.length, "Too many buffers!");

        uint n = 0;
        foreach(buffer; buffers)
        {
            if (buffer.length == 0)
                continue;
            assert(buffer.length <= uint.max, "Buffer too large!");
            bufs[n].buf = cast(char*)buffer.ptr;
            bufs[n++].len = cast(uint)buffer.length;
        }
        if (n > 0)
        {
            int rc = WSASend(socket.handle, bufs.ptr, n, &sent, /+map_message_flags(flags)+/ 0, null, null); // there are no meaningful flags on Windows
            if (rc == SOCKET_ERROR)
                return socket_getlasterror();
        }
        if (bytes_sent)
            *bytes_sent = sent;
        return Result.success;
    }
    else
        return sendmsg(socket, null, flags, null, bytes_sent, buffers);
}

Result sendto(Socket socket, const(void)[] message, MsgFlags flags = MsgFlags.none, const InetAddress* address = null, size_t* bytes_sent = null)
{
    version (SocketCallbacks)
        return sendmsg(socket, address, flags, null, bytes_sent, (&message)[0..1]);
    else version (WinSock)
        return sendto(socket, address, bytes_sent, (&message)[0..1]);
    else
        return sendmsg(socket, address, flags, null, bytes_sent, (&message)[0..1]);
}

Result sendto(Socket socket, const InetAddress* address, size_t* bytes_sent, const void[][] buffers...)
{
    version (SocketCallbacks)
        return sendmsg(socket, address, MsgFlags.none, null, bytes_sent, buffers);
    else version (WinSock)
    {
        ubyte[sockaddr_storage.sizeof] tmp = void;
        size_t addr_len;
        sockaddr* sock_addr = null;
        if (address)
        {
            sock_addr = make_sockaddr(*address, tmp, addr_len);
            assert(sock_addr, "Invalid socket address");
        }

        uint sent;
        WSABUF[32] bufs = void;
        assert(buffers.length <= bufs.length, "Too many buffers!");

        uint n = 0;
        foreach(buffer; buffers)
        {
            if (buffer.length == 0)
                continue;
            assert(buffer.length <= uint.max, "Buffer too large!");
            bufs[n].buf = cast(char*)buffer.ptr;
            bufs[n++].len = cast(uint)buffer.length;
        }
        if (n > 0)
        {
            int r = WSASendTo(socket.handle, bufs.ptr, n, &sent, /+map_message_flags(flags)+/ 0, sock_addr, cast(int)addr_len, null, null); // there are no meaningful flags on Windows
            if (r == SOCKET_ERROR)
                return socket_getlasterror();
        }
        if (bytes_sent)
            *bytes_sent = sent;
        return Result.success;
    }
    else
        return sendmsg(socket, address, MsgFlags.none, null, bytes_sent, buffers);
}

Result sendmsg(Socket socket, const InetAddress* address, MsgFlags flags, const(void)[] control, size_t* bytes_sent, const void[][] buffers)
{
    version (SocketCallbacks)
        return Result(_socket_backend.sendmsg(socket, address, flags, buffers, bytes_sent));
    else
    {
        ubyte[sockaddr_storage.sizeof] tmp = void;
        size_t addr_len;
        sockaddr* sock_addr = null;
        if (address)
        {
            sock_addr = make_sockaddr(*address, tmp, addr_len);
            assert(sock_addr, "Invalid socket address");
        }

        version (WinSock)
        {
            uint sent;
            WSAMSG msg;
            WSABUF[32] bufs = void;
            assert(buffers.length <= bufs.length, "Too many buffers!");

            uint n = 0;
            foreach(buffer; buffers)
            {
                if (buffer.length == 0)
                    continue;
                assert(buffer.length <= uint.max, "Buffer too large!");
                bufs[n].buf = cast(char*)buffer.ptr;
                bufs[n++].len = cast(uint)buffer.length;
            }
            if (n > 0)
            {
                msg.name = sock_addr;
                msg.namelen = cast(int)addr_len;
                msg.lpBuffers = bufs.ptr;
                msg.dwBufferCount = n;
                msg.Control.buf = cast(char*)control.ptr;
                msg.Control.len = cast(uint)control.length;
                msg.dwFlags = 0;

                int rc = WSASendMsg(socket.handle, &msg, /+map_message_flags(flags)+/ 0, &sent, null, null); // there are no meaningful flags on Windows
                if (rc == SOCKET_ERROR)
                    return socket_getlasterror();
            }
        }
        else
        {
            ptrdiff_t sent;
            msghdr hdr;
            iovec[32] iov = void;
            assert(buffers.length <= iov.length, "Too many buffers!");

            size_t n = 0;
            foreach(buffer; buffers)
            {
                if (buffer.length == 0)
                    continue;
                assert(buffer.length <= uint.max, "Buffer too large!");
                iov[n].iov_base = cast(void*)buffer.ptr;
                iov[n++].iov_len = buffer.length;
            }
            if (n > 0)
            {
                hdr.msg_name = sock_addr;
                hdr.msg_namelen = cast(socklen_t)addr_len;
                hdr.msg_iov = iov.ptr;
                hdr.msg_iovlen = cast(typeof(hdr.msg_iovlen))n;
                hdr.msg_control = cast(void*)control.ptr;
                hdr.msg_controllen = cast(typeof(hdr.msg_controllen))control.length;
                hdr.msg_flags = 0;

                sent = _sendmsg(socket.handle, &hdr, map_message_flags(flags));
                if (sent < 0)
                    return socket_getlasterror();
            }
        }
        if (bytes_sent)
            *bytes_sent = sent;
        return Result.success;
    }
}

Result pending(Socket socket, out size_t bytes_available)
{
    version (SocketCallbacks)
        return Result(_socket_backend.pending(socket, bytes_available));
    else
    {
        version (WinSock)
        {
            import urt.internal.sys.windows.winsock2 : ioctlsocket, FIONREAD;
            uint avail;
            if (ioctlsocket(socket.handle, FIONREAD, &avail) != 0)
                return socket_getlasterror();
            bytes_available = avail;
        }
        else version (Posix)
        {
            import urt.internal.os : ioctl;
            int avail;
            if (ioctl(socket.handle, 0x541B, &avail) < 0) // FIONREAD
                return socket_getlasterror();
            bytes_available = avail;
        }
        else version (lwIP)
        {
            uint avail;
            if (ioctlsocket(socket.handle, FIONREAD, &avail) != 0)
                return socket_getlasterror();
            bytes_available = avail;
        }
        else
            static assert(false, "Platform not supported");
        return Result.success;
    }
}

Result recv(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.none, size_t* bytes_received)
{
    version (SocketCallbacks)
        return Result(_socket_backend.recv(socket, buffer, flags, bytes_received));
    else
    {
        Result r = Result.success;
        ptrdiff_t bytes = _recv(socket.handle, buffer.ptr, cast(int)buffer.length, map_message_flags(flags));
        if (bytes > 0)
            *bytes_received = bytes;
        else
        {
            *bytes_received = 0;
            if (bytes == 0)
            {
                // if we request 0 bytes, we receive 0 bytes, and it doesn't imply end-of-stream
                if (buffer.length > 0)
                {
                    // a graceful disconnection occurred
                    // TODO: !!!
                    r = ConnectionClosedResult;
//                    r = InternalResult(InternalCode.RemoteDisconnected);
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
}

Result recvfrom(Socket socket, void[] buffer, MsgFlags flags = MsgFlags.none, InetAddress* sender_address = null, size_t* bytes_received, InetAddress* local_address = null)
{
    version (SocketCallbacks)
    {
        assert(local_address is null, "local_address not supported on callback backend");
        return Result(_socket_backend.recvfrom(socket, buffer, flags, sender_address, bytes_received));
    }
    else
    {
        char[sockaddr_storage.sizeof] addr_buffer = void;
        sockaddr* addr = cast(sockaddr*)addr_buffer.ptr;

        if (local_address)
        {
            version (WinSock)
            {
                assert(WSARecvMsg, "WSARecvMsg not available!");

                void[1500] ctrl = void; // HUGE BUFFER!

                WSABUF msg_buf;
                msg_buf.buf = cast(char*)buffer.ptr;
                msg_buf.len = cast(uint)buffer.length;

                WSAMSG msg;
                msg.name = addr;
                msg.namelen = addr_buffer.sizeof;
                msg.lpBuffers = &msg_buf;
                msg.dwBufferCount = 1;
                msg.Control.buf = cast(char*)ctrl.ptr;
                msg.Control.len = cast(uint)ctrl.length;
                msg.dwFlags = 0;
                uint bytes;
                int r = WSARecvMsg(socket.handle, &msg, &bytes, null, null);
                if (r == 0)
                    *bytes_received = bytes;
                else
                {
                    *bytes_received = 0;
                    goto fail;
                }

                // parse the control messages
                *local_address = InetAddress();
                for (WSACMSGHDR* c = WSA_CMSG_FIRSTHDR(&msg); c != null; c = WSA_CMSG_NXTHDR(&msg, c))
                {
                    if (c.cmsg_level == IPPROTO_IP && c.cmsg_type == IP_PKTINFO)
                    {
                        IN_PKTINFO* pk = cast(IN_PKTINFO*)WSA_CMSG_DATA(c);
                        *local_address = InetAddress(make_IPAddr(pk.ipi_addr), 0); // TODO: be nice to populate the listening port...
                        // pk.ipi_ifindex   = receiving interface index
                    }
                    if (c.cmsg_level == IPPROTO_IPV6 && c.cmsg_type == IPV6_PKTINFO)
                    {
                        IN6_PKTINFO* pk6 = cast(IN6_PKTINFO*)WSA_CMSG_DATA(c);
                        *local_address = InetAddress(make_IPv6Addr(pk6.ipi6_addr), 0); // TODO: be nice to populate the listening port...
                        // pk6.ipi6_ifindex = receiving interface index
                    }
                }
            }
            else
            {
                assert(false, "TODO: call recvmsg and all that...");
            }
        }
        else
        {
            socklen_t size = addr_buffer.sizeof;
            ptrdiff_t bytes = _recvfrom(socket.handle, buffer.ptr, cast(int)buffer.length, map_message_flags(flags), addr, &size);
            if (bytes >= 0)
                *bytes_received = bytes;
            else
            {
                *bytes_received = 0;
                goto fail;
            }
        }

        if (sender_address)
            *sender_address = make_InetAddress(addr);
        return Result.success;

    fail:
        Result error = socket_getlasterror();
        SocketResult sockRes = socket_result(error);
        if (sockRes != SocketResult.no_buffer && // buffers full
            sockRes != SocketResult.connection_refused && // posix error
            sockRes != SocketResult.connection_reset) // !!! windows may report this error, but it appears to mean something different on posix
            return error;
        return Result.success;
    }
}

Result set_socket_option(Socket socket, SocketOption option, const(void)* optval, size_t optlen)
{
    version (SocketCallbacks)
        return Result(_socket_backend.set_option(socket, option, optval, optlen));
    else
    {
        Result r = Result.success;

        // check the option appears to be the proper datatype
        const OptInfo* opt_info = &s_socketOptions[option];
        assert(opt_info.rt_type != OptType.unsupported, "Socket option is unsupported on this platform!");
        assert(optlen == s_optTypeRtSize[opt_info.rt_type], "Socket option has incorrect payload size!");

        // special case for non-blocking
        // this is not strictly a 'socket option', but this rather simplifies our API
        if (option == SocketOption.non_blocking)
        {
            bool value = *cast(const(bool)*)optval;
            version (WinSock)
            {
                uint opt = value ? 1 : 0;
                r.system_code = ioctlsocket(socket.handle, FIONBIO, &opt);
            }
            else version (BSDSockets)
            {
                version (lwIP)
                {
                    // lwIP's fcntl has quirks with F_SETFL; use ioctlsocket(FIONBIO) instead.
                    int opt = value ? 1 : 0;
                    r.system_code = ioctlsocket(socket.handle, FIONBIO, &opt);
                }
                else
                {
                    int flags = fcntl(socket.handle, F_GETFL, 0);
                    r.system_code = fcntl(socket.handle, F_SETFL, value ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK));
                }
            }
            else
                assert(false, "Not implemented!");
            return r;
        }

//        // Convenience for socket-level no signal since some platforms only support message flag
//        if (option == SocketOption.NoSigPipe)
//        {
//            LockGuard!SharedMutex lock(s_noSignalMut);
//            s_noSignal.InsertOrAssign(socket.handle, *cast(const(bool)*)optval);
//
//            if (opt_info.platform_type == OptType.unsupported)
//                return r;
//        }

        // determine the option 'level'
        OptLevel level = get_optlevel(option);
        version (HasIPv6) {} else
            assert(level != OptLevel.ipv6 && level != OptLevel.icmpv6, "Platform does not support IPv6!");

        // platforms don't all agree on option data formats!
        const(void)* arg = optval;
        int itmp = void;
        linger ling = void;
        if (opt_info.rt_type != opt_info.platform_type)
        {
            switch (opt_info.rt_type)
            {
                // TODO: there are more converstions necessary as options/platforms are added
                case OptType.bool_:
                {
                    const bool value = *cast(const(bool)*)optval;
                    switch (opt_info.platform_type)
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
                    switch (opt_info.platform_type)
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
                            ling = linger(!!itmp, cast(typeof(linger.l_linger))itmp);
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
        r.system_code = setsockopt(socket.handle, s_sockOptLevel[level], opt_info.option, cast(const(char)*)arg, s_optTypePlatformSize[opt_info.platform_type]);

        return r;
    }
}

Result set_socket_option(Socket socket, SocketOption option, bool value)
{
    version (SocketCallbacks)
        return set_socket_option(socket, option, &value, bool.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.bool_, "Incorrect value type for option");
        return set_socket_option(socket, option, &value, bool.sizeof);
    }
}

Result set_socket_option(Socket socket, SocketOption option, int value)
{
    version (SocketCallbacks)
        return set_socket_option(socket, option, &value, int.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.int_, "Incorrect value type for option");
        return set_socket_option(socket, option, &value, int.sizeof);
    }
}

Result set_socket_option(Socket socket, SocketOption option, Duration value)
{
    version (SocketCallbacks)
        return set_socket_option(socket, option, &value, Duration.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.duration, "Incorrect value type for option");
        return set_socket_option(socket, option, &value, Duration.sizeof);
    }
}

Result set_socket_option(Socket socket, SocketOption option, IPAddr value)
{
    version (SocketCallbacks)
        return set_socket_option(socket, option, &value, IPAddr.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.inet_addr, "Incorrect value type for option");
        return set_socket_option(socket, option, &value, IPAddr.sizeof);
    }
}

Result set_socket_option(Socket socket, SocketOption option, ref MulticastGroup value)
{
    version (SocketCallbacks)
        return set_socket_option(socket, option, &value, MulticastGroup.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.multicast_group, "Incorrect value type for option");
        return set_socket_option(socket, option, &value, MulticastGroup.sizeof);
    }
}

Result get_socket_option(Socket socket, SocketOption option, void* output, size_t outputlen)
{
    version (SocketCallbacks)
        return Result(_socket_backend.get_option(socket, option, output, outputlen));
    else
    {
        Result r = Result.success;

        // check the option appears to be the proper datatype
        const OptInfo* opt_info = &s_socketOptions[option];
        assert(opt_info.rt_type != OptType.unsupported, "Socket option is unsupported on this platform!");
        assert(outputlen == s_optTypeRtSize[opt_info.rt_type], "Socket option has incorrect payload size!");

        assert(option != SocketOption.non_blocking, "Socket option NonBlocking cannot be get");

        // determine the option 'level'
        OptLevel level = get_optlevel(option);
        version (HasIPv6) {} else
            assert(level != OptLevel.ipv6 && level != OptLevel.icmpv6, "Platform does not support IPv6!");

        // platforms don't all agree on option data formats!
        void* arg = output;
        int itmp = 0;
        linger ling = { 0, 0 };
        if (opt_info.rt_type != opt_info.platform_type)
        {
            switch (opt_info.platform_type)
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

        socklen_t writtenLen = s_optTypePlatformSize[opt_info.platform_type];
        // get the option
        r.system_code = getsockopt(socket.handle, s_sockOptLevel[level], opt_info.option, cast(char*)arg, &writtenLen);

        if (opt_info.rt_type != opt_info.platform_type)
        {
            switch (opt_info.rt_type)
            {
                // TODO: there are more converstions necessary as options/platforms are added
                case OptType.bool_:
                {
                    bool* value = cast(bool*)output;
                    switch (opt_info.platform_type)
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
                    switch (opt_info.platform_type)
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

        assert(opt_info.rt_type != OptType.inet_addr, "TODO: uncomment this block... for some reason, this block causes DMD to do a bad codegen!");
/+
        // Options expected in network-byte order
        switch (opt_info.rt_type)
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
}

Result get_socket_option(Socket socket, SocketOption option, out bool output)
{
    version (SocketCallbacks)
        return get_socket_option(socket, option, &output, bool.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.bool_, "Incorrect value type for option");
        return get_socket_option(socket, option, &output, bool.sizeof);
    }
}

Result get_socket_option(Socket socket, SocketOption option, out int output)
{
    version (SocketCallbacks)
        return get_socket_option(socket, option, &output, int.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.int_, "Incorrect value type for option");
        return get_socket_option(socket, option, &output, int.sizeof);
    }
}

Result get_socket_option(Socket socket, SocketOption option, out Duration output)
{
    version (SocketCallbacks)
        return get_socket_option(socket, option, &output, Duration.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.duration, "Incorrect value type for option");
        return get_socket_option(socket, option, &output, Duration.sizeof);
    }
}

Result get_socket_option(Socket socket, SocketOption option, out IPAddr output)
{
    version (SocketCallbacks)
        return get_socket_option(socket, option, &output, IPAddr.sizeof);
    else
    {
        const OptInfo* opt_info = &s_socketOptions[option];
        if (opt_info.rt_type == OptType.unsupported)
            return InternalResult.unsupported;
        assert(opt_info.rt_type == OptType.inet_addr, "Incorrect value type for option");
        return get_socket_option(socket, option, &output, IPAddr.sizeof);
    }
}

Result set_keepalive(Socket socket, bool enable, Duration keepIdle, Duration keepInterval, int keepCount)
{
    version (WinSock)
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
    version (SocketCallbacks)
        return Result(_socket_backend.get_peer_name(socket, name));
    else
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
}

Result get_socket_name(Socket socket, out InetAddress name)
{
    version (SocketCallbacks)
        return Result(_socket_backend.get_socket_name(socket, name));
    else
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
}

Result get_hostname(char* name, size_t len)
{
    version (SocketCallbacks)
        return Result(_socket_backend.get_hostname(name, len));
    else
    {
        int fail = gethostname(name, cast(int)len);
        if (fail)
            return socket_getlasterror();
        return Result.success;
    }
}

Result get_address_info(const(char)[] nodeName, const(char)[] service, AddressInfo* hints, out AddressInfoResolver result)
{
    import urt.string : findFirst;

    size_t colon = nodeName.findFirst(':');
    if (colon < nodeName.length)
    {
        if (!service)
            service = nodeName[colon + 1..$];
        nodeName = nodeName[0 .. colon];
    }

    version (SocketCallbacks)
    {
        // Backend fills the resolver with a defaultAllocator-allocated
        // array of AddressInfo entries (sentinel-terminated).
        return Result(_socket_backend.get_address_info(nodeName, service, hints, &result));
    }
    else
    {
        import urt.mem.temp : tstringz;

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
}

Result poll(PollFd[] pollFds, Duration timeout, out uint numEvents)
{
    version (SocketCallbacks)
        return Result(_socket_backend.poll(pollFds, timeout, numEvents));
    else
    {
        enum MaxFds = 512;
        assert(pollFds.length <= MaxFds, "Too many fds!");
        version (WinSock)
            WSAPOLLFD[MaxFds] fds;
        else
            pollfd[MaxFds] fds;
        for (size_t i = 0; i < pollFds.length; ++i)
        {
            fds[i].fd = pollFds[i].socket.handle;
            fds[i].revents = 0;
            fds[i].events = cast(short)(((pollFds[i].request_events & PollEvents.read)  ? POLLRDNORM : 0) |
                            ((pollFds[i].request_events & PollEvents.write) ? POLLWRNORM : 0));
        }
        int r;
        version (WinSock)
            r = WSAPoll(fds.ptr, cast(uint)pollFds.length, timeout.ticks < 0 ? -1 : cast(int)timeout.as!"msecs");
        else version (BSDSockets)
            r = _poll(fds.ptr, cast(uint)pollFds.length, timeout.ticks < 0 ? -1 : cast(int)timeout.as!"msecs");
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
        {
            version (SocketCallbacks)
                _socket_backend.free_address_info(&this);
            else
                freeaddrinfo(cast(addrinfo*)m_internal[0]);
        }
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

        version (SocketCallbacks)
            return _socket_backend.next_address(&this, addressInfo);
        else
        {
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



Result get_socket_error(Socket socket)
{
    version (SocketCallbacks)
    {
        int err;
        Result r = get_socket_option(socket, SocketOption.error, err);
        if (r)
            r.system_code = err;
        return r;
    }
    else
    {
        Result r;
        socklen_t optlen = r.system_code.sizeof;
        int callResult = getsockopt(socket.handle, SOL_SOCKET, SO_ERROR, cast(char*)&r.system_code, &optlen);
        if (callResult)
            r.system_code = callResult;
        return r;
    }
}

// TODO: !!!
enum Result ConnectionClosedResult = Result(-12345);
SocketResult socket_result(Result result)
{
    version (SocketCallbacks)
        return cast(SocketResult)result.system_code;
    else
    {
        if (result)
            return SocketResult.success;
        if (result.system_code == ConnectionClosedResult.system_code)
            return SocketResult.connection_closed;
        else version (WinSock)
        {
            if (result.system_code == WSAEWOULDBLOCK)
                return SocketResult.would_block;
            if (result.system_code == WSAEINPROGRESS)
                return SocketResult.would_block;
            if (result.system_code == WSAENOBUFS)
                return SocketResult.no_buffer;
            if (result.system_code == WSAENETDOWN)
                return SocketResult.network_down;
            if (result.system_code == WSAENETUNREACH)
                return SocketResult.network_unreachable;
            if (result.system_code == WSAEHOSTUNREACH)
                return SocketResult.host_unreachable;
            if (result.system_code == WSAECONNREFUSED)
                return SocketResult.connection_refused;
            if (result.system_code == WSAECONNRESET)
                return SocketResult.connection_reset;
            if (result.system_code == WSAECONNABORTED)
                return SocketResult.connection_aborted;
            if (result.system_code == WSAEADDRINUSE)
                return SocketResult.address_in_use;
            if (result.system_code == WSAEADDRNOTAVAIL)
                return SocketResult.address_not_available;
            if (result.system_code == WSAETIMEDOUT)
                return SocketResult.timed_out;
            if (result.system_code == WSAENOTCONN)
                return SocketResult.not_connected;
            if (result.system_code == WSAEISCONN)
                return SocketResult.already_connected;
            if (result.system_code == WSAEACCES)
                return SocketResult.permission_denied;
            if (result.system_code == WSAEINTR)
                return SocketResult.interrupted;
            if (result.system_code == WSAENOTSOCK)
                return SocketResult.invalid_socket;
            if (result.system_code == WSAEINVAL)
                return SocketResult.invalid_argument;
        }
        else version (Errno)
        {
            import urt.internal.stdc.errno;
            static if (EAGAIN != EWOULDBLOCK)
                if (result.system_code == EAGAIN)
                    return SocketResult.would_block;
            if (result.system_code == EWOULDBLOCK)
                return SocketResult.would_block;
            if (result.system_code == EINPROGRESS)
                return SocketResult.would_block;
            if (result.system_code == ENOMEM)
                return SocketResult.no_buffer;
            if (result.system_code == ENETDOWN)
                return SocketResult.network_down;
            if (result.system_code == ENETUNREACH)
                return SocketResult.network_unreachable;
            if (result.system_code == EHOSTUNREACH)
                return SocketResult.host_unreachable;
            if (result.system_code == ECONNREFUSED)
                return SocketResult.connection_refused;
            if (result.system_code == ECONNRESET)
                return SocketResult.connection_reset;
            if (result.system_code == ECONNABORTED)
                return SocketResult.connection_aborted;
            if (result.system_code == EADDRINUSE)
                return SocketResult.address_in_use;
            if (result.system_code == EADDRNOTAVAIL)
                return SocketResult.address_not_available;
            if (result.system_code == ETIMEDOUT)
                return SocketResult.timed_out;
            if (result.system_code == ENOTCONN)
                return SocketResult.not_connected;
            if (result.system_code == EISCONN)
                return SocketResult.already_connected;
            if (result.system_code == EACCES)
                return SocketResult.permission_denied;
            if (result.system_code == EINTR)
                return SocketResult.interrupted;
            if (result.system_code == EINVAL)
                return SocketResult.invalid_argument;
        }
        return SocketResult.failure;
    }
}

private:

version (SocketCallbacks) {} else {

Result socket_getlasterror()
{
    version (WinSock)
        return Result(WSAGetLastError());
    else version (Errno)
        return errno_result();
    else
        static assert(false, "socket_getlasterror not implemented for this platform");
}

sockaddr* make_sockaddr(ref const InetAddress address, ubyte[] buffer, out size_t addr_len)
{
    sockaddr* sock_addr = cast(sockaddr*)buffer.ptr;

    switch (address.family)
    {
        case AddressFamily.ipv4:
        {
            addr_len = sockaddr_in.sizeof;
            if (buffer.length < sockaddr_in.sizeof)
                return null;

            sockaddr_in* ain = cast(sockaddr_in*)sock_addr;
            memzero(ain, sockaddr_in.sizeof);
            version (lwIP)
                ain.sin_len = sockaddr_in.sizeof;
            ain.sin_family = s_addressFamily[AddressFamily.ipv4];
            version (WinSock)
            {
                ain.sin_addr.S_un.S_un_b.s_b1 = address._a.ipv4.addr.b[0];
                ain.sin_addr.S_un.S_un_b.s_b2 = address._a.ipv4.addr.b[1];
                ain.sin_addr.S_un.S_un_b.s_b3 = address._a.ipv4.addr.b[2];
                ain.sin_addr.S_un.S_un_b.s_b4 = address._a.ipv4.addr.b[3];
            }
            else version (BSDSockets)
                ain.sin_addr.s_addr = address._a.ipv4.addr.address;
            else
                assert(false, "Not implemented!");
            storeBigEndian(&ain.sin_port, ushort(address._a.ipv4.port));
            break;
        }
        case AddressFamily.ipv6:
        {
            version (HasIPv6)
            {
                addr_len = sockaddr_in6.sizeof;
                if (buffer.length < sockaddr_in6.sizeof)
                    return null;

                sockaddr_in6* ain6 = cast(sockaddr_in6*)sock_addr;
                memzero(ain6, sockaddr_in6.sizeof);
                version (lwIP)
                    ain6.sin6_len = sockaddr_in6.sizeof;
                ain6.sin6_family = s_addressFamily[AddressFamily.ipv6];
                storeBigEndian(&ain6.sin6_port, cast(ushort)address._a.ipv6.port);
                storeBigEndian(cast(uint*)&ain6.sin6_flowinfo, address._a.ipv6.flow_info);
                storeBigEndian(cast(uint*)&ain6.sin6_scope_id, address._a.ipv6.scopeId);
                for (int a = 0; a < 8; ++a)
                {
                    version (WinSock)
                        storeBigEndian(&ain6.sin6_addr.in6_u.u6_addr16[a], address._a.ipv6.addr.s[a]);
                    else version (Posix)
                        storeBigEndian(&ain6.sin6_addr.__in6_u.__u6_addr16[a], address._a.ipv6.addr.s[a]);
                    else version (BSDSockets)
                        storeBigEndian(cast(ushort*)&ain6.sin6_addr.s6_addr[a * 2], address._a.ipv6.addr.s[a]);
                    else
                        assert(false, "Not implemented!");
                }
            }
            else
                assert(false, "Platform does not support IPv6!");
            break;
        }
        case AddressFamily.unix:
        {
//            version (HasUnixSocket)
//            {
//                addr_len = sockaddr_un.sizeof;
//                if (buffer.length < sockaddr_un.sizeof)
//                    return null;
//
//                sockaddr_un* aun = cast(sockaddr_un*)sock_addr;
//                memzero(aun, sockaddr_un.sizeof);
//                aun.sun_family = s_addressFamily[AddressFamily.unix];
//
//                memcpy(aun.sun_path, address.un.path, UNIX_PATH_LEN);
//                break;
//            }
//            else
                assert(false, "Platform does not support unix sockets!");
        }
        default:
        {
            sock_addr = null;
            addr_len = 0;

            assert(false, "Unsupported address family");
            break;
        }
    }

    return sock_addr;
}

InetAddress make_InetAddress(const(sockaddr)* sock_address)
{
    InetAddress addr;
    addr.family = map_address_family(sock_address.sa_family);
    switch (addr.family)
    {
        case AddressFamily.ipv4:
        {
            const sockaddr_in* ain = cast(const(sockaddr_in)*)sock_address;

            addr._a.ipv4.port = loadBigEndian(&ain.sin_port);
            addr._a.ipv4.addr = make_IPAddr(ain.sin_addr);
            break;
        }
        case AddressFamily.ipv6:
        {
            version (HasIPv6)
            {
                const sockaddr_in6* ain6 = cast(const(sockaddr_in6)*)sock_address;

                addr._a.ipv6.port = loadBigEndian(&ain6.sin6_port);
                addr._a.ipv6.flow_info = loadBigEndian(cast(const(uint)*)&ain6.sin6_flowinfo);
                addr._a.ipv6.scopeId = loadBigEndian(cast(const(uint)*)&ain6.sin6_scope_id);
                addr._a.ipv6.addr = make_IPv6Addr(ain6.sin6_addr);
            }
            else
                assert(false, "Platform does not support IPv6!");
            break;
        }
        case AddressFamily.unix:
        {
//            version (HasUnixSocket)
//            {
//                const sockaddr_un* aun = cast(const(sockaddr_un)*)sock_address;
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

IPAddr make_IPAddr(ref const in_addr in4)
{
    IPAddr addr;
    version (WinSock)
    {
        addr.b[0] = in4.S_un.S_un_b.s_b1;
        addr.b[1] = in4.S_un.S_un_b.s_b2;
        addr.b[2] = in4.S_un.S_un_b.s_b3;
        addr.b[3] = in4.S_un.S_un_b.s_b4;
    }
    else version (BSDSockets)
        addr.address = in4.s_addr;
    else
        assert(false, "Not implemented!");
    return addr;
}

IPv6Addr make_IPv6Addr(ref const in6_addr in6)
{
    IPv6Addr addr;
    for (int a = 0; a < 8; ++a)
    {
        version (WinSock)
            addr.s[a] = loadBigEndian(&in6.in6_u.u6_addr16[a]);
        else version (Posix)
            addr.s[a] = loadBigEndian(&in6.__in6_u.__u6_addr16[a]);
        else version (BSDSockets)
            addr.s[a] = loadBigEndian(cast(const(ushort)*)&in6.s6_addr[a * 2]);
        else
            assert(false, "Not implemented!");
    }
    return addr;
}

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

version (lwIP)
    alias sa_family_t = ubyte;
else
    alias sa_family_t = ushort;

__gshared immutable sa_family_t[AddressFamily.max+1] s_addressFamily = [
    AF_UNSPEC,
    AF_UNIX,
    AF_INET,
    AF_INET6
];
AddressFamily map_address_family(int addressFamily)
{
    if (addressFamily == AF_INET)
        return AddressFamily.ipv4;
    else if (addressFamily == AF_INET6)
        return AddressFamily.ipv6;
    else if (addressFamily == AF_UNIX)
        return AddressFamily.unix;
    else if (addressFamily == AF_UNSPEC)
        return AddressFamily.unspecified;
    assert(false, "Unsupported address family");
    return AddressFamily.unknown;
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

version (WinSock) // BS_NETWORK_WINDOWS_VERSION >= _WIN32_WINNT_VISTA
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
        OptInfo( IP_PKTINFO, OptType.bool_, OptType.int_ ),
        OptInfo( IPV6_RECVPKTINFO, OptType.bool_, OptType.int_ ),
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
        OptInfo( IP_PKTINFO, OptType.bool_, OptType.int_ ),
        OptInfo( IPV6_RECVPKTINFO, OptType.bool_, OptType.int_ ),
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
        OptInfo( IP_PKTINFO, OptType.bool_, OptType.int_ ),
        OptInfo( IPV6_RECVPKTINFO, OptType.bool_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ),
        OptInfo( TCP_KEEPALIVE, OptType.duration, OptType.seconds ),
        OptInfo( TCP_NODELAY, OptType.bool_, OptType.int_ ),
    ];
}
else version (lwIP)
{
    __gshared immutable OptInfo[SocketOption.max] s_socketOptions = [
        OptInfo( -1, OptType.bool_, OptType.bool_ ), // NonBlocking
        OptInfo( SO_KEEPALIVE, OptType.bool_, OptType.int_ ),
        OptInfo( SO_LINGER, OptType.duration, OptType.linger ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ), // RandomizePort
        OptInfo( SO_SNDBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_RCVBUF, OptType.int_, OptType.int_ ),
        OptInfo( SO_REUSEADDR, OptType.bool_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ), // NoSigPipe
        OptInfo( SO_ERROR, OptType.int_, OptType.int_ ),
        OptInfo( IP_ADD_MEMBERSHIP, OptType.multicast_group, OptType.multicast_group ),
        OptInfo( IP_MULTICAST_LOOP, OptType.bool_, OptType.int_ ),
        OptInfo( IP_MULTICAST_TTL, OptType.int_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ), // IP_PKTINFO
        OptInfo( -1, OptType.unsupported, OptType.unsupported ), // IPV6_PKTINFO
        OptInfo( TCP_KEEPIDLE, OptType.duration, OptType.seconds ),
        OptInfo( TCP_KEEPINTVL, OptType.duration, OptType.seconds ),
        OptInfo( TCP_KEEPCNT, OptType.int_, OptType.int_ ),
        OptInfo( -1, OptType.unsupported, OptType.unsupported ), // TcpKeepAlive (Apple)
        OptInfo( TCP_NODELAY, OptType.bool_, OptType.int_ ),
    ];
}
else
    static assert(false, "TODO");

int map_message_flags(MsgFlags flags)
{
    int r = 0;
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
    version (WinSock)
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


version (WinSock)
{
    pragma(crt_constructor)
    void crt_bootup()
    {
        WSADATA wsaData;
        int result = WSAStartup(0x0202, &wsaData);
        // what if this fails???

        // this is truly the worst thing I ever wrote!!
        enum SIO_GET_EXTENSION_FUNCTION_POINTER = 0xC8000006;
        struct GUID { uint Data1; ushort Data2, Data3; ubyte[8] Data4; }
        __gshared immutable GUID WSAID_WSASENDMSG = GUID(0xA441E712, 0x754F, 0x43CA, [0x84,0xA7,0x0D,0xEE,0x44,0xCF,0x60,0x6D]);
        __gshared immutable GUID WSAID_WSARECVMSG = GUID(0xF689D7C8, 0x6F1F, 0x436B, [0x8A,0x53,0xE5,0x4F,0xE3,0x51,0xC3,0x22]);

        Socket dummy;
        uint bytes = 0;
        if (!create_socket(AddressFamily.ipv4, SocketType.datagram, Protocol.udp, dummy))
            goto FAIL;
        if (WSAIoctl(dummy.handle, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&WSAID_WSASENDMSG, cast(uint)GUID.sizeof,
                     &WSASendMsg, cast(uint)WSASendMsgFn.sizeof, &bytes, null, null) != 0)
            goto FAIL;
        assert(bytes == WSASendMsgFn.sizeof);
        if (WSAIoctl(dummy.handle, SIO_GET_EXTENSION_FUNCTION_POINTER, cast(void*)&WSAID_WSARECVMSG, cast(uint)GUID.sizeof,
                     &WSARecvMsg, cast(uint)WSARecvMsgFn.sizeof, &bytes, null, null) != 0)
            goto FAIL;
        assert(bytes == WSARecvMsgFn.sizeof);
        dummy.close();
        if (!WSASendMsg || !WSARecvMsg)
            goto FAIL;
        return;

    FAIL:
        import urt.log;
        writeWarning("Failed to get WSASendMsg/WSARecvMsg function pointers - sendmsg() won't work, recvfrom() won't be able to report the dst address");
    }

    pragma(crt_destructor)
    void crt_shutdown()
    {
        WSACleanup();
    }
}





// TODO: REMOVE ME - pushed to druntime...
version (WinSock)
{
    // stuff that's missing from the windows headers...

    enum : int
    {
        AI_NUMERICSERV = 0x0008,
        AI_ALL = 0x0100,
        AI_V4MAPPED = 0x0800,
        AI_FQDN = 0x4000,
    }

    struct ip_mreq
    {
        in_addr imr_multiaddr;
        in_addr imr_interface;
    }

    struct WSAMSG
    {
        LPSOCKADDR name;
        int        namelen;
        LPWSABUF   lpBuffers;
        uint       dwBufferCount;
        WSABUF     Control;
        uint       dwFlags;
    }
    alias LPWSAMSG = WSAMSG*;

    struct WSABUF
    {
        uint len;
        char* buf;
    }
    alias LPWSABUF = WSABUF*;

    alias WSASendMsgFn = extern(Windows) int function(SOCKET s, LPWSAMSG lpMsg, uint dwFlags, uint* lpNumberOfBytesSent, LPWSAOVERLAPPED lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
    alias WSARecvMsgFn = extern(Windows) int function(SOCKET s, LPWSAMSG lpMsg, uint* lpdwNumberOfBytesRecvd, LPWSAOVERLAPPED lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
    __gshared WSASendMsgFn WSASendMsg;
    __gshared WSARecvMsgFn WSARecvMsg;

    struct IN_PKTINFO
    {
        in_addr ipi_addr;
        uint ipi_ifindex;
    }
    struct IN6_PKTINFO
    {
        in6_addr ipi6_addr;
        uint ipi6_ifindex;
    }

    struct WSACMSGHDR
    {
        size_t cmsg_len;
        int    cmsg_level;
        int    cmsg_type;
    }
    alias LPWSACMSGHDR = WSACMSGHDR*;

    LPWSACMSGHDR WSA_CMSG_FIRSTHDR(LPWSAMSG msg)
        => msg.Control.len >= WSACMSGHDR.sizeof ? cast(LPWSACMSGHDR)msg.Control.buf : null;

    LPWSACMSGHDR WSA_CMSG_NXTHDR(LPWSAMSG msg, LPWSACMSGHDR cmsg)
    {
        if (!cmsg)
            return WSA_CMSG_FIRSTHDR(msg);
        if (cast(ubyte*)cmsg + WSA_CMSGHDR_ALIGN(cmsg.cmsg_len) + WSACMSGHDR.sizeof > cast(ubyte*)msg.Control.buf + msg.Control.len)
            return null;
        return cast(LPWSACMSGHDR)(cast(ubyte*)cmsg + WSA_CMSGHDR_ALIGN(cmsg.cmsg_len));
    }

    void* WSA_CMSG_DATA(LPWSACMSGHDR cmsg)
        => cast(ubyte*)cmsg + WSA_CMSGDATA_ALIGN(WSACMSGHDR.sizeof);

    size_t WSA_CMSGHDR_ALIGN(size_t length)
        => (length + WSACMSGHDR.alignof-1) & ~(WSACMSGHDR.alignof-1);

    size_t WSA_CMSGDATA_ALIGN(size_t length)
        => (length + size_t.alignof-1) & ~(size_t.alignof-1);

     struct WSAOVERLAPPED
     {
        uint Internal;
        uint InternalHigh;
        uint Offset;
        uint OffsetHigh;
        HANDLE hEvent;
    }
    alias LPWSAOVERLAPPED = WSAOVERLAPPED*;

    alias LPWSAOVERLAPPED_COMPLETION_ROUTINE = void function(uint dwError, uint cbTransferred, LPWSAOVERLAPPED lpOverlapped, uint dwFlags);

    extern(Windows) int WSASend(SOCKET s, LPWSABUF lpBuffers, uint dwBufferCount, uint* lpNumberOfBytesSent, uint dwFlags, LPWSAOVERLAPPED lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
    extern(Windows) int WSASendTo(SOCKET s, LPWSABUF lpBuffers, uint dwBufferCount, uint* lpNumberOfBytesSent, uint dwFlags, const(sockaddr)* lpTo, int iTolen, LPWSAOVERLAPPED lpOverlapped, LPWSAOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine);
}

} // SocketCallbacks
