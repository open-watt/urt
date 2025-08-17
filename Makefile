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
DEPFILE := $(OBJDIR)/$(TARGETNAME).d

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=nosharedaccess -preview=in

ifeq ($(OS),windows)
SOURCES := $(shell dir /s /b $(SRCDIR)\\*.d)
else
SOURCES := $(shell find "$(SRCDIR)" -type f -name '*.d')
endif

ifeq ($(OS),windows)
    TARGET = $(TARGETDIR)/$(TARGETNAME).lib
else
    TARGET = $(TARGETDIR)/lib$(TARGETNAME).a
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
    DFLAGS := $(DFLAGS) -unittest
    TARGETNAME := $(TARGETNAME)_test
endif

-include $(DEPFILE)

$(TARGET):
ifeq ($(OS),windows)
	@if not exist "obj" mkdir "obj" > nul 2>&1
	@if not exist "$(subst /,\,$(OBJDIR))" mkdir "$(subst /,\,$(OBJDIR))" > nul 2>&1
	@if not exist "bin" mkdir "bin" > nul 2>&1
	@if not exist "$(subst /,\,$(TARGETDIR))" mkdir "$(subst /,\,$(TARGETDIR))" > nul 2>&1
else
	mkdir -p $(OBJDIR) $(TARGETDIR)
endif
ifeq ($(D_COMPILER),ldc)
	"$(DC)" $(DFLAGS) -lib -of$(TARGET) -od$(OBJDIR) -deps=$(DEPFILE) $(SOURCES)
else ifeq ($(D_COMPILER),dmd)
	"$(DC)" $(DFLAGS) -lib -of$(notdir $(TARGET)) -od$(OBJDIR) -makedeps $(SOURCES) > $(DEPFILE)
ifeq ($(OS),windows)
	move "$(subst /,\,$(OBJDIR))\\$(notdir $(TARGET))" "$(subst /,\,$(TARGETDIR))" > nul
else
	mv "$(OBJDIR)/$(notdir $(TARGET))" "$(TARGETDIR)"
endif
endif

clean:
	rm -rf $(OBJDIR) $(TARGETDIR)
