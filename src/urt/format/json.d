module urt.format.json;

import urt.array;
import urt.conv;
import urt.lifetime;
import urt.kvp;
import urt.mem.allocator;
import urt.string;
import urt.string.format;

public import urt.variant;

nothrow @nogc:


Variant parse_json(const(char)[] text)
{
    return parse_node(text);
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

            const char[] s = val.asString();

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
            // escape strings
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

                // write escape sequence
                if (buffer.length < offset + 3)
                    return -1;
                buffer[offset++] = '\\';
                buffer[offset++] = sub;
            }
            buffer[offset++] = '"';
            return offset;

        case Variant.Type.Number:
            import urt.conv;

            if (val.isQuantity())
                assert(false, "TODO: implement quantity formatting for JSON");

            if (val.isDouble())
                return val.asDouble().format_float(buffer);

            // TODO: parse args?
            //format

            if (val.isUlong())
                return val.asUlong().format_uint(buffer);
            return val.asLong().format_int(buffer);

        case Variant.Type.User:
            // for custom types, we'll use the type's regular string format into a json string
            if (!buffer.ptr)
                return val.toString(null, null, null) + 2;
            if (buffer.length < 1)
                return -1;
            buffer[0] = '\"';
            ptrdiff_t len = val.toString(buffer[1 .. $], null, null);
            if (len < 0)
                return len;
            if (buffer.length < len + 2)
                return -1;
            buffer[1 + len] = '\"';
            return len + 2;
    }
}


unittest
{
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
}


private:

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

Variant parse_node(ref const(char)[] text)
{
    text = text.trimFront();

    if (text.empty)
        return Variant();
    else if (text.startsWith("null"))
    {
        text = text[4 .. $];
        return Variant();
    }
    else if (text.startsWith("true"))
    {
        text = text[4 .. $];
        return Variant(true);
    }
    else if (text.startsWith("false"))
    {
        text = text[5 .. $];
        return Variant(false);
    }
    else if (text[0] == '"')
    {
        assert(text.length > 1);
        size_t i = 1;
        while (i < text.length && text[i] != '"')
        {
            // TODO: we need to collapse the escape sequence, so we need to copy the string somewhere >_<
            //       ...overwrite the source buffer?
            if (text[i] == '\\')
            {
                assert(i + 1 < text.length);
                i += 2;
            }
            else
                i++;
        }
        assert(i < text.length);
        Variant node = Variant(text[1 .. i]);
        text = text[i + 1 .. $];
        return node;
    }
    else if (text[0] == '{' || text[0] == '[')
    {
        Array!Variant tmp;

        bool isArray = text[0] == '[';
        text = text[1 .. $];

        bool expectComma = false;
        while (true)
        {
            text = text.trimFront;
            if (text.length == 0 || text[0] == (isArray ? ']' : '}'))
                break;
            else if (expectComma)
            {
                if (text[0] == ',')
                    text = text[1 .. $].trimFront;
            }
            else
                expectComma = true;

            tmp ~= parse_node(text);
            if (!isArray)
            {
                assert(tmp.back().isString());

                text = text.trimFront;
                assert(text.length > 0 && text[0] == ':');
                text = text[1 .. $].trimFront;
                tmp ~= parse_node(text);
            }
        }
        assert(text.length > 0);
        text = text[1 .. $];

        Variant r = Variant(tmp.move);
        if (!isArray)
            r.flags = Variant.Flags.Map;
        return r;
    }
    else if (text[0].is_numeric || (text[0] == '-' && text.length > 1 && text[1].is_numeric))
    {
        size_t taken = void;
        int e = void;
        long value = text.parse_int_with_exponent(e, &taken, 10);
        assert(taken > 0);
        text = text[taken .. $];

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

        if (is_integer)
            return Variant(value);
        else
            return Variant(value * 10.0^^e);
    }
    else
        assert(false, "Invalid JSON!");
}
