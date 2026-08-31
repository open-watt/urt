/*
 * BK7231T (ARM968E-S, ARMv5TE), OTA layout
 *
 * Physical flash partitions:
 *   Bootloader    0x000000, 68 KiB
 *   Application   0x011000, 1156 KiB
 *   OTA           0x132000, 600 KiB
 *   RF firmware   0x1E0000, 4 KiB
 *   NET params    0x1E1000, 4 KiB
 *
 * Runtime SRAM:
 *   0x00400000..0x00400100   vectors and exception register capture
 *   0x00400100..__heap_start  data and BSS
 *   __heap_start..0x0043D800  general heap
 *   0x0043D800..0x0043E000   UND and ABT stacks
 *   0x0043E000..0x00440000   main stack
 *
 * Flash addresses below are logical addresses after controller CRC removal.
 */

ENTRY(Reset_Handler)

EXTERN(_write _read _close _lseek _fstat _isatty _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    /* FLASH includes unpacked RAM-image workspace; _image_limit is the packed boundary. */
    FLASH (rx)  : ORIGIN = 0x00010000, LENGTH = 0x148680
    SRAM  (rwx) : ORIGIN = 0x00400100, LENGTH = 256K - 0x100
}

_image_start = ORIGIN(FLASH);
_image_limit = ORIGIN(FLASH) + 0x108780;

SECTIONS
{
    /* The bootloader requires the image header at flash origin. */
    .vectors : ALIGN(4)
    {
        KEEP(*(.text.vectors))
        KEEP(*(.text.entry))
    } > FLASH

    /* Flash-control and clock-changing vendor routines must execute from SRAM. */
    .itcm.code ALIGN(8) :
    {
        _itcmcode_ram_begin = .;
        *(.itcm .itcm.*)
        *(.text.intc_hdl_entry)
        *(.text.intc_irq)
        *(.text.intc_fiq)
        *(.text.bk_timer_isr)
        *(.text.power_save_wakeup_isr)
        *(.text.fclk_get_tick)
        *(.text.flash_read_sr)
        *(.text.flash_write_sr)
        *(.text.flash_clr_qwfr)
        *(.text.set_flash_protect)
        *(.text.flash_read)
        *(.text.flash_read_data)
        *(.text.flash_set_qe)
        *(.text.flash_set_qwfr)
        *(.text.flash_set_line_mode*)
        *(.text.flash_get_line_mode)
        *(.text.flash_write)
        *(.text.flash_ctrl)
        *(.text.power_save_dtim_wake)
        *(.text.sctrl_fix_dpll_div)
        . = ALIGN(4);
        _itcmcode_ram_end = .;
    } > SRAM AT> FLASH
    _itcmcode_flash_begin = LOADADDR(.itcm.code);

    .text : ALIGN(4)
    {
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

    .ARM.exidx : ALIGN(4)
    {
        __exidx_start = .;
        *(.ARM.exidx* .gnu.linkonce.armexidx.*)
        __exidx_end = .;
    } > FLASH

    .ARM.extab : ALIGN(4)
    {
        *(.ARM.extab* .gnu.linkonce.armextab.*)
    } > FLASH

    .got : ALIGN(4)
    {
        _got_load  = LOADADDR(.got);
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > SRAM AT > FLASH

    /* No DTCM: @fast_data is ordinary SRAM here and the fast heap is empty. */
    .dtcm_data (NOLOAD) : ALIGN(8)
    {
        _dtcm_data_start = .;
        *(.dtcm_data .dtcm_data.*)
        . = ALIGN(4);
        _dtcm_data_end = .;
    } > SRAM
    _fast_heap_start = _dtcm_data_end;
    _fast_heap_end   = _dtcm_data_end;

    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        _tdata_end = .;
    } > SRAM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    } > SRAM AT > FLASH

    _data_load = LOADADDR(.data);

    _ram_image_load = _tdata_load;
    _ram_image_start = _tdata_start;
    _ram_image_end = _data_end;

    /* Inflate input cannot extend beyond the original final load region. */
    _flash_end = LOADADDR(.data) + SIZEOF(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > SRAM

    _stack_size       = 8K;
    _abt_stack_size   = 1K;
    _und_stack_size   = 1K;

    _stack_top    = ORIGIN(SRAM) + LENGTH(SRAM);
    _stack_bottom = _stack_top - _stack_size;
    _abt_stack_start = _stack_bottom - _abt_stack_size;
    _und_stack_start = _abt_stack_start - _und_stack_size;

    __heap_start = ALIGN(_bss_end, 8);
    __heap_end   = _und_stack_start;
    ASSERT(__heap_end - __heap_start >= 32K, "static data has squeezed the heap below 32K")
    _stack_low = _stack_bottom;
    __StackTop = _stack_top;

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
