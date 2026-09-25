module urt.driver.ethernet;

import urt.result : Result, InternalResult;

version (Espressif)
    public import urt.driver.esp32.ethernet;
else version (MT7621)
    public import urt.driver.mt7621.ethernet;
else
{
    enum uint num_ethernet = 0;
    enum bool has_eth_timestamp = false;
    enum bool has_eth_gigabit = false;
    enum bool has_eth_pin_select = false;
    enum bool has_eth_tx_checksum = false;
}

// A MAC that fronts a switch declares has_eth_switch and carries per-frame front-port metadata.
static if (!__traits(compiles, has_eth_switch))
    enum bool has_eth_switch = false;

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
    ubyte switch_port = ubyte.max; // the front port it arrived on, when the MAC fronts a switch
}

// Delivered by eth_service() for each received frame. Frame starts at the
// destination address, carries no FCS, and is valid only until the callback returns.
alias EthRxCallback = void function(EthMac eth, const(ubyte)[] frame, ref const EthRxInfo info) nothrow @nogc;

// Delivered by eth_service() on each link transition.
alias EthLinkCallback = void function(EthMac eth, EthLinkEvent event) nothrow @nogc;

// Delivered by eth_service() on each link transition of a front port.
alias EthSwitchLinkCallback = void function(EthMac eth, ubyte switch_port, EthLinkEvent event) nothrow @nogc;

// Same contract as WifiReadyCallback: may fire from task or interrupt
// context, must only signal or schedule service, never re-enter the driver.
alias EthReadyCallback = void function() nothrow @nogc;

struct EthMac
{
    ubyte port = ubyte.max;
}

bool is_open(ref const EthMac eth) pure
{
    return eth.port != ubyte.max;
}


void eth_set_ready_callback(EthReadyCallback cb)
{
    static if (num_ethernet > 0)
        eth_hw_set_ready_callback(cb);
}

// The vendor's name for the MAC (e.g. "ge1"); null where the platform does not name its MACs.
const(char)[] eth_name(ubyte port)
{
    static if (__traits(compiles, eth_hw_name(port)))
        return port < num_ethernet ? eth_hw_name(port) : null;
    else
        return null;
}

// Front ports of the switch behind the MAC; 0 for a plain MAC.
uint eth_switch_ports(ubyte port)
{
    static if (has_eth_switch)
        return port < num_ethernet ? eth_hw_switch_ports(port) : 0;
    else
        return 0;
}

// Link events arrive asynchronously after open.
Result eth_open(ref EthMac eth, ubyte port, ref const EthernetConfig cfg)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (port >= num_ethernet)
            return InternalResult.invalid_parameter;
        if (cfg.timestamp && !has_eth_timestamp)
            return InternalResult.unsupported;
        if (cfg.tx_checksum && !has_eth_tx_checksum)
            return InternalResult.unsupported;
        if (cfg.phy_interface == EthPhyInterface.rgmii && !has_eth_gigabit)
            return InternalResult.unsupported;
        if (!eth_hw_open(port, cfg))
            return InternalResult.failed;
        eth.port = port;
        return Result.success;
    }
}

// On failure the handle stays open and the close is to be retried; nothing was released.
Result eth_close(ref EthMac eth)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (!eth_hw_close(eth.port))
            return InternalResult.failed;
    }
    eth.port = ubyte.max;
    return Result.success;
}

// The frame is copied before return; checksum insertion requires a zeroed TCP or UDP checksum field.
Result eth_tx(ref EthMac eth, const(ubyte)[] frame, bool insert_checksum = false)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (frame.length < 14 || frame.length > eth_max_frame)
            return InternalResult.invalid_parameter;
        return eth_hw_tx(eth.port, frame, insert_checksum) ? Result.success : InternalResult.failed;
    }
}

// Sends out one front port of the switch behind the MAC; the frame is copied before return.
Result eth_tx_switch(ref EthMac eth, const(ubyte)[] frame, ubyte switch_port)
{
    static if (has_eth_switch)
    {
        if (frame.length < 14 || frame.length > eth_max_frame || switch_port >= eth_hw_switch_ports(eth.port))
            return InternalResult.invalid_parameter;
        return eth_hw_tx_switch(eth.port, frame, switch_port) ? Result.success : InternalResult.failed;
    }
    else
        assert(false, "no switch behind this MAC");
}

// An enabled front port exchanges frames with the CPU only; a disabled one is off.
Result eth_switch_port_enable(ref EthMac eth, ubyte switch_port, bool enable)
{
    static if (has_eth_switch)
    {
        if (switch_port >= eth_hw_switch_ports(eth.port))
            return InternalResult.invalid_parameter;
        return eth_hw_switch_port_enable(eth.port, switch_port, enable) ? Result.success : InternalResult.failed;
    }
    else
        assert(false, "no switch behind this MAC");
}

// Valid once a link-up event has been delivered for the port.
Result eth_get_switch_link(ref EthMac eth, ubyte switch_port, ref EthLinkInfo info)
{
    static if (has_eth_switch)
        return eth_hw_get_switch_link(eth.port, switch_port, info) ? Result.success : InternalResult.failed;
    else
        assert(false, "no switch behind this MAC");
}

void eth_set_switch_link_callback(ref EthMac eth, EthSwitchLinkCallback cb)
{
    static if (has_eth_switch)
        eth_hw_set_switch_link_callback(eth.port, cb);
    else
        assert(false, "no switch behind this MAC");
}

// Requires a valid frame; checks hardware layout support, not protocol validity.
bool eth_checksum_insertable(ref const EthMac eth, const(ubyte)[] frame)
{
    static if (num_ethernet == 0)
        return false;
    else
        return eth_hw_checksum_insertable(eth.port, frame);
}

// The factory address; needs no open MAC.
Result eth_get_hardware_address(ubyte port, ref ubyte[6] address)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (port >= num_ethernet)
            return InternalResult.invalid_parameter;
        return eth_hw_get_hardware_address(port, address) ? Result.success : InternalResult.failed;
    }
}

Result eth_set_address(ref EthMac eth, ref const ubyte[6] address)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_set_address(eth.port, address) ? Result.success : InternalResult.failed;
}

Result eth_set_promiscuous(ref EthMac eth, bool enable)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_set_promiscuous(eth.port, enable) ? Result.success : InternalResult.failed;
}

// Valid once a link-up event has been delivered.
Result eth_get_link(ref EthMac eth, ref EthLinkInfo info)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_get_link(eth.port, info) ? Result.success : InternalResult.failed;
}

// Forces the link when autonegotiate is false. The MAC only accepts this while
// stopped, so the link drops and renegotiates around the change.
Result eth_set_link_mode(ref EthMac eth, bool autonegotiate, EthSpeed speed, bool full_duplex)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
    {
        if (speed == EthSpeed.s1000m && !has_eth_gigabit)
            return InternalResult.unsupported;
        return eth_hw_set_link_mode(eth.port, autonegotiate, speed, full_duplex) ? Result.success : InternalResult.failed;
    }
}

void eth_set_rx_callback(ref EthMac eth, EthRxCallback cb)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        eth_hw_set_rx_callback(eth.port, cb);
}

void eth_set_link_callback(ref EthMac eth, EthLinkCallback cb)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        eth_hw_set_link_callback(eth.port, cb);
}

// Deliver queued frames and link events in caller context; returns true when
// work remains after budget callbacks.
bool eth_service(ref EthMac eth, size_t budget = 32)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_service(eth.port, budget);
}

uint eth_take_rx_drops(ref EthMac eth)
{
    static if (num_ethernet == 0)
        assert(false, "no ethernet MAC on this platform");
    else
        return eth_hw_take_rx_drops(eth.port);
}

// The IEEE 1588 clock of the MAC. It free-runs from zero once timestamping is
// enabled; disciplining it against a grandmaster is the protocol above this.
static if (has_eth_timestamp)
{
    Result eth_get_time(ref EthMac eth, ref EthTime time)
        => eth_hw_get_time(eth.port, time) ? Result.success : InternalResult.failed;

    Result eth_set_time(ref EthMac eth, ref const EthTime time)
        => eth_hw_set_time(eth.port, time) ? Result.success : InternalResult.failed;

    // ppb is relative to the nominal clock rate.
    Result eth_adjust_frequency(ref EthMac eth, int ppb)
        => eth_hw_adjust_frequency(eth.port, ppb) ? Result.success : InternalResult.failed;
}
