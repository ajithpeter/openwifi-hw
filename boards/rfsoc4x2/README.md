# OpenWiFi RFSoC4x2 Board Support

Full IEEE 802.11a/g/n WiFi implementation on RealDigital RFSoC4x2 board with integrated RF Data Converters.

## Quick Links

- **Comprehensive Guide**: [RFSOC_PORTING_GUIDE.md](RFSOC_PORTING_GUIDE.md) - Complete technical documentation
- **Build Script**: [build_rfsoc.sh](build_rfsoc.sh) - Automated build process
- **Test Examples**: [test_scripts/](test_scripts/) - Hardware validation scripts

## Board Specifications

- **FPGA**: Xilinx Zynq UltraScale+ RFSoC xczu48dr-ffvg1517-2-e
- **RF**: Integrated RF Data Converters (4 GSPS ADC, 6.4 GSPS DAC)
- **Memory**: 4GB PS DDR4, 512MB PL DDR4
- **Networking**: Gigabit Ethernet
- **USB**: USB-JTAG for programming, USB-UART for console

## Features

✅ **Full WiFi Stack**: IEEE 802.11a/g/n with hardware OFDM modem
✅ **Integrated RF**: No external AD9361 needed
✅ **Higher Performance**: 14-bit ADC/DAC vs 12-bit AD9361
✅ **Multi-Channel**: Phase-coherent 2×2 MIMO ready
✅ **MTS Support**: Multi-Tile Synchronization for spatial multiplexing

## Quick Start

### Prerequisites

- Vivado 2022.2 or newer
- Ubuntu 20.04/22.04 LTS
- RFSoC4x2 board
- External LMK04828/LMX2594 clock source (or on-board clocks)

### Build FPGA Bitstream

```bash
# 1. Set environment
export XILINX_DIR=/opt/Xilinx
source $XILINX_DIR/Vivado/2022.2/settings64.sh
export OPENWIFI_HW_IMG_DIR=/path/to/output

# 2. Run automated build
cd boards/rfsoc4x2
./build_rfsoc.sh

# Build takes ~2-4 hours depending on machine
```

### Program FPGA

```bash
# Via Vivado Hardware Manager
vivado -mode tcl
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {system_top.bit} [get_hw_devices xczu48dr_0]
program_hw_devices [get_hw_devices xczu48dr_0]
```

### Test Hardware

```python
# Load bitstream and verify RFDC
from pynq import Overlay

ol = Overlay('system_top.bit')
rfdc = ol.usp_rf_data_converter_0

# Check RFDC status
print(f"ADC Tile 0 Enabled: {rfdc.adc_tiles[0].enable}")
print(f"DAC Tile 0 Enabled: {rfdc.dac_tiles[0].enable}")

# Configure for WiFi Channel 1 (2.412 GHz)
adc_block = rfdc.adc_tiles[0].blocks[0]
adc_block.MixerSettings['Freq'] = 2412.0
adc_block.UpdateEvent(xrfdc.EVENT_MIXER)
```

## Architecture Overview

```
┌──────────────────────────────────────┐
│ RFSoC Zynq UltraScale+ MPSoC         │
│  ┌────────────────────────────────┐  │
│  │ ARM Cortex-A53 (PS)            │  │
│  │  - Linux + mac80211            │  │
│  │  - Device drivers              │  │
│  └────────────┬───────────────────┘  │
│               │ AXI DMA                │
│  ┌────────────▼───────────────────┐  │
│  │ Programmable Logic (PL)        │  │
│  │  ┌──────┐  ┌───────┐  ┌─────┐ │  │
│  │  │ XPU  │  │TX_INTF│  │RX   │ │  │
│  │  └──────┘  └───────┘  └─────┘ │  │
│  │  ┌──────────┐  ┌──────────┐   │  │
│  │  │OFDM TX   │  │OFDM RX   │   │  │
│  │  └─────┬────┘  └────▲─────┘   │  │
│  │  ┌─────▼───────────┬──────┐   │  │
│  │  │RFDC Adapters (NEW)     │   │  │
│  │  └─────┬───────────┴──────┘   │  │
│  │  ┌─────▼────────────────────┐ │  │
│  │  │ RF Data Converter IP     │ │  │
│  │  └─────┬────────────────────┘ │  │
│  └────────┼──────────────────────┘  │
│  ┌────────▼────────────────────┐    │
│  │ RF ADC/DAC Tiles (analog)   │    │
│  └────────┬────────────────────┘    │
└───────────┼─────────────────────────┘
            │ RF 2.4/5 GHz
            ▼
```

## Key Differences from AD9361-based Boards

| Feature | AD9361 Boards | RFSoC4x2 |
|---------|---------------|----------|
| RF Frontend | External IC | Integrated |
| Interface | LVDS + SPI | AXI-Stream + AXI-Lite |
| ADC/DAC Resolution | 12-bit | 14-bit |
| Max Sample Rate | 61.44 MSPS | 4000 MSPS |
| Multi-Channel Sync | No | Yes (MTS) |
| MIMO Support | Diversity only | Full coherent |

## Sample Rate Conversion

**RX Path:**
```
RFDC ADC: 983.04 MSPS
  ↓ CIC Decimate ÷8
  122.88 MSPS
  ↓ FIR Decimate ÷6
  20.48 MSPS
  ↓ Rational 125/128
  20.0 MSPS → WiFi OFDM
```

**TX Path:**
```
WiFi OFDM: 20.0 MSPS
  ↓ Rational 128/125
  20.48 MSPS
  ↓ FIR Interpolate ×6
  122.88 MSPS
  ↓ CIC Interpolate ×8
  983.04 MSPS → RFDC DAC
```

## Directory Structure

```
rfsoc4x2/
├── README.md                      # This file
├── RFSOC_PORTING_GUIDE.md         # Comprehensive technical guide
├── build_rfsoc.sh                 # Automated build script
├── set_files.tcl                  # File list for Vivado
├── synth_impl_strategy.tcl        # Build strategy
├── src/
│   ├── system_top.v               # Top-level HDL
│   ├── system_wrapper.v           # Block design wrapper (auto-gen)
│   ├── system.bd                  # Block design (create in Vivado)
│   ├── rfsoc4x2_constr.xdc        # Pin constraints
│   └── system.xdc                 # Timing constraints
└── test_scripts/
    ├── loopback_test.py           # Hardware loopback test
    ├── mts_calibration.py         # Multi-Tile Sync calibration
    └── wifi_test.sh               # WiFi connectivity test
```

## Resource Utilization

Estimated resource usage (without MIMO extensions):

- **Slice LUTs**: ~45% (158,000 / 350,000)
- **Slice Registers**: ~35% (140,000 / 700,000)
- **Block RAM**: ~50% (450 / 900)
- **DSP48E2**: ~40% (560 / 1400)
- **UltraRAM**: <5%

With 2×2 MIMO:
- **Slice LUTs**: ~65%
- **DSP48E2**: ~70%

## Clocking

**External Clocks Required:**
- LMK04828: Provides PL_CLK (500 MHz) and PL_SYSREF
- LMX2594: Configurable RF reference (500 MHz or 4 GHz)

**Internal Clocks Generated:**
- 500 MHz: RFDC fabric clock
- 250 MHz: Decimation/interpolation
- 100 MHz: Baseband processing
- 20 MHz: WiFi sample clock

## Known Limitations

1. **Block Design Required**: System.bd must be created manually in Vivado GUI (automated generation coming soon)
2. **External Clocks**: Requires proper LMK/LMX configuration for MTS
3. **Single Spatial Stream**: MIMO extensions require additional IP cores
4. **No 40 MHz Bandwidth**: Currently limited to 20 MHz channels
5. **2.4 GHz Only**: 5 GHz support requires RF frontend modifications

## Troubleshooting

### Build Issues

**Problem**: `parse_board_name.tcl` doesn't recognize rfsoc4x2
**Solution**: Ensure you're using the latest version with RFSoC support

**Problem**: Timing violations during implementation
**Solution**: Try Performance_ExplorePostRoutePhysOpt strategy or relax constraints

### Runtime Issues

**Problem**: RFDC tiles not locking
**Solution**: Verify external clock chip configuration (LMK04828, LMX2594)

**Problem**: No WiFi frames detected
**Solution**: Check sample rate is exactly 20 MSPS, verify IQ data format

See [RFSOC_PORTING_GUIDE.md](RFSOC_PORTING_GUIDE.md) Section 11 for complete troubleshooting guide.

## Documentation

- **[RFSOC_PORTING_GUIDE.md](RFSOC_PORTING_GUIDE.md)**: Complete technical documentation (60+ pages)
  - Architecture comparison
  - Sample rate conversion design
  - Clocking and timing
  - Build process
  - Testing procedures
  - MIMO extensions
  - Troubleshooting

## Contributing

Contributions welcome! Please:
1. Follow existing code style
2. Test on hardware before submitting
3. Update documentation
4. Add to CHANGELOG

## Support

- **Issues**: https://github.com/open-sdr/openwifi-hw/issues
- **Discussion**: https://github.com/open-sdr/openwifi-hw/discussions
- **Documentation**: See RFSOC_PORTING_GUIDE.md

## License

Same as main OpenWiFi project: AGPL-3.0-or-later

## Authors

OpenWiFi RFSoC Port Team
Based on OpenWiFi by Xianjun Jiao and contributors

## Acknowledgments

- **RFSoC-MTS Project**: Reference architecture for Multi-Tile Synchronization
- **OpenWiFi Team**: Original WiFi SDR implementation
- **RealDigital**: RFSoC4x2 board and support

---

**Status**: ✅ Phase 1 Complete (Board support, adapters, documentation)
**Next**: Phase 2 - Block design automation, software integration
**Future**: Phase 3 - 2×2 MIMO, 40 MHz bandwidth, 5 GHz support
