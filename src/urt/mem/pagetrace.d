/**
 * Live page holders by call path, for memory budget work on a running system.
 *
 * Enabled with `version = MemStats;` (make MEMSTATS=1). page_alloc records the call path that asked
 * for each page and its release forgets it, so `page_trace_report` names who holds the pool's pages
 * right now, how many each path has held at most, and where allocations failed. Pages taken in an ISR
 * are not traced, and a page an ISR releases stays counted until its path is next reported.
 */
module urt.mem.pagetrace;

version (MemStats):

import urt.atomic;
import urt.mem.page;
import urt.sync.critical;

nothrow @nogc:


struct PageSite
{
    void*[frame_depth] frames;  // nearest caller of page_alloc first
    uint live;
    uint peak;
    uint allocs;
    uint fails;
    size_t bytes;               // capacity of the pages live
}

// Called by page_alloc with its own address, so the caller's frames are found on any unwinder.
void page_trace_alloc(Page* page, size_t capacity, const(void)* allocator)
{
    import urt.internal.exception : capture_trace;

    void*[frame_depth + 6] pcs = void;
    size_t n = capture_trace(pcs[]);
    size_t first = n;
    foreach (i; 0 .. n)
    {
        if (code_offset(pcs[i], allocator) < allocator_span)
        {
            first = i + 1;
            break;
        }
    }
    if (first == n)
        first = n < 2 ? n : 2;
    void*[frame_depth] key = null;
    foreach (i; 0 .. frame_depth)
        if (first + i < n)
            key[i] = pcs[first + i];

    auto guard = _lock.acquire();
    PageSite* site = find_site(key);
    if (!site)
    {
        ++_overflow;
        return;
    }
    if (!page)
    {
        ++site.fails;
        return;
    }
    ++site.allocs;
    if (!insert(page, cast(ushort)(site - _sites.ptr)))
    {
        ++_untracked;
        return;
    }
    site.bytes += capacity;
    if (++site.live > site.peak)
        site.peak = site.live;
}

void page_trace_free(Page* page)
{
    auto guard = _lock.acquire();
    size_t i = slot_of(page);
    if (i == size_t.max)
        return;
    PageSite* site = &_sites[_entries[i].site];
    --site.live;
    site.bytes -= page.capacity;
    remove_at(i);
}

// one line per call path that has allocated or failed, the most pages live first
void page_trace_report(scope void delegate(const(char)[]) nothrow @nogc sink)
{
    import urt.string.format : tconcat;

    PageSite[max_sites] sites = void;
    uint count, overflow, untracked;
    {
        auto guard = _lock.acquire();
        count = _site_count;
        sites[0 .. count] = _sites[0 .. count];
        overflow = _overflow;
        untracked = _untracked;
    }
    foreach (i; 1 .. count)
    {
        PageSite s = sites[i];
        size_t j = i;
        for (; j > 0 && (sites[j - 1].live < s.live || (sites[j - 1].live == s.live && sites[j - 1].allocs < s.allocs)); --j)
            sites[j] = sites[j - 1];
        sites[j] = s;
    }

    sink("live  peak     bytes   allocs  fails  call path");
    foreach (ref s; sites[0 .. count])
        sink(tconcat(pad(s.live, 4), "  ", pad(s.peak, 4), "  ", pad(s.bytes, 8), "  ", pad(s.allocs, 7), "  ", pad(s.fails, 5), "  ", describe(s.frames)));
    if (overflow || untracked)
        sink(tconcat("allocations past the site table: ", overflow, ", pages past the live table: ", untracked));
}


private:

enum size_t frame_depth = 4;
enum size_t allocator_span = 512;   // a return address inside page_alloc lies this close to its entry
enum size_t max_sites = 96;
version (Embedded)
    enum size_t max_entries = 512;
else
    enum size_t max_entries = 16384;
static assert((max_entries & (max_entries - 1)) == 0);

struct Entry
{
    Page* page;     // null is empty; removal shifts back, so there are no tombstones
    ushort site;
}

__gshared Critical _lock;
__gshared PageSite[max_sites] _sites;
__gshared uint _site_count;
__gshared Entry[max_entries] _entries;
__gshared uint _overflow;
__gshared uint _untracked;

// return addresses on a windowed core carry the window increment in their top bits
size_t code_offset(const(void)* pc, const(void)* entry)
{
    version (Xtensa)
        enum size_t mask = 0x3FFF_FFFF;
    else
        enum size_t mask = size_t.max;
    return ((cast(size_t)pc & mask) - (cast(size_t)entry & mask)) & mask;
}

PageSite* find_site(ref void*[frame_depth] key)
{
    foreach (ref s; _sites[0 .. _site_count])
        if (s.frames == key)
            return &s;
    if (_site_count == max_sites)
        return null;
    PageSite* s = &_sites[_site_count++];
    *s = PageSite.init;
    s.frames = key;
    return s;
}

size_t home(const(Page)* page)
    => (cast(size_t)page >> 4) & (max_entries - 1);

bool insert(Page* page, ushort site)
{
    size_t i = home(page);
    foreach (_; 0 .. max_entries)
    {
        if (!_entries[i].page)
        {
            _entries[i] = Entry(page, site);
            return true;
        }
        i = (i + 1) & (max_entries - 1);
    }
    return false;
}

size_t slot_of(const(Page)* page)
{
    size_t i = home(page);
    foreach (_; 0 .. max_entries)
    {
        if (_entries[i].page is page)
            return i;
        if (!_entries[i].page)
            return size_t.max;
        i = (i + 1) & (max_entries - 1);
    }
    return size_t.max;
}

void remove_at(size_t i)
{
    size_t j = i;
    while (true)
    {
        j = (j + 1) & (max_entries - 1);
        if (!_entries[j].page)
            break;
        size_t k = home(_entries[j].page);
        // the entry at j may fill the hole at i unless its home lies cyclically in (i, j]
        if (i <= j ? (i < k && k <= j) : (i < k || k <= j))
            continue;
        _entries[i] = _entries[j];
        i = j;
    }
    _entries[i] = Entry.init;
}

const(char)[] pad(size_t value, size_t width)
{
    import urt.mem.temp : talloc;
    import urt.conv : format_uint;
    char[] text = cast(char[])talloc(width < 20 ? 20 : width);
    char[20] digits = void;
    size_t n = format_uint(value, digits[]);
    size_t lead = n < width ? width - n : 0;
    text[0 .. lead] = ' ';
    text[lead .. lead + n] = digits[0 .. n];
    return text[0 .. lead + n];
}

// function names where the target can resolve them, addresses to resolve offline where it cannot
const(char)[] describe(ref const void*[frame_depth] frames)
{
    import urt.internal.exception : demangle_symbol, resolve_address, Resolved;
    import urt.string : trim;
    import urt.string.format : tconcat;

    // built locally: a lookup may reuse the temporary space an earlier name was formatted in
    char[640] text = void;
    size_t length;
    foreach (i, f; frames)
    {
        if (!f)
            break;
        char[256] name = void;
        Resolved r;
        const(char)[] part = resolve_address(cast(void*)f, r) && r.name.length ? demangle_symbol(r.name, name[]).trim!(c => c <= ' ') : tconcat(f);
        const(char)[] sep = i ? " <- " : "";
        if (length + sep.length + part.length > text.length)
            break;
        text[length .. length + sep.length] = sep;
        length += sep.length;
        text[length .. length + part.length] = part;
        length += part.length;
    }
    return tconcat(text[0 .. length]);
}


unittest
{
    import urt.mem.pagepool : page_pool_init, page_pool_deinit, page_alloc, page_free;

    bool owns_pool = page_pool_init();
    scope (exit) if (owns_pool) page_pool_deinit();

    static Page* held_here()
    {
        pragma(inline, false);
        return page_alloc(64);
    }

    Page*[3] pages;
    foreach (ref p; pages)
        p = held_here();
    uint live, peak;
    bool named;
    page_trace_report((const(char)[] line) {
        import urt.string : contains, trim;
        if (line.contains("pagetrace.__unittest"))
        {
            named = true;
            import urt.conv : parse_int;
            size_t taken;
            live = cast(uint)parse_int(line.trim, &taken);
        }
    });
    foreach (p; pages)
        page_free(p);
    version (Windows)
        assert(named && live == 3, "the caller of page_alloc heads its path");
    else version (linux)
        assert(named && live == 3, "the caller of page_alloc heads its path");

    size_t after;
    page_trace_report((const(char)[] line) {
        import urt.string : contains, trim;
        if (line.contains("pagetrace.__unittest"))
        {
            import urt.conv : parse_int;
            size_t taken;
            after = cast(size_t)parse_int(line.trim, &taken);
        }
    });
    version (Windows)
        assert(after == 0, "released pages leave their path");
    else version (linux)
        assert(after == 0, "released pages leave their path");
}
