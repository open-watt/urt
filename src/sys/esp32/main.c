// OpenWatt ESP-IDF entry point.
// ESP-IDF calls app_main() after FreeRTOS scheduler starts.
// .init_array (D module constructors) are called automatically by
// ESP-IDF startup before app_main, so we just call D's main().

#include "esp_netif.h"
#include "esp_event.h"

extern int main(int argc, char **argv);

void app_main(void)
{
    // Initialize lwIP and event loop early -- D code may open sockets
    // during startup before any WiFi/Ethernet interface is created.
    esp_netif_init();
    esp_event_loop_create_default();

    main(0, (char **)0);
}
