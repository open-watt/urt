/**
 * Allocation profiling for memory budget tuning on small targets.
 *
 * Enabled with `version = AllocProfile;` (make ALLOC_PROFILE=1). The target emits an event per
 * allocation and keeps only `Counters`; `tools/allocprof.py` replays the stream to reconstruct
 * lifetimes, watermarks and per-call-site attribution.
 *
 * Event format, one line per event, all fields hex:
 *
 *   ap A <ms> <size> <ptr> <pc>...    allocation, with captured call frames
 *   ap F <ms> <size> <ptr>            free
 *   ap R <ms> <size> <ptr> <old_ptr>  realloc, identity moves old -> new
 *   ap M <ms> <label>                 marker
 *   ap B <ms> <addr> <symbol>         runtime address of a known symbol, so the host can undo
 *                                     PIE/ASLR slide
 *
 * Events bypass the log system deliberately: sinks allocate, and the free of a sink's own
 * allocation lands after the reentrancy guard is dropped, emitting an event that logs and
 * allocates again. Writing direct also captures allocations made before any sink exists.
 */
module urt.mem.profile.log;

version (AllocProfile):

import urt.io : write_err;
import urt.mem.profile.common : Sink, time_ms;

nothrow @nogc:


// It takes about six frames to climb out of the allocator, so anything shallower resolves
// entirely to plumbing and attributes nothing. Costs log bandwidth, not RAM.
enum trace_depth = 10;


struct Counters
{
    ulong live_bytes;
    ulong peak_live_bytes;
    ulong total_bytes;
    uint  total_allocs;
    uint  live_allocs;
    uint  peak_live_allocs;
    uint  max_single_alloc;
    uint  events_dropped;   // emission re-entered the allocator
}


void profile_alloc(void* ptr, size_t size)
{
    if (ptr is null)
        return;

    _counters.live_bytes += size;
    _counters.total_bytes += size;
    ++_counters.total_allocs;
    ++_counters.live_allocs;
    if (_counters.live_bytes > _counters.peak_live_bytes)
        _counters.peak_live_bytes = _counters.live_bytes;
    if (_counters.live_allocs > _counters.peak_live_allocs)
        _counters.peak_live_allocs = _counters.live_allocs;
    if (size > _counters.max_single_alloc)
        _counters.max_single_alloc = cast(uint) size;

    emit_alloc(size, ptr);
}

void profile_free(void* ptr, size_t size)
{
    if (ptr is null)
        return;

    if (size <= _counters.live_bytes)
        _counters.live_bytes -= size;
    else
        _counters.live_bytes = 0;
    if (_counters.live_allocs > 0)
        --_counters.live_allocs;

    emit_event('F', size, ptr, null);
}

void profile_realloc(void* old_ptr, void* new_ptr, size_t new_size, size_t old_size)
{
    if (new_ptr is null)
        return;

    if (old_ptr !is null)
    {
        if (old_size <= _counters.live_bytes)
            _counters.live_bytes -= old_size;
        else
            _counters.live_bytes = 0;
    }
    else
    {
        ++_counters.total_allocs;
        ++_counters.live_allocs;
    }

    _counters.live_bytes += new_size;
    _counters.total_bytes += new_size;
    if (_counters.live_bytes > _counters.peak_live_bytes)
        _counters.peak_live_bytes = _counters.live_bytes;
    if (new_size > _counters.max_single_alloc)
        _counters.max_single_alloc = cast(uint) new_size;

    emit_event('R', new_size, new_ptr, old_ptr is new_ptr ? null : old_ptr);
}

void profile_expand(void* ptr, size_t old_size, size_t new_size)
{
    if (ptr is null)
        return;
    profile_realloc(ptr, ptr, new_size, old_size);
}


void alloc_profile_logging(bool enable)
{
    _logging = enable;
}

bool alloc_profile_logging() => _logging;

Counters alloc_profile_counters()
{
    return _counters;
}

void alloc_profile_mark(const(char)[] label)
{
    if (!_logging || _emitting)
        return;
    _emitting = true;
    if (!_base_emitted)
        emit_base();

    char[64] buf = void;
    size_t len = 0;
    buf[len++] = 'a';
    buf[len++] = 'p';
    buf[len++] = ' ';
    buf[len++] = 'M';
    buf[len++] = ' ';
    len += put_hex(buf[len .. $], cast(size_t) time_ms());
    buf[len++] = ' ';
    // Leave room for the newline emit_line appends.
    size_t room = buf.length - len - 1;
    size_t n = label.length < room ? label.length : room;
    buf[len .. len + n] = label[0 .. n];
    len += n;
    emit_line(buf[], len);

    _emitting = false;
}

// Re-zero the peaks to measure a window; totals are left alone.
void alloc_profile_reset_peaks()
{
    _counters.peak_live_bytes = _counters.live_bytes;
    _counters.peak_live_allocs = _counters.live_allocs;
    _counters.max_single_alloc = 0;
}

void alloc_profile_stats(scope Sink sink)
{
    import urt.mem.temp : tformat;

    Counters c = _counters;

    sink(tformat("Live:  {0} bytes in {1} allocations", c.live_bytes, c.live_allocs));
    sink(tformat("Peak:  {0} bytes in {1} allocations", c.peak_live_bytes, c.peak_live_allocs));
    sink(tformat("Total: {0} bytes in {1} allocations", c.total_bytes, c.total_allocs));
    sink(tformat("Largest single allocation: {0} bytes", c.max_single_alloc));
    sink(tformat("Event stream: {0}", _logging ? "on" : "off"));
    if (c.events_dropped > 0)
        sink(tformat("WARNING: {0} events dropped (emission re-entered the allocator)", c.events_dropped));
    sink("Lifetime classification and call-site attribution come from replaying");
    sink("the event stream on the host: tools/allocprof.py");
}


private:

__gshared Counters _counters;
__gshared bool     _logging = true;
__gshared bool     _emitting;
__gshared bool     _base_emitted;


// Raw runtime addresses match nothing in the ELF once a PIE loader has slid them, so hand the
// host one known symbol to recover the slide from. Zero on targets that execute in place.
void emit_base()
{
    _base_emitted = true;

    char[64] buf = void;
    size_t len = 0;
    buf[len++] = 'a';
    buf[len++] = 'p';
    buf[len++] = ' ';
    buf[len++] = 'B';
    buf[len++] = ' ';
    len += put_hex(buf[len .. $], cast(size_t) time_ms());
    buf[len++] = ' ';
    len += put_hex(buf[len .. $], cast(size_t) &profile_alloc);
    buf[len++] = ' ';
    buf[len .. len + 13] = "profile_alloc";
    len += 13;
    emit_line(buf[], len);
}


// Formats into a stack buffer and writes direct, so emission never allocates. A re-entrant call
// is counted and dropped rather than recursing.

void emit_alloc(size_t size, void* ptr)
{
    if (!_logging || _emitting)
    {
        if (_emitting)
            ++_counters.events_dropped;
        return;
    }
    _emitting = true;
    if (!_base_emitted)
        emit_base();

    void*[trace_depth] pcs = null;
    {
        import urt.internal.exception : capture_trace;
        capture_trace(pcs[]);
    }

    char[32 + 12 * (trace_depth + 1)] buf = void;
    size_t len = format_head(buf[], 'A', size, ptr);
    foreach (pc; pcs)
    {
        if (pc is null)
            break;
        buf[len++] = ' ';
        len += put_hex(buf[len .. $], cast(size_t) pc);
    }
    emit_line(buf[], len);

    _emitting = false;
}

void emit_event(char kind, size_t size, void* ptr, void* other)
{
    if (!_logging || _emitting)
    {
        if (_emitting)
            ++_counters.events_dropped;
        return;
    }
    _emitting = true;
    if (!_base_emitted)
        emit_base();

    char[64] buf = void;
    size_t len = format_head(buf[], kind, size, ptr);
    if (other !is null)
    {
        buf[len++] = ' ';
        len += put_hex(buf[len .. $], cast(size_t) other);
    }
    emit_line(buf[], len);

    _emitting = false;
}

// One write per line, or other stderr traffic can interleave and split a record.
void emit_line(char[] buf, size_t len)
{
    buf[len++] = '\n';
    write_err(buf[0 .. len]);
}

size_t format_head(char[] buf, char kind, size_t size, void* ptr)
{
    size_t len = 0;
    buf[len++] = 'a';
    buf[len++] = 'p';
    buf[len++] = ' ';
    buf[len++] = kind;
    buf[len++] = ' ';
    len += put_hex(buf[len .. $], cast(size_t) time_ms());
    buf[len++] = ' ';
    len += put_hex(buf[len .. $], size);
    buf[len++] = ' ';
    len += put_hex(buf[len .. $], cast(size_t) ptr);
    return len;
}

size_t put_hex(char[] buf, size_t value)
{
    static immutable char[16] digits = "0123456789abcdef";

    if (value == 0)
    {
        buf[0] = '0';
        return 1;
    }

    char[size_t.sizeof * 2] tmp = void;
    size_t n = 0;
    while (value != 0)
    {
        tmp[n++] = digits[value & 0xF];
        value >>= 4;
    }
    foreach (i; 0 .. n)
        buf[i] = tmp[n - 1 - i];
    return n;
}


unittest
{
    // Fails the moment someone reaches for a table.
    static assert(Counters.sizeof <= 64);
    static assert(_counters.sizeof + _logging.sizeof + _emitting.sizeof <= 64);

    // The hooks are live for the whole unittest binary, so use fake pointers and restore state.
    bool saved_logging = _logging;
    _logging = false;               // no log noise, and no sink reentrancy
    scope (exit) _logging = saved_logging;

    Counters base = _counters;
    ubyte[8][3] blocks;

    profile_alloc(&blocks[0], 100);
    assert(_counters.live_bytes == base.live_bytes + 100);
    assert(_counters.live_allocs == base.live_allocs + 1);
    assert(_counters.total_allocs == base.total_allocs + 1);
    assert(_counters.max_single_alloc >= 100);

    profile_free(&blocks[0], 100);
    assert(_counters.live_bytes == base.live_bytes);
    assert(_counters.live_allocs == base.live_allocs);

    ulong peak_after = _counters.peak_live_bytes;
    assert(peak_after >= base.live_bytes + 100);

    profile_alloc(&blocks[1], 200);
    uint allocs_before = _counters.live_allocs;
    profile_realloc(&blocks[1], &blocks[2], 500, 200);
    assert(_counters.live_bytes == base.live_bytes + 500);
    assert(_counters.live_allocs == allocs_before);
    profile_free(&blocks[2], 500);
    assert(_counters.live_bytes == base.live_bytes);

    // An oversized free must not drive the live count below zero.
    profile_free(&blocks[0], ulong.max >> 1);
    assert(_counters.live_bytes == 0);
    _counters.live_bytes = base.live_bytes;

    alloc_profile_reset_peaks();
    assert(_counters.peak_live_bytes == _counters.live_bytes);
    assert(_counters.max_single_alloc == 0);

    char[32] hex = void;
    assert(hex[0 .. put_hex(hex[], 0)] == "0");
    assert(hex[0 .. put_hex(hex[], 1)] == "1");
    assert(hex[0 .. put_hex(hex[], 0xdeadbeef)] == "deadbeef");
    assert(hex[0 .. put_hex(hex[], 0xa0)] == "a0");

    // The exact wire format the host parser keys on, prefix included.
    char[64] line = void;
    size_t n = format_head(line[], 'A', 0x30, cast(void*) 0x1234);
    assert(line[0 .. 5] == "ap A ");
    assert(line[n - 7 .. n] == "30 1234");

    uint lines = 0;
    alloc_profile_stats((const(char)[]) { ++lines; });
    assert(lines >= 6);

    _counters = base;
}
