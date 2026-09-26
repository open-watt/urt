// ESP32 timer driver -- D wrapper over ESP-IDF timer APIs
//
// Uses esp_timer_get_time() for monotonic microsecond clock.
// Periodic tick uses FreeRTOS tick or esp_timer under the hood.
module urt.driver.esp32.timer;

nothrow @nogc:


enum uint mtime_freq_hz = 1_000_000; // esp_timer_get_time returns microseconds
enum bool has_mtime = true;
enum bool has_rtc = true;
enum bool has_mcycle = false;
enum bool has_timer_stop = false;
enum bool has_oneshot_timer = false;

ulong mtime_read()
{
    return cast(ulong)esp_timer_get_time();
}

// The RTC counter runs from the slow clock and keeps counting across a reset; IDF retains its
// calibration in RTC memory, so it only restarts at power-on.
enum uint rtc_freq_hz = 1_000_000;

void rtc_enable() {}
void rtc_reset() {}

ulong rtc_read() => esp_rtc_get_time_us();

alias TimerCallback = void function() nothrow @nogc;

void timer_set_periodic(ulong period_ticks, TimerCallback cb)
{
    tick_callback = cb;
    // TODO: configure esp_timer or FreeRTOS tick for periodic callback
}


private:

private __gshared TimerCallback tick_callback;

extern(C) nothrow @nogc
{
    long esp_timer_get_time();
    ulong esp_rtc_get_time_us();
}
