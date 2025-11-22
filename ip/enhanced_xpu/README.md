# Enhanced XPU Software Integration

This directory contains the complete software stack for controlling the Enhanced XPU hardware from Linux userspace.

## Overview

The Enhanced XPU (eXtended Processing Unit) is a hardware module for the OpenWiFi platform that provides:

- **WiFi Monitor Mode**: Capture 802.11 frames with advanced filtering
- **Frame Injection**: Transmit arbitrary 802.11 frames
- **Drone Remote ID**: ASTM F3411 compliant Remote ID transmission and monitoring

## Components

```
enhanced_xpu/
├── driver/              Kernel driver
│   ├── enhanced_xpu_drv.c     Character device driver
│   ├── enhanced_xpu_ioctl.h   IOCTL interface definitions
│   └── Kbuild                 Kernel build configuration
├── lib/                 Userspace library
│   ├── libenhanced_xpu.c      Library implementation
│   ├── libenhanced_xpu.h      Public API
│   └── remote_id_codec.c      Remote ID encoder/decoder
├── tools/               Command-line tools
│   ├── xpu_mon.c              Monitor mode tool
│   ├── xpu_inject.c           Frame injection tool
│   └── xpu_remote_id.c        Remote ID tool
├── python/              Python bindings
│   ├── enhanced_xpu.py        Python module
│   ├── setup.py               Installation script
│   └── README.md              Python documentation
├── include/             Headers
│   └── remote_id_types.h      Remote ID data structures
└── Makefile             Build system
```

## Building

### Requirements

- Linux kernel headers (for driver)
- GCC compiler
- libpcap development files
- Python 3.6+ (for Python bindings)

**Debian/Ubuntu:**
```bash
sudo apt-get install linux-headers-$(uname -r) build-essential libpcap-dev python3-dev
```

### Build All Components

```bash
make
```

### Build Specific Components

```bash
make kernel    # Kernel driver only
make lib       # Userspace library only
make tools     # Command-line tools only
make python    # Python bindings only
```

### Cross-Compilation for ARM (Zynq)

```bash
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
export KERNEL_SRC=/path/to/kernel/source

make
```

## Installation

### Install All Components

```bash
sudo make install
```

This installs:
- Kernel module to `/lib/modules/$(uname -r)/extra/`
- Library to `/usr/local/lib/`
- Tools to `/usr/local/bin/`
- Headers to `/usr/local/include/enhanced_xpu/`

### Load Kernel Module

```bash
sudo modprobe enhanced_xpu
# Or manually:
sudo insmod /lib/modules/$(uname -r)/extra/enhanced_xpu.ko
```

Verify device node:
```bash
ls -l /dev/enhanced_xpu
```

### Install Python Bindings

```bash
cd python
sudo python3 setup.py install
```

## Usage

### Monitor Mode Tool (xpu_mon)

Capture WiFi frames similar to tcpdump:

```bash
# Monitor channel 6
xpu_mon -c 6

# Capture beacons to pcap file
xpu_mon -f beacon -w beacons.pcap

# Monitor NAN frames (Remote ID)
xpu_mon -f nan -v

# Filter by MAC address
xpu_mon -m 00:11:22:33:44:55

# Capture 100 packets and exit
xpu_mon -n 100
```

### Frame Injection Tool (xpu_inject)

Inject arbitrary 802.11 frames:

```bash
# Inject beacon frame (template)
xpu_inject -t beacon:MySSID -c 10

# Inject probe request continuously
xpu_inject -t probe-req -c 0 -d 100

# Inject frame from hex file
xpu_inject -f frame.hex -r 54 -p 20

# Inject hex frame directly
xpu_inject -x "40 00 00 00 ff ff ff ff ff ff ..."
```

### Remote ID Tool (xpu_remote_id)

ASTM F3411 Remote ID transmission and monitoring:

#### Transmit Mode
```bash
xpu_remote_id transmit \
    -u "DRONE-12345" \
    -o "OP-001" \
    -l 37.7749,-122.4194 \
    -a 100
```

#### Monitor Mode
```bash
xpu_remote_id monitor -v
```

#### Test Mode (TX + RX simultaneously)
```bash
xpu_remote_id test \
    -u "TEST-001" \
    -l 0,0 \
    -a 50
```

### Using the C Library

```c
#include <enhanced_xpu/libenhanced_xpu.h>

int main() {
    xpu_handle_t handle;
    uint8_t packet[2048];
    ssize_t len;

    /* Open device */
    handle = xpu_open("/dev/enhanced_xpu");
    if (!handle) {
        fprintf(stderr, "Failed to open: %s\n", xpu_get_error());
        return 1;
    }

    /* Enable monitor mode */
    xpu_set_monitor_mode(handle, true);

    /* Capture packet */
    len = xpu_receive_packet(handle, packet, sizeof(packet), 1000);
    if (len > 0) {
        printf("Received %zd bytes\n", len);
    }

    /* Close device */
    xpu_close(handle);
    return 0;
}
```

Compile:
```bash
gcc -o myapp myapp.c -lenhanced_xpu -lpthread -lm
```

### Using Python Bindings

```python
from enhanced_xpu import XPU, RemoteIDLocationClass

# Monitor mode
with XPU() as xpu:
    xpu.set_monitor_mode(True)

    for packet in xpu.capture(count=10):
        print(f"Received {len(packet)} bytes")

# Frame injection
with XPU() as xpu:
    xpu.set_inject_mode(True)
    beacon = bytes.fromhex("80 00 00 00 ff ff ...")
    xpu.inject_frame(beacon, rate=6, power=15)

# Remote ID
with XPU() as xpu:
    location = RemoteIDLocationClass(
        latitude=37.7749,
        longitude=-122.4194,
        altitude=100.0
    )
    xpu.set_inject_mode(True)
    xpu.remote_id_transmit(location)
```

## Architecture

### Kernel Driver

The kernel driver (`enhanced_xpu_drv.c`) provides:

- Character device interface (`/dev/enhanced_xpu`)
- IOCTL commands for configuration
- DMA buffers for RX/TX
- Interrupt handling
- Integration with Linux device model

### Userspace Library

The library (`libenhanced_xpu`) provides:

- High-level C API
- Error handling and validation
- Remote ID encoding/decoding
- Packet filtering
- Statistics collection

### Remote ID Codec

Implementation of ASTM F3411 standard:

- Message encoding (Basic ID, Location, Self-ID, Operator ID)
- NAN frame encapsulation (WiFi Aware)
- Message validation
- Human-readable formatting

### Command-Line Tools

Production-ready tools for:

- Packet capture and analysis
- Frame injection and testing
- Remote ID compliance

## Hardware Integration

### Device Tree

Add to your device tree:

```dts
enhanced_xpu@43C10000 {
    compatible = "openwifi,enhanced-xpu-1.0";
    reg = <0x43C10000 0x10000>;
    interrupts = <0 29 4>;
    interrupt-parent = <&intc>;
};
```

### AXI Address Map

The driver expects these registers at the base address:

| Offset | Register | Description |
|--------|----------|-------------|
| 0x00   | CONTROL  | Control register |
| 0x04   | STATUS   | Status register |
| 0x08   | IRQ_EN   | Interrupt enable |
| 0x0C   | IRQ_STS  | Interrupt status |
| 0x10   | FILTER   | Packet filter control |
| 0x20   | RX_DMA   | RX DMA address |
| 0x30   | TX_DMA   | TX DMA address |
| 0x40   | STATS    | Statistics registers |

## Testing

### Basic Functionality Test

```bash
# Load driver
sudo modprobe enhanced_xpu

# Verify device
ls -l /dev/enhanced_xpu

# Test monitor mode
xpu_mon -c 6 -n 10

# Test injection
xpu_inject -t beacon:TestAP -c 1

# Test Remote ID
xpu_remote_id test -u "TEST" -l 0,0 -a 50
```

### Remote ID Compliance Test

```bash
# Terminal 1: Transmit
xpu_remote_id transmit -u "DRONE-001" -l 37.7749,-122.4194 -a 100

# Terminal 2: Monitor
xpu_remote_id monitor -v
```

## Troubleshooting

### Driver Issues

**Device not found:**
```bash
# Check if module loaded
lsmod | grep enhanced_xpu

# Check kernel messages
dmesg | grep enhanced_xpu

# Manual load
sudo insmod driver/enhanced_xpu.ko
```

**Permission denied:**
```bash
sudo chmod 666 /dev/enhanced_xpu
```

### Library Issues

**Library not found:**
```bash
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
sudo ldconfig
```

### Tool Issues

**Monitor mode not working:**
- Ensure driver is loaded
- Check device permissions
- Verify hardware is configured correctly

## Performance

- **RX Throughput**: Up to 100 Mbps
- **TX Throughput**: Up to 54 Mbps
- **Latency**: <1ms (DMA)
- **Remote ID TX Rate**: 1 Hz (ASTM F3411 compliant)
- **Packet Capture**: Up to 10,000 packets/sec

## Compliance

### ASTM F3411 Remote ID

- ✅ Message Types: Basic ID, Location, Self-ID, Operator ID
- ✅ Transport: WiFi NAN (IEEE 802.11)
- ✅ Transmission Rate: 1 Hz
- ✅ Message Size: 25 bytes
- ✅ Accuracy Encoding: Per specification
- ✅ Timestamp: Synchronized

### WiFi Standards

- ✅ IEEE 802.11a/b/g/n
- ✅ Monitor Mode (RFMON)
- ✅ Frame Injection
- ✅ WiFi Aware / NAN

## License

AGPL-3.0-only

## Support

For issues and questions:
- GitHub: https://github.com/open-sdr/openwifi-hw
- Documentation: See `/docs` directory

## Contributors

OpenWiFi Team, 2025
