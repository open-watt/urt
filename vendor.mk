# Bouffalo vendor C deps (tlsf, mbedtls, BL808 M0 wifi/psram). Included via
# platforms.mk so consumers inherit the paths, object lists, compile rules and
# -L/-I without duplicating them. URT_ROOT resolves the trees whether make runs
# from the URT root or a consumer root. OBJDIR comes from the consumer, hence
# the deferred (=) object lists.

ifneq ($(filter bl808 bl618,$(PLATFORM)),)

BL_TLSF_DIR  := $(URT_ROOT)third_party/tlsf
BL_TLSF_SRCS := $(BL_TLSF_DIR)/tlsf.c

# rv32 cores (BL618 + BL808 M0) share the BL618 .a; rv64 D0 uses its own. Key
# on ARCH so a defaulted PROCESSOR can't pick the wrong-width archive.
ifeq ($(USE_MBEDTLS),1)
  MBEDTLS_INC := $(URT_ROOT)third_party/mbedtls/include
  ifeq ($(ARCH),riscv)
    MBEDTLS_LIB := $(URT_ROOT)platforms/bl618/lib/libmbedtls.a
  else
    MBEDTLS_LIB := $(URT_ROOT)platforms/bl808/lib/libmbedtls.a
  endif
  DFLAGS := $(DFLAGS) -L$(MBEDTLS_LIB)
endif

ifeq ($(BUILDNAME),bl808-m0)
  BL_WIFI_DIR  := $(URT_ROOT)platforms/bl808_m0/vendor/wifi
  BL_WIFI_INC  := $(BL_WIFI_DIR)/include
  BL_WIFI_SRCS := $(wildcard $(BL_WIFI_DIR)/src/*.c)
  BL_WIFI_LIBS := $(BL_WIFI_DIR)/lib/libwifi.a $(BL_WIFI_DIR)/lib/libbl606p_phyrf.a
  DFLAGS := $(DFLAGS) $(addprefix -L,$(BL_WIFI_LIBS))

  BL_PSRAM_DIR  := $(URT_ROOT)platforms/bl808_m0/vendor/psram
  BL_PSRAM_INC  := $(BL_PSRAM_DIR)/include
  BL_PSRAM_SRCS := $(wildcard $(BL_PSRAM_DIR)/src/*.c)
endif

# BAREMETAL_SPECS routes a bare cross-gcc to picolibc's hosted headers.
ifdef BL_TLSF_DIR
  BL_TLSF_OBJS    = $(patsubst $(BL_TLSF_DIR)/%.c,$(OBJDIR)/bl_tlsf/%.o,$(BL_TLSF_SRCS))
  BL_TLSF_CFLAGS := $(BAREMETAL_CFLAGS) $(BAREMETAL_SPECS) -ffreestanding -Os -DNDEBUG -fcommon -include $(BL_TLSF_DIR)/tlsf_silent.h
endif

ifdef BL_WIFI_DIR
  BL_WIFI_OBJS    = $(patsubst $(BL_WIFI_DIR)/src/%.c,$(OBJDIR)/bl_wifi/%.o,$(BL_WIFI_SRCS))
  # -fshort-enums: libwifi.a uses packed enums; lmac_msg's header is 8 bytes
  # only with it -- otherwise the blob reads dest/src at the wrong offsets.
  BL_WIFI_CFLAGS := $(BAREMETAL_CFLAGS) $(BAREMETAL_SPECS) -ffreestanding -Os \
      -I$(BL_WIFI_INC) -I$(BL_WIFI_INC)/bl_os_adapter \
      -DCFG_CHIP_BL808 -DCFG_TXDESC=4 -DCFG_STA_MAX=5 \
      -fcommon -fshort-enums
endif

ifdef BL_PSRAM_DIR
  BL_PSRAM_OBJS    = $(patsubst $(BL_PSRAM_DIR)/src/%.c,$(OBJDIR)/bl_psram/%.o,$(BL_PSRAM_SRCS))
  BL_PSRAM_CFLAGS := $(BAREMETAL_CFLAGS) $(BAREMETAL_SPECS) -ffreestanding -Os \
      -I$(BL_PSRAM_INC) -DBL808 -DARCH_RISCV -fcommon
endif

ifdef MBEDTLS_LIB
  MBEDTLS_SHIM_SRC := $(URT_SRCDIR)/urt/internal/mbedtls.c
  MBEDTLS_OBJS      = $(OBJDIR)/mbedtls/$(notdir $(MBEDTLS_SHIM_SRC:.c=.o))
  MBEDTLS_CFLAGS   := $(BAREMETAL_CFLAGS) $(BAREMETAL_SPECS) -ffreestanding -Oz \
      -ffunction-sections -fdata-sections \
      -I$(MBEDTLS_INC) -DMBEDTLS_CONFIG_FILE='"mbedtls_config_openwatt.h"' -fcommon
endif

ifdef BL_TLSF_DIR
$(OBJDIR)/bl_tlsf/%.o: $(BL_TLSF_DIR)/%.c
	@mkdir -p $(OBJDIR)/bl_tlsf
	$(BAREMETAL_GCC) $(BL_TLSF_CFLAGS) -c -o $@ $<
endif

ifdef BL_WIFI_DIR
$(OBJDIR)/bl_wifi/%.o: $(BL_WIFI_DIR)/src/%.c
	@mkdir -p $(OBJDIR)/bl_wifi
	$(BAREMETAL_GCC) $(BL_WIFI_CFLAGS) -c -o $@ $<
endif

ifdef BL_PSRAM_DIR
$(OBJDIR)/bl_psram/%.o: $(BL_PSRAM_DIR)/src/%.c
	@mkdir -p $(OBJDIR)/bl_psram
	$(BAREMETAL_GCC) $(BL_PSRAM_CFLAGS) -c -o $@ $<
endif

ifdef MBEDTLS_LIB
$(OBJDIR)/mbedtls/%.o: $(dir $(MBEDTLS_SHIM_SRC))%.c
	@mkdir -p $(OBJDIR)/mbedtls
	$(BAREMETAL_GCC) $(MBEDTLS_CFLAGS) -c -o $@ $<
endif

# Single aggregate for consumers to link; the per-blob lists above are private.
VENDOR_OBJS = $(BL_TLSF_OBJS) $(BL_WIFI_OBJS) $(BL_PSRAM_OBJS) $(MBEDTLS_OBJS)

endif
