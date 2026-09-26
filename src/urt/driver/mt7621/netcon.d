module urt.driver.mt7621.netcon;

import urt.driver.mt7621.ethernet : eth_hw_get_hardware_address, fe_tx_tagged, num_front_ports;
import urt.endian : bigEndianToNative, nativeToBigEndian;

nothrow @nogc:

// TODO: bring-up netconsole: console output as UDP broadcasts to port 6666 out every front port,
// with the hEX S's MAC and a fixed address. Goes once OpenWatt carries a UDP log sink.

void netcon_put(const(char)[] s)
{
    foreach (c; s)
    {
        _line[_len++] = c;
        if (c == '\n' || _len == _line.length)
            netcon_flush();
    }
}

void netcon_flush()
{
    if (_len == 0)
        return;
    send(_line[0 .. _len]);
    _len = 0;
}


private:

__gshared char[1024] _line;
__gshared uint _len;
__gshared ushort _ip_id;

void send(const(char)[] payload)
{
    ubyte[14 + 20 + 8 + _line.length] f = void;
    immutable uint udp_len = 8 + cast(uint)payload.length;
    immutable uint ip_len = 20 + udp_len;

    f[0 .. 6] = 0xFF;
    ubyte[6] src_mac = void;
    eth_hw_get_hardware_address(0, 0, src_mac);
    f[6 .. 12] = src_mac;
    f[12] = 0x08;
    f[13] = 0x00;

    ubyte* ip = f.ptr + 14;
    ip[0] = 0x45;
    ip[1] = 0;
    ip[2 .. 4] = nativeToBigEndian(cast(ushort)ip_len);
    ip[4 .. 6] = nativeToBigEndian(_ip_id++);
    ip[6] = 0x40;
    ip[7] = 0;
    ip[8] = 64;
    ip[9] = 17;
    ip[10] = 0;
    ip[11] = 0;
    ip[12 .. 16] = src_ip;
    ip[16 .. 20] = 0xFF;
    uint sum = 0;
    foreach (k; 0 .. 10)
        sum += bigEndianToNative!ushort(ip[k * 2 .. k * 2 + 2][0 .. 2]);
    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);
    ip[10 .. 12] = nativeToBigEndian(cast(ushort)~sum);

    ubyte* udp = ip + 20;
    udp[0 .. 2] = nativeToBigEndian(cast(ushort)6666);
    udp[2 .. 4] = nativeToBigEndian(cast(ushort)6666);
    udp[4 .. 6] = nativeToBigEndian(cast(ushort)udp_len);
    udp[6 .. 8] = 0;
    foreach (k, c; payload)
        udp[8 + k] = c;

    fe_tx_tagged(f[0 .. 14 + ip_len], (1 << num_front_ports) - 1);
}


static immutable ubyte[4] src_ip = [192, 168, 0, 248];
