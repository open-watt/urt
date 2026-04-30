// Linux GPIO via legacy /sys/class/gpio sysfs. Targets SBCs (Pi, Orange
// Pi, BeagleBone) where the kernel exposes pins as files. Pin numbering
// is the kernel's flat global GPIO number; each board documents its
// mapping.
//
// Sysfs is deprecated since Linux 4.8 in favour of gpio-cdev
// (/dev/gpiochipN ioctl) but ships in every shipping kernel. cdev
// backend is a future TODO.
//
// Limitations: no pull config (sysfs doesn't expose it; pulls come from
// device tree or external resistors), no peripheral muxing (kernel
// owns it), and one open/close per op (~10us each, fine for management
// rates).
module urt.driver.posix.gpio;

import urt.driver.gpio : Pull, DriveMode;
import urt.file : File, FileOpenMode, save_file, open, close, read;
import urt.mem.temp : tconcat;

nothrow @nogc:


enum uint num_gpio = 256;
enum bool has_pull_up = false;
enum bool has_pull_down = false;
enum bool has_open_drain = false;
enum bool has_pin_function_muxing = false;


// Walks /sys/class/gpio/gpiochip<N>/{base,ngpio} for N in 0..64 (covers
// real SBCs incl. Pi 5 where chips are at 0 and 4) and returns
// max(base+ngpio). 0 means no GPIO chips registered in sysfs.
uint gpio_count()
{
    uint max_pin = 0;
    foreach (i; 0 .. 64)
    {
        uint base, ngpio;
        if (!read_uint_file(tconcat("/sys/class/gpio/gpiochip", i, "/base"), base))
            continue;
        if (!read_uint_file(tconcat("/sys/class/gpio/gpiochip", i, "/ngpio"), ngpio))
            continue;
        uint top = base + ngpio;
        if (top > max_pin)
            max_pin = top;
    }
    return max_pin;
}

void gpio_output_init(uint pin, bool initial = false, DriveMode mode = DriveMode.push_pull)
{
    assert(mode == DriveMode.push_pull, "posix gpio: open-drain not supported via sysfs");
    save_file("/sys/class/gpio/export", tconcat(pin));   // EBUSY = already exported
    // "low" / "high" atomically set direction=out plus initial value.
    save_file(tconcat("/sys/class/gpio/gpio", pin, "/direction"), initial ? "high" : "low");
}

void gpio_input_init(uint pin, Pull pull = Pull.none)
{
    save_file("/sys/class/gpio/export", tconcat(pin));
    save_file(tconcat("/sys/class/gpio/gpio", pin, "/direction"), "in");
}

void gpio_output_set(uint pin, bool value)
{
    save_file(tconcat("/sys/class/gpio/gpio", pin, "/value"), value ? "1" : "0");
}

void gpio_output_toggle(uint pin)
{
    auto path = tconcat("/sys/class/gpio/gpio", pin, "/value");
    bool current;
    if (!read_bool_file(path, current))
        return;
    save_file(path, current ? "0" : "1");
}

bool gpio_input_read(uint pin)
{
    bool v;
    return read_bool_file(tconcat("/sys/class/gpio/gpio", pin, "/value"), v) && v;
}

void gpio_set_pull(uint pin, Pull pull)
{
}

void gpio_release(uint pin)
{
    save_file("/sys/class/gpio/unexport", tconcat(pin));
}


private:

bool read_bool_file(const(char)[] path, out bool value)
{
    File f;
    if (!f.open(path, FileOpenMode.ReadExisting))
        return false;
    ubyte[2] buf;
    size_t n;
    auto r = f.read(buf, n);
    f.close();
    if (!r || n == 0)
        return false;
    value = buf[0] == '1';
    return true;
}

bool read_uint_file(const(char)[] path, out uint value)
{
    File f;
    if (!f.open(path, FileOpenMode.ReadExisting))
        return false;
    ubyte[16] buf;
    size_t n;
    auto r = f.read(buf, n);
    f.close();
    if (!r)
        return false;
    uint v = 0;
    foreach (c; buf[0 .. n])
    {
        if (c < '0' || c > '9')
            break;
        v = v * 10 + (c - '0');
    }
    value = v;
    return true;
}
