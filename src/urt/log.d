module urt.log;

import urt.mem.temp : tconcat, tformat;
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
    MonoTime timestamp;
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

void log_emergency(T...)(const(char)[] tag, ref T args) { write_log(Severity.emergency, tag, null, args); }
void log_alert(T...)(const(char)[] tag, ref T args) { write_log(Severity.alert, tag, null, args); }
void log_critical(T...)(const(char)[] tag, ref T args) { write_log(Severity.critical, tag, null, args); }
void log_error(T...)(const(char)[] tag, ref T args) { write_log(Severity.error, tag, null, args); }
void log_warning(T...)(const(char)[] tag, ref T args) { write_log(Severity.warning, tag, null, args); }
void log_notice(T...)(const(char)[] tag, ref T args) { write_log(Severity.notice, tag, null, args); }
void log_info(T...)(const(char)[] tag, ref T args) { write_log(Severity.info, tag, null, args); }

void log_emergencyf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.emergency, tag, null, fmt, args); }
void log_alertf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.alert, tag, null, fmt, args); }
void log_criticalf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.critical, tag, null, fmt, args); }
void log_errorf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.error, tag, null, fmt, args); }
void log_warningf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.warning, tag, null, fmt, args); }
void log_noticef(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.notice, tag, null, fmt, args); }
void log_infof(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.info, tag, null, fmt, args); }

void log_debug(T...)(const(char)[] tag, ref T args) { write_log(Severity.debug_, tag, null, args); }
void log_trace(T...)(const(char)[] tag, ref T args) { write_log(Severity.trace, tag, null, args); }
void log_debugf(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.debug_, tag, null, fmt, args); }
void log_tracef(T...)(const(char)[] tag, const(char)[] fmt, ref T args) { write_logf(Severity.trace, tag, null, fmt, args); }

// this can be declared in any scope to automatically prefix log messages with a tag (e.g. module name)
// eg: alias log = Log!"my.module";
//     log.warn("oh no!");
template Log(string tag)
{
    void info(T...)(ref T args) { write_log(Severity.info, tag, null, args); }
    void warning(T...)(ref T args) { write_log(Severity.warning, tag, null, args); }
    void error(T...)(ref T args) { write_log(Severity.error, tag, null, args); }
    void notice(T...)(ref T args) { write_log(Severity.notice, tag, null, args); }
    void critical(T...)(ref T args) { write_log(Severity.critical, tag, null, args); }
    void alert(T...)(ref T args) { write_log(Severity.alert, tag, null, args); }
    void emergency(T...)(ref T args) { write_log(Severity.emergency, tag, null, args); }

    void infof(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.info, tag, null, fmt, args); }
    void warningf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.warning, tag, null, fmt, args); }
    void errorf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.error, tag, null, fmt, args); }
    void noticef(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.notice, tag, null, fmt, args); }
    void criticalf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.critical, tag, null, fmt, args); }
    void alertf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.alert, tag, null, fmt, args); }
    void emergencyf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.emergency, tag, null, fmt, args); }

    void debug_(T...)(ref T args) { write_log(Severity.debug_, tag, null, args); }
    void trace(T...)(ref T args) { write_log(Severity.trace, tag, null, args); }
    void debugf(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.debug_, tag, null, fmt, args); }
    void tracef(T...)(const(char)[] fmt, ref T args) { write_logf(Severity.trace, tag, null, fmt, args); }
}

void write_log(T...)(Severity severity, const(char)[] tag, const(char)[] object_name, ref T args)
{
    if (severity > g_max_severity)
        return;
    import urt.string, urt.array;
    static if (T.length == 1 && (is(T[0] : const(char)[]) || is(T[0] : const String) || is(T[0] : const MutableString!N, size_t N) || is(T[0] : const Array!char)))
        auto msg = LogMessage(severity, tag, object_name, args[0][], getTime());
    else
        auto msg = LogMessage(severity, tag, object_name, tconcat(args), getTime());
    write_log(msg);
}

void write_logf(T...)(Severity severity, const(char)[] tag, const(char)[] object_name, const(char)[] fmt, ref T args)
{
    if (severity > g_max_severity)
        return;
    auto msg = LogMessage(severity, tag, object_name, tformat(fmt, args), getTime());
    write_log(msg);
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

void writeDebug(T...)(ref T things) { writeLog(Level.Debug, things); }
void writeInfo(T...)(ref T things) { writeLog(Level.Info, things); }
void writeWarning(T...)(ref T things) { writeLog(Level.Warning, things); }
void writeError(T...)(ref T things) { writeLog(Level.Error, things); }

void writeDebugf(T...)(const(char)[] format, ref T things) { writeLogf(Level.Debug, format, things); }
void writeInfof(T...)(const(char)[] format, ref T things) { writeLogf(Level.Info, format, things); }
void writeWarningf(T...)(const(char)[] format, ref T things) { writeLogf(Level.Warning, format, things); }
void writeErrorf(T...)(const(char)[] format, ref T things) { writeLogf(Level.Error, format, things); }

void writeLog(T...)(Level level, ref T things)
{
    Severity sev = level_to_severity(level);
    if (sev > g_max_severity)
        return;
    write_log(sev, null, null, things);
}

void writeLogf(T...)(Level level, const(char)[] format, ref T things)
{
    write_logf(level_to_severity(level), null, null, format, things);
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

enum max_sinks = 16;

struct SinkSlot
{
    SinkOutputFn output;
    void* context;
    LogFilter filter;
    bool enabled;
    bool active;
}

__gshared SinkSlot[max_sinks] g_sinks;
__gshared Severity g_max_severity = Severity.info;

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
