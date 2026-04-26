BK7231 (Beken) -- ARM968E-S @ 120 MHz, ARMv5TE
==============================================

Two variants in this directory:

  bk7231n   Wi-Fi 802.11b/g/n + BLE 5.0
  bk7231t   Wi-Fi only (no BLE)

Both share the same MCU core and most peripherals. SRAM layout differs
(N reserves TCM regions for the BLE stack; T uses full SRAM). They are
NOT interchangeable -- flashing the wrong image will not boot.

Setup
-----

Toolchain (Ubuntu 22.04+):

    # D compiler -- LDC with the official upstream build.
    curl -fsS https://dlang.org/install.sh | bash -s ldc
    source ~/dlang/ldc-*/activate

    # ARM cross-toolchain and picolibc.
    sudo apt-get install gcc-arm-none-eabi picolibc-arm-none-eabi

Flash tool (Python; bundled with OpenBK7231T_App):

    git clone https://github.com/openshwprojects/OpenBK7231T_App
    pip install pyserial    # only dependency hid_download.py needs

The flasher is at OpenBK7231T_App/scripts/hid_download.py -- run it
directly, no install step.

Windows: LDC installer from https://github.com/ldc-developers/ldc/releases;
ARM GNU Toolchain installer from
https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads.

Build the unittest image
------------------------

From the URT root:

    make PLATFORM=bk7231n CONFIG=unittest
    make PLATFORM=bk7231t CONFIG=unittest

Outputs:

    bin/bk7231n_unittest/urt_test.bin
    bin/bk7231t_unittest/urt_test.bin

Toolchain required: ldc, gcc-arm-none-eabi, picolibc-arm-none-eabi.
Linker scripts: bk7231n.ld (192 KB SRAM, BLE TCM carve-out) and
bk7231t.ld (256 KB SRAM, no carve-out).

This URT-only build does NOT include the Beken SDK -- no Wi-Fi, no BLE,
no SDK-provided UART driver beyond what URT ships. The full OpenWatt
build links against libbeken.a + WiFi/BLE blobs; the URT unittest does
not. The image will boot, run unittests, print results to UART, halt.

Flash
-----

Use hid_download_py from the OpenBK7231T_App project:

    git clone https://github.com/openshwprojects/OpenBK7231T_App
    cd OpenBK7231T_App/scripts
    python hid_download.py -d COM5 -f bin/bk7231n_unittest/urt_test.bin \
                           -c bk7231n -a 0x011000

(Use bk7231t / -a 0x011000 for the T variant.)

The bootloader expects the application at offset 0x11000 in flash. Hold
the CEN/RESET button while invoking the tool to enter download mode.

Console
-------

UART1 (the SDK calls it "uart_print"), 921600 baud, 8N1. Pins are board-
specific; on most modules UART1 is broken out to a header. The unittest
harness prints results then halts.

Notes
-----

* ARMv5TE has no atomic instructions. URT's start.S sets the LLVM
  thread-model to "single" so atomics lower to plain loads/stores --
  fine for single-core unittests, NOT safe if you ever bring up
  the SDK's RTOS scheduler alongside URT code.
* Vector table lives in the bootloader (no VTOR on ARM968E-S) -- IRQs
  must be installed via SDK API in real applications. The URT unittest
  runs polled, so this is not exercised.
