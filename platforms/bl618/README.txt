BL618 (Bouffalo Lab) -- T-Head E907 RV32IMAFC @ 320 MHz
========================================================

Reference board: Sipeed M0P Dock.

Setup
-----

Toolchain (Ubuntu 22.04+):

    # D compiler -- LDC with the official upstream build (includes RISC-V).
    # The Ubuntu apt 'ldc' package also works but may lag the latest release.
    curl -fsS https://dlang.org/install.sh | bash -s ldc
    source ~/dlang/ldc-*/activate

    # RISC-V cross-toolchain and picolibc
    sudo apt-get install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf

Flash tool (Python, host-side; no target dependency):

    pip install bflb-mcu-tool

Windows: LDC installer from https://github.com/ldc-developers/ldc/releases.
RISC-V toolchain from the xpack distribution
(https://xpack.github.io/dev-tools/riscv-none-elf-gcc/) -- put its bin
directory on PATH; picolibc is bundled. Or use WSL2 with the Ubuntu
instructions above.

Build the unittest image
------------------------

From the URT root:

    make PLATFORM=bl618 CONFIG=unittest

Outputs (in bin/bl618_unittest/):

    urt_test         ELF with debug symbols
    urt_test.bin     Raw binary, ready to flash

Toolchain required: ldc, gcc-riscv64-unknown-elf, picolibc-riscv64-unknown-elf.
Linker script: third_party/urt/platforms/bl618/bl618.ld (uses flash XIP from
0xA0000000, OCRAM at 0x22020000, DTCM at 0x20000000).

Flash
-----

Bouffalo's official tool is BLDevCube (GUI) or bflb-mcu-tool (CLI):

    pip install bflb-mcu-tool
    bflb-mcu-tool --chipname bl616 --interface uart \
                  --port /dev/ttyUSB0 --baudrate 2000000 \
                  --firmware bin/bl618_unittest/urt_test.bin \
                  --addr 0x0

Hold BOOT, tap RESET, release BOOT to enter the ROM bootloader before
running the command. The chipname is "bl616" -- BL618 is a pin/package
variant of the same die, the tool only knows the bl616 family identifier.

Console
-------

UART0 on the default pins (GPIO14 TX, GPIO15 RX on the M0P Dock, exposed
on the onboard USB-serial bridge). 2 Mbaud, 8N1. The unittest harness
prints test results to stdout, then halts; tap RESET to re-run.

Notes
-----

* The memory map in bl618.ld is from the BL616 reference manual and may
  need tweaking for non-Sipeed boards. Verify against the vendor BSP for
  your specific carrier.
* No FreeRTOS, no SDK -- bare metal. URT brings its own start.S, syscall
  stubs, UART driver, and IRQ table.
