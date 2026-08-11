// ESP32 BLE driver -- D wrapper over NimBLE via C shim + direct calls
//
// The C shim (ow_shim.c) handles:
//   - ow_ble_init/deinit: NimBLE host config struct, port init, host task
//
// Everything else (scan, connect, GATT) calls NimBLE C API directly.
//
// BLE controller count per chip (ESP-IDF v6.0):
//   ESP32, S3, C2, C3, C5, C6, H2: 1    S2, P4: 0
module urt.driver.esp32.ble;

import urt.atomic : MemoryOrder, atomicExchange, atomicFetchAdd, atomicLoad, atomicStore;
import urt.driver.ble;
import urt.log : log_error;

import urt.sync.mpsc : MpscQueue;
import urt.uuid : GUID;

nothrow @nogc:


version (ESP32)         enum uint num_ble = 1;
else version (ESP32_S3) enum uint num_ble = 1;
else version (ESP32_C2) enum uint num_ble = 1;
else version (ESP32_C3) enum uint num_ble = 1;
else version (ESP32_C5) enum uint num_ble = 1;
else version (ESP32_C6) enum uint num_ble = 1;
else version (ESP32_H2) enum uint num_ble = 1;
else                    enum uint num_ble = 0; // S2, P4


static if (num_ble > 0):


bool ble_hw_open(uint port, ref const BLEConfig cfg)
{
    if (port >= num_ble)
        return false;
    if (_faulted)
        return false;
    if (_opened)
        return true;

    reset_queues();

    if (ow_ble_init() != 0)
        return false;

    _opened = true;
    return true;
}

void ble_hw_close(uint port)
{
    if (!_opened)
        return;

    ble_hw_scan_stop(port);
    ble_hw_adv_stop(port, BLEAdv.init);

    foreach (ref s; _sessions)
    {
        if (atomicLoad!(MemoryOrder.acquire)(s.state) != SessionState.inactive)
            ble_gap_terminate(s.nimble_handle, 0x13); // Remote User Terminated
    }

    if (ow_ble_deinit() != 0)
    {
        // The host task may still be producing events, so its queues cannot be reset safely.
        _opened = false;
        _faulted = true;
        return;
    }
    reset_queues();

    _opened = false;
    _scan_cb = null;
    _conn_cb = null;
    _discover_cb = null;
    _read_cb = null;
    _write_cb = null;
    _notify_cb = null;
    atomicStore!(MemoryOrder.release)(_pending_connect, cast(ubyte)0);
    atomicStore!(MemoryOrder.release)(_scan_requested, cast(ubyte)0);
    atomicStore!(MemoryOrder.release)(_scan_active, cast(ubyte)0);
    atomicStore!(MemoryOrder.release)(_scan_restart, cast(ubyte)0);
    atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.idle);
    _num_discovered_svcs = 0;
    _current_svc_idx = 0;
    _discovery_overflow = false;
    foreach (ref session; _sessions)
        atomicStore!(MemoryOrder.release)(session.state, SessionState.inactive);
}

// --- Scanning ---

bool ble_hw_scan_start(uint port, ref const BLEScanConfig cfg)
{
    _scan_config = cfg;
    atomicStore!(MemoryOrder.release)(_scan_requested, cast(ubyte)1);
    return start_scan();
}

void ble_hw_scan_stop(uint port)
{
    atomicStore!(MemoryOrder.release)(_scan_requested, cast(ubyte)0);
    atomicStore!(MemoryOrder.release)(_scan_restart, cast(ubyte)0);
    atomicStore!(MemoryOrder.release)(_scan_active, cast(ubyte)0);
    ble_gap_disc_cancel();
}

private bool start_scan()
{
    ble_gap_disc_params params;
    params.itvl = cast(ushort)(_scan_config.interval_ms * 1000 / 625); // BLE units of 0.625ms
    params.window = cast(ushort)(_scan_config.window_ms * 1000 / 625);
    if (!_scan_config.active)
        params.flags |= 0x02; // passive
    if (_scan_config.filter_duplicates)
        params.flags |= 0x04; // filter_duplicates

    int rc = ble_gap_disc(0, BLE_HS_FOREVER, &params, &gap_event_trampoline, null);
    if (rc != 0)
    {
        // Silence here is indistinguishable from a healthy scan, and the radio simply goes deaf.
        log_error("ble", "could not start scan, NimBLE status=", rc);
        return false;
    }
    atomicStore!(MemoryOrder.release)(_scan_active, cast(ubyte)1);
    return true;
}

private void request_scan_resume()
{
    if (atomicLoad!(MemoryOrder.acquire)(_scan_requested) != 0
        && atomicLoad!(MemoryOrder.acquire)(_scan_active) == 0)
        atomicStore!(MemoryOrder.release)(_scan_restart, cast(ubyte)1);
}

private void resume_scan_if_needed()
{
    if (atomicExchange!(MemoryOrder.acq_rel)(&_scan_restart, cast(ubyte)0) == 0)
        return;
    if (atomicLoad!(MemoryOrder.acquire)(_scan_requested) == 0
        || atomicLoad!(MemoryOrder.acquire)(_scan_active) != 0)
        return;
    if (!start_scan())
        atomicStore!(MemoryOrder.release)(_scan_restart, cast(ubyte)1);
}

private ushort conn_interval_units(ushort ms) pure
{
    return cast(ushort)((cast(uint)ms * 1000 + 1249) / 1250);
}

// --- Advertising ---

BLEAdv ble_hw_adv_start(uint port, ref const BLEAdvConfig cfg)
{
    if (cfg.adv_data.length > 0 && cfg.adv_data.length <= 31)
    {
        if (ble_gap_adv_set_data(cfg.adv_data.ptr, cast(int)cfg.adv_data.length) != 0)
            return BLEAdv.init;
    }

    if (cfg.scan_rsp.length > 0 && cfg.scan_rsp.length <= 31)
    {
        if (ble_gap_adv_rsp_set_data(cfg.scan_rsp.ptr, cast(int)cfg.scan_rsp.length) != 0)
            return BLEAdv.init;
    }

    ble_gap_adv_params params;
    params.conn_mode = cfg.adv_type == BLEAdvType.connectable ? 2 : 0; // BLE_GAP_CONN_MODE_UND : NON
    params.disc_mode = 2; // BLE_GAP_DISC_MODE_GEN
    params.itvl_min = cast(ushort)(cfg.interval_ms * 1000 / 625);
    params.itvl_max = params.itvl_min;

    if (ble_gap_adv_start(0, null, 0, &params, &gap_event_trampoline, null) != 0)
        return BLEAdv.init;
    return BLEAdv(0);
}

void ble_hw_adv_stop(uint port, BLEAdv)
{
    ble_gap_adv_stop();
}

// --- Connection ---

bool ble_hw_connect(uint port, ref const ubyte[6] peer_addr, BLEAddrType addr_type, ref const BLEConnConfig cfg)
{
    if (atomicLoad!(MemoryOrder.acquire)(_pending_connect) != 0)
        return false;

    if (atomicLoad!(MemoryOrder.acquire)(_scan_active) != 0)
    {
        int rc = ble_gap_disc_cancel();
        if (rc != 0 && rc != BLE_HS_EALREADY)
        {
            log_error("ble", "could not stop scan before connecting, NimBLE status=", rc);
            return false;
        }
        atomicStore!(MemoryOrder.release)(_scan_active, cast(ubyte)0);
    }

    ble_addr_t addr;
    addr.type = cast(ubyte)addr_type;
    // NimBLE uses LSB-first byte order
    foreach (i; 0 .. 6)
        addr.val[i] = peer_addr[5 - i];

    ble_gap_conn_params params;
    params.scan_itvl = 0x0010;
    params.scan_window = 0x0010;
    params.itvl_min = conn_interval_units(cfg.interval_min_ms);
    params.itvl_max = conn_interval_units(cfg.interval_max_ms);
    params.latency = cfg.latency;
    params.supervision_timeout = cast(ushort)(cfg.timeout_ms / 10); // units of 10ms
    params.min_ce_len = 0;
    params.max_ce_len = 0;

    atomicStore!(MemoryOrder.release)(_pending_connect, cast(ubyte)1);
    int rc = ble_gap_connect(0, &addr, 30_000, &params, &gap_event_trampoline, null);
    if (rc != 0)
    {
        log_error("ble", "could not submit connection request, NimBLE status=", rc);
        atomicStore!(MemoryOrder.release)(_pending_connect, cast(ubyte)0);
        request_scan_resume();
        return false;
    }
    return true;
}

void ble_hw_connect_cancel(uint port)
{
    // A successful cancel completes through BLE_GAP_EVENT_CONNECT; a rejected cancel has no callback.
    if (ble_gap_conn_cancel() != 0)
        atomicStore!(MemoryOrder.release)(_pending_connect, cast(ubyte)0);
}

bool ble_hw_disconnect(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    if (ble_gap_terminate(s.nimble_handle, 0x13) != 0)
        return false;
    return true;
}

// --- GATT discovery ---

bool ble_hw_gatt_discover(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null || atomicLoad!(MemoryOrder.acquire)(_discover_phase) != DiscoverPhase.idle)
        return false;

    _discovering_conn = conn.id;
    atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.services);
    _num_discovered_svcs = 0;
    _current_svc_idx = 0;
    _discovery_overflow = false;
    s.num_chars = 0;

    if (ble_gattc_disc_all_svcs(s.nimble_handle, &svc_discover_cb, null) != 0)
    {
        atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.idle);
        return false;
    }
    return true;
}

// --- GATT read/write ---

bool ble_hw_gatt_read(uint port, BLEConn conn, ushort handle)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    if (ble_gattc_read(s.nimble_handle, handle, &gatt_read_cb, cast(void*)cast(size_t)conn.id) != 0)
        return false;
    return true;
}

bool ble_hw_gatt_write(uint port, BLEConn conn, ushort handle, const(ubyte)[] data, bool with_response)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    if (with_response)
    {
        if (ble_gattc_write_flat(s.nimble_handle, handle, data.ptr, cast(ushort)data.length, &gatt_write_cb, cast(void*)cast(size_t)conn.id) != 0)
            return false;
    }
    else
    {
        if (ble_gattc_write_no_rsp_flat(s.nimble_handle, handle, data.ptr, cast(ushort)data.length) != 0)
            return false;
    }
    return true;
}

// --- Notifications ---

bool ble_hw_gatt_subscribe(uint port, BLEConn conn, ushort handle, bool enable)
{
    auto s = find_session(conn.id);
    if (s is null)
        return false;

    ushort cccd_handle;
    foreach (ref c; s.chars[0 .. s.num_chars])
        if (c.handle == handle)
        {
            cccd_handle = c.cccd_handle;
            break;
        }
    if (cccd_handle == 0)
        return false;

    ubyte[2] cccd_value;
    if (enable)
        cccd_value[0] = 0x01; // enable notifications

    int rc = ble_gattc_write_flat(s.nimble_handle, cccd_handle, cccd_value.ptr, 2, null, null);
    if (rc != 0)
    {
        log_error("ble", "could not write CCCD ", cccd_handle, " for handle ", handle,
                  ", NimBLE status=", rc);
        return false;
    }
    return true;
}

// --- Queries ---

bool ble_hw_get_mac(uint port, ref ubyte[6] mac)
{
    ubyte addr_type;
    if (ble_hs_id_infer_auto(0, &addr_type) != 0)
        return false;
    if (ble_hs_id_copy_addr(addr_type, mac.ptr, null) != 0)
        return false;
    return true;
}

byte ble_hw_get_rssi(uint port, BLEConn conn)
{
    auto s = find_session(conn.id);
    if (s is null)
        return -128;

    byte rssi;
    if (ble_gap_conn_rssi(s.nimble_handle, &rssi) != 0)
        return -128;
    return rssi;
}

// --- Callbacks ---

void ble_hw_set_scan_callback(uint port, BLEScanCallback cb) { _scan_cb = cb; }
void ble_hw_set_conn_callback(uint port, BLEConnCallback cb) { _conn_cb = cb; }
void ble_hw_set_discover_callback(uint port, BLEDiscoverCallback cb) { _discover_cb = cb; }
void ble_hw_set_read_callback(uint port, BLEReadCallback cb) { _read_cb = cb; }
void ble_hw_set_write_callback(uint port, BLEWriteCallback cb) { _write_cb = cb; }
void ble_hw_set_notify_callback(uint port, BLENotifyCallback cb) { _notify_cb = cb; }
void ble_hw_set_ready_callback(BLEReadyCallback cb)
{
    atomicStore!(MemoryOrder.seq)(_ready_callback_bits, cast(size_t)cb);
}

bool ble_hw_service(uint port, size_t budget)
{
    if (port >= num_ble)
        return false;
    resume_scan_if_needed();
    if (_servicing)
        return queues_pending();

    _servicing = true;
    uint generation = atomicLoad!(MemoryOrder.acquire)(_queue_generation);
    auto ble = BLE(cast(ubyte)port);
    size_t serviced;

    while (serviced < budget && generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
    {
        fill_pending_events();
        EventSource source = next_event_source();
        if (source == EventSource.none)
            break;

        final switch (source)
        {
            case EventSource.scan:
                dispatch_scan(ble, _pending_scan);
                if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
                    _have_scan = false;
                break;
            case EventSource.control:
                dispatch_control(ble, _pending_control);
                if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
                    _have_control = false;
                break;
            case EventSource.gatt:
                dispatch_gatt(ble, _pending_gatt);
                if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
                    _have_gatt = false;
                break;
            case EventSource.notification:
                dispatch_notification(ble, _pending_notification);
                if (generation == atomicLoad!(MemoryOrder.acquire)(_queue_generation))
                    _have_notification = false;
                break;
            case EventSource.none:
                assert(false);
        }
        ++serviced;
    }

    _servicing = false;
    return queues_pending();
}

void ble_hw_poll(uint port)
{
    if (ble_hw_service(port, default_service_budget))
        signal_wake();
}

uint ble_hw_take_rx_drops(uint port)
{
    return atomicExchange!(MemoryOrder.acq_rel)(&_rx_drops, 0u);
}

uint ble_hw_take_event_drops(uint port)
{
    return atomicExchange!(MemoryOrder.acq_rel)(&_event_drops, 0u);
}


private:

enum int ESP_OK = 0;
enum int BLE_HS_EALREADY = 2;
enum max_sessions = 4;
enum max_chars_per_session = 32;
enum scan_queue_capacity = 16;
enum control_queue_capacity = 16; // Lifecycle transitions must not be dropped.
enum gatt_queue_capacity = 16;
enum notify_queue_capacity = 16;
enum default_service_budget = 32;

// --- Session table ---

struct SessionCharInfo
{
    ushort handle;
    ushort def_handle;
    ushort svc_end;
    ushort cccd_handle;
    GUID service_uuid;
    GUID char_uuid;
    ushort properties;
}

// active is visible to callers; disconnecting remains visible until its queued event is dispatched;
// unannounced is terminating after its connected event could not be queued.
enum SessionState : ubyte { inactive, active, disconnecting, unannounced }

struct Session
{
    shared SessionState state;
    ubyte id;            // our BLEConn.id
    ushort nimble_handle; // NimBLE connection handle
    SessionCharInfo[max_chars_per_session] chars;
    ubyte num_chars;
}

Session* find_session(ubyte id)
{
    foreach (ref s; _sessions)
    {
        auto state = atomicLoad!(MemoryOrder.acquire)(s.state);
        if ((state == SessionState.active || state == SessionState.disconnecting) && s.id == id)
            return &s;
    }
    return null;
}

Session* find_session_by_nimble(ushort nimble_handle)
{
    foreach (ref s; _sessions)
    {
        if (atomicLoad!(MemoryOrder.acquire)(s.state) != SessionState.inactive && s.nimble_handle == nimble_handle)
            return &s;
    }
    return null;
}

Session* alloc_session(ushort nimble_handle)
{
    Session* session;
    foreach (ref candidate; _sessions)
    {
        if (atomicLoad!(MemoryOrder.acquire)(candidate.state) == SessionState.inactive)
        {
            session = &candidate;
            break;
        }
    }
    if (session is null)
        return null;

    ubyte id = allocate_connection_id();
    if (id == ubyte.max)
        return null;

    session.id = id;
    session.nimble_handle = nimble_handle;
    session.num_chars = 0;
    atomicStore!(MemoryOrder.release)(session.state, SessionState.active);
    return session;
}

ubyte allocate_connection_id()
{
    foreach (_; 0 .. ubyte.max)
    {
        ubyte id = _next_conn_id++;
        bool in_use;
        foreach (ref session; _sessions)
        {
            if (atomicLoad!(MemoryOrder.acquire)(session.state) != SessionState.inactive && session.id == id)
            {
                in_use = true;
                break;
            }
        }
        if (id != ubyte.max && !in_use)
            return id;
    }
    return ubyte.max;
}

bool has_active_sessions()
{
    foreach (ref session; _sessions)
        if (atomicLoad!(MemoryOrder.acquire)(session.state) == SessionState.active)
            return true;
    return false;
}

struct ScanEvent
{
    uint sequence;
    BLEAdvReport report;
}

struct GattCompletionEvent
{
    uint sequence;
    ubyte conn_id;
    ushort handle;
    bool is_read;
    BLEError error;
    ubyte data_len;
    ubyte[247] data;
}

struct NotifyEvent
{
    uint sequence;
    ubyte conn_id;
    ushort handle;
    ubyte data_len;
    ubyte[247] data;
}

enum ControlEventKind : ubyte { connected, connect_failed, disconnected, discover_done, discover_failed }

struct ControlEvent
{
    uint sequence;
    ControlEventKind kind;
    ubyte conn_id;
    BLEError error;
    ubyte hci_status;
}

void dispatch_scan(BLE ble, ref const ScanEvent scan)
{
    if (_scan_cb !is null)
        _scan_cb(ble, scan.report);
}

void dispatch_control(BLE ble, ref const ControlEvent control)
{
    final switch (control.kind)
    {
        case ControlEventKind.connected:
            if (_conn_cb !is null)
                _conn_cb(ble, BLEConn(control.conn_id), true, BLEError.none);
            break;
        case ControlEventKind.connect_failed:
            if (control.hci_status != 0)
                log_error("ble", "connection failed, HCI status=", control.hci_status);
            if (_conn_cb !is null)
                _conn_cb(ble, BLEConn(control.conn_id), false, control.error);
            break;
        case ControlEventKind.disconnected:
            auto session = find_session(control.conn_id);
            if (session !is null)
                atomicStore!(MemoryOrder.release)(session.state, SessionState.inactive);
            if (_conn_cb !is null)
                _conn_cb(ble, BLEConn(control.conn_id), false, BLEError.none);
            break;
        case ControlEventKind.discover_done:
            BLEGattChar[max_chars_per_session] chars = void;
            size_t num_chars;
            BLEError error = BLEError.none;

            if (_discover_cb !is null)
            {
                auto session = find_session(control.conn_id);
                if (session is null)
                    error = BLEError.protocol;
                else
                {
                    num_chars = session.num_chars;
                    foreach (i; 0 .. session.num_chars)
                    {
                        chars[i].handle = session.chars[i].handle;
                        chars[i].cccd_handle = session.chars[i].cccd_handle;
                        chars[i].service_uuid = session.chars[i].service_uuid;
                        chars[i].char_uuid = session.chars[i].char_uuid;
                        chars[i].properties = cast(GattCharProps)session.chars[i].properties;
                    }
                }
            }
            atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.idle);
            if (_discover_cb !is null)
                _discover_cb(ble, BLEConn(control.conn_id), chars[0 .. num_chars], error);
            break;
        case ControlEventKind.discover_failed:
            atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.idle);
            if (_discover_cb !is null)
                _discover_cb(ble, BLEConn(control.conn_id), null, BLEError.protocol);
            break;
    }
}

void dispatch_gatt(BLE ble, ref const GattCompletionEvent gatt)
{
    if (gatt.is_read && _read_cb !is null)
        _read_cb(ble, BLEConn(gatt.conn_id), gatt.handle, gatt.data[0 .. gatt.data_len], gatt.error);
    else if (!gatt.is_read && _write_cb !is null)
        _write_cb(ble, BLEConn(gatt.conn_id), gatt.handle, gatt.error);
}

void dispatch_notification(BLE ble, ref const NotifyEvent notification)
{
    if (find_session(notification.conn_id) is null)
        count_rx_drop();
    else if (_notify_cb !is null)
        _notify_cb(ble, BLEConn(notification.conn_id), notification.handle, notification.data[0 .. notification.data_len]);
}

// --- Module state ---

__gshared bool _opened;
__gshared bool _faulted;
shared ubyte _pending_connect;
shared ubyte _scan_requested;
shared ubyte _scan_active;
shared ubyte _scan_restart;
__gshared ubyte _next_conn_id;
__gshared BLEScanConfig _scan_config;

__gshared Session[max_sessions] _sessions;

__gshared BLEScanCallback _scan_cb;
__gshared BLEConnCallback _conn_cb;
__gshared BLEDiscoverCallback _discover_cb;
__gshared BLEReadCallback _read_cb;
__gshared BLEWriteCallback _write_cb;
__gshared BLENotifyCallback _notify_cb;
shared size_t _ready_callback_bits;
shared uint _rx_drops;
shared uint _event_drops;
shared uint _event_sequence;
shared uint _queue_generation;
__gshared bool _servicing;

static assert(BLEReadyCallback.sizeof == size_t.sizeof);

uint next_event_sequence()
{
    // NimBLE serialises all GAP and GATT callbacks on one host task. Cross-queue ordering relies on
    // that single producer assigning a sequence immediately before enqueueing each event.
    return atomicFetchAdd!(MemoryOrder.relaxed)(_event_sequence, 1u);
}

bool sequence_before(uint lhs, uint rhs)
{
    return cast(int)(lhs - rhs) < 0;
}

void count_rx_drop()
{
    atomicFetchAdd!(MemoryOrder.relaxed)(_rx_drops, 1u);
}

void count_event_drop()
{
    atomicFetchAdd!(MemoryOrder.relaxed)(_event_drops, 1u);
}

void signal_wake()
{
    auto callback = cast(BLEReadyCallback)atomicLoad!(MemoryOrder.seq)(_ready_callback_bits);
    if (callback !is null)
        callback();
}

__gshared MpscQueue!(ScanEvent, scan_queue_capacity) _scan_queue;

// GATT completion ring buffer
__gshared MpscQueue!(GattCompletionEvent, gatt_queue_capacity) _gatt_queue;

// notification ring buffer
__gshared MpscQueue!(NotifyEvent, notify_queue_capacity) _notify_queue;

// control events (connect / disconnect / discovery), set from NimBLE task
__gshared MpscQueue!(ControlEvent, control_queue_capacity) _control_queue;

__gshared ScanEvent _pending_scan;
__gshared ControlEvent _pending_control;
__gshared GattCompletionEvent _pending_gatt;
__gshared NotifyEvent _pending_notification;
__gshared bool _have_scan;
__gshared bool _have_control;
__gshared bool _have_gatt;
__gshared bool _have_notification;

enum EventSource : ubyte { none, scan, control, gatt, notification }

void fill_pending_events()
{
    if (!_have_scan)
        _have_scan = _scan_queue.dequeue(_pending_scan);
    if (!_have_control)
        _have_control = _control_queue.dequeue(_pending_control);
    if (!_have_gatt)
        _have_gatt = _gatt_queue.dequeue(_pending_gatt);
    if (!_have_notification)
        _have_notification = _notify_queue.dequeue(_pending_notification);
}

EventSource next_event_source()
{
    EventSource source;
    uint sequence;

    if (_have_scan)
    {
        source = EventSource.scan;
        sequence = _pending_scan.sequence;
    }
    if (_have_control && (source == EventSource.none || sequence_before(_pending_control.sequence, sequence)))
    {
        source = EventSource.control;
        sequence = _pending_control.sequence;
    }
    if (_have_gatt && (source == EventSource.none || sequence_before(_pending_gatt.sequence, sequence)))
    {
        source = EventSource.gatt;
        sequence = _pending_gatt.sequence;
    }
    if (_have_notification && (source == EventSource.none || sequence_before(_pending_notification.sequence, sequence)))
    {
        source = EventSource.notification;
        sequence = _pending_notification.sequence;
    }

    return source;
}

void reset_queues()
{
    // The producer must be stopped before resetting queue storage.
    atomicFetchAdd!(MemoryOrder.acq_rel)(_queue_generation, 1u);
    _scan_queue.init();
    _control_queue.init();
    _gatt_queue.init();
    _notify_queue.init();
    _have_scan = false;
    _have_control = false;
    _have_gatt = false;
    _have_notification = false;
    atomicStore!(MemoryOrder.relaxed)(_rx_drops, 0u);
    atomicStore!(MemoryOrder.relaxed)(_event_drops, 0u);
    atomicStore!(MemoryOrder.relaxed)(_event_sequence, 0u);
}

bool queues_pending()
{
    return _have_scan || _have_control || _have_gatt || _have_notification || !_scan_queue.empty || !_control_queue.empty || !_gatt_queue.empty || !_notify_queue.empty;
}

bool push_control(ControlEventKind kind, ubyte conn_id, BLEError error = BLEError.none, ubyte hci_status = 0)
{
    ControlEvent event;
    event.sequence = next_event_sequence();
    event.kind = kind;
    event.conn_id = conn_id;
    event.error = error;
    event.hci_status = hci_status;
    if (_control_queue.enqueue(event))
        return true;
    count_event_drop();
    return false;
}

enum DiscoverPhase : ubyte { idle, services, chars, descriptors, complete }
shared DiscoverPhase _discover_phase;
__gshared ubyte _discovering_conn;
__gshared bool _discovery_overflow;

// service discovery iteration state (used from NimBLE task callbacks)
__gshared ble_gatt_svc[16] _discovered_svcs;
__gshared ubyte _num_discovered_svcs;
__gshared ubyte _current_svc_idx;
__gshared ubyte _current_chr_idx;
__gshared GUID _current_svc_uuid;

void finish_discovery(bool success)
{
    atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.complete);
    if (!push_control(success ? ControlEventKind.discover_done : ControlEventKind.discover_failed, _discovering_conn))
        atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.idle);
    _num_discovered_svcs = 0;
    _current_svc_idx = 0;
    _discovery_overflow = false;
    signal_wake();
}


// --- GAP event trampoline (called from NimBLE host task) ---

extern(C) int gap_event_trampoline(ble_gap_event* event, void*) nothrow @nogc
{
    if (event is null)
        return 0;

    switch (event.type)
    {
        case BLE_GAP_EVENT_DISC:
            ScanEvent scan = void;
            scan.sequence = next_event_sequence();
            auto report = &scan.report;
            auto disc = &event.disc;
            if (disc.length_data > report.data_buf.length)
            {
                count_rx_drop();
                signal_wake();
                return 0;
            }

            // NimBLE addr is LSB-first, we want MSB-first
            foreach (i; 0 .. 6)
                report.addr[i] = disc.addr.val[5 - i];
            report.addr_type = cast(BLEAddrType)disc.addr.type;
            report.rssi = disc.rssi;
            report.tx_power = -128; // not in base event

            ubyte len = disc.length_data;
            report.data_len = len;
            if (len > 0)
                report.data_buf[0 .. len] = disc.data[0 .. len];

            report.adv_type = disc.event_type == 0 ? BLEAdvType.connectable : BLEAdvType.nonconnectable;
            if (!_scan_queue.enqueue(scan))
                count_rx_drop();
            signal_wake();
            return 0;

        case BLE_GAP_EVENT_CONNECT:
            atomicStore!(MemoryOrder.release)(_pending_connect, cast(ubyte)0);
            if (event.connect.status == 0)
            {
                auto s = alloc_session(event.connect.conn_handle);
                if (s !is null)
                {
                    if (!push_control(ControlEventKind.connected, s.id))
                    {
                        atomicStore!(MemoryOrder.release)(s.state, SessionState.unannounced);
                        ble_gap_terminate(event.connect.conn_handle, 0x13);
                    }
                }
                else
                {
                    push_control(ControlEventKind.connect_failed, ubyte.max, BLEError.internal);
                    ble_gap_terminate(event.connect.conn_handle, 0x13);
                }
                // Initiating a central connection requires cancelling the scan,
                // but scanning may resume once the connection procedure finishes.
                // The vehicle scanner uses advertisements to retain its session.
                request_scan_resume();
            }
            else
            {
                push_control(ControlEventKind.connect_failed, ubyte.max, BLEError.timeout, cast(ubyte)event.connect.status);
                request_scan_resume();
            }
            signal_wake();
            return 0;

        case BLE_GAP_EVENT_DISC_COMPLETE:
            // The controller stopped discovery on its own. Without clearing the flag the driver
            // believes it is still scanning, resume_scan_if_needed() short-circuits forever, and
            // the radio never hears another advertisement.
            atomicStore!(MemoryOrder.release)(_scan_active, cast(ubyte)0);
            request_scan_resume();
            signal_wake();
            return 0;

        case BLE_GAP_EVENT_DISCONNECT:
            // NimBLE completes active GATT procedures before issuing the GAP disconnect event.
            auto s = find_session_by_nimble(event.disconnect.conn.conn_handle);
            if (s !is null)
            {
                if (atomicLoad!(MemoryOrder.acquire)(s.state) == SessionState.unannounced)
                    atomicStore!(MemoryOrder.release)(s.state, SessionState.inactive);
                else if (push_control(ControlEventKind.disconnected, s.id))
                    atomicStore!(MemoryOrder.release)(s.state, SessionState.disconnecting);
                else
                    atomicStore!(MemoryOrder.release)(s.state, SessionState.inactive);
                if (!has_active_sessions())
                    request_scan_resume();
            }
            signal_wake();
            return 0;

        case BLE_GAP_EVENT_NOTIFY_RX:
            auto s = find_session_by_nimble(event.notify_rx.conn_handle);
            if (s !is null && atomicLoad!(MemoryOrder.acquire)(s.state) == SessionState.active)
            {
                NotifyEvent evt = void;
                evt.sequence = next_event_sequence();
                evt.conn_id = s.id;
                evt.handle = event.notify_rx.attr_handle;
                auto om = event.notify_rx.om;
                // copy mbuf chain to flat buffer
                evt.data_len = 0;
                while (om !is null)
                {
                    if (evt.data_len + om.om_len > evt.data.length)
                        break;
                    ushort copy = om.om_len;
                    evt.data[evt.data_len .. evt.data_len + copy] = om.om_data[0 .. copy];
                    evt.data_len += copy;
                    om = om.om_next;
                }
                if (om !is null || !_notify_queue.enqueue(evt))
                    count_rx_drop();
            }
            else
                count_rx_drop();
            signal_wake();
            return 0;

        default:
            return 0;
    }
}

// --- GATT service discovery callback (NimBLE task) ---

extern(C) int svc_discover_cb(ushort conn_handle, const(ble_gatt_error)* error, const(ble_gatt_svc)* service, void*) nothrow @nogc
{
    if (error !is null && error.status == 0 && service !is null)
    {
        if (_num_discovered_svcs < _discovered_svcs.length)
            _discovered_svcs[_num_discovered_svcs++] = *service;
        else
            _discovery_overflow = true;
        return 0;
    }

    // EDONE is the only successful terminal callback; truncation would expose an invalid cache.
    if (error is null || error.status != BLE_HS_EDONE || _discovery_overflow)
    {
        finish_discovery(false);
        return 0;
    }

    if (_num_discovered_svcs == 0)
    {
        finish_discovery(true);
        return 0;
    }

    _current_svc_idx = 0;
    return discover_next_svc_chars(conn_handle);
}

int discover_next_svc_chars(ushort conn_handle) nothrow @nogc
{
    while (_current_svc_idx < _num_discovered_svcs)
    {
        auto svc = &_discovered_svcs[_current_svc_idx];
        _current_svc_uuid = nimble_uuid_to_guid(&svc.uuid);
        atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.chars);

        if (ble_gattc_disc_all_chrs(conn_handle, svc.start_handle, svc.end_handle, &chr_discover_cb, null) == 0)
            return 0;

        finish_discovery(false);
        return 0;
    }

    _current_chr_idx = 0;
    return discover_next_chr_descriptors(conn_handle);
}

// --- GATT characteristic discovery callback (NimBLE task) ---

extern(C) int chr_discover_cb(ushort conn_handle, const(ble_gatt_error)* error, const(ble_gatt_chr)* chr, void*) nothrow @nogc
{
    if (error !is null && error.status == 0 && chr !is null)
    {
        auto s = find_session_by_nimble(conn_handle);
        if (s !is null && s.num_chars < max_chars_per_session)
        {
            auto ci = &s.chars[s.num_chars++];
            ci.handle = chr.val_handle;
            ci.def_handle = chr.def_handle;
            ci.svc_end = _discovered_svcs[_current_svc_idx].end_handle;
            ci.service_uuid = _current_svc_uuid;
            ci.char_uuid = nimble_uuid_to_guid(&chr.uuid);
            ci.properties = chr.properties;
        }
        else
            _discovery_overflow = true;
        return 0;
    }

    // EDONE is the only successful terminal callback; truncation would expose an invalid cache.
    if (error is null || error.status != BLE_HS_EDONE || _discovery_overflow)
    {
        finish_discovery(false);
        return 0;
    }

    _current_svc_idx++;
    return discover_next_svc_chars(conn_handle);
}

// NimBLE reports every descriptor against the start_handle passed to ble_gattc_disc_all_dscs,
// so discovery must be issued per characteristic value handle; a service-wide range attributes
// all CCCDs to the service start handle and none ever match.
int discover_next_chr_descriptors(ushort conn_handle) nothrow @nogc
{
    auto s = find_session_by_nimble(conn_handle);
    if (s is null)
    {
        finish_discovery(false);
        return 0;
    }

    while (_current_chr_idx < s.num_chars)
    {
        auto c = &s.chars[_current_chr_idx];
        ushort end = c.svc_end;
        if (_current_chr_idx + 1 < s.num_chars && s.chars[_current_chr_idx + 1].svc_end == c.svc_end)
            end = cast(ushort)(s.chars[_current_chr_idx + 1].def_handle - 1);
        if (end <= c.handle)
        {
            ++_current_chr_idx;
            continue;
        }
        atomicStore!(MemoryOrder.release)(_discover_phase, DiscoverPhase.descriptors);

        if (ble_gattc_disc_all_dscs(conn_handle, c.handle, end, &dsc_discover_cb, null) == 0)
            return 0;

        finish_discovery(false);
        return 0;
    }

    finish_discovery(true);
    return 0;
}

extern(C) int dsc_discover_cb(ushort conn_handle, const(ble_gatt_error)* error,
                               ushort chr_val_handle, const(ble_gatt_dsc)* dsc, void*) nothrow @nogc
{
    if (error !is null && error.status == 0 && dsc !is null)
    {
        if (dsc.uuid.u.type == 16 && dsc.uuid.u16.value == 0x2902)
        {
            auto s = find_session_by_nimble(conn_handle);
            if (s !is null)
                foreach (ref c; s.chars[0 .. s.num_chars])
                    if (c.handle == chr_val_handle)
                    {
                        c.cccd_handle = dsc.handle;
                        break;
                    }
        }
        return 0;
    }

    if (error is null || error.status != BLE_HS_EDONE)
    {
        finish_discovery(false);
        return 0;
    }

    ++_current_chr_idx;
    return discover_next_chr_descriptors(conn_handle);
}

// --- GATT read callback (NimBLE task) ---

extern(C) int gatt_read_cb(ushort conn_handle, const(ble_gatt_error)* error, ble_gatt_attr* attr, void* cb_arg) nothrow @nogc
{
    ubyte conn_id = cast(ubyte)cast(size_t)cb_arg;
    GattCompletionEvent evt = void;
    bool payload_dropped;
    bool received_payload;

    evt.sequence = next_event_sequence();
    evt.conn_id = conn_id;
    evt.is_read = true;

    if (error !is null && error.status == 0 && attr !is null)
    {
        evt.handle = attr.handle;
        evt.error = BLEError.none;
        // copy mbuf to flat buffer
        evt.data_len = 0;
        auto om = attr.om;
        while (om !is null)
        {
            if (om.om_len != 0)
                received_payload = true;
            if (evt.data_len + om.om_len > evt.data.length)
            {
                evt.error = BLEError.protocol;
                evt.data_len = 0;
                payload_dropped = true;
                break;
            }
            ushort copy = om.om_len;
            evt.data[evt.data_len .. evt.data_len + copy] = om.om_data[0 .. copy];
            evt.data_len += copy;
            om = om.om_next;
        }
    }
    else
    {
        evt.handle = attr !is null ? attr.handle : 0;
        evt.error = BLEError.protocol;
        evt.data_len = 0;
    }
    if (payload_dropped)
        count_rx_drop();
    if (!_gatt_queue.enqueue(evt))
    {
        if (received_payload && !payload_dropped)
            count_rx_drop();
        count_event_drop();
    }
    signal_wake();
    return 0;
}

// --- GATT write callback (NimBLE task) ---

extern(C) int gatt_write_cb(ushort conn_handle, const(ble_gatt_error)* error, ble_gatt_attr* attr, void* cb_arg) nothrow @nogc
{
    ubyte conn_id = cast(ubyte)cast(size_t)cb_arg;
    GattCompletionEvent evt = void;

    evt.sequence = next_event_sequence();
    evt.conn_id = conn_id;
    evt.handle = attr !is null ? attr.handle : 0;
    evt.is_read = false;
    evt.data_len = 0;
    evt.error = (error !is null && error.status == 0) ? BLEError.none : BLEError.protocol;
    if (!_gatt_queue.enqueue(evt))
        count_event_drop();
    signal_wake();
    return 0;
}

// --- UUID conversion ---

GUID nimble_uuid_to_guid(const(ble_uuid_any)* uuid) nothrow @nogc
{
    GUID g;
    if (uuid.u.type == 16) // BLE_UUID_TYPE_16
    {
        // BT SIG base: 0000xxxx-0000-1000-8000-00805F9B34FB
        g.data1 = uuid.u16.value;
        g.data3 = 0x1000;
        g.data4 = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];
    }
    else if (uuid.u.type == 32) // BLE_UUID_TYPE_32
    {
        g.data1 = uuid.u32.value;
        g.data3 = 0x1000;
        g.data4 = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];
    }
    else if (uuid.u.type == 128) // BLE_UUID_TYPE_128
    {
        // NimBLE stores 128-bit UUIDs in little-endian byte order
        auto v = uuid.u128.value;
        g.data1 = v[12] | (cast(uint)v[13] << 8) | (cast(uint)v[14] << 16) | (cast(uint)v[15] << 24);
        g.data2 = cast(ushort)(v[10] | (cast(ushort)v[11] << 8));
        g.data3 = cast(ushort)(v[8] | (cast(ushort)v[9] << 8));
        foreach (i; 0 .. g.data4.length)
            g.data4[i] = v[7 - i];
    }
    return g;
}


// ====================================================================
// NimBLE C API declarations
// ====================================================================

struct ble_addr_t
{
    ubyte type;
    ubyte[6] val;
}

struct ble_gap_disc_params
{
    ushort itvl;
    ushort window;
    ubyte filter_policy;
    ubyte flags;  // bit 0: limited, bit 1: passive, bit 2: filter_duplicates, bit 3: disable_observer_mode
}

struct ble_gap_conn_params
{
    ushort scan_itvl;
    ushort scan_window;
    ushort itvl_min;
    ushort itvl_max;
    ushort latency;
    ushort supervision_timeout;
    ushort min_ce_len;
    ushort max_ce_len;
}

struct ble_gap_adv_params
{
    ubyte conn_mode;
    ubyte disc_mode;
    ushort itvl_min;
    ushort itvl_max;
    ubyte channel_map;
    ubyte filter_policy;
    ubyte high_duty_cycle;
}

// NimBLE GAP event structure (simplified)
struct ble_gap_event
{
    ubyte type;
    ubyte[3] _pad;

    struct ConnectData { int status; ushort conn_handle; }
    struct DisconnectData { int reason; ble_gap_conn_desc conn; }
    struct DiscData { ubyte event_type; ubyte length_data; ble_addr_t addr; byte rssi; const(ubyte)* data; ble_addr_t direct_addr; }
    struct NotifyRxData { os_mbuf* om; ushort attr_handle; ushort conn_handle; ubyte indication; }

    union
    {
        ConnectData connect;
        DisconnectData disconnect;
        DiscData disc;
        NotifyRxData notify_rx;
    }
}

struct ble_gap_conn_desc
{
    uint sec_state;
    ble_addr_t our_id_addr;
    ble_addr_t peer_id_addr;
    ble_addr_t our_ota_addr;
    ble_addr_t peer_ota_addr;
    ushort conn_handle;
    ushort conn_itvl;
    ushort conn_latency;
    ushort supervision_timeout;
    ubyte role;
    ubyte master_clock_accuracy;
}

struct ble_gatt_error
{
    ushort status;
    ushort att_handle;
}

struct ble_uuid
{
    ubyte type; // 16, 32, or 128
}

struct ble_uuid16
{
    ble_uuid u;
    ushort value;
}

struct ble_uuid32
{
    ble_uuid u;
    uint value;
}

struct ble_uuid128
{
    ble_uuid u;
    ubyte[16] value;
}

union ble_uuid_any
{
    ble_uuid u;
    ble_uuid16 u16;
    ble_uuid32 u32;
    ble_uuid128 u128;
}

struct ble_gatt_svc
{
    ushort start_handle;
    ushort end_handle;
    ble_uuid_any uuid;
}

struct ble_gatt_chr
{
    ushort def_handle;
    ushort val_handle;
    ubyte properties;
    ble_uuid_any uuid;
}

struct ble_gatt_dsc
{
    ushort handle;
    ble_uuid_any uuid;
}

struct ble_gatt_attr
{
    ushort handle;
    ushort offset;
    os_mbuf* om;
}

// NimBLE mbuf
struct os_mbuf
{
    ubyte* om_data;
    ubyte om_flags;
    ubyte om_pkthdr_len;
    ushort om_len;
    void* om_omp;       // os_mbuf_pool* (opaque)
    os_mbuf* om_next;   // SLIST_ENTRY(os_mbuf) - single ptr in practice
}

enum ushort BLE_HS_EDONE = 14;

// GAP event types
enum : ubyte
{
    BLE_GAP_EVENT_CONNECT       = 0,
    BLE_GAP_EVENT_DISCONNECT    = 1,
    BLE_GAP_EVENT_DISC          = 7,
    BLE_GAP_EVENT_DISC_COMPLETE = 8,
    BLE_GAP_EVENT_NOTIFY_RX     = 12,
}

// ble_gap_disc() treats a 0 duration as BLE_GAP_DISC_DUR_DFLT (10.24s), not as "no expiry";
// BLE_HS_FOREVER is what keeps the scan up indefinitely.
enum int BLE_HS_FOREVER = int.max;

// C shim functions
extern(C) nothrow @nogc
{
    int ow_ble_init();
    int ow_ble_deinit();
}

// Direct NimBLE calls
extern(C) nothrow @nogc
{
    int ble_gap_disc(ubyte own_addr_type, int duration_ms, const(ble_gap_disc_params)* params, int function(ble_gap_event*, void*) cb, void* cb_arg);
    int ble_gap_disc_cancel();
    int ble_gap_connect(ubyte own_addr_type, const(ble_addr_t)* peer_addr, int duration_ms, const(ble_gap_conn_params)* params, int function(ble_gap_event*, void*) cb, void* cb_arg);
    int ble_gap_conn_cancel();
    int ble_gap_terminate(ushort conn_handle, ubyte hci_reason);
    int ble_gap_conn_rssi(ushort conn_handle, byte* rssi);

    int ble_gap_adv_set_data(const(ubyte)* data, int data_len);
    int ble_gap_adv_rsp_set_data(const(ubyte)* data, int data_len);
    int ble_gap_adv_start(ubyte own_addr_type, const(ble_addr_t)* direct_addr, int duration_ms, const(ble_gap_adv_params)* params, int function(ble_gap_event*, void*) cb, void* cb_arg);
    int ble_gap_adv_stop();

    int ble_gattc_disc_all_svcs(ushort conn_handle, int function(ushort, const(ble_gatt_error)*, const(ble_gatt_svc)*, void*) cb, void* cb_arg);
    int ble_gattc_disc_all_chrs(ushort conn_handle, ushort start_handle, ushort end_handle, int function(ushort, const(ble_gatt_error)*, const(ble_gatt_chr)*, void*) cb, void* cb_arg);
    int ble_gattc_disc_all_dscs(ushort conn_handle, ushort start_handle, ushort end_handle, int function(ushort, const(ble_gatt_error)*, ushort, const(ble_gatt_dsc)*, void*) cb, void* cb_arg);
    int ble_gattc_read(ushort conn_handle, ushort attr_handle, int function(ushort, const(ble_gatt_error)*, ble_gatt_attr*, void*) cb, void* cb_arg);
    int ble_gattc_write_flat(ushort conn_handle, ushort attr_handle, const(void)* data, ushort data_len, int function(ushort, const(ble_gatt_error)*, ble_gatt_attr*, void*) cb, void* cb_arg);
    int ble_gattc_write_no_rsp_flat(ushort conn_handle, ushort attr_handle, const(void)* data, ushort data_len);

    int ble_hs_id_infer_auto(int privacy, ubyte* out_addr_type);
    int ble_hs_id_copy_addr(ubyte addr_type, ubyte* out_addr, int* out_is_nrpa);
}
