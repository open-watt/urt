module urt.si.quantity;

import urt.meta : TypeForOp;
import urt.si.unit;
import urt.traits;

nothrow @nogc:


alias VarQuantity = Quantity!double;
alias Scalar = Quantity!(double, ScaledUnit());
alias Metres = Quantity!(double, ScaledUnit(Metre));
alias Seconds = Quantity!(double, ScaledUnit(Second));
alias PerSecond = Quantity!(double, ScaledUnit(Second^^-1));
alias Volts = Quantity!(double, ScaledUnit(Volt));
alias Amps = Quantity!(double, ScaledUnit(Ampere));
alias AmpHours = Quantity!(double, AmpereHour);
alias Watts = Quantity!(double, ScaledUnit(Watt));
alias Kilowatts = Quantity!(double, Kilowatt);
alias WattHours = Quantity!(double, WattHour);


struct Quantity(T, ScaledUnit _unit = ScaledUnit(uint.max))
{
nothrow @nogc:

    alias This = Quantity!(T, _unit);

    enum Dynamic = _unit.pack == uint.max;
    enum IsCompatible(ScaledUnit U) = _unit.unit == U.unit;

    T value = 0;

    static if (Dynamic)
        ScaledUnit unit;
    else
        alias unit = _unit;

    static if (is_some_float!T)
    {
        enum nan        = This(T.nan);
        enum infinity   = This(T.infinity);
        enum epsilon    = This(T.epsilon);
        enum max        = This(T.max);
        enum min_normal = This(T.min_normal);
    }
    else static if (is_some_int!T)
    {
        enum min = This(T.min);
        enum max = This(T.max);
    }

    bool isCompatible(U, ScaledUnit _U)(Quantity!(U, _U) compatibleWith) const pure
        if (is(U : T))
        => unit.unit == compatibleWith.unit.unit;

    // raw IEEE test; opEquals/opCmp have epsilon semantics, so q == q can't be used
    bool is_nan() const pure
        => is_some_float!T && value != value;

    static if (Dynamic)
    {
        this(T value, ScaledUnit unit = ScaledUnit()) pure
        {
            this.unit = unit;
            this.value = value;
        }
    }
    else
    {
        this(T value) pure
        {
            this.value = value;
        }
    }

    this(U, ScaledUnit _U)(Quantity!(U, _U) b) pure
        if (is(U : T))
    {
        static if (Dynamic)
        {
            unit = b.unit;
            value = b.value;
        }
        else
        {
            static if (b.Dynamic)
            {
                static if (is_some_float!T)
                {
                    if (!isCompatible(b))
                    {
                        value = T.nan;
                        return;
                    }
                }
                else
                    assert(isCompatible(b), "Incompatible units!");
            }
            else
                static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", b.unit.toString);
            value = adjust_scale(b);
        }
    }

    void opAssign()(T value) pure
    {
        static if (Dynamic)
            unit = Scalar;
        else
            static assert(unit == Unit(), "Incompatible units: ", unit.toString, " and Scalar");
        this.value = value;
    }

    void opAssign(U, ScaledUnit _U)(Quantity!(U, _U) b) pure
    {
        static assert(__traits(compiles, value = b.value), "cannot implicitly convert ScaledUnit of type `", U, "` to `", T, "`");

        static if (Dynamic)
        {
            unit = b.unit;
            value = b.value;
        }
        else
        {
            static if (b.Dynamic)
                assert(isCompatible(b), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", b.unit.toString);
            value = adjust_scale(b);
        }
    }

    auto opUnary(string op)() const pure
        if (op == "+" || op == "-")
    {
        alias RT = Quantity!(TypeForOp!(op, T), _unit);
        static if (Dynamic)
            return RT(mixin(op ~ "value"), unit);
        else
            return RT(mixin(op ~ "value"));
    }

    auto opBinary(string op, U)(U value) const pure
        if ((op == "+" || op == "-") && is(U : T))
        => opBinary!op(Quantity!(U, ScaledUnit())(value));

    auto opBinary(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
        if ((op == "+" || op == "-") && is(U : T))
    {
        // TODO: what unit should be result take?
        //       for float T, I reckon maybe the MAX exponent?
        //       for int types... we need to do some special shit to manage overflows!
        // HACK: for now, we just scale to the left-hand size... :/
        static if (!Dynamic && !b.Dynamic && unit == Unit() && b.unit == Unit())
            return mixin("value " ~ op ~ " b.value");
        else
        {
            static if (Dynamic || b.Dynamic)
                assert(isCompatible(b), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", b.unit.toString);

            Quantity!(TypeForOp!(op, T, U), _unit) r;
            r.value = mixin("value " ~ op ~ " adjust_scale(b)");
            static if (Dynamic)
                r.unit = unit;
            return r;
        }
    }

    auto opBinary(string op, U)(U value) const pure
        if ((op == "*" || op == "/") && is(U : T))
    {
        static if (!Dynamic && unit == Unit())
            return mixin("this.value " ~ op ~ " value");
        else
        {
            alias RT = TypeForOp!(op, T, U);
            RT v = mixin("this.value " ~ op ~ " value");
            static if (Dynamic)
                return Quantity!RT(v, unit);
            else
                return Quantity!(RT, unit)(v);
        }
    }

    auto opBinary(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
        if ((op == "*" || op == "/") && is(U : T))
    {
        static if (!Dynamic && !b.Dynamic && unit == Unit() && b.unit == Unit())
            return mixin("value " ~ op ~ " b.value");
        else
        {
            // TODO: if the unit product is invalid, then we need to decide a target scaling factor...
            static if (Dynamic || b.Dynamic)
                const u = mixin("unit " ~ op ~ " b.unit");
            else
                enum u = mixin("unit " ~ op ~ " b.unit");

            alias RT = TypeForOp!(op, T, U);
            RT v = mixin("value " ~ op ~ " b.value");

            static if (Dynamic || b.Dynamic)
                return Quantity!RT(v, u);
            else
                return Quantity!(RT, u)(v);
        }
    }

    void opOpAssign(string op)(T value) pure
    {
        // TODO: in D; ubyte += int is allowed, so we should cast the result to T
        this = opBinary!op(value);
    }

    void opOpAssign(string op, U, ScaledUnit _U)(Quantity!(U, _U) b) pure
    {
        // TODO: in D; ubyte += int is allowed, so we should cast the result to T
        this = opBinary!op(b);
    }

    bool opCast(T : bool)() const pure
        => value != 0;

    // not clear if this should return the raw value, or the normalised value...?
//    T opCast(T)() const pure
//        if (is_some_float!T || is_some_int!T)
//    {
//        assert(unit.pack == 0, "Non-scalar unit can't cast to scalar");
//        assert(false, "TODO: should we be applying the scale to this result?");
//        return cast(T)value;
//    }

    T opCast(T)() const pure
        if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
    {
        static if (is(T == Quantity!(U, _U), U, ScaledUnit _U))
        {
            T r;
            static if (Dynamic || T.Dynamic)
                assert(isCompatible(r), "Incompatible units!");
            else
                static assert(IsCompatible!_U, "Incompatible units: ", r.unit.toString, " and ", unit.toString);
            r.value = cast(U)r.adjust_scale(this);
            static if (T.Dynamic)
                r.unit = unit;
            return r;
        }
    }

    bool opEquals(U)(U value) const pure
        if (is(U : T))
    {
        if (unit == Unit())
            return value == value;
        return false;
    }

    bool opEquals(double epsilon = 0, U, ScaledUnit _U)(Quantity!(U, _U) rh) const pure
        => opCmp!(epsilon, true)(rh);

    auto opCmp(double epsilon = 0, bool eq = false, U, ScaledUnit _U)(Quantity!(U, _U) rh) const pure
        if (is(U : T))
    {
        double lhs = value;
        double rhs = rh.value;

        // if they have the same unit and scale...
        if (unit == rh.unit)
            goto compare;

        // can't compare mismatch unit types... i think?
        static if (Dynamic || rh.Dynamic)
            assert(isCompatible(rh), "Incompatible units!");
        else
            static assert(IsCompatible!_U, "Incompatible units: ", unit.toString, " and ", rh.unit.toString);

        // TODO: meeting in the middle is only better if the signs are opposite
        //       otherwise we should just scale to the left...
        static if (Dynamic && rh.Dynamic)
        {{
            // if the scale values are both dynamic, it should be more precise if we meet in the middle...
            auto lScale = unit.scale();
            auto lTrans = unit.offset();
            auto rScale = rh.unit.scale();
            auto rTrans = rh.unit.offset();
            lhs = lhs*lScale + lTrans;
            rhs = rhs*rScale + rTrans;
        }}
        else
            rhs = adjust_scale(rh);

    compare:
        static if (!eq)
        {
            // nan compares equal to itself and sorts after numbers; naive ordering would find it "equal" to everything
            if (lhs != lhs || rhs != rhs)
                return (lhs != lhs) - (rhs != rhs);
        }
        static if (epsilon == 0)
        {
            static if (eq)
                return lhs == rhs;
            else
                return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
        }
        else
        {
            double cmp = lhs - rhs;
            static if (eq)
                return cmp >= -epsilon && cmp <= epsilon;
            else
                return cmp < -epsilon ? -1 : cmp > epsilon ? 1 : 0;
        }
    }

    auto normalise() const pure
    {
        static if (Dynamic)
        {
            Quantity!T r;
            r.unit = ScaledUnit(unit.unit);
            r.value = cast(T)convert_quantity_scale(value, unit, r.unit);
        }
        else
        {
            Quantity!(T, ScaledUnit(unit.unit)) r;
            r.value = r.adjust_scale(this);
        }
        return r;
    }

    Quantity!Ty adjust_scale(Ty = T)(ScaledUnit su) const pure
    {
        Quantity!Ty r;
        r.unit = su;
        assert(r.isCompatible(this), "Incompatible units!");
        if (su == unit)
            r.value = cast(Ty)this.value;
        else
            r.value = cast(Ty)convert_quantity_scale(value, unit, su);
        return r;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[], const(FormatArg)[]) const
    {
        static if (is_some_float!T)
            return format_quantity_floating(value, unit, buffer);
        else
            return format_quantity_integer(cast(ulong)value, is_signed_int!T, unit, buffer);
    }

    ptrdiff_t fromString(const(char)[] s)
    {
        ScaledUnit* dynamic_unit;
        static if (Dynamic)
            dynamic_unit = &unit;

        ptrdiff_t taken;
        static if (is_some_float!T)
        {
            double parsed;
            taken = parse_quantity_floating(s, unit, dynamic_unit, parsed);
            if (taken >= 0)
                value = cast(T)parsed;
        }
        else
        {
            ulong parsed;
            taken = parse_quantity_integer(s, unit, dynamic_unit, is_signed_int!T, parsed);
            if (taken >= 0)
                value = cast(T)parsed;
        }
        return taken;
    }

private:
    T adjust_scale(U, ScaledUnit _U)(Quantity!(U, _U) b) const pure
    {
        static if (!Dynamic && !b.Dynamic && unit == b.unit)
            return cast(T)b.value;
        else
        {
            if (unit == b.unit)
                return cast(T)b.value;

            static if (Dynamic || b.Dynamic)
                return cast(T)convert_quantity_scale(b.value, b.unit, unit);
            else
            {
                enum lScale = unit.scale!true();
                enum lTrans = unit.offset!true();
                enum rScale = b.unit.scale();
                enum rTrans = b.unit.offset();
                enum scale = lScale*rScale;
                enum trans = lTrans + lScale*rTrans;
                return cast(T)(b.value*scale + trans);
            }
        }
    }
}


unittest
{
    alias Kilometres = Quantity!(double, Kilometre);
    alias Millimetres = Quantity!(double, Millimetre);
    alias Inches = Quantity!(double, Inch);
    alias Feet = Quantity!(double, Foot);
    alias SqMetres = Quantity!(double, ScaledUnit(Metre^^2));
    alias SqCentimetres = Quantity!(double, Centimetre^^2);
    alias SqInches = Quantity!(double, Inch^^2);
    alias MetresPerSecond = Quantity!(double, ScaledUnit(Metre/Second));
    alias DegreesK = Quantity!(double, ScaledUnit(Kelvin));
    alias DegreesC = Quantity!(double, Celsius);
    alias DegreesF = Quantity!(double, Fahrenheit);

    Scalar a = 1;
    Scalar b = 2;
    assert(a + b == 3);
    assert(a * b == 2);
    a *= 3;
    assert(a == 3);

    a = 10;
    assert(a == 10);

    Metres m = 10;
    assert(m == Metres(10));
    assert(m * b == Metres(20));
    Kilometres km = m;
    assert(km == Kilometres(0.01));
    km = m * 100;
    assert(km == Kilometres(1));
    Inches i = m;
    assert(i == Inches(393.7007874015748));
    i -= m;
    assert(i == Inches(0));
    SqMetres sqm = m * m;
    assert(sqm == SqMetres(100));
    sqm = Metres(1) * Kilometres(1);
    assert(sqm == SqMetres(1000));
    sqm = Kilometres(1) * Kilometres(1);
    assert(sqm == SqMetres(1000000));
    sqm = Metres(1) * Inches(1);
    assert(sqm == SqMetres(0.0254));
//    sqm = Kilometres(1) * Inches(1); // TODO: need a way to detect invalid unit product...
//    assert(sqm == SqMetres(25.4));

    Seconds s = 2;
    auto mps = m/s;
    static assert(is(typeof(mps) == MetresPerSecond));
    assert(mps == MetresPerSecond(5));

    m = mps * 2 * s;
    assert(m == Metres(20));

    VarQuantity v = mps;
    assert(v.unit == Metre/Second);
    v = m;
    assert(v.unit == Metre);
    assert(v * b == Metres(40));

    enum epsilon = 1e-12;

    DegreesF f = DegreesC(100);
    assert(f.opEquals!epsilon(DegreesF(212)));

    assert(Kilometres(2).opEquals!epsilon(Metres(2000)));
    assert(Metres(2).opEquals!epsilon(Kilometres(0.002)));
    assert(Kilometres(2).opEquals!epsilon(Millimetres(2000000)));

    assert(Inches(1).opEquals!epsilon(Metres(0.0254)));
    assert(Metres(1).opEquals!epsilon(Inches(1/0.0254)));
    assert(Millimetres(1).opEquals!epsilon(Inches(1/25.4)));
    assert(Inches(1).opEquals!epsilon(Millimetres(25.4)));
    assert(Feet(1).opEquals!epsilon(Inches(12)));
    assert(Inches(12).opEquals!epsilon(Feet(1)));
    assert(SqCentimetres(1).opEquals!epsilon(SqInches(0.15500031000062)));

    assert(DegreesC(100).opEquals!epsilon(DegreesK(373.15)));
    assert(DegreesK(200).opEquals!epsilon(DegreesC(-73.15)));
    assert(DegreesF(100).opEquals!epsilon(DegreesK(310.92777777777777)));
    assert(DegreesK(200).opEquals!epsilon(DegreesF(-99.67)));
    assert(DegreesC(100).opEquals!epsilon(DegreesF(212)));
    assert(DegreesF(100).opEquals!epsilon(DegreesC(37.77777777777777)));

    // nan property exists for float Quantities (both typed and Dynamic)
    {
        Metres nan_m = Metres.nan;
        assert(nan_m.value != nan_m.value);  // NaN != NaN

        VarQuantity nan_v = VarQuantity.nan;
        assert(nan_v.value != nan_v.value);
    }
    static assert(!__traits(compiles, Quantity!(int, ScaledUnit(Metre)).nan));

    char[32] text;
    auto exact_signed = Quantity!(long, ScaledUnit())(9_007_199_254_740_993);
    ptrdiff_t length = exact_signed.toString(text, null, null);
    assert(text[0 .. length] == "9007199254740993");
    exact_signed = Quantity!(long, ScaledUnit())(long.min);
    length = exact_signed.toString(text, null, null);
    assert(text[0 .. length] == "-9223372036854775808");
    auto exact_unsigned = Quantity!(ulong, ScaledUnit())(ulong.max);
    length = exact_unsigned.toString(text, null, null);
    assert(text[0 .. length] == "18446744073709551615");

    alias DeciAmps = Quantity!(ushort, ScaledUnit(Ampere, -1));
    DeciAmps current = DeciAmps(165);
    length = current.toString(text, null, null);
    assert(text[0 .. length] == "16.5A");
    assert(current.fromString("12.3A") == 5 && current.value == 123);
}


VarQuantity parse_quantity(const(char)[] text, size_t* bytes_taken = null) nothrow
{
    import urt.si.unit;
    import urt.conv;

    int e;
    uint base;
    size_t taken;
    long raw_value = text.parse_int_with_exponent_and_base(e, base, &taken);
    if (taken == 0)
    {
        if (bytes_taken)
            *bytes_taken = 0;
        return VarQuantity(double.nan);
    }

    // we parsed a number!
    auto r = VarQuantity(e == 0 ? raw_value : raw_value * double(base)^^e);

    if (taken < text.length)
    {
        // try and parse a unit...
        ScaledUnit su;
        float pre_scale;
        ptrdiff_t unit_taken = su.parse_unit(text[taken .. $], pre_scale, false);
        if (unit_taken > 0)
        {
            taken += unit_taken;
            r = VarQuantity(r.value * pre_scale, su);
        }
    }
    if (bytes_taken)
        *bytes_taken = taken;
    return r;
}

unittest
{
    import urt.si.unit;

    size_t taken;
    assert("10V".parse_quantity(&taken) == Volts(10) && taken == 3);
    assert("10.2e+2Wh".parse_quantity(&taken) == WattHours(1020) && taken == 9);

    VarQuantity q = "1ms".parse_quantity(&taken);
    assert(taken == 3 && q.value == 1 && q.unit == ScaledUnit(Second, -3));
    q = "1m*s".parse_quantity(&taken);
    assert(taken == 4 && q.value == 1 && q.unit == Metre * Second);
    q = "1/ms".parse_quantity(&taken);
    assert(taken == 4 && q.value == 1 && q.unit == ScaledUnit(Second, -3)^^-1);
    q = "1m^-1*s^-1".parse_quantity(&taken);
    assert(taken == 10 && q.value == 1 && q.unit == (Metre * Second)^^-1);

    q = "1km^2".parse_quantity(&taken);
    assert(taken == 5 && q.value == 1 && q.unit == Kilometre^^2);
    assert(q.normalise() == VarQuantity(1e6, ScaledUnit(Metre^^2)));
    q = "100m^2".parse_quantity(&taken);
    assert(taken == 6 && q.value == 100 && q.unit == ScaledUnit(Metre^^2));
    q = "10000m^2".parse_quantity(&taken);
    assert(taken == 8 && q.value == 10000 && q.unit == ScaledUnit(Metre^^2));

    // reciprocal units (leading '/' and ascii powers)
    q = "3/hr".parse_quantity(&taken);
    assert(taken == 4 && q.value == 3 && q.unit == Hour^^-1);
    q = "3/h".parse_quantity(&taken);
    assert(taken == 3 && q.value == 3 && q.unit == Hour^^-1);
    q = "3h^-1".parse_quantity(&taken);
    assert(taken == 5 && q.value == 3 && q.unit == Hour^^-1);
    q = "0.2/s".parse_quantity(&taken);
    assert(taken == 5 && q.value == 0.2 && q.unit == ScaledUnit(Second)^^-1);
    q = "4/min".parse_quantity(&taken);
    assert(taken == 5 && q.value == 4 && q.unit == Minute^^-1);
    assert("12/hr".parse_quantity().normalise().opEquals!1e-12(VarQuantity(12.0 / 3600, ScaledUnit(Second)^^-1)));

    // km/h is a named unit now, so it parses whole rather than being rejected
    q = "3km/h".parse_quantity(&taken);
    assert(taken == 5 && q.unit == ScaledUnits.kilometre_per_hour);
    q = "1800rpm".parse_quantity(&taken);
    assert(taken == 7 && q.value == 1800 && q.unit == ScaledUnits.revolutions_per_minute);

    // scale factors that can't combine must still reject the unit, not assert
    q = "3hr*min".parse_quantity(&taken);
    assert(taken == 1 && q.unit == ScaledUnit());

    // fromString round-trip, including unit conversion to the target scale
    Seconds sec;
    assert(sec.fromString("2min") == 4 && sec.value == 120);
    assert(sec.fromString("5V") == -1);
    VarQuantity dyn;
    assert(dyn.fromString("12/hr") == 5 && dyn.value == 12 && dyn.unit == Hour^^-1);
}


private:

ptrdiff_t format_quantity_floating(double value, ScaledUnit unit, char[] buffer)
{
    import urt.conv : format_float;

    value *= normalise_quantity_unit(unit);
    ptrdiff_t length = format_float(value, buffer);
    return append_quantity_unit(buffer, length, unit);
}

ptrdiff_t format_quantity_integer(ulong value, bool signed_value, ScaledUnit unit, char[] buffer)
{
    import urt.conv : format_float, format_int, format_uint;

    double scale = normalise_quantity_unit(unit);
    ptrdiff_t length;
    if (scale != 1)
    {
        double scaled = signed_value ? cast(long)value * scale : value * scale;
        length = format_float(scaled, buffer);
    }
    else
        length = signed_value ? format_int(cast(long)value, buffer) : format_uint(value, buffer);
    return append_quantity_unit(buffer, length, unit);
}

double normalise_quantity_unit(ref ScaledUnit unit)
{
    if (!unit.pack || !unit.siScale)
        return 1;

    int exponent = unit.exp;
    if (unit.unit.pack == 0)
    {
        if (exponent == -3)
        {
            unit = ScaledUnit(Unit(), exponent + 1);
            return 0.1;
        }
        if (exponent != -2)
        {
            double scale = unit.scale();
            unit = ScaledUnit();
            return scale;
        }
        return 1;
    }

    exponent = (exponent + 33) % 3;
    if (exponent == 0)
        return 1;
    unit = ScaledUnit(unit.unit, unit.exp + (3 - exponent));
    return exponent == 1 ? 0.01 : 0.1;
}

ptrdiff_t append_quantity_unit(char[] buffer, ptrdiff_t length, ScaledUnit unit)
{
    if (length < 0 || !unit.pack)
        return length;
    ptrdiff_t unit_length = unit.toString(buffer.ptr ? buffer.ptr[length .. buffer.length] : null, null, null);
    return unit_length < 0 ? unit_length : length + unit_length;
}

ptrdiff_t parse_quantity_floating(const(char)[] text, ScaledUnit target_unit, ScaledUnit* dynamic_unit, out double value)
{
    size_t taken;
    VarQuantity parsed = parse_quantity(text, &taken);
    if (taken == 0)
        return -1;
    if (dynamic_unit)
    {
        *dynamic_unit = parsed.unit;
        value = parsed.value;
    }
    else
    {
        if (parsed.unit.unit != target_unit.unit)
            return -1;
        value = convert_quantity_scale(parsed.value, parsed.unit, target_unit);
    }
    return taken;
}

ptrdiff_t parse_quantity_integer(const(char)[] text, ScaledUnit target_unit, ScaledUnit* dynamic_unit,
    bool signed_value, out ulong value)
{
    double parsed;
    ptrdiff_t taken = parse_quantity_floating(text, target_unit, dynamic_unit, parsed);
    if (taken >= 0)
        value = signed_value ? cast(ulong)cast(long)parsed : cast(ulong)parsed;
    return taken;
}

double convert_quantity_scale(double value, ScaledUnit from, ScaledUnit to) pure
{
    if (from == to)
        return value;
    double to_scale = to.scale!true();
    double scale = to_scale * from.scale();
    double translation = to.offset!true() + to_scale * from.offset();
    return value*scale + translation;
}
