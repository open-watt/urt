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
//     Where:   the lower 24 bits are from Unit
//            x specifies standard or extended encoding
//       Standard (x = 0): sssssss = eeeeeer
//            eeeeee is a 6-bit signed exponent (ie; scale = 10^^e)
//                   the value -32 (100000) is reserved for future expansion
//                 r is a reserved bit...
//       Extended (x = 1): sssssss = ieessss
//               i is the inverted bit (ie 1/scale)
//              ee is the scaling power minus 1 (ie; exp = ee+1, scale^^exp)
//            ssss is a value from the ScaleFactor table
//                 if ssss == 1111, we reinterpret ee as additional expanded encoding for values
//                 that can not be exponentiated, like temperatures
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

// non-si units
enum Minute = ScaledUnit(Second, ScaleFactor.Minute);
enum Hour = ScaledUnit(Second, ScaleFactor.Hour);
enum Day = ScaledUnit(Second, ScaleFactor.Day);
enum Inch = ScaledUnit(Metre, ScaleFactor.Inch);
enum Foot = ScaledUnit(Metre, ScaleFactor.Foot);
enum Mile = ScaledUnit(Metre, ScaleFactor.Mile);
enum Ounce = ScaledUnit(Kilogram, ScaleFactor.Ounce);
enum Pound = ScaledUnit(Kilogram, ScaleFactor.Pound);
enum Celsius = ScaledUnit(Kelvin, ExtendedScaleFactor.Celsius);
enum Fahrenheit = ScaledUnit(Kelvin, ExtendedScaleFactor.Fahrenheit);
enum Cycle = ScaledUnit(Radian, ScaleFactor.Cycles);
enum Degree = ScaledUnit(Radian, ScaleFactor.Degrees);

// derived units
enum Percent = ScaledUnit(Unit(), -2);
enum Permille = ScaledUnit(Unit(), -3);
enum Centimetre = ScaledUnit(Metre, -2);
enum Millimetre = ScaledUnit(Metre, -3);
enum Kilometre = ScaledUnit(Metre, 3);
enum SquareMetre = Metre^^2;
enum CubicMetre = Metre^^3;
enum Litre = ScaledUnit(CubicMetre, -3);
enum Gram = ScaledUnit(Kilogram, -3);
enum Milligram = ScaledUnit(Kilogram, -6);
enum Nanosecond = ScaledUnit(Second, -9);
enum Hertz = Cycle / Second;
enum Kilohertz = ScaledUnit(Hertz, SiPrefix.Kilo);
enum Megahertz = ScaledUnit(Hertz, SiPrefix.Mega);
enum Gigahertz = ScaledUnit(Hertz, SiPrefix.Giga);
enum Newton = Kilogram * Metre / Second^^2;
enum Pascal = Newton / Metre^^2;
enum PSI = ScaledUnit(Pascal, ScaleFactor.PSI);
enum Joule = Newton * Metre;
enum Watt = Joule / Second;
enum Kilowatt = ScaledUnit(Watt, 3);
enum AmpereHour = ScaledUnit(Coulomb, ScaleFactor.Hour);
enum WattHour = ScaledUnit(Joule, ScaleFactor.Hour);
enum KilowattHour = ScaledUnit(WattHour, SiPrefix.Kilo);
enum MegawattHour = ScaledUnit(WattHour, SiPrefix.Mega);
enum GigawattHour = ScaledUnit(WattHour, SiPrefix.Giga);
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

            if (const Unit* u = unit in unitMap)
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
    // prefix-mode factors (contiguous low range): ee field encodes an SI prefix
    // (none/k/M/G); no exponentiation other than ^^-1
    Minute = 0,
    Hour,
    Day,
    Cycles,

    // power-mode factors: ee field encodes a power exponent (1..4); no SI prefix
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
static assert(ScaleFactor.max < 15);

enum LastPrefixModeFactor = ScaleFactor.Cycles;

bool is_prefix_mode(ScaleFactor f) pure
    => f <= LastPrefixModeFactor;

enum SiPrefix : ubyte
{
    None = 0,    // 10^^0
    Kilo,        // 10^^3
    Mega,        // 10^^6
    Giga,        // 10^^9
}

enum ExtendedScaleFactor : ubyte
{
    Res1 = 0,   // what here?
    Celsius = 1,
    Res2 = 2,   // what here?
    Fahrenheit = 3,
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
        pack = u.pack | (e << 26);
    }

    this(Unit u, ScaleFactor sf, int e = 1) pure
    {
        debug assert(!is_prefix_mode(sf) || e == 1 || e == -1, "Prefix-mode ScaleFactor only supports e == ±1; use the SiPrefix overload for prefixed units");

        pack = u.pack;

        if (e == 0)
            return;

        assert(uint(e + 4) <= 8);

        if (e < 0)
            pack |= 0x81000000 | (sf << 25) | (~e << 29);
        else
            pack |= 0x01000000 | (sf << 25) | ((e - 1) << 29);
    }

    this(ScaledUnit base, SiPrefix prefix) pure
    {
        debug assert(!base.siScale() && !base.isExtended() && is_prefix_mode(base.sf()), "SI prefix only valid on prefix-mode extended ScaledUnit");
        pack = (base.pack & ~(3U << 29)) | (uint(prefix) << 29);
    }

    this(Unit u, ExtendedScaleFactor scaleFactor, bool inverse = false) pure
    {
        pack = u.pack | 0x1F000000 | (scaleFactor << 29) | (inverse << 31);
    }

    bool siScale() const pure
        => (pack & 0x1000000) == 0;
    bool isExtended() const pure
        => (pack & 0x1F000000) == 0x1F000000;
    bool isTemperature() const pure
        => (pack & 0x3F000000) == 0x3F000000;

    int exp() const pure
        => int(pack) >> 26;

    bool inv() const pure
        => pack >> 31;
    ScaleFactor sf() const pure
        => cast(ScaleFactor)((pack >> 25) & 0xF);
    ExtendedScaleFactor esf() const pure
        => cast(ExtendedScaleFactor)((pack >> 29) & 0x3);

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

        if (isExtended())
            return extScaleFactor[(pack >> 29) ^ (invert << 2)];

        ScaleFactor f = sf();
        uint inv = (pack >> 31) ^ invert;

        if (is_prefix_mode(f))
        {
            double s = scaleFactor[0][f] * prefixScale[(pack >> 29) & 3];
            return inv ? 1.0 / s : s;
        }

        double s = scaleFactor[inv][f];
        for (uint i = ((pack >> 29) & 3); i > 0; --i)
            s *= s;
        return s;
    }
    double offset(bool inv = false)() const pure
    {
        if (!isTemperature())
            return 0;
        return tempOffsets[(pack >> 30) ^ (inv << 1)];
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
            return ScaledUnit(u | (pack & 0xFF000000) ^ 0x80000000);
        }

        if (siScale())
            return ScaledUnit(u | ((exp() * e) << 26));

        // if it's extended, we can't exponentiate these units...
        assert(!isExtended(), "Temperature units can't be multiplied");

        assert(!is_prefix_mode(sf()), "Prefix-mode units only support exponents of ±1");

        int f = decodeExp[pack >> 29] * e;

        if (uint(f + 4) > 8)
            assert(false, "Invalid exponent: |e| > 4");

        return ScaledUnit(u | (pack & 0x1F000000) | (encodeExp[f + 4] << 29));
    }

    ScaledUnit opBinary(string op)(Unit b) const pure
        if (op == "*" || op == "/")
    {
        return ScaledUnit(unit.opBinary!op(b).pack | (pack & 0xFF000000));
    }

    ScaledUnit opBinaryRight(string op)(Unit b) const pure
        if (op == "*" || op == "/")
    {
        static if (op == "*")
            return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000));
        else
        {
            if (siScale())
                return ScaledUnit(b.opBinary!op(unit).pack | (-(int(pack) >> 26) << 26));
            return ScaledUnit(b.opBinary!op(unit).pack | (pack & 0xFF000000) ^ 0x80000000);
        }
    }

    ScaledUnit opBinary(string op)(ScaledUnit b) const pure
        if (op == "*" || op == "/")
    {
        uint u = unit.opBinary!op(b.unit).pack;

        ubyte f = pack >> 24;
        ubyte bf = b.pack >> 24;

        if (f == 0) // if LHS is identity
        {
            static if (op == "*")
                return ScaledUnit(u | (bf << 24));
            else
            {
                if (bf == 0)
                    return ScaledUnit(u);
                if ((bf & 1) == 0)
                    return ScaledUnit(u | (-(int(b.pack) >> 26) << 26));
                return ScaledUnit(u | ((bf ^ 0x80) << 24));
            }
        }
        else if (bf == 0) // if RHS is identity
            return ScaledUnit(u | (pack & 0xFF000000));

        if (siScale())
        {
            assert(b.siScale(), "Can't combine SI and arbitrary units");

            static if (op == "*")
                return ScaledUnit(u | ((exp() + b.exp()) << 26));
            else
                return ScaledUnit(u | ((exp() - b.exp()) << 26));
        }

        assert(!b.siScale(), "Can't combine SI and arbitrary units");
        assert(!isExtended(), "Temperature units can't be multiplied");
        assert(sf() == b.sf(), "Can't combine mismatching arbitrary units");

        if (is_prefix_mode(sf()))
        {
            // prefix-mode factors don't compose; division of identical scales cancels
            static if (op == "/")
            {
                if ((pack & 0xFF000000) == (b.pack & 0xFF000000))
                    return ScaledUnit(u);
            }
            assert(false, "Prefix-mode units don't compose with multiplication");
        }

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

    // preconditions of `^^` and `*`/`/` above (scale representability, not dims); parse_unit()
    // checks these so unrepresentable input like "km/h" is a parse error, not a combine assert
    bool can_pow(int e) const pure
    {
        if (pack == 0 || uint(e + 1) <= 2)
            return true;
        if (siScale())
            return true;
        if (isExtended() || is_prefix_mode(sf()))
            return false;
        return uint(decodeExp[pack >> 29] * e + 4) <= 8;
    }

    bool can_combine(string op)(ScaledUnit b) const pure
        if (op == "*" || op == "/")
    {
        ubyte f = pack >> 24;
        ubyte bf = b.pack >> 24;
        if (f == 0 || bf == 0)
            return true;
        if (siScale() != b.siScale())
            return false;
        if (siScale())
            return true;
        if (isExtended() || b.isExtended())
            return false;
        if (sf() != b.sf())
            return false;
        if (is_prefix_mode(sf()))
            return op == "/" && (pack & 0xFF000000) == (b.pack & 0xFF000000);
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
            else if (const ScaledUnit* su = term[offset .. $] in noScaleUnitMap)
            {
                if (!combine(*su, invert ? -p : p))
                    return -1;
                pre_scale *= 10.0^^e;
            }
            else
            {
                // try and parse SI prefix...
                switch (term[offset])
                {
                    case 'Y':   e += 24;   ++offset;    break;
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
                if (const Unit* u = term in unitMap)
                {
                    if (term == "kg")
                    {
                        // we alrady parsed the 'k', so this string must have been "kkg", which is nonsense
                        return -1;
                    }
                    if (!combine(ScaledUnit((*u) ^^ (invert ? -p : p), e), 1))
                        return -1;
                }
                else if (const ScaledUnit* su = term in scaledUnitMap)
                {
                    if (!combine(ScaledUnit(su.unit, su.exp + e), invert ? -p : p))
                        return -1;
                }
                else if (const ScaledUnit* su = term in noScaleUnitMapSI)
                {
                    // if SI exponent fits in our 2-bit prefix table (none / k / M / G), encode the prefix into the ScaledUnit exponent
                    // TODO: should we round e4,5->3 with 10-100x scaling, rather than 10,000-100,000x scaling as would be applied below?
                    if (!su.siScale() && !su.isExtended() && is_prefix_mode(su.sf()) && (e == 0 || e == 3 || e == 6 || e == 9))
                    {
                        SiPrefix prefix = cast(SiPrefix)(e / 3);
                        if (!combine(ScaledUnit(*su, prefix), invert ? -p : p))
                            return -1;
                    }
                    else
                    {
                        if (!combine(*su, invert ? -p : p))
                            return -1;
                        pre_scale *= 10.0^^e;
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
                assert(false, "TODO!"); // how (or should?) we encode a scale as a unit type?
        }

        size_t len = 0;
        if (siScale)
        {
            int x = exp;
            if (x != 0)
            {
                // for scale factors between SI units, we'll normalise to the next higher unit...
                int y = (x + 33) % 3;
                if (y != 0)
                {
                    if (y == 1)
                    {
                        if (buffer.ptr)
                        {
                            if (buffer.length < 2)
                                return -1;
                            buffer[0..2] = "10";
                        }
                        --x;
                        len += 2;
                    }
                    else
                    {
                        if (buffer.ptr)
                        {
                            if (buffer.length < 3)
                                return -1;
                            buffer[0..3] = "100";
                        }
                        x -= 2;
                        len += 3;
                    }
                }
                assert(x >= -30, "TODO: handle this very small case");

                if (x != 0)
                {
                    if (buffer.ptr)
                    {
                        if (buffer.length <= len)
                            return -1;
                        buffer[len] = "qryzafpnum kMGTPEZYRQ"[x/3 + 10];
                    }
                    ++len;
                }
            }

            if (const string* name = unit in unitNames)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < len + name.length)
                        return -1;
                    buffer[len .. len + name.length] = *name;
                }
                len += name.length;
            }
            else if (const string* name = len == 0 ? (unit ^^ -1) in unitNames : null)
            {
                // reciprocal of a nameable unit formats as "/name" (only prefix-free; a prefix
                // ahead of the '/' would bind to the numerator and not parse back)
                if (buffer.ptr)
                {
                    if (buffer.length < 1 + name.length)
                        return -1;
                    buffer[0] = '/';
                    buffer[1 .. 1 + name.length] = *name;
                }
                len = 1 + name.length;
            }
            else
            {
                // synth a unit name...
                assert(false, "TODO");
            }
        }
        else
        {
            if (const string* name = this in scaledUnitNames)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < len + name.length)
                        return -1;
                    buffer[len .. len + name.length] = *name;
                }
                len += name.length;
            }
            else if (const string* name = (this ^^ -1) in scaledUnitNames)
            {
                if (buffer.ptr)
                {
                    if (buffer.length < len + 1 + name.length)
                        return -1;
                    buffer[len] = '/';
                    buffer[len + 1 .. len + 1 + name.length] = *name;
                }
                len += 1 + name.length;
            }
            else
            {
                // what now?
                assert(false, "TODO");
            }
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

    // bit-stability check
    assert(WattHour.unit == Joule);

    // prefix-mode extended units (hybrid SI prefix + named ScaleFactor)
    assert(WattHour.scale() == 3600.0);
    assert(KilowattHour.scale() == 3600.0 * 1000);
    assert(MegawattHour.scale() == 3600.0 * 1e6);
    assert(GigawattHour.scale() == 3600.0 * 1e9);

    // inversion of prefix-mode extended units
    assert((WattHour^^-1).scale() == 1.0 / 3600);
    assert((KilowattHour^^-1).scale() == 1.0 / (3600.0 * 1000));

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
    assert(su.parse_unit("km/h", pre) == -1);
    assert(su.parse_unit("hr*min", pre) == -1);
    assert(su.parse_unit("Wh^2", pre) == -1);

    // format: reciprocal of a nameable unit renders as "/name"
    char[16] fmt_buf;
    assert((Hour^^-1).format_unit(fmt_buf[], pre) == 3 && fmt_buf[0..3] == "/hr" && pre == 1);
    assert((ScaledUnit(Second)^^-1).format_unit(fmt_buf[], pre) == 2 && fmt_buf[0..2] == "/s");
}


private:

import urt.math : PI;

immutable byte[8] decodeExp = [ 1, 2, 3, 4, -1, -2, -3, -4 ];
immutable ubyte[9] encodeExp = [ 7, 6, 5, 4, 0, 0, 1, 2, 3 ];

immutable double[19] sciScaleFactor = [ 1e-9, 1e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9 ];

immutable double[16][2] scaleFactor = [ [
    60,         // Minute
    3600,       // Hour
    86400,      // Day
    2*PI,       // Cycles
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
    double.nan  // extended...
], [
    1/60.0,     // Minute
    1/3600.0,   // Hour
    1/86400.0,  // Day
    1/(2*PI),   // Cycles
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
    double.nan  // extended...
] ];

immutable double[4] prefixScale = [ 1.0, 1e3, 1e6, 1e9 ];

immutable double[8] extScaleFactor = [
    0,      // Res1
    1,      // Celsius
    0,      // Res2
    5.0/9,  // Fahrenheit

    0,      // 1/Res1
    1,      // 1/Celsius
    0,      // 1/Res2
    9.0/5   // 1/Fahrenheit
];

// what is the proper order?
immutable double[4] tempOffsets = [
    273.15,                 // C -> K
    (-32.0*5)/9 + 273.15,   // F -> K

    -273.15,                // K -> C
    (-273.15*9)/5 + 32      // K -> F
];

immutable string[Unit] unitNames = [
    Metre       : "m",
    Metre^^2    : "m²",
    Metre^^3    : "m³",
    Kilogram    : "kg",
    Second      : "s",
    Ampere      : "A",
    Kelvin      : "K",
    Candela     : "cd",
    Radian      : "rad",

    // derived units
    Newton      : "N",
    Pascal      : "Pa",
    Joule       : "J",
    Watt        : "W",
    Coulomb     : "C",
    Volt        : "V",
    Ohm         : "Ω",
    Farad       : "F",
    Siemens     : "S",
    Weber       : "Wb",
    Tesla       : "T",
    Henry       : "H",
    Lumen       : "lm",
    Lux         : "lx",
];

immutable string[ScaledUnit] scaledUnitNames = [
    Minute      : "min",
//    Minute      : "mins",
    Hour        : "hr",
//    Hour        : "hrs",
    Day         : "day",

    Inch        : "in",
    Foot        : "ft",
    Mile        : "mi",
    Ounce       : "oz",
    Pound       : "lb",
    Celsius     : "°C",
    Fahrenheit  : "°F",
    Cycle       : "cy",
    Degree      : "°",

    Percent     : "%",
    Permille    : "‰",
    Centimetre  : "cm",
    Millimetre  : "mm",
    Kilometre   : "km",
    Litre       : "l",
    Gram        : "g",
    Milligram   : "mg",
    Hertz       : "Hz",
    Kilohertz   : "kHz",
    Megahertz   : "MHz",
    Gigahertz   : "GHz",
    PSI         : "psi",
    Kilowatt    : "kW",
    AmpereHour  : "Ah",
    WattHour    : "Wh",
    KilowattHour : "kWh",
    MegawattHour : "MWh",
    GigawattHour : "GWh",
];

immutable Unit[string] unitMap = [
    // base units
    "m"     : Metre,
    "kg"    : Kilogram,
    "s"     : Second,
    "A"     : Ampere,
    "K"     : Kelvin,
    "cd"    : Candela,
    "rad"   : Radian,

    // derived units
    "N"     : Newton,
    "Pa"    : Pascal,
    "J"     : Joule,
    "W"     : Watt,
    "C"     : Coulomb,
    "V"     : Volt,
    "Ω"     : Ohm,
    "F"     : Farad,
    "S"     : Siemens,
    "Wb"    : Weber,
    "T"     : Tesla,
    "H"     : Henry,
    "lm"    : Lumen,
    "lx"    : Lux,

    // questionable... :/
    "VA"    : Watt,
    "var"   : Watt,
];

immutable ScaledUnit[string] noScaleUnitMap = [
    "min"   : Minute,
    "mins"  : Minute,
    "h"     : Hour,
    "hr"    : Hour,
    "hrs"   : Hour,
    "day"   : Day,
    "days"  : Day,
    "'"     : Inch,
    "in"    : Inch,
    "\""    : Foot,
    "ft"    : Foot,
    "mi"    : Mile,
    "oz"    : Ounce,
    // TODO: us/uk floz/gallon?
    "lb"    : Pound,
    "°"     : Degree,
    "deg"   : Degree,
    "°C"    : Celsius,
    "°F"    : Fahrenheit,
    "cy"    : Cycle,
    "psi"   : PSI,
    "%"     : Percent,
    "‰"     : Permille,
    "‱"    : ScaledUnit(Unit(), -4),
    "ppm"   : ScaledUnit(Unit(), -6),
];

// these can have SI prefixes
immutable ScaledUnit[string] scaledUnitMap = [
    "l"     : Litre,
    "g"     : Gram,
];

// these can have SI prefixes, but scale must be converted to coefficient
immutable ScaledUnit[string] noScaleUnitMapSI = [
    "Ah"    : AmpereHour,
    "Wh"    : WattHour,
    "Hz"    : Hertz,

    // questionable... :/
    "VAh"   : WattHour,
    "varh"  : WattHour,
];

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
    }
    else if (s.length > 3 && s[$-3..$] == "⁴")
    {
        if (s.length > 6 && s[$-6..$-3] == "⁻")
        {
            s = s[0..$-6];
            return -4;
        }
        s = s[0..$-3];
        return 4;
    }
    return 1;
}
