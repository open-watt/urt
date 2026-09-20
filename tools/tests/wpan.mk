# Host regression tests with a fake IDF backend:
# make -f Makefile -f tools/tests/wpan.mk CONFIG=unittest
ifneq ($(filter freertos baremetal,$(OS)),)
    $(error WPAN fake-backend tests require a host target)
endif
DFLAGS += $(VERSION_FLAG)ESP32_C5
URT_SOURCES += src/urt/driver/esp32/wpan.d tools/tests/wpan.d
$(TARGET): src/urt/driver/esp32/wpan.d tools/tests/wpan.d tools/tests/wpan.mk
