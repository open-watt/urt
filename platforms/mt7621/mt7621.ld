/* RAM-resident image: RouterBOOT (netboot or the `kernel` file in flash) loads the ELF's PT_LOAD
   segments where they are linked and jumps to the entry point. Linked where Linux sits on MT7621. */
ENTRY(_start)

EXTERN(_write _read _close _lseek _fstat _isatty _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)

PHDRS
{
    text PT_LOAD;
    data PT_LOAD;
}

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80001000, LENGTH = 512M - 4K
}

SECTIONS
{
    .vectors : ALIGN(4096)
    {
        KEEP(*(.vectors))
    } > RAM :text

    .text : ALIGN(4)
    {
        _text_start = .;
        KEEP(*(.text.start))
        *(.text .text.*)
        _text_end = .;
    } > RAM

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > RAM

    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > RAM

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > RAM

    .init_array : ALIGN(4)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > RAM

    .data : ALIGN(8)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM :data

    .got : ALIGN(16)
    {
        *(.got .got.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(8)
    {
        _bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        _bss_end = .;
    } > RAM

    _stack_size = 64K;

    /* __ram_size comes from the board (--defsym); RAM above is only the KSEG0 ceiling. The 4K page
       below the stack is write-watched, so an overflow faults instead of reaching the heap. */
    _stack_top = 0x80000000 + __ram_size;
    _stack_low = _stack_top - _stack_size;
    _stack_guard = _stack_low - 4K;

    __heap_start = ALIGN(_bss_end, 16);
    __heap_end   = _stack_guard;
    ASSERT(__heap_end > __heap_start, "image does not fit the board's RAM")

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.pdr)
        *(.gnu.linkonce.*)
    }
}
