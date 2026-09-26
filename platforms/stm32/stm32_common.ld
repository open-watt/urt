/* A part script declares MEMORY, aliases CORE_RAM (core-coupled: statics, stack, a pool) and
 * BULK_RAM (system SRAM: .ramfunc, a pool), then includes this file. DMA cannot reach F4's CCM or
 * H7's DTCM, so DMA buffers come from the heap, never from statics. */

ENTRY(Reset_Handler)

EXTERN(_write _read _close _lseek _fstat _isatty _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

PROVIDE(__stm32_hse_hz = 0);

SECTIONS
{
    .vector_table : ALIGN(4)
    {
        KEEP(*(.vector_table))
    } > FLASH

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
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > CORE_RAM AT > FLASH

    _got_load = LOADADDR(.got);

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        . = ALIGN(4);
        _data_end = .;
    } > CORE_RAM AT > FLASH

    _data_load = LOADADDR(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        . = ALIGN(4);
        _tdata_end = .;
    } > CORE_RAM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        . = ALIGN(4);
        _tbss_end = .;
    } > CORE_RAM

    /* The thread pointer sits 8 bytes (the ARM TCB) below the TLS block, rounded down to the
     * block alignment: lld places each thread-local at tp + 8 + ((block - 8) mod align). */
    _tls_base = ((SIZEOF(.tdata) ? ADDR(.tdata) : ADDR(.tbss)) - 8) & ~(MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)) - 1);

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
        __bss_end__ = .;
    } > CORE_RAM

    /* @persist: never zeroed or loaded; prior contents survive a reset. */
    .persist (NOLOAD) : ALIGN(8)
    {
        *(.persist .persist.*)
        . = ALIGN(8);
        _persist_end = .;
    } > CORE_RAM

    _stack_top = ORIGIN(CORE_RAM) + LENGTH(CORE_RAM);
    _stack_low = _stack_top - _stack_size;
    __StackTop = _stack_top;

    __core_heap_start = _persist_end;
    __core_heap_end   = _stack_low;
    ASSERT(__core_heap_end >= __core_heap_start, "core RAM exhausted: static data collides with the stack")

    .ramfunc : ALIGN(8)
    {
        _ramfunc_start = .;
        *(.ramfunc .ramfunc.*)
        . = ALIGN(8);
        _ramfunc_end = .;
    } > BULK_RAM AT > FLASH

    _ramfunc_load = LOADADDR(.ramfunc);

    __bulk_heap_start = _ramfunc_end;
    __bulk_heap_end   = ORIGIN(BULK_RAM) + LENGTH(BULK_RAM);

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
