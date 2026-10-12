module urt.time;

import urt.array : Array;
import urt.traits : is_signed_integral, is_some_float;

version (Windows)
{
    import urt.internal.sys.windows;

    extern(Windows) void GetSystemTimePreciseAsFileTime(FILETIME* lpSystemTimeAsFileTime) nothrow @nogc;
}
else version (Posix)
{
    import urt.internal.sys.posix;
}
else version (Embedded)
{
    import urt.driver.timer;
}

nothrow @nogc:


// TODO: DELETEME! legacy camelCase aliases; migrate callers to snake_case
alias getTime = get_time;
alias getSysTime = get_sys_time;
alias getDateTime = get_date_time;
alias getAppTime = get_app_time;
alias unixTimeNs = unix_time_ns;


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
    Unspecified = 0,
    January,
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
    LocalTime,
}

alias MonoTime = Time!(Clock.Monotonic);
alias SysTime = Time!(Clock.SystemTime);
alias LocalTime = Time!(Clock.LocalTime);

struct Time(Clock clock)
{
nothrow @nogc:

    static if (clock == Clock.SystemTime)
    {
        enum type_name = "dt";

        // ticks are platform-epoch (FILETIME on Windows); canonical wire image is LE u64 unix-ns
        ptrdiff_t serialise(void[] buffer) const
        {
            import urt.endian : storeLittleEndian;
            if (buffer.length < 8)
                return -1;
            storeLittleEndian(cast(ulong*)buffer.ptr, unix_time_ns(this));
            return 8;
        }
        ptrdiff_t deserialise(const(void)[] buffer)
        {
            import urt.endian : loadLittleEndian;
            if (buffer.length < 8)
                return -1;
            this = from_unix_time_ns(loadLittleEndian(cast(const(ulong)*)buffer.ptr));
            return 8;
        }
    }

    ulong ticks;

    bool opCast(T : bool)() const pure
        => ticks != 0;

    T opCast(T)() const
        if (is(T == Time!c, Clock c) && c != clock)
    {
        static if (is(T == Time!c, Clock c))
            return T(ticks + cast(ulong)(clock_offset!c - clock_offset!clock));
        else
            static assert(false, "constraint out of sync");
    }

    bool opEquals(Time!clock b) const pure
        => ticks == b.ticks;

    int opCmp(Time!clock b) const pure
        => ticks < b.ticks ? -1 : ticks > b.ticks ? 1 : 0;

    Duration opBinary(string op, Clock c)(Time!c rhs) const if (op == "-")
    {
        ulong t1 = ticks - cast(ulong)clock_offset!clock;
        ulong t2 = rhs.ticks - cast(ulong)clock_offset!c;
        return Duration(t1 - t2);
    }

    Time opBinary(string op)(Duration rhs) const pure if (op == "+" || op == "-")
        => Time(mixin("ticks " ~ op ~ " rhs.ticks"));

    void opOpAssign(string op)(Duration rhs) pure if (op == "+" || op == "-")
    {
        mixin("ticks " ~ op ~ "= rhs.ticks;");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        static if (clock == Clock.Monotonic)
        {
            long ns = (ticks != 0 ? app_time(this) : Duration()).as!"nsecs";
            if (!buffer.ptr)
                return 2 + time_to_string(ns, null);
            if (buffer.length < 2)
                return -1;
            buffer[0..2] = "T+";
            ptrdiff_t len = time_to_string(ns, buffer[2..$]);
            return len < 0 ? len : 2 + len;
        }
        else
        {
            static if (clock == Clock.SystemTime)
                size_t suffix = 1;
            else
                size_t suffix = tz_offset_len(g_current_timezone);

            DateTime dt = get_date_time(SysTime(ticks));
            if (!buffer.ptr)
                return dt.toString(null, format, formatArgs) + suffix;
            ptrdiff_t len = dt.toString(buffer, format, formatArgs);
            if (len < 0)
                return len;
            if (buffer.length < len + suffix)
                return -1;
            static if (clock == Clock.SystemTime)
                buffer[len] = 'Z';
            else
                format_tz_offset(g_current_timezone, buffer[len .. len + suffix]);
            return len + suffix;
        }
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        static if (clock == Clock.Monotonic)
        {
            assert(false, "TODO: ???"); // what is the format we parse?
        }
        else static if (clock == Clock.SystemTime)
        {
            DateTime dt;
            ptrdiff_t len = dt.fromString(s);
            if (len >= 0)
                this = get_sys_time(dt);
            return len;
        }
        else
        {
            DateTime dt;
            bool has_tz;
            ptrdiff_t len = dt.from_string(s, has_tz);
            if (len >= 0)
                this = has_tz ? cast(LocalTime)get_sys_time(dt) : get_local_time(dt);
            return len;
        }
    }

    version (Windows)
    auto __debugOverview() const
    {
        import urt.mem;
        char[] b = debug_alloc!char(64);
        ptrdiff_t len = toString(b, null, null);
        return b[0..len];
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
        => cast(T)ticks / cast(T)ticks_per_second;

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
            return ticks_to_nsecs(ticks);
        else static if (base == "usecs")
            return ticks_to_nsecs(ticks) / 1_000;
        else static if (base == "msecs")
            return ticks_to_nsecs(ticks) / 1_000_000;
        else static if (base == "seconds")
            return ticks_to_nsecs(ticks) / 1_000_000_000;
        else static if (base == "minutes")
            return ticks_to_nsecs(ticks) / 60_000_000_000;
        else static if (base == "hours")
            return ticks_to_nsecs(ticks) / 3_600_000_000_000;
        else static if (base == "days")
            return ticks_to_nsecs(ticks) / 86_400_000_000_000;
        else static if (base == "weeks")
            return ticks_to_nsecs(ticks) / 604_800_000_000_000;
        else
            static assert(false, "Invalid base");
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        return duration_to_string(as!"nsecs", buffer, format);
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_uint;
        import urt.string.ascii : is_numeric;

        if (!s.length)
            return -1;

        const(char)* p = s.ptr, end = p + s.length;
        bool negate = *p == '-';
        if (negate || *p == '+')
            ++p;
        immutable ulong limit = cast(ulong)long.max + negate;
        ulong remaining = limit;
        ubyte last_unit = 8;

        while (p < end)
        {
            if (!(*p).is_numeric)
                break;
            size_t digits;
            ulong whole = p[0 .. end - p].parse_uint(&digits);
            if (!digits)
                return -1;
            p += digits;

            uint fraction, divisor = 1;
            if (p < end && *p == '.')
            {
                ++p;
                fraction = cast(uint)p[0 .. end - p].parse_uint(&digits);
                if (digits - 1 >= 9)
                    return -1;
                p += digits;
                divisor = digit_multipliers.ptr[9 - digits];
            }

            if (p == end)
                return -1;
            // 'd' through 'w' map to unit indices; 8 is invalid.
            static immutable ubyte[20] unit_map = [6, 8, 8, 8, 5, 8, 8, 8, 8, 2, 0, 8, 8, 8, 8, 3, 8, 1, 8, 7];
            uint c = (*p++ | 0x20) - 'd';
            if (c >= unit_map.length)
                return -1;
            ubyte this_unit = unit_map.ptr[c];
            if (this_unit == 2 && end - p >= 2 && (p[0] | 0x20) == 'i' && (p[1] | 0x20) == 'n')
            {
                this_unit = 4;
                p += 2;
            }
            else if (this_unit < 3)
            {
                if (p == end || (*p++ | 0x20) != 's')
                    return -1;
            }

            if ((p < end && cast(uint)((*p | 0x20) - 'a') < 26) || this_unit >= last_unit)
                return -1;
            last_unit = this_unit < 3 ? 0 : this_unit;
            uint scale = duration_scales.ptr[this_unit];
            ulong ns_scale = this_unit >= 3 ? cast(ulong)scale * 1_000_000_000 : scale;
            if (whole > remaining / ns_scale)
                return -1;
            remaining -= whole * ns_scale;
            fraction *= 1_000_000_000 / divisor;
            ulong tail = this_unit >= 3 ? cast(ulong)fraction * scale : fraction / (1_000_000_000 / scale);
            if (tail > remaining)
                return -1;
            remaining -= tail;
            if (divisor != 1)
            {
                if (p < end && (*p).is_numeric)
                    return -1;
                break;
            }
        }

        if (last_unit == 8)
            return -1;
        ticks = nsecs_to_ticks(cast(long)(negate ? remaining - limit : limit - remaining));
        return p - s.ptr;
    }

    version (Windows)
    {
        auto __debugOverview() const
            => cast(double)this;
    }
}

Duration random_delay(Duration limit)
{
    import urt.rand : rand;

    if (limit <= Duration.zero)
        return Duration.zero;

    ulong bound = cast(ulong)limit.ticks;
    ulong value;
    ulong threshold = -bound % bound;
    do
        value = cast(ulong)rand() << 32 | rand();
    while (value < threshold);
    return Duration(cast(long)(value % bound + 1));
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

    void reset(MonoTime now = get_time()) pure
    {
        startTime = now;
    }

    bool expired(MonoTime now = get_time()) const pure
    {
        static if (milliseconds != 0)
            return now - startTime >= milliseconds.msecs;
        else
            return now - startTime >= timeout;
    }

    Duration elapsed(MonoTime now = get_time()) const pure
        => now - startTime;

    Duration remaining(MonoTime now = get_time()) const pure
    {
        static if (milliseconds != 0)
            return milliseconds.msecs - (now - startTime);
        else
            return timeout - (now - startTime);
    }

    Duration expiredDuration(MonoTime now = get_time()) const pure
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
                    uint digit = nsecs / digit_multipliers[m + 1];
                    nsecs -= digit * digit_multipliers[1 + m++];
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
                int digit = nsecs / digit_multipliers[m + 1];
                buffer[offset++] = cast(char)('0' + digit);
                nsecs -= digit * digit_multipliers[1 + m++];
            }
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        bool has_tz;
        return from_string(s, has_tz);
    }

    // has_tz reports whether the string carried an explicit timezone (Z or +/-HH:MM)
    // when it does, the parsed wall-clock is normalised to UTC
    ptrdiff_t from_string(const(char)[] s, out bool has_tz)
    {
        import urt.conv : parse_int, parse_uint;
        import urt.string.ascii : ieq, is_numeric, is_whitespace, to_lower;

        month = Month.Unspecified;
        day = 0;
        hour = 0;
        minute = 0;
        second = 0;
        ns = 0;

        size_t offset = 0;

        // parse year
        if (s.length >= 2 && s[0..2].ieq("bc"))
        {
            offset = 2;
            if (s.length >= 3 && s[2] == ' ')
                ++offset;
        }
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

        if (offset == s.length || (s[offset] != '-' && s[offset] != '/'))
            return offset;

        // parse month
        value = s[++offset..$].parse_int(&len);
        if (len == 0)
        {
            if (s.length < 3)
                return -1;
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

        if (offset == s.length || (s[offset] != '-' && s[offset] != '/'))
            return offset;

        // parse day
        value = s[++offset..$].parse_int(&len);
        if (len == 0 || value < 1 || value > 31)
            return -1;
        day = cast(ubyte)value;
        offset += len;

        if (offset == s.length || (s[offset] != 'T' && s[offset] != ' '))
            return offset;

        // parse hour
        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 23)
            return -1;
        hour = cast(ubyte)value;
        offset += len;

        if (offset == s.length)
            return offset;

        if (s[offset] == ':')
        {
            // parse minute
            value = s[++offset..$].parse_int(&len);
            if (len != 2 || value < 0 || value > 59)
                return -1;
            minute = cast(ubyte)value;
            offset += len;

            if (offset == s.length)
                return offset;

            if (s[offset] == ':')
            {
                // parse second
                value = s[++offset..$].parse_int(&len);
                if (len != 2 || value < 0 || value > 59)
                    return -1;
                second = cast(ubyte)value;
                offset += len;

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
                        return offset-1; // no number after the dot
                }
            }
            else if (s[offset] == '.')
            {
                // fraction of minute
                assert(false, "TODO");
            }
        }
        else if (s[offset] == '.')
        {
            // fraction of hour
            assert(false, "TODO");
        }

        if (offset == s.length)
            return offset;

        if (s[offset].to_lower == 'z')
        {
            has_tz = true;
            return offset + 1;
        }

        size_t tz_offset = offset;
        if (s[offset] == ' ')
            ++tz_offset;
        if (s[tz_offset] != '-' && s[tz_offset] != '+')
            return offset;
        bool tz_neg = s[tz_offset] == '-';
        tz_offset += 1;

        // parse timezone (00:00)
        int tz_hr, tz_min;

        value = s[tz_offset..$].parse_uint(&len);
        if (len == 0)
            return offset;

        if (len == 4)
        {
            if (value > 2359)
                return -1;
            tz_min = cast(int)(value % 100);
            if (tz_min > 59)
                return -1;
            tz_hr = cast(int)(value / 100);
            tz_offset += 4;
        }
        else
        {
            if (len != 2 || value > 59)
                return -1;

            tz_hr = cast(int)value;
            tz_offset += 2;

            if (tz_offset < s.length && s[tz_offset] == ':')
            {
                value = s[tz_offset+1..$].parse_uint(&len);
                if (len != 0)
                {
                    if (len != 2 || value > 59)
                        return -1;
                    tz_min = cast(int)value;
                    tz_offset += 3;
                }
            }
        }

        long off_min = cast(long)tz_hr * 60 + tz_min;
        if (tz_neg)
            off_min = -off_min;

        if (off_min != 0)
            this = unix_ns_to_datetime(cast(ulong)(cast(long)datetime_to_unix_ns(this) - off_min * 60_000_000_000L));
        has_tz = true;

        return tz_offset;
    }
}

struct TimeOfDay
{
pure nothrow @nogc:

    enum type_name = "tod";

    ubyte hour;
    ubyte minute;
    ubyte second;
    uint ns;

    ushort msec() const => cast(ushort)(ns / 1_000_000);
    uint usec() const => ns / 1_000;

    Duration opBinary(string op)(TimeOfDay rhs) const if (op == "-")
    {
        long lhs_ns = (cast(long)hour*3600 + cast(long)minute*60 + cast(long)second) * 1_000_000_000 + ns;
        long rhs_ns = (cast(long)rhs.hour*3600 + cast(long)rhs.minute*60 + cast(long)rhs.second) * 1_000_000_000 + rhs.ns;
        return (lhs_ns - rhs_ns).nsecs;
    }

    TimeOfDay opBinary(string op)(Duration rhs) const if (op == "+" || op == "-")
    {
        long tod_ns = (cast(long)hour*3600 + cast(long)minute*60 + cast(long)second) * 1_000_000_000 + ns;
        static if (op == "+")
            tod_ns += rhs.as!"nsecs";
        else
            tod_ns -= rhs.as!"nsecs";
        enum long day_ns = 86_400_000_000_000;
        tod_ns = ((tod_ns % day_ns) + day_ns) % day_ns;
        TimeOfDay r;
        r.ns = cast(uint)(tod_ns % 1_000_000_000);
        long sod = tod_ns / 1_000_000_000;
        r.second = cast(ubyte)(sod % 60);
        r.minute = cast(ubyte)((sod / 60) % 60);
        r.hour = cast(ubyte)(sod / 3600);
        return r;
    }

    void opOpAssign(string op)(Duration rhs) if (op == "+" || op == "-")
    {
        this = mixin("this " ~ op ~ " rhs;");
    }

    int opCmp(TimeOfDay tod) const
    {
        int r = hour - tod.hour;
        if (r != 0) return r;
        r = minute - tod.minute;
        if (r != 0) return r;
        r = second - tod.second;
        if (r != 0) return r;
        return cast(int)ns - cast(int)tod.ns;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[] format, const(FormatArg)[] formatArgs) const
    {
        if (!buffer.ptr)
        {
            ptrdiff_t len = 8;
            if (ns)
            {
                ++len;
                uint nsecs = ns;
                uint m = 0;
                while (nsecs)
                {
                    ++len;
                    uint digit = nsecs / digit_multipliers[m + 1];
                    nsecs -= digit * digit_multipliers[1 + m++];
                }
            }
            return len;
        }

        if (buffer.length < 8)
            return -1;
        size_t offset = 0;
        buffer[offset++] = cast(char)('0' + (hour / 10));
        buffer[offset++] = cast(char)('0' + (hour % 10));
        buffer[offset++] = ':';
        buffer[offset++] = cast(char)('0' + (minute / 10));
        buffer[offset++] = cast(char)('0' + (minute % 10));
        buffer[offset++] = ':';
        buffer[offset++] = cast(char)('0' + (second / 10));
        buffer[offset++] = cast(char)('0' + (second % 10));
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
                int digit = nsecs / digit_multipliers[m + 1];
                buffer[offset++] = cast(char)('0' + digit);
                nsecs -= digit * digit_multipliers[1 + m++];
            }
        }
        return offset;
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        import urt.conv : parse_int;
        import urt.string.ascii : is_numeric;

        hour = 0;
        minute = 0;
        second = 0;
        ns = 0;

        if (s.length == 0)
            return -1;

        size_t offset = 0;
        size_t len;
        long value = s[offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 23)
            return -1;
        hour = cast(ubyte)value;
        offset += len;

        if (offset == s.length || s[offset] != ':')
            return offset;

        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 59)
            return -1;
        minute = cast(ubyte)value;
        offset += len;

        if (offset == s.length || s[offset] != ':')
            return offset;

        value = s[++offset..$].parse_int(&len);
        if (len != 2 || value < 0 || value > 59)
            return -1;
        second = cast(ubyte)value;
        offset += len;

        if (offset < s.length && s[offset] == '.')
        {
            ++offset;
            uint multiplier = 100_000_000;
            while (offset < s.length && multiplier > 0 && s[offset].is_numeric)
            {
                ns += (s[offset++] - '0') * multiplier;
                multiplier /= 10;
            }
            if (multiplier == 100_000_000)
                return offset-1;
        }

        return offset;
    }

    version (Windows)
    auto __debugOverview() const
    {
        import urt.mem;
        char[] b = debug_alloc!char(20);
        ptrdiff_t len = toString(b, null, null);
        return b[0..len];
    }
}

TimeOfDay time_of_day(DateTime dt) pure
{
    TimeOfDay t;
    t.hour = dt.hour;
    t.minute = dt.minute;
    t.second = dt.second;
    t.ns = dt.ns;
    return t;
}

TimeOfDay time_of_day(SysTime t) pure
    => time_of_day(get_date_time(t));

SysTime next_occurrence(SysTime now, TimeOfDay tod, ubyte weekday_mask = 0x7F) pure
{
    if ((weekday_mask & 0x7F) == 0)
        weekday_mask = 0x7F;

    ulong now_ns = unix_time_ns(now);
    enum ulong day_ns = 86_400_000_000_000UL;
    ulong day_start = now_ns - now_ns % day_ns;
    ulong tod_ns = (cast(ulong)tod.hour*3600 + cast(ulong)tod.minute*60 + cast(ulong)tod.second) * 1_000_000_000UL + tod.ns;

    DateTime dt = get_date_time(now);
    ubyte wday = cast(ubyte)dt.wday;

    foreach (_; 0 .. 7)
    {
        if (weekday_mask & (1 << wday))
        {
            ulong candidate = day_start + tod_ns;
            if (candidate > now_ns)
                return from_unix_time_ns(candidate);
        }
        day_start += day_ns;
        wday = cast(ubyte)((wday + 1) % 7);
    }

    return from_unix_time_ns(day_start + tod_ns);
}


Duration dur(string base)(long value) pure
{
    static if (base == "nsecs")
        return Duration(nsecs_to_ticks(value));
    else static if (base == "usecs")
        return Duration(nsecs_to_ticks(value*1_000));
    else static if (base == "msecs")
        return Duration(nsecs_to_ticks(value*1_000_000));
    else static if (base == "seconds")
        return Duration(nsecs_to_ticks(value*1_000_000_000));
    else static if (base == "minutes")
        return Duration(nsecs_to_ticks(value*60_000_000_000));
    else static if (base == "hours")
        return Duration(nsecs_to_ticks(value*3_600_000_000_000));
    else static if (base == "days")
        return Duration(nsecs_to_ticks(value*86_400_000_000_000));
    else static if (base == "weeks")
        return Duration(nsecs_to_ticks(value*604_800_000_000_000));
    else
        static assert(false, "Invalid base");
}

alias nsecs   = dur!"nsecs";
alias usecs   = dur!"usecs";
alias msecs   = dur!"msecs";
alias seconds = dur!"seconds";

MonoTime get_time()
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
        return MonoTime(ts.tv_sec * 1_000_000_000L + ts.tv_nsec);
    }
    else version (Embedded)
    {
        static if (has_mtime)
            return MonoTime(mtime_read());
        else
            static assert(false, "get_time: no monotonic timer for this platform");
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime get_sys_time()
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
        return SysTime(ts.tv_sec * 1_000_000_000L + ts.tv_nsec);
    }
    else version (Embedded)
    {
        static if (has_mtime)
            return SysTime(mtime_read() + sys_time_offset);
        else
            static assert(false, "get_sys_time: no monotonic timer for this platform");
    }
    else
    {
        static assert(false, "TODO");
    }
}

SysTime get_sys_time(DateTime time) pure
{
    return from_unix_time_ns(datetime_to_unix_ns(time));
}

LocalTime get_local_time()
    => cast(LocalTime)get_sys_time();

LocalTime get_local_time(DateTime time) pure
    => LocalTime(get_sys_time(time).ticks);

DateTime get_date_time()
{
    return get_date_time(get_sys_time());
}

DateTime get_date_time(SysTime time) pure
{
    return unix_ns_to_datetime(unix_time_ns(time));
}

DateTime get_date_time(LocalTime time) pure
    => get_date_time(SysTime(time.ticks));

Duration get_app_time()
    => get_time() - startTime;

Duration app_time(MonoTime t) pure
    => t - startTime;
Duration app_time(SysTime t) pure
    => cast(MonoTime)t - startTime;

ulong unix_time_ns(SysTime t) pure
{
    version (Windows)
        return (t.ticks - unix_epoch_as_filetime) * 100UL;
    else version (Posix)
        return t.ticks;
    else version (Embedded)
        return ticks_to_nsecs(t.ticks);
    else
        static assert(false, "TODO");
}

SysTime from_unix_time_ns(ulong ns) pure
{
    version (Windows)
        return SysTime(ns / 100UL + unix_epoch_as_filetime);
    else version (Posix)
        return SysTime(ns);
    else version (Embedded)
        return SysTime(nsecs_to_ticks(ns));
    else
        static assert(false, "TODO");
}

Duration abs(Duration d) pure
    => Duration(d.ticks < 0 ? -d.ticks : d.ticks);

bool wall_time_set()
{
    return has_wall_time;
}

void set_utc_time(ulong unix_ns)
{
    long old_offset = cast(long)sys_time_offset;
    cast()sys_time_offset = nsecs_to_ticks(unix_ns) - get_time().ticks;
    long delta_ns = has_wall_time ? ticks_to_nsecs(cast(long)sys_time_offset - old_offset) : 0;
    has_wall_time = true;

    apply_os_clock(unix_ns);
    notify_clock_change(delta_ns);
}

void adjust_utc_time(long delta_ns)
{
    cast()sys_time_offset = cast(ulong)(cast(long)sys_time_offset + nsecs_to_ticks(delta_ns));
    has_wall_time = true;

    apply_os_clock(unix_time_ns(get_sys_time()));
    notify_clock_change(delta_ns);
}

private void apply_os_clock(ulong unix_ns)
{
    version (Windows)
    {
        import urt.internal.sys.windows;

        ulong ft = unix_ns / 100 + unix_epoch_as_filetime;
        SYSTEMTIME st;
        FileTimeToSystemTime(cast(FILETIME*)&ft, &st);
        SetSystemTime(&st);
    }
    else version (Posix)
    {
        timespec ts;
        ts.tv_sec = cast(time_t)(unix_ns / 1_000_000_000);
        ts.tv_nsec = cast(uint)(unix_ns % 1_000_000_000);
        clock_settime(CLOCK_REALTIME, &ts);
    }
    else version (Embedded)
    {
        static if (has_rtc)
        {
            auto p = persistent_state();
            ulong mtime_ticks = nsecs_to_ticks(unix_ns);
            ulong sec = mtime_ticks / mtime_freq_hz;
            ulong frac = mtime_ticks % mtime_freq_hz;
            ulong hbn_ticks = sec * rtc_freq_hz + frac * rtc_freq_hz / mtime_freq_hz;
            p.utc_offset = cast(long)hbn_ticks - cast(long)rtc_read();
            p.magic = RtcPersist.magic_value;
        }
    }
}

void set_timezone(Duration offset)
{
    g_current_timezone = offset;
    notify_clock_change(0); // local representation only; UTC didn't step
}


// delta_ns = 0 when only the timezone changed, or on first establishment of the clock
alias ClockChangeHandler = void delegate(long delta_ns) nothrow @nogc;

void subscribe_clock_change(ClockChangeHandler h)
{
    _clock_change_handlers ~= h;
}

void unsubscribe_clock_change(ClockChangeHandler h)
{
    debug assert(g_iterating_clock_change == false, "must not unsubscribe from a clock_change handler");
    foreach (i, hh; _clock_change_handlers)
    {
        if (hh is h)
        {
            _clock_change_handlers.removeSwapLast(i);
            return;
        }
    }
}

void notify_clock_change(long delta_ns)
{
    debug g_iterating_clock_change = true;
    foreach (h; _clock_change_handlers)
        h(delta_ns);
    debug g_iterating_clock_change = false;
}

debug __gshared g_iterating_clock_change = false;


private:

__gshared Array!ClockChangeHandler _clock_change_handlers;
__gshared Duration g_current_timezone;

__gshared immutable MonoTime startTime;

__gshared immutable string[12] g_month_names = [ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" ];
__gshared immutable uint[10] digit_multipliers = [ 1_000_000_000, 100_000_000, 10_000_000, 1_000_000, 100_000, 10_000, 1_000, 100, 10, 1 ];

version (Windows)
{
    enum ulong unix_epoch_as_filetime = 116_444_736_000_000_000UL;

    enum uint ticks_per_second = 10_000_000; // QPC has been 10mHz for several decades. I don't think it can ever change...
}
else version (Posix)
    enum uint ticks_per_second = 1_000_000_000;
else version (Embedded)
    enum uint ticks_per_second = mtime_freq_hz;

// A tick is nsec_num / nsec_den nanoseconds, reduced, so rates that do not divide a second convert exactly.
enum ulong nsec_num = 1_000_000_000 / gcd(1_000_000_000, ticks_per_second);
enum ulong nsec_den = ticks_per_second / gcd(1_000_000_000, ticks_per_second);

T ticks_to_nsecs(T)(T ticks) pure
    => scale!(nsec_num, nsec_den)(ticks);

T nsecs_to_ticks(T)(T ns) pure
    => scale!(nsec_den, nsec_num)(ns);

// x * num / den by a multiply-high with the fraction fixed at compile time: never a divide, and truncated toward zero
// except for |x| >= 2^64 / den, where it may land one tick up. Compile time takes the same path, so the two agree.
T scale(ulong num, ulong den, T)(T x) pure
{
    enum T n = num, d = den;
    static if (den == 1)
        return x * n;
    else
    {
        static if (is_signed_integral!T)
        {
            if (x < 0)
                return -cast(T)scale_up!(num, den)(0UL - cast(ulong)x);
        }
        return cast(T)scale_up!(num, den)(x);
    }
}

ulong scale_up(ulong num, ulong den)(ulong x) pure
{
    static assert(den <= uint.max);
    enum ulong frac = () {
        ulong r = num % den, q;
        foreach (_; 0 .. 2)
        {
            r <<= 32;
            q = q << 32 | r / den;
            r %= den;
        }
        return r ? q + 1 : q;
    }();

    if (__ctfe)
    {
        immutable ulong xl = cast(uint)x, xh = x >> 32, fl = cast(uint)frac, fh = frac >> 32;
        immutable ulong mid = (xl * fl >> 32) + cast(uint)(xh * fl) + cast(uint)(xl * fh);
        return x * (num / den) + xh * fh + (xh * fl >> 32) + (xl * fh >> 32) + (mid >> 32);
    }
    import urt.math : mul64to128;
    return x * (num / den) + mul64to128(x, frac)[1];
}

ulong gcd(ulong a, ulong b) pure
{
    while (b)
    {
        immutable t = a % b;
        a = b;
        b = t;
    }
    return a;
}

__gshared immutable ulong sys_time_offset;
__gshared bool has_wall_time;

long clock_offset(Clock c)()
{
    static if (c == Clock.Monotonic)
        return 0;
    else static if (c == Clock.SystemTime)
        return cast(long)sys_time_offset;
    else static if (c == Clock.LocalTime)
        return cast(long)sys_time_offset + g_current_timezone.ticks;
    else
        static assert(false, "unknown clock");
}

size_t tz_offset_len(Duration offset) pure
    => (offset.as!"minutes" % 60) ? 6 : 3;

size_t format_tz_offset(Duration offset, char[] buffer) pure
{
    long mins = offset.as!"minutes";
    buffer[0] = mins < 0 ? '-' : '+';
    if (mins < 0)
        mins = -mins;
    uint hh = cast(uint)(mins / 60);
    uint mm = cast(uint)(mins % 60);
    buffer[1] = cast(char)('0' + hh / 10);
    buffer[2] = cast(char)('0' + hh % 10);
    if (mm == 0)
        return 3;
    buffer[3] = ':';
    buffer[4] = cast(char)('0' + mm / 10);
    buffer[5] = cast(char)('0' + mm % 10);
    return 6;
}

package(urt) void init_clock()
{
    cast()startTime = get_time();

    version (Windows)
    {
        import urt.internal.sys.windows;
        import urt.util : min;

        LARGE_INTEGER freq;
        QueryPerformanceFrequency(&freq);
        assert(cast(uint)freq.QuadPart == ticks_per_second, "Unexpected QPC frequency! urt needs to be updated...");

        // we want the ftime for QPC 0; which should be the boot time
        // we'll repeat this 100 times and take the minimum, and we should be within probably nanoseconds of the correct value
        LARGE_INTEGER qpc;
        ulong ftime, boot_time = ulong.max;
        foreach (i; 0 .. 100)
        {
            QueryPerformanceCounter(&qpc);
            GetSystemTimePreciseAsFileTime(cast(FILETIME*)&ftime);
            boot_time = min(boot_time, ftime - qpc.QuadPart);
        }
        cast()sys_time_offset = boot_time;
        has_wall_time = true;
    }
    else version (Posix)
    {
        import urt.util : min;

        // this doesn't really give time since boot, since MONOTIME is not guaranteed to be zero at system startup...
        timespec mt, rt;
        ulong boot_time = ulong.max;
        foreach (i; 0 .. 100)
        {
            clock_gettime(CLOCK_MONOTONIC, &mt);
            clock_gettime(CLOCK_REALTIME, &rt);
            boot_time = min(boot_time, rt.tv_sec*1_000_000_000L + rt.tv_nsec - mt.tv_sec*1_000_000_000L - mt.tv_nsec);
        }
        cast()sys_time_offset = boot_time;
        has_wall_time = true;
    }
    else version (Embedded)
    {
        static if (has_rtc)
        {
            rtc_enable();
            recalc_sys_time_offset();
        }
        else
        {
            cast()sys_time_offset = 0;
        }
    }
    else
        static assert(false, "TODO");
}

// Subsecond entries are nanoseconds; the remaining entries are seconds.
private immutable uint[8] duration_scales = [1, 1_000, 1_000_000, 1, 60, 3_600, 86_400, 604_800];

ptrdiff_t duration_to_string(long ns, char[] buffer, const(char)[] format = null) pure
{
    import urt.conv : format_uint;

    uint terms = 9, places = 9;
    if (format.length)
    {
        if ((format.length != 2 && format.length != 4) || format.ptr[0] != 't')
            return -2;
        terms = format.ptr[1] - '0';
        if (terms - 1 >= 9)
            return -2;
        if (format.length == 4)
        {
            places = format.ptr[3] - '0';
            if (format.ptr[2] != '.' || places > 9)
                return -2;
        }
    }

    ulong a = ns < 0 ? 0UL - cast(ulong)ns : cast(ulong)ns;
    ulong seconds = a / 1_000_000_000;
    uint fraction = cast(uint)(a % 1_000_000_000);
    uint unit = 3;
    if (!seconds && fraction)
    {
        unit = 2;
        while (fraction < duration_scales.ptr[unit])
            --unit;
    }
    uint quantum = digit_multipliers.ptr[9 - (unit * 3 > places ? unit * 3 - places : 0)];
    fraction += quantum / 2;
    fraction -= fraction % quantum;
    if (fraction == 1_000_000_000)
    {
        ++seconds;
        fraction = 0;
    }
    if (unit < 3 && (seconds || fraction >= duration_scales.ptr[unit] * 1_000))
        ++unit;

    uint i = 7, c = cast(uint)(seconds / 604_800);
    uint whole = cast(uint)(seconds % 604_800);
    if (!seconds)
    {
        i = unit;
        c = fraction / duration_scales.ptr[unit];
        fraction %= duration_scales.ptr[unit];
    }
    // At most 30 characters; each numeric field fits in ten.
    char[32] tmp = void;
    char* p = tmp.ptr;
    if (ns < 0)
        *p++ = '-';
    while (true)
    {
        if (c || i == unit)
        {
            p += c.format_uint(p[0 .. 10]);
            if (i == unit && fraction)
            {
                *p++ = '.';
                p += fraction.format_uint(p[0 .. 10], 10, unit * 3, '0');
                while (p[-1] == '0')
                    --p;
            }
            *p++ = "numsmhdw".ptr[i];
            if (i < 3)
                *p++ = 's';
            else if (i == 4 && !format.length)
            {
                *p++ = 'i';
                *p++ = 'n';
            }
            if (--terms == 0 || !(whole | fraction))
                break;
        }
        if (i == unit)
            break;
        --i;
        c = whole / duration_scales.ptr[i];
        whole %= duration_scales.ptr[i];
    }

    size_t len = p - tmp.ptr;
    if (!buffer.ptr)
        return len;
    if (buffer.length < len)
        return -1;
    buffer.ptr[0 .. len] = tmp.ptr[0 .. len];
    return len;
}

ptrdiff_t time_to_string(long ns, char[] buffer) pure
{
    import urt.conv : format_int;

    int hr = cast(int)(ns / 3_600_000_000_000);
    ns = ns < 0 ? -ns % 3_600_000_000_000 : ns % 3_600_000_000_000;
    uint remainder = cast(uint)(ns % 1_000_000_000);

    if (!buffer.ptr)
    {
        size_t tail = 6;
        if (remainder)
        {
            ++tail;
            uint m = 0;
            do
            {
                ++tail;
                uint digit = cast(uint)(remainder / digit_multipliers[m + 1]);
                remainder -= digit * digit_multipliers[1 + m++];
            }
            while (remainder);
        }
        return hr.format_int(null, 10, 2, '0') + tail;
    }

    ptrdiff_t len = hr.format_int(buffer, 10, 2, '0');
    if (len < 0 || buffer.length < len + 6)
        return -1;

    uint min_sec = cast(uint)(ns / 1_000_000_000);
    uint min = min_sec / 60;
    uint sec = min_sec % 60;

    buffer.ptr[len++] = ':';
    buffer.ptr[len++] = cast(char)('0' + (min / 10));
    buffer.ptr[len++] = cast(char)('0' + (min % 10));
    buffer.ptr[len++] = ':';
    buffer.ptr[len++] = cast(char)('0' + (sec / 10));
    buffer.ptr[len++] = cast(char)('0' + (sec % 10));
    if (remainder)
    {
        if (buffer.length < len + 2)
            return -1;
        buffer.ptr[len++] = '.';
        uint i = 0;
        while (remainder)
        {
            if (buffer.length <= len)
                return -1;
            uint m = digit_multipliers[1 + i++];
            uint digit = cast(uint)(remainder / m);
            buffer.ptr[len++] = cast(char)('0' + digit);
            remainder -= digit * m;
        }
    }
    return len;
}

unittest
{
    import urt.mem.temp;

    static void duration_text(long ns, string expected, string spec = null)
    {
        char[48] buffer;
        ptrdiff_t length = duration_to_string(ns, buffer, spec);
        assert(length == expected.length && buffer[0 .. length] == expected);
        assert(duration_to_string(ns, null, spec) == length);
        buffer[] = '?';
        assert(duration_to_string(ns, buffer[0 .. length - 1], spec) == -1);
        assert(buffer[0] == '?');
    }
    duration_text(0, "0s");
    duration_text(10_010_000_000, "10.01s");
    duration_text(-10_010_000_000, "-10.01s");
    duration_text(350_000_000, "350ms");
    duration_text(-10_000, "-10us");
    duration_text(10_000, "10us");
    duration_text(100, "100ns");
    duration_text(10_250, "10.25us");
    duration_text(600_000_000_000, "10min");
    duration_text(600_000_000_000, "10m", "t2");
    duration_text(60_300_000_000, "1min0.3s");
    duration_text(3_723_456_000_000, "1h2min3.456s");
    duration_text(3_723_456_000_000, "1h2m", "t2");
    duration_text(3_723_456_000_000, "1h2m3.456s", "t9");
    duration_text(3_603_000_000_000, "1h3s", "t2");
    duration_text(3_603_000_000_000, "1h", "t1");
    duration_text(-62_300_000_000, "-1m2.3s", "t2.1");
    duration_text(10_014_000_000, "10.01s", "t2.2");
    duration_text(10_016_000_000, "10.02s", "t2.2");
    duration_text(-10_015_000_000, "-10.02s", "t2.2");
    duration_text(350_125_000, "350.13ms", "t2.2");
    duration_text(999_999_000, "1s", "t2.2");
    duration_text(59_999_000_000, "1m", "t2.2");
    duration_text(3_659_999_000_000, "1h1m", "t2.2");
    duration_text(7_199_999_000_000, "1h59m", "t2");
    duration_text(7_199_999_000_000, "2h", "t2.2");
    duration_text(604_799_999_000_000, "1w", "t2.2");
    duration_text(999_999, "1ms", "t2.2");
    duration_text(-1, "-1ns", "t2.0");
    duration_text(long.max, "15250w1d23h47min16.854775807s");
    duration_text(long.min, "-15250w1d23h47min16.854775808s");
    assert(tformat("{0,t2.1}", -62_300.msecs) == "-1m2.3s");
    foreach (spec; ["t", "t/", "t0", "t10", "x2", "t2.", "t2./", "t2.x", "t2.10", ".2"])
        assert(duration_to_string(1, null, spec) == -2);

    Duration parsed_duration;
    ulong sample = 1;
    foreach (i; 0 .. 256)
    {
        sample = sample * 6364136223846793005UL + 1;
        char[48] buffer;
        long ns = cast(long)sample >> (i % 64);
        auto length = duration_to_string(ns, buffer);
        assert(parsed_duration.fromString(buffer[0 .. length]) == length);
        assert(parsed_duration.ticks == nsecs_to_ticks(ns));
    }
    foreach (text; ["10.1s", "-10.1s", "0.01ms", "350.125ms", "1min10.01s", "0.000000001s", "1.5h"])
    {
        assert(parsed_duration.fromString(text) == text.length);
        long parsed_ticks = parsed_duration.ticks;
        const(char)[] formatted = tconcat(parsed_duration)[];
        assert(parsed_duration.fromString(formatted) == formatted.length && parsed_duration.ticks == parsed_ticks);
    }
    assert(parsed_duration.fromString("10.1s") == 5 && parsed_duration.as!"msecs" == 10_100);
    assert(parsed_duration.fromString("0.01ms") == 6 && parsed_duration.as!"usecs" == 10);
    assert(parsed_duration.fromString("1.000000001s") == 12 && parsed_duration.ticks == nsecs_to_ticks(1_000_000_001));
    foreach (text; ["1W", "1D", "1H", "1MiN", "1S", "1Ms", "1uS", "1NS"])
        assert(parsed_duration.fromString(text) == text.length);
    assert(parsed_duration.fromString("1MIN") == 4 && parsed_duration.as!"minutes" == 1);
    assert(parsed_duration.fromString("1MS") == 3 && parsed_duration.as!"msecs" == 1);
    assert(parsed_duration.fromString("9223372036854775807ns") == 21);
    assert(parsed_duration.ticks == nsecs_to_ticks(long.max));
    assert(parsed_duration.fromString("-9223372036854775808ns") == 22);
    assert(parsed_duration.ticks == nsecs_to_ticks(long.min));
    foreach (text; ["", "10", "10.1", "10m", "10M", "10m2s", "1mi", "1mins", "1min2", "1mm", "1ss", "1usx", "1wx", "1xs", "1u", "1n", "1e", "1z", "1uin", "1nin",
        "10.s", ".1s", "1.+1s", "1.-1s", "10.1s1ms", "1.1234567890s", "1.0000000000s", "9223372036854775808ns",
        "-9223372036854775809ns", "184467440737095516160ns", "999999999999999999w"])
    {
        long previous = parsed_duration.ticks;
        assert(parsed_duration.fromString(text) == -1);
        assert(parsed_duration.ticks == previous);
    }

    assert(scale!(125, 2)(3L) == 187);
    assert(scale!(125, 2)(-3L) == -187);
    assert(scale!(2, 125)(1_000_000_000L) == 16_000_000);
    assert(scale!(500, 13)(26_000_000L) == 1_000_000_000);
    assert(scale!(500, 13)(long.max / 500 * 13) == long.max / 500 * 500);
    enum ulong exact = ulong.max / 500 * 13 + ulong.max % 500 * 13 / 500;
    assert(scale!(13, 500)(ulong.max) - exact <= 1);
    enum ulong big = 1_800_000_000_000_000_499UL;
    assert(scale!(13, 500)(big) - (big / 500 * 13 + big % 500 * 13 / 500) <= 1);
    static assert(scale!(13, 500)(big) == 46_800_000_000_000_013);
    assert(scale!(13, 500)(big) == 46_800_000_000_000_013);
    assert(scale!(13, 500)(-cast(long)big) == -46_800_000_000_000_013);
    assert(123_456_789L - nsecs_to_ticks(ticks_to_nsecs(123_456_789L)) <= 1);
    static foreach (r; [[125, 2], [2, 125], [500, 13], [13, 500], [25, 22], [22, 25], [1, 1000]])
    {
        for (ulong x = 0; x < 1UL << 50; x = x < 100_000 ? x + 1 : x * 3 + 7)
            assert(scale!(r[0], r[1])(x) == x * r[0] / r[1]);
    }

    assert(random_delay(Duration.zero) == Duration.zero);
    foreach (_; 0 .. 100)
    {
        Duration delay = random_delay(10.msecs);
        assert(delay > Duration.zero && delay <= 10.msecs);
    }

    assert(tconcat(msecs(3_600_000*3 + 60_000*47 + 1000*34 + 123))[] == "3h47min34.123s");
    assert(tconcat(msecs(3_600_000*-123))[] == "-5d3h");
    assert(tconcat(usecs(3_600_000_000*-123 + 1))[] == "-5d2h59min59.999999s");
    assert(MonoTime().toString(null, null, null) == 10);
    assert(tconcat(get_time())[0..2] == "T+");

    // Test Duration.fromString with compound formats
    Duration d;

    // Simple single units
    assert(d.fromString("5s") == 2 && d.as!"seconds" == 5);
    assert(d.fromString("10min") == 5 && d.as!"minutes" == 10);

    // Compound durations
    assert(d.fromString("1h30min") == 7 && d.as!"minutes" == 90);
    assert(d.fromString("5min30s") == 7 && d.as!"seconds" == 330);

    // Duplicate units should fail
    assert(d.fromString("30min30min") == -1);
    assert(d.fromString("1h2h") == -1);
    assert(d.fromString("5s10s") == -1);

    // Out-of-order units should fail
    assert(d.fromString("30s5min") == -1);
    assert(d.fromString("1min2h") == -1);
    assert(d.fromString("5s10ms5min") == -1);
    assert(d.fromString("5s10ms10ns") == -1);  // ms and ns (only one sub-second unit allowed)

    // Improper units should fail
    assert(d.fromString("30z") == -1);  // not a time denomination

    // Correctly ordered units should work
    assert(d.fromString("1d2h30min15s") == 12 && d.as!"seconds" == 86_400 + 7_200 + 1_800 + 15);

    // A single leading sign negates the whole duration (every component), matching toString
    assert(d.fromString("-5d3h") == 5 && d.as!"hours" == -123);
    assert(d.fromString("-30s") == 4 && d.as!"seconds" == -30);
    assert(d.fromString("+5min") == 5 && d.as!"minutes" == 5);
    assert(d.fromString("-") == -1);        // bare sign, no magnitude
    assert(d.fromString("5s-3s") == 2);     // embedded sign terminates the parse after "5s"

    // toString/fromString round-trip, including negatives and sub-second tails
    foreach (ns; [0L, 5_000_000_000L, -442_800_000_000_000L, -442_799_999_999_000_000L, 90_061_000_000_000L])
    {
        Duration r;
        assert(r.fromString(tconcat(nsecs(ns))[]) > 0 && r.as!"nsecs" == ns);
    }

    // Test DateTime.fromString
    DateTime dt;
    assert(dt.fromString("2024-06-15T12:34:56") == 19);
    assert(dt.fromString("-100/06/15 12:34:56") == 19);
    assert(dt.fromString("BC100-AUG-15 12:34:56.789") == 25);
    assert(dt.fromString("BC 10000-AUG-15 12:34:56.789123456") == 34);
    assert(dt.fromString("1-1-1 01:01:01") == 14);
    assert(dt.fromString("1-1-1 01:01:01.") == 14);
    assert(dt.fromString("2025") == 4);
    assert(dt.fromString("2025-10") == 7);
    assert(dt.fromString("2025-01-01") == 10);
    assert(dt.fromString("2025-01-01 00") == 13);
    assert(dt.fromString("2025-01-01 00:10") == 16);
    assert(dt.fromString("2025-01-01 00:10z") == 17);
    assert(dt.fromString("2025-01-01 00+00:00") == 19);
    assert(dt.fromString("2025-01-01 00-1030") == 18);
    assert(dt.fromString("2025-01-01 00+08") == 16);

    // explicit offsets are normalised to UTC
    DateTime off;
    bool had_off;
    assert(off.from_string("2025-06-15T12:00:00+10:00", had_off) == 25 && had_off);
    assert(off.hour == 2 && off.day == 15 && off.month == Month.June); // 12:00 +10 -> 02:00 UTC
    assert(off.from_string("2025-06-15T01:00:00-05:30", had_off) == 25 && had_off);
    assert(off.hour == 6 && off.minute == 30 && off.day == 15);        // 01:00 -0530 -> 06:30 UTC
    assert(off.from_string("2025-06-15T02:00:00+05:00", had_off) == 25 && had_off);
    assert(off.day == 14 && off.hour == 21);                           // rolls back a day
    assert(off.from_string("2025-06-15T12:00:00Z", had_off) == 20 && had_off);
    assert(off.hour == 12 && off.day == 15);                           // Z is UTC, unchanged
    assert(off.from_string("2025-06-15T12:00:00", had_off) == 19 && !had_off);

    assert(dt.fromString("BC -10") == -1);
    assert(dt.fromString("2024-0-15 12:34:56") == -1);
    assert(dt.fromString("2024-13-15 12:34:56") == -1);
    assert(dt.fromString("2024-1-0 12:34:56") == -1);
    assert(dt.fromString("2024-1-32 12:34:56") == -1);
    assert(dt.fromString("2024-1-1 24:34:56") == -1);
    assert(dt.fromString("2024-1-1 01:60:56") == -1);
    assert(dt.fromString("2024-1-1 01:01:60") == -1);
    assert(dt.fromString("10000-1-1 1:01:01") == -1);

    // ---- TimeOfDay ----

    TimeOfDay tod;
    assert(tod.fromString("10:30") == 5 && tod.hour == 10 && tod.minute == 30 && tod.second == 0 && tod.ns == 0);
    assert(tod.fromString("10:30:45") == 8 && tod.second == 45);
    assert(tod.fromString("10:30:45.5") == 10 && tod.ns == 500_000_000);
    assert(tod.fromString("23:59:59.999999999") == 18 && tod.ns == 999_999_999);
    assert(tod.fromString("00:00:00") == 8);

    assert(tod.fromString("24:00") == -1);
    assert(tod.fromString("10:60") == -1);
    assert(tod.fromString("10:30:60") == -1);
    assert(tod.fromString("1:30") == -1);
    assert(tod.fromString("") == -1);

    tod = TimeOfDay(10, 30, 0, 0);
    assert(tconcat(tod)[] == "10:30:00");
    tod.ns = 123_000_000;
    assert(tconcat(tod)[] == "10:30:00.123");

    // arithmetic
    tod = TimeOfDay(10, 30, 0, 0);
    auto tod2 = tod + dur!"minutes"(45);
    assert(tod2.hour == 11 && tod2.minute == 15 && tod2.second == 0);
    auto tod3 = tod - dur!"hours"(11);
    assert(tod3.hour == 23 && tod3.minute == 30); // wrap backwards
    auto tod4 = tod + dur!"hours"(25);
    assert(tod4.hour == 11 && tod4.minute == 30); // wrap forwards
    Duration diff = TimeOfDay(11, 0, 0, 0) - TimeOfDay(10, 30, 0, 0);
    assert(diff.as!"minutes" == 30);

    // extract from DateTime / SysTime
    dt = DateTime.init;
    dt.year = 2025; dt.month = Month.June; dt.day = 15;
    dt.hour = 8; dt.minute = 30; dt.second = 45; dt.ns = 123_456_789;
    tod = time_of_day(dt);
    assert(tod.hour == 8 && tod.minute == 30 && tod.second == 45 && tod.ns == 123_456_789);

    // ---- unix_ns_to_datetime / datetime_to_unix_ns ----

    // Unix epoch: 1970-01-01 00:00:00 UTC, Thursday
    dt = unix_ns_to_datetime(0);
    assert(dt.year == 1970 && dt.month == Month.January && dt.day == 1);
    assert(dt.hour == 0 && dt.minute == 0 && dt.second == 0 && dt.ns == 0);
    assert(dt.wday == Day.Thursday);

    // Round-trip at epoch
    assert(datetime_to_unix_ns(dt) == 0);

    // 2000-01-01 00:00:00 UTC = 946684800 seconds, Saturday
    dt = unix_ns_to_datetime(946_684_800UL * 1_000_000_000);
    assert(dt.year == 2000 && dt.month == Month.January && dt.day == 1);
    assert(dt.wday == Day.Saturday);
    assert(datetime_to_unix_ns(dt) == 946_684_800UL * 1_000_000_000);

    // 2024-02-29 (leap year) 12:00:00 = 1709208000 seconds, Thursday
    dt = unix_ns_to_datetime(1_709_208_000UL * 1_000_000_000);
    assert(dt.year == 2024 && dt.month == Month.February && dt.day == 29);
    assert(dt.hour == 12 && dt.minute == 0 && dt.second == 0);
    assert(dt.wday == Day.Thursday);
    assert(datetime_to_unix_ns(dt) == 1_709_208_000UL * 1_000_000_000);

    // 1900-03-01 - 1900 is NOT a leap year (century rule)
    // 1900-03-01 00:00:00 = -2203891200 seconds... negative, skip
    // Instead test 2100-03-01 (also not a leap year)
    // 2100-03-01 00:00:00 = 4107542400 seconds, Monday
    dt = unix_ns_to_datetime(4_107_542_400UL * 1_000_000_000);
    assert(dt.year == 2100 && dt.month == Month.March && dt.day == 1);
    assert(dt.wday == Day.Monday);

    // 2000 IS a leap year (400-year rule), Feb 29 exists
    // 2000-02-29 00:00:00 = 951782400 seconds, Tuesday
    dt = unix_ns_to_datetime(951_782_400UL * 1_000_000_000);
    assert(dt.year == 2000 && dt.month == Month.February && dt.day == 29);
    assert(dt.wday == Day.Tuesday);

    // Sub-second precision: 2025-06-15 08:30:45.123456789
    dt.year = 2025; dt.month = Month.June; dt.day = 15;
    dt.hour = 8; dt.minute = 30; dt.second = 45; dt.ns = 123_456_789;
    ulong ns = datetime_to_unix_ns(dt);
    auto dt2 = unix_ns_to_datetime(ns);
    assert(dt2.year == 2025 && dt2.month == Month.June && dt2.day == 15);
    assert(dt2.hour == 8 && dt2.minute == 30 && dt2.second == 45);
    assert(dt2.ns == 123_456_789);

    // Dec 31 ? Jan 1 boundary
    dt = unix_ns_to_datetime(1_735_689_599UL * 1_000_000_000); // 2024-12-31 23:59:59
    assert(dt.year == 2024 && dt.month == Month.December && dt.day == 31);
    assert(dt.hour == 23 && dt.minute == 59 && dt.second == 59);
    dt = unix_ns_to_datetime(1_735_689_600UL * 1_000_000_000); // 2025-01-01 00:00:00
    assert(dt.year == 2025 && dt.month == Month.January && dt.day == 1);
    assert(dt.wday == Day.Wednesday);

    // ---- LocalTime ----

    SysTime utc = from_unix_time_ns(1_700_000_000UL * 1_000_000_000);

    set_timezone(dur!"hours"(10));
    LocalTime local = cast(LocalTime)utc;

    // local wall-clock reads 10 hours ahead of UTC...
    assert(unix_time_ns(SysTime(local.ticks)) == unix_time_ns(utc) + 10UL*3_600 * 1_000_000_000);
    // ...but names the same instant, so it round-trips and differences are zero
    assert(cast(SysTime)local == utc);
    assert((local - utc).ticks == 0);

    // negative, non-whole-hour offset
    set_timezone(-dur!"hours"(5) - dur!"minutes"(30));
    local = cast(LocalTime)utc;
    assert(unix_time_ns(SysTime(local.ticks)) == unix_time_ns(utc) - (5UL*3_600 + 30*60) * 1_000_000_000);
    assert(cast(SysTime)local == utc);

    // LocalTime parses / formats as local wall-clock, with an explicit offset suffix
    set_timezone(dur!"hours"(10));
    SysTime noon = get_sys_time(DateTime(2025, Month.June, Day.Sunday, 15, 12, 0, 0));

    LocalTime parsed;
    assert(parsed.fromString("2025-06-15T12:00:00") == 19);            // bare -> local
    assert(tconcat(parsed)[] == "2025-06-15T12:00:00+10");             // whole hour: no :MM
    assert(cast(SysTime)parsed == get_sys_time(DateTime(2025, Month.June, Day.Sunday, 15, 2, 0, 0)));

    // an explicit offset names an absolute instant
    assert(parsed.fromString("2025-06-15T12:00:00+00:00") == 25);      // 12:00 UTC -> 22:00 local
    assert(tconcat(parsed)[] == "2025-06-15T22:00:00+10");
    assert(cast(SysTime)parsed == noon);

    // half-hour offset keeps :MM
    set_timezone(-dur!"hours"(5) - dur!"minutes"(30));
    assert(tconcat(cast(LocalTime)noon)[] == "2025-06-15T06:30:00-05:30");

    // SysTime renders as UTC ('Z') and round-trips through its own string
    assert(tconcat(noon)[] == "2025-06-15T12:00:00Z");
    SysTime st;
    assert(st.fromString("2025-06-15T12:00:00Z") == 20 && st == noon);
    assert(st.fromString("2025-06-15T12:00:00") == 19 && st == noon);  // bare -> UTC
    assert(st.fromString("2025-06-15T22:00:00+10:00") == 25 && st == noon);

    // naive DateTime <-> Time conversions: the converter supplies the zone
    set_timezone(dur!"hours"(10));
    DateTime wall = get_date_time(noon);   // 2025-06-15 12:00:00, canonical (correct wday)
    // same numerals, two instants 10h apart
    assert(get_sys_time(wall) == noon);                                    // numerals as UTC
    assert(cast(SysTime)get_local_time(wall) == noon - dur!"hours"(10)); // numerals as local
    // breakdown is symmetric: each Time -> its own wall-clock numerals
    assert(get_date_time(get_sys_time(wall)) == wall);
    assert(get_date_time(get_local_time(wall)) == wall);

    set_timezone(Duration.zero);
}


DateTime unix_ns_to_datetime(ulong ns) pure
{
    ulong total_sec = ns / 1_000_000_000;
    uint remainder_ns = cast(uint)(ns % 1_000_000_000);

    uint sod = cast(uint)(total_sec % 86_400);
    long days = cast(long)(total_sec / 86_400);

    DateTime dt;
    dt.hour = cast(ubyte)(sod / 3600);
    dt.minute = cast(ubyte)(sod % 3600 / 60);
    dt.second = cast(ubyte)(sod % 60);
    dt.ns = remainder_ns;

    dt.wday = cast(Day)((days + 4) % 7);

    days += 719_468;
    long era = (days >= 0 ? days : days - 146_096) / 146_097;
    uint doe = cast(uint)(days - era * 146_097);
    uint yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    long y = yoe + era * 400;
    uint doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    uint mp = (5 * doy + 2) / 153;
    uint d = doy - (153 * mp + 2) / 5 + 1;
    uint m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2)
        ++y;

    dt.year = cast(short)y;
    dt.month = cast(Month)m;
    dt.day = cast(ubyte)d;

    return dt;
}

ulong datetime_to_unix_ns(DateTime dt) pure
{
    long y = dt.year;
    uint m = dt.month;
    uint d = dt.day;

    if (m <= 2)
        --y;
    long era = (y >= 0 ? y : y - 399) / 400;
    uint yoe = cast(uint)(y - era * 400);
    uint doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    uint doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long days = era * 146_097 + doe - 719_468;

    ulong total_sec = cast(ulong)(days * 86_400 + dt.hour*3600 + dt.minute*60 + dt.second);

    return total_sec * 1_000_000_000 + dt.ns;
}

version (Embedded) static if (has_rtc)
{
    __gshared ulong last_hbn;

    void correct_drift()
    {
        auto p = persistent_state();
        if (p.magic != RtcPersist.magic_value)
            return;

        ulong now_hbn = rtc_read();

        // detect 40-bit wrap: counter went backwards since last check
        if (now_hbn < last_hbn)
            p.utc_offset += ulong(1) << 40;
        last_hbn = now_hbn;

        ulong sys_mtime = mtime_read() + sys_time_offset;

        // What does HBN + offset think it is (converted to mtime ticks)?
        ulong hbn_total = now_hbn + p.utc_offset;
        ulong sys_hbn = hbn_total / rtc_freq_hz * mtime_freq_hz
                        + hbn_total % rtc_freq_hz * mtime_freq_hz / rtc_freq_hz;

        // difference is accumulated drift; fold into utc_offset
        long drift_mtime = sys_mtime - sys_hbn;
        p.utc_offset += drift_mtime * rtc_freq_hz / mtime_freq_hz;
    }

    void recalc_sys_time_offset()
    {
        import urt.driver.reset : ResetMark, reset_record_take;

        auto p = persistent_state();
        if (reset_record_take() == ResetMark.none)
            p.magic = 0;    // the supply went away; whatever survived in RAM is not a clock
        if (p.magic == RtcPersist.magic_value)
        {
            last_hbn = rtc_read();
            long hbn_total = cast(long)(last_hbn + p.utc_offset);
            long hbn_unix_mtime = hbn_total / rtc_freq_hz * mtime_freq_hz
                                + hbn_total % rtc_freq_hz * mtime_freq_hz / rtc_freq_hz;
            cast()sys_time_offset = cast(ulong)(hbn_unix_mtime - cast(long)mtime_read());
            has_wall_time = true;
        }
    }
}
