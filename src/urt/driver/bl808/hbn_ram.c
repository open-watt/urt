/* HBN RAM persistent storage — placed in .hbn_ram section by linker.
 * Survives hibernate if VBAT is maintained. */

#include <stdint.h>

struct hbn_persist {
    uint32_t magic;
    int64_t  utc_offset;  /* HBN ticks from RTC epoch to Unix epoch */
};

__attribute__((section(".hbn_ram"), used))
struct hbn_persist _hbn_persist;
