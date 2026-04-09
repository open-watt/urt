module urt.platform;


// TODO: I'd like to wrangle some sort of 64bit version...


// Apply stuff is all separated... but a general Darwin would be nice
version (OSX)
    version = Darwin;
version (iOS)
    version = Darwin;
version (tvOS)
    version = Darwin;
version (watchOS)
    version = Darwin;
version (visionOS)
    version = Darwin;


// Platform identity -- specific chip name where known, generic fallback otherwise

version (ESP8266)           enum string Platform = "ESP8266";
else version (ESP32)        enum string Platform = "ESP32";
else version (ESP32_S2)     enum string Platform = "ESP32-S2";
else version (ESP32_S3)     enum string Platform = "ESP32-S3";
else version (ESP32_C2)     enum string Platform = "ESP32-C2";
else version (ESP32_C3)     enum string Platform = "ESP32-C3";
else version (ESP32_C5)     enum string Platform = "ESP32-C5";
else version (ESP32_C6)     enum string Platform = "ESP32-C6";
else version (ESP32_H2)     enum string Platform = "ESP32-H2";
else version (ESP32_P4)     enum string Platform = "ESP32-P4";
else version (BL808)        enum string Platform = "BL808";
else version (BL808_M0)     enum string Platform = "BL808-M0";
else version (BL618)        enum string Platform = "BL618";
else version (BK7231N)      enum string Platform = "BK7231N";
else version (BK7231T)      enum string Platform = "BK7231T";
else version (RP2350)       enum string Platform = "RP2350";
else version (STM32F4)      enum string Platform = "STM32F4";
else version (STM32F7)      enum string Platform = "STM32F7";
else version (Windows)      enum string Platform = "Windows";
else version (linux)        enum string Platform = "Linux";
else version (Darwin)       enum string Platform = "macOS";
else version (FreeBSD)      enum string Platform = "FreeBSD";
else version (FreeRTOS)     enum string Platform = "FreeRTOS";
else version (BareMetal)    enum string Platform = "bare-metal";
else version (FreeStanding) enum string Platform = "bare-metal";
else                        enum string Platform = "unknown";
