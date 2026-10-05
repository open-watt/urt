// BL808 chip reset from either core: the vendor's GLB_SW_POR_Reset, with the boot ROM's hand-off choice.
module urt.driver.bl808.reset;

import core.volatile : volatileLoad, volatileStore;

import urt.attribute : critical;
import urt.driver.bl808.watchdog : wdt_stop;

nothrow @nogc:

// Both cores and every clock drop to RC32M before the power-on reset, as the vendor does; the
// clock switch takes the flash clock with it, so this runs from RAM. download=true asks the boot
// ROM for its UART/USB download mode through HBN_RSV2, which survives the reset.
@critical noreturn por_reset(bool download)
{
    asm nothrow @nogc { "csrci mstatus, 8"; }
    wdt_stop();

    uint hand_off = volatileLoad(reg(hbn_rsv2)) & ~hand_off_mask;
    if (download)
        hand_off |= hand_off_release | hand_off_download;
    volatileStore(reg(hbn_rsv2), hand_off);

    set_field(mm_clk_ctrl_cpu, 10, 1, 0);               // D0 XCLK = RC32M
    set_field(mm_clk_ctrl_cpu, 11, 1, 0);               // D0 root = XCLK
    set_field(mm_clk_cpu, 0, 0xFF, 0);                  // CPU_CLK_DIV
    set_field(mm_clk_cpu, 16, 0xFF, 0);                 // BCLK2X_DIV
    set_field(mm_clk_ctrl_cpu, 18, 1, 1);               // BCLK2X_DIV_ACT_PULSE
    wait_bit(mm_clk_ctrl_cpu, 20);                      // BCLK2X_PROT_DONE

    set_field(hbn_glb, 0, 3, 0);                        // M0 XCLK = RC32M, root = XCLK
    set_field(glb_sys_cfg0, 8, 0xFF, 0);                // HCLK_DIV
    set_field(glb_sys_cfg0, 16, 0xFF, 0);               // BCLK_DIV
    set_field(glb_sys_cfg1, 0, 1, 1);                   // BCLK_DIV_ACT_PULSE
    wait_bit(glb_sys_cfg1, 2);                          // BCLK_PROT_DONE
    set_field(pds_cpu_core_cfg7, 0, 0xFF, 0);           // PICO_DIV
    set_field(glb_sys_cfg1, 16, 1, 1);                  // PICO_CLK_DIV_ACT_PULSE
    wait_bit(glb_sys_cfg1, 18);                         // PICO_CLK_PROT_DONE

    set_field(glb_swrst_cfg2, 0, 1, 0);                 // PWRON_RST pulse
    set_field(glb_swrst_cfg2, 0, 1, 1);
    set_field(glb_swrst_cfg2, 0, 1, 0);
    for (;;) {}
}

private:

enum uint hbn_glb           = 0x2000_F030;
enum uint hbn_rsv2          = 0x2000_F108;
enum uint glb_sys_cfg0      = 0x2000_0090;
enum uint glb_sys_cfg1      = 0x2000_0094;
enum uint glb_swrst_cfg2    = 0x2000_0548;
enum uint pds_cpu_core_cfg7 = 0x2000_E12C;
enum uint mm_clk_ctrl_cpu   = 0x3000_7000;
enum uint mm_clk_cpu        = 0x3000_7004;

// HBN_RSV2 [31:24] marks the hand-off valid, [23:22] picks it: 0 boot pin, 1 download, 2 flash.
enum uint hand_off_mask     = 0xFFC0_0000;
enum uint hand_off_release  = 0x48 << 24;
enum uint hand_off_download = 1 << 22;

pragma(inline, true) uint* reg(uint address)
    => cast(uint*)address;

pragma(inline, true) void set_field(uint address, uint shift, uint mask, uint value)
{
    uint v = volatileLoad(reg(address));
    volatileStore(reg(address), (v & ~(mask << shift)) | (value << shift));
}

pragma(inline, true) void wait_bit(uint address, uint bit)
{
    for (uint timeout = 1024; timeout && !(volatileLoad(reg(address)) & (1 << bit)); --timeout) {}
}
