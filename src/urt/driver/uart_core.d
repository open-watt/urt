// The queues, delivery and bounded progress every interrupt-driven UART backend shares. The backend supplies tx_idle,
// and tx_fill, which moves the TX queue into the FIFO with interrupts held off and arms TX while more waits.
module urt.driver.uart_core;

import urt.driver.irq : irq_critical;
import urt.driver.uart : Uart, UartCallbackContext, UartError, UartRxCallback, UartRxTiming, UartTxCallback;
import urt.mem.alloc : MemFlags, alloc, free;
import urt.mem.ring : RingBuffer;
import urt.sync.spsc : SPSCRing;
import urt.time : getTime, msecs;

nothrow @nogc:

enum tx_drain_limit = 250.msecs;
enum uint puts_stall_spins = 1_000_000;     // tens of milliseconds of register reads: no clock on a fault path

alias UartRxRing = SPSCRing!(ubyte, 512);
alias UartTxRing = RingBuffer!1024;

// A backend whose TX interrupt cannot be relied on writes synchronously and leaves out tx_fill: it queues no TX.
struct UartPorts(uint count, uint first, alias tx_idle, alias tx_fill = void)
{
nothrow @nogc:

    enum bool queues_tx = !is(tx_fill == void);

    // Rings survive a reopen; a failed open releases them.
    bool acquire(uint id)
    {
        Port* p = &_port[id];
        if (!p.rx)
        {
            p.rx = alloc!UartRxRing(MemFlags.none);
            static if (queues_tx)
                p.tx = alloc!UartTxRing(MemFlags.none);
            if (!p.rx || (queues_tx && !p.tx))
            {
                release(id);
                return false;
            }
        }
        auto guard = irq_critical();
        (*p.rx).init();
        if (p.tx)
            p.tx.purge();
        p.cb = null;
        p.errors = UartError.none;
        return true;
    }

    void start(uint id, UartRxCallback cb, UartRxTiming timing, UartTxCallback tx_cb = null)
    {
        _port[id].cb = cb;
        static if (queues_tx)
            _port[id].tx_cb = tx_cb;
        retime(id, timing);
    }

    void retime(uint id, UartRxTiming timing)
    {
        _port[id].latency_us = timing.latency_us;
        _port[id].gap = timing.gap;
    }

    void release(uint id)
    {
        UartRxRing* rx;
        UartTxRing* tx;
        {
            auto guard = irq_critical();
            rx = _port[id].rx;
            tx = _port[id].tx;
            _port[id] = Port.init;
        }
        if (rx)
            free(rx);
        if (tx)
            free(tx);
    }

    ptrdiff_t read(uint id, void[] buffer)
        => _port[id].rx ? _port[id].rx.pop(cast(ubyte[])buffer) : 0;

    static if (queues_tx)
    {
        // Takes what the ring holds now; a short write raises the TX callback once the ring is half empty.
        ptrdiff_t write(uint id, const(void)[] data)
        {
            Port* p = &_port[id];
            if (!p.tx)
                return 0;
            auto guard = irq_critical();
            size_t n = p.tx.write(data);
            tx_fill(id);
            if (n < data.length)
                p.tx_wait = true;
            return n;
        }

        // ISR side, after a refill.
        bool tx_room(uint id)
        {
            Port* p = &_port[id];
            if (!p.tx_wait || p.tx.pending > UartTxRing.capacity / 2)
                return false;
            p.tx_wait = false;
            return p.tx_cb ? p.tx_cb(Uart(cast(ubyte)(id + first)), UartCallbackContext.interrupt) : false;
        }
    }

    // Feeds the FIFO itself, so it drains with interrupts masked too, then waits out the last character.
    void drain(uint id)
    {
        immutable deadline = getTime() + tx_drain_limit;
        static if (queues_tx)
        {
            while (getTime() < deadline)
            {
                auto guard = irq_critical();
                tx_fill(id);
                if (!_port[id].tx || _port[id].tx.empty)
                    break;
            }
        }
        while (!tx_idle(id) && getTime() < deadline)
        {}
    }

    ptrdiff_t rx_pending(uint id)
        => _port[id].rx ? _port[id].rx.pending : 0;

    ptrdiff_t tx_pending(uint id)
    {
        auto guard = irq_critical();
        return _port[id].tx ? _port[id].tx.pending : 0;
    }

    bool tx_queued(uint id)
        => _port[id].tx && !_port[id].tx.empty;

    bool tx_pop(uint id, ref ubyte b)
        => _port[id].tx && _port[id].tx.read((&b)[0 .. 1]) == 1;

    UartRxTiming timing(uint id)
        => UartRxTiming(_port[id].latency_us, _port[id].gap);

    UartError take_errors(uint id)
    {
        auto guard = irq_critical();
        immutable errors = _port[id].errors;
        _port[id].errors = UartError.none;
        return errors;
    }

    // ISR side. A byte with no room is dropped rather than left in the FIFO, where its level interrupt would storm.
    bool receive(uint id, ubyte b)
    {
        Port* p = &_port[id];
        if (p.rx && p.rx.push((&b)[0 .. 1]))
            return true;
        p.errors = cast(UartError)(p.errors | UartError.overrun);
        return false;
    }

    void error(uint id, UartError errors)
    {
        _port[id].errors = cast(UartError)(_port[id].errors | errors);
    }

    void notify(uint id)
    {
        Port* p = &_port[id];
        if (p.cb)
            p.cb(Uart(cast(ubyte)(id + first)), p.rx ? p.rx.pending : 0, UartCallbackContext.interrupt);
    }

private:
    struct Port
    {
        UartRxRing* rx;
        static if (queues_tx)
        {
            UartTxRing* tx;
            UartTxCallback tx_cb;
        }
        else
            enum UartTxRing* tx = null;
        UartRxCallback cb;
        uint latency_us;
        ubyte gap;
        UartError errors;
        static if (queues_tx)
            bool tx_wait;
    }

    Port[count] _port;
}


unittest
{
    static struct Model
    {
        static __gshared bool stalled, busy;
        static __gshared ubyte[64] wire;
        static __gshared size_t sent;
        static __gshared UartPorts!(2, 1, idle, fill) ports;
        static __gshared size_t calls, last_avail, tx_calls;

    nothrow @nogc:
        static void fill(uint id)
        {
            ubyte b;
            while (!stalled && ports.tx_pop(id, b))
            {
                if (sent < wire.length)
                    wire[sent] = b;
                ++sent;
            }
        }

        static bool idle(uint id)
            => !busy;

        static bool cb(Uart u, size_t avail, UartCallbackContext)
        {
            assert(u.port == 2);
            ++calls;
            last_avail = avail;
            return false;
        }

        static bool tx_cb(Uart u, UartCallbackContext context)
        {
            assert(u.port == 2 && context == UartCallbackContext.interrupt);
            ++tx_calls;
            return false;
        }
    }
    alias ports = Model.ports;

    assert(ports.read(1, null) == 0 && ports.write(1, "x") == 0 && ports.tx_pending(1) == 0, "a closed port moves nothing");

    assert(ports.acquire(1));
    ports.start(1, &Model.cb, UartRxTiming(80, 35), &Model.tx_cb);
    assert(ports.timing(1).latency_us == 80);

    assert(ports.write(1, "hello") == 5 && Model.sent == 5 && Model.wire[0 .. 5] == "hello", "a running line takes the whole write");

    ports.tx_room(1);
    assert(Model.tx_calls == 0, "a whole write leaves no writer waiting");

    Model.stalled = true;
    ubyte[1500] big;
    immutable t0 = getTime();
    assert(ports.write(1, big[]) == 1023 && ports.tx_pending(1) == 1023, "a stalled line takes what the ring holds");
    assert(getTime() - t0 < 10.msecs, "and the write does not wait for the line");
    ports.tx_room(1);
    assert(Model.tx_calls == 0, "a full ring has no room to report");

    Model.busy = true;
    immutable t1 = getTime();
    ports.drain(1);
    assert(getTime() - t1 >= tx_drain_limit && getTime() - t1 < tx_drain_limit + 100.msecs, "a drain against a stalled line is bounded");

    Model.stalled = false;
    Model.busy = false;
    ports.drain(1);
    assert(ports.tx_pending(1) == 0 && Model.sent == 5 + 1023, "a drain empties the ring into the line");
    ports.tx_room(1);
    assert(Model.tx_calls == 1, "the short writer hears once the ring has room");
    ports.tx_room(1);
    assert(Model.tx_calls == 1, "and only once");

    assert(ports.receive(1, 'a') && ports.receive(1, 'b'));
    ports.notify(1);
    assert(Model.calls == 1 && Model.last_avail == 2, "notify reports what the ring holds");
    ubyte[4] buf;
    assert(ports.read(1, buf[]) == 2 && buf[0 .. 2] == "ab");
    assert(ports.take_errors(1) == UartError.none);

    foreach (i; 0 .. 600)
        ports.receive(1, cast(ubyte)i);
    ports.error(1, UartError.parity);
    assert(ports.rx_pending(1) == 511 && ports.take_errors(1) == (UartError.overrun | UartError.parity), "an RX overrun drops the excess, and errors accumulate");
    assert(ports.take_errors(1) == UartError.none, "and are reported once");

    ports.release(1);
    ports.notify(1);
    assert(Model.calls == 1 && ports.rx_pending(1) == 0, "a released port signals nobody");

    assert(ports.acquire(1) && ports.rx_pending(1) == 0 && ports.take_errors(1) == UartError.none, "a reopen starts clean");
    ports.release(1);
}
