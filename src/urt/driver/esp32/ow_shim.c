// OpenWatt ESP-IDF shim -- the single C bridge between D and ESP-IDF.
// Wraps FreeRTOS macros, UART HAL inlines, and anything else that
// needs C headers or static-inline access.

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "driver/uart.h"
#include "esp_rom_serial_output.h"
#include "soc/soc_caps.h"
#include <stdatomic.h>
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
#include "soc/gpio_num.h"

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

void ow_gpio_output_set(int pin, int value)
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
        ow_uart_rx_ready_cb_t callback = atomic_load_explicit(
            &uart_rx_ready[port], memory_order_acquire);
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
    if (port >= NUM_UARTS ||
        atomic_load_explicit(&uart_initialized[port], memory_order_acquire) ||
        data_bits < 5 || data_bits > 8)
        return 0;

    uart_config_t config = {0};
    config.baud_rate = (int)baud_rate;
    config.data_bits = (uart_word_length_t)(UART_DATA_5_BITS + data_bits - 5);
    config.parity = parity < sizeof(parity_map) / sizeof(parity_map[0])
        ? parity_map[parity] : UART_PARITY_DISABLE;
    config.stop_bits = stop_bits < sizeof(stop_bits_map) / sizeof(stop_bits_map[0])
        ? stop_bits_map[stop_bits] : UART_STOP_BITS_1;
    config.flow_ctrl = UART_HW_FLOWCTRL_DISABLE;
    config.source_clk = UART_SCLK_DEFAULT;

    uart_port_t uart = (uart_port_t)port;
    if (uart_param_config(uart, &config) != ESP_OK ||
        uart_set_pin(uart, tx_gpio, rx_gpio, de_gpio, UART_PIN_NO_CHANGE) != ESP_OK ||
        uart_driver_install(uart, UART_RX_BUFFER_SIZE, UART_TX_BUFFER_SIZE,
                            UART_EVENT_QUEUE_SIZE, &uart_event_queue[port], 0) != ESP_OK)
    {
        uart_event_queue[port] = NULL;
        return 0;
    }

    uint32_t inverse = rs485_enabled && !de_active_high
        ? UART_SIGNAL_RTS_INV : 0;
    if (uart_set_line_inverse(uart, inverse) != ESP_OK)
    {
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }
    if (rs485_enabled &&
        uart_set_mode(uart, UART_MODE_RS485_HALF_DUPLEX) != ESP_OK)
    {
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }

    if (!uart_event_task_done[port])
        uart_event_task_done[port] = xSemaphoreCreateBinaryStatic(
            &uart_event_task_done_storage[port]);
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
    if (xTaskCreate(ow_uart_event_task, "ow-uart", UART_EVENT_TASK_STACK,
                    (void *)(uintptr_t)port, tskIDLE_PRIORITY + 2,
                    &uart_event_task[port]) != pdPASS)
    {
        atomic_store_explicit(&uart_initialized[port], false,
                              memory_order_release);
        atomic_store_explicit(&uart_rx_ready[port], NULL,
                              memory_order_release);
        uart_driver_delete(uart);
        uart_event_queue[port] = NULL;
        return 0;
    }
    return 1;
}

void ow_uart_close(unsigned port)
{
    if (port >= NUM_UARTS ||
        !atomic_exchange_explicit(&uart_initialized[port], false,
                                  memory_order_acq_rel))
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
    if (port >= NUM_UARTS ||
        !atomic_load_explicit(&uart_initialized[port], memory_order_acquire) ||
        !buf || len <= 0)
        return 0;
    return uart_read_bytes((uart_port_t)port, buf, (uint32_t)len, 0);
}

int32_t ow_uart_write(unsigned port, const uint8_t *buf, int32_t len)
{
    if (port >= NUM_UARTS ||
        !atomic_load_explicit(&uart_initialized[port], memory_order_acquire) ||
        !buf || len <= 0)
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
    if (port >= NUM_UARTS ||
        !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    size_t available = 0;
    return uart_get_buffered_data_len((uart_port_t)port, &available) == ESP_OK
        ? (int32_t)available : 0;
}

int ow_uart_tx_idle(unsigned port)
{
    if (port >= NUM_UARTS ||
        !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 1;
    return uart_wait_tx_done((uart_port_t)port, 0) == ESP_OK;
}

int32_t ow_uart_flush(unsigned port)
{
    if (port >= NUM_UARTS ||
        !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    return uart_wait_tx_done((uart_port_t)port, portMAX_DELAY) == ESP_OK ? 0 : -1;
}

int ow_uart_check_errors(unsigned port)
{
    if (port >= NUM_UARTS ||
        !atomic_load_explicit(&uart_initialized[port], memory_order_acquire))
        return 0;
    return (int)atomic_exchange_explicit(&uart_errors[port], 0,
                                          memory_order_relaxed);
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

typedef void (*ow_wifi_promisc_cb_t)(int type, int rssi, int channel,
                                     int rate, int fcs_fail, int len,
                                     const uint8_t *payload);

static ow_wifi_promisc_cb_t ow_wifi_promisc_callback;

static void ow_wifi_promisc_trampoline(void *buf, wifi_promiscuous_pkt_type_t type)
{
    // ESP-IDF reports WIFI_PKT_MISC with metadata but no payload.
    if (!ow_wifi_promisc_callback || !buf || type == WIFI_PKT_MISC)
        return;
    const wifi_promiscuous_pkt_t *pkt = (const wifi_promiscuous_pkt_t *)buf;
    const wifi_pkt_rx_ctrl_t *rx = &pkt->rx_ctrl;
    ow_wifi_promisc_callback((int)type, (int)rx->rssi, (int)rx->channel,
                             (int)rx->rate, (int)rx->rx_state, (int)rx->sig_len,
                             pkt->payload);
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
    return esp_wifi_set_channel((uint8_t)primary,
                                (wifi_second_chan_t)secondary) == ESP_OK ? 1 : 0;
}

// Inject a raw 802.11 frame. ifx selects WIFI_IF_STA (0) or WIFI_IF_AP (1).
// en_sys_seq=true lets the MAC fill the sequence number; the caller can
// still set destination/source MACs and frame control. Used by monitor-mode
// injection paths.
int ow_wifi_raw_tx(int ifx, const uint8_t *frame, int len, int en_sys_seq)
{
    return esp_wifi_80211_tx((wifi_interface_t)ifx, frame, len,
                             en_sys_seq ? true : false) == ESP_OK ? 1 : 0;
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

typedef int (*ow_gap_event_cb_t)(struct ble_gap_event *, void *);
static ow_gap_event_cb_t ow_gap_callback;

static int ow_gap_event_dispatch(struct ble_gap_event *event, void *arg)
{
    if (ow_gap_callback)
        return ow_gap_callback(event, arg);
    return 0;
}

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

void ow_ble_deinit(void)
{
    nimble_port_stop();
    nimble_port_deinit();
}

void ow_ble_set_gap_callback(ow_gap_event_cb_t cb)
{
    ow_gap_callback = cb;
}

#else // !BT_NIMBLE

typedef int (*ow_gap_event_cb_t)(void *, void *);

int ow_ble_init(void) { return -1; }
void ow_ble_deinit(void) {}
void ow_ble_set_gap_callback(ow_gap_event_cb_t cb) { (void)cb; }

#endif // CONFIG_BT_NIMBLE_ENABLED

// -- CAN (TWAI) driver --
//
// Only ow_can_open lives here -- it builds the timing/general/filter config
// structs and does install+start.  Everything else is called directly from D
// via the ESP-IDF _v2 handle API.

#include "soc/soc_caps.h"
#if SOC_TWAI_SUPPORTED
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcpp"
#include "driver/twai.h"
#pragma GCC diagnostic pop

twai_handle_t ow_can_open(unsigned port, uint32_t bitrate, int tx_gpio, int rx_gpio, uint8_t sjw, uint8_t tseg1, uint8_t tseg2, uint16_t brp)
{
    if (port >= SOC_TWAI_CONTROLLER_NUM)
        return NULL;

    twai_timing_config_t timing;
    if (brp > 0)
    {
        memset(&timing, 0, sizeof(timing));
        timing.clk_src = TWAI_CLK_SRC_DEFAULT;
        timing.brp = brp;
        timing.tseg_1 = tseg1;
        timing.tseg_2 = tseg2;
        timing.sjw = sjw;
    }
    else
    {
        switch (bitrate)
        {
        case 1000:    timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_1KBITS();     break;
        case 5000:    timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_5KBITS();     break;
        case 10000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_10KBITS();    break;
        case 12500:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_12_5KBITS();  break;
        case 16000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_16KBITS();    break;
        case 20000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_20KBITS();    break;
        case 25000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_25KBITS();    break;
        case 50000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_50KBITS();    break;
        case 100000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_100KBITS();   break;
        case 125000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_125KBITS();   break;
        case 250000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_250KBITS();   break;
        case 500000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_500KBITS();   break;
        case 800000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_800KBITS();   break;
        case 1000000: timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_1MBITS();     break;
        default: return NULL;
        }
    }

    twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT_V2(
        port, tx_gpio, rx_gpio, TWAI_MODE_NORMAL);
    general.alerts_enabled = TWAI_ALERT_BUS_ERROR | TWAI_ALERT_ERR_PASS
        | TWAI_ALERT_ERR_ACTIVE | TWAI_ALERT_BUS_OFF | TWAI_ALERT_ABOVE_ERR_WARN
        | TWAI_ALERT_BELOW_ERR_WARN | TWAI_ALERT_RX_FIFO_OVERRUN
        | TWAI_ALERT_RX_QUEUE_FULL | TWAI_ALERT_ARB_LOST | TWAI_ALERT_TX_FAILED;
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();

    twai_handle_t handle = NULL;
    if (twai_driver_install_v2(&general, &timing, &filter, &handle) != ESP_OK)
        return NULL;

    if (twai_start_v2(handle) != ESP_OK)
    {
        twai_driver_uninstall_v2(handle);
        return NULL;
    }

    return handle;
}

#else // !SOC_TWAI_SUPPORTED

typedef struct twai_obj_t *twai_handle_t;

twai_handle_t ow_can_open(unsigned, uint32_t, int, int, uint8_t, uint8_t, uint8_t, uint16_t)
{
    return (twai_handle_t)0;
}

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
