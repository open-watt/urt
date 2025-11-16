module urt.log;

import urt.mem.temp;

nothrow @nogc:


enum Level : ubyte
{
    Error = 0,
    Warning,
    Info,
    Debug
}

immutable string[] levelNames = [ "Error", "Warning", "Info", "Debug" ];

alias LogSink = void function(Level level, const(char)[] message) nothrow @nogc;

__gshared Level logLevel = Level.Info;

void register_log_sink(LogSink sink) nothrow @nogc
{
    if (g_log_sink_count < g_log_sinks.length)
    {
        g_log_sinks[g_log_sink_count] = sink;
        g_log_sink_count++;
    }
}

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
    if (level > logLevel)
        return;

    const(char)[] message = tconcat(levelNames[level], ": ", things);
    for (size_t i = 0; i < g_log_sink_count; i++)
        g_log_sinks[i](level, message);
}

void writeLogf(T...)(Level level, const(char)[] format, ref T things)
{
    if (level > logLevel)
        return;

    const(char)[] message = tformat("{-2}: {@-1}", things, levelNames[level], format);

    for (size_t i = 0; i < g_log_sink_count; i++)
        g_log_sinks[i](level, message);
}


private:

// HACK: temp until we have a proper registration process...
__gshared LogSink[8] g_log_sinks;
__gshared size_t g_log_sink_count = 0;
