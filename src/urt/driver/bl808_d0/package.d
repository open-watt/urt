/// BL808 D0 core platform package.
///
/// Re-exports the D0 peripheral drivers. sys_init lives in
/// urt.driver.bl_common.system and is shared with M0 / BL618.
module urt.driver.bl808_d0;

public import urt.driver.bl_common.uart;
public import urt.driver.bl808_d0.irq;
public import urt.driver.bl808_d0.timer;
public import urt.driver.bl808_d0.xram;
public import urt.driver.bl808_d0.ipc;
public import urt.driver.bl_common.system;
