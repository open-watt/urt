# Driver contract tests: each backend compiled on the host over its register model, running one suite.
# CI only: make -f Makefile -f test/driver/driver.mk driver-contract COMPILER=ldc
ifneq ($(filter freertos baremetal,$(OS)),)
    $(error driver contract tests require a host target)
endif
ifneq ($(COMPILER),ldc)
    $(error driver contract tests require COMPILER=ldc, for the platform section attributes)
endif

DRIVER_DIR := test/driver
DRIVER_BACKENDS := stm32f4 stm32f7 stm32h7 rp2350 bl808_m0 bl808_d0 bl618 mt7621 bk7231

DRIVER_COMMON := $(DRIVER_DIR)/contract.d $(DRIVER_DIR)/model/cpu.d $(DRIVER_DIR)/model/line.d \
    $(DRIVER_DIR)/model/volatile.d $(DRIVER_DIR)/model/alloc.d src/object.d src/core/atomic.d src/urt/package.d

DRIVER_STM32 := $(DRIVER_DIR)/stm32/package.d $(DRIVER_DIR)/stm32/irq.d $(DRIVER_DIR)/stm32/fixture.d

driver_stm32f4 := $(VERSION_FLAG)STM32 $(VERSION_FLAG)STM32F4 $(DRIVER_STM32)
driver_stm32f7 := $(VERSION_FLAG)STM32 $(VERSION_FLAG)STM32F7 $(DRIVER_STM32)
driver_stm32h7 := $(VERSION_FLAG)STM32 $(VERSION_FLAG)STM32H7 $(DRIVER_STM32)
driver_rp2350 := $(VERSION_FLAG)RP2350 $(DRIVER_DIR)/rp2350/package.d $(DRIVER_DIR)/rp2350/irq.d $(DRIVER_DIR)/rp2350/fixture.d
driver_bl808_m0 := $(VERSION_FLAG)Bouffalo $(VERSION_FLAG)BL808 $(VERSION_FLAG)BL808_M0 $(DRIVER_DIR)/bouffalo/mcu_irq.d $(DRIVER_DIR)/bouffalo/fixture.d
driver_bl808_d0 := $(VERSION_FLAG)Bouffalo $(VERSION_FLAG)BL808 $(VERSION_FLAG)BL808_D0 $(DRIVER_DIR)/bouffalo/d0_irq.d $(DRIVER_DIR)/bouffalo/fixture.d
driver_bl618 := $(VERSION_FLAG)Bouffalo $(VERSION_FLAG)BL618 $(DRIVER_DIR)/bouffalo/mcu_irq.d $(DRIVER_DIR)/bouffalo/fixture.d
driver_mt7621 := $(VERSION_FLAG)MT7621 $(DRIVER_DIR)/mt7621/package.d $(DRIVER_DIR)/mt7621/irq.d $(DRIVER_DIR)/mt7621/netcon.d $(DRIVER_DIR)/mt7621/fixture.d
driver_bk7231 := $(VERSION_FLAG)Beken $(VERSION_FLAG)BK7231 $(VERSION_FLAG)BK7231N $(DRIVER_DIR)/bk7231/alloc.d $(DRIVER_DIR)/bk7231/irq.d $(DRIVER_DIR)/bk7231/fixture.d

.PHONY: driver-contract
driver-contract:
	mkdir -p $(TARGETDIR)
	@set -e; for b in $(DRIVER_BACKENDS); do \
	    echo "=== driver contract: $$b ==="; \
	    case $$b in \
	        stm32f4)  flags='$(driver_stm32f4)' ;; \
	        stm32f7)  flags='$(driver_stm32f7)' ;; \
	        stm32h7)  flags='$(driver_stm32h7)' ;; \
	        rp2350)   flags='$(driver_rp2350)' ;; \
	        bl808_m0) flags='$(driver_bl808_m0)' ;; \
	        bl808_d0) flags='$(driver_bl808_d0)' ;; \
	        bl618)    flags='$(driver_bl618)' ;; \
	        mt7621)   flags='$(driver_mt7621)' ;; \
	        bk7231)   flags='$(driver_bk7231)' ;; \
	    esac; \
	    "$(DC)" $(filter-out -unittest,$(DFLAGS)) -i $$flags $(DRIVER_COMMON) -of$(TARGETDIR)/contract-$$b$(if $(filter windows,$(OS)),.exe) -od$(OBJDIR)/contract-$$b; \
	    ./$(TARGETDIR)/contract-$$b$(if $(filter windows,$(OS)),.exe); \
	done
