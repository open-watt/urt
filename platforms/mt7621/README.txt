MT7621A (MediaTek) -- dual MIPS 1004Kc @ 880 MHz, no FPU
=========================================================

MIPS32r2 little-endian, soft-float o32. URT runs on one VPE of core 0.

Reference board: MikroTik hEX S (RB760iGS), 256 MB DDR3, 16 MB SPI NOR.

The image is a RAM-resident ELF linked at 0x80001000 (where Linux sits on
this SoC). The board's bootloader loads its PT_LOAD segments and jumps to
_start; URT has no boot stage of its own and assumes DDR, PLLs and the
console UART are already up.

Toolchain
---------

No distro ships a bare-metal soft-float mipsel toolchain, and the musl.cc
libgcc is PIC abicalls code (it derives gp from t9, which non-abicalls
callers never set). So the musl.cc gcc only assembles and preprocesses, and
a sysroot is built with it holding picolibc and compiler-rt builtins, both
non-PIC:

    mkdir -p ~/toolchains && cd ~/toolchains
    curl -fsSL https://musl.cc/mipsel-linux-muslsf-cross.tgz | tar xz

    TC=~/toolchains/mipsel-linux-muslsf-cross
    GI=$TC/lib/gcc/mipsel-linux-muslsf/11.2.1
    SYSROOT=~/toolchains/picolibc-mipsel
    CFLAGS="-nostdlib -nostdinc -isystem $GI/include -isystem $GI/include-fixed \
            -ffreestanding -march=mips32r2 -msoft-float -EL -G0 -fno-pic -mno-abicalls"

picolibc (needs meson and ninja), with a meson cross file whose c entry is
the gcc plus $CFLAGS, and whose host_machine is cpu_family 'mips',
endian 'little', system 'none':

    git clone https://github.com/picolibc/picolibc && cd picolibc
    meson setup build-mipsel --cross-file cross-mipsel.txt -Dprefix=$SYSROOT \
        -Dmultilib=false -Dpicocrt=false -Dsemihost=false -Dtests=false \
        -Dspecsdir=none -Dthread-local-storage=false
    ninja -C build-mipsel install

compiler-rt builtins: compile each lib/builtins/*.c from llvm-project with
the same gcc and $CFLAGS -isystem $SYSROOT/include -O2 -fno-builtin, skip
the x87/bf16/atomic_flag files that do not build for this target, and
archive the objects as $SYSROOT/lib/libclang_rt.builtins.a.

MIPSEL_GCC and MIPSEL_SYSROOT override the default locations above.

Build
-----

    make BOARD=rb760igs CONFIG=release

Outputs (in bin/mt7621_rb760igs_release/): openwatt, the ELF with symbols, and
kernel, the same ELF stripped. The board sets the RAM size the linker sizes the
heap and stack from.

Boot (MikroTik RouterBOOT)
--------------------------

RouterBOOT boots an ELF either over the network (BOOTP, then TFTP, on ether1)
or from a file named `kernel` in the filesystem on the flash `firmware`
partition (0x40000-0x1000000; 0x0-0x40000 is RouterBOOT itself and must not be
touched).

To netboot without touching flash, serve `kernel` over BOOTP and TFTP, then
either set the next boot to the network from RouterOS:

    /system/routerboard/settings/set boot-device=try-ethernet-once-then-nand
    /system/reboot

or hold the reset button through power-on until the board asks the network for
an image. RouterBOOT boots from flash again afterwards; the running image can
also arm the next netboot itself by rewriting soft_config.

Console
-------

UART1 (the 16550 at 0x1E000C00, reg-shift 2), 115200 8N1, is on pads inside the
hEX S; no header is fitted. Console output is also broadcast as UDP to port 6666
out of every front port, from 192.168.0.248, until the platform has a network
log sink. UART2 and UART3 are pinmuxed to GPIO on this board.
