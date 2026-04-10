/* RP2350 second-stage bootloader (boot2)
 *
 * The RP2350 ROM reads this 256-byte block from the start of QSPI flash,
 * copies it to SRAM, and executes it.  boot2's job is to configure the
 * QSPI controller for XIP (execute-in-place), then return to the ROM
 * which will then load the vector table from flash.
 *
 * This is a minimal stub that configures generic 03h SPI read mode.
 * It works with any standard SPI flash but is slow (single-bit, no XIP cache).
 * For production, replace with the Pico SDK's boot2_w25q080.S (or similar)
 * which enables QSPI and continuous read mode for much better performance.
 *
 * The block must be exactly 256 bytes.  The last 4 bytes are a CRC32
 * checksum of the first 252 bytes (verified by the ROM before execution).
 */

    .syntax unified
    .cpu    cortex-m33
    .thumb

    .section .boot2, "ax"
    .global __boot2_entry
    .type   __boot2_entry, %function
__boot2_entry:

/* SSI (Synopsys SSI / QSPI controller) registers */
.equ SSI_BASE,      0x18000000
.equ SSI_CTRLR0,    0x00
.equ SSI_SSIENR,    0x08        /* SSI enable */
.equ SSI_SPI_CTRLR0, 0xF4      /* SPI control register */

/* Configure SSI for standard SPI 03h read, 32-bit address+data frames */

    /* Disable SSI while configuring */
    ldr     r3, =SSI_BASE
    movs    r0, #0
    str     r0, [r3, #SSI_SSIENR]

    /* CTRLR0: 8-bit data frames, SPI mode 0 (CPOL=0, CPHA=0) */
    movs    r0, #0x07           /* DFS = 8-1 = 7 (8-bit frames) */
    movs    r1, #0
    orr     r0, r0, r1          /* TMOD=0 (TX+RX), FRF=0 (Motorola SPI) */
    str     r0, [r3, #SSI_CTRLR0]

    /* SPI_CTRLR0: standard 03h read, 24-bit address, 8 wait cycles */
    movs    r0, #0x03           /* INST_L=8bit (0x03), ADDR_L=24bit */
    lsls    r1, r0, #0
    movs    r0, #0x06           /* ADDR_L = 24 bits (6 * 4) */
    lsls    r0, r0, #2
    orr     r1, r1, r0
    /* TRANS_TYPE = 0 (instruction + address both in standard SPI) */
    str     r1, [r3, #SSI_SPI_CTRLR0]

    /* Re-enable SSI */
    movs    r0, #1
    str     r0, [r3, #SSI_SSIENR]

    /* Return to ROM -- it will now use XIP to read the vector table */
    bx      lr

    .size __boot2_entry, . - __boot2_entry

    /* Pad to 252 bytes (256 - 4 byte CRC32 at end) */
    .balign 256, 0x00
    /* CRC32 placeholder -- must be computed by the build tooling or
     * flash programmer.  The Pico SDK's pad_checksum tool does this.
     * For now, set to zero -- will need post-processing before flashing. */

    .size __boot2_entry, . - __boot2_entry
