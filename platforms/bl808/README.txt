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

    make PLATFORM=bl808 PROCESSOR=c906 CONFIG=unittest    (D0 image)
    make PLATFORM=bl808 PROCESSOR=e907 CONFIG=unittest    (M0 image)

Outputs:

    bin/bl808-d0_unittest/urt_test.bin    D0 firmware, loads to PSRAM
    bin/bl808-m0_unittest/urt_test.bin    M0 firmware, runs XIP from flash

Linker scripts: bl808_d0.ld (D0 expects to run from PSRAM at 0x50100000;
M0 firmware copies it from flash at boot). bl808_m0.ld (M0 runs XIP from
flash at 0x58000000).

Boot dependency
---------------

D0 cannot boot standalone -- only M0 starts at power-on. Before D0 can
fetch its first instruction, M0 must:

  1. Initialize clocks and PLLs.
  2. Bring up the flash controller and PSRAM controller.
  3. Copy the D0 firmware from flash (typically 0x580F0000) to PSRAM.
  4. Release D0 from reset by writing its boot-address register.

This means a D0-only urt_test.bin is a valid build artifact but is NOT
flashable on its own. To run the D0 unittests on hardware, flash both
images together: an M0 firmware that performs the handoff, plus the D0
image at the address M0 expects.

Flash
-----

Same tool as BL618, with chipname=bl808:

    pip install bflb-mcu-tool
    bflb-mcu-tool --chipname bl808 --interface uart \
                  --port /dev/ttyUSB0 --baudrate 2000000 \
                  --firmware bin/bl808-m0_unittest/urt_test.bin \
                  --addr 0x58000000

For a paired D0+M0 image, flash D0 at 0x580F0000 in the same command
(refer to BLDevCube's partition table editor for the proper layout).

Hold BOOT, tap RESET, release BOOT to enter ROM bootloader.

Console
-------

UART0 on the default pins (exposed via the onboard USB-serial bridge on
the M1s Dock). 2 Mbaud, 8N1. M0 brings up UART early; D0 prints once it
has been released and reaches main().
