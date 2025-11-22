# enhanced_xpu Quick Start Guide

**Get started in 5 minutes!**

This guide will help you quickly set up and run your first enhanced_xpu example.

## Prerequisites

- ANTSDR or ANTSDR-E200 board
- Linux PC (Ubuntu 20.04+ recommended)
- USB cable and WiFi antenna
- Basic command-line knowledge

## Step 1: Hardware Setup (2 minutes)

```
1. Connect antenna to ANTSDR RF port
2. Connect USB cable from ANTSDR to PC
3. Power on ANTSDR (via USB or external power)
4. Wait for boot (~30 seconds)
```

**Verify Connection:**
```bash
# Check if device appears
ip addr show  # Look for 192.168.2.1 network

# SSH to ANTSDR (default password: analog)
ssh root@192.168.2.1
```

## Step 2: Software Setup (2 minutes)

### On Your PC

```bash
# Clone OpenWiFi repository
cd ~
git clone https://github.com/open-sdr/openwifi
cd openwifi/ip/enhanced_xpu/examples

# Build examples
make

# Or cross-compile for ARM
make CROSS_COMPILE=arm-linux-gnueabihf-
```

### Transfer to ANTSDR

```bash
# Copy examples to ANTSDR
scp monitor_beacons inject_beacon remote_id_transmitter remote_id_receiver root@192.168.2.1:/root/
```

### On ANTSDR

```bash
# SSH to ANTSDR
ssh root@192.168.2.1

# Load driver (if not already loaded)
cd /root
insmod sdr.ko

# Verify
ls /dev/sdr0  # Should exist
```

## Step 3: Run First Example (1 minute)

### Example 1: Monitor WiFi Beacons

```bash
# On ANTSDR
./monitor_beacons 6

# Output:
TIME      BSSID              CH   RSSI        ENCRYPTION    SSID
--------------------------------------------------------------------------------
14:23:45  AA:BB:CC:DD:EE:FF  6    -45 dBm     WPA2/WPA3     MyNetwork
14:23:46  11:22:33:44:55:66  6    -67 dBm     Open          GuestWiFi
```

**Press Ctrl+C to stop**

### Example 2: Inject Beacon Frame

```bash
# On ANTSDR
./inject_beacon -s "TestAP" -c 6 -i 100

# You should see the "TestAP" network appear on nearby WiFi scanners
```

**WARNING**: Only use in controlled environments! May be illegal in some jurisdictions.

## Step 4: Try More Examples

### Remote ID Transmitter (Drone)

```bash
# Simulated GPS (for testing)
./remote_id_transmitter -i "DRONE123456789" -c 6

# With real GPS module
./remote_id_transmitter -i "DRONE123456789" -g /dev/ttyUSB0 -c 6
```

### Remote ID Receiver

```bash
# In another terminal or on another device
./remote_id_receiver -c 6 -v

# You should see drone location updates
```

### wfb-ng Video Injector

```bash
# Test mode (inject test pattern)
./wfb_ng_injector -c 149 -r 18 -t

# With video stream (requires gstreamer)
gst-launch-1.0 videotestsrc ! x264enc ! h264parse ! fdsink | \
  ./wfb_ng_injector -c 149 -r 18
```

## Common Commands

### Change Channel

```bash
# 2.4 GHz
./monitor_beacons 1   # Channel 1 (2.412 GHz)
./monitor_beacons 6   # Channel 6 (2.437 GHz)
./monitor_beacons 11  # Channel 11 (2.462 GHz)

# 5 GHz
./monitor_beacons 36   # Channel 36 (5.180 GHz)
./monitor_beacons 149  # Channel 149 (5.745 GHz)
```

### Check Driver Status

```bash
# Check if driver loaded
lsmod | grep sdr

# Check device
ls -l /dev/sdr0

# View kernel messages
dmesg | tail -20
```

### Reload Driver

```bash
# Unload
rmmod sdr

# Reload
insmod /root/sdr.ko

# Verify
dmesg | grep sdr
```

## Troubleshooting

### Device Not Found

```bash
# Check connection
ip addr show

# Ping ANTSDR
ping 192.168.2.1

# Check USB
lsusb | grep -i xilinx
```

### /dev/sdr0 Missing

```bash
# Load driver
insmod /root/sdr.ko

# Check errors
dmesg | grep -i error
```

### No Frames Received

```bash
# Verify antenna is connected
# Check channel (use common channels like 1, 6, 11)
# Try different filter settings

# Debug mode
./monitor_beacons 6 | tee debug.log
```

### Permission Denied

```bash
# Run as root
sudo ./monitor_beacons 6

# Or add user to sdr group
sudo usermod -a -G sdr $USER
```

## Next Steps

Now that you've run the examples, explore more:

📖 **[User Guide](docs/USER_GUIDE.md)** - Complete feature documentation

📖 **[API Reference](docs/API_REFERENCE.md)** - Developer API details

📖 **[Remote ID Guide](docs/REMOTE_ID_GUIDE.md)** - Drone Remote ID implementation

🔧 **Customize Examples** - Modify the C code to suit your needs

🚀 **Build Your Application** - Use the API to create custom tools

## Example Use Cases

### WiFi Security Research

```bash
# Capture all management frames
./monitor_beacons 6  # Start with beacons

# Analyze with Wireshark
# (configure ANTSDR to forward frames to PC)
```

### Drone Remote ID

```bash
# Transmitter (on drone)
./remote_id_transmitter -i "DRONE001" -g /dev/ttyUSB0 -c 6

# Receiver (on ground)
./remote_id_receiver -c 6 -l drones.log
```

### FPV Video Streaming

```bash
# Transmitter (on drone with camera)
raspivid -t 0 -w 1280 -h 720 -fps 30 -b 2000000 -o - | \
  ./wfb_ng_injector -c 149 -r 24

# Receiver (ground station with wfb-ng)
# Use standard wfb-ng receiver
```

### WiFi Monitoring Dashboard

```bash
# Log all beacons to file
./monitor_beacons 6 > beacons.log &

# Analyze with script
tail -f beacons.log | grep -i "specific_ssid"
```

## Tips & Best Practices

✅ **Always connect antenna before powering on** (prevents RF damage)

✅ **Use channel 6 for maximum compatibility** (2.4 GHz, worldwide)

✅ **Start with low TX power** (10-15 dBm for testing)

✅ **Check local regulations** before using frame injection

✅ **Monitor dmesg** for errors: `dmesg -w`

✅ **Keep driver updated** with latest OpenWiFi releases

## Getting Help

- 📚 Read the [User Guide](docs/USER_GUIDE.md) for detailed documentation
- 💬 Ask questions on OpenWiFi forum
- 🐛 Report bugs on [GitHub Issues](https://github.com/open-sdr/openwifi/issues)
- 📧 Join the OpenWiFi mailing list

## Building Custom Applications

Use the examples as templates:

```bash
# Copy template
cp monitor_beacons.c my_app.c

# Edit code
nano my_app.c

# Build
gcc -o my_app my_app.c -I../include -lm

# Run
./my_app
```

See [API_REFERENCE.md](docs/API_REFERENCE.md) for API details.

## Summary

You've learned how to:

✅ Set up ANTSDR hardware
✅ Build and run enhanced_xpu examples
✅ Monitor WiFi frames
✅ Inject custom frames
✅ Use Remote ID for drones
✅ Troubleshoot common issues

**Congratulations!** You're ready to explore advanced WiFi SDR applications with enhanced_xpu.

---

**Need more details?** Check out the comprehensive [User Guide](docs/USER_GUIDE.md).

**Ready to develop?** See the [API Reference](docs/API_REFERENCE.md).

**Building a drone?** Read the [Remote ID Guide](docs/REMOTE_ID_GUIDE.md).

---

**Copyright © 2025 OpenWiFi Project**
**License: AGPL-3.0-only**
