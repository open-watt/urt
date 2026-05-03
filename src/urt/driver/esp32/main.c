// OpenWatt ESP-IDF entry point.
// ESP-IDF calls app_main() after FreeRTOS scheduler starts.
// .init_array (D module constructors) are called automatically by
// ESP-IDF startup before app_main, so we just call D's main().

#include "esp_event.h"
#include "nvs_flash.h"
#include "esp_task_wdt.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#ifdef OW_USE_LWIP
#include "esp_netif.h"
#endif

extern int main(int argc, char **argv);

void ow_watchdog_feed(void)
{
    esp_task_wdt_reset();
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

    // Event loop is required for WIFI_EVENT delivery.
    esp_event_loop_create_default();

#ifdef OW_USE_LWIP
    // Bring up lwIP early -- D code may open sockets during startup before
    // any WiFi/Ethernet interface is created.
    esp_netif_init();
#endif

    // Delay so early boot logs are visible on USB Serial/JTAG.
    vTaskDelay(pdMS_TO_TICKS(500));

    // Configure task watchdog: 5s timeout, panic+backtrace-dump on trigger.
    // ESP-IDF may have already initialised the WDT for idle tasks; in that
    // case reconfigure to apply our settings.
    esp_task_wdt_config_t wdt_config = {
        .timeout_ms = 5000,
        .idle_core_mask = 0,
        .trigger_panic = true,
    };
    if (esp_task_wdt_init(&wdt_config) == ESP_ERR_INVALID_STATE)
        esp_task_wdt_reconfigure(&wdt_config);
    esp_task_wdt_add(NULL);

    main(0, (char **)0);
}
