/// BL808 WiFi interface via XRAM IPC to M0
///
/// M0 runs the WiFi/BT stack. D0 sends commands (connect, disconnect)
/// and exchanges Ethernet frames via the XRAM NET ring buffer.
/// TODO: implement using ipc module.
module sys.bl808.wifi;
