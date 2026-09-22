ENTRY(Reset_Handler)

EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x10000000, LENGTH = 4M
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 520K
}

SECTIONS
{
    .vector_table : ALIGN(4)
    {
        KEEP(*(.vector_table))
    } > FLASH

    /* The boot ROM rejects an image whose first 4KB holds no IMAGE_DEF block. */
    .embedded_block : ALIGN(4)
    {
        KEEP(*(.embedded_block))
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
        _got_load  = LOADADDR(.got);
        _got_start = .;
        *(.got .got.*)
        *(.got.plt)
        _got_end = .;
    } > SRAM AT > FLASH

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        _data_end = .;
    } > SRAM AT > FLASH

    _data_load = LOADADDR(.data);
    __ram_load_addr = _data_load;
    __ram_data_start__ = _data_start;
    __ram_data_end__ = _data_end;

    .tdata : ALIGN(4)
    {
        _tdata_start = .;
        *(.tdata .tdata.*)
        _tdata_end = .;
    } > SRAM AT > FLASH

    _tdata_load = LOADADDR(.tdata);

    .tbss (NOLOAD) : ALIGN(4)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    /* ARM EABI reserves an 8-byte TCB, padded to the TLS segment alignment. */
    _tls_base = (SIZEOF(.tdata) ? ADDR(.tdata) : ADDR(.tbss)) - MAX(8, MAX(ALIGNOF(.tdata), ALIGNOF(.tbss)));

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > SRAM

    /* @persist: never zeroed or loaded; prior contents survive a reset. */
    .persist (NOLOAD) : ALIGN(8)
    {
        *(.persist .persist.*)
        . = ALIGN(8);
        _persist_end = .;
    } > SRAM

    _stack_size = 4K;

    __heap_start = _persist_end;
    __heap_end   = ORIGIN(SRAM) + LENGTH(SRAM) - _stack_size;

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    _stack_low = __heap_end;
    __StackTop = _stack_top;
    ASSERT(__heap_end > __heap_start, "SRAM exhausted: static data collides with the stack")

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
