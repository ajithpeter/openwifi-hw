# OpenWiFi RFSoC4x2 Board Support

## Overview

This directory contains board support files for running OpenWiFi on the Real Digital RFSoC4x2 development board (Xilinx Zynq UltraScale+ ZU48DR).

**Key Features:**
- Zynq UltraScale+ MPSoC with integrated RF Data Converters (RFDC)
- Direct RF sampling (no external AD9361 required)
- Multi-channel capability (2×2 MIMO ready)
- Higher bandwidth potential (RFDC 4.9 GSPS)
- 64-bit ARM Cortex-A53 quad-core processor

## Hardware Requirements

- **Board**: RealDigital RFSoC4x2
- **FPGA**: Xilinx Zynq UltraScale+ ZU48DR
- **RF Frontend**: Integrated RFDC (4.9152 GSPS ADC/DAC)
- **External Clocks**: LMK04828 (clock distribution), LMX2594 (RF reference)
- **Memory**: 4GB DDR4 RAM
- **Storage**: 16GB+ SD card

## Software Prerequisites

### Development Host
- Ubuntu 18.04+ or equivalent Linux distribution
- Xilinx Vitis 2022.2 (with Vitis, NOT just Vitis_HLS)
- Cross-compiler: aarch64-linux-gnu-gcc (provided by Vitis)
- Git, device-tree-compiler, u-boot-tools

### Target Board
- Linux kernel 5.15.36 (ADI 2022_R2 branch)
- PYNQ or Petalinux base image with RFDC support
- Python 3 with xrfclk library (for clock configuration)
- xrfdc kernel driver

## Build Instructions

### 1. Clone Repositories

```bash
# OpenWiFi software
git clone https://github.com/open-sdr/openwifi.git
cd openwifi
git submodule update --init --recursive

# OpenWiFi hardware (for FPGA bitstream)
cd ..
git clone https://github.com/open-sdr/openwifi-hw.git
cd openwifi-hw
git checkout claude/openwifi-rfsoc-port-*  # Use the RFSoC porting branch
```

### 2. Build FPGA Bitstream

See openwifi-hw/boards/rfsoc4x2/README.md for complete FPGA build instructions.

Quick summary:
```bash
cd openwifi-hw/boards/rfsoc4x2
./build_rfsoc.sh
# Output: system_top.bit, system_top.xsa
```

### 3. Build Kernel

```bash
export XILINX_DIR=/path/to/Xilinx
export OPENWIFI_DIR=/path/to/openwifi

# Prepare kernel source (one-time)
cd $OPENWIFI_DIR/user_space
./prepare_kernel.sh $XILINX_DIR 64

# Configure for RFSoC4x2
cd $OPENWIFI_DIR/adi-linux-64
cp ../kernel_boot/kernel_config_zynqmp .config
make oldconfig

# Build kernel
make -j12 Image
make -j12 modules

# Output: arch/arm64/boot/Image
```

### 4. Build Device Tree

```bash
cd $OPENWIFI_DIR/kernel_boot/boards/rfsoc4x2
dtc -I dts -O dtb -o system.dtb system.dts
```

### 5. Build OpenWiFi Driver Modules

```bash
cd $OPENWIFI_DIR/driver
./make_all.sh $XILINX_DIR 64

# Output: sdr.ko, openofdm_tx.ko, openofdm_rx.ko, tx_intf.ko, rx_intf.ko, xpu.ko
```

### 6. Build User-Space Tools

```bash
cd $OPENWIFI_DIR/user_space/sdrctl_src
make

cd ../inject_80211
make
```

## Deployment

### Prepare SD Card

1. **BOOT Partition (FAT32, 512MB)**:
   ```
   BOOT.BIN           # Boot binary (FSBL + FPGA + U-Boot)
   Image              # Linux kernel
   system.dtb         # Device tree blob
   boot.scr           # U-Boot script (optional)
   ```

2. **ROOT Partition (EXT4, rest of SD)**:
   - Base Linux filesystem (PYNQ or Petalinux)
   - OpenWiFi kernel modules in /lib/modules/
   - OpenWiFi scripts in /root/openwifi/

### Generate Boot Binary

```bash
cd $OPENWIFI_DIR/kernel_boot
./build_zynqmp_boot_bin.sh \
    $OPENWIFI_HW_IMG_DIR/boards/rfsoc4x2/sdk/system_top.xsa \
    boards/rfsoc4x2/u-boot.elf \
    boards/rfsoc4x2/bl31.elf

# Output: BOOT.BIN
```

### Copy Files to SD Card

```bash
# Mount SD card partitions
sudo mount /dev/sdX1 /mnt/boot
sudo mount /dev/sdX2 /mnt/rootfs

# Copy boot files
sudo cp kernel_boot/BOOT.BIN /mnt/boot/
sudo cp adi-linux-64/arch/arm64/boot/Image /mnt/boot/
sudo cp kernel_boot/boards/rfsoc4x2/system.dtb /mnt/boot/

# Copy kernel modules
sudo cp -r driver/*.ko /mnt/rootfs/root/openwifi/

# Copy user-space tools
sudo cp user_space/sdrctl_src/sdrctl /mnt/rootfs/root/openwifi/
sudo cp user_space/inject_80211/inject_80211 /mnt/rootfs/root/openwifi/

# Unmount
sudo umount /mnt/boot /mnt/rootfs
```

## Board Bring-Up

### 1. First Boot

Insert SD card and power on. Connect via UART (115200 baud) or SSH.

Default credentials (if using PYNQ image):
- Username: `xilinx`
- Password: `xilinx`

### 2. Configure RF Clocks

The RFSoC requires external clock configuration via LMK04828 and LMX2594:

```python
# Using Python on the board
from xrfclk import set_ref_clks

# Configure for WiFi operation
# LMK: 500 MHz PLB_CLK, LMX: 500 MHz (or 4 GHz for higher sampling)
set_ref_clks(lmk_freq=500.0, lmx_freq=500.0)
```

Or use the test script:
```bash
python3 /root/openwifi-hw/boards/rfsoc4x2/test_scripts/mts_calibration.py
```

### 3. Load FPGA Bitstream (if not in BOOT.BIN)

```bash
# Dynamic loading via fpga_manager
echo system_top.bit.bin > /sys/class/fpga_manager/fpga0/firmware

# Load device tree overlay
mkdir -p /configfs/device-tree/overlays/full
cat pl.dtbo > /configfs/device-tree/overlays/full/dtbo
```

### 4. Load OpenWiFi Driver

```bash
cd /root/openwifi
./wgd.sh  # Loads all kernel modules and initializes driver
```

### 5. Verify Operation

```bash
# Check kernel modules loaded
lsmod | grep sdr

# Check network interface
ip link show sdr0

# Bring up interface
ip link set sdr0 up

# Scan for networks
iw dev sdr0 scan

# Check FPGA version
./sdrctl dev sdr0 get reg xpu 63
```

## RFSoC-Specific Configuration

### RFDC Mixer Frequency

The RFSoC uses RFDC NCO (Numerically Controlled Oscillator) for frequency tuning instead of external LO.

**Current Implementation Status:**
- Driver framework supports channel switching (rfsoc_rf_set_channel)
- RFDC NCO control is pending full implementation
- Requires RFDC IIO driver integration or direct register access

**TODO**: Implement RFDC NCO control via:
1. RFDC IIO driver interface (preferred)
2. libmetal register access
3. Direct AXI register writes

### Sample Rate Configuration

**WiFi Baseband**: 20 MSPS (standard 802.11 20MHz bandwidth)
**RFDC Sampling**: 4.9152 GSPS (configurable)
**Sample Rate Conversion**: CIC decimation + FIR filtering in FPGA

Sample rate conversion is handled by `rfdc_adc_adapter` and `rfdc_dac_adapter` IP cores in the FPGA design.

### Multi-Channel/MIMO Support

The RFSoC4x2 hardware supports 2×2 MIMO operation:
- ADC Tile 0: Channels 0-1 (RX diversity)
- DAC Tile 0: Channels 0-1 (TX diversity)

**Current Status**: Framework implemented, full MIMO requires additional driver development.

## Testing

### Loopback Test (Hardware Verification)

```bash
cd /root/openwifi-hw/boards/rfsoc4x2/test_scripts
python3 loopback_test.py

# This tests RFDC ADC→DAC loopback without WiFi processing
```

### WiFi Functionality Test

```bash
cd /root/openwifi-hw/boards/rfsoc4x2/test_scripts
./wifi_test.sh

# Tests:
# 1. Bitstream loading
# 2. Device tree overlay
# 3. RF clock configuration
# 4. Driver loading
# 5. Network interface setup
# 6. Basic WiFi operations
```

### Access Point Mode

```bash
# Configure as AP
cd /root/openwifi/user_space
./fosdem.sh  # Starts AP on channel 6

# Check clients
iw dev sdr0 station dump
```

### Station Mode

```bash
# Connect to existing network
iw dev sdr0 connect "YourSSID"

# Or use wpa_supplicant for WPA/WPA2
wpa_supplicant -i sdr0 -c /etc/wpa_supplicant.conf -B
```

## Troubleshooting

### FPGA Loading Issues

```bash
# Check FPGA manager
cat /sys/class/fpga_manager/fpga0/state
# Should show: "operating" or "idle"

# Check device tree
cat /proc/device-tree/model
# Should include "RFSoC4x2"
```

### RF Clock Issues

```bash
# Verify clock wizard lock
# (via FPGA status registers or ILA)

# Re-run clock configuration
python3 -c "from xrfclk import set_ref_clks; set_ref_clks(500.0, 500.0)"
```

### Driver Loading Failures

```bash
# Check dmesg for errors
dmesg | grep -i sdr
dmesg | grep -i openwifi

# Verify device tree matches FPGA
cat /proc/device-tree/fpga-axi@0/sdr/compatible
# Should show: "sdr,sdr"

# Check DMA channels
ls -la /sys/class/dma/
```

### Network Interface Not Appearing

```bash
# Verify kernel modules loaded
lsmod | grep -E "sdr|tx_intf|rx_intf|xpu|openofdm"

# Check for hardware detection
dmesg | grep "TI lmk04828"
# Should show RFSoC4x2 detection

# Manual module load (if needed)
insmod sdr.ko
```

## Known Limitations

1. **RFDC NCO Control**: Not yet implemented in driver
   - Workaround: Frequency set in FPGA or device tree

2. **Multi-Tile Synchronization (MTS)**: Requires manual calibration
   - Use mts_calibration.py script before operation

3. **40 MHz Bandwidth**: Not currently supported
   - Limited to 20 MHz WiFi channels

4. **MIMO**: Framework ready, full implementation pending
   - Single spatial stream only (MCS 0-7)

## References

- OpenWiFi Project: https://github.com/open-sdr/openwifi
- OpenWiFi Hardware: https://github.com/open-sdr/openwifi-hw
- RFSoC Porting Guide: openwifi-hw/boards/rfsoc4x2/RFSOC_PORTING_GUIDE.md
- Xilinx RFSoC Documentation: https://www.xilinx.com/products/silicon-devices/soc/rfsoc.html
- RFSoC4x2 Board Files: https://www.realdigital.org/hardware/rfsoc-4x2

## Support

For issues specific to RFSoC4x2 porting:
- GitHub Issues: https://github.com/open-sdr/openwifi-hw/issues
- OpenWiFi Google Group: https://groups.google.com/g/open-sdr

## License

OpenWiFi is licensed under AGPL-3.0. See LICENSE file in repository root.

## Authors

RFSoC4x2 port developed as part of the OpenWiFi RFSoC integration effort.
Based on original OpenWiFi project by Xianjun Jiao and contributors.
