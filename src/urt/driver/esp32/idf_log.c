#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

#include "esp_log_write.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define OW_IDF_LOG_BUFFER_CAPACITY 256

typedef void (*ow_idf_log_sink_t)(void *task, const char *data, size_t length, int truncated);

static _Atomic(ow_idf_log_sink_t) log_sink;
static atomic_uint callbacks_in_flight;
static atomic_bool capture_open;
static vprintf_like_t previous_vprintf;

static int capture_vprintf(const char *format, va_list arguments)
{
    atomic_fetch_add_explicit(&callbacks_in_flight, 1, memory_order_acquire);

    ow_idf_log_sink_t sink = atomic_load_explicit(&log_sink, memory_order_acquire);
    int result;
    if (sink != NULL)
    {
        char buffer[OW_IDF_LOG_BUFFER_CAPACITY];
        va_list copy;
        va_copy(copy, arguments);
        result = vsnprintf(buffer, sizeof(buffer), format, copy);
        va_end(copy);

        size_t length = result < 0 ? 0 : (size_t)result;
        bool truncated = result < 0 || length >= sizeof(buffer);
        if (length >= sizeof(buffer))
            length = sizeof(buffer) - 1;
        sink(xTaskGetCurrentTaskHandle(), buffer, length, truncated);
    }
    else
    {
        vprintf_like_t previous = previous_vprintf;
        result = previous != NULL ? previous(format, arguments) : 0;
    }

    atomic_fetch_sub_explicit(&callbacks_in_flight, 1, memory_order_release);
    return result;
}

int ow_idf_log_open(ow_idf_log_sink_t sink)
{
    if (sink == NULL)
        return 0;

    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&capture_open, &expected, true,
                                                 memory_order_acq_rel, memory_order_acquire))
        return 0;

    atomic_store_explicit(&log_sink, sink, memory_order_release);
    previous_vprintf = esp_log_set_vprintf(&capture_vprintf);
    return 1;
}

void ow_idf_log_close(void)
{
    if (!atomic_exchange_explicit(&capture_open, false, memory_order_acq_rel))
        return;

    vprintf_like_t displaced = esp_log_set_vprintf(previous_vprintf);
    if (displaced != &capture_vprintf)
        esp_log_set_vprintf(displaced);

    atomic_store_explicit(&log_sink, NULL, memory_order_release);
    while (atomic_load_explicit(&callbacks_in_flight, memory_order_acquire) != 0)
        vTaskDelay(1);
}
