# enhanced_xpu User Guide

**OpenWiFi Project**
**Last Updated: 2025-11-22**

## Table of Contents

1. [Introduction](#introduction)
2. [Hardware Setup](#hardware-setup)
3. [Software Installation](#software-installation)
4. [Monitor Mode](#monitor-mode)
5. [Frame Injection](#frame-injection)
6. [Remote ID Transmission/Reception](#remote-id-transmissionreception)
7. [Troubleshooting](#troubleshooting)
8. [FAQ](#faq)

---

## Introduction

The **enhanced_xpu** module extends the OpenWiFi platform with advanced packet filtering and frame injection capabilities specifically designed for:

- **SDR Developers**: Advanced WiFi experimentation and research
- **Drone Operators**: ASTM F3411 compliant Remote ID transmission
- **WiFi Security Researchers**: Monitor mode and packet analysis
- **FPV Enthusiasts**: High-rate video streaming via WiFi broadcast

### Key Features

- **Enhanced Packet Filtering**: Hardware-accelerated frame classification
- **Monitor Mode**: Capture all WiFi frames (beacons, probes, NAN, etc.)
- **Frame Injection**: Transmit custom WiFi frames at high rates
- **NAN Support**: WiFi Aware/Neighbor Awareness Networking
- **Remote ID**: Complete ASTM F3411-22 implementation
- **wfb-ng Compatible**: WiFi broadcast for FPV video

---

## Hardware Setup

### Supported Hardware

The enhanced_xpu module supports the following OpenWiFi-compatible SDR platforms:

| Platform | SoC | FPGA | Status |
|----------|-----|------|--------|
| ANTSDR | Zynq-7020 | Xilinx 7-series | ✅ Fully Supported |
| ANTSDR-E200 | Zynq-7020 | Xilinx 7-series | ✅ Fully Supported |
| PlutoSDR | Zynq-7010 | Xilinx 7-series | ⚠️ Limited (see PlutoSDR guide) |
| ZCU102 | ZynqMP | UltraScale+ | ✅ Supported |

### Hardware Connections

#### ANTSDR / ANTSDR-E200

```
┌─────────────────────────────────────────┐
│                ANTSDR                   │
│                                         │
│  ┌─────┐  ┌──────┐  ┌──────────────┐  │
│  │ USB │──│ ZYNQ │──│ AD9361 (2x2) │──┼──> RF Antenna (WiFi 2.4/5 GHz)
│  └─────┘  │ SoC  │  │  Transceiver │  │
│           └──────┘  └──────────────┘  │
│                                         │
│  Optional:                              │
│  ┌──────┐                               │
│  │ UART │──────────────────────────────┼──> GPS Module (for Remote ID)
│  └──────┘                               │
└─────────────────────────────────────────┘
```

#### Antenna Selection

| Band | Frequency | Recommended Antenna |
|------|-----------|---------------------|
| 2.4 GHz | 2.412-2.484 GHz | Omnidirectional, 2-5 dBi |
| 5 GHz | 5.150-5.850 GHz | Omnidirectional, 2-8 dBi |
| Remote ID | 2.4 GHz (Ch 6) | Omnidirectional, low gain |
| FPV Video | 5.8 GHz | Directional/patch antenna |

**Important**: Ensure antenna is connected before powering on to avoid damaging the transceiver!

### Power Requirements

- **ANTSDR**: 5V @ 2A via USB-C
- **GPS Module** (optional): 3.3V or 5V via GPIO/UART

---

## Software Installation

### Prerequisites

```bash
# Install dependencies (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    git \
    cmake \
    linux-headers-$(uname -r) \
    dkms

# For cross-compilation (ARM targets)
sudo apt-get install -y \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf
```

### Clone OpenWiFi Repository

```bash
cd ~
git clone https://github.com/open-sdr/openwifi
cd openwifi
```

### Build FPGA Bitstream

```bash
cd ~/openwifi/ip
./create_vivado_proj.sh antsdr  # or antsdr_e200, zcu102, etc.

# Open Vivado and generate bitstream
vivado ./boards/antsdr/openwifi.xpr

# In Vivado:
# 1. Generate Bitstream (Ctrl+G)
# 2. Wait for completion (~30 minutes)
# 3. Export bitstream to ~/openwifi/kernel/boot/
```

### Build Kernel Driver

```bash
cd ~/openwifi/driver
make

# Copy driver to target device
scp sdr.ko root@<BOARD_IP>:/root/
```

### Build Examples

```bash
cd ~/openwifi/ip/enhanced_xpu/examples
make

# Cross-compile for ARM
make CROSS_COMPILE=arm-linux-gnueabihf-

# Install on target
make install INSTALL_DIR=/usr/local/bin
```

### Load Driver on Target Device

```bash
# SSH to ANTSDR
ssh root@192.168.2.1  # Default IP

# Load FPGA bitstream
cat /root/openwifi.bit.bin > /dev/xdevcfg

# Load kernel driver
insmod /root/sdr.ko

# Verify device
ls /dev/sdr0
dmesg | grep sdr
```

---

## Monitor Mode

Monitor mode allows capturing all WiFi frames without associating to an access point.

### Enabling Monitor Mode

#### Using Example Application

```bash
# Monitor beacons on channel 6
sudo ./monitor_beacons 6
```

#### Manual Configuration via ioctl

```c
#include <sys/ioctl.h>

#define IOCTL_SET_MONITOR_MODE  _IOW('o', 10, uint32_t)
#define IOCTL_SET_FILTER        _IOW('o', 12, uint32_t)

int fd = open("/dev/sdr0", O_RDWR);

// Enable monitor mode
uint32_t enable = 1;
ioctl(fd, IOCTL_SET_MONITOR_MODE, enable);

// Set filter (beacons only)
uint32_t filter = (1 << 0);  // FILTER_BEACON
ioctl(fd, IOCTL_SET_FILTER, filter);
```

### Filter Options

The enhanced_xpu supports fine-grained frame filtering:

| Filter Flag | Value | Description |
|-------------|-------|-------------|
| FILTER_BEACON | 0x01 | Beacon frames |
| FILTER_PROBE_REQ | 0x02 | Probe requests |
| FILTER_PROBE_RESP | 0x04 | Probe responses |
| FILTER_DATA | 0x08 | Data frames |
| FILTER_NAN | 0x10 | NAN action frames |
| FILTER_AUTH | 0x20 | Authentication frames |
| FILTER_DEAUTH | 0x40 | Deauthentication frames |
| FILTER_ASSOC | 0x80 | Association frames |

Combine filters with bitwise OR:

```c
uint32_t filter = FILTER_BEACON | FILTER_PROBE_REQ | FILTER_NAN;
ioctl(fd, IOCTL_SET_FILTER, filter);
```

### Reading Captured Frames

```c
uint8_t buffer[4096];
ssize_t len;

while (1) {
    len = read(fd, buffer, sizeof(buffer));
    if (len > 0) {
        // Process frame
        process_frame(buffer, len);
    }
}
```

### Example: Beacon Monitor

See `examples/monitor_beacons.c` for a complete example that displays:
- SSID
- BSSID (MAC address)
- Channel
- RSSI (signal strength)
- Encryption type (Open/WPA/WPA2/WPA3)

```bash
sudo ./monitor_beacons 6

TIME      BSSID              CH   RSSI        ENCRYPTION    SSID
--------------------------------------------------------------------------------
14:23:45  AA:BB:CC:DD:EE:FF  6    -45 dBm     WPA2/WPA3     MyNetwork
14:23:46  11:22:33:44:55:66  6    -67 dBm     Open          GuestWiFi
```

---

## Frame Injection

Frame injection allows transmitting custom WiFi frames for testing and experimentation.

### Basic Frame Injection

```c
#define IOCTL_INJECT_FRAME  _IOW('o', 20, void*)

struct inject_params {
    uint8_t  *frame;     // Frame data
    uint32_t  length;    // Frame length
    uint32_t  rate;      // Data rate (Mbps)
    uint32_t  retries;   // Number of retries
    uint32_t  flags;     // Injection flags
};

// Prepare frame
uint8_t frame[256];
build_beacon_frame(frame, sizeof(frame));

// Inject
struct inject_params params = {
    .frame = frame,
    .length = frame_len,
    .rate = 6,       // 6 Mbps
    .retries = 0,    // No retries (broadcast)
    .flags = 0
};

ioctl(fd, IOCTL_INJECT_FRAME, &params);
```

### Injection Flags

| Flag | Value | Description |
|------|-------|-------------|
| NO_ACK | 0x0001 | Don't wait for ACK (broadcast) |
| USE_CTS | 0x0002 | Use CTS-to-self protection |
| USE_RTS | 0x0004 | Use RTS/CTS handshake |
| NO_SEQ | 0x0008 | Don't auto-increment sequence |

### Data Rates

Supported data rates (802.11g/n):

| Rate (Mbps) | Modulation | Notes |
|-------------|------------|-------|
| 1 | BPSK | Long range, robust |
| 6 | QPSK | Management frames default |
| 12 | 16-QAM | Good balance |
| 18 | 16-QAM | Recommended for Remote ID |
| 24 | 64-QAM | Higher throughput |
| 54 | 64-QAM | Maximum 802.11g rate |

### Example: Beacon Injection

See `examples/inject_beacon.c`:

```bash
# Transmit beacon for "TestAP" on channel 6 at 100ms interval
sudo ./inject_beacon -s "TestAP" -c 6 -i 100

# With encryption advertisement
sudo ./inject_beacon -s "SecureAP" -c 6 -e
```

### Safety Considerations

⚠️ **WARNING**: Unauthorized frame injection may be illegal in your jurisdiction!

- Only use in controlled environments (shielded room, attenuated setup)
- Respect local regulations (FCC Part 15, ETSI EN 300 328, etc.)
- Do not interfere with production networks
- Use appropriate TX power limits

---

## Remote ID Transmission/Reception

The enhanced_xpu provides complete support for drone Remote ID per ASTM F3411-22.

### Remote ID Transmitter

Transmits drone identification and location via WiFi NAN (Neighbor Awareness Networking).

#### Basic Usage

```bash
# With GPS
sudo ./remote_id_transmitter -i "DRONE123456789" -g /dev/ttyUSB0 -c 6

# Simulated GPS (for testing)
sudo ./remote_id_transmitter -i "TESTDRONE001" -c 6
```

#### GPS Connection

For real GPS data, connect a NMEA-compatible GPS module:

```
GPS Module    ANTSDR
----------    ------
VCC     -->   3.3V or 5V
GND     -->   GND
TX      -->   UART RX (GPIO pin)
```

Configure serial port:

```bash
# Check GPS output
cat /dev/ttyUSB0

# Should see NMEA sentences:
# $GPGGA,123456.00,3745.1234,N,12227.5678,W,1,08,1.2,50.0,M,...
# $GPRMC,123456.00,A,3745.1234,N,12227.5678,W,5.2,123.4,...
```

#### Message Types

The transmitter sends:

1. **Basic ID (Type 0)**: Static drone identification
   - UAS ID (serial number)
   - UA Type (multirotor, fixed-wing, etc.)

2. **Location (Type 1)**: Real-time position and velocity
   - Latitude, Longitude
   - Altitude (barometric and geodetic)
   - Speed and direction
   - Accuracy estimates

Transmitted at **1 Hz** (once per second) as required by ASTM F3411.

#### Integration with Flight Controller

For ArduPilot/PX4 integration:

```bash
# Read MAVLink telemetry for GPS
# (requires mavlink library - not included in this example)
./remote_id_transmitter -i "DRONE001" -m /dev/ttyACM0
```

### Remote ID Receiver

Monitors for Remote ID frames and displays drone information.

#### Basic Usage

```bash
# Monitor channel 6 with logging
sudo ./remote_id_receiver -c 6 -l drones.log -v
```

#### Output

```
Monitoring for Remote ID frames on channel 6...

14:30:15  [LOCATION] ID: DRONE123456789      Lat:  37.7749000  Lon: -122.4194000  Alt:   50.0m  Spd:   5.2m/s  Dir: 123.4°
14:30:16  [LOCATION] ID: DRONE123456789      Lat:  37.7749100  Lon: -122.4194100  Alt:   51.0m  Spd:   5.5m/s  Dir: 125.1°
```

#### Log File Format

CSV format for easy analysis:

```csv
timestamp,message_type,uas_id,latitude,longitude,altitude,speed,direction
1700000000,BASIC_ID,DRONE123456789,Multirotor
1700000001,LOCATION,DRONE123456789,37.7749,-122.4194,50.0,5.2,123.4
```

#### Tracking Multiple Drones

The receiver tracks up to 100 drones simultaneously and displays a summary:

```
================================================================================
Tracked Drones Summary (3 total)
================================================================================

Drone #1:
  UAS ID:    DRONE123456789
  Type:      Multirotor
  Location:  37.7749, -122.4194 (alt: 50.0m)
  Speed:     5.2 m/s  Direction: 123.4°
  Last seen: 2 seconds ago
  Messages:  150
```

---

## Troubleshooting

### Device Not Found

**Problem**: `/dev/sdr0` does not exist

**Solution**:
```bash
# Check if driver is loaded
lsmod | grep sdr

# Check dmesg for errors
dmesg | grep -i sdr

# Reload driver
rmmod sdr
insmod /root/sdr.ko

# Verify FPGA bitstream
md5sum /root/openwifi.bit.bin
```

### Monitor Mode Not Working

**Problem**: No frames captured in monitor mode

**Solution**:
```bash
# Verify monitor mode is enabled
cat /sys/class/net/sdr0/monitor_mode

# Check channel is set
iw dev sdr0 info

# Increase verbosity
dmesg -w &
./monitor_beacons 6
```

### Frame Injection Fails

**Problem**: `ioctl: Operation not permitted` or frames not transmitted

**Solution**:
```bash
# Run as root
sudo ./inject_beacon -s "Test"

# Check TX power
iw dev sdr0 info | grep txpower

# Verify channel is allowed for TX
iw reg get

# Check for hardware errors
dmesg | tail -20
```

### GPS Not Working (Remote ID)

**Problem**: GPS data not received or invalid

**Solution**:
```bash
# Check GPS serial port
sudo cat /dev/ttyUSB0
# Should see NMEA sentences

# Check baud rate (usually 9600)
stty -F /dev/ttyUSB0 9600

# Verify GPS has fix
# Wait for GPS to acquire satellites (may take 1-5 minutes)

# Use simulated GPS for testing
./remote_id_transmitter -i "TEST" -c 6  # No -g option
```

### Low Range / High Packet Loss

**Problem**: Frames not received beyond short distance

**Solution**:
```bash
# Increase TX power
iw dev sdr0 set txpower fixed 2000  # 20 dBm

# Use lower data rate for better range
./inject_beacon -s "Test" -c 6 -r 6  # 6 Mbps

# Check antenna connection
# Ensure antenna is properly connected

# Try different channel
# Some channels may have interference
./monitor_beacons 11  # Try channel 11 instead of 6
```

### High CPU Usage

**Problem**: Application uses excessive CPU

**Solution**:
```bash
# Reduce frame rate
# For beacon injection, increase interval:
./inject_beacon -s "Test" -i 200  # 200ms instead of 100ms

# Use hardware filtering
# Enable specific filters instead of promiscuous mode

# Check for infinite loops in code
# Review custom applications for busy-wait loops
```

---

## FAQ

### General Questions

**Q: What is enhanced_xpu?**
A: It's an enhanced packet filter and frame injection module for OpenWiFi, extending the base XPU (transmit/receive processing unit) with advanced features for SDR applications.

**Q: Is enhanced_xpu legal to use?**
A: The software itself is legal. However, some use cases (frame injection, operating on certain channels) may be regulated in your jurisdiction. Always comply with local laws (FCC, ETSI, etc.).

**Q: Can I use this with standard WiFi cards?**
A: No, enhanced_xpu requires OpenWiFi-compatible SDR hardware (ANTSDR, PlutoSDR with modifications, etc.).

### Technical Questions

**Q: What's the maximum frame injection rate?**
A: Depends on frame size and data rate. With 1400-byte frames at 54 Mbps, you can achieve 40+ Mbps throughput. For wfb-ng video, 20-30 Mbps is typical.

**Q: Does it support 802.11n/ac?**
A: Currently, enhanced_xpu supports 802.11g (OFDM). 802.11n (HT) support is in development.

**Q: Can I capture encrypted frames?**
A: Yes, in monitor mode you can capture all frames including encrypted ones. However, you cannot decrypt them without the encryption keys.

**Q: What's the range for Remote ID?**
A: Per ASTM F3411, Remote ID should be receivable at 400m minimum. Actual range depends on TX power, antenna, and environment. Typical range: 500-1000m.

### Remote ID Questions

**Q: Is this compliant with FAA/EASA regulations?**
A: This implementation follows ASTM F3411-22 standard. However, compliance also requires proper drone integration, testing, and certification. Consult local authorities.

**Q: Why use WiFi NAN instead of Bluetooth?**
A: WiFi NAN provides longer range (500m+ vs ~100m for Bluetooth) and is specified in ASTM F3411 as one of the approved transport methods.

**Q: Can standard smartphones receive Remote ID?**
A: Yes, with appropriate apps that support WiFi Aware/NAN. Several Remote ID receiver apps are available for Android.

### Development Questions

**Q: How do I add custom frame types?**
A: See `API_REFERENCE.md` for details on extending the packet filter and building custom frames.

**Q: Can I contribute to the project?**
A: Yes! OpenWiFi is open-source. Submit pull requests on GitHub.

**Q: Where can I get support?**
A: Check the OpenWiFi forum, GitHub issues, or Discord channel (links in main README).

---

## Additional Resources

- [API Reference](API_REFERENCE.md) - Detailed API documentation
- [Remote ID Guide](REMOTE_ID_GUIDE.md) - Complete Remote ID implementation guide
- [Quick Start](../QUICKSTART.md) - 5-minute setup guide
- [OpenWiFi Main Documentation](https://github.com/open-sdr/openwifi)
- [ASTM F3411-22 Standard](https://www.astm.org/f3411-22.html)
- [IEEE 802.11 Standard](https://standards.ieee.org/standard/802_11-2020.html)

---

**Copyright © 2025 OpenWiFi Project**
**License: AGPL-3.0-only**
