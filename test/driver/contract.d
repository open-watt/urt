// The UART and event-link contracts, run against a backend compiled over its register model.
module tests.driver.contract;

import urt.attribute : isr_safe;
import urt.driver.event;
import urt.driver.gpio : GpioInterruptTrigger, GpioLine;
import urt.driver.uart;
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

__gshared uint rx_calls;
__gshared size_t rx_avail;

bool on_rx(Uart, size_t avail, UartCallbackContext)
{
    ++rx_calls;
    rx_avail = avail;
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

void uart_contract()
{
    import urt.driver.uart_core : tx_drain_limit, tx_stall_limit;

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
    static if (!has_rx_callback)
        assert(uart_open(u, uart_port, cfg, 0, &on_rx) == InternalResult.unsupported, "a backend without an RX event refuses a callback");
    assert(uart_open(u, uart_port, cfg, 64) == InternalResult.unsupported, "a buffer size nothing honours is refused");
    assert(uart_open(u, uart_port, cfg, 0, null, (Uart, size_t) {}) == InternalResult.unsupported, "as is a TX callback nothing raises");
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

    static if (has_rx_callback)
        UartRxCallback cb = &on_rx;
    else
        UartRxCallback cb = null;
    enum bool queues = (uart_drive_modes & 1 << DriveMode.interrupt) != 0;

    immutable int baseline = live;
    foreach (n; 0 .. 2)
    {
        fail_after = n;
        if (uart_open(u, uart_port, cfg, 0, cb))
        {
            static if (queues)
                assert(n > 0, "an open without its buffers fails");
            uart_close(u);
        }
        assert(live == baseline, "and frees what it took");
    }
    fail_after = uint.max;

    assert(uart_open(u, uart_port, cfg, 0, cb));
    assert(uart_open(dup, uart_port, cfg) == InternalResult.already_exists, "an open port is not opened twice");
    assert(uart_open(u, other_port, cfg) == InternalResult.already_exists && u.port == uart_port, "an open handle is not opened again");

    UartRxTiming timing = uart_rx_timing(u);
    static if (queues)
        assert(timing.latency_us > 0 && timing.latency_us <= cfg.rx_latency_us, "an open port reports its RX timing");

    assert(uart_write(u, "hello") == 5);
    uart_tx_flush(u);
    assert(wire() == "hello" && uart_tx_queued(u) == 0, "written bytes reach the line in order");

    wire_clear();
    tx_hold(true);
    __gshared ubyte[3000] big;
    foreach (i, ref b; big)
        b = cast(ubyte)(i * 7);
    ptrdiff_t accepted;
    immutable stall = timed!(() { accepted = uart_write(u, big[]); })();
    assert(accepted > 0 && accepted < big.length && stall < tx_stall_limit + tx_drain_limit + 100.msecs, "a stalled line ends a write short");
    static if (queues)
        assert(stall >= tx_stall_limit, "after the stall limit");
    assert(uart_tx_queued(u) <= accepted, "what is still queued was accepted");
    assert(timed!(() => uart_tx_flush(u))() < tx_drain_limit + 200.msecs, "a flush against a stalled line is bounded");
    tx_hold(false);
    run_line();
    assert(wire() == big[0 .. accepted] && uart_tx_queued(u) == 0, "a released line sends everything accepted, in order, with no further call");

    ubyte[600] buf;
    static if (has_rx_timing)
    {
        wire_clear();
        tx_hold(true);
        uart_write(u, big[0 .. 100]);
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
        assert(uart_read(u, buf[]) == 1 && buf[0] == '<', "as is what arrived before the retime");
        assert(uart_check_errors(u) & UartError.overrun, "and the errors it had not reported");
        immutable UartRxTiming retimed = uart_rx_timing(u);
        static if (retimes_latency_live)
            assert(retimed.latency_us > timing.latency_us, "the new latency runs at once");
        else
            assert(retimed.latency_us == timing.latency_us, "or the old one, reported as such, until the port next opens");
        static if (programs_rx_gap)
            assert(uart_gap_tenths(slow, rx_gap_bits()) == retimed.gap, "with the gap it reports programmed");
        static if (has_rx_callback)
        {
            immutable uint trigger = chars_in(slow, retimed);
            rx_calls = 0;
            foreach (i; 0 .. trigger - 1)
                rx(cast(ubyte)i);
            assert(rx_calls == 0, "a burst short of the reported threshold waits");
            rx(cast(ubyte)(trigger - 1));
            assert(rx_calls > 0, "and the threshold delivers it");
            assert(uart_read(u, buf[]) == trigger && buf[trigger - 1] == trigger - 1);
        }

        assert(uart_set_rx_timing(u, cfg) == timing, "a retime back restores the timing");
        static if (programs_rx_gap)
            assert(uart_gap_tenths(cfg, rx_gap_bits()) == timing.gap);
        static if (has_rx_callback)
        {
            immutable uint threshold = chars_in(cfg, timing);
            rx_calls = 0;
            foreach (i; 0 .. threshold - 1)
                rx(cast(ubyte)i);
            assert(rx_calls == 0);
            rx(cast(ubyte)(threshold - 1));
            assert(rx_calls > 0, "and the threshold");
            assert(uart_read(u, buf[]) == threshold);
        }

        uart_close(u);
        assert(uart_open(u, uart_port, slow, 0, cb));
        assert(uart_rx_timing(u).latency_us > timing.latency_us, "an open applies the latency");
        uart_close(u);
        assert(uart_open(u, uart_port, cfg, 0, cb));
    }

    static if (shows_tx_busy)
    {
        wire_clear();
        shift_busy(true);
        uart_write(u, "x");
        assert(timed!(() => uart_tx_flush(u))() >= tx_drain_limit - 50.msecs, "a flush waits for the last character to leave the shifter");
        shift_busy(false);
        uart_tx_flush(u);
        assert(wire() == "x");
    }

    rx_calls = 0;
    rx('a');
    line_idle();
    static if (has_rx_callback)
        assert(rx_calls > 0, "a pause delivers what preceded it");
    assert(uart_rx_available(u) == 1 && uart_read(u, buf[]) == 1 && buf[0] == 'a', "received bytes are read");

    static if (has_rx_callback)
    {
        immutable uint burst = chars_in(cfg, timing);
        rx_calls = 0;
        foreach (i; 0 .. burst)
            rx(cast(ubyte)('0' + i));
        assert(rx_calls > 0, "a continuous burst is delivered within the RX latency, without a pause");
        line_idle();
        assert(uart_read(u, buf[]) == burst && buf[0] == '0' && buf[burst - 1] == '0' + burst - 1);
    }

    foreach (round; 0 .. 3)
    {
        size_t got;
        foreach (i; 0 .. 300)
        {
            rx(cast(ubyte)(i + round));
            static if (!queues)
                got += uart_read(u, buf[got .. $]);
        }
        line_idle();
        got += uart_read(u, buf[got .. $]);
        assert(got == 300, "received bytes wrap the ring");
        foreach (i; 0 .. 300)
            assert(buf[i] == cast(ubyte)(i + round), "in order");
    }
    assert(uart_check_errors(u) == UartError.none, "and cleanly");

    foreach (i; 0 .. 600)
        rx(cast(ubyte)i);
    line_idle();
    assert(uart_check_errors(u) & UartError.overrun, "a full buffer reports the overrun");
    assert(uart_check_errors(u) == UartError.none, "once");
    immutable size_t kept = uart_read(u, buf[]);
    assert(kept > 0 && kept < 600 && buf[0] == 0 && buf[kept - 1] == cast(ubyte)(kept - 1), "and keeps the oldest bytes");

    rx_overrun();
    assert(uart_check_errors(u) & UartError.overrun, "a hardware overrun is reported");
    assert(uart_check_errors(u) == UartError.none, "once");
    rx('z');
    line_idle();
    assert(uart_read(u, buf[]) == 1 && buf[0] == 'z', "reception continues after an overrun");

    wire_clear();
    assert(uart_write(u, "bye") == 3);
    uart_tx_flush(u);
    assert(wire() == "bye", "a flush returns once the last character is on the line");
    wire_clear();
    assert(uart_write(u, "bye") == 3);
    uart_close(u);
    assert(!u.is_open && wire() == "bye" && tx_disabled_while_busy() == 0, "a close sends everything written before it stops the transmitter");
    assert(uart_rx_timing(u) == UartRxTiming(), "a closed port reports no RX timing");
    static if (has_rx_timing)
        assert(uart_set_rx_timing(u, cfg) == UartRxTiming(), "and takes no retime");

    cfg.parity = Parity.even;
    assert(uart_open(u, uart_port, cfg, 0, cb));
    assert(uart_rx_available(u) == 0 && uart_check_errors(u) == UartError.none, "a reopened port starts clean");
    foreach (e; [ UartError.parity, UartError.framing, UartError.noise, UartError.break_ ])
    {
        if (!(line_errors & e))
            continue;
        rx_calls = 0;
        rx(0x55, e);
        static if (has_rx_callback)
            assert(rx_calls > 0, "a line error alone raises the RX event");
        assert(uart_check_errors(u) & e, "and is reported as what it was");
        static if (keeps_bad_bytes)
            uart_read(u, buf[]);
        else
            assert(uart_rx_available(u) == 0, "and its byte is not delivered");
    }

    tx_hold(true);
    uart_write(u, big[0 .. 100]);
    assert(timed!(() => uart_close(u))() < tx_drain_limit + 200.msecs, "a close against a stalled line is bounded");
    tx_hold(false);

    assert(live == baseline, "closed ports hold no memory");
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
