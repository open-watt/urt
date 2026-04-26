STM32 (STMicroelectronics) -- Cortex-M4F / Cortex-M7F
=====================================================

Two PLATFORM aliases supported:

  stm4xx   STM32F4 family (Cortex-M4F, FPv4-SP-D16)
  stm7xx   STM32F7 family (Cortex-M7F, FPv5-D16)

Linker scripts: stm32_f4.ld and stm32_f7.ld respectively. Each is a
generic-ish memory map -- override flash/RAM sizes in the script if
your specific part has more or less than the defaults.

Setup
-----

Toolchain (Ubuntu 22.04+):

    # D compiler -- LDC with the official upstream build.
    curl -fsS https://dlang.org/install.sh | bash -s ldc
    source ~/dlang/ldc-*/activate

    # ARM cross-toolchain and picolibc.
    sudo apt-get install gcc-arm-none-eabi picolibc-arm-none-eabi

Flash tools (pick one; you do not need all three):

    # ST-LINK + STM32CubeProgrammer -- official ST tool, GUI + CLI.
    # Download from https://www.st.com/en/development-tools/stm32cubeprog.html
    # (free with registration). Adds STM32_Programmer_CLI to PATH.

    # OpenOCD with ST-LINK or J-Link -- open-source.
    sudo apt-get install openocd

    # dfu-util for the ROM bootloader path.
    sudo apt-get install dfu-util

Windows: LDC installer from https://github.com/ldc-developers/ldc/releases;
ARM GNU Toolchain installer from
https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads;
STM32CubeProgrammer Windows installer (it also ships the ST-LINK USB
drivers, which you will need separately on first connect even with
OpenOCD).

Build the unittest image
------------------------

From the URT root:

    make PLATFORM=stm4xx CONFIG=unittest
    make PLATFORM=stm7xx CONFIG=unittest

Outputs:

    bin/stm4xx_unittest/urt_test.bin
    bin/stm7xx_unittest/urt_test.bin

Toolchain required: ldc, gcc-arm-none-eabi, picolibc-arm-none-eabi.

Flash
-----

Three common paths:

1. ST-LINK + STM32CubeProgrammer (GUI or CLI):

       STM32_Programmer_CLI -c port=SWD -d bin/stm4xx_unittest/urt_test.bin 0x08000000 -rst

2. openocd + ST-LINK or J-Link:

       openocd -f interface/stlink.cfg -f target/stm32f4x.cfg \
               -c "program bin/stm4xx_unittest/urt_test.bin 0x08000000 verify reset exit"

   (Use target/stm32f7x.cfg for stm7xx.)

3. DFU bootloader (ROM-resident on most parts):

       dfu-util -a 0 -s 0x08000000 -D bin/stm4xx_unittest/urt_test.bin

   Requires entering DFU mode -- typically BOOT0 high at reset.

The reset vector and image base are at 0x08000000 in all three cases
(internal flash bank 1).

Console
-------

USART2 by default (PA2=TX, PA3=RX on most Nucleo and Discovery boards;
exposed via the ST-LINK USB-CDC bridge). 115200 baud, 8N1. Some boards
mux the ST-LINK VCP to USART3 instead; check the board user manual.

The unittest harness prints results and halts. Tap RESET to re-run.

Notes
-----

* The default linker script assumes 1 MB flash + 192 KB RAM (a common
  F4/F7 mid-range part). Edit the MEMORY block in stm32_f4.ld or
  stm32_f7.ld for your specific MCU.
* No HAL, no LL drivers, no CubeMX -- URT brings its own start.S,
  vector table stub, and minimal UART driver. If you need on-chip
  peripherals beyond UART you will need to write them or pull in the
  vendor headers manually.
* MFPU defaults: F4 = fpv4-sp-d16 (single-precision only), F7 =
  fpv5-d16 (double-precision). The Makefile picks these per
  STM32_VARIANT; override with MFPU=... if your part differs.
