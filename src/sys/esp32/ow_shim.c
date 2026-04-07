// OpenWatt ESP-IDF shim -- the single C bridge between D and ESP-IDF.
// Wraps FreeRTOS macros, UART HAL inlines, and anything else that
// needs C headers or static-inline access.

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hal/uart_hal.h"
#include "hal/uart_types.h"
#include "hal/uart_periph.h"
#include "esp_rom_gpio.h"
#include "lwip/netdb.h"

// -- errno accessor (picolibc uses _Thread_local errno, incompatible with emulated-TLS) --

#include <errno.h>

int *ow_errno_location(void)
{
    return &errno;
}

// -- FreeRTOS task wrappers --

typedef void (*ow_task_func_t)(void *);

int ow_task_create(ow_task_func_t func, const char *name, uint32_t stack_bytes,
                   void *param, uint32_t priority, void **out_handle)
{
    return xTaskCreate(func, name, stack_bytes, param, priority,
                       (TaskHandle_t *)out_handle) == pdPASS ? 1 : 0;
}

void ow_task_delete(void *handle)
{
    vTaskDelete((TaskHandle_t)handle);
}

void *ow_task_current(void)
{
    return (void *)xTaskGetCurrentTaskHandle();
}

void ow_task_notify_give(void *handle)
{
    xTaskNotifyGive((TaskHandle_t)handle);
}

uint32_t ow_task_notify_take(uint32_t ticks_to_wait)
{
    return ulTaskNotifyTake(pdTRUE, ticks_to_wait);
}

uint32_t ow_task_priority_get(void *handle)
{
    return uxTaskPriorityGet((TaskHandle_t)handle);
}

// -- UART HAL wrappers --

#define NUM_UARTS 3

static uart_hal_context_t uart_ctx[NUM_UARTS];
static bool uart_initialized[NUM_UARTS];

// D enums: StopBits { one=0, one_point_five=1, two=2 }
//          Parity   { none=0, even=1, odd=2, mark=3, space=4 }
// HAL enums: UART_STOP_BITS_1=1, _1_5=2, _2=3
//            UART_PARITY_DISABLE=0, _EVEN=2, _ODD=3
static const uart_stop_bits_t stop_bits_map[] = {
    UART_STOP_BITS_1, UART_STOP_BITS_1_5, UART_STOP_BITS_2
};
static const uart_parity_t parity_map[] = {
    UART_PARITY_DISABLE, UART_PARITY_EVEN, UART_PARITY_ODD,
    UART_PARITY_DISABLE, UART_PARITY_DISABLE
};

int ow_uart_open(int port, uint32_t baud_rate, uint8_t data_bits,
                 uint8_t stop_bits, uint8_t parity,
                 int8_t tx_gpio, int8_t rx_gpio)
{
    if (port < 0 || port >= NUM_UARTS)
        return 0;

    uart_hal_init(&uart_ctx[port], port);

    uart_ll_set_sclk(uart_ctx[port].dev, UART_SCLK_APB);
    uart_ll_set_baudrate(uart_ctx[port].dev, baud_rate, 80000000);
    uart_ll_set_data_bit_num(uart_ctx[port].dev, data_bits - 5);
    uart_ll_set_stop_bits(uart_ctx[port].dev, stop_bits < sizeof(stop_bits_map) ? stop_bits_map[stop_bits] : 1);
    uart_ll_set_parity(uart_ctx[port].dev, parity < sizeof(parity_map)/sizeof(parity_map[0]) ? parity_map[parity] : UART_PARITY_DISABLE);

    uart_hal_rxfifo_rst(&uart_ctx[port]);
    uart_hal_txfifo_rst(&uart_ctx[port]);

    // GPIO pin routing -- UART0 defaults (TX=43, RX=44) set by bootloader.
    // For non-default pins or UART1/2, route via GPIO matrix.
    if (tx_gpio >= 0)
    {
        esp_rom_gpio_pad_select_gpio(tx_gpio);
        esp_rom_gpio_connect_out_signal(tx_gpio,
            uart_periph_signal[port].pins[SOC_UART_PERIPH_SIGNAL_TX].signal, false, false);
    }
    if (rx_gpio >= 0)
    {
        esp_rom_gpio_pad_select_gpio(rx_gpio);
        esp_rom_gpio_pad_pullup_only(rx_gpio);
        esp_rom_gpio_connect_in_signal(rx_gpio,
            uart_periph_signal[port].pins[SOC_UART_PERIPH_SIGNAL_RX].signal, false);
    }

    uart_initialized[port] = true;
    return 1;
}

void ow_uart_close(int port)
{
    if (port < 0 || port >= NUM_UARTS || !uart_initialized[port])
        return;
    uart_hal_txfifo_rst(&uart_ctx[port]);
    uart_hal_rxfifo_rst(&uart_ctx[port]);
    uart_initialized[port] = false;
}

int32_t ow_uart_read(int port, uint8_t *buf, int32_t len)
{
    if (port < 0 || port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    int rd_len = (int)len;
    uart_hal_read_rxfifo(&uart_ctx[port], buf, &rd_len);
    return rd_len;
}

int32_t ow_uart_write(int port, const uint8_t *buf, int32_t len)
{
    if (port < 0 || port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    uint32_t written = 0;
    uart_hal_write_txfifo(&uart_ctx[port], buf, (uint32_t)len, &written);
    return (int32_t)written;
}

int32_t ow_uart_rx_pending(int port)
{
    if (port < 0 || port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    return (int32_t)uart_ll_get_rxfifo_len(uart_ctx[port].dev);
}

int ow_uart_tx_idle(int port)
{
    if (port < 0 || port >= NUM_UARTS || !uart_initialized[port])
        return 1;
    return uart_ll_is_tx_idle(uart_ctx[port].dev) ? 1 : 0;
}

int32_t ow_uart_flush(int port)
{
    if (port < 0 || port >= NUM_UARTS || !uart_initialized[port])
        return 0;
    while (!uart_ll_is_tx_idle(uart_ctx[port].dev))
        ;
    return 0;
}

// -- WiFi wrappers --

#include "esp_wifi.h"
#include "esp_private/wifi.h"
#include "esp_netif.h"
#include "esp_event.h"
#include "esp_mac.h"

static esp_netif_t *ow_wifi_netif_sta;
static esp_netif_t *ow_wifi_netif_ap;
static int ow_wifi_refcount;

typedef void (*ow_wifi_event_cb_t)(int event_id, void *data, int data_len);

static ow_wifi_event_cb_t ow_wifi_sta_cb;
static ow_wifi_event_cb_t ow_wifi_ap_cb;

static void ow_wifi_event_handler(void *arg, esp_event_base_t base,
                                  int32_t event_id, void *event_data)
{
    if (base == WIFI_EVENT)
    {
        switch (event_id)
        {
        case WIFI_EVENT_STA_CONNECTED:
        case WIFI_EVENT_STA_DISCONNECTED:
        case WIFI_EVENT_STA_START:
        case WIFI_EVENT_STA_STOP:
            if (ow_wifi_sta_cb)
                ow_wifi_sta_cb(event_id, event_data, 0);
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
    else if (base == IP_EVENT)
    {
        if (event_id == IP_EVENT_STA_GOT_IP && ow_wifi_sta_cb)
            ow_wifi_sta_cb(event_id, event_data, 0);
    }
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

    // Create netifs before registering RX callbacks or starting WiFi,
    // so esp_netif_receive() always has valid targets.
    if (!ow_wifi_netif_sta)
        ow_wifi_netif_sta = esp_netif_create_default_wifi_sta();
    if (!ow_wifi_netif_ap)
        ow_wifi_netif_ap = esp_netif_create_default_wifi_ap();

    esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                               &ow_wifi_event_handler, NULL);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                               &ow_wifi_event_handler, NULL);

    return 0;
}

void ow_wifi_deinit(void)
{
    if (--ow_wifi_refcount > 0)
        return;

    esp_wifi_stop();
    esp_wifi_deinit();

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
}

int ow_wifi_set_mode(int mode)
{
    // mode: 0=none, 1=sta, 2=ap, 3=apsta
    return esp_wifi_set_mode((wifi_mode_t)mode) == ESP_OK ? 1 : 0;
}

int ow_wifi_start(void)
{
    return esp_wifi_start() == ESP_OK ? 1 : 0;
}

int ow_wifi_stop(void)
{
    return esp_wifi_stop() == ESP_OK ? 1 : 0;
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

int ow_wifi_sta_connect(void)
{
    return esp_wifi_connect() == ESP_OK ? 1 : 0;
}

int ow_wifi_sta_disconnect(void)
{
    return esp_wifi_disconnect() == ESP_OK ? 1 : 0;
}

int ow_wifi_ap_config(const char *ssid, const char *password,
                      uint8_t channel, uint8_t max_conn, uint8_t hidden)
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

int ow_wifi_set_tx_power(int8_t power)
{
    return esp_wifi_set_max_tx_power(power) == ESP_OK ? 1 : 0;
}

int ow_wifi_get_channel(uint8_t *channel)
{
    uint8_t primary;
    wifi_second_chan_t second;
    if (esp_wifi_get_channel(&primary, &second) != ESP_OK)
        return 0;
    *channel = primary;
    return 1;
}

int ow_wifi_get_mac(int iface, uint8_t *mac)
{
    // iface: 0=sta, 1=ap
    return esp_read_mac(mac, iface == 0 ? ESP_MAC_WIFI_STA : ESP_MAC_WIFI_SOFTAP) == ESP_OK ? 1 : 0;
}

// Ethernet frame RX callbacks -- one per netif (STA=0, AP=1).
// esp_wifi_internal_reg_rxcb gives us raw Ethernet frames before lwIP,
// so the bridge/routing layer sees all traffic.

typedef void (*ow_wifi_rx_cb_t)(const uint8_t *data, int len, int iface);

static ow_wifi_rx_cb_t ow_wifi_rx_callback;

static esp_err_t ow_wifi_sta_rx(void *buffer, uint16_t len, void *eb)
{
    if (ow_wifi_rx_callback)
        ow_wifi_rx_callback((const uint8_t *)buffer, len, 0);
    return esp_netif_receive(ow_wifi_netif_sta, buffer, len, eb);
}

static esp_err_t ow_wifi_ap_rx(void *buffer, uint16_t len, void *eb)
{
    if (ow_wifi_rx_callback)
        ow_wifi_rx_callback((const uint8_t *)buffer, len, 1);
    return esp_netif_receive(ow_wifi_netif_ap, buffer, len, eb);
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

int ow_wifi_tx(int iface, const uint8_t *data, int len)
{
    return esp_wifi_internal_tx((wifi_interface_t)iface, (void *)data, (uint16_t)len) == ESP_OK ? 1 : 0;
}

void ow_wifi_set_sta_callback(ow_wifi_event_cb_t cb)
{
    ow_wifi_sta_cb = cb;
}

void ow_wifi_set_ap_callback(ow_wifi_event_cb_t cb)
{
    ow_wifi_ap_cb = cb;
}

// -- TWAI (CAN) wrappers --

// Legacy TWAI driver -- TODO: port to esp_twai.h node-handle API
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcpp"
#include "driver/twai.h"
#pragma GCC diagnostic pop

static bool ow_twai_initialized;

int ow_twai_init(uint32_t baud_rate, int tx_io, int rx_io)
{
    if (ow_twai_initialized)
        return 1;

    twai_timing_config_t timing;
    switch (baud_rate)
    {
    case 25000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_25KBITS();   break;
    case 50000:   timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_50KBITS();   break;
    case 100000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_100KBITS();  break;
    case 125000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_125KBITS();  break;
    case 250000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_250KBITS();  break;
    case 500000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_500KBITS();  break;
    case 800000:  timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_800KBITS();  break;
    case 1000000: timing = (twai_timing_config_t)TWAI_TIMING_CONFIG_1MBITS();    break;
    default: return 0;
    }

    twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT(tx_io, rx_io, TWAI_MODE_NORMAL);
    twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();

    if (twai_driver_install(&general, &timing, &filter) != ESP_OK)
        return 0;

    if (twai_start() != ESP_OK)
    {
        twai_driver_uninstall();
        return 0;
    }

    ow_twai_initialized = true;
    return 1;
}

void ow_twai_deinit(void)
{
    if (!ow_twai_initialized)
        return;
    twai_stop();
    twai_driver_uninstall();
    ow_twai_initialized = false;
}

int ow_twai_transmit(uint32_t id, int extended, int rtr, const uint8_t *data, uint8_t len)
{
    if (!ow_twai_initialized)
        return 0;

    twai_message_t msg = {0};
    msg.identifier = id;
    msg.extd = extended ? 1 : 0;
    msg.rtr = rtr ? 1 : 0;
    msg.data_length_code = len;
    if (len > 0 && data)
        memcpy(msg.data, data, len > 8 ? 8 : len);

    return twai_transmit(&msg, 0) == ESP_OK ? 1 : 0;
}

int ow_twai_receive(uint32_t *id, int *extended, int *rtr, uint8_t *data, uint8_t *len)
{
    if (!ow_twai_initialized)
        return 0;

    twai_message_t msg;
    if (twai_receive(&msg, 0) != ESP_OK)
        return 0;

    *id = msg.identifier;
    *extended = msg.extd;
    *rtr = msg.rtr;
    *len = msg.data_length_code;
    if (msg.data_length_code > 0)
        memcpy(data, msg.data, msg.data_length_code > 8 ? 8 : msg.data_length_code);

    return 1;
}

// -- lwIP netdb wrappers (link-order fix) --
// D object references lwip_getaddrinfo/lwip_freeaddrinfo but the D object
// appears after liblwip.a in the link. These wrappers are in libmain.a
// which is linked with --whole-archive, ensuring they're always present.

int ow_lwip_getaddrinfo(const char *nodename, const char *servname,
                        const struct addrinfo *hints, struct addrinfo **res)
{
    return lwip_getaddrinfo(nodename, servname, hints, res);
}

void ow_lwip_freeaddrinfo(struct addrinfo *ai)
{
    lwip_freeaddrinfo(ai);
}
