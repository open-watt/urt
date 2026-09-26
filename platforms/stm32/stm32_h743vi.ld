/* STM32H743xI: 2 MB flash, 128 KB DTCM, 512 KB AXI SRAM, 288 KB SRAM1-3 (DMA, uncached by the MPU).
 * SRAM4 and ITCM are unused. */

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 2M
    DTCM  (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
    AXI   (rwx) : ORIGIN = 0x24000000, LENGTH = 512K
    D2SRAM (rw) : ORIGIN = 0x30000000, LENGTH = 288K
}

REGION_ALIAS("CORE_RAM", DTCM);
REGION_ALIAS("BULK_RAM", AXI);

__dma_heap_start = ORIGIN(D2SRAM);
__dma_heap_end   = ORIGIN(D2SRAM) + LENGTH(D2SRAM);

PROVIDE(_stack_size = 32K);

INCLUDE stm32_common.ld
