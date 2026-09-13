module urt.format.xml;

import urt.array : takeFront;
import urt.conv;
import urt.string;
import urt.string.uni : uni_convert;

nothrow @nogc:


enum max_xml_depth = 32;

enum XmlEvent : ubyte
{
    none,
    start,
    end,
    text,
    eof,
    error,
}

struct XmlAttr
{
    const(char)[] prefix;
    const(char)[] name;
    const(char)[] value;
}

// Pull tokenizer over a complete document. Names and values are slices of the input; text and
// attribute values are raw (still escaped) and decode with decode_xml.
struct XmlReader
{
nothrow @nogc:

    this(const(char)[] text) pure
    {
        _text = text;
    }

    XmlEvent event() const pure
        => _event;
    const(char)[] prefix() const pure
        => _prefix;
    const(char)[] name() const pure
        => _name;
    const(char)[] text() const pure
        => _content;
    bool cdata() const pure
        => _cdata;
    int depth() const pure
        => _depth;

    XmlEvent next()
    {
        if (_event == XmlEvent.eof || _event == XmlEvent.error)
            return _event;
        if (_empty_element)
        {
            _empty_element = false;
            return end_element(_name, _prefix);
        }

        while (true)
        {
            if (_text.empty)
                return _depth == 0 ? set(XmlEvent.eof) : fail();

            if (_text[0] != '<')
            {
                const(char)[] t = _text.takeFront(_text.findFirst('<'));
                if (_depth == 0 || t.trimFront.empty)
                    continue;
                _content = t;
                _cdata = false;
                return set(XmlEvent.text);
            }

            if (_text.startsWith("<![CDATA["))
            {
                _text = _text[9 .. $];
                size_t i = _text.findFirst("]]>");
                if (i == _text.length)
                    return fail();
                _content = _text.takeFront(i);
                _text = _text[3 .. $];
                _cdata = true;
                return set(XmlEvent.text);
            }
            if (_text.startsWith("<!--"))
            {
                if (!skip_past("-->", 4))
                    return fail();
                continue;
            }
            if (_text.startsWith("<?"))
            {
                if (!skip_past("?>", 2))
                    return fail();
                continue;
            }
            if (_text.startsWith("<!"))
            {
                if (!skip_past(">", 2))
                    return fail();
                continue;
            }

            if (_text.length > 1 && _text[1] == '/')
            {
                _text = _text[2 .. $];
                const(char)[] prefix, name;
                if (!take_name(prefix, name))
                    return fail();
                _text = _text.trimFront;
                if (_text.empty || _text[0] != '>')
                    return fail();
                _text = _text[1 .. $];
                return end_element(name, prefix);
            }

            _text = _text[1 .. $];
            if (!take_name(_prefix, _name))
                return fail();
            if (_depth == max_xml_depth)
                return fail();

            size_t i = 0;
            bool self_closing = false;
            while (true)
            {
                if (i == _text.length)
                    return fail();
                char c = _text[i];
                if (c == '>')
                    break;
                if (c == '/' && i + 1 < _text.length && _text[i + 1] == '>')
                {
                    self_closing = true;
                    break;
                }
                if (c == '"' || c == '\'')
                {
                    i += 1 + _text[i + 1 .. $].findFirst(c);
                    if (i == _text.length)
                        return fail();
                }
                ++i;
            }
            _attrs = _text.takeFront(i);
            _text = _text[self_closing ? 2 : 1 .. $];
            _stack[_depth++] = _name;
            _empty_element = self_closing;
            return set(XmlEvent.start);
        }
    }

    // Attributes of the current start element, lazily scanned.
    auto attributes() const pure
    {
        static struct Range
        {
        nothrow @nogc:
            const(char)[] text;
            XmlAttr front;
            bool empty = true;

            this(const(char)[] attrs) pure
            {
                text = attrs;
                popFront();
            }
            void popFront() pure
            {
                text = text.trimFront;
                empty = text.empty;
                if (empty)
                    return;
                size_t i = 0;
                while (i < text.length && text[i] != '=' && !text[i].is_space)
                    ++i;
                split_name(text[0 .. i], front.prefix, front.name);
                text = text[i .. $].trimFront;
                if (text.empty || text[0] != '=')
                {
                    text = null;
                    empty = true;
                    return;
                }
                text = text[1 .. $].trimFront;
                if (text.empty || (text[0] != '"' && text[0] != '\''))
                {
                    text = null;
                    empty = true;
                    return;
                }
                char quote = text[0];
                text = text[1 .. $];
                size_t q = text.findFirst(quote);
                if (q == text.length)
                {
                    text = null;
                    empty = true;
                    return;
                }
                front.value = text.takeFront(q);
                text = text[1 .. $];
            }
        }
        return Range(_event == XmlEvent.start ? _attrs : null);
    }

    const(char)[] attribute(const(char)[] name) const pure
    {
        foreach (ref a; attributes)
        {
            if (a.name == name)
                return a.value;
        }
        return null;
    }

    // Consume the current element through its end tag, returning its raw text content.
    const(char)[] element_text()
    {
        if (_event != XmlEvent.start)
            return null;
        int target = _depth - 1;
        const(char)[] result;
        while (true)
        {
            XmlEvent e = next();
            if (e == XmlEvent.text)
                result = _content;
            else if (e == XmlEvent.start)
                skip();
            else if (e == XmlEvent.end && _depth == target)
                return result;
            else if (e != XmlEvent.end)
                return null;
        }
    }

    long element_int()
    {
        const(char)[] t = element_text().trim;
        size_t taken;
        long r = t.parse_int(&taken);
        return taken == t.length && taken > 0 ? r : 0;
    }

    ulong element_uint(uint base = 10)
    {
        const(char)[] t = element_text().trim;
        size_t taken;
        ulong r = t.parse_uint(&taken, base);
        return taken == t.length && taken > 0 ? r : 0;
    }

    bool element_bool()
    {
        const(char)[] t = element_text().trim;
        return t == "true" || t == "1";
    }

    // Skip the remainder of the current element's subtree.
    void skip()
    {
        if (_event != XmlEvent.start)
            return;
        int target = _depth - 1;
        while (true)
        {
            XmlEvent e = next();
            if (e == XmlEvent.eof || e == XmlEvent.error || (e == XmlEvent.end && _depth == target))
                return;
        }
    }

private:
    const(char)[] _text;
    const(char)[] _attrs;
    const(char)[] _prefix;
    const(char)[] _name;
    const(char)[] _content;
    const(char)[][max_xml_depth] _stack;
    int _depth;
    XmlEvent _event;
    bool _empty_element;
    bool _cdata;

    XmlEvent set(XmlEvent e) pure
    {
        _event = e;
        return e;
    }

    XmlEvent fail() pure
    {
        _text = null;
        return set(XmlEvent.error);
    }

    XmlEvent end_element(const(char)[] name, const(char)[] prefix) pure
    {
        if (_depth == 0 || _stack[_depth - 1] != name)
            return fail();
        --_depth;
        _name = name;
        _prefix = prefix;
        return set(XmlEvent.end);
    }

    bool skip_past(const(char)[] terminator, size_t from) pure
    {
        size_t i = from + _text[from .. $].findFirst(terminator);
        if (i == _text.length)
            return false;
        _text = _text[i + terminator.length .. $];
        return true;
    }

    bool take_name(out const(char)[] prefix, out const(char)[] name) pure
    {
        size_t i = 0;
        while (i < _text.length && is_name_char(_text[i]))
            ++i;
        if (i == 0)
            return false;
        split_name(_text.takeFront(i), prefix, name);
        return true;
    }

    static void split_name(const(char)[] qname, out const(char)[] prefix, out const(char)[] name) pure
    {
        name = qname;
        prefix = name.split!(':', false, false);
        if (name.empty)
        {
            name = prefix;
            prefix = null;
        }
    }

    static bool is_name_char(char c) pure
        => c.is_alpha || c.is_numeric || c == '_' || c == '-' || c == '.' || c == ':' || c >= 0x80;
}

// Expand entity and character references. A null dst returns the decoded length; dst never needs to be
// longer than src.
ptrdiff_t decode_xml(const(char)[] src, char[] dst) pure
{
    size_t len = 0;
    size_t i = 0;
    while (i < src.length)
    {
        char c = src[i++];
        if (c == '&')
        {
            size_t semi = i;
            while (semi < src.length && src[semi] != ';')
                ++semi;
            if (semi == src.length)
                return -1;
            const(char)[] ent = src[i .. semi];
            i = semi + 1;
            dchar code;
            if (ent == "amp")
                code = '&';
            else if (ent == "lt")
                code = '<';
            else if (ent == "gt")
                code = '>';
            else if (ent == "quot")
                code = '"';
            else if (ent == "apos")
                code = '\'';
            else if (ent.length > 1 && ent[0] == '#')
            {
                size_t taken;
                bool hex = ent[1] == 'x';
                ulong v = ent[(hex ? 2 : 1) .. $].parse_uint(&taken, hex ? 16 : 10);
                if (taken != ent.length - (hex ? 2 : 1))
                    return -1;
                code = cast(dchar)v;
            }
            else
                return -1;

            char[4] utf = void;
            size_t n = uni_convert((&code)[0 .. 1], utf);
            if (n == 0)
                return -1;
            if (dst.ptr)
            {
                if (len + n > dst.length)
                    return -1;
                dst[len .. len + n] = utf[0 .. n];
            }
            len += n;
            continue;
        }
        if (dst.ptr)
        {
            if (len == dst.length)
                return -1;
            dst[len] = c;
        }
        ++len;
    }
    return len;
}

// Serialiser into a caller buffer. length always reports the bytes the document needs, so a null buffer
// measures and an overflowed one is retried larger. Element names must outlive the writer.
struct XmlWriter
{
nothrow @nogc:

    this(char[] buffer) pure
    {
        _buffer = buffer;
    }

    size_t length() const pure
        => _length;
    bool overflow() const pure
        => _length > _buffer.length;
    char[] result() pure
        => overflow ? null : _buffer[0 .. _length];

    void declaration() pure
    {
        put(`<?xml version="1.0" encoding="UTF-8"?>`);
    }

    void open(const(char)[] name) pure
    {
        close_start_tag();
        put('<');
        put(name);
        if (_depth < max_xml_depth)
            _stack[_depth] = name;
        ++_depth;
        _open = true;
    }

    void close() pure
    {
        if (_depth == 0)
            return;
        --_depth;
        if (_open)
        {
            put("/>");
            _open = false;
            return;
        }
        put("</");
        put(_depth < max_xml_depth ? _stack[_depth] : "");
        put('>');
    }

    void element(T)(const(char)[] name, T value) pure
    {
        open(name);
        text(value);
        close();
    }

    void attr(const(char)[] name, const(char)[] value) pure
    {
        if (!_open)
            return;
        put(' ');
        put(name);
        put(`="`);
        escape(value, true);
        put('"');
    }
    void attr(const(char)[] name, long value) pure
    {
        char[24] tmp = void;
        attr(name, tmp[0 .. value.format_int(tmp)]);
    }
    void attr(const(char)[] name, ulong value, uint base = 10) pure
    {
        char[24] tmp = void;
        attr(name, tmp[0 .. value.format_uint(tmp, base)]);
    }
    void attr(const(char)[] name, bool value) pure
    {
        attr(name, value ? "true" : "false");
    }

    void text(const(char)[] value) pure
    {
        close_start_tag();
        escape(value, false);
    }
    void text(long value) pure
    {
        char[24] tmp = void;
        text(tmp[0 .. value.format_int(tmp)]);
    }
    void text(ulong value, uint base = 10) pure
    {
        char[24] tmp = void;
        text(tmp[0 .. value.format_uint(tmp, base)]);
    }
    void text(bool value) pure
    {
        text(value ? "true" : "false");
    }
    void text(double value) pure
    {
        char[32] tmp = void;
        ptrdiff_t n = value.format_float(tmp);
        text(n > 0 ? tmp[0 .. n] : "0");
    }

    void raw(const(char)[] value) pure
    {
        close_start_tag();
        put(value);
    }

private:
    char[] _buffer;
    size_t _length;
    const(char)[][max_xml_depth] _stack;
    int _depth;
    bool _open;

    void close_start_tag() pure
    {
        if (_open)
        {
            put('>');
            _open = false;
        }
    }

    void put(char c) pure
    {
        if (_length < _buffer.length)
            _buffer[_length] = c;
        ++_length;
    }

    void put(const(char)[] s) pure
    {
        if (_length + s.length <= _buffer.length)
            _buffer[_length .. _length + s.length] = s[];
        _length += s.length;
    }

    void escape(const(char)[] s, bool in_attr) pure
    {
        foreach (c; s)
        {
            switch (c)
            {
                case '&':  put("&amp;");  break;
                case '<':  put("&lt;");   break;
                case '>':  put("&gt;");   break;
                case '"':  in_attr ? put("&quot;") : put(c); break;
                default:   put(c);        break;
            }
        }
    }
}


unittest
{
    enum doc = `<?xml version="1.0" encoding="UTF-8"?>
<!-- a DERControl, roughly -->
<DERControl xmlns="urn:ieee:std:2030.5:ns" xmlns:csipaus="https://csipaus.org/ns" href="/derp/1/derc/3" responseRequired='07'>
  <mRID>0123456789ABCDEF0123456789ABCDEF</mRID>
  <description>Export &amp; import &lt;limits&gt; &#x41;&#66;</description>
  <interval><duration>3600</duration><start>1700000000</start></interval>
  <DERControlBase>
    <opModExpLimW><multiplier>3</multiplier><value>1500</value></opModExpLimW>
    <csipaus:opModImpLimW><value>-5</value></csipaus:opModImpLimW>
    <opModEnergize>true</opModEnergize>
  </DERControlBase>
  <note><![CDATA[raw <text> & stuff]]></note>
  <empty/>
</DERControl>`;

    auto r = XmlReader(doc);
    assert(r.next() == XmlEvent.start && r.name == "DERControl" && r.depth == 1);
    assert(r.attribute("href") == "/derp/1/derc/3");
    assert(r.attribute("responseRequired") == "07");
    assert(r.attribute("missing") is null);
    size_t attrs = 0;
    foreach (ref a; r.attributes)
    {
        ++attrs;
        if (a.name == "csipaus")
            assert(a.prefix == "xmlns" && a.value == "https://csipaus.org/ns");
    }
    assert(attrs == 4);

    assert(r.next() == XmlEvent.start && r.name == "mRID");
    assert(r.element_text() == "0123456789ABCDEF0123456789ABCDEF");
    assert(r.event == XmlEvent.end && r.name == "mRID" && r.depth == 1);

    assert(r.next() == XmlEvent.start && r.name == "description");
    const(char)[] raw = r.element_text();
    char[64] buf = void;
    ptrdiff_t n = decode_xml(raw, buf);
    assert(decode_xml(raw, null) == n);
    assert(buf[0 .. n] == "Export & import <limits> AB");

    assert(r.next() == XmlEvent.start && r.name == "interval");
    assert(r.next() == XmlEvent.start && r.name == "duration");
    assert(r.element_int() == 3600);
    assert(r.next() == XmlEvent.start && r.name == "start");
    assert(r.element_uint() == 1700000000);
    assert(r.next() == XmlEvent.end && r.name == "interval");

    assert(r.next() == XmlEvent.start && r.name == "DERControlBase" && r.depth == 2);
    assert(r.next() == XmlEvent.start && r.name == "opModExpLimW");
    r.skip();
    assert(r.event == XmlEvent.end && r.name == "opModExpLimW" && r.depth == 2);
    assert(r.next() == XmlEvent.start && r.prefix == "csipaus" && r.name == "opModImpLimW");
    assert(r.next() == XmlEvent.start && r.name == "value");
    assert(r.element_int() == -5);
    assert(r.next() == XmlEvent.end && r.prefix == "csipaus" && r.name == "opModImpLimW");
    assert(r.next() == XmlEvent.start && r.name == "opModEnergize");
    assert(r.element_bool());
    assert(r.next() == XmlEvent.end && r.name == "DERControlBase");

    assert(r.next() == XmlEvent.start && r.name == "note");
    assert(r.next() == XmlEvent.text && r.cdata && r.text == "raw <text> & stuff");
    assert(r.next() == XmlEvent.end);
    assert(r.next() == XmlEvent.start && r.name == "empty");
    assert(r.next() == XmlEvent.end && r.name == "empty");
    assert(r.next() == XmlEvent.end && r.name == "DERControl" && r.depth == 0);
    assert(r.next() == XmlEvent.eof);
    assert(r.next() == XmlEvent.eof);

    // malformed documents fail rather than crash
    assert(XmlReader("<a><b></a>").skip_all() == XmlEvent.error);
    assert(XmlReader("<a>").skip_all() == XmlEvent.error);
    assert(XmlReader("<a x='1></a>").skip_all() == XmlEvent.error);
    assert(XmlReader("<!-- unterminated").skip_all() == XmlEvent.error);
    assert(XmlReader("<a><![CDATA[x]]</a>").skip_all() == XmlEvent.error);
    assert(XmlReader("junk before <a/>").skip_all() == XmlEvent.eof);
    assert(decode_xml("&bogus;", null) == -1);
    assert(decode_xml("&#x110000;", null) == -1);
    assert(decode_xml("a&amp", null) == -1);

    char[3 * (max_xml_depth + 1)] deep = void;
    foreach (i; 0 .. max_xml_depth + 1)
        deep[i * 3 .. i * 3 + 3] = "<a>";
    assert(XmlReader(deep[]).skip_all() == XmlEvent.error);

    // writer
    char[256] out_buf = void;
    auto w = XmlWriter(out_buf);
    w.declaration();
    w.open("Response");
    w.attr("xmlns", "urn:ieee:std:2030.5:ns");
    w.attr("count", 2L);
    w.element("subject", "0123ABCD");
    w.open("status");
    w.text(ulong(255), 16);
    w.close();
    w.element("ok", true);
    w.element("note", `a<b>&"c"`);
    w.open("empty");
    w.attr("q", `x"y`);
    w.close();
    w.close();
    enum expect = `<?xml version="1.0" encoding="UTF-8"?><Response xmlns="urn:ieee:std:2030.5:ns" count="2"><subject>0123ABCD</subject><status>FF</status><ok>true</ok><note>a&lt;b&gt;&amp;"c"</note><empty q="x&quot;y"/></Response>`;
    assert(!w.overflow && w.result == expect);

    auto measure = XmlWriter(null);
    measure.open("a");
    measure.element("b", 1L);
    measure.close();
    assert(measure.overflow && measure.length == `<a><b>1</b></a>`.length);

    // round trip
    auto rt = XmlReader(w.result);
    assert(rt.next() == XmlEvent.start && rt.name == "Response" && rt.attribute("count") == "2");
    assert(rt.next() == XmlEvent.start && rt.name == "subject" && rt.element_text() == "0123ABCD");
    assert(rt.next() == XmlEvent.start && rt.element_uint(16) == 255);
    assert(rt.next() == XmlEvent.start && rt.element_bool());
    assert(rt.next() == XmlEvent.start && rt.name == "note");
    n = decode_xml(rt.element_text(), buf);
    assert(buf[0 .. n] == `a<b>&"c"`);
}

version (unittest)
{
    XmlEvent skip_all(ref XmlReader r)
    {
        XmlEvent e;
        do
            e = r.next();
        while (e != XmlEvent.eof && e != XmlEvent.error);
        return e;
    }
}
