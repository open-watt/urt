// ESP32 counter backend over ESP-IDF gptimer through ow_shim.c.
//
// counter_hw_reload executes from interrupt context; the shim requires
// CONFIG_GPTIMER_CTRL_FUNC_IN_IRAM and CONFIG_GPTIMER_ISR_CACHE_SAFE and
// fails the C build without them.
module urt.driver.esp32.counter;

import urt.attribute : critical;
import urt.driver.counter;
import urt.result : InternalResult, Result;

nothrow @nogc:


version (ESP32)
    enum uint num_counters = 4;
else
    enum uint num_counters = 0;

Result counter_hw_open(uint port, ref const CounterConfig config)
{
    return ow_counter_open(port, config.resolution_hz) == 0 ? Result.success : InternalResult.failed;
}

Result counter_hw_arm(uint port, ulong ticks, bool periodic)
{
    return ow_counter_arm(port, ticks, periodic) == 0 ? Result.success : InternalResult.failed;
}

@critical void counter_hw_reload(uint port)
{
    ow_counter_reload(port);
}

@critical void counter_hw_rearm(uint port, ulong ticks)
{
    ow_counter_rearm(port, ticks);
}

@critical ulong counter_hw_read(uint port)
{
    return ow_counter_read(port);
}

void counter_hw_close(uint port)
{
    ow_counter_close(port);
}


private:

extern(C) nothrow @nogc
{
    int ow_counter_open(uint port, uint resolution_hz);
    int ow_counter_arm(uint port, ulong ticks, bool periodic);
    void ow_counter_reload(uint port);
    void ow_counter_rearm(uint port, ulong ticks);
    ulong ow_counter_read(uint port);
    void ow_counter_close(uint port);
}
