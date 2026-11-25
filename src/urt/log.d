module urt.log;

import urt.mem.temp : tconcat_impl, tformat, tformat_packed;
import urt.string.format : ConcatArg, ConcatArgLayout, FormatArg, make_concat_args, pack_format_args;
import urt.time;

nothrow @nogc:


enum Severity : ubyte
{
    emergency  = 0,
    alert      = 1,
    critical   = 2,
    error      = 3,
    warning    = 4,
    notice     = 5,
    info       = 6,
    debug_     = 7,
    trace      = 8,
}

immutable string[9] severity_names = [
    "Emergency", "Alert", "Critical", "Error", "Warning", "Notice", "Info", "Debug", "Trace"
];

struct LogMessage
{
    Severity severity;
    const(char)[] tag;
    const(char)[] object_name;
    const(char)[] message;
    const(char)[] hostname;
    SysTime timestamp;
}

struct LogFilter
{
    Severity max_severity = Severity.info;
    const(char)[] tag_prefix;
}

alias SinkOutputFn = void function(void* context, scope ref const LogMessage msg) nothrow @nogc;

struct LogSinkHandle
{
    int index = -1;
    bool valid() const pure nothrow @nogc
        => index >= 0 && index < max_sinks;
}

LogSinkHandle register_log_sink(SinkOutputFn output, void* context = null, LogFilter filter = LogFilter.init)
{
    foreach (i, ref sink; g_sinks)
    {
        if (!sink.active)
        {
            sink.output = output;
            sink.context = context;
            sink.filter = filter;
            sink.enabled = true;
            sink.active = true;
            recalc_max_severity();
            return LogSinkHandle(cast(int)i);
        }
    }
    return LogSinkHandle(-1);
}

void unregister_log_sink(LogSinkHandle handle)
{
    if (!handle.valid)
        return;
    g_sinks[handle.index] = SinkSlot.init;
    recalc_max_severity();
}

void set_sink_filter(LogSinkHandle handle, LogFilter filter)
{
    if (!handle.valid)
        return;
    g_sinks[handle.index].filter = filter;
    recalc_max_severity();
}

void set_sink_enabled(LogSinkHandle handle, bool enabled)
{
    if (!handle.valid)
        return;
    g_sinks[handle.index].enabled = enabled;
    recalc_max_severity();
}

void set_log_hostname(const(char)[] name)
{
    g_log_hostname = name;
}

pragma(inline, true) void log_emergency(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.emergency, tag, args); }
pragma(inline, true) void log_alert(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.alert, tag, args); }
pragma(inline, true) void log_critical(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.critical, tag, args); }
pragma(inline, true) void log_error(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.error, tag, args); }
pragma(inline, true) void log_warning(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.warning, tag, args); }
pragma(inline, true) void log_notice(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.notice, tag, args); }
pragma(inline, true) void log_info(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.info, tag, args); }

pragma(inline, true) void log_emergencyf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.emergency, tag, fmt, args); }
pragma(inline, true) void log_alertf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.alert, tag, fmt, args); }
pragma(inline, true) void log_criticalf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.critical, tag, fmt, args); }
pragma(inline, true) void log_errorf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.error, tag, fmt, args); }
pragma(inline, true) void log_warningf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.warning, tag, fmt, args); }
pragma(inline, true) void log_noticef(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.notice, tag, fmt, args); }
pragma(inline, true) void log_infof(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.info, tag, fmt, args); }

pragma(inline, true) void log_debug(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.debug_, tag, args); }
pragma(inline, true) void log_trace(T...)(const(char)[] tag, ref T args) { write_log_from!(const(char)[], T)(Severity.trace, tag, args); }
pragma(inline, true) void log_debugf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.debug_, tag, fmt, args); }
pragma(inline, true) void log_tracef(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.trace, tag, fmt, args); }

// this can be declared in any scope to automatically prefix log messages with a tag (e.g. module name)
// eg: alias log = Log!"my.module";
//     log.warn("oh no!");
template Log(alias tag)
{
    pragma(inline, true) void info(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.info, tag[], args); }
    pragma(inline, true) void warning(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.warning, tag[], args); }
    pragma(inline, true) void error(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.error, tag[], args); }
    pragma(inline, true) void notice(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.notice, tag[], args); }
    pragma(inline, true) void critical(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.critical, tag[], args); }
    pragma(inline, true) void alert(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.alert, tag[], args); }
    pragma(inline, true) void emergency(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.emergency, tag[], args); }

    pragma(inline, true) void infof(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.info, tag[], fmt, args); }
    pragma(inline, true) void warningf(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.warning, tag[], fmt, args); }
    pragma(inline, true) void errorf(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.error, tag[], fmt, args); }
    pragma(inline, true) void noticef(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.notice, tag[], fmt, args); }
    pragma(inline, true) void criticalf(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.critical, tag[], fmt, args); }
    pragma(inline, true) void alertf(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.alert, tag[], fmt, args); }
    pragma(inline, true) void emergencyf(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.emergency, tag[], fmt, args); }

    pragma(inline, true) void debug_(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.debug_, tag[], args); }
    pragma(inline, true) void trace(T...)(ref T args) { write_log_from!(const(char)[], T)(Severity.trace, tag[], args); }
    pragma(inline, true) void debugf(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.debug_, tag[], fmt, args); }
    pragma(inline, true) void tracef(T...)(const(char)[] fmt, ref T args) { write_logf_from!(const(char)[], T)(Severity.trace, tag[], fmt, args); }
}

void write_log(T...)(Severity severity, const(char)[] tag, const(char)[] object_name, ref T args)
{
    if (severity > g_max_severity)
        return;
    static if (T.length == 1 && is_log_string!(T[0]))
    {
        const(char)[] message = args[0][];
        write_log_message(severity, tag.ptr, tag.length, object_name.ptr, object_name.length, message.ptr, message.length);
    }
    else
    {
        ConcatArg[T.length] packed = void;
        auto layout = make_concat_args(args, packed.ptr);
        write_concat_log(severity, tag.ptr, tag.length, object_name.ptr, object_name.length,
            packed.ptr, layout);
    }
}

void write_logf(T...)(Severity severity, const(char)[] tag, const(char)[] object_name, const(char)[] fmt, ref T args)
{
    if (severity > g_max_severity)
        return;
    const(char)[] message = tformat(fmt, args);
    write_log_message(severity, tag.ptr, tag.length, object_name.ptr, object_name.length, message.ptr, message.length);
}

// Resolve the tag and retain the name through formatting and sink dispatch.
// A tag slice has no object name. An object supplies its tag via type() and its owning String via name().
void write_log_from(Source, T...)(Severity severity, Source source, ref T args)
{
    if (severity > g_max_severity)
        return;
    static if (T.length == 1 && is_log_string!(T[0]))
        write_source_message(severity, source, args[0][]);
    else
    {
        ConcatArg[T.length] packed = void;
        auto layout = make_concat_args(args, packed.ptr);
        write_source_concat(severity, source, packed.ptr, layout);
    }
}

void write_logf_from(Source, T...)(Severity severity, Source source, const(char)[] fmt, ref T args)
{
    if (severity > g_max_severity)
        return;
    auto packed = pack_format_args(args);
    write_source_format(severity, source, fmt, packed[]);
}

void write_log(scope ref const LogMessage msg)
{
    import urt.string : startsWith;

    foreach (ref sink; g_sinks)
    {
        if (!sink.active || !sink.enabled)
            continue;
        if (msg.severity > sink.filter.max_severity)
            continue;
        if (sink.filter.tag_prefix.length > 0 && !msg.tag.startsWith(sink.filter.tag_prefix))
            continue;
        sink.output(sink.context, msg);
    }
}


// --- backward compatibility (deprecated) ---

enum Level : ubyte
{
    Error = 0,
    Warning,
    Info,
    Debug
}

immutable string[] levelNames = ["Error", "Warning", "Info", "Debug"];

Severity level_to_severity(Level level)
{
    final switch (level)
    {
        case Level.Error:   return Severity.error;
        case Level.Warning: return Severity.warning;
        case Level.Info:    return Severity.info;
        case Level.Debug:   return Severity.debug_;
    }
}

__gshared Level logLevel = Level.Info;

void writeDebug(T...)(ref T things) { write_log_from!(const(char)[], T)(Severity.debug_, null, things); }
void writeInfo(T...)(ref T things) { write_log_from!(const(char)[], T)(Severity.info, null, things); }
void writeWarning(T...)(ref T things) { write_log_from!(const(char)[], T)(Severity.warning, null, things); }
void writeError(T...)(ref T things) { write_log_from!(const(char)[], T)(Severity.error, null, things); }

void writeDebugf(T...)(const(char)[] format, ref T things) { write_logf_from!(const(char)[], T)(Severity.debug_, null, format, things); }
void writeInfof(T...)(const(char)[] format, ref T things) { write_logf_from!(const(char)[], T)(Severity.info, null, format, things); }
void writeWarningf(T...)(const(char)[] format, ref T things) { write_logf_from!(const(char)[], T)(Severity.warning, null, format, things); }
void writeErrorf(T...)(const(char)[] format, ref T things) { write_logf_from!(const(char)[], T)(Severity.error, null, format, things); }

void writeLog(T...)(Level level, ref T things)
{
    write_log_from!(const(char)[], T)(level_to_severity(level), null, things);
}

void writeLogf(T...)(Level level, const(char)[] format, ref T things)
{
    write_logf_from!(const(char)[], T)(level_to_severity(level), null, format, things);
}

alias LegacyLogSink = void function(Level level, scope const(char)[] message) nothrow @nogc;

private void legacy_sink_adapter(void* context, scope ref const LogMessage msg) nothrow @nogc
{
    __gshared immutable Level[9] map = [Level.Error, Level.Error, Level.Error, Level.Error, Level.Warning, Level.Info, Level.Info, Level.Debug, Level.Debug];
    (cast(LegacyLogSink)context)(map[msg.severity], msg.message);
}

LogSinkHandle register_log_sink(LegacyLogSink sink)
    => register_log_sink(&legacy_sink_adapter, cast(void*)sink);


private:

import urt.array : Array;
import urt.string : MutableString, String;

enum is_log_string(T) = is(T : const(char)[]) || is(T : const String) ||
    is(T : const MutableString!N, size_t N) || is(T : const Array!char);

const(char)[] source_tag(Source)(Source source)
{
    static if (is(Source : const(char)[]))
        return source;
    else
        return source.type();
}

auto source_name(Source)(Source source)
{
    static if (is(Source : const(char)[]))
        return cast(const(char)[])null;
    else
        return source.name();
}

pragma(inline, false)
void write_source_message(Source)(Severity severity, Source source, const(char)[] message)
{
    auto tag = source_tag(source);
    auto name = source_name(source);
    write_log_message(severity, tag.ptr, tag.length, name[].ptr, name[].length, message.ptr, message.length);
}

pragma(inline, false)
void write_source_concat(Source)(Severity severity, Source source, const(ConcatArg)* args, ConcatArgLayout layout)
{
    auto tag = source_tag(source);
    auto name = source_name(source);
    write_concat_log(severity, tag.ptr, tag.length, name[].ptr, name[].length, args, layout);
}

pragma(inline, false)
void write_source_format(Source)(Severity severity, Source source, const(char)[] fmt, const(FormatArg)[] args)
{
    auto tag = source_tag(source);
    auto name = source_name(source);
    const(char)[] message = tformat_packed(fmt, args);
    write_log_message(severity, tag.ptr, tag.length, name[].ptr, name[].length, message.ptr, message.length);
}

void write_concat_log(Severity severity, const(char)* tag, size_t tag_length, const(char)* object_name,
    size_t object_name_length, const(ConcatArg)* args, ConcatArgLayout layout)
{
    const(char)[] message = tconcat_impl(args, layout);
    write_log_message(severity, tag, tag_length, object_name, object_name_length, message.ptr, message.length);
}

void write_log_message(Severity severity, const(char)* tag, size_t tag_length, const(char)* object_name,
    size_t object_name_length, const(char)* message, size_t message_length)
{
    auto msg = LogMessage(severity, tag[0 .. tag_length], object_name[0 .. object_name_length],
        message[0 .. message_length], g_log_hostname, get_sys_time());
    write_log(msg);
}

enum max_sinks = 16;

struct SinkSlot
{
    SinkOutputFn output;
    void* context;
    LogFilter filter;
    bool enabled;
    bool active;
}

__gshared SinkSlot[max_sinks] g_sinks = void;
__gshared Severity g_max_severity = Severity.info;

__gshared const(char)[] g_log_hostname;

void recalc_max_severity()
{
    Severity max_sev = Severity.emergency;
    foreach (ref sink; g_sinks)
    {
        if (sink.active && sink.enabled && sink.filter.max_severity > max_sev)
            max_sev = sink.filter.max_severity;
    }
    g_max_severity = max_sev;
}

version (unittest)
{
    struct TestLogCapture
    {
        const(char)[] tag;
        const(char)[] message;
        bool named_object;
    }

    struct TestLogSource
    {
    nothrow @nogc:
        uint lookups;

        const(char)[] type() => "source";

        String name()
        {
            import urt.string : make_string;
            ++lookups;
            return make_string("object");
        }
    }

    void test_log_sink(void* context, scope ref const LogMessage message)
    {
        TestLogCapture* capture = cast(TestLogCapture*)context;
        capture.tag = message.tag;
        capture.message = message.message;
        capture.named_object = message.object_name == "object";
    }
}

unittest
{
    Severity old_max_severity = g_max_severity;
    TestLogCapture capture;
    LogSinkHandle sink = register_log_sink(&test_log_sink, &capture);
    log_info("test", "value=", 10);
    assert(capture.tag == "test");
    assert(capture.message == "value=10");

    alias module_log = Log!"module";
    module_log.info("direct");
    assert(capture.tag == "module" && !capture.named_object && capture.message == "direct");
    log_infof("test", "value={0}", 13);
    assert(capture.tag == "test" && !capture.named_object && capture.message == "value=13");
    writeInfof("value={0}", 14);
    assert(capture.tag.length == 0 && !capture.named_object && capture.message == "value=14");

    TestLogSource source;
    write_log_from(Severity.debug_, &source, "filtered");
    write_logf_from(Severity.debug_, &source, "{0}", 12);
    assert(source.lookups == 0);

    write_log_from(Severity.info, &source, "direct");
    assert(capture.tag == "source");
    assert(capture.named_object);
    assert(capture.message == "direct");
    write_log_from(Severity.info, &source, "value=", 11);
    assert(capture.message == "value=11");
    write_logf_from(Severity.info, &source, "value={0}", 12);
    assert(capture.message == "value=12");
    assert(source.lookups == 3);

    unregister_log_sink(sink);
    g_max_severity = old_max_severity;
}
