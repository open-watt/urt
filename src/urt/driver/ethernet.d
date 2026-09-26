module urt.driver.ethernet;

import urt.result : Result, InternalResult;

version (Espressif)
    public import urt.driver.esp32.ethernet;
else
{
    enum uint num_ethernet = 0;
    enum bool has_eth_timestamp = false;
    enum bool has_eth_gigabit = false;
    enum bool has_eth_pin_select = false;
    enum bool has_eth_tx_checksum = false;
}

nothrow @nogc:


enum size_t eth_max_frame = 1522;   // 1500 payload + 14 header + 4 VLAN + 4 FCS

// MAC to PHY data interface. platform_default takes the reference wiring of the part.
enum EthPhyInterface : ubyte
{
    platform_default,
    rmii,
    rgmii,
}

// Who sources the RMII 50MHz reference clock.
enum EthClockMode : ubyte
{
    platform_default,
    external,   // PHY or oscillator drives the MAC
    output,     // MAC drives the PHY from an internal PLL
}

enum EthPhy : ubyte
{
    generic,
    yt8531,     // Motorcomm gigabit: drops autonegotiation on reset, and needs its RGMII clock delays set
}

enum EthSpeed : ubyte
{
    s10m,
    s100m,
    s1000m,
}

enum EthLinkEvent : ubyte
{
    down,
    up,
}

struct EthernetConfig
{
    // -1 everywhere means the reference wiring of the part; phy_address -1 probes the bus.
    EthPhy phy;
    byte phy_address = -1;
    byte mdc_gpio = -1;
    byte mdio_gpio = -1;
    byte phy_reset_gpio = -1;
    EthPhyInterface phy_interface;
    EthClockMode clock_mode;
    byte clock_gpio = -1;
    byte clock_loopback_gpio = -1;  // where an output clock re-enters a MAC with no internal loopback
    // With has_eth_pin_select. RMII: tx_en txd0 txd1 crs_dv rxd0 rxd1.
    // RGMII: tx_ctl txd0-3 rx_ctl rxd0-3 rx_clk tx_clk.
    byte[12] data_gpio = -1;
    bool promiscuous = true;
    bool flow_control;
    bool timestamp;     // hardware receive timestamps; needs has_eth_timestamp
    bool tx_checksum;   // allow eth_tx to ask for checksum insertion; needs has_eth_tx_checksum
}

struct EthLinkInfo
{
    EthSpeed speed;
    bool full_duplex;
}

struct EthTime
{
    uint seconds;
    uint nanoseconds;
}

struct EthRxInfo
{
    EthTime timestamp;  // when the SFD crossed the MAC, on the MAC clock
    bool has_timestamp;
    bool checksum_verified; // the MAC checked the IP header and TCP or UDP checksum of this frame
}

// Delivered by eth_service() for each frame received on the port. Frame starts at the
// destination address, carries no FCS, and is valid only until the callback returns.
alias EthRxCallback = void function(void* context, const(ubyte)[] frame, ref const EthRxInfo info) nothrow @nogc;

// Delivered by eth_service() on each link transition of the port.
alias EthLinkCallback = void function(void* context, EthLinkEvent event) nothrow @nogc;

// Same contract as WifiReadyCallback: may fire from task or interrupt
// context, must only signal or schedule service, never re-enter the driver.
alias EthReadyCallback = void function() nothrow @nogc;

// A MAC is a switch with eth_ports(mac) front ports, one when it is wired to a single PHY. A port
// is what opens, sends, receives and reports link; the MAC comes up with its first and goes down
// with its last.
struct EthPort
{
    ubyte mac = ubyte.max;
    ubyte port;
}

bool is_open(ref const EthPort p) pure
    => p.mac != ubyte.max;


void eth_set_ready_callback(EthReadyCallback cb)
{
    static if (num_ethernet > 0)
        eth_hw_set_ready_callback(cb);
}

// The vendor's name for the MAC (e.g. "ge1"); null where the platform does not name its MACs.
const(char)[] eth_name(ubyte mac)
{
    static if (__traits(compiles, eth_hw_name(mac)))
        return mac < num_ethernet ? eth_hw_name(mac) : null;
    else
        return null;
}

uint eth_ports(ubyte mac)
{
    static if (num_ethernet == 0)
        return 0;
    else
        return mac < num_ethernet ? eth_hw_ports(mac) : 0;
}

// The MAC takes the configuration of the first port opened on it. Link events arrive asynchronously after open.
Result eth_open(ref EthPort p, ubyte mac, ubyte port, ref const EthernetConfig cfg, EthRxCallback rx, EthLinkCallback link, void* context)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (p.is_open)
            return InternalResult.already_exists;
        if (mac >= num_ethernet || port >= eth_hw_ports(mac))
            return InternalResult.invalid_parameter;
        if (cfg.timestamp && !has_eth_timestamp)
            return InternalResult.unsupported;
        if (cfg.tx_checksum && !has_eth_tx_checksum)
            return InternalResult.unsupported;
        if (cfg.phy_interface == EthPhyInterface.rgmii && !has_eth_gigabit)
            return InternalResult.unsupported;
        assert(eth_hw_ports(mac) <= 32);
        if (_open_ports[mac] & (1u << port))
            return InternalResult.already_exists;
        if (!eth_hw_open(mac, port, cfg, rx, link, context))
            return InternalResult.failed;
        _open_ports[mac] |= 1u << port;
        p = EthPort(mac, port);
        return Result.success;
    }
}

// On failure the handle stays open and the close is to be retried; nothing was released.
Result eth_close(ref EthPort p)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (!p.is_open)
            return Result.success;
        if (!eth_hw_close(p.mac, p.port))
            return InternalResult.failed;
        _open_ports[p.mac] &= ~(1u << p.port);
    }
    p = EthPort.init;
    return Result.success;
}

// The frame is copied before return; checksum insertion requires a zeroed TCP or UDP checksum field.
Result eth_tx(ref EthPort p, const(ubyte)[] frame, bool insert_checksum = false)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (frame.length < 14 || frame.length > eth_max_frame)
            return InternalResult.invalid_parameter;
        return eth_hw_tx(p.mac, p.port, frame, insert_checksum) ? Result.success : InternalResult.failed;
    }
}

// Requires a valid frame; checks hardware layout support, not protocol validity.
bool eth_checksum_insertable(ref const EthPort p, const(ubyte)[] frame)
{
    static if (num_ethernet == 0)
        return false;
    else
        return eth_hw_checksum_insertable(p.mac, p.port, frame);
}

// The factory address of the port; needs no open port.
Result eth_get_hardware_address(ubyte mac, ubyte port, ref ubyte[6] address)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (mac >= num_ethernet || port >= eth_hw_ports(mac))
            return InternalResult.invalid_parameter;
        return eth_hw_get_hardware_address(mac, port, address) ? Result.success : InternalResult.failed;
    }
}

Result eth_set_address(ref EthPort p, ref const ubyte[6] address)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_set_address(p.mac, p.port, address) ? Result.success : InternalResult.failed;
}

Result eth_set_promiscuous(ref EthPort p, bool enable)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_set_promiscuous(p.mac, p.port, enable) ? Result.success : InternalResult.failed;
}

// Valid once a link-up event has been delivered for the port.
Result eth_get_link(ref EthPort p, ref EthLinkInfo info)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_get_link(p.mac, p.port, info) ? Result.success : InternalResult.failed;
}

// Forces the link when autonegotiate is false. The MAC only accepts this while
// stopped, so the link drops and renegotiates around the change.
Result eth_set_link_mode(ref EthPort p, bool autonegotiate, EthSpeed speed, bool full_duplex)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (speed == EthSpeed.s1000m && !has_eth_gigabit)
            return InternalResult.unsupported;
        return eth_hw_set_link_mode(p.mac, p.port, autonegotiate, speed, full_duplex) ? Result.success : InternalResult.failed;
    }
}

// Deliver queued frames and link events of every port on the MAC in caller context; returns true
// when work remains after budget callbacks, false for a MAC with no port open.
bool eth_service(ubyte mac, size_t budget = 32)
{
    static if (num_ethernet == 0)
        return false;
    else
        return mac < num_ethernet && _open_ports[mac] != 0 && eth_hw_service(mac, budget);
}

uint eth_take_rx_drops(ref EthPort p)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_take_rx_drops(p.mac, p.port);
}

// The IEEE 1588 clock of the MAC. It free-runs from zero once timestamping is
// enabled; disciplining it against a grandmaster is the protocol above this.
static if (has_eth_timestamp)
{
    Result eth_get_time(ubyte mac, ref EthTime time)
        => eth_hw_get_time(mac, time) ? Result.success : InternalResult.failed;

    Result eth_set_time(ubyte mac, ref const EthTime time)
        => eth_hw_set_time(mac, time) ? Result.success : InternalResult.failed;

    // ppb is relative to the nominal clock rate.
    Result eth_adjust_frequency(ubyte mac, int ppb)
        => eth_hw_adjust_frequency(mac, ppb) ? Result.success : InternalResult.failed;
}


private:

static if (num_ethernet > 0)
    __gshared uint[num_ethernet] _open_ports;
