// BL808 core clocks and the timer rate both cores share.
module urt.driver.bl808.clock;

nothrow @nogc:

enum uint xclk_hz = 40_000_000;         // the crystal
enum uint m0_clock_hz = 320_000_000;    // boot2's choice
enum uint d0_clock_hz = 480_000_000;    // the CPU PLL, set by M0

// Each core's mtime divides its own clock. M0 sets both to this rate and zeroes them together, so the
// cores read one timebase.
enum uint mtime_hz = 160_000_000;

static assert(m0_clock_hz % mtime_hz == 0 && d0_clock_hz % mtime_hz == 0 && mtime_hz % 1_000_000 == 0);
