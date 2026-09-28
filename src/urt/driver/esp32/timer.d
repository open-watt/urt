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
enum bool has_timer_compare = false;

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



private:


extern(C) nothrow @nogc
{
    long esp_timer_get_time();
    ulong esp_rtc_get_time_us();
}
