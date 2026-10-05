/* BL808 D0 core (T-Head C906 RV64GC) linker script
 *
 * D0 has no image of its own in flash. M0 carries it deflated after the end of the M0
 * image and inflates each load segment straight to its run address, then starts D0 at
 * the ELF entry. Nothing is copied at boot; start.S only zeroes .bss and .tbss.
 *
 *   PSRAM:   0x50100000, 60MB  (.text .. .data, then .bss and the heap)
 *   SRAM:    0x3eff8000, 64KB  (.got + .sram_data fast globals + .tdata/.tbss + stack)
 *   HBNRAM:  0x20010800, 2KB   (D0's half of HBN RAM, less its record; survives hibernate if VBAT maintained)
 */

ENTRY(_start)

/* Force-link newlib syscall stubs and D runtime symbols
 * (otherwise --gc-sections strips them before newlib resolves) */
EXTERN(_write _read _close _lseek _fstat _isatty _sbrk _exit _kill _getpid)
EXTERN(_Dmodule_ref __errno_location stdout)
EXTERN(socket close poll _accept _recv _recvfrom _sendmsg)
EXTERN(_shutdown _bind _listen _connect setsockopt getsockname getpeername)
EXTERN(getaddrinfo freeaddrinfo)

MEMORY
{
    PSRAM  (rwx) : ORIGIN = 0x50100000, LENGTH = 60M
    SRAM   (rwx) : ORIGIN = 0x3eff8000, LENGTH = 64K
    HBNRAM (rw)  : ORIGIN = 0x20010800, LENGTH = 0x7F0
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.entry))
        . = ALIGN(4);
        *(.text.psram_early)
        *(.text .text.*)
    } > PSRAM

    .rodata : ALIGN(8)
    {
        *(.rodata .rodata.*)
    } > PSRAM

    /* DWARF exception handling -- required for D throw/catch (fibre abort, etc.). */
    .eh_frame : ALIGN(8)
    {
        __eh_frame_start = .;
        KEEP(*(.eh_frame))
        KEEP(*(.eh_frame_hdr))
    } > PSRAM

    .gcc_except_table : ALIGN(4)
    {
        *(.gcc_except_table .gcc_except_table.*)
    } > PSRAM

    /* Init array -- LDC module info registration functions. Called from start.S before main(). */
    .init_array : ALIGN(8)
    {
        __init_array_start = .;
        KEEP(*(.init_array))
        __init_array_end = .;
    } > PSRAM

    .data : ALIGN(8)
    {
        *(.data .data.*)
    } > PSRAM

    .bss (NOLOAD) : ALIGN(8)
    {
        __bss_start__ = .;
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
        __bss_end__ = .;
    } > PSRAM

    .got : ALIGN(8)
    {
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.got .got.*)
        *(.got.plt)
        *(.sdata .sdata.*)
        *(.srodata .srodata.*)
    } > SRAM

    /* @fast_data -- frequently-accessed globals in fast on-chip SRAM. */
    .sram_data : ALIGN(8)
    {
        *(.sram_data .sram_data.*)
    } > SRAM

    /* TLS: .tdata + .tbss must be VMA-contiguous (they form the TLS template). */
    .tdata : ALIGN(8)
    {
        *(.tdata .tdata.*)
    } > SRAM

    _tdata_start = ADDR(.tdata);
    _tdata_end   = _tdata_start + SIZEOF(.tdata);

    .tbss (NOLOAD) : ALIGN(8)
    {
        _tbss_start = .;
        *(.tbss .tbss.*)
        _tbss_end = .;
    } > SRAM

    /* HBN RAM: persistent across hibernate, not initialized by startup */
    .hbn_ram (NOLOAD) : ALIGN(4)
    {
        *(.hbn_ram)
    } > HBNRAM

    /* PSRAM heap pool: end of .bss to the end of PSRAM. */
    __psram_heap_start = ALIGN(_bss_end, 8);
    __psram_heap_end   = ORIGIN(PSRAM) + LENGTH(PSRAM);

    /* SRAM heap pool (fast / dma / fastest -- D0 has no DTCM). End of .tbss
     * up to stack reservation at top of SRAM. */
    __sram_heap_start = ALIGN(_tbss_end, 8);
    __sram_heap_end   = ORIGIN(SRAM) + LENGTH(SRAM) - 16K;

    /* Stack in fast on-chip SRAM, top 16K reserved. */
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
    _stack_low = __sram_heap_end;
    __StackTop = _stack_top;

    /* Compatibility aliases for get_sysinfo (urt.system.d). */
    __heap_start = __psram_heap_start;
    __heap_end   = __psram_heap_end;

    /* Vendor start_load.c expects these symbols for ITCM/DTCM/system RAM
     * copy loops. We don't use those sections, so define them as empty. */
    PROVIDE(__itcm_load_addr = 0);
    PROVIDE(__tcm_code_start__ = 0);
    PROVIDE(__tcm_code_end__ = 0);
    PROVIDE(__dtcm_load_addr = 0);
    PROVIDE(__tcm_data_start__ = 0);
    PROVIDE(__tcm_data_end__ = 0);
    PROVIDE(__system_ram_load_addr = 0);
    PROVIDE(__system_ram_data_start__ = 0);
    PROVIDE(__system_ram_data_end__ = 0);

    /DISCARD/ :
    {
        *(.comment)
        *(.note.*)
        *(.gnu.hash)
        *(.gnu.linkonce.*)
    }
}
