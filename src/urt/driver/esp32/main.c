// OpenWatt ESP-IDF entry point.
// ESP-IDF calls app_main() after FreeRTOS scheduler starts.
// .init_array (D module constructors) are called automatically by
// ESP-IDF startup before app_main, so we just call D's main().

#include "esp_event.h"
#ifdef OW_ENABLE_COREDUMP
#include "esp_core_dump.h"
#include "esp_partition.h"
#endif
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

#ifdef OW_ENABLE_COREDUMP
bool ow_crash_dump_size(size_t *size)
{
    size_t address;
    return esp_core_dump_image_check() == ESP_OK &&
           esp_core_dump_image_get(&address, size) == ESP_OK;
}

bool ow_crash_dump_read(size_t offset, void *buffer, size_t length)
{
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_COREDUMP, NULL);
    return partition && offset <= partition->size && length <= partition->size - offset &&
           esp_partition_read(partition, offset, buffer, length) == ESP_OK;
}

bool ow_crash_dump_clear(void)
{
    return esp_core_dump_image_erase() == ESP_OK;
}
#endif

void app_main(void)
{
    // Initialize NVS -- required by WiFi for calibration data storage.
    esp_err_t ret = nvs_flash_init();
#ifndef OW_PRESERVE_NVS
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND)
    {
        nvs_flash_erase();
        nvs_flash_init();
    }
#else
    (void)ret;
#endif

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
