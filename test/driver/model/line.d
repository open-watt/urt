// A serial line behind a UART's FIFOs, and a store for the registers a fixture does not model.
//
// Time passes one step per status read: a character moves from the TX FIFO into the shifter, then leaves
// it for the wire on the next step. A held line moves nothing; a busy shifter never finishes.
module model.line;

nothrow @nogc:

struct Line(uint tx_depth, uint rx_depth)
{
nothrow @nogc:
    bool held, busy;
    uint tx_overflows, disabled_while_busy;

    bool tx_full() const => tx_len == tx_depth;
    uint tx_count() const => tx_len;
    bool tx_idle() const => tx_len == 0 && !shifting && !busy;

    void put(ubyte b)
    {
        if (tx_full)
        {
            ++tx_overflows;
            return;
        }
        tx[(tx_head + tx_len++) % tx_depth] = b;
    }

    void step()
    {
        if (held)
            return;
        if (shifting)
        {
            wire[sent++ % wire.length] = shifter;
            shifting = false;
        }
        else if (tx_len)
        {
            shifter = tx[tx_head];
            tx_head = (tx_head + 1) % tx_depth;
            --tx_len;
            shifting = true;
        }
    }

    // The transmitter is switched off: whatever is queued or shifting never reaches the wire.
    void tx_disable()
    {
        if (!tx_idle)
            ++disabled_while_busy;
        tx_len = 0;
        shifting = false;
    }

    const(ubyte)[] sent_bytes() const => wire[0 .. sent < wire.length ? sent : wire.length];
    void clear_wire() { sent = 0; }

    bool receive(ubyte b, ubyte err)
    {
        if (rx_len == rx_depth)
            return false;
        rx[(rx_head + rx_len++) % rx_depth] = Rx(b, err);
        return true;
    }

    uint rx_count() const => rx_len;
    ubyte head_err() const => rx_len ? rx[rx_head].err : 0;

    ubyte pop()
    {
        if (!rx_len)
            return 0;
        immutable b = rx[rx_head].b;
        rx_head = (rx_head + 1) % rx_depth;
        --rx_len;
        return b;
    }

    void rx_clear() { rx_len = 0; }
    void tx_clear() { tx_len = 0; }

private:
    struct Rx
    {
        ubyte b, err;
    }

    ubyte[tx_depth] tx;
    Rx[rx_depth] rx;
    ubyte[8192] wire;
    size_t sent;
    uint tx_head, tx_len, rx_head, rx_len;
    ubyte shifter;
    bool shifting;
}

struct Registers
{
nothrow @nogc:
    uint get(size_t addr) const
    {
        foreach (ref e; _e[0 .. _n])
            if (e.addr == addr)
                return e.value;
        return 0;
    }

    void set(size_t addr, uint value)
    {
        foreach (ref e; _e[0 .. _n])
        {
            if (e.addr == addr)
            {
                e.value = value;
                return;
            }
        }
        assert(_n < _e.length, "register store full");
        _e[_n++] = Entry(addr, value);
    }

    void clear() { _n = 0; }

private:
    struct Entry
    {
        size_t addr;
        uint value;
    }

    Entry[1024] _e;
    uint _n;
}
