// littlefs on Espressif: the block device is esp_partition_* directly, which is
// why nothing here needs IDF's VFS or newlib (see the SPIFFS shim in idf_shim.c).

#include "esp_partition.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "lfs.h"

extern void urt_watchdog_feed(void);
extern int urt_littlefs_format_run(void);

static const esp_partition_t *urt_lfs_partition;

static int urt_lfs_bd_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                           void *buffer, lfs_size_t size)
{
    urt_watchdog_feed();
    esp_err_t result = esp_partition_read(urt_lfs_partition, block * c->block_size + off, buffer, size);
    urt_watchdog_feed();
    return result == ESP_OK ? 0 : LFS_ERR_IO;
}

static int urt_lfs_bd_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                           const void *buffer, lfs_size_t size)
{
    urt_watchdog_feed();
    esp_err_t result = esp_partition_write(urt_lfs_partition, block * c->block_size + off, buffer, size);
    urt_watchdog_feed();
    return result == ESP_OK ? 0 : LFS_ERR_IO;
}

static int urt_lfs_bd_erase(const struct lfs_config *c, lfs_block_t block)
{
    urt_watchdog_feed();
    esp_err_t result = esp_partition_erase_range(urt_lfs_partition, block * c->block_size, c->block_size);
    urt_watchdog_feed();
    return result == ESP_OK ? 0 : LFS_ERR_IO;
}

static int urt_lfs_bd_sync(const struct lfs_config *c)
{
    (void)c;
    return 0;   // esp_partition writes are synchronous
}

bool urt_littlefs_bd_init(struct lfs_config *config)
{
    urt_lfs_partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
                                                ESP_PARTITION_SUBTYPE_ANY, "storage");
    if (!urt_lfs_partition)
        return false;

    config->read        = &urt_lfs_bd_read;
    config->prog        = &urt_lfs_bd_prog;
    config->erase       = &urt_lfs_bd_erase;
    config->sync        = &urt_lfs_bd_sync;
    config->block_size  = urt_lfs_partition->erase_size;
    config->block_count = urt_lfs_partition->size / urt_lfs_partition->erase_size;
    return true;
}


// Format runs on its own task for the same reason SPIFFS's does: erasing a
// multi-megabyte partition blocks long enough to starve the watchdog.
enum { OW_LFS_FORMAT_IDLE = 0, OW_LFS_FORMAT_RUNNING, OW_LFS_FORMAT_COMPLETE, OW_LFS_FORMAT_FAILED };

static volatile int urt_lfs_format_state = OW_LFS_FORMAT_IDLE;

static void urt_lfs_format_task(void *argument)
{
    (void)argument;
    urt_lfs_format_state = urt_littlefs_format_run() == 0 ? OW_LFS_FORMAT_COMPLETE : OW_LFS_FORMAT_FAILED;
    vTaskDelete(NULL);
}

int urt_littlefs_format_begin(void)
{
    if (urt_lfs_format_state == OW_LFS_FORMAT_RUNNING)
        return 0;
    urt_lfs_format_state = OW_LFS_FORMAT_RUNNING;
    if (xTaskCreate(urt_lfs_format_task, "urt-lfs-fmt", 4096, NULL, tskIDLE_PRIORITY + 1, NULL) != pdPASS)
    {
        urt_lfs_format_state = OW_LFS_FORMAT_FAILED;
        return -1;
    }
    return 0;
}

int urt_littlefs_format_status(void)
{
    return urt_lfs_format_state;
}
