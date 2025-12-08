module urt.time;

import urt.traits : is_some_float;

version (Windows)
{
    import core.sys.windows.windows;

    extern (Windows) void GetSystemTimePreciseAsFileTime(FILETIME* lpSystemTimeAsFileTime) nothrow @nogc;
}
else version (Posix)
{
    import core.sys.posix.time;
}

nothrow @nogc:

enum Day : ubyte
{
    Sunday,
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
}

enum Month : ubyte
{
    January = 1,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
}

enum Clock
{
    SystemTime,
    Monotonic,
}

alias MonoTime = Time!(Clock.Monotonic);
alias SysTime = Time!(Clock.SystemTime);

struct Time(Clock clock)
{
pure nothrow @nogc:

    ulong ticks;

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const
        if (is(T == Time!c, Clock c) && c != clock)
    {
        static if (clock == Clock.Monotonic && c == Clock.SystemTime)
            return SysTime(ticks + ticksSinceBoot);
        else
            return MonoTime(ticks - ticksSinceBoot);
    }

    bool opEquals(Time!clock b) const
        => ticks == b.ticks;

    int opCmp(Time!clock b) const
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opBinary(string op, Clock c)(Time!c rhs) const if (op == "-")
    {
        ulong t1 = ticks;
        ulong t2 = rhs.ticks;
        static if (clock != c)
        {
            static if (clock == Clock.Monotonic)
                t1 += ticksSinceBoot;
            else
                t2 += ticksSinceBoot;
        }
        return Duration(t1 - t2);
    }

    Time opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
        => Time(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        static if (clock == Clock.SystemTime)
        {
            DateTime dt = getDateTime(this);
            return dt.toString(buffer, format, formatArgs);
        }
        else
        {
            long ns = (ticks != 0 ? appTime(this) : Duration()).as!"nsecs";
            if (!buffer.ptr)
                return 2 + timeToString(ns, null);
            if (buffer.length < 2)
                return -1;
            buffer[0..2] = "T+";
            ptrdiff_t len = timeToString(ns, buffer[2..$]);
            return len < 0 ? len : 2 + len;
        }
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        static if (clock == Clock.SystemTime)
        {
            DateTime dt;
            ptrdiff_t len = dt.fromString(s);
            if (len >= 0)
                this = getSysTime(dt);
            return len;
        }
        else
        {
            assert(false, "TODO: ???"); // what is the format we parse?
        }
    }

    auto __debugOverview() const
    {
        debug
        {
            import urt.mem.temp;
            char[] b = cast(char[])talloc(64);
            ptrdiff_t len = toString(b, null, null);
            return b[0..len];
        }
        else
            return appTime(this).as!"msecs";
    }
}

struct Duration
{
pure nothrow @nogc:

    long ticks;

    enum zero = Duration(0);
    enum max = Duration(long.max);
    enum min = Duration(long.min);

    bool opCast(T : bool)() const
        => ticks != 0;

    T opCast(T)() const if (is_some_float!T)
        => cast(T)ticks / cast(T)ticksPerSecond;

    bool opEquals(Duration b) const
        => ticks == b.ticks;

    int opCmp(Duration b) const
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opUnary(string op)() const if (op == "-")
        => Duration(-ticks);

    Duration opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
        => Duration(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs)
        if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    long as(string base)() const
    {
        static if (base == "nsecs")
            return ticks*nsecMultiplier;
        else static if (base == "usecs")
            return ticks*nsecMultiplier / 1_000;
        else static if (base == "msecs")
            return ticks*nsecMultiplier / 1_000_000;
        else static if (base == "seconds")
            return ticks*nsecMultiplier / 1_000_000_000;
        else static if (base == "minutes")
            return ticks*nsecMultiplier / 60_000_000_000;
        else static if (base == "hours")
            return ticks*nsecMultiplier / 3_600_000_000_000;
        else static if (base == "days")
            return ticks*nsecMultiplier / 86_400_000_000_000;
        else static if (base == "weeks")
            return ticks*nsecMultiplier / 604_800_000_000_000;
        else
            static assert(false, "Invalid base");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        return timeToString(as!"nsecs", buffer);
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_int;
        import urt.string.ascii : is_alpha, ieq;

        if (s.length == 0)
            return -1;

        size_t offset = 0;
        long total_nsecs = 0;
        ubyte last_unit = 8;

        while (offset < s.length)
        {
            // Parse number
            size_t len;
            long value = s[offset..$].parse_int(&len);
            if (len == 0)
                return last_unit != 8 ? offset : -1;
            offset += len;

            if (offset >= s.length)
                return -1;

            // Parse unit
            size_t unit_start = offset;
            while (offset < s.length && s[offset].is_alpha)
                offset++;

            if (offset == unit_start)
                return -1;

            const(char)[] unit = s[unit_start..offset];

            // Convert unit to nanoseconds and check for duplicates
            ubyte this_unit;
            if (unit.ieq("w"))
            {
                value *= 604_800_000_000_000;
                this_unit = 7;
            }
            else if (unit.ieq("d"))
            {
                value *= 86_400_000_000_000;
                this_unit = 6;
            }
            else if (unit.ieq("h"))
            {
                value *= 3_600_000_000_000;
                this_unit = 5;
            }
            else if (unit.ieq("m"))
            {
                value *= 60_000_000_000;
                this_unit = 4;
            }
            else if (unit.ieq("s"))
            {
                value *= 1_000_000_000;
                this_unit = 3;
            }
            else if (unit.ieq("ms"))
            {
                value *= 1_000_000;
                this_unit = 2;
            }
            else if (unit.ieq("us"))
            {
                value *= 1_000;
                this_unit = 1;
            }
            else if (unit.ieq("ns"))
                this_unit = 0;
            else
                return -1;

            // Check for ordering, duplicates, and only one of ms/us/ns may be present
            if (this_unit >= last_unit || (this_unit < 2 && last_unit < 3))
                return -1;
            last_unit = this_unit;

            total_nsecs += value;
        }

        if (last_unit == 8)
            return -1;

        ticks = total_nsecs / nsecMultiplier;
        return offset;
    }

    auto __debugOverview() const
        => cast(double)this;
}

alias Timer = FixedTimer!();

struct FixedTimer(uint milliseconds = 0)
{
nothrow @nogc:
    MonoTime startTime;

    static if (milliseconds == 0)
    {
        Duration timeout;

        this(Duration timeout)
        {
            setTimeout(timeout);
            reset();
        }

        void setTimeout(Duration timeout) pure
        {
            this.timeout = timeout;
        }
    }

    void reset(MonoTime now = getTime()) pure
    {
        startTime = now;
    }

    bool expired(MonoTime now = getTime()) const pure
    {
        static if (milliseconds != 0)
            return now - startTime >= milliseconds.msecs;
        else
            return now - startTime >= timeout;
    }

    Duration elapsed(MonoTime now = getTime()) const pure
        => now - startTime;

    Duration remaining(MonoTime now = getTime()) const pure
    {
        static if (milliseconds != 0)
            return milliseconds.msecs - (now - startTime);
        else
            return timeout - (now - startTime);
    }

    Duration expiredDuration(MonoTime now = getTime()) const pure
        => -remaining(now);
}

struct DateTime
{
pure nothrow @nogc:

    short year;
    Month month;
    Day wday;
    ubyte day;
    ubyte hour;
    ubyte minute;
    ubyte second;
    uint ns;

    ushort msec() const => ns / 1_000_000;
    uint usec() const => ns / 1_000;

    bool leapYear() const => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0); // && year >= -44; <- this is the year leap years were invented...

    Duration opBinary(string op)(DateTime rhs) const if (op == "-")
    {
        // complicated...
        assert(false);
    }

    DateTime opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
    {
        // complicated...
        assert(false);
    }

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        this = mixin("this " ~ op ~ " rhs;");
    }

    int opCmp(DateTime dt) const
    {
        int r = year - dt.year;
        if (r != 0) return r;
        r = month - dt.month;
        if (r != 0) return r;
        r = day - dt.day;
        if (r != 0) return r;
        r = hour - dt.hour;
        if (r != 0) return r;
        r = minute - dt.minute;
        if (r != 0) return r;
        r = second - dt.second;
        if (r != 0) return r;
        return ns - dt.ns;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        import urt.conv : format_int, format_uint;

        ptrdiff_t len;
        if (!buffer.ptr)
        {
            len = 15; // all the fixed chars
            len += year.format_int(null);
            if (ns)
            {
                ++len; // the dot
                uint nsecs = ns;
                uint m = 0;
                while (nsecs)
                {
                    ++len;
                    uint digit = nsecs / digit_multipliers[m];
                    nsecs -= digit * digit_multipliers[m++];
                }
            }
            return len;
        }

        len = year.format_int(buffer[]);
        if (len < 0 || len + 15 > buffer.length)
            return -1;
        size_t offset = len;
        buffer[offset++] = '-';
        buffer[offset++] = '0' + (month / 10);
        buffer[offset++] = '0' + (month % 10);
        buffer[offset++] = '-';
        buffer[offset++] = '0' + (day / 10);
        buffer[offset++] = '0' + (day % 10);
        buffer[offset++] = 'T';
        buffer[offset++] = '0' + (hour / 10);
        buffer[offset++] = '0' + (hour % 10);
        buffer[offset++] = ':';
        buffer[offset++] = '0' + (minute / 10);
        buffer[offset++] = '0' + (minute % 10);
        buffer[offset++] = ':';
        buffer[offset++] = '0' + (second / 10);
        buffer[offset++] = '0' + (second % 10);
        if (ns)
        {
            if (offset == buffer.length)
                return -1;
            buffer[offset++] = '.';
            uint nsecs = ns;
            uint m = 0;
            while (nsecs)
            {
                if (offset == buffer.length)
                    return -1;
                int digit = nsecs / digit_multipliers[m];
                buffer[offset++] = cast(char)('0' + digit);
                nsecs -= digit * digit_multipliers[m++];
            }
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_int;
        import urt.string.ascii : ieq, is_numeric, is_whitespace, to_lower;

        if (s.length < 14)
            return -1;
        size_t offset = 0;

        // parse year
        if (s[0..2].ieq("bc"))
        {
            offset = 2;
            if (s[2] == ' ')
                ++offset;
        }
        if (s[offset] == '+')
            return -1;
        size_t len;
        long value = s[offset..$].parse_int(&len);
        if (len == 0)
            return -1;
        if (offset > 0)
        {
            if (value <= 0)
                return -1; // no year 0, or negative years BC!
            value = -value + 1;
        }
        if (value < short.min || value > short.max)
            return -1;
        year = cast(short)value;
        offset += len;

        if (s[offset] != '-' && s[offset] != '/')
            return -1;

        // parse month
        value = s[++offset..$].parse_int(&len);
        if (len == 0)
        {
            foreach (i; 0..12)
            {
                if (s[offset..offset+3].ieq(g_month_names[i]))
                {
                    value = i + 1;
                    len = 3;
                    goto got_month;
                }
            }
            return -1;
        got_month:
        }
        else if (value < 1 || value > 12)
            return -1;
        month = cast(Month)value;
        offset += len;

        if (s[offset] != '-' && s[offset] != '/')
            return -1;

        // parse day
        value = s[++offset..$].parse_int(&len);
        if (len == 0 || value < 1 || value > 31)
            return -1;
        day = cast(ubyte)value;
        offset += len;

        if (offset >= s.length || (s[offset] != 'T' && s[offset] != ' '))
            return -1;

        // parse hour
        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 23)
            return -1;
        hour = cast(ubyte)value;
        offset += len;

        if (offset >= s.length || s[offset++] != ':')
            return -1;

        // parse minute
        value = s[offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 59)
            return -1;
        minute = cast(ubyte)value;
        offset += len;

        if (offset >= s.length || s[offset++] != ':')
            return -1;

        // parse second
        value = s[offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 59)
            return -1;
        second = cast(ubyte)value;
        offset += len;

        ns = 0;
        if (offset < s.length && s[offset] == '.')
        {
            // parse fractions
            ++offset;
            uint multiplier = 100_000_000;
            while (offset < s.length && multiplier > 0 && s[offset].is_numeric)
            {
                ns += (s[offset++] - '0') * multiplier;
                multiplier /= 10;
            }
            if (multiplier == 100_000_000)
                return -1; // no number after the dot
        }

        if (offset < s.length && s[offset].to_lower == 'z')
        {
            ++offset;
            // TODO: UTC timezone designator...
            assert(false, "TODO: we need to know our local timezone...");
        }

        return offset;
    }
}

Duration dur(string base)(long value) pure
{
    static if (base == "nsecs")
        return Duration(value / nsecMultiplier);
    else static if (base == "usecs")
        return Duration(value*1_000 / nsecMultiplier);
    else static if (base == "msecs")
        return Duration(value*1_000_000 / nsecMultiplier);
    else static if (base == "seconds")
        return Duration(value*1_000_000_000 / nsecMultiplier);
    else static if (base == "minutes")
        return Duration(value*60_000_000_000 / nsecMultiplier);
    else static if (base == "hours")
        return Duration(value*3_600_000_000_000 / nsecMultiplier);
    else static if (base == "days")
        return Duration(value*86_400_000_000_000 / nsecMultiplier);
    else static if (base == "weeks")
        return Duration(value*604_800_000_000_000 / nsecMultiplier);
    else
        static assert(false, "Invalid base");
}

alias nsecs   = dur!"nsecs";
alias usecs   = dur!"usecs";
alias msecs   = dur!"msecs";
alias seconds = dur!"seconds";

MonoTime getTime()
{
    version (Windows)
    {
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        return MonoTime(now.QuadPart);
    }
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return MonoTime(ts.tv_sec * 1_000_000_000 + ts.tv_nsec);
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime getSysTime()
{
    version (Windows)
    {
        FILETIME ft;
        GetSystemTimePreciseAsFileTime(&ft);
        return SysTime(*cast(ulong*)&ft);
    }
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return SysTime(ts.tv_sec * 1_000_000_000 + ts.tv_nsec);
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime getSysTime(DateTime time) pure
{
    assert(false, "TODO: convert to SysTime...");
}

DateTime getDateTime()
{
    version (Windows)
        return fileTimeToDateTime(getSysTime());
    else version (Posix)
    {
        timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return realtimeToDateTime(ts);
    }
    else
        static assert(false, "TODO");
}

DateTime getDateTime(SysTime time) pure
{
    version (Windows)
        return fileTimeToDateTime(time);
    else version (Posix)
    {
        timespec ts;
        ts.tv_sec = cast(time_t)(time.ticks / 1_000_000_000);
        ts.tv_nsec = cast(uint)(time.ticks % 1_000_000_000);
        return realtimeToDateTime(ts);
    }
    else
        static assert(false, "TODO");
}

Duration getAppTime()
    => getTime() - startTime;

Duration appTime(MonoTime t) pure
    => t - startTime;
Duration appTime(SysTime t) pure
    => cast(MonoTime)t - startTime;

ulong unixTimeNs(SysTime t) pure
{
    version (Windows)
        return (t.ticks - 116444736000000000UL) * 100UL;
    else version (Posix)
        return t.ticks;
    else
        static assert(false, "TODO");
}

SysTime from_unix_time_ns(ulong ns) pure
{
    version (Windows)
        return SysTime(ns / 100UL + 116444736000000000UL);
    else version (Posix)
        return SysTime(ns);
    else
        static assert(false, "TODO");
}

Duration abs(Duration d) pure
    => Duration(d.ticks < 0 ? -d.ticks : d.ticks);


private:

immutable MonoTime startTime;

__gshared immutable string[12] g_month_names = [ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" ];
__gshared immutable uint[9] digit_multipliers = [ 100_000_000, 10_000_000, 1_000_000, 100_000, 10_000, 1_000, 100, 10, 1 ];

version (Windows)
{
    immutable uint ticksPerSecond;
    immutable uint nsecMultiplier;
    immutable ulong ticksSinceBoot;
}
else version (Posix)
{
    enum uint ticksPerSecond = 1_000_000_000;
    enum uint nsecMultiplier = 1;
    immutable ulong ticksSinceBoot;
}

package(urt) void initClock()
{
    cast()startTime = getTime();

    version (Windows)
    {
        import core.sys.windows.windows;
        import urt.util : min;

        LARGE_INTEGER freq;
        QueryPerformanceFrequency(&freq);
        cast()ticksPerSecond = cast(uint)freq.QuadPart;
        cast()nsecMultiplier = 1_000_000_000 / ticksPerSecond;

        // we want the ftime for QPC 0; which should be the boot time
        // we'll repeat this 100 times and take the minimum, and we should be within probably nanoseconds of the correct value
        LARGE_INTEGER qpc;
        ulong ftime, bootTime = ulong.max;
        foreach (i; 0 .. 100)
        {
            QueryPerformanceCounter(&qpc);
            GetSystemTimePreciseAsFileTime(cast(FILETIME*)&ftime);
            bootTime = min(bootTime, ftime - qpc.QuadPart);
        }
        cast()ticksSinceBoot = bootTime;
    }
    else version (Posix)
    {
        import urt.util : min;

        // this doesn't really give time since boot, since MONOTIME is not guaranteed to be zero at system startup...
        timespec mt, rt;
        ulong bootTime = ulong.max;
        foreach (i; 0 .. 100)
        {
            clock_gettime(CLOCK_MONOTONIC, &mt);
            clock_gettime(CLOCK_REALTIME, &rt);
            bootTime = min(bootTime, rt.tv_sec*1_000_000_000 + rt.tv_nsec - mt.tv_sec*1_000_000_000 - mt.tv_nsec);
        }
        cast()ticksSinceBoot = bootTime;
    }
    else
        static assert(false, "TODO");
}

ptrdiff_t timeToString(long ns, char[] buffer) pure
{
    import urt.conv : format_int;

    long hr = ns / 3_600_000_000_000;

    if (!buffer.ptr)
    {
        size_t tail = 6;
        ns %= 1_000_000_000;
        if (ns)
        {
            ++tail;
            uint m = 0;
            do
            {
                ++tail;
                uint digit = cast(uint)(ns / digit_multipliers[m]);
                ns -= digit * digit_multipliers[m++];
            }
            while (ns);
        }
        return hr.format_int(null, 10, 2, '0') + tail;
    }

    ptrdiff_t len = hr.format_int(buffer, 10, 2, '0');
    if (len < 0 || buffer.length < len + 6)
        return -1;

    ubyte min = cast(ubyte)(ns / 60_000_000_000 % 60);
    ubyte sec = cast(ubyte)(ns / 1_000_000_000 % 60);
    ns %= 1_000_000_000;

    buffer.ptr[len++] = ':';
    buffer.ptr[len++] = cast(char)('0' + (min / 10));
    buffer.ptr[len++] = cast(char)('0' + (min % 10));
    buffer.ptr[len++] = ':';
    buffer.ptr[len++] = cast(char)('0' + (sec / 10));
    buffer.ptr[len++] = cast(char)('0' + (sec % 10));
    if (ns)
    {
        if (buffer.length < len + 2)
            return -1;
        buffer.ptr[len++] = '.';
        uint m = 0;
        while (ns)
        {
            if (buffer.length < len + 1)
                return -1;
            uint digit = cast(uint)(ns / digit_multipliers[m]);
            buffer.ptr[len++] = cast(char)('0' + digit);
            ns -= digit * digit_multipliers[m++];
        }
    }
    return len;
}

unittest
{
    import urt.mem.temp;

    assert(tconcat(msecs(3_600_000*3 + 60_000*47 + 1000*34 + 123))[] == "03:47:34.123");
    assert(tconcat(msecs(3_600_000*-123))[] == "-123:00:00");
    assert(MonoTime().toString(null, null, null) == 10);
    assert(tconcat(getTime())[0..2] == "T+");

    // Test Duration.fromString with compound formats
    Duration d;

    // Simple single units
    assert(d.fromString("5s") == 2 && d.as!"seconds" == 5);
    assert(d.fromString("10m") == 3 && d.as!"minutes" == 10);

    // Compound durations
    assert(d.fromString("1h30m") == 5 && d.as!"minutes" == 90);
    assert(d.fromString("5m30s") == 5 && d.as!"seconds" == 330);

    // Duplicate units should fail
    assert(d.fromString("30m30m") == -1);
    assert(d.fromString("1h2h") == -1);
    assert(d.fromString("5s10s") == -1);

    // Out-of-order units should fail
    assert(d.fromString("30s5m") == -1);  // s before m
    assert(d.fromString("1m2h") == -1);   // m before h
    assert(d.fromString("5s10ms5m") == -1);  // m after s
    assert(d.fromString("5s10ms10ns") == -1);  // ms and ns (only one sub-second unit allowed)

    // Improper units should fail
    assert(d.fromString("30z") == -1);  // not a time denomination

    // Correctly ordered units should work
    assert(d.fromString("1d2h30m15s") == 10 && d.as!"seconds" == 86_400 + 7_200 + 1_800 + 15);

    // Test DateTime.fromString
    DateTime dt;
    assert(dt.fromString("2024-06-15T12:34:56") == 19);
    assert(dt.fromString("-100/06/15 12:34:56") == 19);
    assert(dt.fromString("BC100-AUG-15 12:34:56.789") == 25);
    assert(dt.fromString("BC 10000-AUG-15 12:34:56.789123456") == 34);
    assert(dt.fromString("1-1-1 01:01:01") == 14);
    assert(dt.fromString("1-1-1 01:01:01.") == -1);
    assert(dt.fromString("2025-01-01") == -1);
    assert(dt.fromString("2024-0-15 12:34:56") == -1);
    assert(dt.fromString("2024-13-15 12:34:56") == -1);
    assert(dt.fromString("2024-1-0 12:34:56") == -1);
    assert(dt.fromString("2024-1-32 12:34:56") == -1);
    assert(dt.fromString("2024-1-1 24:34:56") == -1);
    assert(dt.fromString("2024-1-1 01:60:56") == -1);
    assert(dt.fromString("2024-1-1 01:01:60") == -1);
    assert(dt.fromString("10000-1-1 1:01:01") == -1);
}


version (Windows)
{
    DateTime fileTimeToDateTime(SysTime ftime) pure
    {
        version (BigEndian)
            static assert(false, "Only works in little endian!");

        SYSTEMTIME stime;
        alias PureHACK = extern(Windows) BOOL function(const(FILETIME)*, LPSYSTEMTIME) pure nothrow @nogc;
        (cast(PureHACK)&FileTimeToSystemTime)(cast(FILETIME*)&ftime.ticks, &stime);

        DateTime dt;
        dt.year = stime.wYear;
        dt.month = cast(Month)stime.wMonth;
        dt.wday = cast(Day)stime.wDayOfWeek;
        dt.day = cast(ubyte)stime.wDay;
        dt.hour = cast(ubyte)stime.wHour;
        dt.minute = cast(ubyte)stime.wMinute;
        dt.second = cast(ubyte)stime.wSecond;
        dt.ns = (ftime.ticks % 10_000_000) * 100;

        debug assert(stime.wMilliseconds == dt.msec);

        return dt;
    }
}
else version (Posix)
{
    DateTime realtimeToDateTime(timespec ts) pure
    {
        tm t;
        alias PureHACK = extern(C) tm* function(time_t* timer, tm* buf) pure nothrow @nogc;
        (cast(PureHACK)&gmtime_r)(&ts.tv_sec, &t);

        DateTime dt;
        dt.year = cast(short)(t.tm_year + 1900);
        dt.month = cast(Month)(t.tm_mon + 1);
        dt.wday = cast(Day)t.tm_wday;
        dt.day = cast(ubyte)t.tm_mday;
        dt.hour = cast(ubyte)t.tm_hour;
        dt.minute = cast(ubyte)t.tm_min;
        dt.second = cast(ubyte)t.tm_sec;
        dt.ns = cast(uint)ts.tv_nsec;

        return dt;
    }
}
