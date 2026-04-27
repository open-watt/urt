URT_SRCDIR := src

include platforms.mk

# =======================================================================
# Build mode
#
# Host (windows/linux/freebsd):
#   default        -> static lib (liburt.a / urt.lib)
#   CONFIG=unittest -> standalone test exe
#
# Cross (freertos/baremetal):
#   CONFIG=unittest -> flashable test image (.bin via objcopy), using URT's
#                     in-tree linker script (platforms/<chip>/<chip>.ld)
#   default         -> compile-only (.o for non-ESP, .bc for ESP)
#   ESP             -> always .bc, no link possible without ESP-IDF
# =======================================================================

OBJDIR    := obj/$(BUILDNAME)_$(CONFIG)
TARGETDIR := bin/$(BUILDNAME)_$(CONFIG)

# =======================================================================
# GDC ImportC: GDC's ImportC does not preprocess #include directives, so
# any *.c the D side imports (urt.internal.os, urt.internal.mbedtls, ...)
# must be preprocessed to *.i first via the host C compiler. We stage
# them in $(OBJDIR)/imports/ and prepend that to the import path so GDC
# resolves urt.internal.os to os.i instead of os.c.
# =======================================================================
ifeq ($(COMPILER),gdc)
GDC_I_DIR := $(OBJDIR)/imports
URT_C_FILES := $(shell find "$(URT_SRCDIR)" -type f -name '*.c' -not -path '$(URT_SRCDIR)/urt/driver/*')
URT_I_FILES := $(patsubst $(URT_SRCDIR)/%.c,$(GDC_I_DIR)/%.i,$(URT_C_FILES))
URT_SOURCES := $(patsubst $(URT_SRCDIR)/%.c,$(GDC_I_DIR)/%.i,$(URT_SOURCES))
DFLAGS := -I $(GDC_I_DIR) $(DFLAGS)

$(GDC_I_DIR)/%.i: $(URT_SRCDIR)/%.c
	@mkdir -p $(@D)
	gcc -E -P -o $@ $<
endif

# Linker script selection for cross-target unittest builds (ESP excluded --
# no ESP-IDF on build slave). platforms.mk falls back to compile-only when
# BAREMETAL_LD isn't set.
ifeq ($(CONFIG),unittest)
  ifeq ($(PLATFORM),bl808)
    ifeq ($(PROCESSOR),c906)
      BAREMETAL_LD := platforms/bl808/bl808_d0.ld
    else ifeq ($(PROCESSOR),e907)
      BAREMETAL_LD := platforms/bl808/bl808_m0.ld
    endif
  else ifeq ($(PLATFORM),bl618)
    BAREMETAL_LD := platforms/bl618/bl618.ld
  else ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    BAREMETAL_LD := platforms/bk7231/$(PLATFORM).ld
  else ifeq ($(PLATFORM),rp2350)
    BAREMETAL_LD := platforms/rp2350/rp2350.ld
  else ifdef STM32_VARIANT
    BAREMETAL_LD := platforms/stm32/stm32_$(STM32_VARIANT).ld
  endif
  ifdef BAREMETAL_LD
    DFLAGS := $(DFLAGS) -L-T$(BAREMETAL_LD) -main
  endif
endif

# Resolve build mode + target file
ifneq ($(filter freertos baremetal,$(OS)),)
  ifdef BAREMETAL_LD
    BUILD_MODE := embedded-exe
    TARGETNAME := urt_test
    TARGET     := $(TARGETDIR)/$(TARGETNAME)
    BUILD_CMD_FLAGS :=
  else ifeq ($(ARCH),xtensa)
    # Xtensa: bitcode for downstream Espressif llc / ESP-IDF
    BUILD_MODE := bitcode
    TARGETNAME := urt$(if $(filter unittest,$(CONFIG)),_test)
    TARGET     := $(OBJDIR)/$(TARGETNAME).bc
    BUILD_CMD_FLAGS :=
  else
    # No linker script + non-Xtensa cross: compile-only object
    BUILD_MODE := compile-only
    TARGETNAME := urt$(if $(filter unittest,$(CONFIG)),_test)
    TARGET     := $(OBJDIR)/$(TARGETNAME).o
    BUILD_CMD_FLAGS :=
  endif
else ifeq ($(CONFIG),unittest)
  BUILD_MODE := exe
  TARGETNAME := urt_test
  BUILD_CMD_FLAGS := -main
  ifeq ($(OS),windows)
    TARGET := $(TARGETDIR)/$(TARGETNAME).exe
  else
    TARGET := $(TARGETDIR)/$(TARGETNAME)
  endif
else
  BUILD_MODE := lib
  TARGETNAME := urt
  BUILD_CMD_FLAGS := -lib
  ifeq ($(OS),windows)
    TARGET := $(TARGETDIR)/$(TARGETNAME).lib
  else
    TARGET := $(TARGETDIR)/lib$(TARGETNAME).a
  endif
endif

DEPFILE := $(OBJDIR)/$(TARGETNAME).d

# objcopy for embedded-exe -> .bin (derive from cross-gcc path)
ifeq ($(BUILD_MODE),embedded-exe)
  ifneq ($(filter arm thumb,$(ARCH)),)
    BAREMETAL_OBJCOPY := arm-none-eabi-objcopy
    OBJCOPY_FLAGS     := -R .bss -R .tbss -R '.tbss.*' -R .ARM.attributes -R '.debug*'
  else
    BAREMETAL_OBJCOPY := riscv64-unknown-elf-objcopy
    OBJCOPY_FLAGS     :=
  endif

  BAREMETAL_OBJS   := $(patsubst %.S,$(OBJDIR)/%.o,$(patsubst %.c,$(OBJDIR)/%.o,$(BAREMETAL_SRCS)))
  BAREMETAL_CFLAGS := $(BAREMETAL_CFLAGS) -ffreestanding -O2

$(OBJDIR)/%.o: $(BAREMETAL_DIR)/%.S
	@mkdir -p $(OBJDIR)
	$(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) -c -o $@ $<

$(OBJDIR)/%.o: $(BAREMETAL_DIR)/%.c
	@mkdir -p $(OBJDIR)
	$(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) -c -o $@ $<
endif

# =======================================================================
# Build rule
# =======================================================================

$(TARGET): $(BAREMETAL_OBJS) $(URT_I_FILES)
	mkdir -p $(OBJDIR) $(TARGETDIR)
ifeq ($(COMPILER),ldc)
	"$(DC)" $(DFLAGS) $(BUILD_CMD_FLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(BAREMETAL_OBJS) $(URT_SOURCES)
else ifeq ($(COMPILER),dmd)
ifeq ($(BUILD_MODE),lib)
	"$(DC)" $(DFLAGS) $(BUILD_CMD_FLAGS) -of$(OBJDIR)/$(notdir $(TARGET)) -od$(OBJDIR) -makedeps $(URT_SOURCES) > $(DEPFILE)
	mv "$(OBJDIR)/$(notdir $(TARGET))" "$(TARGETDIR)"
else
	"$(DC)" $(DFLAGS) $(BUILD_CMD_FLAGS) -of$(TARGET) -od$(OBJDIR) -makedeps $(URT_SOURCES) > $(DEPFILE)
endif
else ifeq ($(COMPILER),gdc)
ifeq ($(BUILD_MODE),lib)
	"$(DC)" $(DFLAGS) -c -o $(OBJDIR)/urt.o $(URT_SOURCES)
	$(AR) rcs $(TARGET) $(OBJDIR)/urt.o
else
	"$(DC)" $(DFLAGS) -o $(TARGET) $(URT_SOURCES)
endif
endif
ifeq ($(BUILD_MODE),embedded-exe)
	$(BAREMETAL_OBJCOPY) -O binary $(OBJCOPY_FLAGS) $(TARGET) $(TARGETDIR)/$(TARGETNAME).bin
endif

# =======================================================================
# CI: build the full cross-target matrix
#
# Embedded targets produce flashable urt_test images (.bin); ESP variants
# produce LLVM bitcode (no ESP-IDF on build slave). Catches submodule-bump
# breakage before downstream projects update.
# =======================================================================

CI_PLATFORMS := \
    esp32 esp32-s2 esp32-s3 esp32-c2 esp32-c3 esp32-c5 esp32-c6 esp32-h2 esp32-p4 \
    bl618 bk7231n bk7231t rp2350 stm4xx stm7xx bl808-d0 bl808-m0

.PHONY: ci-build
ci-build:
	@set -e; for p in $(CI_PLATFORMS); do \
	    case $$p in \
	        bl808-d0) args="PLATFORM=bl808 PROCESSOR=c906" ;; \
	        bl808-m0) args="PLATFORM=bl808 PROCESSOR=e907" ;; \
	        *)        args="PLATFORM=$$p" ;; \
	    esac; \
	    echo "=== ci-build: $$p ($$args) ==="; \
	    $(MAKE) --no-print-directory $$args CONFIG=unittest || exit 1; \
	done
	@echo ""
	@echo "=== ci-build complete ==="
	@find bin obj -type f \( -name 'urt_test*.bin' -o -name 'urt_test*.bc' -o -name 'urt_test*.o' \) 2>/dev/null | sort

# =======================================================================
# Clean
# =======================================================================

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)

clean-all:
	rm -rf obj bin
