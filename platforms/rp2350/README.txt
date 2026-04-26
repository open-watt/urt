RP2350 (Raspberry Pi) -- dual Cortex-M33 @ 150 MHz
==================================================

520 KB SRAM, XIP from external QSPI flash. URT targets the Arm cores
(the chip also has dual Hazard3 RISC-V cores selectable at boot; URT
does not currently support that mode).

Reference board: Raspberry Pi Pico 2.

Setup
-----

Toolchain (Ubuntu 22.04+):

    # D compiler -- LDC with the official upstream build.
    curl -fsS https://dlang.org/install.sh | bash -s ldc
    source ~/dlang/ldc-*/activate

    # ARM cross-toolchain and picolibc.
    sudo apt-get install gcc-arm-none-eabi picolibc-arm-none-eabi

Flash tool (picotool, for ELF -> UF2 conversion):

    sudo apt-get install build-essential cmake libusb-1.0-0-dev
    git clone https://github.com/raspberrypi/picotool
    cd picotool && mkdir build && cd build && cmake .. && make
    sudo cp picotool /usr/local/bin/

Pre-built picotool binaries are also published at
https://github.com/raspberrypi/pico-sdk-tools/releases for those who
don't want to build from source.

Windows: LDC installer from https://github.com/ldc-developers/ldc/releases;
ARM GNU Toolchain installer from
https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads;
picotool prebuilt from the pico-sdk-tools releases page noted above.

Build the unittest image
------------------------

From the URT root:

    make PLATFORM=rp2350 CONFIG=unittest

Outputs (in bin/rp2350_unittest/):

    urt_test         ELF with debug symbols
    urt_test.bin     Raw binary

Toolchain required: ldc, gcc-arm-none-eabi, picolibc-arm-none-eabi.
Linker script: rp2350.ld.

Flash
-----

The RP2350 has a USB mass-storage bootloader -- hold BOOTSEL while
plugging in USB to enter it. Drag-and-drop a .uf2 file onto the
mounted RPI-RP2 volume.

Convert urt_test (the ELF, not the .bin) to UF2:

    picotool uf2 convert bin/rp2350_unittest/urt_test \
                         bin/rp2350_unittest/urt_test.uf2 \
                         --family rp2350-arm-s

(Install picotool from https://github.com/raspberrypi/picotool.)

Then drop urt_test.uf2 onto the RPI-RP2 volume. The board reboots and
runs immediately.

Alternatively, flash directly via SWD with openocd + the Pi-supplied
config files (slower; UF2 is the path of least resistance).

Console
-------

UART0 (GP0=TX, GP1=RX on the Pico 2 header), 115200 baud, 8N1. Or use
the picoprobe firmware on a second Pico for SWD + virtual UART.

The unittest harness prints results and halts. Tap RESET (or unplug/
replug USB) to re-run.

Notes
-----

* boot2.S is included in URT's start sources -- a second-stage bootloader
  that configures XIP for the QSPI flash chip on the Pico 2 board. Other
  boards with different flash chips may need a different boot2.
* The RP2350 has secure/non-secure split (TrustZone-M). URT runs
  entirely in secure mode; non-secure callable veneers are not set up.
