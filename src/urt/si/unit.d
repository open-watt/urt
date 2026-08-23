module urt.si.unit;

import urt.array;
import urt.string;

nothrow @nogc:


//
// Encoding schemes:
//
//   Unit: 00000000_uuuipp_uuuipp_uuuipp_uuuipp
//     Where: uuu is the 3-bit unit type
//              i is the inverted bit (ie; n/unit, or unit^^-1)
//             pp is the exponent minus 1 (ie; exp = pp+1, unit^^exp)
//
//                This encoding scheme can map unit exponents [-4, 4]
//
//   ScaledUnit: sssssssx_uuuipp_uuuipp_uuuipp_uuuipp
//     Where: the lower 24 bits are from Unit
//
//       x = 0: ??????r0
//         r = 0: eeeeee00
//           eeeeee is a 6-bit signed exponent (ie; scale = 10^^e)
//                  the value -32 (100000) is reserved for future expansion
//         r = 1: eeeiss10
//           eee is a 3-bit signed SI exponent in steps of 3
//             i is the inverted factor bit
//            ss is a value from the PrefixFactor table
//           eee = 100: 100iss10
//             i selects forward or inverse conversion
//            ss is a scale-and-bias pair from the BiasedScaleFactor table
//               biased factors can not take an SI prefix or a power greater than one
//
//       x = 1: ieessss1
//         i is the inverted bit (ie 1/scale)
//        ee is the scaling power minus 1 (ie; exp = ee+1, scale^^exp)
//      ssss is a value from the ScaleFactor table
//


enum ScaledUnit unit(const(char)[] desc) = () { ScaledUnit r; float f; ptrdiff_t e = r.parse_unit(desc, f); assert(e > 0, "Invalid unit"); assert(f == 1, "Unit requires pre-scale"); return r; }();


// base units
enum Metre = Unit(UnitType.Length);
enum Kilogram = Unit(UnitType.Mass);
enum Second = Unit(UnitType.Time);
enum Ampere = Unit(UnitType.Current);
enum Kelvin = Unit(UnitType.Temperature);
enum Candela = Unit(UnitType.Luma);
enum Radian = Unit(UnitType.Angle);

// unscaled derived units
enum SquareMetre = Metre^^2;
enum CubicMetre = Metre^^3;
enum Newton = Kilogram * Metre / Second^^2;
enum Pascal = Newton / Metre^^2;
enum Joule = Newton * Metre;
enum Watt = Joule / Second;
enum Coulomb = Ampere * Second;
enum Volt = Watt / Ampere;
enum Ohm = Volt / Ampere;
enum Farad = Coulomb / Volt;
enum Siemens = Ohm^^-1;
enum Weber = Volt * Second;
enum Tesla = Weber / Metre^^2;
enum Henry = Weber / Ampere;
enum Lumen = Candela * Radian^^2;
enum Lux = Lumen / Metre^^2;

enum SiPrefixable;

enum ScaledUnits : ScaledUnit
{
    @("min", "mins")
    minute = ScaledUnit(Second, PrefixFactor.Minute),
    @("hr", "h", "hrs")
    hour = ScaledUnit(Second, PrefixFactor.Hour),
    @("day", "days")
    day = ScaledUnit(Second, ScaleFactor.Day),
    @("in", "'")
    inch = ScaledUnit(Metre, ScaleFactor.Inch),
    @("ft", "\"")
    foot = ScaledUnit(Metre, ScaleFactor.Foot),
    @("mi")
    mile = ScaledUnit(Metre, ScaleFactor.Mile),
    @("oz")
    ounce = ScaledUnit(Kilogram, ScaleFactor.Ounce),
    @("lb")
    pound = ScaledUnit(Kilogram, ScaleFactor.Pound),
    @("°C")
    celsius = ScaledUnit(Kelvin, BiasedScaleFactor.Celsius),
    @("°F")
    fahrenheit = ScaledUnit(Kelvin, BiasedScaleFactor.Fahrenheit),
    @("cy")
    cycle = ScaledUnit(Radian, PrefixFactor.Cycles),
    @("°", "deg")
    degree = ScaledUnit(Radian, ScaleFactor.Degrees),

    @("%")
    percent = ScaledUnit(Unit(), -2),
    @("‰")
    permille = ScaledUnit(Unit(), -3),
    @("‱")
    basis_point = ScaledUnit(Unit(), -4),
    @("ppm")
    parts_per_million = ScaledUnit(Unit(), -6),
    @("cm")
    centimetre = ScaledUnit(Metre, -2),
    @("mm")
    millimetre = ScaledUnit(Metre, -3),
    @("km")
    kilometre = ScaledUnit(Metre, 3),
    @SiPrefixable @("l")
    litre = ScaledUnit(CubicMetre, -3),
    @SiPrefixable @("g")
    gram = ScaledUnit(Kilogram, -3),
    @("mg")
    milligram = ScaledUnit(Kilogram, -6),
    @("ns")
    nanosecond = ScaledUnit(Second, -9),
    @SiPrefixable @("Hz")
    hertz = cycle / Second,
    @("kHz")
    kilohertz = ScaledUnit(hertz, SiPrefix.Kilo),
    @("MHz")
    megahertz = ScaledUnit(hertz, SiPrefix.Mega),
    @("GHz")
    gigahertz = ScaledUnit(hertz, SiPrefix.Giga),
    @("psi")
    psi = ScaledUnit(Pascal, ScaleFactor.PSI),
    @("kW")
    kilowatt = ScaledUnit(Watt, 3),
    @SiPrefixable @("Ah")
    ampere_hour = ScaledUnit(Coulomb, PrefixFactor.Hour),
    @SiPrefixable @("Wh", "VAh", "varh")
    watt_hour = ScaledUnit(Joule, PrefixFactor.Hour),
    @("kWh")
    kilowatt_hour = ScaledUnit(watt_hour, SiPrefix.Kilo),
    @("MWh")
    megawatt_hour = ScaledUnit(watt_hour, SiPrefix.Mega),
    @("GWh")
    gigawatt_hour = ScaledUnit(watt_hour, SiPrefix.Giga),

    @("m/s")
    metre_per_second = ScaledUnit(Metre / Second),
    @("m/h")
    metre_per_hour = ScaledUnit(Metre / Second, PrefixFactor.Hour, true),
    @("km/h", "kph")
    kilometre_per_hour = ScaledUnit(ScaledUnit(Metre / Second, PrefixFactor.Hour, true), SiPrefix.Kilo),
    @("rpm", "r/min", "rev/min")
    revolutions_per_minute = ScaledUnit(Radian / Second, PrefixFactor.RPM),
}

enum Minute = ScaledUnits.minute;
enum Hour = ScaledUnits.hour;
enum Day = ScaledUnits.day;
enum Inch = ScaledUnits.inch;
enum Foot = ScaledUnits.foot;
enum Mile = ScaledUnits.mile;
enum Ounce = ScaledUnits.ounce;
enum Pound = ScaledUnits.pound;
enum Celsius = ScaledUnits.celsius;
enum Fahrenheit = ScaledUnits.fahrenheit;
enum Cycle = ScaledUnits.cycle;
enum Degree = ScaledUnits.degree;
enum Percent = ScaledUnits.percent;
enum Permille = ScaledUnits.permille;
enum Centimetre = ScaledUnits.centimetre;
enum Millimetre = ScaledUnits.millimetre;
enum Kilometre = ScaledUnits.kilometre;
enum Litre = ScaledUnits.litre;
enum Gram = ScaledUnits.gram;
enum Milligram = ScaledUnits.milligram;
enum Nanosecond = ScaledUnits.nanosecond;
enum Hertz = ScaledUnits.hertz;
enum Kilohertz = ScaledUnits.kilohertz;
enum Megahertz = ScaledUnits.megahertz;
enum Gigahertz = ScaledUnits.gigahertz;
enum PSI = ScaledUnits.psi;
enum Kilowatt = ScaledUnits.kilowatt;
enum AmpereHour = ScaledUnits.ampere_hour;
enum WattHour = ScaledUnits.watt_hour;
enum KilowattHour = ScaledUnits.kilowatt_hour;
enum MegawattHour = ScaledUnits.megawatt_hour;
enum GigawattHour = ScaledUnits.gigawatt_hour;


enum UnitType : ubyte
{
    None,
    Mass,
    Length,
    Time,
    Current,
    Temperature,
    Luma,
    Angle
}

struct Unit
{
nothrow:
    // debug/ctfe helper
    string toString() pure
    {
        char[32] t = void;
        ptrdiff_t l = toString(t, null, null);
        if (l < 0)
            return "Invalid unit"; // OR JUST COULDN'T STRINGIFY!
        return t[0..l].idup;
    }

@nogc:

    uint pack;

    this(UnitType type, int e = 1) pure
    {
        debug assert(e != 0 && uint(e + 4) <= 8);
        pack = (type << 3) | (e < 0 ? 3-e : e-1);
    }

    Unit opBinary(string op)(int e) const pure
        if (op == "^^")
    {
        if (pack == 0 || e == 0)
            return Unit();
        if (pack < 0x40 && (pack & 3) == 0)
            return Unit(pack ^ (e < 0 ? 3-e : e-1));
        if (e == -1)
        {
            enum Signs = 0b000100_000100_000100_000100;

            // sign bits set for valid units
            uint valid = (pack >> 1 | (pack >> 2) | (pack >> 3)) & Signs;
            return Unit(pack ^ valid);
        }
//        if (e == 1)      // this case is highly unlikely, so consider it last
//            return this; // maybe just remove it; not worth the `if`?

        // we'll scale all the magnitudes by the exponent...
        enum Magnitude = 0b000011_000011_000011_000011;
        enum Ones      = 0b000001_000001_000001_000001;

        // one bits set for valid units
        uint valid = (pack >> 3 | (pack >> 4) | (pack >> 5)) & Ones;
        uint mags = (pack & Magnitude);

        bool neg = e < 0;
        mags += valid;
        mags *= neg ? -e : e;
        mags -= valid;

        // check for magnitude overflow
        if (mags & ~Magnitude)
            assert(false, "Invalid exponent: |e| > 4");

        if (neg)
            return Unit((pack & ~Magnitude) ^ (valid << 2) | mags);
        return Unit((pack & ~Magnitude) | mags);
    }

    Unit opBinary(string op)(Unit rh) const pure
        if (op == "*" || op == "/")
    {
        uint lp = pack;
        uint rp = rh.pack;

        if (!rp)
            return this;
        if (!lp)
        {
            static if (op == "*")
                return rh;
            else
                return rh^^-1;
        }

        uint a = lp & 0x3F;
        uint b = rp & 0x3F;

        uint r, s;
        while (true)
        {
            // we need to compound the exponents from each side on ascending order...
            if (a && (b == 0 || (a >> 3) < (b >> 3)))
            {
                r |= a << s;
                s += 6;
                lp >>= 6;
                a = lp & 0x3F;
            }
            else if (a == 0 || (b >> 3) < (a >> 3))
            {
                static if (op == "*")
                    r |= b << s;
                else
                    r |= (b ^ 4) << s;
                s += 6;
                rp >>= 6;
                b = rp & 0x3F;
            }
            else
            {
                // both sides have the same unit type so we sum the exponents...
                int e = decodeExp[a & 7];
//                int e = (a & 4) ? -(a & 3) : (a & 3);
                int be = decodeExp[b & 7];
//                int be = (b & 4) ? -(b & 3) : (b & 3);
                static if (op == "*")
                    e += be;
                else
                    e -= be;

                // the summed exponents may have cancelled out...
                if (e != 0)
                {
                    if (uint(e + 4) > 8)
                        assert(false, "Invalid exponent: |e| > 4");

                    r |= ((a & 0x38) | encodeExp[e + 4]) << s;
//                    r |= ((a & 0x38) | (e < 0 ? 3-e : e-1)) << s;
                    s += 6;
                }

                rp >>= 6, lp >>= 6;
                a = lp & 0x3F;
                b = rp & 0x3F;
            }

            if (!a && !b)
                break;
        }
        return Unit(r);
    }

    void opOpAssign(string op, T)(T rh) pure
    {
        this = this.opBinary!op(rh);
    }

    import urt.string.format : FormatArg;
    ptrdiff_t toString(char[] buffer, const(char)[], const(FormatArg)[]) const pure
    {
        assert(false, "TODO");
    }

    ptrdiff_t fromString(const(char)[] s) pure
    {
        if (s.length == 0)
        {
            pack = 0;
            return 0;
        }

        Unit r;
        size_t len = s.length;
        bool invert;
        char sep;
        while (const(char)[] unit = s.split!('/', '*')(sep))
        {
            int p = unit.take_power();
            if (p == 0)
                return -1; // invalid power

            if (const Unit* u = find_named_unit(unit))
                r *= (*u) ^^ (invert ? -p : p);
            else
            {
                assert(false, "TODO?");
            }
            if (sep == '/')
                invert = true;
        }
        this = r;
        return len;
    }

    size_t toHash() const pure
        => pack;

package:
    this(uint pack) pure
    {
        this.pack = pack;
    }
}

unittest
{
    assert(Unit(UnitType.Mass).pack       == ((UnitType.Mass   << 3) | 0));
    assert(Unit(UnitType.Length, 2).pack  == ((UnitType.Length << 3) | 1));
    assert(Unit(UnitType.Length, -2).pack == ((UnitType.Length << 3) | 5));

    assert(Metre * Unit() == Metre);
    assert(Unit() * Metre == Metre);
    assert(Unit() / Metre == Metre^^-1);
    assert(Metre * Metre^^-1 == Unit());
    assert(Cycle / Second == Hertz);
    assert(Metre^^2 * Metre == Metre^^3);
    assert((Metre^^-1)^^-1 == Metre);
    assert((Metre^^-1)^^2 == Metre^^-2);

    Unit farad = Kilogram^^-1 * Metre^^-2 * Second^^4 * Ampere^^2;
    assert(farad.pack == ((UnitType.Mass << 3)     | (4 << 0)  |
                          (UnitType.Length << 9)   | (5 << 6)  |
                          (UnitType.Time << 15)    | (3 << 12) |
                          (UnitType.Current << 21) | (1 << 18)));

    farad *= Metre / Second;
    assert(farad.pack == ((UnitType.Mass << 3)     | (4 << 0)  |
                          (UnitType.Length << 9)   | (4 << 6)  |
                          (UnitType.Time << 15)    | (2 << 12) |
                          (UnitType.Current << 21) | (1 << 18)));

    farad = farad^^-1;
    assert(farad.pack == ((UnitType.Mass << 3)     | (0 << 0)  |
                          (UnitType.Length << 9)   | (0 << 6)  |
                          (UnitType.Time << 15)    | (6 << 12) |
                          (UnitType.Current << 21) | (5 << 18)));

    // TODO: it'd be really cool to test the assert cases...
}


enum ScaleFactor : ubyte
{
    Day,
    Inch,
    Foot,
    Mile,
    Ounce,
    Pound,
    USFluidOunce,
    USGallon,
    UKFluidOunce,
    UKGallon,
    PSI,
    Degrees,
}
static assert(ScaleFactor.max < 16);

enum PrefixFactor : ubyte
{
    Hour,
    Minute,
    Cycles,
    RPM,
}

enum SiPrefix : ubyte
{
    None = 0,    // 10^^0
    Kilo,        // 10^^3
    Mega,        // 10^^6
    Giga,        // 10^^9
}

enum BiasedScaleFactor : ubyte
{
    Celsius,
    Fahrenheit,
    Reserved2,
    Reserved3,
}

struct ScaledUnit
{
nothrow:
    // debug/ctfe helper
    string toString() pure
    {
        char[32] t = void;
        ptrdiff_t l = toString(t, null, null);
        if (l < 0)
            return "Invalid unit"; // OR JUST COULDN'T STRINGIFY!
        return t[0..l].idup;
    }

@nogc:

    uint pack;

    this(Unit u, int e = 0) pure
    {
        debug assert(valid_si_exp(e), "SI exponent is outside the standard encoding");
        pack = u.pack | (e << 26);
    }

    this(Unit u, ScaleFactor sf, int e = 1) pure
    {
        pack = u.pack;

        if (e == 0)
            return;

        assert(uint(e + 4) <= 8);

        if (e < 0)
            pack |= 0x81000000 | (sf << 25) | (~e << 29);
        else
            pack |= 0x01000000 | (sf << 25) | ((e - 1) << 29);
    }

    this(Unit u, PrefixFactor factor, bool inverse = false) pure
    {
        pack = u.pack | encode_prefix_factor(factor, inverse, 0);
    }

    this(ScaledUnit base, SiPrefix prefix) pure
    {
        debug assert(base.isPrefixFactor(), "SI prefix only valid on a prefix-factor ScaledUnit");
        pack = base.unit.pack | encode_prefix_factor(base.pf(), base.factor_inv(), int(prefix));
    }

    this(Unit u, BiasedScaleFactor scaleFactor, bool inverse = false) pure
    {
        pack = u.pack | 0x82000000 | (scaleFactor << 26) | (inverse << 28);
    }

    bool siScale() const pure
        => (pack & 0x03000000) == 0;
    bool isPrefixFactor() const pure
        => (pack & 0x03000000) == 0x02000000 && (pack & 0xE0000000) != 0x80000000;
    bool isBiasedScale() const pure
        => (pack & 0xE3000000) == 0x82000000;

    int exp() const pure
        => int(pack) >> 26;

    bool inv() const pure
        => isPrefixFactor() ? factor_inv() : isBiasedScale() ? biased_inv() : pack >> 31;
    ScaleFactor sf() const pure
        => cast(ScaleFactor)((pack >> 25) & 0xF);
    PrefixFactor pf() const pure
        => cast(PrefixFactor)((pack >> 26) & 0x3);
    BiasedScaleFactor biased_factor() const pure
        => cast(BiasedScaleFactor)((pack >> 26) & 0x3);

    int prefix_exp() const pure
        => int(pack) >> 29;
    bool factor_inv() const pure
        => ((pack >> 28) & 1) != 0;
    bool biased_inv() const pure
        => ((pack >> 28) & 1) != 0;

    static uint encode_prefix_factor(PrefixFactor factor, bool inverse, int e) pure
    {
        debug assert(uint(e + 3) <= 6, "Prefix-factor exponent is outside the standard encoding");
        return ((uint(e) & 7) << 29) | (uint(inverse) << 28) | (uint(factor) << 26) | 0x02000000;
    }

    uint inverse_prefix_factor() const pure
        => encode_prefix_factor(pf(), !factor_inv(), -prefix_exp());

    uint inverse_scale() const pure
    {
        if (siScale())
            return uint(-exp() << 26);
        if (isPrefixFactor())
            return inverse_prefix_factor();
        if (isBiasedScale())
            return (pack & 0xFF000000) ^ 0x10000000;
        return (pack & 0xFF000000) ^ 0x80000000;
    }

    bool combine_prefix_factor(string op)(ScaledUnit b, out uint scale_bits) const pure
        if (op == "*" || op == "/")
    {
        if (isPrefixFactor() && b.isPrefixFactor())
        {
            if (pf() != b.pf())
                return false;
            int a = factor_inv() ? -1 : 1;
            int bb = b.factor_inv() ? -1 : 1;
            int e;
            static if (op == "*")
            {
                if (a + bb != 0)
                    return false;
                e = prefix_exp() + b.prefix_exp();
            }
            else
            {
                if (a - bb != 0)
                    return false;
                e = prefix_exp() - b.prefix_exp();
            }
            scale_bits = uint((e * 3) << 26);
            return true;
        }

        if (!siScale() && !b.siScale())
            return false;

        ScaledUnit r = isPrefixFactor() ? this : b;
        int si_e = isPrefixFactor() ? b.exp() : exp();
        if (si_e % 3 != 0)
            return false;

        int e;
        bool inverse;
        static if (op == "*")
        {
            e = r.prefix_exp() + si_e / 3;
            inverse = r.factor_inv();
        }
        else
        {
            if (isPrefixFactor())
            {
                e = r.prefix_exp() - si_e / 3;
                inverse = r.factor_inv();
            }
            else
            {
                e = si_e / 3 - r.prefix_exp();
                inverse = !r.factor_inv();
            }
        }
        if (uint(e + 3) > 6)
            return false;
        scale_bits = encode_prefix_factor(r.pf(), inverse, e);
        return true;
    }

    bool canCompare(ScaledUnit b) const pure
    {
        return unit == b.unit;
    }

    double scale(bool invert = false)() const pure
    {
        if (siScale)
        {
            int e = exp();
            if (invert)
                e = -e;
            if (uint(e + 9) < 19)
                return sciScaleFactor[e + 9];
            return 10^^e;
        }

        if (isPrefixFactor())
        {
            int e = prefix_exp();
            bool inverse = factor_inv();
            if (invert)
            {
                e = -e;
                inverse = !inverse;
            }
            return prefixFactorScale[inverse][pf()] * sciScaleFactor[e * 3 + 9];
        }

        if (isBiasedScale())
        {
            uint index = uint(biased_factor()) | (uint(biased_inv() ^ invert) << 2);
            return biasedScaleFactor[index];
        }

        ScaleFactor f = sf();
        uint inv = (pack >> 31) ^ invert;
        double s = scaleFactor[inv][f];
        for (uint i = ((pack >> 29) & 3); i > 0; --i)
            s *= s;
        return s;
    }
    double offset(bool inv = false)() const pure
    {
        if (!isBiasedScale())
            return 0;
        uint index = uint(biased_factor()) | (uint(biased_inv() ^ inv) << 2);
        return biasedOffsets[index];
    }

    Unit unit() const pure
        => Unit(pack & 0xFFFFFF);

    ScaledUnit opBinary(string op)(int e) const pure
        if (op == "^^")
    {
        if (pack == 0 || e == 0)
            return ScaledUnit();
        if (e == 1)
            return this;

        uint u = (unit^^e).pack;
        if (e == -1)
        {
            if (siScale())
                return ScaledUnit(u | (-exp() << 26));
            if (isPrefixFactor())
                return ScaledUnit(u | inverse_prefix_factor());
            if (isBiasedScale())
                return ScaledUnit(u | (pack & 0xFF000000) ^ 0x10000000);
            return ScaledUnit(u | (pack & 0xFF000000) ^ 0x80000000);
        }

        if (siScale())
        {
            long scale_exp = long(exp()) * e;
            assert(valid_si_exp(scale_exp), "SI exponent is outside the standard encoding");
            return ScaledUnit(u | (cast(int)scale_exp << 26));
        }

        assert(!isBiasedScale(), "Biased scale factors can't be exponentiated");

        assert(!isPrefixFactor(), "Prefix-factor units only support exponents of ±1");

        int f = decodeExp[pack >> 29] * e;

        if (uint(f + 4) > 8)
            assert(false, "Invalid exponent: |e| > 4");

        return ScaledUnit(u | (pack & 0x1F000000) | (encodeExp[f + 4] << 29));
    }

    ScaledUnit opBinary(string op)(Unit b) const pure
        if (op == "*" || op == "/")
    {
        assert(!isBiasedScale() || b.pack == 0, "Biased scale factors can't be combined");
        return ScaledUnit(unit.opBinary!op(b).pack | (pack & 0xFF000000));
    }

    ScaledUnit opBinaryRight(string op)(Unit b) const pure
        if (op == "*" || op == "/")
    {
        assert(!isBiasedScale() || b.pack == 0, "Biased scale factors can't be combined");
        static if (op == "*")
            return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000));
        else
        {
            if (siScale())
                return ScaledUnit(b.opBinary!op(unit).pack | (-(int(pack) >> 26) << 26));
            if (isPrefixFactor())
                return ScaledUnit(b.opBinary!op(unit).pack | inverse_prefix_factor());
            if (isBiasedScale())
                return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000) ^ 0x10000000);
            return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000) ^ 0x80000000);
        }
    }

    ScaledUnit opBinary(string op)(ScaledUnit b) const pure
        if (op == "*" || op == "/")
    {
        uint u = unit.opBinary!op(b.unit).pack;

        assert(!isBiasedScale() || b.pack == 0, "Biased scale factors can't be combined");
        assert(!b.isBiasedScale() || pack == 0, "Biased scale factors can't be combined");

        ubyte f = pack >> 24;
        ubyte bf = b.pack >> 24;

        if (f == 0) // if LHS is identity
        {
            static if (op == "*")
                return ScaledUnit(u | (bf << 24));
            else
                return ScaledUnit(u | b.inverse_scale());
        }
        else if (bf == 0) // if RHS is identity
            return ScaledUnit(u | (pack & 0xFF000000));

        if (siScale() && b.siScale())
        {
            static if (op == "*")
                long scale_exp = long(exp()) + b.exp();
            else
                long scale_exp = long(exp()) - b.exp();
            assert(valid_si_exp(scale_exp), "SI exponent is outside the standard encoding");
            return ScaledUnit(u | (cast(int)scale_exp << 26));
        }

        if (isPrefixFactor() || b.isPrefixFactor())
        {
            uint scale_bits;
            bool valid = combine_prefix_factor!op(b, scale_bits);
            assert(valid, "Scales don't fit the prefix-factor encoding");
            return ScaledUnit(u | scale_bits);
        }

        assert(!siScale() && !b.siScale(), "Can't combine SI and arbitrary units");
        assert(!isBiasedScale() && !b.isBiasedScale(), "Biased scale factors can't be multiplied");
        assert(sf() == b.sf(), "Can't combine mismatching arbitrary units");

        static if (op == "*")
            int e = decodeExp[f >> 5] + decodeExp[bf >> 5];
        else
            int e = decodeExp[f >> 5] - decodeExp[bf >> 5];

        if (e == 0)
            return ScaledUnit(u);

        if (uint(e + 4) > 8)
            assert(false, "Invalid exponent: |e| > 4");

        return ScaledUnit(u | (pack & 0x1F000000) | (encodeExp[e + 4] << 29));
    }

    // parse_unit() checks scale representability before invoking these operators.
    bool can_pow(int e) const pure
    {
        if (pack == 0 || uint(e + 1) <= 2)
            return true;
        if (siScale())
            return valid_si_exp(long(exp()) * e);
        if (isBiasedScale() || isPrefixFactor())
            return false;
        return uint(decodeExp[pack >> 29] * e + 4) <= 8;
    }

    bool can_combine(string op)(ScaledUnit b) const pure
        if (op == "*" || op == "/")
    {
        if ((isBiasedScale() && b.pack != 0) || (b.isBiasedScale() && pack != 0))
            return false;

        ubyte f = pack >> 24;
        ubyte bf = b.pack >> 24;
        if (f == 0 || bf == 0)
            return true;
        if (siScale() && b.siScale())
        {
            static if (op == "*")
                long scale_exp = long(exp()) + b.exp();
            else
                long scale_exp = long(exp()) - b.exp();
            return valid_si_exp(scale_exp);
        }
        if (isPrefixFactor() || b.isPrefixFactor())
        {
            uint scale_bits;
            return combine_prefix_factor!op(b, scale_bits);
        }
        if (siScale() != b.siScale())
            return false;
        if (isBiasedScale() || b.isBiasedScale())
            return false;
        if (sf() != b.sf())
            return false;
        static if (op == "*")
            int e = decodeExp[f >> 5] + decodeExp[bf >> 5];
        else
            int e = decodeExp[f >> 5] - decodeExp[bf >> 5];
        return uint(e + 4) <= 8;
    }

    void opOpAssign(string op, T)(T rh) pure
    {
        this = this.opBinary!op(rh);
    }

    bool opEquals(ScaledUnit rh) const pure
        => pack == rh.pack;

    bool opEquals(Unit rh) const pure
        => (pack & 0xFF000000) ? false : unit == rh;

    alias parseUnit = parse_unit; // TODO: DELETE ME!!!
    ptrdiff_t parse_unit(const(char)[] s, out float pre_scale, bool allow_unit_scale = true) pure
    {
        import urt.conv : parse_uint_with_exponent;

        pre_scale = 1;

        if (s.length == 0)
        {
            pack = 0;
            return 0;
        }

        size_t len = s.length;
        if (s[0] == '-')
        {
            if (s.length == 1)
                return -1;
            pre_scale = -1;
            s = s[1 .. $];
        }

        size_t spelling_index = find_scaled_unit_spelling(s);
        if (spelling_index < g_unit_spellings.length)
        {
            this = scaled_unit_from_spelling(spelling_index);
            return len;
        }

        ScaledUnit r;

        bool combine(ScaledUnit t, int q)
        {
            if (!t.can_pow(q))
                return false;
            ScaledUnit x = t ^^ q;
            if (!r.can_combine!"*"(x))
                return false;
            r *= x;
            return true;
        }

        bool invert;
        bool leading = true;
        char sep;
        while (const(char)[] term = s.split!(['/', '*'], false, false)(&sep))
        {
            if (term.length == 0 && leading && sep == '/')
            {
                // a leading '/' opens a reciprocal unit, like "/s" (per-second)
                leading = false;
                invert = true;
                continue;
            }
            leading = false;

            int p = term.take_power();
            if (p == 0)
                return -1; // invalid exponent
            if (term.length == 0)
                return -1;

            size_t offset = 0;

            // parse the scale factor
            int e = 0;
            if (term[0].is_numeric)
            {
                if (!allow_unit_scale)
                    return -1; // no numeric scale factor allowed
                ulong sf = term.parse_uint_with_exponent(e, &offset);
                pre_scale *= sf;
            }

            if (offset == term.length)
            {
                if (!combine(ScaledUnit(Unit(), e), 1))
                    return -1;
            }
            else if (const Unit* u = find_named_unit(term[offset .. $]))
            {
                // prefer folding the decimal exponent into the unit; records then
                // stay integral instead of carrying a runtime scale
                if (!valid_si_exp(e) || !combine(ScaledUnit(*u, e), invert ? -p : p))
                {
                    if (!combine(ScaledUnit(*u), invert ? -p : p))
                        return -1;
                    pre_scale *= 10.0^^e;
                }
            }
            else if ((spelling_index = find_scaled_unit_spelling(term[offset .. $])) < g_unit_spellings.length)
            {
                if (!combine(scaled_unit_from_spelling(spelling_index), invert ? -p : p))
                    return -1;
                pre_scale *= 10.0^^e;
            }
            else
            {
                // try and parse SI prefix...
                switch (term[offset])
                {
                    case 'Y':   e += 24;   ++offset;    break;
                    case 'R':   e += 27;   ++offset;    break;
                    case 'Q':   e += 30;   ++offset;    break;
                    case 'Z':   e += 21;   ++offset;    break;
                    case 'E':   e += 18;   ++offset;    break;
                    case 'P':   e += 15;   ++offset;    break;
                    case 'T':   e += 12;   ++offset;    break;
                    case 'G':   e += 9;    ++offset;    break;
                    case 'M':   e += 6;    ++offset;    break;
                    case 'k':   e += 3;    ++offset;    break;
                    case 'h':   e += 2;    ++offset;    break;
                    case 'c':   e -= 2;    ++offset;    break;
                    case 'u':   e -= 6;    ++offset;    break;
                    case 'n':   e -= 9;    ++offset;    break;
                    case 'p':   e -= 12;   ++offset;    break;
                    case 'f':   e -= 15;   ++offset;    break;
                    case 'a':   e -= 18;   ++offset;    break;
                    case 'z':   e -= 21;   ++offset;    break;
                    case 'y':   e -= 24;   ++offset;    break;
                    case 'r':   e -= 27;   ++offset;    break;
                    case 'q':   e -= 30;   ++offset;    break;
                    case 'm':
                        // can confuse with metres... so gotta check...
                        if (offset + 1 < term.length)
                            e -= 3, ++offset;
                        break;
                    case 'd':
                        if (offset + 1 < term.length && term[offset + 1] == 'a')
                        {
                            e += 1, offset += 2;
                            break;
                        }
                        e -= 1, ++offset;
                        break;
                    default:
                        if (offset + "µ".length < term.length && term[offset .. offset + "µ".length] == "µ")
                            e -= 6, offset += "µ".length;
                        break;
                }
                if (offset == term.length)
                    return -1;

                term = term[offset .. $];
                if (const Unit* u = find_named_unit(term))
                {
                    if (term == "kg")
                    {
                        // we alrady parsed the 'k', so this string must have been "kkg", which is nonsense
                        return -1;
                    }
                    if (!combine(ScaledUnit(*u, e), invert ? -p : p))
                        return -1;
                }
                else if ((spelling_index = find_scaled_unit_spelling(term, true)) < g_unit_spellings.length)
                {
                    ScaledUnit su = scaled_unit_from_spelling(spelling_index);
                    if (su.siScale())
                    {
                        if (!combine(ScaledUnit(su.unit, su.exp + e), invert ? -p : p))
                            return -1;
                    }
                    else
                    {
                        int prefix = su.prefix_exp() + e / 3;
                        if (su.isPrefixFactor() && e % 3 == 0 && uint(prefix + 3) <= 6)
                        {
                            ScaledUnit prefixed = ScaledUnit(su.unit.pack | encode_prefix_factor(su.pf(), su.factor_inv(), prefix));
                            if (!combine(prefixed, invert ? -p : p))
                                return -1;
                        }
                        else
                        {
                            if (!combine(su, invert ? -p : p))
                                return -1;
                            pre_scale *= 10.0^^e;
                        }
                    }
                }
                else
                    return -1; // string was not taken?
            }

            if (sep == '/')
                invert = true;
        }
        this = r;
        return len;
    }

    import urt.string.format : FormatArg;
    ptrdiff_t format_unit(char[] buffer, out float pre_scale, bool allow_unit_scale = true) const pure
    {
        assert(allow_unit_scale == true, "TODO: support for no-scale formatting (require pre-scale)");
        pre_scale = 1;

        if (const(char)[] spelling = scaled_unit_spelling(this))
        {
            if (buffer.ptr)
            {
                if (buffer.length < spelling.length)
                    return -1;
                buffer[0 .. spelling.length] = spelling[];
            }
            return spelling.length;
        }

        if (!unit.pack)
        {
            if (siScale && exp == -2)
            {
                if (buffer.ptr)
                {
                    if (buffer.length == 0)
                        return -1;
                    buffer[0] = '%';
                }
                return 1;
            }
            else if (siScale && exp == -3)
            {
                enum pm_len = "‰".length;
                if (buffer.ptr)
                {
                    if (buffer.length < pm_len)
                        return -1;
                    buffer[0..pm_len] = "‰";
                }
                return pm_len;
            }
            else
                return -1; // a bare scale has no unit spelling; refuse rather than abort
        }

        size_t len = 0;
        if (siScale)
        {
            if (const string* name = find_unit_name(unit))
            {
                const(char)[] spelling = *name;
                int scale_exp = exp;
                if (unit == Kilogram && exp != 0)
                {
                    spelling = "g";
                    scale_exp += 3;
                }
                ptrdiff_t l = format_si_scale(scale_exp, buffer);
                if (l < 0)
                    return -1;
                len = l;
                if (buffer.ptr)
                {
                    if (buffer.length < len + spelling.length)
                        return -1;
                    buffer[len .. len + spelling.length] = spelling[];
                }
                len += spelling.length;
            }
            else if (const string* name = find_unit_name(unit ^^ -1))
            {
                const(char)[] spelling = *name;
                int scale_exp = -exp;
                if ((unit ^^ -1) == Kilogram && exp != 0)
                {
                    spelling = "g";
                    scale_exp += 3;
                }
                if (buffer.ptr)
                {
                    if (buffer.length == 0)
                        return -1;
                    buffer[0] = '/';
                }
                ptrdiff_t l = format_si_scale(scale_exp, buffer.ptr ? buffer[1 .. $] : null);
                if (l < 0)
                    return -1;
                len = 1 + l;
                if (buffer.ptr)
                {
                    if (buffer.length < len + spelling.length)
                        return -1;
                    buffer[len .. len + spelling.length] = spelling[];
                }
                len += spelling.length;
            }
            else
            {
                return synth_unit_name(unit, buffer, exp);
            }
        }
        else
        {
            if (const(char)[] spelling = scaled_unit_spelling(this ^^ -1))
            {
                if (spelling.findFirst('/') < spelling.length || spelling.findFirst('*') < spelling.length)
                    return -1;
                if (buffer.ptr)
                {
                    if (buffer.length < 1 + spelling.length)
                        return -1;
                    buffer[0] = '/';
                    buffer[1 .. 1 + spelling.length] = spelling[];
                }
                len = 1 + spelling.length;
            }
            else
                return -1;
        }
        return len;
    }

    ptrdiff_t toString(char[] buffer, const(char)[], const(FormatArg)[]) const pure
    {
        float pre_scale;
        ptrdiff_t r = format_unit(buffer, pre_scale, true);
        if (pre_scale != 1)
            return -1;
        return r;
    }

    ptrdiff_t fromString(const(char)[] s) pure
    {
        float scale;
        ptrdiff_t r = parse_unit(s, scale);
        if (scale != 1)
            return -1;
        return r;
    }

    size_t toHash() const pure
        => pack;

    version (Windows)
    {
        auto __debugOverview()
        {
            import urt.mem;
            char[] buffer = debug_alloc!char(32);
            ptrdiff_t len = toString(buffer, null, null);
            if (len < 0)
            {
                buffer[0 .. "Invalid unit".length] = "Invalid unit";
                len = "Invalid unit".length;
            }
            return buffer[0 .. len];
        }
    }

package:
    this(uint pack) pure
    {
        this.pack = pack;
    }
}

unittest
{
    assert(ScaledUnit(Metre) * ScaledUnit(Metre) == ScaledUnit(Metre^^2));
    assert(ScaledUnit(Metre) / ScaledUnit(Metre) == ScaledUnit());

    // si scale
    assert(Kilometre * ScaledUnit() == Kilometre);
    assert(Kilometre / ScaledUnit() == Kilometre);
    assert(ScaledUnit() * Kilometre == Kilometre);
    assert(ScaledUnit() / Kilometre == Kilometre^^-1);

    assert(Metre * Kilometre == ScaledUnit(Metre^^2, 3));
    assert(Metre / Kilometre == ScaledUnit(Unit(), -3));
    assert(Metre * Kilometre^^-1 == Metre / Kilometre);
    assert(Kilometre * Metre == ScaledUnit(Metre^^2, 3));
    assert(Kilometre / Metre == ScaledUnit(Unit(), 3));
    assert(Kilometre * Kilometre == Kilometre^^2);
    assert(Kilometre / Kilometre == ScaledUnit());
    assert(Kilometre^^2 == ScaledUnit(Metre^^2, 6));
    assert((Kilometre^^2)^^-2 == ScaledUnit(Metre^^-4, -12));

    // arbitrary scale
    assert(Inch * ScaledUnit() == Inch);
    assert(Inch / ScaledUnit() == Inch);
    assert(ScaledUnit() * Inch == Inch);
    assert(ScaledUnit() / Inch == Inch^^-1);

    assert(Inch * Inch == ScaledUnit(Metre^^2, ScaleFactor.Inch, 2));
    assert(Inch / Inch == ScaledUnit());
    assert(Inch * Inch^^-1 == ScaledUnit());
    assert(Inch^^2 * Inch == Inch^^3);
    assert((Inch^^2)^^-2 == ScaledUnit(Metre^^-4, ScaleFactor.Inch, -4));

    assert(Metre * Inch == ScaledUnit(Metre^^2, ScaleFactor.Inch));
    assert(Metre / Inch == ScaledUnit(Unit(), ScaleFactor.Inch, -1));

    assert(WattHour.unit == Joule);

    assert((Hour.pack & 0xFF000000) == 0x02000000);
    assert((Minute.pack & 0xFF000000) == 0x06000000);
    assert((Cycle.pack & 0xFF000000) == 0x0A000000);
    assert((ScaledUnits.revolutions_per_minute.pack & 0xFF000000) == 0x0E000000);
    assert(Celsius.isBiasedScale() && Celsius.biased_factor() == BiasedScaleFactor.Celsius);
    assert(Fahrenheit.isBiasedScale() && Fahrenheit.biased_factor() == BiasedScaleFactor.Fahrenheit);

    assert(WattHour.scale() == 3600.0);
    assert(KilowattHour.scale() == 3600.0 * 1000);
    assert(MegawattHour.scale() == 3600.0 * 1e6);
    assert(GigawattHour.scale() == 3600.0 * 1e9);

    assert((WattHour^^-1).scale() == 1.0 / 3600);
    assert((KilowattHour^^-1).scale() == 1.0 / (3600.0 * 1000));
    assert((KilowattHour.pack & 0xFF000000) == 0x22000000);
    assert(((KilowattHour^^-1).pack & 0xFF000000) == 0xF2000000);

    // Hertz family (Cycles scale factor): kHz/MHz/GHz scale = Hz scale × prefix
    assert(Kilohertz.scale() == Hertz.scale() * 1e3);
    assert(Megahertz.scale() == Hertz.scale() * 1e6);
    assert(Gigahertz.scale() == Hertz.scale() * 1e9);
    assert((Kilohertz^^-1).scale() == 1.0 / (Hertz.scale() * 1e3));

    // ascii unit powers
    const(char)[] pow_s = "m^2";
    assert(pow_s.take_power() == 2 && pow_s == "m");
    pow_s = "s^-1";
    assert(pow_s.take_power() == -1 && pow_s == "s");
    pow_s = "s^-5";
    assert(pow_s.take_power() == 0);

    // parse: leading '/' reciprocals; unrepresentable scale combinations reject rather than assert
    ScaledUnit su;
    float pre;
    assert(su.parse_unit("/hr", pre) == 3 && su == Hour^^-1 && pre == 1);
    assert(su.parse_unit("/s", pre) == 2 && su == ScaledUnit(Second)^^-1);
    // exact spellings only: a prefix match would swallow "km/hour" as "km/h"
    assert(su.parse_unit("km/h", pre) == 4 && su == ScaledUnits.kilometre_per_hour);
    assert(su.parse_unit("kph", pre) == 3 && su == ScaledUnits.kilometre_per_hour);
    assert(su.parse_unit("m/s", pre) == 3 && su == ScaledUnits.metre_per_second);
    assert(su.parse_unit("m/h", pre) == 3 && su == ScaledUnits.metre_per_hour);
    assert(su.parse_unit("rpm", pre) == 3 && su == ScaledUnits.revolutions_per_minute);
    assert(su.parse_unit("r/min", pre) == 5 && su == ScaledUnits.revolutions_per_minute);
    assert(su.parse_unit("rev/min", pre) == 7 && su == ScaledUnits.revolutions_per_minute);
    assert(su.parse_unit("l/min", pre) == 5 && su == Litre / Minute && pre == 1);
    assert(su.parse_unit("km/hour", pre) == -1);
    assert(su.parse_unit("-km/h", pre) == 5 && pre == -1 && su == ScaledUnits.kilometre_per_hour);
    assert(su.parse_unit("ms", pre) == 2 && su == ScaledUnit(Second, -3) && pre == 1);
    assert(su.parse_unit("m*s", pre) == 3 && su == Metre * Second && pre == 1);
    assert(su.parse_unit("/ms", pre) == 3 && su == ScaledUnit(Second, -3)^^-1 && pre == 1);
    assert(su.scale() == 1e3 && su != Kilohertz);
    assert(su.parse_unit("m^-1*s^-1", pre) == 9 && su == (Metre * Second)^^-1 && pre == 1);
    assert(ScaledUnits.kilometre_per_hour.scale() == 1000.0 / 3600);
    assert((ScaledUnits.kilometre_per_hour^^-1).scale() == 3600.0 / 1000);
    assert(Kilometre / Hour == ScaledUnits.kilometre_per_hour);
    assert((ScaledUnits.kilometre_per_hour.pack & 0xFF000000) == 0x32000000);
    assert(((ScaledUnits.kilometre_per_hour^^-1).pack & 0xFF000000) == 0xE2000000);
    assert(fabs(ScaledUnits.revolutions_per_minute.scale() - 2*PI/60) < 1e-15);

    // formatting is exact and must parse back to the same unit
    static void round_trip(ScaledUnit u, const(char)[] expect)
    {
        char[64] b = void;
        ptrdiff_t l = u.toString(b[], null, null);
        assert(l > 0 && b[0 .. l] == expect, "unexpected spelling");
        ScaledUnit back; float ps;
        assert(back.parse_unit(b[0 .. l], ps) == l, "spelling must parse back");
        assert(ps == 1 && back == u, "round trip must preserve the unit");
    }
    round_trip(ScaledUnits.kilometre_per_hour, "km/h");
    round_trip(ScaledUnits.metre_per_second, "m/s");
    round_trip(ScaledUnits.metre_per_hour, "m/h");
    round_trip(ScaledUnits.revolutions_per_minute, "rpm");
    round_trip(ScaledUnit(Radian), "rad");
    round_trip(ScaledUnit(Pascal), "Pa");
    round_trip(ScaledUnit(Candela), "cd");
    round_trip(ScaledUnit(Tesla), "T");
    round_trip(ScaledUnit(Pascal, 3), "kPa");
    round_trip(ScaledUnit(Candela, -2), "ccd");
    round_trip(ScaledUnit(Tesla, 12), "TT");
    round_trip(ScaledUnit(Radian, -27), "rrad");
    round_trip(ScaledUnit(Second^^-1, -3), "/ks");
    round_trip(ScaledUnit(Kilogram, 3), "Mg");
    round_trip(ScaledUnit(Kilogram^^-1, -3), "/Mg");
    round_trip(ScaledUnit(Metre^^4), "m⁴");
    round_trip(Kilometre^^2, "km²");
    round_trip(ScaledUnit(Second, -3), "ms");
    round_trip(ScaledUnit(Metre * Second), "m*s");
    round_trip(ScaledUnit(Second, -3)^^-1, "/ms");
    round_trip(ScaledUnit((Metre * Second)^^-1), "/m*s");
    assert((Kilometre^^2).scale() == 1e6);
    assert(su.parse_unit("km^2", pre) == 4 && su == Kilometre^^2 && pre == 1);
    assert(!ScaledUnit(Metre, 24).can_pow(2));
    assert(!ScaledUnit(Metre, 24).can_combine!"*"(ScaledUnit(Second, 24)));
    {
        char[16] b = void;
        assert(ScaledUnit(Metre^^2, 3).toString(b[], null, null) < 0);
    }
    {
        ScaledUnit t; float ps;
        assert(t.parse_unit("kg/m*s", ps) > 0);
        round_trip(t, "kg/m*s");
        assert(t.parse_unit("g/s", ps) > 0);
        round_trip(t, "g/s");
    }
    {
        char[64] b = void;
        assert((ScaledUnits.kilometre_per_hour^^-1).toString(b[], null, null) < 0);
    }
    foreach (spelling; ["/min", "m/s"])
    {
        ScaledUnit t; float pr = 1;
        assert(t.parse_unit(spelling, pr) > 0, "spelling must parse");
        char[64] fb = void;
        assert(t.toString(fb[], null, null) >= 0, "unit must format");
    }
    assert(su.parse_unit("hr*min", pre) == -1);
    assert(su.parse_unit("Wh^2", pre) == -1);
    assert(su.parse_unit("°C*m", pre) == -1);

    // format: reciprocal of a nameable unit renders as "/name"
    char[16] fmt_buf;
    assert((Hour^^-1).format_unit(fmt_buf[], pre) == 3 && fmt_buf[0..3] == "/hr" && pre == 1);
    assert((ScaledUnit(Second)^^-1).format_unit(fmt_buf[], pre) == 2 && fmt_buf[0..2] == "/s");

    foreach (i, entry; g_unit_spellings)
    {
        const(char)[] spelling = scaled_unit_spelling_text(entry);
        assert(find_scaled_unit_spelling(spelling) == i);
        if (i)
            assert(uni_compare(scaled_unit_spelling_text(g_unit_spellings[i - 1]), spelling) < 0);
    }
    foreach (i, unit; g_units)
    {
        size_t spelling_index = g_canonical_string[i];
        assert(scaled_unit_from_spelling(spelling_index) == unit);
        assert(scaled_unit_spelling(unit) == scaled_unit_spelling_text(g_unit_spellings[spelling_index]));
    }
}


private:

import urt.algorithm : binary_search, qsort;
import urt.math : PI, fabs;
import urt.string.uni : uni_compare;

immutable byte[8] decodeExp = [ 1, 2, 3, 4, -1, -2, -3, -4 ];
immutable ubyte[9] encodeExp = [ 7, 6, 5, 4, 0, 0, 1, 2, 3 ];

immutable double[19] sciScaleFactor = [ 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9 ];

immutable double[16][2] scaleFactor = [ [
    86400,      // Day
    0.0254,     // Inch
    0.3048,     // Foot
    1609.344,   // Mile
    453.59237 / 16, // Ounce
    453.59237,  // Pound
    3.785411784 / 128, // USFluidOunce
    3.785411784, // USGallon
    4.54609 / 160, // UKFluidOunce
    4.54609,    // UKGallon
    6894.7572931683, // PSI => 4.4482216152605/(0.0254*0.0254)
    PI/180,     // Degrees
    double.nan,
    double.nan,
    double.nan,
    double.nan
], [
    1/86400.0,  // Day
    1/0.0254,   // Inch
    1/0.3048,   // Foot
    1/1609.344, // Mile
    16/453.59237, // Ounce
    1/453.59237, // Pound
    128/3.785411784, // USFluidOunce
    1/3.785411784, // USGallon
    160/4.54609, // UKFluidOunce
    1/4.54609,  // UKGallon
    1/6894.7572931683, // PSI
    180/PI,     // Degrees
    double.nan,
    double.nan,
    double.nan,
    double.nan
] ];

immutable double[4][2] prefixFactorScale = [ [
    3600,
    60,
    2*PI,
    2*PI/60,
], [
    1/3600.0,
    1/60.0,
    1/(2*PI),
    60/(2*PI),
] ];

immutable double[8] biasedScaleFactor = [
    1,
    5.0/9,
    double.nan,
    double.nan,

    1,
    9.0/5,
    double.nan,
    double.nan,
];

immutable double[8] biasedOffsets = [
    273.15,
    (-32.0*5)/9 + 273.15,
    double.nan,
    double.nan,

    -273.15,
    (-273.15*9)/5 + 32,
    double.nan,
    double.nan,
];

struct ScaledUnitSpelling
{
    ushort spelling_offset;
    ubyte unit_offset;
    bool is_prefixable;
}

static assert(ScaledUnitSpelling.sizeof == 4);

align(2) immutable char[packed_scaled_unit_spelling_strings.cache.length] g_spelling_strings = packed_scaled_unit_spelling_strings.cache;
immutable ScaledUnit[sorted_scaled_units.length] g_units = sorted_scaled_units;
immutable ScaledUnitSpelling[sorted_scaled_unit_spelling_specs.length] g_unit_spellings = scaled_unit_lookup_tables.spellings;
immutable ubyte[sorted_scaled_units.length] g_canonical_string = scaled_unit_lookup_tables.canonical;

enum ScaledUnitSpellingFlags : ubyte
{
    canonical = 1,
    si_prefixable = 2,
}

struct ScaledUnitSpellingSpec
{
    ScaledUnit unit;
    string spelling;
    ubyte flags;
}

enum scaled_unit_spelling_count = () {
    size_t count;
    static foreach (name; __traits(allMembers, ScaledUnits))
    {{
        alias member = __traits(getMember, ScaledUnits, name);
        static foreach (attribute; __traits(getAttributes, member))
            static if (is(typeof(attribute) == string))
                ++count;
    }}
    return count;
}();

enum sorted_scaled_unit_spelling_specs = () {
    ScaledUnitSpellingSpec[scaled_unit_spelling_count] specs;
    size_t index;
    static foreach (name; __traits(allMembers, ScaledUnits))
    {{
        alias member = __traits(getMember, ScaledUnits, name);
        bool si_prefixable;
        static foreach (attribute; __traits(getAttributes, member))
            static if (__traits(isSame, attribute, SiPrefixable))
                si_prefixable = true;

        bool canonical = true;
        static foreach (attribute; __traits(getAttributes, member))
        {
            static if (is(typeof(attribute) == string))
            {
                specs[index++] = ScaledUnitSpellingSpec(member, attribute, (canonical ? ScaledUnitSpellingFlags.canonical : 0) | (si_prefixable ? ScaledUnitSpellingFlags.si_prefixable : 0));
                canonical = false;
            }
        }
    }}
    specs.qsort!((ref a, ref b) => uni_compare(a.spelling, b.spelling));
    foreach (i; 1 .. specs.length)
        assert(specs[i - 1].spelling != specs[i].spelling, "Duplicate scaled unit spelling");
    return specs;
}();

enum scaled_unit_spelling_texts = () {
    string[sorted_scaled_unit_spelling_specs.length] spellings;
    foreach (i, spec; sorted_scaled_unit_spelling_specs)
        spellings[i] = spec.spelling;
    return spellings;
}();

enum sorted_scaled_units = () {
    ScaledUnit[__traits(allMembers, ScaledUnits).length] units;
    static foreach (i, name; __traits(allMembers, ScaledUnits))
        units[i] = __traits(getMember, ScaledUnits, name);
    units.qsort!((ref a, ref b) => a.pack < b.pack ? -1 : a.pack > b.pack ? 1 : 0);
    foreach (i; 1 .. units.length)
        assert(units[i - 1] != units[i], "Duplicate scaled unit value");
    return units;
}();

static assert(sorted_scaled_unit_spelling_specs.length <= ubyte.max);
static assert(sorted_scaled_units.length <= ubyte.max);

enum packed_scaled_unit_spelling_strings = make_table!(scaled_unit_spelling_texts, false);

struct ScaledUnitLookupTables
{
    ScaledUnitSpelling[sorted_scaled_unit_spelling_specs.length] spellings;
    ubyte[sorted_scaled_units.length] canonical;
}

enum scaled_unit_lookup_tables = () {
    ScaledUnitLookupTables tables;
    tables.canonical[] = ubyte.max;
    foreach (i, spec; sorted_scaled_unit_spelling_specs)
    {
        size_t spelling_offset = cast(size_t)packed_scaled_unit_spelling_strings.offsets[i] << packed_scaled_unit_spelling_strings.offset_shift;
        assert(spelling_offset <= ushort.max);

        size_t unit_offset = size_t.max;
        foreach (j, unit; sorted_scaled_units)
            if (unit == spec.unit)
            {
                unit_offset = j;
                break;
            }
        assert(unit_offset != size_t.max);

        tables.spellings[i] = ScaledUnitSpelling(cast(ushort)spelling_offset, cast(ubyte)unit_offset, (spec.flags & ScaledUnitSpellingFlags.si_prefixable) != 0);
        if (spec.flags & ScaledUnitSpellingFlags.canonical)
        {
            assert(tables.canonical[unit_offset] == ubyte.max);
            tables.canonical[unit_offset] = cast(ubyte)i;
        }
    }
    foreach (index; tables.canonical)
        assert(index != ubyte.max);
    return tables;
}();

bool valid_si_exp(long e) pure
    => e >= -31 && e <= 31;

size_t find_scaled_unit_spelling(const(char)[] spelling, bool require_si_prefix = false) pure nothrow @nogc
{
    size_t index = binary_search!scaled_unit_spelling_compare(g_unit_spellings[], spelling);
    if (index == g_unit_spellings.length || (require_si_prefix && !g_unit_spellings[index].is_prefixable))
        return g_unit_spellings.length;
    return index;
}

int scaled_unit_spelling_compare(const ScaledUnitSpelling entry, const(char)[] spelling) pure nothrow @nogc
{
    return uni_compare(scaled_unit_spelling_text(entry), spelling);
}

int scaled_unit_compare(const ScaledUnit a, const ScaledUnit b) pure nothrow @nogc
{
    return a.pack < b.pack ? -1 : a.pack > b.pack ? 1 : 0;
}

ScaledUnit scaled_unit_from_spelling(size_t index) pure nothrow @nogc
{
    return g_units[g_unit_spellings[index].unit_offset];
}

const(char)[] scaled_unit_spelling_text(const ScaledUnitSpelling entry) pure nothrow @nogc
{
    // CTFE cannot follow a pointer into a global, so read the length prefix by index
    if (__ctfe)
    {
        size_t o = entry.spelling_offset;
        version (LittleEndian)
            size_t len = (g_spelling_strings[o - 2] | (g_spelling_strings[o - 1] << 8)) & 0x7FFF;
        else
            size_t len = (g_spelling_strings[o - 1] | (g_spelling_strings[o - 2] << 8)) & 0x7FFF;
        return g_spelling_strings[o .. o + len];
    }
    return as_string(g_spelling_strings.ptr + entry.spelling_offset)[];
}

const(char)[] scaled_unit_spelling(ScaledUnit u) pure nothrow @nogc
{
    size_t unit_index = binary_search!scaled_unit_compare(g_units[], u);
    if (unit_index == g_units.length)
        return null;
    return scaled_unit_spelling_text(g_unit_spellings[g_canonical_string[unit_index]]);
}

ptrdiff_t format_si_scale(int e, char[] buffer) pure nothrow @nogc
{
    if (e == 0)
        return 0;

    const(char)[] prefix;
    switch (e)
    {
        case -2: prefix = "c";  break;
        case -1: prefix = "d";  break;
        case 1:  prefix = "da"; break;
        case 2:  prefix = "h";  break;
        default:
            if (e < -30 || e > 30 || e % 3 != 0)
                return -1;
            size_t i = e / 3 + 10;
            prefix = "qryzafpnum kMGTPEZYRQ"[i .. i + 1];
            break;
    }

    if (buffer.ptr)
    {
        if (buffer.length < prefix.length)
            return -1;
        buffer[0 .. prefix.length] = prefix[];
    }
    return prefix.length;
}

ptrdiff_t synth_unit_name(Unit u, char[] buffer, int scale_exp = 0) pure nothrow @nogc
{
    static immutable string[8] base_names = [ "", "kg", "m", "s", "A", "K", "cd", "rad" ];

    size_t len = 0;
    bool wrote_slash = false;
    bool wrote_scale = false;

    ptrdiff_t emit(const(char)[] text)
    {
        if (buffer.ptr)
        {
            if (buffer.length < len + text.length)
                return -1;
            buffer[len .. len + text.length] = text[];
        }
        len += text.length;
        return 0;
    }

    foreach (negative; 0 .. 2)
    {
        foreach (i; 0 .. 4)
        {
            uint group = (u.pack >> (i * 6)) & 0x3F;
            uint type = group >> 3;
            if (type == 0)
                continue;

            int e = (group & 4) ? -int((group & 3) + 1) : int((group & 3) + 1);
            if ((e < 0) != (negative != 0))
                continue;

            if (negative && !wrote_slash)
            {
                if (emit("/") < 0)
                    return -1;
                wrote_slash = true;
            }
            else if (len)
            {
                if (emit("*") < 0)
                    return -1;
            }

            const(char)[] name = base_names[type];
            if (!wrote_scale)
            {
                if (scale_exp % e != 0)
                    return -1;
                int term_scale = scale_exp / e;
                if (type == UnitType.Mass && scale_exp != 0)
                {
                    term_scale += 3;
                    name = "g";
                }
                ptrdiff_t scale_len = format_si_scale(term_scale, buffer.ptr ? buffer[len .. $] : null);
                if (scale_len < 0)
                    return -1;
                len += scale_len;
                wrote_scale = true;
            }

            if (emit(name) < 0)
                return -1;

            int mag = e < 0 ? -e : e;
            if (mag > 1)
            {
                static immutable string[5] powers = [ "", "", "²", "³", "⁴" ];
                if (emit(powers[mag]) < 0)
                    return -1;
            }
        }
    }
    return len;
}

private struct NamedUnit
{
    string name;
    Unit unit;
}

private immutable NamedUnit[] named_units = [
    NamedUnit("m", Metre),
    NamedUnit("kg", Kilogram),
    NamedUnit("s", Second),
    NamedUnit("A", Ampere),
    NamedUnit("K", Kelvin),
    NamedUnit("cd", Candela),
    NamedUnit("rad", Radian),
    NamedUnit("N", Newton),
    NamedUnit("Pa", Pascal),
    NamedUnit("J", Joule),
    NamedUnit("W", Watt),
    NamedUnit("C", Coulomb),
    NamedUnit("V", Volt),
    NamedUnit("Ω", Ohm),
    NamedUnit("F", Farad),
    NamedUnit("S", Siemens),
    NamedUnit("Wb", Weber),
    NamedUnit("T", Tesla),
    NamedUnit("H", Henry),
    NamedUnit("lm", Lumen),
    NamedUnit("lx", Lux),
    NamedUnit("VA", Watt),
    NamedUnit("var", Watt),
];

private const(Unit)* find_named_unit(const(char)[] name) pure
{
    foreach (ref named; named_units)
        if (name == named.name)
            return &named.unit;
    return null;
}

private const(string)* find_unit_name(Unit unit) pure
{
    foreach (ref named; named_units)
        if (unit == named.unit)
            return &named.name;
    return null;
}

int take_power(ref const(char)[] s) pure
{
    size_t e = s.findFirst('^');
    if (e < s.length)
    {
        const(char)[] p = s[e+1..$];
        s = s[0..e];
        if (s.length == 0 || p.length == 0)
            return 0;
        if (p[0] == '-')
        {
            if (p.length != 2 || uint(p[1] - '0') > 4)
                return 0;
            return -(p[1] - '0');
        }
        if (p.length != 1 || uint(p[0] - '0') > 4)
            return 0;
        return p[0] - '0';
    }
    else if (s.length > 2)
    {
        if (s[$-2..$] == "¹")
        {
            if (s.length > 5 && s[$-5..$-2] == "⁻")
            {
                s = s[0..$-5];
                return -1;
            }
            s = s[0..$-2];
            return 1;
        }
        if (s[$-2..$] == "²")
        {
            if (s.length > 5 && s[$-5..$-2] == "⁻")
            {
                s = s[0..$-5];
                return -2;
            }
            s = s[0..$-2];
            return 2;
        }
        if (s[$-2..$] == "³")
        {
            if (s.length > 5 && s[$-5..$-2] == "⁻")
            {
                s = s[0..$-5];
                return -3;
            }
            s = s[0..$-2];
            return 3;
        }
        if (s.length > 3 && s[$-3..$] == "⁴")
        {
            if (s.length > 6 && s[$-6..$-3] == "⁻")
            {
                s = s[0..$-6];
                return -4;
            }
            s = s[0..$-3];
            return 4;
        }
    }
    return 1;
}
