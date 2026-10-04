BL808 (Bouffalo Lab) -- multi-core SoC
======================================

Two heterogeneous cores in one package:

  D0  T-Head C906 RV64GC @ 480 MHz   (application/multimedia)
  M0  T-Head E907 RV32IMAFC @ 320 MHz (boot core, MCU domain)

Reference board: Sipeed M1s Dock.

There is also an LP core (E902) in the LP domain; URT does not target it.

Setup
-----

Toolchain (Ubuntu 22.04+):

    # D compiler -- LDC with the official upstream build.
    curl -fsS https://dlang.org/install.sh | bash -s ldc
    source ~/dlang/ldc-*/activate

    # RISC-V cross-toolchain and picolibc (covers both D0 RV64 and M0 RV32).
    sudo apt-get install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf

Flash tool (Python, host-side):

    pip install bflb-mcu-tool

The C906 (D0) core uses the T-Head xthead extensions; recent
gcc-riscv64-unknown-elf and LDC both accept the +xthead* mattr flags.
If you see "unsupported mattr" errors, your toolchain is too old --
upgrade to Ubuntu 24.04 or install LDC 1.36+ from the upstream tarball.

Windows: LDC installer from https://github.com/ldc-developers/ldc/releases;
xpack RISC-V toolchain (https://xpack.github.io/dev-tools/riscv-none-elf-gcc/);
or use WSL2 with the Ubuntu instructions above. Older xpack builds may
not include the xthead extensions needed for C906; if so, use the
T-Head toolchain from https://www.xrvm.cn/community/download.

Build the unittest image
------------------------

From the URT root:

    make PLATFORM=bl808 CONFIG=unittest       (M0, the core that owns the chip)
    make PLATFORM=bl808_d0 CONFIG=unittest    (D0, the C906 expansion core)

Outputs:

    bin/bl808_unittest/urt_test.bin       M0 firmware, runs XIP from flash
    bin/bl808_d0_unittest/urt_test.bin    D0 firmware, loads to PSRAM

Linker scripts: bl808_m0/bl808_m0.ld (M0 runs XIP from flash at
0x58000000) and bl808_d0/bl808_d0.ld (D0 runs from PSRAM at 0x50100000).

Boot dependency
---------------

Only M0 starts at power-on, and it is a complete part on its own. D0 runs
only if M0 starts it: M0 brings up the clocks and PSRAM, inflates a D0
payload appended to its own image (tools/bl808_image.py) into PSRAM, and
releases D0 at the payload's entry. An image without a payload leaves D0
halted.

Flash
-----

Hold BOOT, tap RESET, release BOOT to enter the ROM bootloader, then flash
the M0 image (with any D0 payload appended) with Bouffalo's DevCube or
bflb tools, chipname=bl808, through the partition table's FW slot.

Console
-------

UART0 on the default pins (exposed via the onboard USB-serial bridge on
the M1s Dock). 2 Mbaud, 8N1. M0 brings up UART early; D0 prints once it
has been released and reaches main().
