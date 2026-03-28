/// BL808 GPIO and WS2812 LED driver
///
/// GPIO config registers: GLB_BASE + 0x8C4 + pin*4
///   bits[4:0] = function (11 = SWGPIO, software-controlled)
///   bit[6]    = input enable
///   bit[11]   = output enable
///   bit[17]   = output value
///   bit[24]   = pull-up enable
///   bit[25]   = pull-down enable
///
/// WS2812B on the M1s Dock board: GPIO8
module sys.bl808.gpio;

@nogc nothrow:

private:

enum uint GLB_BASE      = 0x2000_0000;
enum uint GPIO_CFG_BASE = GLB_BASE + 0x8C4;

// GPIO_CFG field values
enum uint GPIO_FUN_SWGPIO  = 11;
enum uint GPIO_OUTPUT_EN   = 1u << 11;
enum uint GPIO_OUTPUT_HIGH = 1u << 17;

// WS2812 LED pin on M1s Dock
enum uint WS2812_PIN = 8;

// Timing loop counts — calibrated for ~480MHz D0 core clock.
// WS2812B spec: T0H=400ns, T0L=850ns, T1H=800ns, T1L=450ns (±150ns).
// At 480MHz: 1 cycle ≈ 2.08ns, so T0H ≈ 192 cycles, T1H ≈ 384 cycles.
// Loop body (addi + bnez compressed) ≈ 2 cycles → divide by 2.
enum uint WS_T0H_LOOPS = 80;    // ~400ns at 400MHz
enum uint WS_T0L_LOOPS = 170;   // ~850ns at 400MHz
enum uint WS_T1H_LOOPS = 160;   // ~800ns at 400MHz
enum uint WS_T1L_LOOPS = 90;    // ~450ns at 400MHz
enum uint WS_RESET_US  = 60;    // µs for reset pulse (>50µs required)

pragma(inline, true)
void gpio_cfg_write(uint pin, uint value)
{
    *cast(uint*)(GPIO_CFG_BASE + pin * 4) = value;
}

pragma(inline, true)
void delay_loops(ulong n)
{
    // =r → output (ulong/i64); 0 → input tied to output 0 (same register, same type).
    import ldc.llvmasm;
    cast(void) __asm!ulong(`
        1: addi $0, $0, -1
           bnez $0, 1b
    `, "=r,0", n);
}

void gpio_set(uint pin, bool high)
{
    uint cfg = GPIO_FUN_SWGPIO | GPIO_OUTPUT_EN;
    if (high)
        cfg |= GPIO_OUTPUT_HIGH;
    gpio_cfg_write(pin, cfg);
}

public:

/// Configure a pin as software-controlled output, initially low.
void gpio_output_init(uint pin)
{
    gpio_cfg_write(pin, GPIO_FUN_SWGPIO | GPIO_OUTPUT_EN);
}

/// Set pin output level.
void gpio_output_set(uint pin, bool high)
{
    gpio_set(pin, high);
}

/// Send one WS2812 bit (0 = short high, 1 = long high) on the given pin.
private void ws2812_bit(uint pin, bool one)
{
    if (one)
    {
        gpio_set(pin, true);
        delay_loops(WS_T1H_LOOPS);
        gpio_set(pin, false);
        delay_loops(WS_T1L_LOOPS);
    }
    else
    {
        gpio_set(pin, true);
        delay_loops(WS_T0H_LOOPS);
        gpio_set(pin, false);
        delay_loops(WS_T0L_LOOPS);
    }
}

/// Send one byte (MSB first) to a WS2812 LED.
private void ws2812_byte(uint pin, ubyte b)
{
    foreach (i; 0 .. 8)
        ws2812_bit(pin, (b & (0x80 >> i)) != 0);
}

/// Send one GRB pixel to the WS2812 at the given pin.
/// Colours: r/g/b = 0..255.
void ws2812_send(uint pin, ubyte r, ubyte g, ubyte b)
{
    gpio_output_init(pin);
    ws2812_byte(pin, g);   // WS2812 order: G, R, B
    ws2812_byte(pin, r);
    ws2812_byte(pin, b);
    // Reset: hold low for >50µs
    gpio_set(pin, false);
    delay_loops(WS_RESET_US * 200);  // ~60µs at 400MHz
}

/// Set the on-board WS2812 LED colour.
void led_set(ubyte r, ubyte g, ubyte b)
{
    ws2812_send(WS2812_PIN, r, g, b);
}

/// Boot-stage colour helpers
void led_red()   { led_set(32, 0,  0);  }
void led_green() { led_set(0,  32, 0);  }
void led_blue()  { led_set(0,  0,  32); }
void led_white() { led_set(16, 16, 16); }
void led_off()   { led_set(0,  0,  0);  }
