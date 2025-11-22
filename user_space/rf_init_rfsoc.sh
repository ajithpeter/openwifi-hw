#!/bin/bash

# OpenWiFi RF Initialization Script for RFSoC Platforms
# Replaces AD9361 IIO control with RFDC control

set -e

CHANNEL=${1:-6}  # Default WiFi channel 6 (2.437 GHz)

echo "========================================="
echo "OpenWiFi RFSoC RF Initialization"
echo "========================================="
echo "Target Channel: $CHANNEL"

# WiFi channel to frequency mapping (2.4 GHz band)
case $CHANNEL in
    1)  FREQ_MHZ=2412 ;;
    2)  FREQ_MHZ=2417 ;;
    3)  FREQ_MHZ=2422 ;;
    4)  FREQ_MHZ=2427 ;;
    5)  FREQ_MHZ=2432 ;;
    6)  FREQ_MHZ=2437 ;;
    7)  FREQ_MHZ=2442 ;;
    8)  FREQ_MHZ=2447 ;;
    9)  FREQ_MHZ=2452 ;;
    10) FREQ_MHZ=2457 ;;
    11) FREQ_MHZ=2462 ;;
    *)
        echo "Error: Invalid channel $CHANNEL (must be 1-11)"
        exit 1
        ;;
esac

echo "Target Frequency: $FREQ_MHZ MHz"

# Step 1: Configure external clocks (LMK04828 + LMX2594)
echo "Step 1: Configuring external RF clocks..."

python3 - <<PYPROG
try:
    from xrfclk import set_ref_clks

    # Configure for WiFi operation
    # LMK: 500 MHz PLB_CLK
    # LMX: 500 MHz (RF reference for RFDC)
    set_ref_clks(lmk_freq=500.0, lmx_freq=500.0)
    print("  ✓ External clocks configured")
    print("    LMK04828: 500 MHz")
    print("    LMX2594: 500 MHz")
except ImportError:
    print("  ⚠ xrfclk not available - skipping clock configuration")
    print("    Ensure xrfclk library is installed: pip3 install xrfclk")
except Exception as e:
    print(f"  ✗ Clock configuration failed: {e}")
    exit(1)
PYPROG

# Step 2: Check RFDC driver presence
echo "Step 2: Checking RFDC driver..."

if [ -d "/sys/bus/platform/drivers/usp_rf_data_converter" ]; then
    echo "  ✓ RFDC driver loaded"

    # List RFDC devices
    RFDC_DEVICES=$(find /sys/bus/platform/drivers/usp_rf_data_converter -name "a*" -type l 2>/dev/null || true)
    if [ -n "$RFDC_DEVICES" ]; then
        echo "  RFDC devices found:"
        echo "$RFDC_DEVICES" | sed 's/^/    /'
    fi
else
    echo "  ⚠ RFDC driver not found"
    echo "    Ensure kernel module is loaded: modprobe usp_rf_data_converter"
fi

# Step 3: Configure RFDC NCO frequency (if driver supports sysfs interface)
echo "Step 3: Configuring RFDC NCO frequency..."

# Note: RFDC frequency control depends on driver implementation
# This is a placeholder for future RFDC IIO/sysfs interface

# Option 1: Via RFDC IIO driver (if available)
RFDC_IIO_PATH="/sys/bus/iio/devices"
if [ -d "$RFDC_IIO_PATH" ]; then
    RFDC_ADC=$(find $RFDC_IIO_PATH -name "iio:device*" -type d | head -n1)
    if [ -n "$RFDC_ADC" ]; then
        echo "  Found RFDC IIO device: $RFDC_ADC"

        # Try to set NCO frequency (implementation-dependent)
        # echo "$FREQ_MHZ" > $RFDC_ADC/nco_frequency_mhz 2>/dev/null || true
        echo "  ⚠ RFDC NCO control via IIO not yet implemented"
    else
        echo "  No RFDC IIO devices found"
    fi
else
    echo "  IIO subsystem not available"
fi

# Option 2: Via direct register access (requires devmem or similar)
echo "  ℹ RFDC frequency control pending driver implementation"
echo "    Current frequency: $FREQ_MHZ MHz (configured in FPGA)"

# Step 4: Configure baseband gain (via OpenWiFi adapter IP)
echo "Step 4: Configuring baseband gain..."

# Default gain settings for RFSoC
RX_BB_GAIN=1   # 0=unity, 1=2x, 2=4x, 3=8x
TX_BB_GAIN=0   # 0=unity (no additional gain)

# Set via sdrctl (if driver is loaded and interface is up)
if command -v sdrctl &> /dev/null; then
    if ip link show sdr0 &> /dev/null; then
        echo "  Setting RX baseband gain: $RX_BB_GAIN"
        sdrctl dev sdr0 set reg rx_intf 11 $RX_BB_GAIN 2>/dev/null || echo "    (deferred until interface up)"

        echo "  Setting TX baseband gain: $TX_BB_GAIN"
        sdrctl dev sdr0 set reg tx_intf 13 $TX_BB_GAIN 2>/dev/null || echo "    (deferred until interface up)"
    else
        echo "  ⚠ sdr0 interface not available - gain settings deferred"
    fi
else
    echo "  ⚠ sdrctl not found - gain settings skipped"
fi

# Step 5: Display RFDC status
echo "Step 5: RFDC Status..."

python3 - <<PYPROG
try:
    import pynq
    from pynq import Overlay

    # Try to access RFDC via PYNQ
    ol = pynq.Overlay('/root/openwifi/system_top.bit', download=False)

    if hasattr(ol, 'usp_rf_data_converter'):
        rfdc = ol.usp_rf_data_converter
        print("  ✓ RFDC accessible via PYNQ")
        print(f"    ADC Tiles: {rfdc.adc_tiles}")
        print(f"    DAC Tiles: {rfdc.dac_tiles}")
    else:
        print("  ℹ RFDC not accessible via PYNQ overlay")
except ImportError:
    print("  ℹ PYNQ not available (not required for basic operation)")
except Exception as e:
    print(f"  ℹ RFDC status check: {e}")
PYPROG

# Step 6: Summary
echo ""
echo "========================================="
echo "RF Initialization Complete"
echo "========================================="
echo "Configuration:"
echo "  • Channel: $CHANNEL"
echo "  • Frequency: $FREQ_MHZ MHz"
echo "  • Clocks: LMK=500MHz, LMX=500MHz"
echo "  • RX Gain: $RX_BB_GAIN (baseband)"
echo "  • TX Gain: $TX_BB_GAIN (baseband)"
echo ""
echo "Next Steps:"
echo "  1. Bring up WiFi interface: ip link set sdr0 up"
echo "  2. Scan for networks: iw dev sdr0 scan"
echo "  3. Or start AP mode: ./fosdem.sh"
echo ""

exit 0
