STM32 (STMicroelectronics) -- Cortex-M4F / Cortex-M7F
=====================================================

Three PLATFORMs:

  stm32f4  STM32F4 family (Cortex-M4F, FPv4-SP-D16, 168 MHz)
  stm32f7  STM32F7 family (Cortex-M7F, FPv5-D16, 168 MHz)
  stm32h7  STM32H7 family (Cortex-M7F, FPv5-D16, 400 MHz)

The Geehy APM32F407 is register-compatible and builds as stm32f4.

Board facts are make variables:

  STM32_PART    memory map, platforms/stm32/stm32_<part>.ld. Defaults: f407vg, f746ng, h743vi.
  STM32_HSE_HZ  HSE crystal in Hz. Unset runs from HSI.

Each part script declares MEMORY and the CORE_RAM / BULK_RAM aliases and includes
stm32_common.ld. CORE_RAM (F4 CCM, F7/H7 DTCM) holds statics, TLS and the stack; BULK_RAM
(system or AXI SRAM) holds .ramfunc and the heap. The part script sizes the stack: 16 KB on the
64 KB core-RAM parts, 32 KB on H7; a board overrides it with -L--defsym=_stack_size=N. Add a part
by writing a new stm32_<part>.ld.

Setup
-----

Toolchain (Ubuntu 22.04+):

    curl -fsS https://dlang.org/install.sh | bash -s ldc
    source ~/dlang/ldc-*/activate
    sudo apt-get install gcc-arm-none-eabi picolibc-arm-none-eabi

Flash tools, any one of: STM32CubeProgrammer, openocd with an ST-LINK or J-Link, or dfu-util for
the ROM bootloader.

Build the unittest image
------------------------

From the URT root:

    make PLATFORM=stm32h7 CONFIG=unittest
    make PLATFORM=stm32f4 STM32_PART=f407ve STM32_HSE_HZ=25000000 CONFIG=unittest

Output: bin/<platform>_unittest/urt_test.bin, linked at 0x08000000.

Flash
-----

    STM32_Programmer_CLI -c port=SWD -d bin/stm32h7_unittest/urt_test.bin 0x08000000 -rst
    openocd -f interface/stlink.cfg -f target/stm32h7x.cfg \
            -c "program bin/stm32h7_unittest/urt_test.bin 0x08000000 verify reset exit"
    dfu-util -a 0 -s 0x08000000:leave -D bin/stm32h7_unittest/urt_test.bin

dfu-util needs the ROM bootloader: BOOT0 high at reset.

Console
-------

USART1 on PA9 (TX) / PA10 (RX), 115200 8N1. The boot banner reports the core clock, whether it
runs from HSE, and the flash size the factory programmed.
