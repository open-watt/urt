// OpenWatt ESP-IDF entry point.
// ESP-IDF calls app_main() after FreeRTOS scheduler starts.
// .init_array (D module constructors) are called automatically by
// ESP-IDF startup before app_main, so we just call D's main().

#include "esp_netif.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

extern int ets_printf(const char *fmt, ...);
extern int main(int argc, char **argv);

// Software watchdog: reboots if main task stops feeding.
// Call ow_watchdog_feed() from the main loop each frame.
static volatile uint32_t watchdog_counter;

void ow_watchdog_feed(void)
{
    watchdog_counter++;
}

static void watchdog_task(void *arg)
{
    const int timeout_ms = 5000;
    for (;;)
    {
        uint32_t before = watchdog_counter;
        vTaskDelay(pdMS_TO_TICKS(timeout_ms));
        if (watchdog_counter == before)
        {
            ets_printf("WATCHDOG: main loop stalled for %ds, aborting\n",
                       timeout_ms / 1000);
            abort();
        }
    }
}

void app_main(void)
{
    // Initialize NVS -- required by WiFi for calibration data storage.
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        nvs_flash_erase();
        nvs_flash_init();
    }

    // Initialize lwIP and event loop early -- D code may open sockets
    // during startup before any WiFi/Ethernet interface is created.
    esp_netif_init();
    esp_event_loop_create_default();

    xTaskCreate(watchdog_task, "ow_wdt", 2048, NULL, 1, NULL);

    // Delay so early boot logs are visible on USB Serial/JTAG
    vTaskDelay(pdMS_TO_TICKS(3000));

    main(0, (char **)0);
}
