OS ?= ubuntu
PLATFORM ?= x86_64
CONFIG ?= debug
D_COMPILER ?= dmd
DC ?= dmd

SRCDIR := src
TARGET_SUBDIR := $(PLATFORM)_$(CONFIG)
OBJDIR := obj/$(TARGET_SUBDIR)
TARGETDIR := bin/$(TARGET_SUBDIR)
TARGETNAME := urt

# unittest config adjustments
ifeq ($(CONFIG),unittest)
    TARGETNAME := $(TARGETNAME)_test
    BUILD_TYPE := exe
else
    BUILD_TYPE := lib
endif

DEPFILE := $(OBJDIR)/$(TARGETNAME).d

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=nosharedaccess -preview=in

SOURCES := $(shell find "$(SRCDIR)" -type f -name '*.d')

# Set target file based on build type and OS
ifeq ($(BUILD_TYPE),exe)
    BUILD_CMD_FLAGS :=
    ifeq ($(OS),windows)
        TARGET = $(TARGETDIR)/$(TARGETNAME).exe
    else
        TARGET = $(TARGETDIR)/$(TARGETNAME)
    endif
else # lib
    BUILD_CMD_FLAGS := -lib
    ifeq ($(OS),windows)
        TARGET = $(TARGETDIR)/$(TARGETNAME).lib
    else
        TARGET = $(TARGETDIR)/lib$(TARGETNAME).a
    endif
endif

ifeq ($(D_COMPILER),ldc)
    DFLAGS := $(DFLAGS) -I $(SRCDIR)

    ifeq ($(PLATFORM),x86_64)
#        DFLAGS := $(DFLAGS) -mtriple=x86_64-linux-gnu
    else ifeq ($(PLATFORM),x86)
        ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=i686-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=i686-linux-gnu
        endif
    else ifeq ($(PLATFORM),arm64)
        DFLAGS := $(DFLAGS) -mtriple=aarch64-linux-gnu
    else ifeq ($(PLATFORM),arm)
        DFLAGS := $(DFLAGS) -mtriple=arm-linux-eabihf -mcpu=cortex-a7
    else ifeq ($(PLATFORM),riscv64)
        # we are building the Sipeed M1s device... which is BL808 as I understand
        DFLAGS := $(DFLAGS) -mtriple=riscv64-unknown-elf -mcpu=c906 -mattr=+m,+a,+f,+c,+v
    else
        $(error "Unsupported platform: $(PLATFORM)")
    endif

    ifeq ($(CONFIG),release)
        DFLAGS := $(DFLAGS) -release -O3 -enable-inlining
    else
        DFLAGS := $(DFLAGS) -g -d-debug
    endif
else ifeq ($(D_COMPILER),dmd)
    DFLAGS := $(DFLAGS) -I=$(SRCDIR)

    ifeq ($(PLATFORM),x86_64)
#        DFLAGS := $(DFLAGS) -m64
    else ifeq ($(PLATFORM),x86)
        DFLAGS := $(DFLAGS) -m32
    else
        $(error "Unsupported platform: $(PLATFORM)")
    endif

    ifeq ($(CONFIG),release)
        DFLAGS := $(DFLAGS) -release -O -inline
    else
        DFLAGS := $(DFLAGS) -g -debug
    endif
else
    $(error "Unknown D compiler: $(D_COMPILER)")
endif

ifeq ($(CONFIG),unittest)
    DFLAGS := $(DFLAGS) -unittest -main
endif

-include $(DEPFILE)

$(TARGET):
	mkdir -p $(OBJDIR) $(TARGETDIR)
ifeq ($(D_COMPILER),ldc)
	"$(DC)" $(DFLAGS) $(BUILD_CMD_FLAGS) -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(SOURCES)
else ifeq ($(D_COMPILER),dmd)
ifeq ($(BUILD_TYPE),lib)
	"$(DC)" $(DFLAGS) $(BUILD_CMD_FLAGS) -of$(OBJDIR)/$(notdir $(TARGET)) -od$(OBJDIR) -makedeps $(SOURCES) > $(DEPFILE)
	mv "$(OBJDIR)/$(notdir $(TARGET))" "$(TARGETDIR)"
else # exe
	"$(DC)" $(DFLAGS) $(BUILD_CMD_FLAGS) -of$(TARGET) -od$(OBJDIR) -makedeps $(SOURCES) > $(DEPFILE)
endif
endif

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
