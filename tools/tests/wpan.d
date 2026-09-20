module tests.wpan;

import urt.driver.esp32.wpan;
import urt.driver.wpan : Wpan, WpanConfig, WpanRxInfo, WpanTxError;
import urt.mem.pagepool : Page, page_pool_init, page_pool_deinit, page_release;

nothrow @nogc:

private alias Rx = extern(C) void function(const(ubyte)*, byte, ubyte, ubyte, int) nothrow @nogc;
private alias Tx = extern(C) void function(int, const(ubyte)*, byte, ubyte, ubyte) nothrow @nogc;
private __gshared Rx receive;
private __gshared Tx complete;
private __gshared uint api_calls, rx_calls, tx_calls;
private __gshared bool reopen, retry, synchronous_failure;
private __gshared ubyte[8] address;
private __gshared Page* retained;
private immutable ubyte[6] packet = [5, 1, 2, 3, 0, 0];
private immutable ubyte[6] replacement = [5, 4, 5, 6, 0, 0];

private void on_rx(Wpan w, Page* page, ref const WpanRxInfo info)
{
    auto frame = cast(const(ubyte)[])page.data;
    assert(page.headroom >= 64);
    ++rx_calls;
    assert(frame == packet[1 .. 4] || frame == replacement[1 .. 4]);
    if (reopen)
    {
        reopen = false;
        wpan_hw_close(w.port);
        WpanConfig cfg;
        cfg.rx_headroom = 64;
        assert(wpan_hw_open(w.port, cfg));
        wpan_hw_set_rx_callback(w.port, &on_rx);
        receive(replacement.ptr, -80, 10, 20, 0);
        assert(frame == packet[1 .. 4] && info.rssi == -40 && info.channel == 11);
        assert(wpan_hw_service(w.port, 16)); // recursive service must not consume the new frame
        assert(rx_calls == 1);
        retained = page;
    }
    else
        page_release(page);
}

private void on_tx(Wpan w, WpanTxError error, const(ubyte)[] ack, ref const WpanRxInfo info)
{
    ++tx_calls;
    if (ack.length == 0)
        assert(info == WpanRxInfo.init);
    else
        assert(ack == packet[1 .. 4] && info.rssi == -30 && info.lqi == 90 && info.channel == 15);
    if (retry)
    {
        assert(error == WpanTxError.cca_busy);
        assert(wpan_hw_tx(w.port, packet[1 .. 4], true));
    }
}

unittest
{
    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();
    WpanConfig cfg;
    cfg.rx_headroom = 64;
    assert(wpan_hw_open(0, cfg));
    wpan_hw_set_rx_callback(0, &on_rx);
    wpan_hw_set_tx_callback(0, &on_tx);
    uint calls = api_calls;
    foreach (port; [1u, 255u])
    {
        wpan_hw_close(port);
        assert(!wpan_hw_open(port, cfg));
        assert(!wpan_hw_tx(port, packet[1 .. 4], true));
        assert(!wpan_hw_set_channel(port, 12));
        assert(wpan_hw_get_channel(port) == 0);
        assert(!wpan_hw_set_tx_power(port, 5));
        assert(!wpan_hw_set_promiscuous(port, true));
        assert(!wpan_hw_set_pan_id(port, 1));
        assert(!wpan_hw_set_short_address(port, 2));
        assert(!wpan_hw_set_extended_address(port, address));
        assert(!wpan_hw_get_extended_address(port, address));
        assert(!wpan_hw_get_hardware_address(port, address));
        wpan_hw_set_rx_callback(port, null);
        wpan_hw_set_tx_callback(port, null);
        assert(!wpan_hw_service(port, 16));
        assert(wpan_hw_take_rx_drops(port) == 0);
    }
    assert(api_calls == calls);

    // A synchronous retry must not starve a queued RX, even with budget one.
    synchronous_failure = retry = true;
    receive(packet.ptr, -40, 80, 11, 0);
    assert(wpan_hw_tx(0, packet[1 .. 4], true));
    assert(wpan_hw_service(0, 0) && tx_calls == 0 && rx_calls == 0);
    assert(wpan_hw_service(0, 1) && tx_calls == 1 && rx_calls == 0);
    assert(wpan_hw_service(0, 1) && tx_calls == 1 && rx_calls == 1);
    retry = synchronous_failure = false;
    assert(!wpan_hw_service(0, 1) && tx_calls == 2);

    // No-ACK and invalid-ACK completions must not inherit a previous ACK's metadata.
    foreach (kind; 0 .. 3)
    {
        assert(wpan_hw_tx(0, packet[1 .. 4], true));
        ubyte[1] invalid = [1];
        complete(0, kind == 0 ? packet.ptr : kind == 1 ? null : invalid.ptr, -30, 90, 15);
        assert(!wpan_hw_service(0, 1));
    }

    rx_calls = 0;
    reopen = true;
    wpan_hw_close(0);
    assert(wpan_hw_open(0, cfg));
    wpan_hw_set_rx_callback(0, &on_rx);
    receive(packet.ptr, -40, 80, 11, 0);
    assert(wpan_hw_service(0, 16) && rx_calls == 1);
    assert(!wpan_hw_service(0, 16) && rx_calls == 2);
    wpan_hw_close(0);
    assert(retained !is null && cast(const(ubyte)[])retained.data == packet[1 .. 4]);
    page_release(retained);
    retained = null;
    calls = api_calls;
    wpan_hw_close(0);
    assert(!wpan_hw_tx(0, packet[1 .. 4], true));
    assert(!wpan_hw_set_channel(0, 11));
    assert(!wpan_hw_service(0, 16));
    assert(api_calls == calls);
}

extern(C):

int ow_wpan_enable(Rx rx, Tx tx) { ++api_calls; receive = rx; complete = tx; return 0; }
void ow_wpan_disable() { ++api_calls; receive = null; complete = null; }
int esp_ieee802154_set_channel(ubyte channel) { ++api_calls; return 0; }
ubyte esp_ieee802154_get_channel() { ++api_calls; return 11; }
int esp_ieee802154_set_txpower(byte power) { ++api_calls; return 0; }
int esp_ieee802154_set_promiscuous(bool enable) { ++api_calls; return 0; }
int esp_ieee802154_set_panid(ushort panid) { ++api_calls; return 0; }
int esp_ieee802154_set_short_address(ushort short_address) { ++api_calls; return 0; }
int esp_ieee802154_get_extended_address(ubyte* value) { ++api_calls; value[0 .. 8] = address[]; return 0; }
int esp_ieee802154_set_extended_address(const(ubyte)* value) { ++api_calls; address[] = value[0 .. 8]; return 0; }
int esp_ieee802154_set_rx_when_idle(bool enable) { ++api_calls; return 0; }
int esp_ieee802154_receive() { ++api_calls; return 0; }
int esp_ieee802154_transmit(const(ubyte)* frame, bool cca)
{
    ++api_calls;
    if (synchronous_failure)
        complete(WpanTxError.cca_busy, null, 0, 0, 0);
    return 0;
}
int esp_read_mac(ubyte* mac, int type) { ++api_calls; mac[0 .. 8] = 1; return 0; }
