// HBN (hibernate) RAM, 4K at 0x20010000, survives deep sleep while VBAT holds, and a reset short of the pin or
// power. Its base holds state every Bouffalo build and both BL808 cores share, at a fixed address: the clock,
// so whichever core boots first restores what the other seeded. Above it each build's @persist data drifts
// freely within its own region, and urt.driver.reset keeps each core's reset record in a fixed slot.
module urt.driver.bl_common.hbn;

@nogc nothrow:


/// Every build reads this layout at the same address, so it changes only with HBN_MAGIC.
struct HbnPersist
{
    enum uint HBN_MAGIC = 0x4F57_4254; // "OWBT" (OpenWatt Boot Time)
    alias magic_value = HBN_MAGIC;

    uint magic;
    long utc_offset; // HBN ticks from RTC epoch to Unix epoch
}

/// Access the persistent state in HBN RAM.
HbnPersist* hbn_persist() => cast(HbnPersist*)hbn_shared;


private:

enum size_t hbn_shared = 0x2001_0000;
static assert(HbnPersist.sizeof <= 0x40, "the shared HBN state outgrew its 64 bytes below the @persist regions");
