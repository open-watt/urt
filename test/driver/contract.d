// The UART and event-link contracts, run against a backend compiled over its register model.
module tests.driver.contract;

import urt.attribute : isr_safe;
import urt.driver.event;
import urt.driver.gpio : GpioInterruptTrigger, GpioLine;
import urt.driver.uart;
import urt.mem.page : Page, page_chain_span;
import urt.mem.pagepool : page_alloc, page_free;
import urt.result : InternalResult, Result;
import urt.time : Duration, getTime, msecs;

import fixture;
import model.cpu : storms;
import urt.driver.posix.alloc : fail_after, live;

nothrow @nogc:

int main()
{
    uart_contract();
    event_contract();
    assert(storms == 0, "an interrupt stayed asserted after its handler ran");
    import core.stdc.stdio : printf;
    printf("driver contract passed\n");
    return 0;
}


private:

__gshared uint rx_calls, tx_calls;

bool on_rx(Uart, UartCallbackContext)
{
    ++rx_calls;
    return false;
}

bool on_tx(Uart, UartCallbackContext)
{
    ++tx_calls;
    return false;
}

uint chars_in(ref const UartConfig cfg, UartRxTiming timing)
    => cast(uint)((ulong(timing.latency_us) * cfg.baud_rate + 10_000_000 - 1) / 10_000_000);

Duration timed(alias f)()
{
    immutable t0 = getTime();
    f();
    return getTime() - t0;
}

// the bytes as a chain of pages of at most `size`, so a send walks page boundaries
Page* chain_of(const(void)[] data, size_t size = 100)
{
    const(ubyte)[] bytes = cast(const(ubyte)[])data;
    Page* head, tail;
    while (bytes.length)
    {
        immutable size_t n = bytes.length < size ? bytes.length : size;
        Page* page = page_alloc(n);
        (cast(ubyte[])page.data)[] = bytes[0 .. n];
        if (tail)
            tail.next = page;
        else
            head = page;
        tail = page;
        bytes = bytes[n .. $];
    }
    return head;
}

bool send(ref Uart u, const(void)[] data)
{
    Page* chain = chain_of(data);
    if (uart_send(u, chain))
        return true;
    free_chain(chain);
    return false;
}

uint pages_in_use()
{
    import urt.mem.pagepool : page_category_heap, page_pool_num_categories, page_pool_stats;
    uint pages = page_pool_stats(page_category_heap).pages_in_use;
    foreach (ubyte category; 0 .. cast(ubyte)page_pool_num_categories())
        pages += page_pool_stats(category).pages_in_use;
    return pages;
}

void free_chain(Page* page)
{
    while (page)
    {
        Page* next = page.next;
        page_free(page);
        page = next;
    }
}

// takes everything received into buf and frees the pages; gaps counts the bursts a quiet line ended, and gap says
// whether one ended the last
size_t read(ref Uart u, ubyte[] buf, bool* gap = null, size_t* gaps = null)
{
    size_t got;
    Page* chain = uart_rx_take(u);
    foreach (i; 0 .. uart_burst_count(chain))
    {
        UartBurst burst = uart_burst(chain, i);
        assert(got + burst.length <= buf.length, "the read buffer holds what arrived");
        for (size_t at = 0; at < burst.length; )
        {
            const(ubyte)[] span = cast(const(ubyte)[])page_chain_span(chain, burst.offset + at, burst.length - at);
            buf[got + at .. got + at + span.length] = span[];
            at += span.length;
        }
        got += burst.length;
        if (gap)
            *gap = burst.gap;
        if (gaps)
            *gaps += burst.gap;
    }
    free_chain(chain);
    return got;
}

void uart_contract()
{
    import urt.driver.uart_core : tx_drain_limit;
    import urt.mem.pagepool : page_pool_deinit, page_pool_init;

    reset();
    UartConfig cfg;
    Uart u, dup;

    UartConfig bad;
    bad.baud_rate = 0;
    assert(uart_open(u, uart_port, bad) == InternalResult.invalid_parameter, "a zero baud rate is refused");
    bad = cfg;
    foreach (m; DriveMode.polled .. DriveMode.auto_)
    {
        if (uart_drive_modes & 1 << m)
            continue;
        bad.drive_mode = m;
        assert(uart_open(u, uart_port, bad) == InternalResult.unsupported, "a drive mode the backend lacks is refused");
    }

    foreach (i; 0 .. 7)
    {
        bad = cfg;
        final switch (i)
        {
            case 0: bad.data_bits = 4; break;
            case 1: bad.parity = Parity.mark; break;
            case 2: bad.stop_bits = StopBits.half; break;
            case 3: bad.flow_control = FlowControl.software; break;
            case 4: bad.rs485.enabled = true; break;
            case 5: bad.tx_gpio = 1; break;
            case 6: bad.data_bits = 9; break;
        }
        if (!uart_config_supported(bad))
            assert(uart_open(u, uart_port, bad) == InternalResult.unsupported, "a setting the backend cannot honour is refused");
    }

    immutable int baseline = live;
    assert(!uart_open(u, uart_port, cfg, &on_rx) && live == baseline, "a port does not open before the page pool, and takes nothing");
    immutable bool owns_pool = page_pool_init();
    immutable uint pages = pages_in_use();

    static if (uart_has_pin_select)
    {
        bad = cfg;
        bad.tx_gpio = 254;
        assert(!uart_open(u, uart_port, bad), "a pin the part lacks is refused, not asserted on");
        bad.tx_gpio = wrong_tx_pin;
        assert(!uart_open(u, uart_port, bad) && pin_function(wrong_tx_pin) == 0, "a pin that does not carry the signal is refused, untouched");
        bad = cfg;
        bad.tx_gpio = alt_tx_pin;
        bad.rx_gpio = alt_rx_pin;
        assert(uart_open(u, uart_port, bad), "a pin that carries the signal is taken");
        assert(pin_function(alt_tx_pin) == alt_af && pin_function(alt_rx_pin) == alt_af, "through the function that carries it");
        uart_close(u);
    }

    bad = cfg;
    bad.baud_rate = 1;
    assert(!uart_open(u, uart_port, bad), "a rate no divider reaches is refused");
    foreach (rate; [ 300, 1200, 9600, 115_200, 921_600, 2_000_000, 10_000_000 ])
    {
        bad.baud_rate = rate;
        if (!uart_open(u, uart_port, bad))
            continue;
        immutable uint got = programmed_baud();
        uart_close(u);
        assert((got > rate ? got - rate : rate - got) * 100 <= rate * 3, "an accepted rate is the rate programmed");
    }
    bad.baud_rate = 115_200;
    assert(uart_open(u, uart_port, bad), "115200 is reachable everywhere");
    assert(programmed_baud() > 115_200 * 97 / 100 && programmed_baud() < 115_200 * 103 / 100);
    uart_close(u);
    reset();

    assert(uart_open(u, uart_port, cfg, &on_rx, &on_tx));
    assert(uart_open(dup, uart_port, cfg) == InternalResult.already_exists, "an open port is not opened twice");
    assert(uart_open(u, other_port, cfg) == InternalResult.already_exists && u.port == uart_port, "an open handle is not opened again");

    UartRxTiming timing = uart_rx_timing(u);
    assert(timing.latency_us > 0 && timing.latency_us <= cfg.rx_latency_us, "an open port reports its RX timing");

    tx_calls = 0;
    assert(send(u, "hello"));
    uart_tx_flush(u);
    assert(wire() == "hello" && uart_tx_queued(u) == 0, "sent bytes reach the line in order");
    assert(tx_calls == 1 && pages_in_use() == pages, "and the page is released, signalling room");

    wire_clear();
    tx_hold(true);
    __gshared ubyte[3000] big;
    foreach (i, ref b; big)
        b = cast(ubyte)(i * 7);
    tx_calls = 0;
    bool sent;
    immutable stall = timed!(() { sent = send(u, big[]); })();
    assert(sent && stall < 20.msecs, "a stalled line takes the whole chain, and the send does not wait for it");
    assert(uart_tx_queued(u) > 0 && uart_tx_queued(u) <= big.length, "and holds what has not reached the FIFO");
    assert(timed!(() => uart_tx_flush(u))() < tx_drain_limit + 200.msecs, "a flush against a stalled line is bounded");
    tx_hold(false);
    run_line();
    assert(wire() == big[] && uart_tx_queued(u) == 0, "a released line sends the whole chain, in order, with no further call");
    assert(tx_calls == (big.length + 99) / 100 && pages_in_use() == pages, "releasing every page, each signalling room");

    // written bytes share pages, and go out ahead of what is sent after them
    wire_clear();
    tx_hold(true);
    foreach (i; 0 .. 200)
        assert(uart_write(u, big[i * 5 .. i * 5 + 5]) == 5);
    assert(uart_tx_queued(u) > 0 && pages_in_use() <= pages + 1000 / 300 + 1, "short writes share pages");
    send(u, big[1000 .. 1100]);
    assert(uart_write(u, big[1100 .. 1200]) == 100);
    tx_hold(false);
    run_line();
    assert(wire() == big[0 .. 1200] && pages_in_use() == pages, "and everything goes out in the order it was given");

    ubyte[600] buf;
    static if (has_rx_timing)
    {
        wire_clear();
        tx_hold(true);
        send(u, big[0 .. 100]);
        immutable size_t queued = uart_tx_queued(u);
        rx_overrun();
        rx('<');
        UartConfig slow = cfg;
        slow.rx_latency_us = 2000;
        slow.rx_gap = 50;
        assert(uart_set_rx_timing(u, slow) == uart_rx_timing(u), "a retime reports the timing the port runs with");
        assert(uart_tx_queued(u) == queued, "and leaves queued TX alone");
        tx_hold(false);
        run_line();
        assert(wire() == big[0 .. 100], "which is sent");
        line_idle();
        assert(read(u, buf[]) == 1 && buf[0] == '<', "as is what arrived before the retime");
        assert(uart_check_errors(u) & UartError.overrun, "and the errors it had not reported");
        immutable UartRxTiming retimed = uart_rx_timing(u);
        static if (retimes_latency_live)
            assert(retimed.latency_us > timing.latency_us, "the new latency runs at once");
        else
            assert(retimed.latency_us == timing.latency_us, "or the old one, reported as such, until the port next opens");
        static if (programs_rx_gap)
            assert(uart_gap_tenths(slow, rx_gap_bits()) == retimed.gap, "with the gap it reports programmed");
        immutable uint trigger = chars_in(slow, retimed);
        rx_calls = 0;
        foreach (i; 0 .. trigger - 1)
            rx(cast(ubyte)i);
        assert(rx_calls == 0, "a burst short of the reported threshold waits");
        rx(cast(ubyte)(trigger - 1));
        assert(rx_calls > 0, "and the threshold delivers it");
        size_t delivered = read(u, buf[]);
        assert(delivered + 1 >= trigger);
        immutable uint before_gap = rx_calls;
        line_idle();
        assert(rx_calls > before_gap, "a gap that ends a frame already taken is still heard");
        assert(delivered + read(u, buf[delivered .. $]) == trigger && buf[trigger - 1] == trigger - 1);

        assert(uart_set_rx_timing(u, cfg) == timing, "a retime back restores the timing");
        static if (programs_rx_gap)
            assert(uart_gap_tenths(cfg, rx_gap_bits()) == timing.gap);
        immutable uint threshold = chars_in(cfg, timing);
        rx_calls = 0;
        foreach (i; 0 .. threshold - 1)
            rx(cast(ubyte)i);
        assert(rx_calls == 0);
        rx(cast(ubyte)(threshold - 1));
        assert(rx_calls > 0, "and the threshold");
        size_t taken = read(u, buf[]);
        assert(taken + 1 >= threshold);
        line_idle();
        assert(taken + read(u, buf[taken .. $]) == threshold);

        uart_close(u);
        assert(uart_open(u, uart_port, slow, &on_rx, &on_tx));
        assert(uart_rx_timing(u).latency_us > timing.latency_us, "an open applies the latency");
        uart_close(u);
        assert(uart_open(u, uart_port, cfg, &on_rx, &on_tx));
    }

    static if (shows_tx_busy)
    {
        wire_clear();
        shift_busy(true);
        send(u, "x");
        assert(timed!(() => uart_tx_flush(u))() >= tx_drain_limit - 50.msecs, "a flush waits for the last character to leave the shifter");
        shift_busy(false);
        uart_tx_flush(u);
        assert(wire() == "x");
    }

    rx_calls = 0;
    rx('a');
    line_idle();
    assert(rx_calls > 0, "a pause delivers what preceded it");
    bool gap;
    assert(read(u, buf[], &gap) == 1 && buf[0] == 'a' && gap, "received bytes are read, ended by the gap");

    immutable uint burst = chars_in(cfg, timing);
    rx_calls = 0;
    foreach (i; 0 .. burst)
        rx(cast(ubyte)('0' + i));
    assert(rx_calls > 0, "a continuous burst is delivered within the RX latency, without a pause");
    gap = true;
    size_t got = read(u, buf[], &gap);
    assert(got + 1 >= burst && !gap, "all of it, or all but the byte a FIFO keeps for its receive timeout, with no gap");
    line_idle();
    got += read(u, buf[got .. $], &gap);
    assert(got == burst && gap && buf[0] == '0' && buf[burst - 1] == '0' + burst - 1, "the gap ends it, with anything held, or alone");
    assert(uart_rx_take(u) is null, "once");

    foreach (i; 0 .. 3)
        rx(cast(ubyte)('p' + i));
    line_idle();
    foreach (i; 0 .. 2)
        rx(cast(ubyte)('x' + i));
    line_idle();
    Page* chain = uart_rx_take(u);
    assert(chain && uart_burst_count(chain) == 2, "a gap splits the bursts");
    UartBurst first = uart_burst(chain, 0), second = uart_burst(chain, 1);
    assert(first.length == 3 && first.gap && cast(const(char)[])page_chain_span(chain, first.offset, 3) == "pqr");
    assert(second.length == 2 && second.gap && cast(const(char)[])page_chain_span(chain, second.offset, 2) == "xy", "each ended by its own");
    assert(second.start >= first.start && first.end >= first.start && first.end + first.quiet == second.start, "each carrying when its bytes arrived");
    free_chain(chain);

    // a gap after a take still ends the run taken, ahead of the run after it
    foreach (i; 0 .. burst)
        rx(cast(ubyte)('0' + i));
    size_t seen = read(u, buf[], &gap);
    assert(seen && !gap, "a take before the gap");
    line_idle();
    rx('x');
    line_idle();
    size_t gaps;
    immutable size_t tail_bytes = read(u, buf[], &gap, &gaps);
    assert(seen + tail_bytes == burst + 1 && gaps == 2 && gap, "and both gaps are reported after it");

    // bursts keep their gaps however many arrive between takes
    foreach (i; 0 .. 12)
    {
        rx(cast(ubyte)('A' + i));
        line_idle();
    }
    gaps = 0;
    assert(read(u, buf[], null, &gaps) == 12 && gaps == 12 && buf[11] == 'L', "every burst arrives with its gap");
    assert(uart_check_errors(u) == UartError.none, "and nothing is lost");

    // a burst longer than a page is one burst across pages, and nothing is held once it is read
    __gshared ubyte[4096] wide;
    foreach (i; 0 .. 3000)
        rx(cast(ubyte)i);
    line_idle();
    gaps = 0;
    immutable size_t kept = read(u, wide[], &gap, &gaps);
    assert(gaps == 1, "one burst, however many pages it fills");
    assert(kept == 3000 && gap && wide[0] == 0 && wide[2999] == cast(ubyte)2999, "in order and whole");
    assert(uart_check_errors(u) == UartError.none && pages_in_use() == pages, "with every page freed by the reader");

    rx_overrun();
    assert(uart_check_errors(u) & UartError.overrun, "a hardware overrun is reported");
    assert(uart_check_errors(u) == UartError.none, "once");
    rx('z');
    line_idle();
    assert(read(u, buf[]) == 1 && buf[0] == 'z', "reception continues after an overrun");

    wire_clear();
    send(u, "bye");
    uart_tx_flush(u);
    assert(wire() == "bye", "a flush returns once the last character is on the line");
    wire_clear();
    send(u, "bye");
    rx('r');
    uart_close(u);
    assert(!u.is_open && wire() == "bye" && tx_disabled_while_busy() == 0, "a close sends everything queued before it stops the transmitter");
    assert(pages_in_use() == pages, "and releases every page it held");
    assert(uart_rx_timing(u) == UartRxTiming(), "a closed port reports no RX timing");
    static if (has_rx_timing)
        assert(uart_set_rx_timing(u, cfg) == UartRxTiming(), "and takes no retime");
    assert(!send(u, "x") && uart_write(u, "x") == 0, "and takes nothing");

    cfg.parity = Parity.even;
    assert(uart_open(u, uart_port, cfg, &on_rx, &on_tx));
    assert(uart_rx_take(u) is null && uart_check_errors(u) == UartError.none, "a reopened port starts clean");
    foreach (e; [ UartError.parity, UartError.framing, UartError.noise, UartError.break_ ])
    {
        if (!(line_errors & e))
            continue;
        rx_calls = 0;
        rx(0x55, e);
        assert(rx_calls > 0, "a line error alone raises the RX event");
        assert(uart_check_errors(u) & e, "and is reported as what it was");
        static if (keeps_bad_bytes)
            read(u, buf[]);
        else
            assert(read(u, buf[]) == 0, "and its byte is not delivered");
        line_idle();
        read(u, buf[]);
    }

    tx_hold(true);
    send(u, big[0 .. 1000]);
    assert(timed!(() => uart_close(u))() < tx_drain_limit + 200.msecs, "a close against a stalled line is bounded");
    assert(pages_in_use() == pages, "and releases every page, the ones it never sent among them");
    tx_hold(false);

    if (owns_pool)
        page_pool_deinit();
    assert(live == baseline, "closed ports hold no memory, and every page came back");
    assert(tx_fifo_overflows() == 0, "the TX FIFO is never written while full");
}

__gshared Link a, b, c, replacement;
__gshared uint a_calls, b_calls, replacement_calls;

@isr_safe bool count(void* counter, LinkContext)
{
    ++*cast(uint*)counter;
    return false;
}

@isr_safe bool close_self(void*, LinkContext)
{
    ++a_calls;
    link_close(a);
    return false;
}

@isr_safe bool replace_peer(void*, LinkContext)
{
    ++a_calls;
    link_close(b);
    assert(link_open(replacement, 3, gpio_event(GpioLine(0, batch_pins[1]), GpioInterruptTrigger.rising), isr_task!count(&replacement_calls)));
    return false;
}

EventSource rising(uint pin) => gpio_event(GpioLine(0, pin), GpioInterruptTrigger.rising);

void event_contract()
{
    reset();
    static if (!has_links)
    {
        assert(link_open(a, 0, rising(event_pins[0]), isr_task!count(&a_calls)) == InternalResult.unsupported, "a backend without links refuses them");
        return;
    }

    assert(link_open(a, 0, rising(event_pins[0]), isr_task!count(&a_calls), LinkTier.unmaskable) == InternalResult.unsupported, "nothing above the interrupt tier");
    assert(link_open(a, 0, gpio_event(GpioLine(0, event_pins[0]), GpioInterruptTrigger.high), isr_task!count(&a_calls)) == InternalResult.invalid_parameter, "a level is not an edge");

    assert(link_open(a, 0, rising(event_pins[0]), isr_task!count(&a_calls)));
    assert(input_enabled(event_pins[0]), "a linked pin samples its input");
    edge(event_pins[0], true);
    edge(event_pins[0], false);
    assert(a_calls == 1, "a rising link fires on rising edges only");

    assert(link_open(b, 0, rising(event_pins[2]), isr_task!count(&b_calls)) == InternalResult.already_exists, "a slot holds one link");
    assert(!link_open(b, 1, rising(event_pins[0]), isr_task!count(&b_calls)), "a pin feeds one link");
    static if (event_pins_share_line)
        assert(!link_open(b, 1, rising(event_pins[1]), isr_task!count(&b_calls)), "as does a shared interrupt line");

    assert(link_open(c, 2, gpio_event(GpioLine(0, event_pins[2]), GpioInterruptTrigger.change), gpio_task(GpioLine(0, output_pin), true)));
    edge(event_pins[2], false);
    assert(pin_level(output_pin), "a GPIO task drives its pin");
    link_close(c);

    link_close(a);
    edge(event_pins[0], true);
    assert(a_calls == 1, "a closed link does not fire");

    a_calls = 0;
    assert(link_open(a, 0, rising(event_pins[0]), Task(TaskKind.isr, 0, 0, &close_self, null)));
    edge(event_pins[0], true);
    edge(event_pins[0], true);
    assert(a_calls == 1 && !a.is_open, "a callback may close its own link");

    a = Link();
    a_calls = b_calls = 0;
    assert(link_open(a, 0, rising(batch_pins[0]), Task(TaskKind.isr, 0, 0, &replace_peer, null)));
    assert(link_open(b, 1, rising(batch_pins[1]), isr_task!count(&b_calls)));
    edges_together(batch_pins[0], batch_pins[1]);
    assert(a_calls == 1 && b_calls == 0 && replacement_calls == 0, "an edge taken before a replacement opened does not reach it");
    edge(batch_pins[1], true);
    assert(replacement_calls == 1, "the replacement takes the next edge");

    link_close(a);
    link_close(b);
    link_close(replacement);
}
