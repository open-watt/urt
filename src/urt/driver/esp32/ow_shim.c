// OpenWatt ESP-IDF shim -- the single C bridge between D and ESP-IDF.
// Wraps FreeRTOS macros, UART HAL inlines, and anything else that
// needs C headers or static-inline access.

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "driver/uart.h"
#include "driver/ledc.h"
#include "esp_rom_serial_output.h"
#include "soc/soc_caps.h"
#include <stdbool.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/types.h>
#include <reent.h>
#ifdef OW_USE_LWIP
#include "lwip/netdb.h"
#endif

// ESP32-C3 ROM exports uart_tx_one_char but not esp_rom_uart_putc.
// Provide the missing symbol so the D object links.
#if defined(CONFIG_IDF_TARGET_ESP32C3) && !defined(esp_rom_uart_putc)
void esp_rom_uart_putc(char c) { esp_rom_output_tx_one_char(c); }
#endif

// -- errno accessor (picolibc uses _Thread_local errno, incompatible with emulated-TLS) --

#include <errno.h>

int *ow_errno_location(void)
{
    return &errno;
}

// IDF's no-VFS syscall adapter also dispatches high file descriptors to lwIP.
// Internal-IP builds wrap those entry points so ordinary C stdio stays on the
// console without retaining the socket adapter and, through it, the full stack.
extern ssize_t _write_r_console(struct _reent *r, int fd, const void *data, size_t size);
extern ssize_t _read_r_console(struct _reent *r, int fd, void *data, size_t size);

extern ssize_t __real__write_r(struct _reent *r, int fd, const void *data, size_t size);
extern ssize_t __real__read_r(struct _reent *r, int fd, void *data, size_t size);
extern int __real__close_r(struct _reent *r, int fd);
extern int __real__fcntl_r(struct _reent *r, int fd, int cmd, int arg);

// Only the three standard streams belong to the console; every other descriptor
// is a VFS file and must reach it, or the filesystem has no read or write.
#define OW_IS_CONSOLE_FD(fd) ((fd) >= 0 && (fd) <= 2)

ssize_t __wrap__write_r(struct _reent *r, int fd, const void *data, size_t size)
{
    if (OW_IS_CONSOLE_FD(fd))
        return _write_r_console(r, fd, data, size);
    return __real__write_r(r, fd, data, size);
}

ssize_t __wrap__read_r(struct _reent *r, int fd, void *data, size_t size)
{
    if (OW_IS_CONSOLE_FD(fd))
        return _read_r_console(r, fd, data, size);
    return __real__read_r(r, fd, data, size);
}

int __wrap__close_r(struct _reent *r, int fd)
{
    if (OW_IS_CONSOLE_FD(fd))
    {
        __errno_r(r) = ENOSYS;
        return -1;
    }
    return __real__close_r(r, fd);
}

int __wrap__fcntl_r(struct _reent *r, int fd, int cmd, int arg)
{
    if (OW_IS_CONSOLE_FD(fd))
    {
        __errno_r(r) = ENOSYS;
        return -1;
    }
    return __real__fcntl_r(r, fd, cmd, arg);
}

// -- WFI shim --
// Single-instruction inline asm; bound from D as ow_irq_wait. The
// surrounding portENTER_CRITICAL pair is handled D-side via direct
// vPortEnterCritical/vPortExitCritical bindings -- no C wrapper needed.

void ow_irq_wait(void)
{
#if CONFIG_IDF_TARGET_ARCH_XTENSA
    __asm__ volatile("waiti 0");
#elif CONFIG_IDF_TARGET_ARCH_RISCV
    __asm__ volatile("wfi");
#endif
}

// -- GPIO wrappers (software GPIO; peripheral function routing goes
//    through ESP-IDF's signal matrix on a per-peripheral basis, not
//    through this module).

#include "driver/gpio.h"
#include "esp_attr.h"
#include "esp_intr_alloc.h"
#include "soc/gpio_num.h"
#include "soc/gpio_struct.h"
#include "soc/interrupts.h"
#include <stdint.h>

// pull: 0=none, 1=up, 2=down (matches D Pull enum encoding)
static gpio_pull_mode_t ow_pull_to_idf(int pull)
{
    return (pull == 1) ? GPIO_PULLUP_ONLY :
           (pull == 2) ? GPIO_PULLDOWN_ONLY : GPIO_FLOATING;
}

void ow_gpio_output_init(int pin, int initial)
{
    gpio_reset_pin((gpio_num_t)pin);
    gpio_set_direction((gpio_num_t)pin, GPIO_MODE_OUTPUT);
    gpio_set_level((gpio_num_t)pin, initial);
}

void ow_gpio_input_init(int pin, int pull)
{
    gpio_reset_pin((gpio_num_t)pin);
    gpio_set_direction((gpio_num_t)pin, GPIO_MODE_INPUT);
    gpio_set_pull_mode((gpio_num_t)pin, ow_pull_to_idf(pull));
}

void IRAM_ATTR ow_gpio_output_set(int pin, int value)
{
    gpio_set_level((gpio_num_t)pin, value);
}

int ow_gpio_input_read(int pin)
{
    return gpio_get_level((gpio_num_t)pin);
}

void ow_gpio_set_pull(int pin, int pull)
{
    gpio_set_pull_mode((gpio_num_t)pin, ow_pull_to_idf(pull));
}

void ow_gpio_release(int pin)
{
    gpio_reset_pin((gpio_num_t)pin);
}

uint32_t ow_gpio_count(void)
{
    return SOC_GPIO_PIN_COUNT;
}

int ow_pwm_open(unsigned port, unsigned pin, unsigned frequency, unsigned resolution, unsigned initial_duty, bool inverted)
{
    if (port >= LEDC_TIMER_MAX || port >= LEDC_CHANNEL_MAX)
        return -1;

    ledc_timer_config_t timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = (ledc_timer_bit_t)resolution,
        .timer_num = (ledc_timer_t)port,
        .freq_hz = frequency,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ledc_channel_config_t channel = {
        .gpio_num = pin,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = (ledc_channel_t)port,
        .intr_type = LEDC_INTR_DISABLE,
        .timer_sel = (ledc_timer_t)port,
        .duty = initial_duty,
        .hpoint = 0,
        .flags = { .output_invert = inverted },
    };
    if (ledc_timer_config(&timer) != ESP_OK)
        return -1;
    return ledc_channel_config(&channel) == ESP_OK ? 0 : -1;
}

int ow_pwm_set_duty(unsigned port, unsigned duty)
{
    if (port >= LEDC_CHANNEL_MAX || ledc_set_duty(LEDC_LOW_SPEED_MODE, (ledc_channel_t)port, duty) != ESP_OK)
        return -1;
    return ledc_update_duty(LEDC_LOW_SPEED_MODE, (ledc_channel_t)port) == ESP_OK ? 0 : -1;
}

void ow_pwm_close(unsigned port)
{
    if (port < LEDC_CHANNEL_MAX)
        ledc_stop(LEDC_LOW_SPEED_MODE, (ledc_channel_t)port, 0);
}

// -- Counter wrappers --

#include "driver/gptimer.h"

#if defined(CONFIG_IDF_TARGET_ESP32)

#if !CONFIG_GPTIMER_CTRL_FUNC_IN_IRAM || !CONFIG_GPTIMER_ISR_CACHE_SAFE
#error "counter alarms rearm from interrupt context; enable CONFIG_GPTIMER_CTRL_FUNC_IN_IRAM and CONFIG_GPTIMER_ISR_CACHE_SAFE"
#endif

#define OW_COUNTERS 4

typedef struct {
    bool (*callback)(unsigned port);
    gptimer_handle_t timer;
    gptimer_alarm_config_t alarm;
    portMUX_TYPE lock;
    unsigned port;
    bool started;
    bool enabled;
    bool open;
} ow_counter_t;

static ow_counter_t counters[OW_COUNTERS] = {
    { .lock = portMUX_INITIALIZER_UNLOCKED },
    { .lock = portMUX_INITIALIZER_UNLOCKED },
    { .lock = portMUX_INITIALIZER_UNLOCKED },
    { .lock = portMUX_INITIALIZER_UNLOCKED },
};

static bool IRAM_ATTR counter_alarm(gptimer_handle_t timer, const gptimer_alarm_event_data_t *event, void *context)
{
    (void)timer;
    (void)event;
    ow_counter_t *counter = context;
    bool (*callback)(unsigned);
    portENTER_CRITICAL_ISR(&counter->lock);
    callback = counter->callback;
    portEXIT_CRITICAL_ISR(&counter->lock);
    return callback ? callback(counter->port) : false;
}

void ow_counter_close(unsigned port);

int ow_counter_open(unsigned port, unsigned resolution_hz)
{
    if (port >= OW_COUNTERS || !resolution_hz)
        return -1;
    ow_counter_t *counter = &counters[port];
    if (counter->open)
        return -1;

    gptimer_config_t config = {
        .clk_src = GPTIMER_CLK_SRC_DEFAULT,
        .direction = GPTIMER_COUNT_UP,
        .resolution_hz = resolution_hz,
    };
    gptimer_event_callbacks_t callbacks = {
        .on_alarm = counter_alarm,
    };
    counter->port = port;
    counter->open = true;
    if (gptimer_new_timer(&config, &counter->timer) != ESP_OK ||
        gptimer_register_event_callbacks(counter->timer, &callbacks, counter) != ESP_OK)
        goto failed;
    if (gptimer_enable(counter->timer) != ESP_OK)
        goto failed;
    counter->enabled = true;
    return 0;

failed:
    ow_counter_close(port);
    return -1;
}

int ow_counter_arm(unsigned port, uint64_t ticks, bool periodic)
{
    if (port >= OW_COUNTERS || !ticks)
        return -1;
    ow_counter_t *counter = &counters[port];
    if (!counter->open)
        return -1;

    portENTER_CRITICAL(&counter->lock);
    counter->alarm = (gptimer_alarm_config_t) {
        .alarm_count = ticks,
        .reload_count = 0,
        .flags.auto_reload_on_alarm = periodic,
    };
    gptimer_set_raw_count(counter->timer, 0);
    esp_err_t result = gptimer_set_alarm_action(counter->timer, &counter->alarm);
    portEXIT_CRITICAL(&counter->lock);
    if (result != ESP_OK)
        return -1;
    if (!counter->started) {
        if (gptimer_start(counter->timer) != ESP_OK)
            return -1;
        counter->started = true;
    }
    return 0;
}

void IRAM_ATTR ow_counter_reload(unsigned port)
{
    if (port >= OW_COUNTERS)
        return;
    ow_counter_t *counter = &counters[port];
    portENTER_CRITICAL_SAFE(&counter->lock);
    if (counter->started) {
        gptimer_set_raw_count(counter->timer, 0);
        gptimer_set_alarm_action(counter->timer, &counter->alarm);
    }
    portEXIT_CRITICAL_SAFE(&counter->lock);
}

uint64_t ow_counter_read(unsigned port)
{
    uint64_t value = 0;
    if (port < OW_COUNTERS && counters[port].open)
        gptimer_get_raw_count(counters[port].timer, &value);
    return value;
}

void ow_counter_set_callback(unsigned port, bool (*callback)(unsigned port))
{
    if (port >= OW_COUNTERS)
        return;
    ow_counter_t *counter = &counters[port];
    portENTER_CRITICAL(&counter->lock);
    counter->callback = callback;
    portEXIT_CRITICAL(&counter->lock);
}

void ow_counter_close(unsigned port)
{
    if (port >= OW_COUNTERS)
        return;
    ow_counter_t *counter = &counters[port];
    if (counter->timer) {
        if (counter->started)
            gptimer_stop(counter->timer);
        if (counter->enabled)
            gptimer_disable(counter->timer);
        gptimer_del_timer(counter->timer);
    }
    portENTER_CRITICAL(&counter->lock);
    counter->callback = NULL;
    counter->timer = NULL;
    counter->alarm = (gptimer_alarm_config_t) { 0 };
    counter->started = false;
    counter->enabled = false;
    counter->open = false;
    portEXIT_CRITICAL(&counter->lock);
}

#else

int ow_counter_open(unsigned port, unsigned resolution_hz)
{
    (void)port;
    (void)resolution_hz;
    return -1;
}

int ow_counter_arm(unsigned port, uint64_t ticks, bool periodic)
{
    (void)port;
    (void)ticks;
    (void)periodic;
    return -1;
}

void ow_counter_reload(unsigned port)
{
    (void)port;
}

uint64_t ow_counter_read(unsigned port)
{
    (void)port;
    return 0;
}

void ow_counter_set_callback(unsigned port, bool (*callback)(unsigned port))
{
    (void)port;
    (void)callback;
}

void ow_counter_close(unsigned port)
{
    (void)port;
}

#endif

#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"

#if defined(CONFIG_IDF_TARGET_ESP32)

#include "soc/rtc_io_struct.h"
#include "soc/sens_reg.h"
#include "soc/sens_struct.h"

#define OW_GPIO_INTERRUPTS 2

typedef struct {
    unsigned input_gpio;
    bool open;
} ow_gpio_interrupt_t;

static portMUX_TYPE adc_locks[2] = {
    portMUX_INITIALIZER_UNLOCKED,
    portMUX_INITIALIZER_UNLOCKED,
};
static ow_gpio_interrupt_t gpio_interrupts[OW_GPIO_INTERRUPTS];
static volatile uintptr_t gpio_interrupt_callbacks[OW_GPIO_INTERRUPTS];
static unsigned gpio_isr_users;
static bool gpio_isr_service_owned;

static int gpio_isr_acquire(void)
{
    if (gpio_isr_users) {
        ++gpio_isr_users;
        return 0;
    }
    if (gpio_install_isr_service(ESP_INTR_FLAG_IRAM) != ESP_OK)
        return -1;
    gpio_isr_service_owned = true;
    gpio_isr_users = 1;
    return 0;
}

static void gpio_isr_release(void)
{
    if (!gpio_isr_users || --gpio_isr_users)
        return;
    if (gpio_isr_service_owned) {
        gpio_uninstall_isr_service();
        gpio_isr_service_owned = false;
    }
}

static adc_atten_t adc_attenuation(unsigned attenuation)
{
    switch (attenuation) {
    case 0: return ADC_ATTEN_DB_0;
    case 1: return ADC_ATTEN_DB_2_5;
    case 2: return ADC_ATTEN_DB_6;
    default: return ADC_ATTEN_DB_12;
    }
}

int ow_adc_open(unsigned unit, void **handle)
{
    if (!handle || unit > ADC_UNIT_2)
        return -1;

    adc_oneshot_unit_init_cfg_t config = {
        .unit_id = (adc_unit_t)unit,
    };
    if (adc_oneshot_new_unit(&config, (adc_oneshot_unit_handle_t *)handle) != ESP_OK)
        return -1;
    return 0;
}

int ow_adc_input_open(void *handle, unsigned unit, unsigned channel, unsigned attenuation, unsigned bit_width, unsigned default_reference_mv, void **calibration, int *calibration_source)
{
    if (!handle || !calibration || !calibration_source || unit > ADC_UNIT_2 || bit_width == 0)
        return -1;

    adc_atten_t atten = adc_attenuation(attenuation);
    adc_oneshot_chan_cfg_t input_config = {
        .atten = atten,
        .bitwidth = (adc_bitwidth_t)bit_width,
    };
    adc_cali_line_fitting_config_t calibration_config = {
        .unit_id = (adc_unit_t)unit,
        .atten = atten,
        .bitwidth = (adc_bitwidth_t)bit_width,
        .default_vref = default_reference_mv,
    };
    if (adc_oneshot_config_channel((adc_oneshot_unit_handle_t)handle, (adc_channel_t)channel, &input_config) != ESP_OK)
        return -1;
    if (adc_cali_create_scheme_line_fitting(&calibration_config, (adc_cali_handle_t *)calibration) != ESP_OK)
        return -1;
    adc_cali_line_fitting_efuse_val_t source;
    *calibration_source = adc_cali_scheme_line_fitting_check_efuse(&source) == ESP_OK ? (int)source : -1;
    return 0;
}

static uint16_t adc1_read_isr(unsigned channel);

int ow_adc_read(void *handle, unsigned unit, unsigned channel, unsigned *raw)
{
    int value;
    if (!handle || !raw || unit > ADC_UNIT_2)
        return -1;
    if (unit == ADC_UNIT_1) {
        portENTER_CRITICAL(&adc_locks[unit]);
        value = adc1_read_isr(channel);
        portEXIT_CRITICAL(&adc_locks[unit]);
    } else if (adc_oneshot_read((adc_oneshot_unit_handle_t)handle, (adc_channel_t)channel, &value) != ESP_OK) {
        return -1;
    }
    *raw = (unsigned)value;
    return 0;
}

int IRAM_ATTR ow_adc_read_critical(unsigned channel, unsigned *raw)
{
    portENTER_CRITICAL_SAFE(&adc_locks[0]);
    uint16_t value = adc1_read_isr(channel);
    portEXIT_CRITICAL_SAFE(&adc_locks[0]);
    *raw = value;
    return 0;
}

int ow_adc_raw_to_mv(void *calibration, unsigned raw, unsigned *millivolts)
{
    int value;
    if (!calibration || !millivolts || adc_cali_raw_to_voltage((adc_cali_handle_t)calibration, raw, &value) != ESP_OK)
        return -1;
    *millivolts = (unsigned)value;
    return 0;
}

void ow_adc_input_close(void *calibration)
{
    if (calibration)
        adc_cali_delete_scheme_line_fitting((adc_cali_handle_t)calibration);
}

void ow_adc_close(void *handle)
{
    if (handle)
        adc_oneshot_del_unit((adc_oneshot_unit_handle_t)handle);
}

static uint16_t IRAM_ATTR adc1_read_isr(unsigned channel)
{
    SENS.sar_read_ctrl.sar1_dig_force = 0;
    SENS.sar_meas_wait2.force_xpd_sar = SENS_FORCE_XPD_SAR_PU;
    RTCIO.hall_sens.xpd_hall = false;
    SENS.sar_meas_wait2.force_xpd_amp = SENS_FORCE_XPD_AMP_PD;
    SENS.sar_meas_ctrl.amp_rst_fb_fsm = 0;
    SENS.sar_meas_ctrl.amp_short_ref_fsm = 0;
    SENS.sar_meas_ctrl.amp_short_ref_gnd_fsm = 0;
    SENS.sar_meas_wait1.sar_amp_wait1 = 1;
    SENS.sar_meas_wait1.sar_amp_wait2 = 1;
    SENS.sar_meas_wait2.sar_amp_wait3 = 1;
    SENS.sar_meas_start1.meas1_start_force = 1;
    SENS.sar_meas_start1.sar1_en_pad_force = 1;
    SENS.sar_touch_ctrl1.xpd_hall_force = 1;
    SENS.sar_touch_ctrl1.hall_phase_force = 1;
    SENS.sar_meas_start1.sar1_en_pad = 1U << channel;
    while (SENS.sar_slave_addr1.meas_status != 0) {}
    SENS.sar_meas_start1.meas1_start_sar = 0;
    SENS.sar_meas_start1.meas1_start_sar = 1;
    while (SENS.sar_meas_start1.meas1_done_sar == 0) {}
    return SENS.sar_meas_start1.meas1_data_sar;
}

static void IRAM_ATTR gpio_interrupt_handler(void *context)
{
    unsigned port = (unsigned)(uintptr_t)context;
    bool (*callback)(unsigned) = (bool (*)(unsigned))gpio_interrupt_callbacks[port];
    if (callback && callback(port))
        portYIELD_FROM_ISR();
}

void ow_gpio_interrupt_close(unsigned port);

int ow_gpio_interrupt_open(unsigned port, unsigned input_gpio, unsigned trigger)
{
    if (port >= OW_GPIO_INTERRUPTS || input_gpio >= SOC_GPIO_PIN_COUNT || trigger > 4)
        return -1;

    ow_gpio_interrupt_t *interrupt = &gpio_interrupts[port];
    if (interrupt->open || gpio_isr_acquire() != 0)
        return -1;
    static const gpio_int_type_t types[] = {
        GPIO_INTR_POSEDGE,
        GPIO_INTR_NEGEDGE,
        GPIO_INTR_ANYEDGE,
        GPIO_INTR_HIGH_LEVEL,
        GPIO_INTR_LOW_LEVEL,
    };
    interrupt->input_gpio = input_gpio;
    // Input buffer explicitly: the pin may be muxed to a peripheral output (only the output path is
    // routed), and edge detection needs GPIO_IN regardless of who drives the pad.
    if (gpio_input_enable((gpio_num_t)input_gpio) != ESP_OK ||
        gpio_set_intr_type((gpio_num_t)input_gpio, types[trigger]) != ESP_OK ||
        gpio_isr_handler_add((gpio_num_t)input_gpio, gpio_interrupt_handler, (void *)(uintptr_t)port) != ESP_OK) {
        gpio_isr_release();
        return -1;
    }
    interrupt->open = true;
    return 0;
}

void ow_gpio_interrupt_set_callback(unsigned port, bool (*callback)(unsigned port))
{
    if (port >= OW_GPIO_INTERRUPTS)
        return;
    gpio_interrupt_callbacks[port] = (uintptr_t)callback;
}

void ow_gpio_interrupt_close(unsigned port)
{
    if (port >= OW_GPIO_INTERRUPTS)
        return;
    ow_gpio_interrupt_t *interrupt = &gpio_interrupts[port];
    if (!interrupt->open)
        return;
    gpio_isr_handler_remove((gpio_num_t)interrupt->input_gpio);
    ow_gpio_interrupt_set_callback(port, NULL);
    interrupt->open = false;
    gpio_isr_release();
}

// -- Link fabric gpio events (dispatcher lives in D: ow_link_fire) --

extern bool ow_link_fire(unsigned slot);

static void IRAM_ATTR link_gpio_handler(void *context)
{
    if (ow_link_fire((unsigned)(uintptr_t)context))
        portYIELD_FROM_ISR();
}

int ow_link_gpio_open(unsigned slot, unsigned gpio, unsigned trigger)
{
    static const gpio_int_type_t types[] = {
        GPIO_INTR_POSEDGE,
        GPIO_INTR_NEGEDGE,
        GPIO_INTR_ANYEDGE,
    };
    if (gpio >= SOC_GPIO_PIN_COUNT || trigger > 2)
        return -1;
    if (gpio_isr_acquire() != 0)
        return -1;
    // Input buffer explicitly: the pin may be muxed to a peripheral output (only the output path is
    // routed), and edge detection needs GPIO_IN regardless of who drives the pad.
    if (gpio_input_enable((gpio_num_t)gpio) != ESP_OK ||
        gpio_set_intr_type((gpio_num_t)gpio, types[trigger]) != ESP_OK ||
        gpio_isr_handler_add((gpio_num_t)gpio, link_gpio_handler, (void *)(uintptr_t)slot) != ESP_OK) {
        gpio_isr_release();
        return -1;
    }
    return 0;
}

void ow_link_gpio_close(unsigned slot, unsigned gpio)
{
    (void)slot;
    if (gpio >= SOC_GPIO_PIN_COUNT)
        return;
    gpio_isr_handler_remove((gpio_num_t)gpio);
    gpio_isr_release();
}

// -- Reflex NMI routing (the handler itself is synthesized in D: xt_nmi) --

static intr_handle_t reflex_nmi_handle;
static unsigned reflex_users;

int ow_reflex_open(unsigned gpio, unsigned trigger)
{
    static const gpio_int_type_t types[] = {
        GPIO_INTR_POSEDGE,
        GPIO_INTR_NEGEDGE,
        GPIO_INTR_ANYEDGE,
    };
    if (gpio >= 32 || trigger > 2)
        return -1;
    if (!reflex_users) {
        // Route the GPIO NMI matrix source to CPU interrupt 14 (level 7). High-level
        // allocation requires a NULL handler; the vector dispatches to xt_nmi directly.
        if (esp_intr_alloc(ETS_GPIO_NMI_SOURCE, ESP_INTR_FLAG_NMI, NULL, NULL, &reflex_nmi_handle) != ESP_OK)
            return -1;
    }
    if (gpio_input_enable((gpio_num_t)gpio) != ESP_OK ||
        gpio_set_intr_type((gpio_num_t)gpio, types[trigger]) != ESP_OK) {
        if (!reflex_users) {
            esp_intr_free(reflex_nmi_handle);
            reflex_nmi_handle = NULL;
        }
        return -1;
    }
    ++reflex_users;
    // Per-pin register and the pin is claimed exclusively, so the RMW races nothing.
    GPIO.pin[gpio].int_ena |= BIT(3);   /* PRO CPU NMI */
    return 0;
}

void ow_reflex_close(unsigned gpio)
{
    if (gpio >= 32 || !reflex_users)
        return;
    GPIO.pin[gpio].int_ena &= ~BIT(3);
    gpio_set_intr_type((gpio_num_t)gpio, GPIO_INTR_DISABLE);
    if (--reflex_users == 0 && reflex_nmi_handle) {
        esp_intr_free(reflex_nmi_handle);
        reflex_nmi_handle = NULL;
    }
}

#else

int ow_adc_open(unsigned unit, void **handle)
{
    (void)unit;
    (void)handle;
    return -1;
}

int ow_adc_input_open(void *handle, unsigned unit, unsigned channel, unsigned attenuation, unsigned bit_width, unsigned default_reference_mv, void **calibration, int *calibration_source)
{
    (void)handle;
    (void)unit;
    (void)channel;
    (void)attenuation;
    (void)bit_width;
    (void)default_reference_mv;
    (void)calibration;
    (void)calibration_source;
    return -1;
}

int ow_adc_read(void *handle, unsigned unit, unsigned channel, unsigned *raw)
{
    (void)handle;
    (void)unit;
    (void)channel;
    (void)raw;
    return -1;
}

int ow_adc_read_critical(unsigned channel, unsigned *raw)
{
    (void)channel;
    (void)raw;
    return -1;
}

int ow_adc_raw_to_mv(void *calibration, unsigned raw, unsigned *millivolts)
{
    (void)calibration;
    (void)raw;
    (void)millivolts;
    return -1;
}

void ow_adc_input_close(void *calibration)
{
    (void)calibration;
}

void ow_adc_close(void *handle)
{
    (void)handle;
}

int ow_gpio_interrupt_open(unsigned port, unsigned input_gpio, unsigned trigger)
{
    (void)port;
    (void)input_gpio;
    (void)trigger;
    return -1;
}

void ow_gpio_interrupt_set_callback(unsigned port, bool (*callback)(unsigned port))
{
    (void)port;
    (void)callback;
}

void ow_gpio_interrupt_close(unsigned port)
{
    (void)port;
}

int ow_link_gpio_open(unsigned slot, unsigned gpio, unsigned trigger)
{
    (void)slot;
    (void)gpio;
    (void)trigger;
    return -1;
}

void ow_link_gpio_close(unsigned slot, unsigned gpio)
{
    (void)slot;
    (void)gpio;
}

int ow_reflex_open(unsigned gpio, unsigned trigger)
{
    (void)gpio;
    (void)trigger;
    return -1;
}

void ow_reflex_close(unsigned gpio)
{
    (void)gpio;
}

#endif

// -- I2C master wrappers --

#include "driver/i2c_master.h"

#ifdef SOC_HP_I2C_NUM
#define OW_I2C_COUNT SOC_HP_I2C_NUM
#else
#define OW_I2C_COUNT SOC_I2C_NUM
#endif
#define I2C_REQUEST_QUEUE_SIZE 1
#define I2C_WORKER_STACK 3072

typedef bool (*ow_i2c_callback_t)(void *context, int result);

typedef struct {
    uint16_t address;
    uint32_t frequency;
    uint8_t address_mode;
    const void *write_data;
    size_t write_length;
    void *read_data;
    size_t read_length;
    int timeout_ms;
    ow_i2c_callback_t callback;
    void *callback_context;
} ow_i2c_request_t;

typedef struct {
    i2c_master_bus_handle_t bus;
    i2c_master_dev_handle_t device;
    uint16_t address;
    uint32_t frequency;
    uint8_t address_mode;
    QueueHandle_t queue;
    TaskHandle_t worker;
    SemaphoreHandle_t worker_done;
    StaticSemaphore_t worker_done_storage;
    atomic_bool initialized;
} ow_i2c_context_t;

static ow_i2c_context_t i2c_contexts[OW_I2C_COUNT];

static bool ow_i2c_configure_device(ow_i2c_context_t *context, uint16_t address, uint8_t address_mode, uint32_t frequency)
{
    if (context->device && context->address == address && context->address_mode == address_mode && context->frequency == frequency)
        return true;

    if (context->device) {
        if (i2c_master_bus_rm_device(context->device) != ESP_OK)
            return false;
        context->device = NULL;
    }

    i2c_device_config_t device_config = {
        .dev_addr_length = address_mode ? I2C_ADDR_BIT_LEN_10 : I2C_ADDR_BIT_LEN_7,
        .device_address = address,
        .scl_speed_hz = frequency,
    };
    if (i2c_master_bus_add_device(context->bus, &device_config, &context->device) != ESP_OK)
        return false;

    context->address = address;
    context->address_mode = address_mode;
    context->frequency = frequency;
    return true;
}

static int ow_i2c_result(esp_err_t result)
{
    if (result == ESP_OK)
        return 0;
    // ESP-IDF 6.0 i2c_master_transmit(), i2c_master_receive(), and i2c_master_transmit_receive() return this result when a transaction receives NACK.
    if (result == ESP_ERR_INVALID_RESPONSE)
        return 1;
    if (result == ESP_ERR_TIMEOUT)
        return 2;
    return 4;
}

static void ow_i2c_worker(void *argument)
{
    ow_i2c_context_t *context = argument;
    ow_i2c_request_t request;

    while (xQueueReceive(context->queue, &request, portMAX_DELAY) == pdTRUE) {
        if (!request.callback)
            break;

        esp_err_t result = ESP_FAIL;
        if (ow_i2c_configure_device(context, request.address, request.address_mode, request.frequency)) {
            if (request.write_length && request.read_length)
                result = i2c_master_transmit_receive(context->device, request.write_data, request.write_length, request.read_data, request.read_length, request.timeout_ms);
            else if (request.write_length)
                result = i2c_master_transmit(context->device, request.write_data, request.write_length, request.timeout_ms);
            else
                result = i2c_master_receive(context->device, request.read_data, request.read_length, request.timeout_ms);
        }
        request.callback(request.callback_context, ow_i2c_result(result));
    }

    xSemaphoreGive(context->worker_done);
    vTaskDelete(NULL);
}

uint32_t ow_i2c_count(void)
{
    return OW_I2C_COUNT;
}

void *ow_i2c_open(unsigned port, int sda_gpio, int scl_gpio, bool internal_pullups)
{
    if (port >= OW_I2C_COUNT)
        return NULL;

    ow_i2c_context_t *context = &i2c_contexts[port];
    if (atomic_exchange_explicit(&context->initialized, true, memory_order_acq_rel))
        return NULL;

    i2c_master_bus_config_t bus_config = {
        .i2c_port = port,
        .sda_io_num = sda_gpio,
        .scl_io_num = scl_gpio,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = internal_pullups,
    };
    if (i2c_new_master_bus(&bus_config, &context->bus) != ESP_OK)
        goto fail;

    context->queue = xQueueCreate(I2C_REQUEST_QUEUE_SIZE, sizeof(ow_i2c_request_t));
    if (!context->queue)
        goto fail;

    if (!context->worker_done)
        context->worker_done = xSemaphoreCreateBinaryStatic(&context->worker_done_storage);
    if (!context->worker_done)
        goto fail;
    xSemaphoreTake(context->worker_done, 0);

    if (xTaskCreate(ow_i2c_worker, "ow-i2c", I2C_WORKER_STACK, context, tskIDLE_PRIORITY + 2, &context->worker) != pdPASS)
        goto fail;
    return context;

fail:
    if (context->queue) {
        vQueueDelete(context->queue);
        context->queue = NULL;
    }
    if (context->bus) {
        i2c_del_master_bus(context->bus);
        context->bus = NULL;
    }
    atomic_store_explicit(&context->initialized, false, memory_order_release);
    return NULL;
}

void ow_i2c_close(void *context_ptr)
{
    ow_i2c_context_t *context = context_ptr;
    if (!context || !atomic_exchange_explicit(&context->initialized, false, memory_order_acq_rel))
        return;

    configASSERT(xTaskGetCurrentTaskHandle() != context->worker);
    ow_i2c_request_t request = {0};
    xQueueSend(context->queue, &request, portMAX_DELAY);
    xSemaphoreTake(context->worker_done, portMAX_DELAY);
    context->worker = NULL;

    if (context->device) {
        i2c_master_bus_rm_device(context->device);
        context->device = NULL;
    }
    if (context->bus) {
        i2c_del_master_bus(context->bus);
        context->bus = NULL;
    }
    vQueueDelete(context->queue);
    context->queue = NULL;
}

int ow_i2c_submit(void *context_ptr, uint16_t address, uint8_t address_mode, uint32_t frequency, const void *write_data, size_t write_length, void *read_data, size_t read_length, int timeout_ms, ow_i2c_callback_t callback, void *callback_context)
{
    ow_i2c_context_t *context = context_ptr;
    if (!context || !atomic_load_explicit(&context->initialized, memory_order_acquire) || !callback || (write_length == 0 && read_length == 0))
        return -1;

    ow_i2c_request_t request = {
        .address = address,
        .frequency = frequency,
        .address_mode = address_mode,
        .write_data = write_data,
        .write_length = write_length,
        .read_data = read_data,
        .read_length = read_length,
        .timeout_ms = timeout_ms,
        .callback = callback,
        .callback_context = callback_context,
    };
    return xQueueSend(context->queue, &request, 0) == pdTRUE ? 0 : -1;
}


// -- SPI master wrappers --

#include "driver/spi_master.h"
#include "esp_rom_gpio.h"
#include "soc/gpio_sig_map.h"
#include "soc/spi_periph.h"

// SPI1 is the flash controller; only the general-purpose hosts are exposed.
#define OW_SPI_COUNT (SOC_SPI_PERIPH_NUM - 1)

typedef bool (*ow_spi_callback_t)(void *context, int result);

typedef struct {
    spi_device_handle_t device;
    spi_host_device_t host;
    int mosi_gpio;
    spi_transaction_t transaction;
    ow_spi_callback_t callback;
    void *callback_context;
    void *read_data;
    size_t read_length;
    atomic_bool initialized;
} ow_spi_context_t;

static ow_spi_context_t spi_contexts[OW_SPI_COUNT];

// Runs in the SPI completion interrupt: SPI_DEVICE_NO_RETURN_RESULT means the descriptor is never posted back to a task.
static void IRAM_ATTR ow_spi_post(spi_transaction_t *transaction)
{
    ow_spi_context_t *context = transaction->user;
    if (!context)
        return;                 // priming transfer at open: no caller to notify

    // Only the descriptor-resident small-transfer path needs a copy out; DMA wrote straight into the caller's buffer.
    uint8_t *destination = context->read_data;
    for (size_t i = 0; i < context->read_length; ++i)
        destination[i] = transaction->rx_data[i];

    if (context->callback(context->callback_context, 0))
        portYIELD_FROM_ISR();
}

uint32_t ow_spi_count(void)
{
    return OW_SPI_COUNT;
}

void *ow_spi_open(unsigned port, int sck_gpio, int mosi_gpio, int miso_gpio, int cs_gpio, uint32_t frequency, uint8_t mode)
{
    if (port >= OW_SPI_COUNT)
        return NULL;

    ow_spi_context_t *context = &spi_contexts[port];
    if (atomic_exchange_explicit(&context->initialized, true, memory_order_acq_rel))
        return NULL;

    context->host = SPI2_HOST + port;
    context->mosi_gpio = mosi_gpio;
    spi_bus_config_t bus_config = {
        .sclk_io_num = sck_gpio,
        .mosi_io_num = mosi_gpio,
        .miso_io_num = miso_gpio,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4096,
    };
    bool bus_initialized = false;
    if (spi_bus_initialize(context->host, &bus_config, SPI_DMA_CH_AUTO) != ESP_OK)
        goto fail;
    bus_initialized = true;

    spi_device_interface_config_t device_config = {
        .clock_speed_hz = (int)frequency,
        .mode = mode,
        .spics_io_num = cs_gpio,
        .queue_size = 1,
        .flags = SPI_DEVICE_NO_RETURN_RESULT,
        .post_cb = ow_spi_post,
    };
    if (spi_bus_add_device(context->host, &device_config, &context->device) != ESP_OK)
        goto fail;

    // SCLK only settles at the mode's idle level once a transaction has run. A device with no
    // chip-select has no frame delimiter, so it counts the first edge after open as data and
    // every subsequent byte lands shifted. Prime the line before any caller can transmit.
    spi_transaction_t priming = {
        .length = 8,
        .flags = SPI_TRANS_USE_TXDATA,
    };
    spi_device_polling_transmit(context->device, &priming);
    return context;

fail:
    if (bus_initialized)
        spi_bus_free(context->host);
    atomic_store_explicit(&context->initialized, false, memory_order_release);
    return NULL;
}

void ow_spi_close(void *context_ptr)
{
    ow_spi_context_t *context = context_ptr;
    if (!context || !atomic_exchange_explicit(&context->initialized, false, memory_order_acq_rel))
        return;

    spi_bus_remove_device(context->device);
    context->device = NULL;
    spi_bus_free(context->host);
}

int ow_spi_submit(void *context_ptr, const void *write_data, size_t write_length, void *read_data, size_t read_length, ow_spi_callback_t callback, void *callback_context)
{
    ow_spi_context_t *context = context_ptr;
    if (!context || !atomic_load_explicit(&context->initialized, memory_order_acquire) || !callback || (write_length == 0 && read_length == 0))
        return -1;
    // spi_device_queue_trans takes a FreeRTOS queue with task-context semantics, so a completion callback cannot resubmit directly.
    if (xPortInIsrContext())
        return -1;

    size_t length = write_length > read_length ? write_length : read_length;
    spi_transaction_t *transaction = &context->transaction;
    memset(transaction, 0, sizeof(*transaction));
    transaction->length = length * 8;
    transaction->user = context;

    context->callback = callback;
    context->callback_context = callback_context;
    context->read_data = read_data;
    context->read_length = 0;

    if (length <= 4)
    {
        // Small transfers ride inside the descriptor, so command bytes may live in flash rather than DMA-capable RAM.
        if (write_length)
        {
            transaction->flags |= SPI_TRANS_USE_TXDATA;
            memcpy(transaction->tx_data, write_data, write_length);
        }
        if (read_length)
        {
            transaction->flags |= SPI_TRANS_USE_RXDATA;
            context->read_length = read_length;
        }
    }
    else
    {
        transaction->tx_buffer = write_length ? write_data : NULL;
        transaction->rx_buffer = read_length ? read_data : NULL;
        if (read_length)
            transaction->rxlength = read_length * 8;
    }

    return spi_device_queue_trans(context->device, transaction, 0) == ESP_OK ? 0 : -1;
}

int ow_spi_suspend(void *context_ptr)
{
    ow_spi_context_t *context = context_ptr;
    if (!context || !atomic_load_explicit(&context->initialized, memory_order_acquire) || context->mosi_gpio < 0)
        return -1;
    // Hand MOSI's output stage back to the GPIO output register; the caller may now re-init and sample the pin.
    esp_rom_gpio_connect_out_signal(context->mosi_gpio, SIG_GPIO_OUT_IDX, false, false);
    return 0;
}

int ow_spi_resume(void *context_ptr)
{
    ow_spi_context_t *context = context_ptr;
    if (!context || !atomic_load_explicit(&context->initialized, memory_order_acquire) || context->mosi_gpio < 0)
        return -1;
    gpio_set_direction((gpio_num_t)context->mosi_gpio, GPIO_MODE_OUTPUT);
    esp_rom_gpio_connect_out_signal(context->mosi_gpio, spi_periph_signal[context->host].spid_out, false, false);
    return 0;
}


// -- UART driver wrappers --

#define NUM_UARTS SOC_UART_NUM
#define UART_RX_BUFFER_SIZE 1024
#define UART_TX_BUFFER_SIZE 1024
#define UART_EVENT_QUEUE_SIZE 16
#define UART_EVENT_TASK_STACK 3072

typedef void (*ow_uart_rx_ready_cb_t)(unsigned port, size_t available);

static atomic_bool uart_initialized[NUM_UARTS];
static QueueHandle_t uart_event_queue[NUM_UARTS];
static TaskHandle_t uart_event_task[NUM_UARTS];
static SemaphoreHandle_t uart_event_task_done[NUM_UARTS];
static StaticSemaphore_t uart_event_task_done_storage[NUM_UARTS];
static atomic_uint uart_errors[NUM_UARTS];
static _Atomic(ow_uart_rx_ready_cb_t) uart_rx_ready[NUM_UARTS];

// D enums: StopBits { half=0, one=1, one_point_five=2, two=3 }
//          Parity   { none=0, even=1, odd=2, mark=3, space=4 }
static const uart_stop_bits_t stop_bits_map[] = {
    UART_STOP_BITS_1, UART_STOP_BITS_1, UART_STOP_BITS_1_5, UART_STOP_BITS_2
};
static const uart_parity_t parity_map[] = {
    UART_PARITY_DISABLE, UART_PARITY_EVEN, UART_PARITY_ODD,
    UART_PARITY_DISABLE, UART_PARITY_DISABLE
};

static void ow_uart_event_task(void *argument)
{
    unsigned port = (unsigned)(uintptr_t)argument;
    uart_event_t event;

    while (xQueueReceive(uart_event_queue[port], &event, portMAX_DELAY) == pdTRUE)
    {
        if (event.type == UART_EVENT_MAX)
            break;

        unsigned error = 0;
        switch (event.type)
        {
            case UART_DATA:
            {
                size_t available = event.size;
                uart_get_buffered_data_len((uart_port_t)port, &available);
                ow_uart_rx_ready_cb_t callback = atomic_load_explicit(
                    &uart_rx_ready[port], memory_order_acquire);
                if (callback)
                    callback(port, available);
                continue;
            }
            case UART_BREAK:
                error = 1u << 4;
                break;
            case UART_BUFFER_FULL:
            case UART_FIFO_OVF:
                error = 1u << 2;
                uart_flush_input((uart_port_t)port);
                break;
            case UART_FRAME_ERR:
                error = 1u << 0;
                break;
            case UART_PARITY_ERR:
                error = 1u << 1;
                break;
            default:
                continue;
        }

        atomic_fetch_or_explicit(&uart_errors[port], error, memory_order_relaxed);
        ow_uart_rx_ready_cb_t callback = atomic_load_explicit(&uart_rx_ready[port], memory_order_acquire);
        if (callback)
            callback(port, 0);
    }

    xSemaphoreGive(uart_event_task_done[port]);
    vTaskDelete(NULL);
}

int ow_uart_open(unsigned port, uint32_t baud_rate, uint8_t data_bits,
                 uint8_t stop_bits, uint8_t parity,
                 int8_t tx_gpio, int8_t rx_gpio,
                 bool rs485_enabled, int8_t de_gpio, bool de_active_high,
                 ow_uart_rx_ready_cb_t rx_ready)
{
    if (port >= NUM_UARTS || atomic_load_explicit(&uart_initialized[port], memory_order_acquire) || data_bits < 5 || data_bits > 8)
        return 0;

    uart_config_t config = {0};
    config.baud_rate = (int)baud_rate;
    config.data_bits = (uart_word_length_t)(UART_DATA_5_BITS + data_bits - 5);
    config.parity = parity < sizeof(parity_map) / sizeof(parity_map[0]) ? parity_map[parity] : UART_PARITY_DISABLE;
    config.stop_bits = stop_bits < sizeof(stop_bits_map) / sizeof(stop_bits_map[0]) ? stop_bits_map[stop_bits] : UART_STOP_BITS_1;
    config.flow_ctrl = UART_HW_FLOWCTRL_DISABLE;
    config.source_clk = UART_SCLK_DEFAULT;

    uart_port_t uart = (uart_port_t)port;
    if (uart_param_config(uart, &config) != ESP_OK ||
        uart_set_pin(uart, tx_gpio, rx_gpio, de_gpio, UART_PIN_NO_CHANGE) != ESP_OK ||
        uart_driver_install(uart, UART_RX_BUFFER_SIZE, UART_TX_BUFFER_SIZE, UART_EVENT_QUEUE_SIZE, &uart_event_queue[port], 0) != ESP_OK)
    {
        uart_event_queue[port] = NULL;
        return 0;
    }

    uint32_t inverse = rs485_enabled && !de_active_high ? UART_SIGNAL_RTS_INV : 0;
    if (uart_set_line_inverse(uart, inverse) != ESP_OK)
    {
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }
    if (rs485_enabled && uart_set_mode(uart, UART_MODE_RS485_HALF_DUPLEX) != ESP_OK)
    {
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }

    if (!uart_event_task_done[port])
        uart_event_task_done[port] = xSemaphoreCreateBinaryStatic(&uart_event_task_done_storage[port]);
    if (!uart_event_task_done[port])
    {
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }
    xSemaphoreTake(uart_event_task_done[port], 0);

    atomic_store_explicit(&uart_errors[port], 0, memory_order_relaxed);
    atomic_store_explicit(&uart_rx_ready[port], rx_ready, memory_order_release);
    atomic_store_explicit(&uart_initialized[port], true, memory_order_release);
    if (xTaskCreate(ow_uart_event_task, "ow-uart", UART_EVENT_TASK_STACK, (void *)(uintptr_t)port, tskIDLE_PRIORITY + 2, &uart_event_task[port]) != pdPASS)
    {
        atomic_store_explicit(&uart_initialized[port], false, memory_order_release);
        atomic_store_explicit(&uart_rx_ready[port], NULL, memory_order_release);
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }
    return 1;
}

void ow_uart_close(unsigned port)
{
    if (port >= NUM_UARTS || !atomic_exchange_explicit(&uart_initialized[port], false, memory_order_acq_rel))
        return;
    atomic_store_explicit(&uart_rx_ready[port], NULL, memory_order_release);
    if (uart_event_task[port])
    {
        configASSERT(xTaskGetCurrentTaskHandle() != uart_event_task[port]);
        uart_event_t shutdown = { .type = UART_EVENT_MAX };
        xQueueSendToFront(uart_event_queue[port], &shutdown, portMAX_DELAY);
        xSemaphoreTake(uart_event_task_done[port], portMAX_DELAY);
        uart_event_task[port] = NULL;
    }
    uart_driver_delete((uart_port_t)port);
    uart_event_queue[port] = NULL;
}

int32_t ow_uart_read(unsigned port, uint8_t *buf, int32_t len)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire) || !buf || len <= 0)
        return 0;
    return uart_read_bytes((uart_port_t)port, buf, (uint32_t)len, 0);
}

int32_t ow_uart_write(unsigned port, const uint8_t *buf, int32_t len)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire) || !buf || len <= 0)
        return 0;
    size_t available = 0;
    if (uart_get_tx_buffer_free_size((uart_port_t)port, &available) != ESP_OK)
        return -1;
    if ((size_t)len > available)
        len = (int32_t)available;
    return len > 0 ? uart_write_bytes((uart_port_t)port, buf, (size_t)len) : 0;
}

void ow_uart_poll(unsigned port)
{
    (void)port;
}

int32_t ow_uart_rx_pending(unsigned port)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    size_t available = 0;
    return uart_get_buffered_data_len((uart_port_t)port, &available) == ESP_OK ? (int32_t)available : 0;
}

// IDF only exposes the ring; the byte in flight and the hardware FIFO tail are
// not counted, ow_uart_tx_idle covers those.
int32_t ow_uart_tx_pending(unsigned port)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    size_t available = 0;
    if (uart_get_tx_buffer_free_size((uart_port_t)port, &available) != ESP_OK)
        return 0;
    return (int32_t)(UART_TX_BUFFER_SIZE - available);
}

int ow_uart_tx_idle(unsigned port)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 1;
    return uart_wait_tx_done((uart_port_t)port, 0) == ESP_OK;
}

int32_t ow_uart_flush(unsigned port)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    return uart_wait_tx_done((uart_port_t)port, portMAX_DELAY) == ESP_OK ? 0 : -1;
}

int ow_uart_check_errors(unsigned port)
{
    if (port >= NUM_UARTS || !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    return (int)atomic_exchange_explicit(&uart_errors[port], 0, memory_order_relaxed);
}

// -- WiFi wrappers --

#if CONFIG_ESP_WIFI_ENABLED
#include "esp_wifi.h"
#include "esp_private/wifi.h"
#include "esp_event.h"
#include "esp_mac.h"

static int ow_wifi_refcount;

#ifdef OW_USE_LWIP
#include "esp_netif.h"

static esp_netif_t *ow_wifi_netif_sta;
static esp_netif_t *ow_wifi_netif_ap;
#endif

typedef void (*ow_wifi_event_cb_t)(int event_id, void *data, int data_len);

static ow_wifi_event_cb_t ow_wifi_sta_cb;
static ow_wifi_event_cb_t ow_wifi_ap_cb;

static void ow_wifi_event_handler(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    if (base == WIFI_EVENT)
    {
        int data_len = 0;
        if (event_id == WIFI_EVENT_STA_DISCONNECTED && event_data)
            data_len = ((wifi_event_sta_disconnected_t *)event_data)->reason;

        switch (event_id)
        {
        case WIFI_EVENT_STA_CONNECTED:
        case WIFI_EVENT_STA_DISCONNECTED:
        case WIFI_EVENT_STA_START:
        case WIFI_EVENT_STA_STOP:
            if (ow_wifi_sta_cb)
                ow_wifi_sta_cb(event_id, event_data, data_len);
            break;

        case WIFI_EVENT_AP_START:
        case WIFI_EVENT_AP_STOP:
        case WIFI_EVENT_AP_STACONNECTED:
        case WIFI_EVENT_AP_STADISCONNECTED:
            if (ow_wifi_ap_cb)
                ow_wifi_ap_cb(event_id, event_data, 0);
            break;
        }
    }
#ifdef OW_USE_LWIP
    else if (base == IP_EVENT)
    {
        if (event_id == IP_EVENT_STA_GOT_IP && ow_wifi_sta_cb)
            ow_wifi_sta_cb(event_id, event_data, 0);
    }
#endif
}

int ow_wifi_init(void)
{
    if (ow_wifi_refcount++ > 0)
        return 0;

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_err_t err = esp_wifi_init(&cfg);
    if (err != ESP_OK)
    {
        ow_wifi_refcount--;
        return (int)err;
    }

    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &ow_wifi_event_handler, NULL);

#ifdef OW_USE_LWIP
    // Create netifs before RX callbacks fire, so esp_netif_receive() has valid targets.
    if (!ow_wifi_netif_sta)
        ow_wifi_netif_sta = esp_netif_create_default_wifi_sta();
    if (!ow_wifi_netif_ap)
        ow_wifi_netif_ap = esp_netif_create_default_wifi_ap();
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &ow_wifi_event_handler, NULL);
#endif

    return 0;
}

void ow_wifi_deinit(void)
{
    if (--ow_wifi_refcount > 0)
        return;

    esp_wifi_stop();
    esp_wifi_deinit();

#ifdef OW_USE_LWIP
    if (ow_wifi_netif_sta)
    {
        esp_netif_destroy(ow_wifi_netif_sta);
        ow_wifi_netif_sta = NULL;
    }
    if (ow_wifi_netif_ap)
    {
        esp_netif_destroy(ow_wifi_netif_ap);
        ow_wifi_netif_ap = NULL;
    }
#endif
}

int ow_wifi_sta_config(const char *ssid, const char *password, const uint8_t *bssid)
{
    wifi_config_t cfg = {0};
    if (ssid)
    {
        size_t len = strlen(ssid);
        if (len > sizeof(cfg.sta.ssid) - 1) len = sizeof(cfg.sta.ssid) - 1;
        memcpy(cfg.sta.ssid, ssid, len);
    }
    if (password)
    {
        size_t len = strlen(password);
        if (len > sizeof(cfg.sta.password) - 1) len = sizeof(cfg.sta.password) - 1;
        memcpy(cfg.sta.password, password, len);
    }
    if (bssid)
    {
        memcpy(cfg.sta.bssid, bssid, 6);
        cfg.sta.bssid_set = true;
    }

    return esp_wifi_set_config(WIFI_IF_STA, &cfg) == ESP_OK ? 1 : 0;
}

int ow_wifi_ap_config(const char *ssid, const char *password, uint8_t channel, uint8_t max_conn, uint8_t hidden)
{
    wifi_config_t cfg = {0};
    if (ssid)
    {
        size_t len = strlen(ssid);
        if (len > sizeof(cfg.ap.ssid) - 1) len = sizeof(cfg.ap.ssid) - 1;
        memcpy(cfg.ap.ssid, ssid, len);
        cfg.ap.ssid_len = (uint8_t)len;
    }
    if (password)
    {
        size_t len = strlen(password);
        if (len > sizeof(cfg.ap.password) - 1) len = sizeof(cfg.ap.password) - 1;
        memcpy(cfg.ap.password, password, len);
        cfg.ap.authmode = (len > 0) ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    }
    else
        cfg.ap.authmode = WIFI_AUTH_OPEN;

    cfg.ap.channel = channel;
    cfg.ap.max_connection = max_conn > 0 ? max_conn : 4;
    cfg.ap.ssid_hidden = hidden;

    return esp_wifi_set_config(WIFI_IF_AP, &cfg) == ESP_OK ? 1 : 0;
}

int ow_wifi_ap_set_max_clients(uint8_t max_conn)
{
    wifi_config_t cfg = {0};

    if (esp_wifi_get_config(WIFI_IF_AP, &cfg) != ESP_OK)
        return 0;

    cfg.ap.max_connection = max_conn > 0 ? max_conn : 4;
    return esp_wifi_set_config(WIFI_IF_AP, &cfg) == ESP_OK ? 1 : 0;
}

int ow_wifi_sta_get_ap_info(uint8_t *bssid, int *rssi)
{
    wifi_ap_record_t record;
    if (esp_wifi_sta_get_ap_info(&record) != ESP_OK)
        return 0;

    if (bssid)
        memcpy(bssid, record.bssid, sizeof(record.bssid));
    if (rssi)
        *rssi = record.rssi;
    return 1;
}

// Ethernet frame RX callbacks -- one per netif (STA=0, AP=1).
// esp_wifi_internal_reg_rxcb gives us raw Ethernet frames before lwIP,
// so the bridge/routing layer sees all traffic.

// Return non-zero when the callback retains eb and assumes responsibility for
// releasing it with ow_wifi_free_rx_buffer().
typedef int (*ow_wifi_rx_cb_t)(const uint8_t *data, int len, int iface, void *eb);

static ow_wifi_rx_cb_t ow_wifi_rx_callback;

static esp_err_t ow_wifi_sta_rx(void *buffer, uint16_t len, void *eb)
{
    int retained = 0;
    if (ow_wifi_rx_callback)
        retained = ow_wifi_rx_callback((const uint8_t *)buffer, len, 0, eb);
#ifdef OW_USE_LWIP
    (void)retained;
    return esp_netif_receive(ow_wifi_netif_sta, buffer, len, eb);
#else
    if (eb && !retained)
        esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
#endif
}

static esp_err_t ow_wifi_ap_rx(void *buffer, uint16_t len, void *eb)
{
    int retained = 0;
    if (ow_wifi_rx_callback)
        retained = ow_wifi_rx_callback((const uint8_t *)buffer, len, 1, eb);
#ifdef OW_USE_LWIP
    (void)retained;
    return esp_netif_receive(ow_wifi_netif_ap, buffer, len, eb);
#else
    if (eb && !retained)
        esp_wifi_internal_free_rx_buffer(eb);
    return ESP_OK;
#endif
}

void ow_wifi_free_rx_buffer(void *eb)
{
    if (eb)
        esp_wifi_internal_free_rx_buffer(eb);
}

int ow_wifi_set_rx_callback(ow_wifi_rx_cb_t cb)
{
    ow_wifi_rx_callback = cb;
    esp_err_t err;
    err = esp_wifi_internal_reg_rxcb(WIFI_IF_STA, cb ? &ow_wifi_sta_rx : NULL);
    if (err != ESP_OK)
        return 0;
    err = esp_wifi_internal_reg_rxcb(WIFI_IF_AP, cb ? &ow_wifi_ap_rx : NULL);
    return err == ESP_OK ? 1 : 0;
}

void ow_wifi_set_sta_callback(ow_wifi_event_cb_t cb)
{
    ow_wifi_sta_cb = cb;
}

void ow_wifi_set_ap_callback(ow_wifi_event_cb_t cb)
{
    ow_wifi_ap_cb = cb;
}

// Promiscuous (monitor) mode wrappers. ESP-IDF's promiscuous mode coexists
// with STA/AP -- the radio's channel is what they all share. The callback
// fires for every 802.11 frame the radio decodes, including frames with
// FCS errors when the FCSFAIL filter bit is set.

typedef void (*ow_wifi_promisc_cb_t)(int type, int rssi, int channel, int rate, int fcs_fail, int len, const uint8_t *payload);

static ow_wifi_promisc_cb_t ow_wifi_promisc_callback;

static void ow_wifi_promisc_trampoline(void *buf, wifi_promiscuous_pkt_type_t type)
{
    // ESP-IDF reports WIFI_PKT_MISC with metadata but no payload.
    if (!ow_wifi_promisc_callback || !buf || type == WIFI_PKT_MISC)
        return;
    const wifi_promiscuous_pkt_t *pkt = (const wifi_promiscuous_pkt_t *)buf;
    const wifi_pkt_rx_ctrl_t *rx = &pkt->rx_ctrl;
    ow_wifi_promisc_callback((int)type, (int)rx->rssi, (int)rx->channel, (int)rx->rate, (int)rx->rx_state, (int)rx->sig_len, pkt->payload);
}

void ow_wifi_set_promiscuous_callback(ow_wifi_promisc_cb_t cb)
{
    ow_wifi_promisc_callback = cb;
    esp_wifi_set_promiscuous_rx_cb(cb ? &ow_wifi_promisc_trampoline : NULL);
}

int ow_wifi_set_promiscuous(int enable, uint32_t filter_mask)
{
    if (enable)
    {
        wifi_promiscuous_filter_t filt = { .filter_mask = filter_mask };
        esp_wifi_set_promiscuous_filter(&filt);
    }
    return esp_wifi_set_promiscuous(enable ? true : false) == ESP_OK ? 1 : 0;
}

int ow_wifi_set_channel(int primary, int secondary)
{
    return esp_wifi_set_channel((uint8_t)primary, (wifi_second_chan_t)secondary) == ESP_OK ? 1 : 0;
}

// Inject a raw 802.11 frame. ifx selects WIFI_IF_STA (0) or WIFI_IF_AP (1).
// en_sys_seq=true lets the MAC fill the sequence number; the caller can
// still set destination/source MACs and frame control. Used by monitor-mode
// injection paths.
int ow_wifi_raw_tx(int ifx, const uint8_t *frame, int len, int en_sys_seq)
{
    return esp_wifi_80211_tx((wifi_interface_t)ifx, frame, len, en_sys_seq ? true : false) == ESP_OK ? 1 : 0;
}
#else // !CONFIG_ESP_WIFI_ENABLED

typedef void (*ow_wifi_event_cb_t)(int, void *, int);
typedef void (*ow_wifi_rx_cb_t)(const uint8_t *, int, int);
typedef void (*ow_wifi_promisc_cb_t)(int, int, int, int, int, int, const uint8_t *);

int ow_wifi_init(void) { return -1; }
void ow_wifi_deinit(void) {}
int ow_wifi_sta_config(const char *s, const char *p, const uint8_t *b) { (void)s;(void)p;(void)b; return 0; }
int ow_wifi_ap_config(const char *s, const char *p, uint8_t c, uint8_t m, uint8_t h) { (void)s;(void)p;(void)c;(void)m;(void)h; return 0; }
int ow_wifi_ap_set_max_clients(uint8_t m) { (void)m; return 0; }
int ow_wifi_sta_get_ap_info(uint8_t *b, int *r) { (void)b; (void)r; return 0; }
int ow_wifi_set_rx_callback(ow_wifi_rx_cb_t cb) { (void)cb; return 0; }
void ow_wifi_set_sta_callback(ow_wifi_event_cb_t cb) { (void)cb; }
void ow_wifi_set_ap_callback(ow_wifi_event_cb_t cb) { (void)cb; }
int ow_wifi_set_promiscuous(int enable, uint32_t filter_mask) { (void)enable;(void)filter_mask; return 0; }
void ow_wifi_set_promiscuous_callback(ow_wifi_promisc_cb_t cb) { (void)cb; }
int ow_wifi_set_channel(int p, int s) { (void)p;(void)s; return 0; }
int ow_wifi_raw_tx(int ifx, const uint8_t *frame, int len, int en) { (void)ifx;(void)frame;(void)len;(void)en; return 0; }

#endif // CONFIG_ESP_WIFI_ENABLED

// -- BLE (NimBLE) wrappers --

#if CONFIG_BT_ENABLED && CONFIG_BT_NIMBLE_ENABLED
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_gap.h"

static void ow_nimble_host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

int ow_ble_init(void)
{
    int rc = nimble_port_init();
    if (rc != 0)
        return rc;
    nimble_port_freertos_init(ow_nimble_host_task);
    return 0;
}

int ow_ble_deinit(void)
{
    int rc = nimble_port_stop();
    if (rc != 0)
        return rc;
    nimble_port_deinit();
    return 0;
}

#else // !BT_NIMBLE

int ow_ble_init(void) { return -1; }
int ow_ble_deinit(void) { return 0; }

#endif // CONFIG_BT_NIMBLE_ENABLED

// -- CAN (TWAI) driver --

#if SOC_TWAI_SUPPORTED
#include "esp_twai.h"
#include "esp_twai_onchip.h"

#define OW_CAN_RX_CAP 32
#define OW_CAN_TX_CAP 16

_Static_assert((OW_CAN_RX_CAP & (OW_CAN_RX_CAP - 1)) == 0, "CAN RX capacity must be a power of two");
_Static_assert(OW_CAN_TX_CAP <= 32, "CAN TX capacity exceeds the ownership bitmap");

typedef bool (*ow_can_rx_cb_t)(unsigned port);

typedef struct {
    uint32_t id;
    uint8_t flags;
    uint8_t dlc;
    uint8_t data[8];
} ow_can_frame_t;

typedef struct {
    twai_frame_t frame;
    uint8_t data[8];
} ow_can_tx_slot_t;

typedef struct {
    twai_node_handle_t handle;
    unsigned port;
    ow_can_rx_cb_t rx_cb;
    _Atomic uint32_t rx_head;
    _Atomic uint32_t rx_tail;
    _Atomic uint32_t rx_drops;
    _Atomic uint32_t errors;
    _Atomic uint32_t tx_used;
    ow_can_frame_t rx[OW_CAN_RX_CAP];
    ow_can_tx_slot_t tx[OW_CAN_TX_CAP];
} ow_can_context_t;

static ow_can_context_t ow_can_contexts[SOC_TWAI_CONTROLLER_NUM];

static ow_can_context_t *ow_can_find(twai_node_handle_t handle)
{
    if (!handle)
        return NULL;
    for (unsigned i = 0; i < SOC_TWAI_CONTROLLER_NUM; ++i)
        if (ow_can_contexts[i].handle == handle)
            return &ow_can_contexts[i];
    return NULL;
}

static bool ow_can_rx_done(twai_node_handle_t handle, const twai_rx_done_event_data_t *edata, void *user_ctx)
{
    (void)edata;
    ow_can_context_t *ctx = (ow_can_context_t *)user_ctx;
    uint8_t data[64];
    twai_frame_t frame = {
        .buffer = data,
        .buffer_len = sizeof(data),
    };
    if (twai_node_receive_from_isr(handle, &frame) != ESP_OK)
        return false;

    uint16_t length = twaifd_dlc2len(frame.header.dlc);
    uint32_t head = atomic_load_explicit(&ctx->rx_head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&ctx->rx_tail, memory_order_acquire);
    if (length > sizeof(ctx->rx[0].data))
    {
        // The portable frame carries only classic-CAN payloads. Account unsupported FD frames as drops, not queue overruns.
        atomic_fetch_add_explicit(&ctx->rx_drops, 1, memory_order_relaxed);
        return false;
    }
    if (head - tail >= OW_CAN_RX_CAP)
    {
        atomic_fetch_add_explicit(&ctx->rx_drops, 1, memory_order_relaxed);
        atomic_fetch_or_explicit(&ctx->errors, 1u << 5, memory_order_relaxed);
        return false;
    }

    ow_can_frame_t *slot = &ctx->rx[head & (OW_CAN_RX_CAP - 1)];
    slot->id = frame.header.id;
    slot->flags = (frame.header.ide ? 1 : 0) | (frame.header.rtr ? 2 : 0) | (frame.header.fdf ? 4 : 0) | (frame.header.brs ? 8 : 0);
    slot->dlc = (uint8_t)length;
    if (frame.header.rtr)
        memset(slot->data, 0, sizeof(slot->data));
    else if (length > 0)
        memcpy(slot->data, data, length);
    atomic_store_explicit(&ctx->rx_head, head + 1, memory_order_release);
    return ctx->rx_cb ? ctx->rx_cb(ctx->port) : false;
}

static bool ow_can_tx_done(twai_node_handle_t handle, const twai_tx_done_event_data_t *edata, void *user_ctx)
{
    (void)handle;
    ow_can_context_t *ctx = (ow_can_context_t *)user_ctx;
    if (!edata->is_tx_success)
        atomic_fetch_or_explicit(&ctx->errors, 1u << 4, memory_order_relaxed);
    if (edata->done_tx_frame)
    {
        ow_can_tx_slot_t *slot = (ow_can_tx_slot_t *)edata->done_tx_frame;
        unsigned index = (unsigned)(slot - ctx->tx);
        if (index < OW_CAN_TX_CAP)
            atomic_fetch_and_explicit(&ctx->tx_used, ~(1u << index), memory_order_release);
    }
    return false;
}

static bool ow_can_error(twai_node_handle_t handle, const twai_error_event_data_t *edata, void *user_ctx)
{
    (void)handle;
    ow_can_context_t *ctx = (ow_can_context_t *)user_ctx;
    uint32_t errors = 0;
    // ESP-IDF 6.0 exposes arbitration, bit, form, stuff, and ACK flags here, but no CRC flag.
    if (edata->err_flags.bit_err)
        errors |= 1u << 0;
    if (edata->err_flags.stuff_err)
        errors |= 1u << 1;
    if (edata->err_flags.form_err)
        errors |= 1u << 3;
    if (edata->err_flags.ack_err)
        errors |= 1u << 4;
    atomic_fetch_or_explicit(&ctx->errors, errors, memory_order_relaxed);
    return false;
}

twai_node_handle_t ow_can_open(unsigned port, uint32_t bitrate, int tx_gpio, int rx_gpio, uint8_t sjw, uint8_t tseg1, uint8_t tseg2, uint16_t brp, ow_can_rx_cb_t rx_cb)
{
    if (port >= SOC_TWAI_CONTROLLER_NUM || bitrate == 0 || tx_gpio < 0 || rx_gpio < 0)
        return NULL;

    ow_can_context_t *ctx = &ow_can_contexts[port];
    if (ctx->handle)
        return ctx->handle;

    twai_onchip_node_config_t config = {
        .io_cfg = {
            .tx = tx_gpio,
            .rx = rx_gpio,
            .quanta_clk_out = -1,
            .bus_off_indicator = -1,
        },
        .bit_timing = {
            .bitrate = bitrate,
        },
        .fail_retry_cnt = -1,
        .tx_queue_depth = OW_CAN_TX_CAP,
    };

    twai_node_handle_t handle = NULL;
    if (twai_new_node_onchip(&config, &handle) != ESP_OK)
        return NULL;

    if (brp > 0)
    {
        twai_timing_advanced_config_t timing = {
            .brp = brp,
            .tseg_1 = tseg1,
            .tseg_2 = tseg2,
            .sjw = sjw,
        };
        if (twai_node_reconfig_timing(handle, &timing, NULL) != ESP_OK)
        {
            twai_node_delete(handle);
            return NULL;
        }
    }

    memset(ctx, 0, sizeof(*ctx));
    ctx->handle = handle;
    ctx->port = port;
    ctx->rx_cb = rx_cb;

    const twai_event_callbacks_t callbacks = {
        .on_tx_done = &ow_can_tx_done,
        .on_rx_done = &ow_can_rx_done,
        .on_error = &ow_can_error,
    };
    if (twai_node_register_event_callbacks(handle, &callbacks, ctx) != ESP_OK || twai_node_enable(handle) != ESP_OK)
    {
        ctx->handle = NULL;
        twai_node_delete(handle);
        return NULL;
    }
    return handle;
}

void ow_can_close(twai_node_handle_t handle)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    if (!ctx)
        return;
    twai_node_disable(handle);
    twai_node_delete(handle);
    memset(ctx, 0, sizeof(*ctx));
}

bool ow_can_transmit(twai_node_handle_t handle, uint32_t id, uint8_t flags, uint8_t dlc, const uint8_t *data)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    if (!ctx || dlc > 8 || (!data && dlc > 0))
        return false;

    uint32_t used = atomic_load_explicit(&ctx->tx_used, memory_order_relaxed);
    unsigned index;
    for (;;)
    {
        for (index = 0; index < OW_CAN_TX_CAP; ++index)
            if (!(used & (1u << index)))
                break;
        if (index == OW_CAN_TX_CAP)
            return false;
        uint32_t desired = used | (1u << index);
        if (atomic_compare_exchange_weak_explicit(&ctx->tx_used, &used, desired, memory_order_acquire, memory_order_relaxed))
            break;
    }

    ow_can_tx_slot_t *slot = &ctx->tx[index];
    memset(slot, 0, sizeof(*slot));
    slot->frame.header.id = id;
    slot->frame.header.dlc = dlc;
    slot->frame.header.ide = (flags & 1) != 0;
    slot->frame.header.rtr = (flags & 2) != 0;
    slot->frame.header.fdf = (flags & 4) != 0;
    slot->frame.header.brs = (flags & 8) != 0;
    slot->frame.buffer = slot->data;
    slot->frame.buffer_len = dlc;
    if (!(flags & 2) && dlc > 0)
        memcpy(slot->data, data, dlc);

    if (twai_node_transmit(handle, &slot->frame, 0) != ESP_OK)
    {
        atomic_fetch_and_explicit(&ctx->tx_used, ~(1u << index), memory_order_release);
        return false;
    }
    return true;
}

bool ow_can_receive(twai_node_handle_t handle, ow_can_frame_t *frame)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    if (!ctx || !frame)
        return false;
    uint32_t tail = atomic_load_explicit(&ctx->rx_tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&ctx->rx_head, memory_order_acquire);
    if (tail == head)
        return false;
    *frame = ctx->rx[tail & (OW_CAN_RX_CAP - 1)];
    atomic_store_explicit(&ctx->rx_tail, tail + 1, memory_order_release);
    return true;
}

uint32_t ow_can_check_errors(twai_node_handle_t handle)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    return ctx ? atomic_exchange_explicit(&ctx->errors, 0, memory_order_relaxed) : 0;
}

uint32_t ow_can_take_rx_drops(twai_node_handle_t handle)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    return ctx ? atomic_exchange_explicit(&ctx->rx_drops, 0, memory_order_relaxed) : 0;
}

uint32_t ow_can_bus_state(twai_node_handle_t handle)
{
    twai_node_status_t status;
    return twai_node_get_info(handle, &status, NULL) == ESP_OK ? (uint32_t)status.state : (uint32_t)TWAI_ERROR_BUS_OFF;
}

uint32_t ow_can_tx_error_count(twai_node_handle_t handle)
{
    twai_node_status_t status;
    return twai_node_get_info(handle, &status, NULL) == ESP_OK ? status.tx_error_count : 0;
}

uint32_t ow_can_rx_error_count(twai_node_handle_t handle)
{
    twai_node_status_t status;
    return twai_node_get_info(handle, &status, NULL) == ESP_OK ? status.rx_error_count : 0;
}

size_t ow_can_rx_available(twai_node_handle_t handle)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    if (!ctx)
        return 0;
    uint32_t head = atomic_load_explicit(&ctx->rx_head, memory_order_acquire);
    uint32_t tail = atomic_load_explicit(&ctx->rx_tail, memory_order_relaxed);
    return head - tail;
}

void ow_can_rx_flush(twai_node_handle_t handle)
{
    ow_can_context_t *ctx = ow_can_find(handle);
    if (!ctx)
        return;
    uint32_t head = atomic_load_explicit(&ctx->rx_head, memory_order_acquire);
    atomic_store_explicit(&ctx->rx_tail, head, memory_order_release);
}

bool ow_can_bus_recover(twai_node_handle_t handle)
{
    return twai_node_recover(handle) == ESP_OK;
}

#else // !SOC_TWAI_SUPPORTED

typedef struct twai_node_base *twai_node_handle_t;
typedef bool (*ow_can_rx_cb_t)(unsigned);
typedef struct {
    uint32_t id;
    uint8_t flags;
    uint8_t dlc;
    uint8_t data[8];
} ow_can_frame_t;

twai_node_handle_t ow_can_open(unsigned port, uint32_t bitrate, int tx_gpio, int rx_gpio, uint8_t sjw, uint8_t tseg1, uint8_t tseg2, uint16_t brp, ow_can_rx_cb_t rx_cb)
{
    return NULL;
}
void ow_can_close(twai_node_handle_t handle) {}
bool ow_can_transmit(twai_node_handle_t handle, uint32_t id, uint8_t flags, uint8_t dlc, const uint8_t *data) { return false; }
bool ow_can_receive(twai_node_handle_t handle, ow_can_frame_t *frame) { return false; }
uint32_t ow_can_check_errors(twai_node_handle_t handle) { return 0; }
uint32_t ow_can_take_rx_drops(twai_node_handle_t handle) { return 0; }
uint32_t ow_can_bus_state(twai_node_handle_t handle) { return 3; } // CanBusState.bus_off
uint32_t ow_can_tx_error_count(twai_node_handle_t handle) { return 0; }
uint32_t ow_can_rx_error_count(twai_node_handle_t handle) { return 0; }
size_t ow_can_rx_available(twai_node_handle_t handle) { return 0; }
void ow_can_rx_flush(twai_node_handle_t handle) {}
bool ow_can_bus_recover(twai_node_handle_t handle) { return false; }

#endif // SOC_TWAI_SUPPORTED

#ifdef OW_USE_LWIP
// -- lwIP netdb wrappers (link-order fix) --
// D object references lwip_getaddrinfo/lwip_freeaddrinfo but the D object
// appears after liblwip.a in the link. These wrappers are in libmain.a
// which is linked with --whole-archive, ensuring they're always present.

int ow_lwip_getaddrinfo(const char *nodename, const char *servname, const struct addrinfo *hints, struct addrinfo **res)
{
    return lwip_getaddrinfo(nodename, servname, hints, res);
}

void ow_lwip_freeaddrinfo(struct addrinfo *ai)
{
    lwip_freeaddrinfo(ai);
}
#endif


// =====================================================================
// SPIFFS -- urt.file backend
//
// TRAJECTORY, not the destination.
//
// This rides newlib's open/read/write, which reach SPIFFS through IDF's VFS.
// That is why platforms/esp32s3/sdkconfig.defaults has to enable
// CONFIG_VFS_SUPPORT_IO and _DIR: with them off, open() is a stub returning
// ENOSYS even though the filesystem mounted fine. Those were deliberately off
// to save space, and turning them on costs every ESP target the whole syscall
// layer for the sake of a stopgap filesystem.
//
// Where this should go: mount SPIFFS directly with SPIFFS_mount() and read /
// write / erase callbacks over esp_partition_*, then call SPIFFS_open() and
// friends. No VFS, no newlib, no "/spiffs" prefixing, and the sdkconfig change
// reverts. The blocker is that IDF keeps spiffs.h in PRIV_INCLUDE_DIRS and
// esp_vfs_spiffs_register() keeps its spiffs* handle private, so it means
// either widening the include path or vendoring the SPIFFS sources -- the
// latter being what a non-Espressif target would need anyway.
//
// littlefs wants exactly that shape too (bring your own block device), so the
// work is not thrown away when this is replaced.
// =====================================================================

#ifdef OW_USE_SPIFFS

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "esp_spiffs.h"

#define OW_SPIFFS_ROOT "/spiffs"

// Registration state is ours, not esp_spiffs_mounted()'s: that reports whether
// the partition is mounted internally, which a format also does, and mounting
// the partition does not put a VFS on OW_SPIFFS_ROOT. -1 latches a failed mount
// so an unformatted partition is not retried on every access.
static int ow_spiffs_last_errno = 0;
static bool ow_spiffs_registered = false;
static int ow_spiffs_mount_state = 0;

static bool ow_spiffs_ready(void)
{
    if (ow_spiffs_registered)
        return true;
    if (ow_spiffs_mount_state < 0)
        return false;

    esp_vfs_spiffs_conf_t conf = {
        .base_path = OW_SPIFFS_ROOT,
        .partition_label = NULL,
        .max_files = 4,
        .format_if_mount_failed = false,
    };
    if (esp_vfs_spiffs_register(&conf) != ESP_OK)
    {
        ow_spiffs_mount_state = -1;
        return false;
    }
    ow_spiffs_registered = true;
    return true;
}

// Anchor caller paths under the mount point.
static bool ow_spiffs_path(const char *path, size_t path_len, char *buffer, size_t buffer_size)
{
    const size_t root = sizeof(OW_SPIFFS_ROOT) - 1;
    size_t skip = (path_len && path[0] == '/') ? 1 : 0;
    if (root + 1 + (path_len - skip) + 1 > buffer_size)
        return false;
    memcpy(buffer, OW_SPIFFS_ROOT, root);
    buffer[root] = '/';
    memcpy(buffer + root + 1, path + skip, path_len - skip);
    buffer[root + 1 + path_len - skip] = 0;
    return true;
}

int urt_spiffs_exists(const char *path, size_t path_len)
{
    char buffer[128];
    if (!ow_spiffs_ready() || !ow_spiffs_path(path, path_len, buffer, sizeof(buffer)))
        return 0;
    struct stat st;
    return stat(buffer, &st) == 0 && S_ISREG(st.st_mode);
}

int urt_spiffs_open(const char *path, size_t path_len, bool write, bool truncate)
{
    char buffer[128];
    if (!ow_spiffs_ready() || !ow_spiffs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;
    int flags = write ? (O_RDWR | O_CREAT) : O_RDONLY;
    if (write && truncate)
        flags |= O_TRUNC;
    int fd = open(buffer, flags, 0644);
    if (fd < 0)
        ow_spiffs_last_errno = errno;
    return fd;
}

ptrdiff_t urt_spiffs_read(int fd, void *buffer, size_t length)
{
    ptrdiff_t n = read(fd, buffer, length);
    if (n < 0)
        ow_spiffs_last_errno = errno;
    return n;
}


int urt_spiffs_info(uint64_t *total, uint64_t *used)
{
    if (!ow_spiffs_ready())
        return -1;
    size_t t = 0, u = 0;
    esp_err_t err = esp_spiffs_info(NULL, &t, &u);
    *total = t;
    *used = u;
    return err == ESP_OK ? 0 : -1;
}

int urt_spiffs_last_error(void)
{
    return ow_spiffs_last_errno;
}

// SPIFFS has no directories; its VFS reports the flat namespace as a single
// listing at the mount root. Exposed raw -- urt.file synthesises the
// hierarchy from '/' in the names.
#define OW_SPIFFS_MAX_SCANS 2

static DIR *ow_spiffs_scans[OW_SPIFFS_MAX_SCANS];

int urt_spiffs_scan_open(void)
{
    if (!ow_spiffs_ready())
        return -1;

    int h = -1;
    for (int i = 0; i < OW_SPIFFS_MAX_SCANS; ++i)
    {
        if (!ow_spiffs_scans[i])
        {
            h = i;
            break;
        }
    }
    if (h < 0)
        return -1;

    DIR *d = opendir(OW_SPIFFS_ROOT);
    if (!d)
    {
        ow_spiffs_last_errno = errno;
        return -1;
    }
    ow_spiffs_scans[h] = d;
    return h;
}

ptrdiff_t urt_spiffs_scan_read(int h, char *name, size_t name_len, uint64_t *size)
{
    if (h < 0 || h >= OW_SPIFFS_MAX_SCANS || !ow_spiffs_scans[h])
        return -1;

    errno = 0;
    struct dirent *e = readdir(ow_spiffs_scans[h]);
    if (!e)
    {
        if (errno)
        {
            ow_spiffs_last_errno = errno;
            return -1;
        }
        return 0;
    }

    size_t len = strlen(e->d_name);
    if (len > name_len)
        len = name_len;
    memcpy(name, e->d_name, len);

    *size = 0;
    char full[128];
    const size_t root = sizeof(OW_SPIFFS_ROOT) - 1;
    if (root + 1 + len + 1 <= sizeof(full))
    {
        memcpy(full, OW_SPIFFS_ROOT, root);
        full[root] = '/';
        memcpy(full + root + 1, e->d_name, len);
        full[root + 1 + len] = '\0';
        struct stat st;
        if (stat(full, &st) == 0)
            *size = (uint64_t)st.st_size;
    }
    return (ptrdiff_t)len;
}

void urt_spiffs_scan_close(int h)
{
    if (h < 0 || h >= OW_SPIFFS_MAX_SCANS || !ow_spiffs_scans[h])
        return;
    closedir(ow_spiffs_scans[h]);
    ow_spiffs_scans[h] = NULL;
}

ptrdiff_t urt_spiffs_write(int fd, const void *data, size_t length)
{
    ptrdiff_t n = write(fd, data, length);
    if (n < 0)
        ow_spiffs_last_errno = errno;
    return n;
}

void urt_spiffs_close(int fd)
{
    close(fd);
}

uint64_t urt_spiffs_size(int fd)
{
    struct stat st;
    if (fstat(fd, &st) == 0)
        return (uint64_t)st.st_size;
    ow_spiffs_last_errno = errno;
    return 0;
}

int64_t urt_spiffs_seek(int fd, int64_t offset, int whence)
{
    return lseek(fd, (off_t)offset, whence);
}

int urt_spiffs_truncate(int fd, uint64_t length)
{
    return ftruncate(fd, (off_t)length);
}

int urt_spiffs_sync(int fd)
{
    return fsync(fd);
}

int urt_spiffs_unlink(const char *path, size_t path_len)
{
    char buffer[128];
    if (!ow_spiffs_ready() || !ow_spiffs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;
    return unlink(buffer);
}

int urt_spiffs_rename(const char *from, size_t from_len, const char *to, size_t to_len)
{
    char from_buffer[128], to_buffer[128];
    if (!ow_spiffs_ready() ||
        !ow_spiffs_path(from, from_len, from_buffer, sizeof(from_buffer)) ||
        !ow_spiffs_path(to, to_len, to_buffer, sizeof(to_buffer)))
        return -1;
    return rename(from_buffer, to_buffer);
}

int urt_spiffs_stat(const char *path, size_t path_len, uint64_t *size)
{
    char buffer[128];
    if (!ow_spiffs_ready() || !ow_spiffs_path(path, path_len, buffer, sizeof(buffer)))
        return -1;
    struct stat st;
    if (stat(buffer, &st) != 0)
        return -1;
    *size = (uint64_t)st.st_size;
    return 0;
}

// Formatting a multi-megabyte partition blocks for long enough to starve the
// watchdog, so it runs on its own task and the caller polls for completion.
enum { OW_SPIFFS_FORMAT_IDLE = 0, OW_SPIFFS_FORMAT_RUNNING, OW_SPIFFS_FORMAT_COMPLETE, OW_SPIFFS_FORMAT_FAILED };

static volatile int ow_spiffs_format_state = OW_SPIFFS_FORMAT_IDLE;

static void ow_spiffs_format_task(void *argument)
{
    (void)argument;
    esp_err_t err = esp_spiffs_format(NULL);
    if (err == ESP_OK)
    {
        // Formatting leaves the partition mounted but unregistered; drop that so
        // the next access can register a VFS on it.
        if (!ow_spiffs_registered && esp_spiffs_mounted(NULL))
            esp_vfs_spiffs_unregister(NULL);
        ow_spiffs_mount_state = 0;
    }
    ow_spiffs_format_state = (err == ESP_OK) ? OW_SPIFFS_FORMAT_COMPLETE : OW_SPIFFS_FORMAT_FAILED;
    vTaskDelete(NULL);
}

int urt_spiffs_format_begin(void)
{
    if (ow_spiffs_format_state == OW_SPIFFS_FORMAT_RUNNING)
        return 0;
    ow_spiffs_format_state = OW_SPIFFS_FORMAT_RUNNING;
    if (xTaskCreate(ow_spiffs_format_task, "ow-spiffs-fmt", 4096, NULL, tskIDLE_PRIORITY + 1, NULL) != pdPASS)
    {
        ow_spiffs_format_state = OW_SPIFFS_FORMAT_FAILED;
        return -1;
    }
    return 0;
}

int urt_spiffs_available(void)
{
    return ow_spiffs_ready() ? 1 : 0;
}

int urt_spiffs_format_status(void)
{
    return ow_spiffs_format_state;
}

#endif // OW_USE_SPIFFS
