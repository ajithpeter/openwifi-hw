# Enhanced XPU Build Instructions for antsdr

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Detailed Build Steps](#detailed-build-steps)
5. [Build Configuration Options](#build-configuration-options)
6. [Loading Bitstream to antsdr](#loading-bitstream-to-antsdr)
7. [Verification](#verification)
8. [Troubleshooting](#troubleshooting)
9. [Advanced Configuration](#advanced-configuration)

---

## Overview

This guide explains how to build the Enhanced XPU IP core with drone Remote ID and monitor mode support for the **antsdr** SDR platform (Zynq7020 + AD9361).

### What Gets Built:
- **Enhanced XPU** IP core with:
  - Monitor mode packet filtering
  - WiFi Aware (NAN) action frame parsing
  - Drone Remote ID detection (ASTM F3411)
  - Vendor IE parsing for beacons
  - Optional frame injection for testing

### Target Platform:
- **Board**: antsdr / antsdr_e200
- **FPGA**: Xilinx Zynq7020 (xc7z020clg400-1)
- **RF Chip**: Analog Devices AD9361
- **Resources**: See [RESOURCE_ESTIMATES.md](./RESOURCE_ESTIMATES.md)

---

## Prerequisites

### Required Software

1. **Xilinx Vivado** (tested with 2019.1, should work with 2018.3-2022.2)
   - Download from: https://www.xilinx.com/support/download.html
   - Free WebPACK edition is sufficient
   - Ensure Zynq7000 device support is installed

2. **Bash shell** (Linux/macOS native, Windows via WSL2 or Git Bash)

3. **GNU Make** (optional, for integrated builds)

### Required Files

Ensure you have the complete openwifi-hw repository:
```bash
cd /path/to/openwifi-hw
git status  # Should show clean working directory
```

Required directory structure:
```
openwifi-hw/
├── ip/
│   ├── xpu/                  # Base XPU IP core
│   │   └── src/
│   │       ├── xpu.v
│   │       ├── tx_control.v
│   │       └── ...
│   └── enhanced_xpu/         # Enhanced XPU (this module)
│       ├── src/
│       │   ├── enhanced_xpu_wrapper.v
│       │   ├── enhanced_pkt_filter.v
│       │   ├── nan_action_handler.v
│       │   ├── remote_id_codec.v
│       │   ├── vendor_ie_codec.v
│       │   └── frame_injection_ctrl.v
│       ├── component.xml
│       ├── build_antsdr.sh
│       └── BUILD_INSTRUCTIONS.md (this file)
└── boards/
    └── antsdr/
        ├── set_files.tcl
        └── synth_impl_strategy.tcl
```

### System Requirements

- **RAM**: 16 GB minimum, 32 GB recommended
- **Disk**: 50 GB free space for Vivado + build artifacts
- **CPU**: Multi-core processor (4+ cores recommended)
- **OS**: Linux (Ubuntu 20.04/22.04 recommended), Windows 10/11 with WSL2

---

## Quick Start

For those familiar with Vivado builds:

```bash
# 1. Navigate to enhanced_xpu directory
cd openwifi-hw/ip/enhanced_xpu

# 2. Source Vivado settings
source /opt/Xilinx/Vivado/2019.1/settings64.sh

# 3. Run build script
./build_antsdr.sh

# 4. Wait ~40-65 minutes for completion

# 5. Find bitstream at:
# build_antsdr/bitstream/enhanced_xpu_antsdr.bit
```

---

## Detailed Build Steps

### Step 1: Setup Environment

1. **Source Vivado settings:**
   ```bash
   source /path/to/Vivado/2019.1/settings64.sh
   ```

2. **Verify Vivado is in PATH:**
   ```bash
   vivado -version
   # Should output: Vivado v2019.1 (64-bit) ...
   ```

3. **Navigate to build directory:**
   ```bash
   cd /home/user/openwifi-hw/ip/enhanced_xpu
   ```

### Step 2: Choose Build Configuration

#### Option A: RX-Only Build (Recommended)
```bash
# Monitor mode + Remote ID detection only
# Resource usage: ~51% LUTs
# Build time: ~40 minutes
./build_antsdr.sh
```

#### Option B: Full Build (with Frame Injection)
```bash
# Includes frame injection controller
# Resource usage: ~55% LUTs
# Build time: ~50 minutes
./build_antsdr.sh --full
```

#### Option C: Synthesis Only (for quick verification)
```bash
# Run synthesis only, skip implementation
# Build time: ~15 minutes
./build_antsdr.sh --synth-only
```

### Step 3: Monitor Build Progress

The script will display progress through these phases:

1. **Project Setup** (~1 min)
   - Creating build directory
   - Adding source files
   - Setting constraints

2. **Synthesis** (~15-25 min)
   - Elaborating design
   - Optimizing logic
   - Generating utilization report

3. **Implementation** (~20-35 min)
   - Placement
   - Routing
   - Physical optimization
   - Post-route optimization

4. **Bitstream Generation** (~5 min)
   - Writing bitstream file
   - Generating reports

### Step 4: Review Build Results

After successful build, check these files:

```bash
# Synthesis utilization report
cat build_antsdr/synth_reports/utilization_synth.rpt

# Implementation timing report
cat build_antsdr/impl_reports/timing_impl.rpt

# Final bitstream
ls -lh build_antsdr/bitstream/enhanced_xpu_antsdr.bit
```

**Expected bitstream size**: ~3.5 MB

**Key metrics to verify**:
- LUT utilization: 50-56%
- Timing slack (WNS): > 0 ns (positive slack)
- No critical warnings in DRC report

---

## Build Configuration Options

### Command Line Options

```bash
./build_antsdr.sh [OPTIONS]

Options:
  -c, --clean           Clean previous build before starting
  -s, --synth-only      Run synthesis only, skip implementation
  -g, --gui             Open Vivado GUI after build
  -j, --jobs N          Number of parallel jobs (default: 4)
  -h, --help            Show help message
```

### Examples:

```bash
# Clean build from scratch
./build_antsdr.sh --clean

# Build with GUI (for debugging)
./build_antsdr.sh --gui

# Fast build with 8 parallel jobs
./build_antsdr.sh --jobs 8

# Synthesis-only for quick RTL check
./build_antsdr.sh --synth-only --jobs 8
```

### Build Variants

You can modify `build_antsdr.sh` to create custom builds:

**Disable frame injection** (saves ~2,500 LUTs + 8 BRAM):
- Comment out `frame_injection_ctrl.v` in TCL script
- Remove instantiation in `enhanced_xpu_wrapper.v`

**Optimize for timing**:
- Increase implementation effort in TCL
- Enable retiming and register balancing

---

## Loading Bitstream to antsdr

### Method 1: Using JTAG (Recommended for Testing)

1. **Connect JTAG cable** to antsdr JTAG header

2. **Open Vivado Hardware Manager:**
   ```bash
   vivado -mode tcl
   open_hw_manager
   connect_hw_server
   open_hw_target
   ```

3. **Program device:**
   ```tcl
   set_property PROGRAM.FILE {/path/to/enhanced_xpu_antsdr.bit} [get_hw_devices xc7z020_1]
   program_hw_devices [get_hw_devices xc7z020_1]
   ```

4. **Verify programming:**
   ```tcl
   refresh_hw_device [get_hw_devices xc7z020_1]
   # Check DONE LED on board
   ```

### Method 2: SD Card Boot (Persistent)

1. **Copy bitstream to BOOT partition:**
   ```bash
   cp build_antsdr/bitstream/enhanced_xpu_antsdr.bit /media/BOOT/system.bit
   ```

2. **Update BOOT.BIN** with new bitstream:
   ```bash
   cd /path/to/antsdr-fw
   ./scripts/create_boot_bin.sh system.bit
   ```

3. **Eject SD card and boot antsdr**

### Method 3: Remote Update via SSH

1. **Copy bitstream to running antsdr:**
   ```bash
   scp build_antsdr/bitstream/enhanced_xpu_antsdr.bit root@antsdr-ip:/tmp/
   ```

2. **Program FPGA remotely:**
   ```bash
   ssh root@antsdr-ip
   cat /tmp/enhanced_xpu_antsdr.bit > /dev/xdevcfg
   ```

3. **Verify FPGA version:**
   ```bash
   devmem 0x43C0013C  # Read FPGA version register
   # Should return build timestamp
   ```

---

## Verification

### Hardware Verification

1. **Check FPGA configuration:**
   ```bash
   ssh root@antsdr-ip
   dmesg | grep xdevcfg
   # Should show successful FPGA configuration
   ```

2. **Verify enhanced XPU registers:**
   ```bash
   # Read enhanced control register (should be accessible)
   devmem 0x83C00000
   
   # Enable monitor mode
   devmem 0x83C00000 32 0x00000001
   
   # Check status register
   devmem 0x83C00004
   ```

3. **Test monitor mode:**
   ```bash
   # Start monitor mode capture
   iw dev wlan0 set type monitor
   iw dev wlan0 set channel 6
   ifconfig wlan0 up
   
   # Capture packets
   tcpdump -i wlan0 -n
   # Should see WiFi beacon frames
   ```

### Software Verification

Create test program to access enhanced features:

```c
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <sys/mman.h>

#define ENHANCED_XPU_BASE 0x83C00000
#define MAP_SIZE 4096

int main() {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    void *map = mmap(0, MAP_SIZE, PROT_READ | PROT_WRITE, 
                     MAP_SHARED, fd, ENHANCED_XPU_BASE);
    
    volatile uint32_t *regs = (volatile uint32_t *)map;
    
    // Enable monitor mode
    regs[0] = 0x00000001;
    
    // Enable NAN processing
    regs[0] |= 0x00000002;
    
    // Read status
    printf("Enhanced XPU Status: 0x%08X\n", regs[3]);
    
    munmap(map, MAP_SIZE);
    close(fd);
    return 0;
}
```

Compile and run:
```bash
arm-linux-gnueabihf-gcc -o test_enhanced_xpu test.c
scp test_enhanced_xpu root@antsdr-ip:/tmp/
ssh root@antsdr-ip /tmp/test_enhanced_xpu
```

---

## Troubleshooting

### Build Failures

#### Synthesis Fails with "Unresolved Reference"

**Cause**: Missing base XPU source files

**Solution**:
```bash
# Verify xpu sources exist
ls -la ../xpu/src/xpu.v

# If missing, pull latest openwifi-hw
cd /path/to/openwifi-hw
git pull origin master
git submodule update --init --recursive
```

#### Timing Not Met (WNS < 0)

**Cause**: Design too complex for 100 MHz clock

**Solutions**:
1. **Reduce clock frequency** (edit constraints):
   ```tcl
   create_clock -period 15.0  # 66.7 MHz instead of 100 MHz
   ```

2. **Increase implementation effort**:
   ```bash
   # Edit build_antsdr.sh, change strategy to:
   set_property strategy "Performance_ExtraTimingOpt" [get_runs impl_1]
   ```

3. **Enable aggressive retiming**:
   ```tcl
   set_property {steps.synth_design.args.retiming} {1} [get_runs synth_1]
   set_property {steps.phys_opt_design.args.directive} {AggressiveExplore} [get_runs impl_1]
   ```

#### Resource Over-Utilization

**Cause**: Design exceeds FPGA capacity

**Check resource usage**:
```bash
grep "Slice LUTs" build_antsdr/impl_reports/utilization_impl.rpt
```

**Solutions**:
1. **Disable frame injection** (saves ~5% LUTs):
   - Edit `enhanced_xpu_wrapper.v`
   - Comment out `frame_injection_ctrl` instantiation

2. **Reduce NAN parser buffer sizes**:
   - Edit `nan_action_handler.v`
   - Reduce `MAX_PKT_SIZE` parameter

3. **Use RX-only build** (no TX support)

### Runtime Issues

#### antsdr Not Booting After Bitstream Update

**Cause**: Corrupted bitstream or incompatible version

**Solution**:
1. Restore factory bitstream from SD card backup
2. Verify bitstream MD5: `md5sum enhanced_xpu_antsdr.bit`
3. Check boot logs: `dmesg | grep -i error`

#### Monitor Mode Not Capturing Packets

**Cause**: Enhanced XPU not enabled or misconfigured

**Debug steps**:
```bash
# Check if enhanced XPU is responding
devmem 0x83C00000
# Should return current config, not 0x00000000

# Verify interface is up
ifconfig wlan0
# Should show UP and RUNNING

# Check for errors
dmesg | grep -i wifi
```

#### No Remote ID Detections

**Cause**: No drones nearby, or NAN processing disabled

**Debug steps**:
```bash
# Enable NAN processing
devmem 0x83C00000 32 0x00000003  # Enable monitor + NAN

# Check NAN status register
devmem 0x83C0000C

# Monitor for NAN frames
tcpdump -i wlan0 -vvv | grep -i "NAN"
```

### Common Warnings (Can Be Ignored)

- **[Synth 8-3331] Timing driven synthesis**: Normal optimization message
- **[Place 30-574] Poor placement**: Vivado will optimize in later stages
- **[Route 35-39] High congestion**: Usually resolves with post-route opt

### Critical Warnings (Must Fix)

- **[Synth 8-6859] Incompatible widths**: Check signal width mismatches
- **[DRC NSTD-1] Unspecified I/O**: Add pin constraints
- **[Timing 38-282] WNS violation**: See "Timing Not Met" above

---

## Advanced Configuration

### Custom Register Map

To add custom registers to enhanced XPU:

1. **Edit `enhanced_xpu_wrapper.v`**:
   ```verilog
   reg [31:0] my_custom_reg;  // Add at line ~120
   ```

2. **Add to AXI read logic** (line ~450):
   ```verilog
   10'h010: s01_axi_rdata_reg <= my_custom_reg;
   ```

3. **Add to AXI write logic** (line ~480):
   ```verilog
   10'h010: my_custom_reg <= s01_axi_wdata;
   ```

4. **Rebuild**:
   ```bash
   ./build_antsdr.sh --clean
   ```

### Integration with Full System

To integrate enhanced_xpu into complete antsdr system:

1. **Navigate to boards/antsdr**:
   ```bash
   cd /path/to/openwifi-hw/boards/antsdr
   ```

2. **Edit `set_files.tcl`**, add enhanced_xpu to IP repos:
   ```tcl
   set ip_repos [list \
     [file normalize "$origin_dir/../../adi-hdl/library"]\
     [file normalize "$origin_dir/ip_repo/"]\
     [file normalize "$origin_dir/../../ip/enhanced_xpu/"]\  # Add this
   ]
   ```

3. **Build full system**:
   ```bash
   cd boards/antsdr
   vivado -mode batch -source system_top.tcl
   ```

### Debugging with ILA (Integrated Logic Analyzer)

To add debug probes:

1. **Mark signals for debug** in `enhanced_xpu_wrapper.v`:
   ```verilog
   (* mark_debug = "true" *) wire is_nan_frame;
   (* mark_debug = "true" *) wire remote_id_detected;
   ```

2. **Rebuild with debug cores**:
   ```bash
   ./build_antsdr.sh --clean
   ```

3. **Open hardware manager and debug**:
   ```bash
   vivado -mode gui
   # Open Hardware Manager
   # Add debug probes
   # Trigger on is_nan_frame
   ```

---

## Additional Resources

### Documentation
- [RESOURCE_ESTIMATES.md](./RESOURCE_ESTIMATES.md) - Detailed resource analysis
- [Remote ID Module Guide](../docs/REMOTE_ID_ARCHITECTURE.md)
- [PlutoSDR Compatibility Guide](../../docs/PLUTOSDR_GUIDE.md)

### Related Projects
- [openwifi-hw](https://github.com/open-sdr/openwifi-hw) - Base WiFi SDR
- [antsdr-fw](https://github.com/MicroPhase/antsdr-fw) - Firmware for antsdr
- [ASTM F3411](https://www.astm.org/f3411-22.html) - Remote ID standard

### Support
- GitHub Issues: https://github.com/open-sdr/openwifi-hw/issues
- Forum: https://openwifi.groups.io
- Email: openwifi@ugent.be

---

## License

SPDX-License-Identifier: AGPL-3.0-only

Copyright (C) 2025 OpenWiFi Project
