#include <stdarg.h>
#include <stdio.h>

void sta_ip_start(void) {}
void sta_ip_down(void) {}
void uap_ip_down(void) {}
void net_wlan_remove_netif(void *mac) { (void)mac; }

extern void bk_send_string(unsigned char uport, const char *string);
extern unsigned char get_printf_port(void);
int __wrap_printf(const char *fmt, ...)
{
    char buf[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    bk_send_string(get_printf_port(), buf);
    return n;
}

extern void ow_log_vendor(const char *msg, unsigned len);
void __wrap_bk_printf(const char *fmt, ...)
{
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0)
        ow_log_vendor(buf, n < (int)sizeof(buf) ? n : (int)sizeof(buf) - 1);
}
