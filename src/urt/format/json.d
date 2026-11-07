module urt.format.json;

import urt.array;
import urt.conv;
import urt.lifetime;
import urt.kvp;
import urt.si.unit;
import urt.string;
import urt.string.format;

public import urt.variant;

nothrow @nogc:


enum max_json_depth = 64;

enum JsonEvent : ubyte
{
    none,
    begin_object,
    end_object,
    begin_array,
    end_array,
    key,
    text,
    number,
    boolean,
    null_,
    eof,
    error,
}

// Pull tokenizer over a complete document. Keys, strings and numbers are slices of the input;
// strings are raw (still escaped) and decode with decode_json_string.
struct JsonReader
{
nothrow @nogc:

    this(const(char)[] text) pure
    {
        _text = text;
    }

    JsonEvent event() const pure
        => _event;
    const(char)[] text() const pure
        => _token;
    bool escaped() const pure
        => _escaped;
    bool boolean() const pure
        => _token.length == 4;
    int depth() const pure
        => _depth;

    JsonEvent next() pure
    {
        if (_event == JsonEvent.eof || _event == JsonEvent.error)
            return _event;
        _text = _text.trimFront;

        final switch (_expect)
        {
            case Expect.done:
                return _text.empty ? set(JsonEvent.eof) : fail();

            case Expect.key_or_end:
                if (!_text.empty && _text[0] == '}')
                    return close('}');
                goto case Expect.key;

            case Expect.key:
                if (_text.empty || _text[0] != '"' || !take_string())
                    return fail();
                _text = _text.trimFront;
                if (_text.empty || _text[0] != ':')
                    return fail();
                _text = _text[1 .. $];
                _expect = Expect.value;
                return set(JsonEvent.key);

            case Expect.value_or_end:
                if (!_text.empty && _text[0] == ']')
                    return close(']');
                goto case Expect.value;

            case Expect.value:
                return take_value();

            case Expect.comma_or_end:
                if (_text.empty)
                    return fail();
                if (_text[0] == '}' || _text[0] == ']')
                    return close(_text[0]);
                if (_text[0] != ',')
                    return fail();
                _text = _text[1 .. $].trimFront;
                if (in_object)
                {
                    _expect = Expect.key;
                    return next();
                }
                return take_value();
        }
    }

    // from a begin event, consumes through the matching end; any other event is already whole
    JsonEvent skip() pure
    {
        if (_event != JsonEvent.begin_object && _event != JsonEvent.begin_array)
            return _event;
        int target = _depth - 1;
        while (true)
        {
            JsonEvent e = next();
            if (e == JsonEvent.error || ((e == JsonEvent.end_object || e == JsonEvent.end_array) && _depth == target))
                return e;
        }
    }

private:
    enum Expect : ubyte
    {
        value,
        key,
        key_or_end,
        value_or_end,
        comma_or_end,
        done,
    }

    const(char)[] _text;
    const(char)[] _token;
    ulong _objects;     // bit n: the container at depth n + 1 is an object
    int _depth;
    JsonEvent _event;
    Expect _expect;
    bool _escaped;

    bool in_object() const pure
        => (_objects >> (_depth - 1)) & 1;

    JsonEvent set(JsonEvent e) pure
    {
        _event = e;
        return e;
    }

    JsonEvent fail() pure
    {
        _token = null;
        return set(JsonEvent.error);
    }

    JsonEvent after_value(JsonEvent e) pure
    {
        _expect = _depth == 0 ? Expect.done : Expect.comma_or_end;
        return set(e);
    }

    JsonEvent close(char c) pure
    {
        if (c != (in_object ? '}' : ']'))
            return fail();
        _text = _text[1 .. $];
        --_depth;
        return after_value(c == '}' ? JsonEvent.end_object : JsonEvent.end_array);
    }

    JsonEvent take_value() pure
    {
        if (_text.empty)
            return fail();
        char c = _text[0];
        if (c == '{' || c == '[')
        {
            if (_depth == max_json_depth)
                return fail();
            _text = _text[1 .. $];
            if (c == '{')
                _objects |= ulong(1) << _depth;
            else
                _objects &= ~(ulong(1) << _depth);
            ++_depth;
            _expect = c == '{' ? Expect.key_or_end : Expect.value_or_end;
            return set(c == '{' ? JsonEvent.begin_object : JsonEvent.begin_array);
        }
        if (c == '"')
            return take_string() ? after_value(JsonEvent.text) : fail();
        if (_text.startsWith("true"))
            return take_literal(4, JsonEvent.boolean);
        if (_text.startsWith("false"))
            return take_literal(5, JsonEvent.boolean);
        if (_text.startsWith("null"))
            return take_literal(4, JsonEvent.null_);
        if (c.is_numeric || (c == '-' && _text.length > 1 && _text[1].is_numeric))
        {
            size_t taken;
            int e;
            parse_int_with_exponent(_text, e, &taken, 10);
            if (taken == 0)
                return fail();
            _token = _text.takeFront(taken);
            return after_value(JsonEvent.number);
        }
        return fail();
    }

    JsonEvent take_literal(size_t length, JsonEvent e) pure
    {
        _token = _text.takeFront(length);
        return after_value(e);
    }

    bool take_string() pure
    {
        _escaped = false;
        size_t i = 1;
        while (i < _text.length && _text[i] != '"')
        {
            if (_text[i] == '\\')
            {
                _escaped = true;
                ++i;
            }
            ++i;
        }
        if (i >= _text.length)
            return false;
        _token = _text[1 .. i];
        _text = _text[i + 1 .. $];
        return true;
    }
}

// a decoded string is never longer than its escaped form; -1 for a malformed escape
ptrdiff_t decode_json_string(const(char)[] raw, char[] buffer) pure
{
    size_t length;
    for (size_t i = 0; i < raw.length; )
    {
        char c = raw[i++];
        if (c != '\\')
        {
            buffer[length++] = c;
            continue;
        }
        if (i == raw.length)
            return -1;
        c = raw[i++];
        switch (c)
        {
            case '"', '\\', '/':
                break;
            case 'b':
                c = '\b';
                break;
            case 'f':
                c = '\f';
                break;
            case 'n':
                c = '\n';
                break;
            case 'r':
                c = '\r';
                break;
            case 't':
                c = '\t';
                break;
            case 'u':
                dchar code;
                if (!take_hex4(raw, i, code))
                    return -1;
                if ((code >> 11) == 0x1B)
                {
                    // a high surrogate needs its low half to follow
                    dchar low;
                    if (code >= 0xDC00 || i + 2 > raw.length || raw[i] != '\\' || raw[i + 1] != 'u')
                        return -1;
                    i += 2;
                    if (!take_hex4(raw, i, low) || (low >> 10) != 0x37)
                        return -1;
                    code = 0x10000 + ((code & 0x3FF) << 10 | (low & 0x3FF));
                }
                length += encode_utf8(code, buffer[length .. $]);
                continue;
            default:
                return -1;
        }
        buffer[length++] = c;
    }
    return length;
}

Variant parse_json(const(char)[] text)
{
    JsonReader reader = JsonReader(text);
    Variant root;
    return read_value(reader, reader.next(), root) ? root.move : Variant();
}

ptrdiff_t write_json(ref const Variant val, char[] buffer, bool dense = false, uint level = 0, uint indent = 2)
{
    final switch (val.type)
    {
        case Variant.Type.Null:
        case Variant.Type.True:
        case Variant.Type.False:
            return val.toString(buffer, null, null);

        case Variant.Type.Map:
        case Variant.Type.Array:
            if (!buffer.ptr)
            {
                ptrdiff_t len;
                size_t itemCount = val.type == Variant.Type.Map ? val.count /2 : val.count;
                if (itemCount == 0)
                    return 2;   // "[]" / "{}"
                if (dense)
                {
                    // open/close brackets + comma-space separators
                    len = 2 + (itemCount - 1)*2;
                    if (val.type == Variant.Type.Map)
                    {
                        // colon separators
                        len += itemCount;
                    }
                }
                else
                {
                    // open/close brackets + comma separators + element newlines + final newline
                    len = 2 + (itemCount - 1) + itemCount*(1 + level + indent) + (1 + level);
                    if (val.type == Variant.Type.Map)
                    {
                        // colon-space separators
                        len += itemCount*2;
                    }
                }
                // ...and the elements
                int inc = val.type == Variant.Type.Map ? 2 : 1;
                for (uint i = 0; i < val.count; i += inc)
                {
                    len += write_json(val.value.n[i], null, dense, level + indent, indent);
                    if (val.type == Variant.Type.Map)
                        len += write_json(val.value.n[i + 1], null, dense, level + indent, indent);
                }
                return len;
            }

            ptrdiff_t written = 0;
            if (!buffer.append(written, val.type == Variant.Type.Map ? '{' : '['))
                return -1;
            if (val.count == 0)
            {
                if (!buffer.append(written, val.type == Variant.Type.Map ? '}' : ']'))
                    return -1;
                return written;
            }
            int inc = val.type == Variant.Type.Map ? 2 : 1;
            for (uint i = 0; i < val.count; i += inc)
            {
                if (i > 0)
                {
                    if (!buffer.append(written, ',') || (dense && !buffer.append(written, ' ')))
                        return -1;
                }
                if (!dense)
                {
                    if (!buffer.newline(written, level + indent))
                        return -1;
                }
                ptrdiff_t len = write_json(val.value.n[i], buffer[written .. $], dense, level + indent, indent);
                if (len < 0)
                    return -1;
                written += len;
                if (val.type == Variant.Type.Map)
                {
                    if (!buffer.append(written, ':') || (!dense && !buffer.append(written, ' ')))
                        return -1;
                    len = write_json(val.value.n[i + 1], buffer[written .. $], dense, level + indent, indent);
                    if (len < 0)
                        return -1;
                    written += len;
                }
            }
            if (!dense && !buffer.newline(written, level))
                return -1;
            if (!buffer.append(written, val.type == Variant.Type.Map ? '}' : ']'))
                return -1;
            return written;

        case Variant.Type.Buffer:
            if (!val.isString)
            {
                import urt.encoding;

                // emit raw buffer as base64
                const data = val.asBuffer();
                size_t enc_len = base64_encode_length(data.length);
                if (buffer.ptr)
                {
                    if (buffer.length < 2 + enc_len)
                        return -1;
                    buffer[0] = '"';
                    ptrdiff_t r = data.base64_encode(buffer[1 .. 1 + enc_len]);
                    if (r != enc_len)
                        return -2;
                    buffer[1 + enc_len] = '"';
                }
                return 2 + enc_len;
            }

            return write_json_string(buffer, val.asString());

        case Variant.Type.Number:
            ScaledUnit source_unit = val.isQuantity() ? val.get_unit : ScaledUnit();
            ScaledUnit unit = source_unit.printable_unit();
            float pre_scale;
            ptrdiff_t u_len = unit.pack ? unit.format_unit(null, pre_scale) : 0;
            if (u_len < 0)
                return -1;

            char[80] number = void;
            ptrdiff_t len;
            bool convert_scale = source_unit != unit && !source_unit.siScale();
            if (val.isDouble() || convert_scale)
            {
                double d = val.asDouble();
                if (convert_scale)
                    d = d * source_unit.scale() + source_unit.offset();
                if (d != d || d == double.infinity || d == -double.infinity)
                {
                    number[0 .. 4] = "null";
                    len = 4;
                }
                else if (val.isFloat() && !convert_scale)
                    len = val.asFloat().format_float_shortest(number);
                else
                    len = d.format_float_shortest(number);
            }
            else if (val.isUlong())
                len = val.asUlong().format_uint(number);
            else
                len = val.asLong().format_int(number);
            if (len < 0)
                return len;

            if (source_unit.siScale() && source_unit != unit && number[0 .. len] != "null")
            {
                int e = source_unit.exp() - unit.exp();
                size_t exponent = number[0 .. len].findFirst('e');
                if (exponent < len)
                {
                    e += cast(int)number[exponent + 1 .. len].parse_int();
                    len = exponent;
                }
                if (e != 0)
                {
                    number[len] = 'e';
                    ++len;
                    ptrdiff_t e_len = e.format_int(number[len .. $]);
                    if (e_len < 0)
                        return e_len;
                    len += e_len;
                }
            }

            size_t result_len = u_len ? 13 + len + u_len : len;
            if (!buffer.ptr)
                return result_len;
            if (buffer.length < result_len)
                return -1;
            if (!u_len)
                buffer[0 .. len] = number[0 .. len];
            else
            {
                buffer[0 .. 5] = "{\"q\":";
                buffer[5 .. 5 + len] = number[0 .. len];
                size_t offset = 5 + len;
                buffer[offset .. offset + 6] = ",\"u\":\"";
                if (unit.format_unit(buffer[offset + 6 .. result_len - 2], pre_scale) != u_len)
                    return -1;
                buffer[result_len - 2 .. result_len] = "\"}";
            }
            return result_len;

        case Variant.Type.User:
            return write_json_user(val, buffer);
    }
}

private:

ptrdiff_t write_json_user(ref const Variant val, char[] buffer)
{
    ptrdiff_t len = val.toString(null, null, null);
    if (len < 0)
        return len;
    size_t text_length = cast(size_t)len;

    if (!buffer.ptr)
    {
        import urt.mem : alloc, free;

        char[512] local = void;
        char[] text = text_length <= local.length
            ? local[0 .. text_length]
            : cast(char[])alloc(text_length, char.alignof);
        if (text_length && !text.ptr)
            return -1;
        bool allocated = text.ptr !is local.ptr;
        scope(exit) if (allocated) free(text);
        if (val.toString(text, null, null) != len)
            return -1;
        return write_json_string(null, text);
    }

    if (buffer.length < text_length + 2)
        return -1;
    if (val.toString(buffer[0 .. text_length], null, null) != len)
        return -1;
    ptrdiff_t json_length = write_json_string(null, buffer[0 .. text_length]);
    if (json_length < 0 || buffer.length < json_length)
        return -1;

    import urt.mem : memmove;

    size_t source = cast(size_t)json_length - text_length;
    memmove(buffer.ptr + source, buffer.ptr, text_length);
    return write_json_string(buffer, buffer[source .. source + text_length]);
}

ptrdiff_t write_json_string(char[] buffer, const(char)[] s)
{
    if (!buffer.ptr)
    {
        size_t len = 0;
        foreach (c; s)
        {
            if (c < 0x20)
            {
                if (c == '\n' || c == '\r' || c == '\t' || c == '\b' || c == '\f')
                    len += 2;
                else
                    len += 6;
            }
            else if (c == '"' || c == '\\')
                len += 2;
            else
                len += 1;
        }
        return len + 2;
    }

    if (buffer.length < s.length + 2)
        return -1;

    buffer[0] = '"';
    size_t offset = 1;
    foreach (c; s)
    {
        char sub = void;
        if (c < 0x20)
        {
            if (c == '\n')
                sub = 'n';
            else if (c == '\r')
                sub = 'r';
            else if (c == '\t')
                sub = 't';
            else if (c == '\b')
                sub = 'b';
            else if (c == '\f')
                sub = 'f';
            else
            {
                if (buffer.length < offset + 7)
                    return -1;
                buffer[offset .. offset + 4] = "\\u00";
                offset += 4;
                buffer[offset++] = hex_digits[c >> 4];
                buffer[offset++] = hex_digits[c & 0xF];
                continue;
            }
        }
        else if (c == '"' || c == '\\')
            sub = c;
        else
        {
            if (buffer.length < offset + 2)
                return -1;
            buffer[offset++] = c;
            continue;
        }

        if (buffer.length < offset + 3)
            return -1;
        buffer[offset++] = '\\';
        buffer[offset++] = sub;
    }
    buffer[offset++] = '"';
    return offset;
}

bool append(char[] buffer, ref ptrdiff_t offset, char c)
{
    if (offset >= buffer.length)
        return false;
    buffer[offset++] = c;
    return true;
}
ptrdiff_t newline(char[] buffer, ref ptrdiff_t offset, int level)
{
    if (offset + level >= buffer.length)
        return false;
    buffer[offset++] = '\n';
    buffer[offset .. offset + level] = ' ';
    offset += level;
    return true;
}

// malformed input fails the parse; it is never a crash, and never goes deeper than max_json_depth
bool read_value(ref JsonReader reader, JsonEvent event, out Variant node)
{
    switch (event)
    {
        case JsonEvent.begin_object:
        case JsonEvent.begin_array:
            bool object = event == JsonEvent.begin_object;
            Array!Variant items;
            while (true)
            {
                JsonEvent e = reader.next();
                if (e == JsonEvent.end_object || e == JsonEvent.end_array)
                    break;
                if (object)
                {
                    if (e != JsonEvent.key)
                        return false;
                    Variant key;
                    if (!read_string(reader, key) || !key.isString())
                        return false;
                    items ~= key.move;
                    e = reader.next();
                }
                Variant item;
                if (!read_value(reader, e, item))
                    return false;
                items ~= item.move;
            }
            node = Variant(items.move);
            if (object)
                node.flags = Variant.Flags.Map;
            return true;

        case JsonEvent.text:
            return read_string(reader, node);

        case JsonEvent.number:
            int e = void;
            long value = reader.text.parse_int_with_exponent(e, null, 10);

            // let's work out if value*10^^e is an integer?
            bool is_integer = e >= 0;
            for (; e > 0; --e)
            {
                if (value < 0 ? (value < long.min / 10) : (value > long.max / 10))
                {
                    is_integer = false;
                    break;
                }
                value *= 10;
            }
            node = is_integer ? Variant(value) : Variant(value * 10.0^^e);
            return true;

        case JsonEvent.boolean:
            node = Variant(reader.boolean);
            return true;

        case JsonEvent.null_:
            return true;

        default:
            return false;
    }
}

bool read_string(ref JsonReader reader, out Variant node)
{
    if (!reader.escaped)
    {
        node = Variant(reader.text);
        return true;
    }
    Array!char decoded;
    decoded.resize(reader.text.length);
    ptrdiff_t length = decode_json_string(reader.text, decoded[]);
    if (length < 0)
        return false;
    node = Variant(decoded[0 .. length]);
    return true;
}

bool take_hex4(const(char)[] raw, ref size_t i, out dchar code) pure
{
    if (i + 4 > raw.length)
        return false;
    size_t taken;
    code = cast(dchar)raw[i .. i + 4].parse_uint(&taken, 16);
    i += 4;
    return taken == 4;
}

size_t encode_utf8(dchar c, char[] buffer) pure
{
    if (c < 0x80)
    {
        buffer[0] = cast(char)c;
        return 1;
    }
    if (c < 0x800)
    {
        buffer[0] = cast(char)(0xC0 | c >> 6);
        buffer[1] = cast(char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000)
    {
        buffer[0] = cast(char)(0xE0 | c >> 12);
        buffer[1] = cast(char)(0x80 | (c >> 6 & 0x3F));
        buffer[2] = cast(char)(0x80 | (c & 0x3F));
        return 3;
    }
    buffer[0] = cast(char)(0xF0 | c >> 18);
    buffer[1] = cast(char)(0x80 | (c >> 12 & 0x3F));
    buffer[2] = cast(char)(0x80 | (c >> 6 & 0x3F));
    buffer[3] = cast(char)(0x80 | (c & 0x3F));
    return 4;
}

unittest
{
    struct JsonUserText
    {
        enum text_length = 600;

        ptrdiff_t toString(char[] buffer, const(char)[], const(FormatArg)[]) const nothrow @nogc
        {
            if (!buffer.ptr)
                return text_length;
            if (buffer.length < text_length)
                return -1;
            buffer[0] = '"';
            buffer[1] = '\\';
            buffer[2] = '\n';
            buffer[3 .. text_length] = 'x';
            return text_length;
        }
    }

    enum doc = `{
        "nothing": null,
        "name": "John Doe",
        "age": 42,
        "neg": -42,
        "sobig": 8234567890,
        "married": true,
        "worried": false,
        "children": [
            {
                "name": "Jane Doe",
                "age": 12
            },
            {
                "name": "Jack Doe",
                "age": 8
            }
        ]
    }`;

    Variant root = parse_json(doc);

    // check the data was parsed correctly...
    assert(root["nothing"].isNull);
    assert(root["name"].asString == "John Doe");
    assert(root["age"].asUint == 42);
    assert(root["neg"].asInt == -42);
    assert(root["sobig"].asLong == 8234567890);
    assert(root["married"].isTrue);
    assert(root["worried"].asBool == false);
    assert(root["children"].length == 2);
    assert(root["children"][0]["name"].asString == "Jane Doe");
    assert(root["children"][0]["age"].asInt == 12);
    assert(root["children"][1]["name"].asString == "Jack Doe");
    assert(root["children"][1]["age"].asInt == 8);

    char[1024] buffer = void;
    // check the dense writer...
    assert(root["children"].write_json(null, true) == 61);
    assert(root["children"].write_json(buffer, true) == 61);
    assert(buffer[0 .. 61] == `[{"name":"Jane Doe", "age":12}, {"name":"Jack Doe", "age":8}]`);

    // check the expanded writer
    assert(root["children"].write_json(null, false, 0, 1) == 83);
    assert(root["children"].write_json(buffer, false, 0, 1) == 83);
    assert(buffer[0 .. 83] == "[\n {\n  \"name\": \"Jane Doe\",\n  \"age\": 12\n },\n {\n  \"name\": \"Jack Doe\",\n  \"age\": 8\n }\n]");

    // check indentation works properly
    assert(root["children"].write_json(null, false, 0, 2) == 95);
    assert(root["children"].write_json(buffer, false, 0, 2) == 95);
    assert(buffer[0 .. 95] == "[\n  {\n    \"name\": \"Jane Doe\",\n    \"age\": 12\n  },\n  {\n    \"name\": \"Jack Doe\",\n    \"age\": 8\n  }\n]");

    // fabricate a JSON object
    Variant write;
    write.asArray ~= Variant(42);
    write.asArray ~= Variant(VariantKVP("wow", Variant(true)), VariantKVP("bogus", Variant(false)));

    assert(write.length == 2);
    assert(write[0].asInt == 42);
    assert(write[1]["wow"].isTrue);
    assert(write[1]["bogus"].asBool == false);
    assert(write.write_json(buffer, true) == 33);
    assert(buffer[0 .. 33] == "[42, {\"wow\":true, \"bogus\":false}]");

    Variant user = Variant(JsonUserText());
    enum user_json_length = JsonUserText.text_length + 5;
    assert(user.write_json(null) == user_json_length);
    assert(user.write_json(buffer) == user_json_length);
    assert(buffer[0] == '"');
    assert(buffer[1 .. 3] == "\\\"");
    assert(buffer[3 .. 5] == "\\\\");
    assert(buffer[5 .. 7] == "\\n");
    assert(buffer[user_json_length - 1] == '"');

    import urt.si.quantity : Quantity;

    static void check(T, ScaledUnit u = ScaledUnit())(T value, const(char)[] expected)
    {
        static bool equal_number(ref const Variant actual, ref const Variant wanted)
        {
            if (actual == wanted)
                return true;
            version (Tiny)
            {
                import urt.math : fabs;
                if (actual.isNumber && wanted.isNumber)
                    return fabs(actual.asDouble() / wanted.asDouble() - 1) < (is(T == float) ? 1e-6 : 1e-13);
            }
            return false;
        }

        Variant q = Variant(Quantity!(T, u)(value));
        char[128] output;
        ptrdiff_t len = q.write_json(null);
        assert(len == q.write_json(output));
        foreach (size; 0 .. len)
        {
            output[] = '#';
            assert(q.write_json(output[0 .. size]) == -1);
            foreach (c; output)
                assert(c == '#');
        }
        assert(q.write_json(output[0 .. len]) == len);
        static if (is(T == float) || is(T == double))
        {
            Variant actual = parse_json(output[0 .. len]);
            Variant wanted = parse_json(expected);
            if (wanted.type == Variant.Type.Map)
            {
                assert(actual.type == Variant.Type.Map, output[0 .. len]);
                assert(actual["u"].asString == wanted["u"].asString, output[0 .. len]);
                assert(equal_number(actual["q"], wanted["q"]), output[0 .. len]);
            }
            else
                assert(equal_number(actual, wanted), output[0 .. len]);
        }
        else
            assert(output[0 .. len] == expected, output[0 .. len]);
        assert(output[len] == '#');
        assert(!parse_json(output[0 .. len]).isNull || expected == "null");
    }

    check!(float, ScaledUnits.bar)(2.95f, `{"q":2.95,"u":"bar"}`);
    check!(float, ScaledUnit(Watt, 5))(2.95f, `{"q":2.95e2,"u":"kW"}`);
    check!(float, ScaledUnit(Watt, -4))(2.95f, `{"q":2.95e2,"u":"uW"}`);
    check!(int, ScaledUnit(Unit(), -1))(23302, "23302e-1");
    check!(int, ScaledUnit(Unit(), -1))(123456789, "123456789e-1");
    check!(ulong, ScaledUnit(Watt, 5))(ulong.max, `{"q":18446744073709551615e2,"u":"kW"}`);
    check!(long, ScaledUnit(Unit(), -1))(long.min, "-9223372036854775808e-1");
    check!(double, ScaledUnit(Watt, 5))(1e304, `{"q":1e306,"u":"kW"}`);
    check!(double, ScaledUnit(Watt, -4))(parse_float("1e-320"), `{"q":1e-318,"u":"uW"}`);
    check!(double, ScaledUnit(Watt, 5))(0.01, `{"q":1,"u":"kW"}`);
    check!(double, ScaledUnit(Watt, 5))(double.nan, `{"q":null,"u":"kW"}`);
    check!(double, ScaledUnit(Unit(), -1))(double.infinity, "null");
    check!(int, ScaledUnits.celsius)(20, `{"q":20,"u":"°C"}`);
    check!(int, ScaledUnit(Kilogram, 4))(2, `{"q":2e1,"u":"Mg"}`);
    check!(int, ScaledUnit(Metre ^^ 2, 5))(2, `{"q":2e5,"u":"m²"}`);
    check!(int, ScaledUnit(Second ^^ -1, 5))(2, `{"q":2e2,"u":"/ms"}`);
    check!(int, ScaledUnit(Watt, -31))(2, `{"q":2e-1,"u":"qW"}`);
    check!(int, ScaledUnit(Watt, 31))(2, `{"q":2e1,"u":"QW"}`);
    check!(int, ScaledUnit(Unit(), -2))(50, `{"q":50,"u":"%"}`);
    check!(double, Inch ^^ 2)(1, `{"q":6.4516e-4,"u":"m²"}`);
    check!double(1.2345678901234567, "1.2345678901234567");
    check!ulong(ulong.max, "18446744073709551615");

    // the reader walks a document as events; strings stay escaped until decoded
    {
        JsonReader r = JsonReader(`{"a": [1, -2.5e1, "x\ny"], "b": {"c": true, "d": null}, "e": false}`);
        assert(r.next() == JsonEvent.begin_object && r.depth == 1);
        assert(r.next() == JsonEvent.key && r.text == "a");
        assert(r.next() == JsonEvent.begin_array && r.depth == 2);
        assert(r.next() == JsonEvent.number && r.text == "1");
        assert(r.next() == JsonEvent.number && r.text == "-2.5e1");
        assert(r.next() == JsonEvent.text && r.text == `x\ny` && r.escaped);
        assert(r.next() == JsonEvent.end_array && r.depth == 1);
        assert(r.next() == JsonEvent.key && r.text == "b" && !r.escaped);
        assert(r.next() == JsonEvent.begin_object);
        assert(r.skip() == JsonEvent.end_object && r.depth == 1);
        assert(r.next() == JsonEvent.key && r.text == "e");
        assert(r.next() == JsonEvent.boolean && !r.boolean);
        assert(r.next() == JsonEvent.end_object && r.depth == 0);
        assert(r.next() == JsonEvent.eof && r.next() == JsonEvent.eof);
    }

    // malformed documents end in error, never a crash; trailing text fails the reader but not parse_json
    static JsonEvent last(const(char)[] doc)
    {
        JsonReader r = JsonReader(doc);
        JsonEvent e;
        do
            e = r.next();
        while (e != JsonEvent.eof && e != JsonEvent.error);
        return e;
    }
    foreach (bad_doc; [`{"a" 1}`, `[1,]`, `{"a":1,}`, `[1}`, `{"a":1]`, `"open`, `[1] x`, `{1:2}`, `[tru]`, ``, `-`])
        assert(last(bad_doc) == JsonEvent.error, bad_doc);
    assert(last(`  [1, {"k": []}]  `) == JsonEvent.eof);
    assert(parse_json(`[1] x`).length == 1);

    // nesting stops at max_json_depth
    {
        char[max_json_depth * 2 + 2] deep = void;
        deep[0 .. max_json_depth] = '[';
        deep[max_json_depth .. max_json_depth * 2] = ']';
        assert(last(deep[0 .. max_json_depth * 2]) == JsonEvent.eof);
        deep[0 .. max_json_depth + 1] = '[';
        deep[max_json_depth + 1 .. max_json_depth * 2 + 2] = ']';
        assert(last(deep[]) == JsonEvent.error && parse_json(deep[]).isNull);
    }

    // escapes decode to their characters, \u to UTF-8, and a surrogate pair to one code point
    {
        char[64] out_;
        ptrdiff_t n = decode_json_string(`a\nb\t\"\\\/\u00e9\ud83d\ude00`, out_[]);
        assert(n >= 0 && out_[0 .. n] == "a\nb\t\"\\/\xC3\xA9\xF0\x9F\x98\x80");
        foreach (bad; [`\x`, `\`, `\u12`, `\u12g4`, `\udc00`, `\ud83d`, `\ud83dx`, `\ud83d\u0041`])
            assert(decode_json_string(bad, out_[]) < 0, bad);
        assert(parse_json(`"\u00e9"`).asString == "\xC3\xA9");
        assert(parse_json(`["\q"]`).isNull);
    }

    // a string written with escapes reads back unchanged
    {
        Variant text = Variant("line\nbreak\t\"quoted\" back\\slash");
        ptrdiff_t n = text.write_json(buffer);
        assert(n > 0 && parse_json(buffer[0 .. n]).asString == text.asString);
    }
}
