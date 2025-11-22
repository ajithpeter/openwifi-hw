#!/bin/bash
# OpenWiFi RFSoC WiFi Functionality Test
# Tests complete WiFi stack on RFSoC platform

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}OpenWiFi RFSoC WiFi Test${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

# Check if running on board
if [ ! -d "/sys/class/fpga_manager" ]; then
    echo -e "${RED}ERROR: Not running on FPGA board${NC}"
    exit 1
fi

# Load bitstream
echo -e "${YELLOW}[1/7] Loading bitstream...${NC}"
if [ -f "system_top.bit.bin" ]; then
    echo system_top.bit.bin > /sys/class/fpga_manager/fpga0/firmware
    echo "Bitstream loaded"
else
    echo -e "${RED}ERROR: system_top.bit.bin not found${NC}"
    exit 1
fi

# Load device tree overlay
echo -e "${YELLOW}[2/7] Loading device tree overlay...${NC}"
if [ -f "pl.dtbo" ]; then
    mkdir -p /configfs/device-tree/overlays/full
    cat pl.dtbo > /configfs/device-tree/overlays/full/dtbo
    echo "Device tree overlay loaded"
else
    echo -e "${YELLOW}WARNING: pl.dtbo not found, skipping${NC}"
fi

# Configure clocks (if xrfclk utility available)
echo -e "${YELLOW}[3/7] Configuring RF clocks...${NC}"
if command -v xrfclk &> /dev/null; then
    python3 -c "import xrfclk; xrfclk.set_ref_clks(lmk_freq=500.0, lmx_freq=500.0)"
    echo "RF clocks configured"
else
    echo -e "${YELLOW}WARNING: xrfclk not available, assuming clocks configured${NC}"
fi

# Load WiFi driver
echo -e "${YELLOW}[4/7] Loading OpenWiFi driver...${NC}"
if [ -d "/root/openwifi" ]; then
    cd /root/openwifi
    ./wgd.sh
    echo "Driver loaded"
else
    echo -e "${RED}ERROR: OpenWiFi driver not found at /root/openwifi${NC}"
    echo "Please install openwifi software stack first"
    exit 1
fi

# Configure WiFi interface
echo -e "${YELLOW}[5/7] Configuring WiFi interface...${NC}"
INTERFACE="sdr0"
if ip link show $INTERFACE &> /dev/null; then
    ip link set $INTERFACE up
    echo "Interface $INTERFACE is up"
else
    echo -e "${RED}ERROR: Interface $INTERFACE not found${NC}"
    exit 1
fi

# Check register access
echo -e "${YELLOW}[6/7] Verifying hardware access...${NC}"
if command -v sdrctl &> /dev/null; then
    # Read FPGA version
    VERSION=$(sdrctl dev $INTERFACE get reg xpu 63)
    echo "FPGA version: 0x$VERSION"

    # Read MAC address
    MAC_LOW=$(sdrctl dev $INTERFACE get reg xpu 30)
    MAC_HIGH=$(sdrctl dev $INTERFACE get reg xpu 31)
    echo "MAC address registers: 0x$MAC_HIGH$MAC_LOW"
else
    echo -e "${YELLOW}WARNING: sdrctl not found, skipping register check${NC}"
fi

# Start as AP (optional)
echo -e "${YELLOW}[7/7] WiFi functionality tests...${NC}"
echo ""
echo "Manual tests required:"
echo "  1. Configure as AP:"
echo "     hostapd /etc/hostapd.conf &"
echo ""
echo "  2. Or scan for networks:"
echo "     iw dev $INTERFACE scan"
echo ""
echo "  3. Monitor packets:"
echo "     tcpdump -i $INTERFACE"
echo ""
echo "  4. Test throughput (after connection):"
echo "     iperf3 -s   # On this board"
echo "     iperf3 -c <board_ip> -t 60  # On client"
echo ""

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Basic setup complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "WiFi interface $INTERFACE is ready for testing"
echo "See RFSOC_PORTING_GUIDE.md for detailed test procedures"
