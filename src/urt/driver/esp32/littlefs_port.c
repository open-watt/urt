// littlefs on Espressif -- urt.file backend.
//
// Unlike the SPIFFS backend this does not go through IDF's VFS or newlib: the
// block device is esp_partition_* directly, which is why nothing here needs
// CONFIG_VFS_SUPPORT_IO. That is the whole point of the exercise; see the
// trajectory note on the SPIFFS shim in ow_shim.c.
//
// littlefs has no notion of a file descriptor, so the handle table below maps
// the small integers urt.file passes around onto lfs_file_t.

#include <string.h>

#include "esp_partition.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "lfs.h"

#define OW_LFS_READ_SIZE      16
#define OW_LFS_PROG_SIZE      16
#define OW_LFS_CACHE_SIZE    256
#define OW_LFS_LOOKAHEAD_SIZE 32
#define OW_LFS_BLOCK_CYCLES  500
// Each console session holds its history file open for the life of the session,
// so this has to cover concurrent sessions plus whatever else is streaming.
#define OW_LFS_MAX_FILES       8
#define OW_LFS_NAME_MAX      127

#define OW_LFS_MAX_DIRS        2

// Distinct from any LFS_ERR_*, so an exhausted handle table cannot be misread
// as a filesystem fault.
#define OW_LFS_ERR_NO_HANDLES (-1000)

static const esp_partition_t *ow_lfs_partition;
static lfs_t ow_lfs;
static bool ow_lfs_mounted;
static int ow_lfs_mount_state;      // -1 latches a failed mount until a format
static int ow_lfs_last_error;

static uint8_t ow_lfs_read_buffer[OW_LFS_CACHE_SIZE];
static uint8_t ow_lfs_prog_buffer[OW_LFS_CACHE_SIZE];
static uint8_t ow_lfs_lookahead_buffer[OW_LFS_LOOKAHEAD_SIZE];

static struct
{
    lfs_file_t file;
    uint8_t buffer[OW_LFS_CACHE_SIZE];
    struct lfs_file_config config;
    bool used;
} ow_lfs_files[OW_LFS_MAX_FILES];

static struct
{
    lfs_dir_t dir;
    bool used;
} ow_lfs_dirs[OW_LFS_MAX_DIRS];

static struct lfs_config ow_lfs_config;


static int ow_lfs_bd_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                          void *buffer, lfs_size_t size)
{
    (void)c;
    return esp_partition_read(ow_lfs_partition, block * ow_lfs_config.block_size + off, buffer, size) == ESP_OK
        ? 0 : LFS_ERR_IO;
}

static int ow_lfs_bd_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                          const void *buffer, lfs_size_t size)
{
    (void)c;
    return esp_partition_write(ow_lfs_partition, block * ow_lfs_config.block_size + off, buffer, size) == ESP_OK
        ? 0 : LFS_ERR_IO;
}

static int ow_lfs_bd_erase(const struct lfs_config *c, lfs_block_t block)
{
    (void)c;
    return esp_partition_erase_range(ow_lfs_partition, block * ow_lfs_config.block_size,
                                     ow_lfs_config.block_size) == ESP_OK ? 0 : LFS_ERR_IO;
}

static int ow_lfs_bd_sync(const struct lfs_config *c)
{
    (void)c;
    return 0;   // esp_partition writes are synchronous
}

static bool ow_lfs_configure(void)
{
    if (ow_lfs_partition)
        return true;

    ow_lfs_partition = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
                                                ESP_PARTITION_SUBTYPE_ANY, "storage");
    if (!ow_lfs_partition)
        return false;

    ow_lfs_config.read  = &ow_lfs_bd_read;
    ow_lfs_config.prog  = &ow_lfs_bd_prog;
    ow_lfs_config.erase = &ow_lfs_bd_erase;
    ow_lfs_config.sync  = &ow_lfs_bd_sync;

    ow_lfs_config.read_size      = OW_LFS_READ_SIZE;
    ow_lfs_config.prog_size      = OW_LFS_PROG_SIZE;
    ow_lfs_config.block_size     = ow_lfs_partition->erase_size;
    ow_lfs_config.block_count    = ow_lfs_partition->size / ow_lfs_partition->erase_size;
    ow_lfs_config.block_cycles   = OW_LFS_BLOCK_CYCLES;
    ow_lfs_config.cache_size     = OW_LFS_CACHE_SIZE;
    ow_lfs_config.lookahead_size = OW_LFS_LOOKAHEAD_SIZE;
    ow_lfs_config.name_max       = OW_LFS_NAME_MAX;

    ow_lfs_config.read_buffer      = ow_lfs_read_buffer;
    ow_lfs_config.prog_buffer      = ow_lfs_prog_buffer;
    ow_lfs_config.lookahead_buffer = ow_lfs_lookahead_buffer;
    return true;
}

static bool ow_lfs_ready(void)
{
    if (ow_lfs_mounted)
        return true;
    if (ow_lfs_mount_state < 0 || !ow_lfs_configure())
        return false;

    int err = lfs_mount(&ow_lfs, &ow_lfs_config);
    if (err != 0)
    {
        ow_lfs_last_error = err;
        ow_lfs_mount_state = -1;
        return false;
    }
    ow_lfs_mounted = true;
    return true;
}

// littlefs takes paths as C strings and has real directories, so unlike the
// SPIFFS shim nothing is flattened or prefixed here.
static bool ow_lfs_path(const char *path, size_t path_len, char *buffer, size_t buffer_size)
{
    if (path_len + 1 > buffer_size)
        return false;
    memcpy(buffer, path, path_len);
    buffer[path_len] = 0;
    return true;
}

// Any parent directories a path names have to exist before the file can be
// created; littlefs will not make them implicitly.
static void ow_lfs_make_parents(char *path)
{
    for (char *p = path + 1; *p; ++p)
    {
        if (*p != '/')
            continue;
        *p = 0;
        lfs_mkdir(&ow_lfs, path);   // LFS_ERR_EXIST is the normal case
        *p = '/';
    }
}

static int ow_lfs_alloc_handle(void)
{
    for (int i = 0; i < OW_LFS_MAX_FILES; ++i)
    {
        if (!ow_lfs_files[i].used)
            return i;
    }
    return -1;
}


int urt_littlefs_available(void)
{
    return ow_lfs_ready() ? 1 : 0;
}

int urt_littlefs_last_error(void)
{
    return ow_lfs_last_error;
}

int urt_littlefs_open_handles(void)
{
    int n = 0;
    for (int i = 0; i < OW_LFS_MAX_FILES; ++i)
        n += ow_lfs_files[i].used ? 1 : 0;
    return n;
}

int urt_littlefs_info(uint64_t *total, uint64_t *used)
{
    if (!ow_lfs_ready())
        return -1;
    lfs_ssize_t blocks = lfs_fs_size(&ow_lfs);
    if (blocks < 0)
        return -1;
    *total = (uint64_t)ow_lfs_config.block_count * ow_lfs_config.block_size;
    *used = (uint64_t)blocks * ow_lfs_config.block_size;
    return 0;
}

int urt_littlefs_exists(const char *path, size_t path_len)
{
    char buffer[OW_LFS_NAME_MAX + 1];
    if (!ow_lfs_ready() || !ow_lfs_path(path, path_len, buffer, sizeof(buffer)))
        return 0;
    struct lfs_info info;
    return lfs_stat(&ow_lfs, buffer, &info) == 0 && info.type == LFS_TYPE_REG;
}

int urt_littlefs_stat(const char *path, size_t path_len, uint64_t *size)
{
    char buffer[OW_LFS_NAME_MAX + 1];
    if (!ow_lfs_ready() || !ow_lfs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;
    struct lfs_info info;
    if (lfs_stat(&ow_lfs, buffer, &info) != 0)
        return -1;
    *size = info.size;
    return 0;
}

int urt_littlefs_unlink(const char *path, size_t path_len)
{
    char buffer[OW_LFS_NAME_MAX + 1];
    if (!ow_lfs_ready() || !ow_lfs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;
    return lfs_remove(&ow_lfs, buffer) == 0 ? 0 : -1;
}

// littlefs renames atomically over an existing target, which SPIFFS cannot do.
int urt_littlefs_rename(const char *from, size_t from_len, const char *to, size_t to_len)
{
    char a[OW_LFS_NAME_MAX + 1], b[OW_LFS_NAME_MAX + 1];
    if (!ow_lfs_ready() || !ow_lfs_path(from, from_len, a, sizeof(a)) || !ow_lfs_path(to, to_len, b, sizeof(b)))
        return -1;
    ow_lfs_make_parents(b);
    return lfs_rename(&ow_lfs, a, b) == 0 ? 0 : -1;
}

int urt_littlefs_open(const char *path, size_t path_len, bool write, bool truncate)
{
    char buffer[OW_LFS_NAME_MAX + 1];
    if (!ow_lfs_ready() || !ow_lfs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;

    int h = ow_lfs_alloc_handle();
    if (h < 0)
    {
        ow_lfs_last_error = OW_LFS_ERR_NO_HANDLES;
        return -1;
    }

    int flags = write ? (LFS_O_RDWR | LFS_O_CREAT) : LFS_O_RDONLY;
    if (write && truncate)
        flags |= LFS_O_TRUNC;

    if (write)
        ow_lfs_make_parents(buffer);

    memset(&ow_lfs_files[h].config, 0, sizeof(ow_lfs_files[h].config));
    ow_lfs_files[h].config.buffer = ow_lfs_files[h].buffer;

    int err = lfs_file_opencfg(&ow_lfs, &ow_lfs_files[h].file, buffer, flags, &ow_lfs_files[h].config);
    if (err != 0)
    {
        ow_lfs_last_error = err;
        return -1;
    }
    ow_lfs_files[h].used = true;
    return h;
}

static bool ow_lfs_valid(int h)
{
    return h >= 0 && h < OW_LFS_MAX_FILES && ow_lfs_files[h].used;
}

ptrdiff_t urt_littlefs_read(int h, void *buffer, size_t length)
{
    if (!ow_lfs_valid(h))
        return -1;
    lfs_ssize_t n = lfs_file_read(&ow_lfs, &ow_lfs_files[h].file, buffer, length);
    if (n < 0)
        ow_lfs_last_error = n;
    return n;
}

ptrdiff_t urt_littlefs_write(int h, const void *data, size_t length)
{
    if (!ow_lfs_valid(h))
        return -1;
    lfs_ssize_t n = lfs_file_write(&ow_lfs, &ow_lfs_files[h].file, data, length);
    if (n < 0)
        ow_lfs_last_error = n;
    return n;
}

void urt_littlefs_close(int h)
{
    if (!ow_lfs_valid(h))
        return;
    lfs_file_close(&ow_lfs, &ow_lfs_files[h].file);
    ow_lfs_files[h].used = false;
}

uint64_t urt_littlefs_size(int h)
{
    if (!ow_lfs_valid(h))
        return 0;
    lfs_soff_t n = lfs_file_size(&ow_lfs, &ow_lfs_files[h].file);
    return n < 0 ? 0 : (uint64_t)n;
}

int64_t urt_littlefs_seek(int h, int64_t offset, int whence)
{
    if (!ow_lfs_valid(h))
        return -1;
    int w = whence == 1 ? LFS_SEEK_CUR : (whence == 2 ? LFS_SEEK_END : LFS_SEEK_SET);
    return lfs_file_seek(&ow_lfs, &ow_lfs_files[h].file, (lfs_soff_t)offset, w);
}

int urt_littlefs_truncate(int h, uint64_t length)
{
    if (!ow_lfs_valid(h))
        return -1;
    return lfs_file_truncate(&ow_lfs, &ow_lfs_files[h].file, (lfs_off_t)length) == 0 ? 0 : -1;
}

int urt_littlefs_sync(int h)
{
    if (!ow_lfs_valid(h))
        return -1;
    return lfs_file_sync(&ow_lfs, &ow_lfs_files[h].file) == 0 ? 0 : -1;
}


int urt_littlefs_dir_open(const char *path, size_t path_len)
{
    char buffer[OW_LFS_NAME_MAX + 1];
    if (!ow_lfs_ready() || !ow_lfs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;

    int h = -1;
    for (int i = 0; i < OW_LFS_MAX_DIRS; ++i)
    {
        if (!ow_lfs_dirs[i].used)
        {
            h = i;
            break;
        }
    }
    if (h < 0)
    {
        ow_lfs_last_error = OW_LFS_ERR_NO_HANDLES;
        return -1;
    }

    // An empty path is the root, which littlefs spells "/".
    int err = lfs_dir_open(&ow_lfs, &ow_lfs_dirs[h].dir, buffer[0] ? buffer : "/");
    if (err != 0)
    {
        ow_lfs_last_error = err;
        return -1;
    }
    ow_lfs_dirs[h].used = true;
    return h;
}

// Returns the name length, 0 at the end of the directory, negative on error.
ptrdiff_t urt_littlefs_dir_read(int h, char *name, size_t name_len, uint64_t *size, int *is_dir)
{
    if (h < 0 || h >= OW_LFS_MAX_DIRS || !ow_lfs_dirs[h].used)
        return -1;

    struct lfs_info info;
    int r = lfs_dir_read(&ow_lfs, &ow_lfs_dirs[h].dir, &info);
    if (r < 0)
    {
        ow_lfs_last_error = r;
        return -1;
    }
    if (r == 0)
        return 0;

    size_t len = strlen(info.name);
    if (len > name_len)
        len = name_len;
    memcpy(name, info.name, len);
    *size = info.size;
    *is_dir = (info.type == LFS_TYPE_DIR);
    return (ptrdiff_t)len;
}

void urt_littlefs_dir_close(int h)
{
    if (h < 0 || h >= OW_LFS_MAX_DIRS || !ow_lfs_dirs[h].used)
        return;
    lfs_dir_close(&ow_lfs, &ow_lfs_dirs[h].dir);
    ow_lfs_dirs[h].used = false;
}


// Format runs on its own task for the same reason SPIFFS's does: erasing a
// multi-megabyte partition blocks long enough to starve the watchdog.
enum { OW_LFS_FORMAT_IDLE = 0, OW_LFS_FORMAT_RUNNING, OW_LFS_FORMAT_COMPLETE, OW_LFS_FORMAT_FAILED };

static volatile int ow_lfs_format_state = OW_LFS_FORMAT_IDLE;

static void ow_lfs_format_task(void *argument)
{
    (void)argument;
    int err = -1;
    if (ow_lfs_configure())
    {
        if (ow_lfs_mounted)
        {
            lfs_unmount(&ow_lfs);
            ow_lfs_mounted = false;
        }
        err = lfs_format(&ow_lfs, &ow_lfs_config);
    }
    if (err == 0)
        ow_lfs_mount_state = 0;     // the partition is usable now; allow a mount retry
    else
        ow_lfs_last_error = err;
    ow_lfs_format_state = (err == 0) ? OW_LFS_FORMAT_COMPLETE : OW_LFS_FORMAT_FAILED;
    vTaskDelete(NULL);
}

int urt_littlefs_format_begin(void)
{
    if (ow_lfs_format_state == OW_LFS_FORMAT_RUNNING)
        return 0;
    ow_lfs_format_state = OW_LFS_FORMAT_RUNNING;
    if (xTaskCreate(ow_lfs_format_task, "ow-lfs-fmt", 4096, NULL, tskIDLE_PRIORITY + 1, NULL) != pdPASS)
    {
        ow_lfs_format_state = OW_LFS_FORMAT_FAILED;
        return -1;
    }
    return 0;
}

int urt_littlefs_format_status(void)
{
    return ow_lfs_format_state;
}
