module urt.driver.esp32.idf_log;

import urt.atomic : MemoryOrder, atomicExchange, atomicFetchAdd, atomicLoad, atomicStore;
import urt.sync.mpsc : MpscQueue;

nothrow @nogc:


enum size_t idf_log_chunk_capacity = 256;

struct IdfLogChunk
{
    void* task;
    uint drop_generation;
    ushort length;
    bool truncated;
    char[idf_log_chunk_capacity] data = void;

    const(char)[] text() const nothrow @nogc
    {
        return data[0 .. length];
    }
}

// Invoked synchronously on an arbitrary ESP-IDF logging task. The callback
// must only notify its consumer; it must not allocate, block, or emit a log.
alias IdfLogReadyCallback = void function() nothrow @nogc;

bool idf_log_open()
{
    if (_opened)
        return false;

    reset_capture();
    if (ow_idf_log_open(&receive_chunk) == 0)
        return false;
    _opened = true;
    return true;
}

void idf_log_close()
{
    if (!_opened)
        return;
    ow_idf_log_close();
    _opened = false;
}

void idf_log_set_ready_callback(IdfLogReadyCallback callback)
{
    atomicStore!(MemoryOrder.release)(_ready_callback_bits, cast(size_t)callback);
}

bool idf_log_receive(out IdfLogChunk chunk)
{
    return _queue.dequeue(chunk);
}

uint idf_log_take_drops()
{
    return atomicExchange!(MemoryOrder.acq_rel)(&_drops, 0u);
}


private:

enum uint queue_capacity = 32;

__gshared bool _opened;
__gshared MpscQueue!(IdfLogChunk, queue_capacity) _queue;
shared size_t _ready_callback_bits;
shared uint _drops;
shared uint _drop_generation;

static assert(IdfLogReadyCallback.sizeof == size_t.sizeof);

void reset_capture()
{
    _queue.init();
    atomicStore!(MemoryOrder.relaxed)(_drops, 0u);
    atomicStore!(MemoryOrder.relaxed)(_drop_generation, 0u);
}

extern(C) void receive_chunk(void* task, const char* data, size_t length, int truncated) nothrow @nogc
{
    IdfLogChunk chunk = void;
    chunk.task = task;
    chunk.drop_generation = atomicLoad!(MemoryOrder.acquire)(_drop_generation);
    if (length > chunk.data.length)
    {
        length = chunk.data.length;
        truncated = 1;
    }
    chunk.length = cast(ushort)length;
    chunk.truncated = truncated != 0;
    if (length != 0)
        chunk.data[0 .. length] = data[0 .. length];

    if (!_queue.enqueue(chunk))
    {
        atomicFetchAdd!(MemoryOrder.relaxed)(_drops, 1u);
        atomicFetchAdd!(MemoryOrder.release)(_drop_generation, 1u);
    }

    auto callback = cast(IdfLogReadyCallback)atomicLoad!(MemoryOrder.acquire)(_ready_callback_bits);
    if (callback !is null)
        callback();
}

extern(C) alias IdfLogSink = void function(void*, const char*, size_t, int) nothrow @nogc;

extern(C) nothrow @nogc
{
    int ow_idf_log_open(IdfLogSink sink);
    void ow_idf_log_close();
}


unittest
{
    reset_capture();
    static immutable text = "idf";
    foreach (i; 0 .. queue_capacity)
        receive_chunk(cast(void*)i, text.ptr, text.length, i == 0);
    receive_chunk(null, text.ptr, text.length, 0);

    assert(idf_log_take_drops() == 1);
    assert(idf_log_take_drops() == 0);

    IdfLogChunk chunk;
    assert(idf_log_receive(chunk));
    assert(chunk.task is null);
    assert(chunk.drop_generation == 0);
    assert(chunk.truncated);
    assert(chunk.text == text);

    foreach (i; 1 .. queue_capacity)
        assert(idf_log_receive(chunk));
    assert(!idf_log_receive(chunk));

    receive_chunk(null, text.ptr, text.length, 0);
    assert(idf_log_receive(chunk));
    assert(chunk.drop_generation == 1);
}
