/* Unwind tables for NOEXCEPTIONS=1 builds. They are SHF_ALLOC and survive
 * --gc-sections, so they need an explicit discard; INSERT AFTER .text places
 * this ahead of any .eh_frame section the main script declares.
 *
 * Only applied where the crash driver walks the frame-pointer chain; targets
 * capturing via _Unwind_Backtrace still need them.
 */
SECTIONS
{
    /DISCARD/ :
    {
        *(.eh_frame)
        *(.eh_frame.*)
        *(.eh_frame_hdr)
        *(.gcc_except_table)
        *(.gcc_except_table.*)
        *(.ARM.exidx* .gnu.linkonce.armexidx.*)
        *(.ARM.extab* .gnu.linkonce.armextab.*)
    }
} INSERT AFTER .text;
