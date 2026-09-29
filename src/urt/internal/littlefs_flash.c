// littlefs block device for bare-metal parts: a region of the part's own flash,
// through the flash driver the chip exports. Format runs inline; littlefs only
// erases the superblock pair, so there is nothing long enough to hand off.

#include <stdbool.h>
#include <stdint.h>

#include "lfs.h"

extern bool urt_flash_fs_region(uint32_t *address, uint32_t *size, uint32_t *erase_size);
extern bool urt_flash_read(uint32_t address, void *buffer, uint32_t size);
extern bool urt_flash_program(uint32_t address, const void *data, uint32_t size);
extern bool urt_flash_erase(uint32_t address, uint32_t size);
extern int urt_littlefs_format_run(void);

static uint32_t ow_lfs_base;

static int ow_lfs_bd_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                          void *buffer, lfs_size_t size)
{
    return urt_flash_read(ow_lfs_base + block * c->block_size + off, buffer, size) ? 0 : LFS_ERR_IO;
}

static int ow_lfs_bd_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
                          const void *buffer, lfs_size_t size)
{
    return urt_flash_program(ow_lfs_base + block * c->block_size + off, buffer, size) ? 0 : LFS_ERR_IO;
}

static int ow_lfs_bd_erase(const struct lfs_config *c, lfs_block_t block)
{
    return urt_flash_erase(ow_lfs_base + block * c->block_size, c->block_size) ? 0 : LFS_ERR_IO;
}

static int ow_lfs_bd_sync(const struct lfs_config *c)
{
    (void)c;
    return 0;
}

bool urt_littlefs_bd_init(struct lfs_config *config)
{
    uint32_t size, erase_size;
    if (!urt_flash_fs_region(&ow_lfs_base, &size, &erase_size))
        return false;

    config->read        = &ow_lfs_bd_read;
    config->prog        = &ow_lfs_bd_prog;
    config->erase       = &ow_lfs_bd_erase;
    config->sync        = &ow_lfs_bd_sync;
    config->block_size  = erase_size;
    config->block_count = size / erase_size;
    return true;
}


enum { OW_LFS_FORMAT_IDLE = 0, OW_LFS_FORMAT_RUNNING, OW_LFS_FORMAT_COMPLETE, OW_LFS_FORMAT_FAILED };

static int ow_lfs_format_state = OW_LFS_FORMAT_IDLE;

int urt_littlefs_format_begin(void)
{
    ow_lfs_format_state = urt_littlefs_format_run() == 0 ? OW_LFS_FORMAT_COMPLETE : OW_LFS_FORMAT_FAILED;
    return 0;
}

int urt_littlefs_format_status(void)
{
    return ow_lfs_format_state;
}
