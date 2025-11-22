# OpenWiFi-HW PlutoSDR Compatibility Guide

## Table of Contents
1. [PlutoSDR-Compatible Boards](#plutosdr-compatible-boards)
2. [Hardware Comparison](#hardware-comparison)
3. [Pin Mapping and Constraints](#pin-mapping-and-constraints)
4. [Board-Specific Modifications](#board-specific-modifications)
5. [Build Instructions for PlutoSDR Boards](#build-instructions-for-plutosdr-boards)
6. [Software Integration](#software-integration)
7. [Performance Considerations](#performance-considerations)
8. [Troubleshooting](#troubleshooting)

---

## PlutoSDR-Compatible Boards

OpenWiFi-HW supports several boards with PlutoSDR-compatible architecture (Zynq7020 + AD9361):

### Primary PlutoSDR-Compatible Boards

| Board | Similarity | Key Features | Best Use Case |
|-------|------------|--------------|---------------|
| **antsdr** | ★★★★★ | Zynq7020 + AD9361, same RF IC | Direct PlutoSDR replacement |
| **antsdr_e200** | ★★★★★ | Zynq7020 + AD9361, Ethernet on PL | High-bandwidth applications |
| **e310v2** | ★★★★☆ | Zynq7020 + AD9361 + GPS/PPS | Precision timing applications |
| **sdrpi** | ★★★★☆ | Zynq7020 + AD936x, RPi form factor | Compact deployments |
| **adrv9364z7020** | ★★★☆☆ | Zynq7020 + AD9364 (single RX) | Cost-optimized solution |

### ADALM-PLUTO (Original) Comparison

| Feature | ADALM-PLUTO | antsdr | antsdr_e200 | e310v2 |
|---------|-------------|--------|-------------|--------|
| **FPGA** | Zynq7010 | Zynq7020 | Zynq7020 | Zynq7020 |
| **RF IC** | AD9363 | AD9361 | AD9361 | AD9361 |
| **LUTs** | 28K | 53K | 53K | 53K |
| **RAM Blocks** | 60 | 140 | 140 | 140 |
| **DSP Slices** | 80 | 220 | 220 | 220 |
| **RX Channels** | 1 | 2 | 2 | 2 |
| **TX Channels** | 1 | 2 | 2 | 2 |
| **Ethernet** | USB only | RGMII (PS) | RGMII (PL) | RGMII (PL) |
| **GPS** | No | No | No | Yes |
| **OpenWiFi Support** | ❌ (too small) | ✅ | ✅ | ✅ |

**Note:** ADALM-PLUTO (Zynq7010) is too small for the full OpenWiFi implementation. Use antsdr or similar boards instead.

---

## Hardware Comparison

### antsdr Board Details

**FPGA:** Xilinx Zynq7020-CLG400-1
```
Part: xc7z020clg400-1
Logic Cells: 85K
LUTs: 53,200
Flip-Flops: 106,400
Block RAM: 140 (4.9 Mb)
DSP48 Slices: 220
```

**RF Transceiver:** AD9361
```
Frequency Range: 70 MHz - 6 GHz
Bandwidth: up to 56 MHz
TX/RX Channels: 2×2 (dual channel)
Sample Rate: up to 61.44 MSPS
Resolution: 12-bit ADC/DAC
```

**Interfaces:**
- USB 2.0 (UART + JTAG via FT2232H)
- Ethernet RGMII (PS-side, 1 Gbps)
- SMA connectors for RF (TX1, TX2, RX1, RX2)
- U.FL connectors optional
- microSD card slot
- JTAG header
- GPIO expansion header

### antsdr_e200 Enhancements

**Key Differences from antsdr:**
- **Ethernet on PL**: Offloads network processing from PS
- **Smaller Form Factor**: More compact design
- **Enhanced Throughput**: Better for high-data-rate applications
- **UHD Compatible**: Works with USRP Hardware Driver

**Performance Benefits:**
```
Standard antsdr:  PS handles Ethernet → CPU overhead
antsdr_e200:      PL handles Ethernet → Reduced CPU load
                  → Higher achievable WiFi throughput
```

### e310v2 Additional Features

**GPS Module Integration:**
- U-blox GPS receiver
- PPS (Pulse Per Second) output
- 10 MHz reference input
- GPSDO capable with external TCXO/OCXO

**Precision Timing:**
```verilog
// In e310v2/src/ppsloop.v
module ppsloop (
  input wire pps_in,          // GPS PPS input
  input wire clk_10m_in,      // 10 MHz reference
  output wire vcxo_ctrl,      // VCXO control (DAC)
  output wire pps_out         // Synchronized PPS
);
```

**VCXO Control:**
```verilog
// In e310v2/src/ad5640_spi.v
module ad5640_spi (
  input wire clk,
  input wire [15:0] dac_val,  // DAC value for freq control
  output wire spi_clk,
  output wire spi_mosi,
  output wire spi_csn
);
```

---

## Pin Mapping and Constraints

### antsdr Pin Assignments

**AD9361 LVDS Interface:**
```tcl
# From boards/antsdr/src/antsdr_constr_lvds.xdc

# RX Data Interface
set_property PACKAGE_PIN N18 [get_ports {rx_data_in_p[0]}]
set_property PACKAGE_PIN P19 [get_ports {rx_data_in_n[0]}]
# ... (rx_data_in_p/n[1:5] continue)

set_property PACKAGE_PIN N20 [get_ports {rx_frame_in_p}]
set_property PACKAGE_PIN P20 [get_ports {rx_frame_in_n}]

set_property PACKAGE_PIN K19 [get_ports {rx_clk_in_p}]
set_property PACKAGE_PIN K20 [get_ports {rx_clk_in_n}]

# TX Data Interface
set_property PACKAGE_PIN M17 [get_ports {tx_data_out_p[0]}]
set_property PACKAGE_PIN M18 [get_ports {tx_data_out_n[0]}]
# ... (tx_data_out_p/n[1:5] continue)

set_property PACKAGE_PIN L19 [get_ports {tx_frame_out_p}]
set_property PACKAGE_PIN L20 [get_ports {tx_frame_out_n}]

set_property PACKAGE_PIN J18 [get_ports {tx_clk_out_p}]
set_property PACKAGE_PIN J19 [get_ports {tx_clk_out_n}]

# IOSTANDARD for LVDS
set_property IOSTANDARD LVDS_25 [get_ports rx_*]
set_property IOSTANDARD LVDS_25 [get_ports tx_*]
```

**AD9361 Control Interface:**
```tcl
# From boards/antsdr/src/antsdr_constr.xdc

# SPI
set_property PACKAGE_PIN F19 [get_ports spi_csn]
set_property PACKAGE_PIN F20 [get_ports spi_clk]
set_property PACKAGE_PIN E18 [get_ports spi_mosi]
set_property PACKAGE_PIN E19 [get_ports spi_miso]

# Control signals
set_property PACKAGE_PIN D19 [get_ports enable]
set_property PACKAGE_PIN D20 [get_ports txnrx]
set_property PACKAGE_PIN C20 [get_ports gpio_resetb]
set_property PACKAGE_PIN B20 [get_ports gpio_sync]
set_property PACKAGE_PIN B19 [get_ports gpio_en_agc]

# GPIO Status (from AD9361)
set_property PACKAGE_PIN A20 [get_ports {gpio_status[0]}]
# ... (gpio_status[1:7] continue)

# IOSTANDARD
set_property IOSTANDARD LVCMOS25 [get_ports spi_*]
set_property IOSTANDARD LVCMOS25 [get_ports gpio_*]
set_property IOSTANDARD LVCMOS25 [get_ports enable]
set_property IOSTANDARD LVCMOS25 [get_ports txnrx]
```

**Clock Constraints:**
```tcl
# ADC clock from AD9361 (via LVDS)
create_clock -period 25.000 -name rx_clk [get_ports rx_clk_in_p]

# PS-generated clocks
create_clock -period 10.000 -name fclk0 \
  [get_pins system_i/sys_ps7/FCLK_CLK0]
create_clock -period 10.000 -name fclk2 \
  [get_pins system_i/sys_ps7/FCLK_CLK2]

# False paths between async clocks
set_false_path -from [get_clocks rx_clk] -to [get_clocks fclk2]
set_false_path -from [get_clocks fclk2] -to [get_clocks rx_clk]
```

### antsdr_e200 Differences

**No External ADI Constraints:**
All constraints are local in `boards/antsdr_e200/src/system.xdc`

**Ethernet on PL:**
```tcl
# RGMII Ethernet (PL-side)
set_property PACKAGE_PIN M16 [get_ports eth_tx_clk]
set_property PACKAGE_PIN N16 [get_ports eth_tx_en]
set_property PACKAGE_PIN L14 [get_ports {eth_txd[0]}]
# ... (eth_txd[1:3], eth_rxd[0:3], etc.)

set_property IOSTANDARD LVCMOS33 [get_ports eth_*]
```

### e310v2 GPS/PPS Additions

```tcl
# GPS PPS Input
set_property PACKAGE_PIN G17 [get_ports pps_in]
set_property IOSTANDARD LVCMOS33 [get_ports pps_in]

# 10 MHz Reference Input
set_property PACKAGE_PIN H17 [get_ports clk_10m_in]
set_property IOSTANDARD LVCMOS33 [get_ports clk_10m_in]

# VCXO Control (SPI to AD5640 DAC)
set_property PACKAGE_PIN F17 [get_ports vcxo_spi_csn]
set_property PACKAGE_PIN E17 [get_ports vcxo_spi_clk]
set_property PACKAGE_PIN D18 [get_ports vcxo_spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports vcxo_spi_*]
```

---

## Board-Specific Modifications

### Minimal Changes Required for PlutoSDR Compatibility

**1. No Hardware Modifications Needed**
- antsdr/antsdr_e200/e310v2 work out-of-box
- Same AD9361 RF IC as PlutoSDR
- Compatible connectors (SMA or U.FL)

**2. FPGA Bitstream Differences**
```
PlutoSDR (Zynq7010):
  - Uses simplified design
  - Limited to basic RX/TX
  - No WiFi MAC/PHY

antsdr (Zynq7020):
  - Full OpenWiFi stack
  - Hardware MAC acceleration
  - 802.11a/g/n support
```

**3. Software Stack**
```
PlutoSDR:
  ├─ IIO drivers (libiio)
  ├─ ADI Transceiver Toolbox
  └─ Simple RX/TX applications

OpenWiFi (antsdr):
  ├─ Linux mac80211 WiFi stack
  ├─ OpenWiFi kernel driver
  ├─ Hardware-accelerated MAC
  └─ Full WiFi AP/STA functionality
```

### Customization for Minimal Beacon Scanner

**Goal:** Strip down OpenWiFi to minimal beacon RX/TX only

**Removed Components:**
- Full MAC CSMA/CA (keep minimal channel access)
- ACK/Block ACK handling
- Retransmission logic
- A-MPDU aggregation
- Most TX queues (keep 1)
- Side channel monitoring (optional)

**Kept Components:**
- OPENOFDM_RX (beacon reception)
- OPENOFDM_TX (beacon transmission)
- RX_INTF (ADC interface)
- TX_INTF (DAC interface, simplified)
- Minimal XPU (just for beacon filtering)
- TSF timer (for beacon intervals)

**Resource Savings:**
```
Full OpenWiFi (Zynq7020):
  LUTs: ~45K (85% utilization)
  BRAMs: ~90 (64% utilization)
  DSP48: ~50 (23% utilization)

Minimal Beacon (Zynq7020):
  LUTs: ~25K (47% utilization)  ← 44% reduction
  BRAMs: ~50 (36% utilization)  ← 44% reduction
  DSP48: ~40 (18% utilization)  ← 20% reduction

Fits on Zynq7010 (PlutoSDR)?
  LUTs: 28K available → 25K needed → Tight but possible!
  BRAMs: 60 available → 50 needed → Just fits!
  DSP48: 80 available → 40 needed → OK
```

---

## Build Instructions for PlutoSDR Boards

### Prerequisites

```bash
# Operating System
Ubuntu 20.04 or 22.04 LTS

# Xilinx Tools
Vivado 2022.2 + Vitis
# Install location: /opt/Xilinx or ~/Xilinx

# Required Packages
sudo apt update
sudo apt install -y \
  build-essential \
  git \
  libtinfo5 \
  libncurses5 \
  python3

# For Ubuntu 24 LTS (libtinfo5 not in repos):
wget http://be.archive.ubuntu.com/ubuntu/pool/main/n/ncurses/libtinfo5_6.1-1ubuntu1.18.04.1_amd64.deb
sudo dpkg -i ./libtinfo5_6.1-1ubuntu1.18.04.1_amd64.deb
```

### Build Process for antsdr

```bash
# 1. Clone repository
git clone https://github.com/open-sdr/openwifi-hw.git
cd openwifi-hw

# 2. Initialize submodules
git submodule init
git submodule update

# 3. Set environment variables
export XILINX_DIR=/opt/Xilinx  # or ~/Xilinx
export BOARD_NAME=antsdr

# 4. Prepare ADI HDL library (once)
./prepare_adi_lib.sh $XILINX_DIR
# Wait for "make" to complete in adi-hdl/library

# 5. Prepare board-specific ADI IP (once per board)
./prepare_adi_board_ip.sh $XILINX_DIR $BOARD_NAME
# Can stop when "Building ABCD project" appears

# 6. Get openofdm_rx submodule (once)
./get_ip_openofdm_rx.sh

# 7. Generate IP repository
cd boards/$BOARD_NAME/
../create_ip_repo.sh $XILINX_DIR
# This will take 30-60 minutes (HLS compilation)

# 8. Open Vivado project
# Vivado GUI will open automatically
# Or manually:
source $XILINX_DIR/Vivado/2022.2/settings64.sh
vivado openwifi_antsdr.xpr &

# 9. In Vivado GUI
# Click "Generate Bitstream"
# Wait for implementation to complete (~30-60 min)

# 10. Export hardware
# File → Export → Export Hardware
# Select: Include bitstream
# Click: Next → Next → Finish

# 11. Package output files
cd ../..
./boards/sdk_update.sh $BOARD_NAME ./output
# Creates output/ directory with:
#   - system_top.bit (bitstream)
#   - system_top.xsa (hardware platform)
#   - system_top.ltx (ILA debug, if enabled)
#   - git revision info
```

### Build for antsdr_e200

```bash
export BOARD_NAME=antsdr_e200
# Follow same steps as antsdr above
# Differences are handled automatically by board-specific TCL files
```

### Build for e310v2

```bash
export BOARD_NAME=e310v2
# Follow same steps
# Includes GPS/PPS modules automatically
```

### Faster Build Options

**Parallel IP Compilation:**
```bash
# In Vivado TCL console after create_ip_repo.sh:
set_param general.maxThreads 8
# Uses 8 CPU threads for parallel compilation
```

**Disable ILA for Production:**
```bash
# Remove debug flags to reduce compile time
cd boards/$BOARD_NAME/
../create_ip_repo.sh $XILINX_DIR
# (Without ENABLE_DBG flags - faster synthesis)
```

---

## Software Integration

### Linux Kernel and Driver

**Prerequisites:**
```bash
# Install ARM cross-compiler
sudo apt install -y \
  gcc-arm-linux-gnueabihf \
  device-tree-compiler \
  u-boot-tools

# Clone openwifi software repository
git clone https://github.com/open-sdr/openwifi.git
cd openwifi
```

**Build Kernel and Driver:**
```bash
# For Zynq7020 boards (antsdr, e310v2, etc.)
cd openwifi/kernel_boot
export BOARD_NAME=antsdr  # or antsdr_e200, e310v2

# Build kernel
./build_kernel.sh $BOARD_NAME

# Build openwifi driver
cd ../driver
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-

# Output:
#   sdr.ko         - Main SDR driver
#   tx_intf.ko     - TX interface driver
#   rx_intf.ko     - RX interface driver
#   openofdm_tx.ko - TX PHY driver
#   openofdm_rx.ko - RX PHY driver
#   xpu.ko         - MAC processor driver
#   side_ch.ko     - Side channel driver (optional)
```

**Deploy to Board:**
```bash
# Copy files to SD card
sudo cp kernel_boot/output/uImage /media/$USER/BOOT/
sudo cp kernel_boot/output/devicetree.dtb /media/$USER/BOOT/
sudo cp driver/*.ko /media/$USER/rootfs/root/

# Copy FPGA bitstream
sudo cp ../openwifi-hw/output/system_top.bit \
  /media/$USER/BOOT/openwifi.bit.bin
```

### User-Space Tools

**hostapd (Access Point mode):**
```bash
cd openwifi/user_space/hostapd-2.9
./build_hostapd.sh

# Deploy
scp hostapd/hostapd root@192.168.1.10:/usr/sbin/
```

**wpa_supplicant (Station mode):**
```bash
cd openwifi/user_space/wpa_supplicant-2.9
./build_wpa_supplicant.sh

# Deploy
scp wpa_supplicant/wpa_supplicant root@192.168.1.10:/usr/sbin/
```

**Configuration:**
```bash
# On board (via SSH or serial console)
modprobe sdr
modprobe tx_intf
modprobe rx_intf
modprobe openofdm_tx
modprobe openofdm_rx
modprobe xpu

# Check WiFi interface
ip link show sdr0
# Should show: sdr0: <BROADCAST,MULTICAST> ...

# Set up as AP
cat > /etc/hostapd.conf <<EOF
interface=sdr0
driver=nl80211
ssid=OpenWiFi-AP
hw_mode=g
channel=6
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=openwifi123
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

hostapd /etc/hostapd.conf
```

---

## Performance Considerations

### PlutoSDR Board Performance

**antsdr:**
```
TX Throughput:     Up to 54 Mbps (802.11a/g)
                   Up to 65 Mbps (802.11n MCS7 short GI)
RX Sensitivity:    -82 dBm @ 6 Mbps
                   -65 dBm @ 54 Mbps
TX Power:          Configurable, up to +10 dBm (software limit)
                   Hardware capable of +20 dBm (with PA)
Range:             ~50m indoor, ~200m outdoor (depends on antenna)
```

**antsdr_e200 (Enhanced Ethernet):**
```
Same RF performance as antsdr
Network Throughput: Higher (Ethernet offloaded to PL)
CPU Usage:         Lower (less PS load)
Best for:          High-data-rate streaming applications
```

**e310v2 (GPS-Enhanced):**
```
Same RF performance as antsdr
Timing Accuracy:   ±1 μs with GPS lock
                   ±10 ns with external 10 MHz + PPS
Best for:          Time-synchronized networks
                   Precision location-based services
```

### Optimization Tips

**1. Reduce Latency:**
```c
// In driver: disable power management
iw dev sdr0 set power_save off

// Increase CPU frequency (on board)
echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

**2. Maximize Throughput:**
```bash
# Use 802.11n HT rates
hostapd.conf:
  ieee80211n=1
  ht_capab=[SHORT-GI-20]

# Disable RTS/CTS for small frames
iwconfig sdr0 rts 2347
```

**3. Improve Sensitivity:**
```c
// In FPGA register configuration:
// Increase RX digital gain
write_reg(RX_INTF_REG11, 3);  // 8x gain

// Lower RSSI threshold for CCA
write_reg(XPU_REG_LBT_TH, -90);  // -90 dBm
```

---

## Troubleshooting

### Common Issues and Solutions

#### Issue 1: "No sdr0 interface after modprobe"

**Symptoms:**
```bash
modprobe sdr
# No error, but ip link show has no sdr0
dmesg | tail
# Shows: "sdr: probe failed with error -110"
```

**Solution:**
```bash
# Check FPGA loaded
cat /sys/class/fpga_manager/fpga0/state
# Should show: operating

# Reload FPGA bitstream
cat /boot/openwifi.bit.bin > /dev/xdevcfg

# Check register access
devmem 0x43C00000
# Should return non-zero value (XPU base address)
```

#### Issue 2: "High packet error rate"

**Symptoms:**
```bash
iw dev sdr0 station dump
# Shows high "tx failed" or "rx drop count"
```

**Solution:**
```bash
# Check AD9361 calibration
iio_attr -d ad9361-phy -c voltage0 hardwaregain
# Should return value, e.g., "71.000000 dB"

# Recalibrate (on board)
echo 1 > /sys/bus/iio/devices/iio:device0/calibrate

# Check channel selection (avoid congested channels)
iw dev sdr0 set channel 11  # Try different channel
```

#### Issue 3: "Vivado synthesis fails with timing violations"

**Symptoms:**
```
CRITICAL WARNING: [Timing 38-282] ... setup timing not met
```

**Solution:**
```tcl
# In Vivado TCL console:
# Relax timing on non-critical paths
set_max_delay 10 -from [get_clocks clk_fpga_0] -to [get_clocks clk_fpga_2]

# Or use more aggressive synthesis strategy:
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream
```

#### Issue 4: "Board boots but no network"

**Symptoms:**
```bash
# Serial console shows boot messages
# But no Ethernet connectivity (antsdr)
```

**Solution:**
```bash
# Check Ethernet PHY
ifconfig eth0
# If "No such device":

# Check device tree
ls /proc/device-tree/amba/ethernet*
# Should exist

# Reload Ethernet driver
modprobe -r macb
modprobe macb

# Set static IP if DHCP fails
ifconfig eth0 192.168.1.10 netmask 255.255.255.0
```

#### Issue 5: "TX not transmitting (no RF output)"

**Symptoms:**
```bash
hostapd starts, but spectrum analyzer shows no signal
```

**Solution:**
```bash
# Check AD9361 TX enable
iio_attr -d ad9361-phy -c altvoltage1 frequency
# Should return TX LO frequency

# Check FPGA TX path
devmem 0x43C00000 32 0x00000001  # Reset TX_INTF
devmem 0x43C10000 32 0x00000001  # Reset OPENOFDM_TX

# Check antenna port selection (hardware)
# Ensure SMA cable connected to TX1 or TX2

# Verify TX power not set too low
iio_attr -d ad9361-phy -c voltage0 hardwaregain 0
# Sets max TX power
```

---

## Additional Resources

### Documentation
- [OpenWiFi Main Repo](https://github.com/open-sdr/openwifi)
- [OpenWiFi Hardware](https://github.com/open-sdr/openwifi-hw)
- [Analog Devices HDL Reference](https://github.com/analogdevicesinc/hdl)
- [AD9361 Datasheet](https://www.analog.com/en/products/ad9361.html)

### Community Support
- [OpenWiFi Discussions](https://github.com/open-sdr/openwifi/discussions)
- [OpenWiFi Issues](https://github.com/open-sdr/openwifi-hw/issues)

### Commercial Support
- [OpenWiFi Tech](https://openwifi.tech) - Subscriptions and support

---

**Document Version:** 1.0
**Last Updated:** 2025-11-22
**Target Boards:** antsdr, antsdr_e200, e310v2, sdrpi
