# SPDX-FileCopyrightText: 2025 OpenWiFi Project
# SPDX-License-Identifier: AGPL-3.0-only

#
# Makefile for enhanced_xpu example applications
#
# Build examples:
#   make                    # Build all examples (native)
#   make all               # Same as above
#   make clean             # Clean build artifacts
#
# Cross-compile for ARM (e.g., ZYNQ, ZynqMP):
#   make CROSS_COMPILE=arm-linux-gnueabihf-
#   make CROSS_COMPILE=aarch64-linux-gnu-
#

# Toolchain
CROSS_COMPILE ?=
CC := $(CROSS_COMPILE)gcc
AR := $(CROSS_COMPILE)ar
STRIP := $(CROSS_COMPILE)strip

# Compiler flags
CFLAGS := -Wall -Wextra -O2 -std=gnu99
CFLAGS += -I../include
CFLAGS += -D_GNU_SOURCE

# Linker flags
LDFLAGS := -lm -lpthread

# Debug build support
DEBUG ?= 0
ifeq ($(DEBUG),1)
    CFLAGS += -g -DDEBUG
    STRIP := true
else
    CFLAGS += -DNDEBUG
endif

# Targets
EXAMPLES := monitor_beacons \
            inject_beacon \
            remote_id_transmitter \
            remote_id_receiver \
            wfb_ng_injector

# Default target
all: $(EXAMPLES)

# Pattern rules
%: %.c
	@echo "  CC      $@"
	@$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@$(STRIP) $@
	@echo "  Built: $@"

# Individual targets (for dependencies)
monitor_beacons: monitor_beacons.c
inject_beacon: inject_beacon.c
remote_id_transmitter: remote_id_transmitter.c ../include/remote_id_types.h
remote_id_receiver: remote_id_receiver.c ../include/remote_id_types.h
wfb_ng_injector: wfb_ng_injector.c

# Install target
INSTALL_DIR ?= /usr/local/bin
install: $(EXAMPLES)
	@echo "Installing examples to $(INSTALL_DIR)..."
	@install -d $(INSTALL_DIR)
	@install -m 755 $(EXAMPLES) $(INSTALL_DIR)
	@echo "Installation complete."

# Uninstall target
uninstall:
	@echo "Uninstalling examples from $(INSTALL_DIR)..."
	@for prog in $(EXAMPLES); do \
		rm -f $(INSTALL_DIR)/$$prog; \
	done
	@echo "Uninstall complete."

# Clean target
clean:
	@echo "Cleaning build artifacts..."
	@rm -f $(EXAMPLES)
	@rm -f *.o
	@echo "Clean complete."

# Help target
help:
	@echo "enhanced_xpu Example Applications"
	@echo ""
	@echo "Targets:"
	@echo "  all              Build all examples (default)"
	@echo "  clean            Remove build artifacts"
	@echo "  install          Install examples to $(INSTALL_DIR)"
	@echo "  uninstall        Remove installed examples"
	@echo "  help             Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  monitor_beacons           - WiFi beacon monitor"
	@echo "  inject_beacon             - Beacon frame injector"
	@echo "  remote_id_transmitter     - Drone Remote ID transmitter"
	@echo "  remote_id_receiver        - Drone Remote ID receiver"
	@echo "  wfb_ng_injector           - wfb-ng frame injector"
	@echo ""
	@echo "Options:"
	@echo "  DEBUG=1          Build with debug symbols"
	@echo "  CROSS_COMPILE=   Cross-compile prefix (e.g., arm-linux-gnueabihf-)"
	@echo ""
	@echo "Cross-compile examples:"
	@echo "  make CROSS_COMPILE=arm-linux-gnueabihf-      # ARM 32-bit"
	@echo "  make CROSS_COMPILE=aarch64-linux-gnu-        # ARM 64-bit"

# Phony targets
.PHONY: all clean install uninstall help

# Print variables for debugging
print-%:
	@echo $* = $($*)
