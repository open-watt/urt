/* BL616/BL618 (T-Head E907 RV32IMAFC) linker script -- Sipeed M0P Dock.
 *
 * Memory map from the BL616/BL618 datasheet and the vendor bouffalo_sdk
 * bl616dk linker template. Cacheability is address-based: bit 30 set = cached
 * (0x62.. / 0x63..), clear = non-cache (0x22.. / 0x23..) -- same physical RAM,
 * two windows. Code and data run from the cached windows; only DMA buffers use
 * the non-cache alias. There is NO TCM on this part (vendor MEMORY{} has none;
 * .tcm_* sections fold into main RAM).
 *
 *   FLASH : 0xA0000000  8M    XIP, I-cached -- .text/.rodata
 *   OCRAM : 0x62FC0000  320K  cached; top 64K aliased non-cache for DMA
 *   WRAM  : 0x23010000  160K  reserved (non-cache) for WiFi DMA
 *   PSRAM : 0xA8000000  4M    M0P pseudo-SRAM (needs bl_psram_init before use)
 *   HBN   : 0x20010000  4K    @persist, survives hibernate
 *
 * D-cache is still disabled in start.S (see its TODO); until it's enabled the
 * cached windows are simply accessed uncached. The split below keeps the DMA
 * region in separate physical RAM from the cached region, so it stays coherent
 * once D-cache is turned on.
 */

ENTRY(_start)

EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH    (rx)  : ORIGIN = 0xA0000000, LENGTH = 8M
    /* OCRAM is 320K physical. Top 64K is reserved for DMA via the non-cache
     * alias (OCRAM_DMA below); the cached window covers the lower 256K. */
    OCRAM    (rwx) : ORIGIN = 0x62FC0000, LENGTH = 256K
    OCRAM_DMA(rw)  : ORIGIN = 0x23000000, LENGTH = 64K
    WRAM     (rwx) : ORIGIN = 0x23010000, LENGTH = 160K
    PSRAM    (rwx) : ORIGIN = 0xA8000000, LENGTH = 4M
    HBNRAM   (rw)  : ORIGIN = 0x20010000, LENGTH = 4K
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
        *(.text .text.*)
    } > FLASH

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > FLASH

    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > FLASH

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > FLASH

    .init_array : ALIGN(4)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > FLASH

    /* @critical -- code that runs from RAM (no ITCM; OCRAM). */
    .ramfunc : ALIGN(4)
    {
        *(.ramfunc .ramfunc.*)
    } > OCRAM AT > FLASH

    _ramfunc_load  = LOADADDR(.ramfunc);
    _ramfunc_start = ADDR(.ramfunc);
    _ramfunc_end   = _ramfunc_start + SIZEOF(.ramfunc);

    .got : ALIGN(4)
    {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.got .got.*)
        *(.got.plt)
        *(.sdata .sdata.*)
        *(.srodata .srodata.*)
    } > OCRAM AT > FLASH

    _got_load  = LOADADDR(.got);
    _got_start = ADDR(.got);
    _got_end   = _got_start + SIZEOF(.got);

    /* @fast_data. */
    .sram_data : ALIGN(4)
    {
        *(.sram_data .sram_data.*)
    } > OCRAM AT > FLASH

    _sram_data_load  = LOADADDR(.sram_data);
    _sram_data_start = ADDR(.sram_data);
    _sram_data_end   = _sram_data_start + SIZEOF(.sram_data);

    /* .data + @bulk_data in cached OCRAM. @bulk_data stays here (not PSRAM)
     * until bl_psram_init is wired into boot -- copying into uninitialised
     * PSRAM would hang. */
    .data : ALIGN(4)
    {
        *(.data .data.*)
        *(.psram_data .psram_data.*)
    } > OCRAM AT > FLASH

    _data_load = LOADADDR(.data);
    _data_start = ADDR(.data);
    _data_end = _data_start + SIZEOF(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > OCRAM

    .tdata : ALIGN(4)
    {
        *(.tdata .tdata.*)
    } > OCRAM AT > FLASH

    _tdata_load  = LOADADDR(.tdata);
    _tdata_start = ADDR(.tdata);
    _tdata_end   = _tdata_start + SIZEOF(.tdata);

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > OCRAM

    /* @persist -- survives hibernate when VBAT is held. NOLOAD by design. */
    .hbn_ram (NOLOAD) : ALIGN(4)
    {
        *(.hbn_ram .hbn_ram.*)
    } > HBNRAM

    /* Stack at top of cached OCRAM, 16K. */
    _stack_top = ORIGIN(OCRAM) + LENGTH(OCRAM);
    _stack_low = _stack_top - 16K;
    __StackTop = _stack_top;

    /* OCRAM heap (cached, fast): between TLS and the stack. */
    __ocram_heap_start = _tbss_end;
    __ocram_heap_end   = _stack_low;

    /* DMA heap (non-cache): the full reserved alias region. */
    __dma_heap_start = ORIGIN(OCRAM_DMA);
    __dma_heap_end   = ORIGIN(OCRAM_DMA) + LENGTH(OCRAM_DMA);

    /* WRAM reserved for inevitable WiFi use (non-cache, like the M0's WIFIRAM).
     * No sections placed; exported for the future WiFi port. */
    __wifi_ram_start = ORIGIN(WRAM);
    __wifi_ram_end   = ORIGIN(WRAM) + LENGTH(WRAM);

    /* PSRAM reserved (4M). Not an allocator pool yet -- it needs bl_psram_init
     * at boot, which the bl618 build doesn't wire. Exported for when it does. */
    __psram_start = ORIGIN(PSRAM);
    __psram_end   = ORIGIN(PSRAM) + LENGTH(PSRAM);

    ASSERT(__ocram_heap_start <= __ocram_heap_end, "OCRAM overflow: code/data + heap + stack don't fit in cached 256K")

    /* get_sysinfo / dead _sbrk aliases. */
    __heap_start = __ocram_heap_start;
    __heap_end   = __ocram_heap_end;

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
