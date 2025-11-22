# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only

##############################################################################
# Enhanced XPU Software Build System
#
# This Makefile builds the kernel driver, userspace library, and tools
# for the Enhanced XPU hardware module.
#
# Usage:
#   make                    - Build everything
#   make kernel             - Build kernel module only
#   make lib                - Build userspace library only
#   make tools              - Build command-line tools only
#   make python             - Build Python bindings only
#   make install            - Install everything
#   make clean              - Clean build artifacts
#
# Cross-compilation:
#   make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
#   make KERNEL_SRC=/path/to/kernel/source
#
##############################################################################

# Detect build environment
ARCH ?= $(shell uname -m)
CROSS_COMPILE ?=

# Kernel build settings
KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
KERNEL_MODULE = driver/enhanced_xpu.ko

# Compiler settings
CC := $(CROSS_COMPILE)gcc
AR := $(CROSS_COMPILE)ar
LD := $(CROSS_COMPILE)ld

# Build flags
CFLAGS := -Wall -Wextra -O2 -fPIC
CFLAGS += -I$(PWD)/include -I$(PWD)/driver
LDFLAGS := -lpthread -lm -lpcap

# Library settings
LIB_NAME = libenhanced_xpu
LIB_STATIC = lib/$(LIB_NAME).a
LIB_SHARED = lib/$(LIB_NAME).so
LIB_VERSION = 1.0.0

# Source files
LIB_SRCS = lib/libenhanced_xpu.c lib/remote_id_codec.c
LIB_OBJS = $(LIB_SRCS:.c=.o)

TOOL_SRCS = tools/xpu_mon.c tools/xpu_inject.c tools/xpu_remote_id.c
TOOL_BINS = $(TOOL_SRCS:.c=)

# Installation paths
PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
INCLUDEDIR = $(PREFIX)/include
MODULEDIR = /lib/modules/$(shell uname -r)/extra

# Python settings
PYTHON ?= python3
PYTHON_SETUP = python/setup.py

##############################################################################
# Build Targets
##############################################################################

.PHONY: all kernel lib tools python clean install help

all: kernel lib tools
	@echo ""
	@echo "=== Build Complete ==="
	@echo "Kernel module: $(KERNEL_MODULE)"
	@echo "Library: $(LIB_STATIC) $(LIB_SHARED)"
	@echo "Tools: $(TOOL_BINS)"
	@echo ""
	@echo "To install: sudo make install"

##############################################################################
# Kernel Module
##############################################################################

kernel: $(KERNEL_MODULE)

$(KERNEL_MODULE): driver/enhanced_xpu_drv.c driver/enhanced_xpu_ioctl.h
	@echo "Building kernel module..."
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD)/driver \
		ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
		modules
	@echo "Kernel module built: $@"

driver/Module.symvers driver/modules.order: $(KERNEL_MODULE)

##############################################################################
# Userspace Library
##############################################################################

lib: $(LIB_STATIC) $(LIB_SHARED)

$(LIB_STATIC): $(LIB_OBJS)
	@echo "Creating static library: $@"
	@mkdir -p $(dir $@)
	$(AR) rcs $@ $^

$(LIB_SHARED): $(LIB_OBJS)
	@echo "Creating shared library: $@"
	@mkdir -p $(dir $@)
	$(CC) -shared -Wl,-soname,$(LIB_NAME).so.1 -o $@.$(LIB_VERSION) $^ $(LDFLAGS)
	@cd $(dir $@) && ln -sf $(notdir $@).$(LIB_VERSION) $(notdir $@).1
	@cd $(dir $@) && ln -sf $(notdir $@).1 $(notdir $@)

lib/%.o: lib/%.c
	@echo "Compiling: $<"
	$(CC) $(CFLAGS) -c $< -o $@

##############################################################################
# Command-Line Tools
##############################################################################

tools: $(TOOL_BINS)

tools/xpu_mon: tools/xpu_mon.c $(LIB_STATIC)
	@echo "Building: $@"
	$(CC) $(CFLAGS) $< -o $@ -L./lib -lenhanced_xpu $(LDFLAGS)

tools/xpu_inject: tools/xpu_inject.c $(LIB_STATIC)
	@echo "Building: $@"
	$(CC) $(CFLAGS) $< -o $@ -L./lib -lenhanced_xpu $(LDFLAGS)

tools/xpu_remote_id: tools/xpu_remote_id.c $(LIB_STATIC)
	@echo "Building: $@"
	$(CC) $(CFLAGS) $< -o $@ -L./lib -lenhanced_xpu $(LDFLAGS)

##############################################################################
# Python Bindings
##############################################################################

python: python/enhanced_xpu.py
	@echo "Python bindings ready (no build required)"
	@echo "To install: cd python && sudo $(PYTHON) setup.py install"

##############################################################################
# Installation
##############################################################################

install: install-kernel install-lib install-tools install-headers
	@echo ""
	@echo "=== Installation Complete ==="
	@echo "Kernel module installed to: $(MODULEDIR)"
	@echo "Library installed to: $(LIBDIR)"
	@echo "Tools installed to: $(BINDIR)"
	@echo "Headers installed to: $(INCLUDEDIR)"
	@echo ""
	@echo "Load kernel module: sudo modprobe enhanced_xpu"
	@echo "Or: sudo insmod $(MODULEDIR)/enhanced_xpu.ko"

install-kernel: $(KERNEL_MODULE)
	@echo "Installing kernel module..."
	install -d $(MODULEDIR)
	install -m 644 $(KERNEL_MODULE) $(MODULEDIR)/
	depmod -a

install-lib: $(LIB_STATIC) $(LIB_SHARED)
	@echo "Installing library..."
	install -d $(LIBDIR)
	install -m 644 $(LIB_STATIC) $(LIBDIR)/
	install -m 755 $(LIB_SHARED).$(LIB_VERSION) $(LIBDIR)/
	cd $(LIBDIR) && ln -sf $(LIB_NAME).so.$(LIB_VERSION) $(LIB_NAME).so.1
	cd $(LIBDIR) && ln -sf $(LIB_NAME).so.1 $(LIB_NAME).so
	ldconfig

install-tools: $(TOOL_BINS)
	@echo "Installing tools..."
	install -d $(BINDIR)
	install -m 755 tools/xpu_mon $(BINDIR)/
	install -m 755 tools/xpu_inject $(BINDIR)/
	install -m 755 tools/xpu_remote_id $(BINDIR)/

install-headers:
	@echo "Installing headers..."
	install -d $(INCLUDEDIR)/enhanced_xpu
	install -m 644 lib/libenhanced_xpu.h $(INCLUDEDIR)/enhanced_xpu/
	install -m 644 include/remote_id_types.h $(INCLUDEDIR)/enhanced_xpu/
	install -m 644 driver/enhanced_xpu_ioctl.h $(INCLUDEDIR)/enhanced_xpu/

install-python: python/enhanced_xpu.py
	@echo "Installing Python bindings..."
	cd python && $(PYTHON) setup.py install

##############################################################################
# Uninstallation
##############################################################################

uninstall:
	@echo "Uninstalling Enhanced XPU..."
	rm -f $(MODULEDIR)/enhanced_xpu.ko
	rm -f $(LIBDIR)/$(LIB_NAME).*
	rm -f $(BINDIR)/xpu_mon
	rm -f $(BINDIR)/xpu_inject
	rm -f $(BINDIR)/xpu_remote_id
	rm -rf $(INCLUDEDIR)/enhanced_xpu
	depmod -a
	ldconfig
	@echo "Uninstallation complete"

##############################################################################
# Cleaning
##############################################################################

clean:
	@echo "Cleaning build artifacts..."
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD)/driver clean 2>/dev/null || true
	rm -f $(LIB_OBJS)
	rm -f $(LIB_STATIC)
	rm -f $(LIB_SHARED)*
	rm -f $(TOOL_BINS)
	rm -f lib/*.o driver/*.o
	rm -f driver/*.mod.c driver/*.mod driver/*.mod.o
	rm -f driver/Module.symvers driver/modules.order
	rm -rf driver/.tmp_versions
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -delete
	@echo "Clean complete"

##############################################################################
# Testing
##############################################################################

test: all
	@echo "Running tests..."
	@echo "TODO: Implement automated tests"

##############################################################################
# Documentation
##############################################################################

docs:
	@echo "Generating documentation..."
	doxygen Doxyfile 2>/dev/null || echo "Doxygen not installed"

##############################################################################
# Kernel Module Makefile (for kernel build system)
##############################################################################

# Create Kbuild file for kernel module
driver/Kbuild:
	@echo "obj-m := enhanced_xpu.o" > $@
	@echo "enhanced_xpu-objs := enhanced_xpu_drv.o" >> $@

##############################################################################
# Help
##############################################################################

help:
	@echo "Enhanced XPU Build System"
	@echo "========================="
	@echo ""
	@echo "Targets:"
	@echo "  all                Build everything (default)"
	@echo "  kernel             Build kernel module"
	@echo "  lib                Build userspace library"
	@echo "  tools              Build command-line tools"
	@echo "  python             Prepare Python bindings"
	@echo "  install            Install all components"
	@echo "  uninstall          Remove all installed components"
	@echo "  clean              Clean build artifacts"
	@echo "  test               Run tests"
	@echo "  docs               Generate documentation"
	@echo "  help               Show this help"
	@echo ""
	@echo "Variables:"
	@echo "  ARCH               Target architecture (default: auto)"
	@echo "  CROSS_COMPILE      Cross-compiler prefix"
	@echo "  KERNEL_SRC         Kernel source directory"
	@echo "  PREFIX             Installation prefix (default: /usr/local)"
	@echo ""
	@echo "Examples:"
	@echo "  make                                    # Build for current system"
	@echo "  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-"
	@echo "  make KERNEL_SRC=/path/to/kernel"
	@echo "  sudo make install                       # Install everything"

##############################################################################
# Dependencies
##############################################################################

# Auto-generate dependencies for library
lib/libenhanced_xpu.o: lib/libenhanced_xpu.c lib/libenhanced_xpu.h \
                        driver/enhanced_xpu_ioctl.h include/remote_id_types.h

lib/remote_id_codec.o: lib/remote_id_codec.c include/remote_id_types.h

tools/xpu_mon.o: tools/xpu_mon.c lib/libenhanced_xpu.h
tools/xpu_inject.o: tools/xpu_inject.c lib/libenhanced_xpu.h
tools/xpu_remote_id.o: tools/xpu_remote_id.c lib/libenhanced_xpu.h \
                        include/remote_id_types.h

.DEFAULT_GOAL := all
