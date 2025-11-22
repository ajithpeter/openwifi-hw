# OpenWiFi RFSoC Porting Guide

**Complete guide for porting OpenWiFi from AD9361+Zynq to RFSoC platforms**

Author: System Analysis Team
Date: 2025
Version: 1.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Hardware Differences](#hardware-differences)
4. [Sample Rate and Clocking Architecture](#sample-rate-and-clocking)
5. [Data Path Mapping](#data-path-mapping)
6. [FPGA Implementation](#fpga-implementation)
7. [Software/Driver Changes](#software-driver-changes)
8. [Build Process](#build-process)
9. [Testing and Validation](#testing-and-validation)
10. [Multi-Channel MIMO Extensions](#mimo-extensions)
11. [Troubleshooting](#troubleshooting)

---

## Executive Summary

This guide documents the complete process of porting OpenWiFi from traditional AD9361 transceiver-based Zynq platforms to RFSoC platforms with integrated RF Data Converters. The port maintains full IEEE 802.11a/g/n compatibility while leveraging RFSoC's superior RF performance and multi-channel capabilities.

### Key Benefits of RFSoC Platform

- **Integrated RF Front-End**: No external AD9361 needed
- **Higher Sample Rates**: Up to 6.4 GSPS DAC, 4.0 GSPS ADC
- **Multi-Tile Synchronization (MTS)**: Phase-coherent multi-channel operation
- **Better Dynamic Range**: 14-16 bit ADC/DAC vs 12-bit AD9361
- **Reduced BOM Cost**: Eliminates external transceiver IC
- **MIMO Ready**: Native support for 2×2, 4×4, or larger arrays

### Supported Platforms

- **RFSoC4x2** (RealDigital): xczu48dr-ffvg1517-2-e
- **ZCU208/216** (Xilinx): xczu28dr/xczu48dr with RF8/RF16 cards
- **ZCU111** (Xilinx): xczu28dr with integrated RF

---

## Architecture Overview

### Current OpenWiFi Architecture (AD9361-based)

```
┌─────────────────────────────────────────────────────┐
│ Zynq-7000 / Zynq MPSoC                              │
│  ┌──────────────────────────────────────┐           │
│  │ Processing System (PS)               │           │
│  │  - Linux + mac80211 WiFi stack       │           │
│  │  - Device drivers                    │           │
│  └─────────┬────────────────────────────┘           │
│            │ AXI DMA                                 │
│  ┌─────────▼────────────────────────────┐           │
│  │ Programmable Logic (PL)              │           │
│  │  ┌────────┐  ┌────────┐  ┌────────┐ │           │
│  │  │ xpu    │  │ tx_intf│  │rx_intf │ │           │
│  │  └────────┘  └───┬────┘  └───▲────┘ │           │
│  │  ┌──────────────┼────────────┼────┐ │           │
│  │  │ openofdm_tx  │            │ rx │ │           │
│  │  └──────────────┼────────────┼────┘ │           │
│  └─────────────────┼────────────┼──────┘           │
│            20 MSPS IQ    20 MSPS IQ                 │
└────────────────────┼────────────┼──────────────────┘
                     │            │
           ┌─────────▼────────────▲─────────┐
           │  AD9361 Transceiver            │
           │  - 40 MHz sample clock         │
           │  - 2T2R (dual antenna)         │
           │  - External SPI control        │
           └────────────┬───────────────────┘
                        │ RF
                        ▼
                  WiFi 2.4/5 GHz
```

### RFSoC-Based Architecture

```
┌──────────────────────────────────────────────────────┐
│ Zynq UltraScale+ RFSoC                               │
│  ┌──────────────────────────────────────┐            │
│  │ Processing System (PS)               │            │
│  │  - Linux + mac80211 WiFi stack       │            │
│  │  - Device drivers + RFDC control     │            │
│  └─────────┬────────────────────────────┘            │
│            │ AXI DMA                                  │
│  ┌─────────▼────────────────────────────┐            │
│  │ Programmable Logic (PL)              │            │
│  │  ┌────────┐  ┌────────┐  ┌────────┐ │            │
│  │  │ xpu    │  │ tx_intf│  │rx_intf │ │            │
│  │  └────────┘  └───┬────┘  └───▲────┘ │            │
│  │  ┌──────────────┼────────────┼────┐ │            │
│  │  │ openofdm_tx  │            │ rx │ │            │
│  │  └──────────────┼────────────┼────┘ │            │
│  │  ┌──────────────▼────────────┴────┐ │            │
│  │  │ RFDC Adapters (NEW)            │ │            │
│  │  │  - Sample rate conversion      │ │            │
│  │  │  - AXI-Stream ↔ Parallel       │ │            │
│  │  └──────────────┬─────────────────┘ │            │
│  │                 │ AXI-Stream         │            │
│  │  ┌──────────────▼─────────────────┐ │            │
│  │  │ RF Data Converter IP           │ │            │
│  │  │  - Multi-Tile Sync (MTS)       │ │            │
│  │  │  - 4 GSPS ADC, 6.4 GSPS DAC    │ │            │
│  │  └──────────────┬─────────────────┘ │            │
│  └─────────────────┼───────────────────┘            │
│                    │ Internal Analog                 │
│  ┌─────────────────▼─────────────────┐              │
│  │ RF ADC/DAC Tiles (On-Chip)        │              │
│  │  - Direct RF sampling             │              │
│  │  - Multi-channel phase coherent   │              │
│  └─────────────────┬─────────────────┘              │
└────────────────────┼──────────────────────────────┘
                     │ RF (on-chip analog)
                     ▼
               WiFi 2.4/5 GHz
```

---

## Hardware Differences

### AD9361 vs RFSoC RFDC Comparison

| Feature | AD9361 (Current) | RFSoC RFDC (Target) |
|---------|------------------|---------------------|
| **Interface** | LVDS, SPI control | AXI-Stream, AXI-Lite |
| **ADC Resolution** | 12-bit | 14-bit (Gen3) |
| **DAC Resolution** | 12-bit | 14-bit (Gen3) |
| **Max ADC Rate** | 61.44 MSPS | 5 GSPS |
| **Max DAC Rate** | 122.88 MSPS | 10 GSPS |
| **Channels** | 2 RX, 2 TX | 8-16 ADC, 8-16 DAC |
| **Clock Source** | Internal PLL | External + Internal PLLs |
| **Synchronization** | Not supported | Multi-Tile Sync (MTS) |
| **MIMO Support** | Diversity only | Full phase coherence |
| **Control** | SPI registers | AXI-Lite registers |
| **Clocking** | Generates clocks | Requires reference clock |

### Data Format Differences

**AD9361 Output:**
```
- Parallel 12-bit samples @ 40 MHz
- Packed to 64-bit: {I1[11:0], Q1[11:0], I0[11:0], Q0[11:0]}
- 2 channels maximum
```

**RFDC Output:**
```
- AXI-Stream 128/256-bit @ fabric clock (250-500 MHz)
- Format: Multiple samples per clock cycle
- 14/16-bit samples (configurable)
- Up to 8 channels per tile
```

---

## Sample Rate and Clocking

### Current OpenWiFi Clocking (AD9361)

```
AD9361 L-CLK (40 MHz)
  ↓
util_ad9361_divclk (IP core)
  ↓ (generates baseband clock)
Baseband: 100 MHz (NUM_CLK_PER_US = 100)
  ↓ (sample enable strobe every 5 clocks)
WiFi Sampling: 20 MSPS
```

### RFSoC Clocking Architecture

```
External LMK04828 Clock Generator
  ├─ PL_CLK: 500 MHz → FPGA reference
  └─ PL_SYSREF: ~5 MHz → MTS synchronization
       ↓
┌──────────────────────────────────────┐
│ FPGA Clocking                        │
│  PL_CLK (500 MHz)                    │
│    ↓                                 │
│  BUFG → MTSclkwiz (MMCM)             │
│    ├─ CLKOUT0: 500 MHz (RF fabric)  │
│    ├─ CLKOUT1: 250 MHz (decimation) │
│    ├─ CLKOUT2: 100 MHz (baseband)   │
│    └─ CLKOUT3: 20 MHz (sample clock)│
└──────────────────────────────────────┘
```

### Sample Rate Conversion Chain

**RX Path (RFDC ADC → WiFi Baseband):**
```
RFDC ADC: 983.04 MSPS (or 491.52 MSPS)
  ↓ [CIC Decimation by 8]
  122.88 MSPS
  ↓ [FIR Decimation by 6]
  20.48 MSPS
  ↓ [Rational Resampler 125/128]
  20.0 MSPS (WiFi baseband)
```

**TX Path (WiFi Baseband → RFDC DAC):**
```
WiFi Baseband: 20.0 MSPS
  ↓ [Rational Resampler 128/125]
  20.48 MSPS
  ↓ [FIR Interpolation by 6]
  122.88 MSPS
  ↓ [CIC Interpolation by 8]
  983.04 MSPS (RFDC DAC)
```

**Filter Specifications:**

*CIC Filter:*
- Stages: 5
- Passband droop: <0.05 dB @ 8 MHz
- Stopband: >80 dB
- Resources: ~500 LUTs, 0 DSP

*FIR Decimation/Interpolation:*
- Taps: 72 (polyphase)
- Stopband: >80 dB
- Resources: 12 DSP48, 2 BRAM

*Rational Resampler:*
- Taps: 1280 (optimized)
- Stopband: >90 dB
- Resources: 32 DSP48, 8 BRAM

---

## Data Path Mapping

### RX Path Detailed Mapping

**AD9361 (Current):**
```verilog
// File: ip/rx_intf/src/adc_intf.v
// Input: AD9361 parallel data
input [63:0] adc_data;      // {I1, Q1, I0, Q0}
input adc_valid;            // 40 MHz strobe

// Decimation
assign adc_valid_decimate = (adc_valid_count == 0);  // 2:1 decimation

// Clock crossing (adc_clk → acc_clk)
always @(posedge acc_clk) begin
    adc_data_stage1 <= adc_data;
    adc_data_stage2 <= adc_data_stage1;
end

// Output to rx_intf: 20 MSPS @ 100 MHz
output [63:0] data_to_bb;
output data_to_bb_valid;
```

**RFSoC (New):**
```verilog
// File: ip/rfsoc_rf_intf/src/rfdc_adc_adapter.v
// Input: RFDC AXI-Stream
input [127:0] s_axis_adc_tdata;
input s_axis_adc_tvalid;
output s_axis_adc_tready;

// Clock domain crossing FIFO
xpm_fifo_async adc_cdc_fifo (
    .wr_clk(rfdc_adc_clk),      // 250 MHz
    .rd_clk(openwifi_clk),      // 100 MHz
    .din(s_axis_adc_tdata),
    .dout(adc_data_async)
);

// Decimation in RFDC clock domain
reg [3:0] decim_count;
assign decim_strobe = (decim_count == 0);

// Output to rx_intf: 20 MSPS @ 100 MHz (compatible format)
output [63:0] adc_data;
output adc_data_valid;
```

### TX Path Detailed Mapping

**AD9361 (Current):**
```verilog
// File: ip/tx_intf/src/dac_intf.v
// Input from tx_intf: 20 MSPS @ 100 MHz
input [31:0] data_from_acc;    // {Q, I}
input read_bb_fifo;

// Interpolation 2:1 (zero-stuffing)
reg dac_phase;
assign dac_data_internal = dac_phase ? data_from_acc : 32'd0;

// Output to AD9361: 40 MHz
output [63:0] dac_data;        // {I1, Q1, I0, Q0}
```

**RFSoC (New):**
```verilog
// File: ip/rfsoc_rf_intf/src/rfdc_dac_adapter.v
// Input from tx_intf: 20 MSPS @ 100 MHz
input [63:0] dac_data;         // {I1, Q1, I0, Q0}
input dac_data_valid;

// Clock domain crossing FIFO
xpm_fifo_async dac_cdc_fifo (
    .wr_clk(openwifi_clk),      // 100 MHz
    .rd_clk(rfdc_dac_clk),      // 250 MHz
    .din(dac_data),
    .dout(dac_data_async)
);

// Interpolation 12:1 (sample hold)
reg [3:0] interp_count;
reg [127:0] dac_data_hold;

always @(posedge rfdc_dac_clk) begin
    if (interp_count == 0)
        dac_data_hold <= dac_data_async;  // New sample
    // else hold previous sample
    interp_count <= (interp_count == 11) ? 0 : interp_count + 1;
end

// Output to RFDC: AXI-Stream @ 250 MHz
output [127:0] m_axis_dac_tdata;
output m_axis_dac_tvalid;
```

---

## FPGA Implementation

### File Structure for RFSoC4x2 Board

```
openwifi-hw/
├── boards/
│   └── rfsoc4x2/                           ← NEW
│       ├── set_files.tcl                   ← Board file list
│       ├── synth_impl_strategy.tcl         ← Build strategy
│       ├── src/
│       │   ├── system.bd                   ← Block design (create in Vivado)
│       │   ├── system_wrapper.v            ← BD wrapper (auto-generated)
│       │   ├── system_top.v                ← Top-level HDL
│       │   ├── rfsoc4x2_constr.xdc         ← Pin constraints
│       │   └── system.xdc                  ← Timing constraints
│       └── ip_repo/                        ← Generated IP repository
├── ip/
│   ├── parse_board_name.tcl                ← MODIFIED (add rfsoc4x2)
│   └── rfsoc_rf_intf/                      ← NEW IP core
│       └── src/
│           ├── rfdc_adc_adapter.v          ← ADC interface
│           └── rfdc_dac_adapter.v          ← DAC interface
└── boards/post_script_common.tcl           ← MODIFIED (add rfsoc check)
```

### Block Design Components

**Required IP Cores:**

1. **Zynq UltraScale+ MPSoC** (zynq_ultra_ps_e)
   - PS-PL interfaces configured
   - AXI HP ports for DMA
   - Clocks: FCLK_CLK0 (100 MHz)

2. **RF Data Converter** (usp_rf_data_converter)
   - ADC Tiles: 2 (Tile 0, Tile 1)
   - DAC Tiles: 2 (Tile 0, Tile 1)
   - MTS enabled: true
   - Reference clock: 500 MHz external

3. **Clocking Wizard** (clk_wiz) for MTS
   - Input: 500 MHz
   - Outputs: 500 MHz, 250 MHz, 100 MHz, 20 MHz

4. **OpenWiFi IP Cores** (existing)
   - xpu
   - tx_intf
   - rx_intf
   - openofdm_tx
   - openofdm_rx
   - side_ch (optional)

5. **RFDC Adapters** (new)
   - rfdc_adc_adapter
   - rfdc_dac_adapter

6. **AXI Interconnects**
   - For DMA data paths
   - For control registers (AXI-Lite)

7. **AXI DMA** (or AXI MCDMA for multi-channel)
   - TX path: MM2S + S2MM
   - RX path: MM2S + S2MM

### Key Block Design Connections

```tcl
# RFDC to RX Adapter
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m00_axis] \
                    [get_bd_intf_pins rfdc_adc_adapter_0/s_axis_adc0]

# RX Adapter to rx_intf
connect_bd_net [get_bd_pins rfdc_adc_adapter_0/adc_data] \
               [get_bd_pins rx_intf_0/adc_data]
connect_bd_net [get_bd_pins rfdc_adc_adapter_0/adc_data_valid] \
               [get_bd_pins rx_intf_0/adc_valid]

# tx_intf to TX Adapter
connect_bd_net [get_bd_pins tx_intf_0/dac_data] \
               [get_bd_pins rfdc_dac_adapter_0/dac_data]
connect_bd_net [get_bd_pins tx_intf_0/dac_valid] \
               [get_bd_pins rfdc_dac_adapter_0/dac_data_valid]

# TX Adapter to RFDC
connect_bd_intf_net [get_bd_intf_pins rfdc_dac_adapter_0/m_axis_dac0] \
                    [get_bd_intf_pins usp_rf_data_converter_0/s00_axis]

# Clocks
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] \
               [get_bd_pins rx_intf_0/s00_axi_aclk]
connect_bd_net [get_bd_pins usp_rf_data_converter_0/clk_adc0] \
               [get_bd_pins rfdc_adc_adapter_0/rfdc_adc_clk]
```

### RFDC Configuration

```tcl
# Critical RFDC settings for WiFi
set_property CONFIG.ADC0_Sampling_Rate {0.98304} $rfdc
set_property CONFIG.ADC0_Refclk_Freq {491.52} $rfdc
set_property CONFIG.ADC0_Fabric_Freq {245.76} $rfdc
set_property CONFIG.ADC0_Multi_Tile_Sync {true} $rfdc
set_property CONFIG.ADC_Slice00_Enable {true} $rfdc
set_property CONFIG.ADC_Slice01_Enable {true} $rfdc

set_property CONFIG.DAC0_Sampling_Rate {0.98304} $rfdc
set_property CONFIG.DAC0_Refclk_Freq {491.52} $rfdc
set_property CONFIG.DAC0_Fabric_Freq {245.76} $rfdc
set_property CONFIG.DAC0_Multi_Tile_Sync {true} $rfdc
```

---

## Software/Driver Changes

### Device Tree Modifications

**Add RFSoC-specific nodes:**

```dts
/ {
    amba_pl: amba_pl {
        #address-cells = <2>;
        #size-cells = <2>;
        compatible = "simple-bus";
        ranges;

        /* RF Data Converter */
        usp_rf_data_converter_0: usp_rf_data_converter@a0000000 {
            compatible = "xlnx,usp-rf-data-converter-2.6";
            reg = <0x0 0xa0000000 0x0 0x40000>;
            clocks = <&zynqmp_clk 71>, <&dac0_clk>, <&dac1_clk>,
                     <&adc0_clk>, <&adc1_clk>;
            clock-names = "s_axi_aclk", "dac0_clk", "dac1_clk",
                          "adc0_clk", "adc1_clk";
        };

        /* RFDC Adapters */
        rfdc_adc_adapter_0: rfdc-adc-adapter@a0050000 {
            compatible = "openwifi,rfdc-adc-adapter-1.0";
            reg = <0x0 0xa0050000 0x0 0x1000>;
        };

        rfdc_dac_adapter_0: rfdc-dac-adapter@a0060000 {
            compatible = "openwifi,rfdc-dac-adapter-1.0";
            reg = <0x0 0xa0060000 0x0 0x1000>;
        };

        /* OpenWiFi IP blocks (existing) */
        openwifi_xpu: openwifi-xpu@83c00000 {
            compatible = "openwifi,xpu-1.0";
            reg = <0x0 0x83c00000 0x0 0x100>;
        };

        /* ... other openwifi nodes ... */
    };

    /* Reserved memory for DMA */
    reserved-memory {
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;

        openwifi_dma: openwifi-dma@70000000 {
            compatible = "shared-dma-pool";
            reg = <0x0 0x70000000 0x0 0x10000000>;  /* 256MB */
            reusable;
        };
    };
};
```

### Driver Initialization Sequence

**Replace AD9361 control with RFDC control:**

```c
// Current: AD9361 via SPI
ad9361_init();
ad9361_set_tx_freq(2412000000);  // Channel 1
ad9361_set_rx_gain_mode(RF_GAIN_MGC);

// RFSoC: RFDC via xrfdc library
#include <linux/fpga/xrfdc.h>

struct xrfdc *rfdc;
rfdc = xrfdc_probe(pdev);

// Configure clock chips (LMK/LMX)
xrfclk_set_ref_clks(500.0, 500.0);

// Configure ADC tile
struct xrfdc_adc_tile_config adc_cfg = {
    .sampling_rate = 983.04,
    .fabric_clk_div = 4,
    .mixer_mode = XRFDC_MIXER_MODE_C2R,
    .nco_freq = 2412.0  // WiFi channel 1
};
xrfdc_set_adc_config(rfdc, 0, 0, &adc_cfg);

// Perform Multi-Tile Sync
xrfdc_mts_adc_config mts_adc = {
    .RefTile = 0,
    .Tiles = 0x03,  // Tiles 0 and 1
    .Target_Latency = -1,  // Auto
    .SysRef_Enable = 1
};
xrfdc_mts_adc(rfdc, &mts_adc);
```

### Frequency Tuning

**NCO (Numerically Controlled Oscillator) for channel selection:**

```c
// Set WiFi channel frequency using RFDC mixer
void openwifi_set_channel_rfsoc(struct openwifi_priv *priv, u32 freq_mhz)
{
    struct xrfdc *rfdc = priv->rfdc;

    // Configure ADC NCO
    xrfdc_set_mixer_freq(rfdc, XRFDC_ADC_TILE, 0, 0, freq_mhz, 0.0);
    xrfdc_update_event(rfdc, XRFDC_ADC_TILE, 0, 0, XRFDC_EVENT_MIXER);

    // Configure DAC NCO
    xrfdc_set_mixer_freq(rfdc, XRFDC_DAC_TILE, 0, 0, freq_mhz, 0.0);
    xrfdc_update_event(rfdc, XRFDC_DAC_TILE, 0, 0, XRFDC_EVENT_MIXER);

    // No need to reconfigure PLL (unlike AD9361)
}
```

---

## Build Process

### Prerequisites

- Vivado 2022.2 or newer
- Vitis (not Vitis_HLS)
- Ubuntu 20.04/22.04 LTS
- RFSoC4x2 or compatible board

### Build Steps

```bash
# 1. Clone repository
cd /path/to/workspace
git clone https://github.com/open-sdr/openwifi-hw.git
cd openwifi-hw

# 2. Get openofdm_rx submodule
./get_ip_openofdm_rx.sh

# 3. Set environment
export XILINX_DIR=/opt/Xilinx
export BOARD_NAME=rfsoc4x2
export OPENWIFI_HW_IMG_DIR=/path/to/output

# 4. Generate IP repository (no ADI HDL for RFSoC)
cd boards/$BOARD_NAME
../create_ip_repo.sh $XILINX_DIR

# 5. Open Vivado and build
vivado -mode tcl

# In Vivado TCL console:
source ../openwifi.tcl
# Wait for synthesis and implementation...
# Bitstream will be generated automatically

# 6. Export hardware
cd boards/
./sdk_update.sh $BOARD_NAME $OPENWIFI_HW_IMG_DIR
```

### Automated Build Script

```bash
#!/bin/bash
# build_rfsoc.sh - Automated RFSoC build

set -e

BOARD=rfsoc4x2
JOBS=8

echo "Building OpenWiFi for $BOARD..."

# Generate IP repository
cd boards/$BOARD
../../create_ip_repo.sh $XILINX_DIR

# Run Vivado build
vivado -mode batch -source ../openwifi.tcl -tclargs $BOARD $JOBS

# Export
cd ..
./sdk_update.sh $BOARD $OPENWIFI_HW_IMG_DIR

echo "Build complete! Output in $OPENWIFI_HW_IMG_DIR/boards/$BOARD/"
```

---

## Testing and Validation

### Phase 1: Hardware Loopback

**Test RFDC without WiFi processing:**

```python
from pynq import Overlay

ol = Overlay('openwifi_rfsoc.bit')
rfdc = ol.usp_rf_data_converter_0

# Configure for loopback
# DAC Tile 0 → ADC Tile 0 (via external cable or on-chip)

# Generate tone on DAC
import numpy as np
fs = 983.04e6
f_tone = 10e6
t = np.arange(0, 1024) / fs
tone = np.int16(8000 * np.sin(2 * np.pi * f_tone * t))

# Load to DAC (via DMA or BRAM)
dac_buffer = ol.allocate(shape=(1024,), dtype=np.int16)
dac_buffer[:] = tone
ol.dac_dma.sendchannel.transfer(dac_buffer)

# Capture on ADC
adc_buffer = ol.allocate(shape=(1024,), dtype=np.int16)
ol.adc_dma.recvchannel.transfer(adc_buffer)

# Verify tone received
import matplotlib.pyplot as plt
plt.plot(adc_buffer)
plt.title('ADC Loopback Capture')
plt.show()
```

### Phase 2: OFDM Loopback

**Test OpenWiFi OFDM cores:**

```bash
# On FPGA board
cd /root/openwifi
./wgd.sh  # Load WiFi driver

# Generate test packet
./sdrctl dev sdr0 set reg xpu 30 0x12345678  # Set test MAC address

# Enable TX
./sdrctl dev sdr0 set reg tx_intf 0 0x00
./sdrctl dev sdr0 set reg tx_intf 13 1024  # TX gain

# Transmit test frame
echo "test" | ./inject_80211/inject_80211 -m n -r 7 wlan0

# Check RX (external loopback cable needed)
tcpdump -i wlan0
```

### Phase 3: Over-the-Air Test

**WiFi connectivity test:**

```bash
# Configure as AP
hostapd /etc/hostapd.conf &

# Scan for AP from another device
# Connect and verify:
# - Beacon transmission
# - Association/authentication
# - Data throughput (iperf3)

# From client:
iperf3 -c <RFSoC_IP> -t 60
```

### Validation Checklist

- [ ] RFDC ADC data capture works
- [ ] RFDC DAC output verified
- [ ] Multi-Tile Sync achieves lock
- [ ] Clock domain crossings clean (ILA verification)
- [ ] OFDM TX generates valid frames
- [ ] OFDM RX decodes frames correctly
- [ ] WiFi association successful
- [ ] Data throughput meets requirements (>50 Mbps)
- [ ] Channel switching works (2.4 GHz band)
- [ ] Timing constraints met (no negative slack)

---

## Multi-Channel MIMO Extensions

### 2×2 MIMO Architecture

**Required modifications for spatial multiplexing:**

1. **Duplicate OFDM cores:**
   - Instantiate 2× openofdm_tx
   - Instantiate 2× openofdm_rx

2. **Add MIMO processor:**
   ```verilog
   module mimo_processor (
       // 2 spatial streams in
       input [31:0] stream0_iq,
       input [31:0] stream1_iq,

       // Channel matrix
       input [127:0] h_matrix,  // 2×2 complex

       // 2 antenna signals out
       output [31:0] ant0_iq,
       output [31:0] ant1_iq
   );
   ```

3. **Configure RFDC for multiple tiles:**
   ```tcl
   set_property CONFIG.ADC0_Multi_Tile_Sync {true} $rfdc
   set_property CONFIG.ADC1_Multi_Tile_Sync {true} $rfdc
   set_property CONFIG.ADC_Slice10_Enable {true} $rfdc
   set_property CONFIG.ADC_Slice11_Enable {true} $rfdc
   ```

4. **Software: Enable HT-MIMO:**
   ```c
   // Configure for 802.11n MIMO
   ieee80211_hw_set(hw, SUPPORTS_HT_MIMO);
   hw->wiphy->bands[NL80211_BAND_2GHZ]->ht_cap.mcs.rx_mask[0] = 0xFF;
   hw->wiphy->bands[NL80211_BAND_2GHZ]->ht_cap.mcs.rx_mask[1] = 0xFF;
   ```

### Resource Scaling for MIMO

| Component | SISO | 2×2 MIMO | 4×4 MIMO |
|-----------|------|----------|----------|
| LUTs | 25% | 45% | 80% |
| FFs | 20% | 35% | 65% |
| BRAM | 30% | 50% | 85% |
| DSP48 | 15% | 40% | 75% |

---

## Troubleshooting

### Common Issues

**1. RFDC Tile Not Locking**

Symptoms: `XRFdc_MultiConverter_Sync() returns error`

Solutions:
- Verify external clock chip configuration (LMK04828, LMX2594)
- Check SYSREF signal presence (should be ~5 MHz)
- Ensure all tiles enabled before MTS call
- Try increasing Target_Latency parameter

**2. No Data on AXI-Stream**

Symptoms: `m_axis_tvalid always 0`

Solutions:
- Verify RFDC startup sequence completed
- Check fabric clock is running
- Use ILA to probe RFDC internal signals
- Confirm decimation/interpolation settings match fabric clock

**3. Timing Violations**

Symptoms: Setup/hold violations in implementation

Solutions:
- Increase CDC FIFO depth
- Add pipeline stages in data path
- Relax cross-domain max_delay constraints to 10 ns
- Use faster speed grade FPGA

**4. WiFi Frames Not Decoded**

Symptoms: RX sees energy but no valid packets

Solutions:
- Verify sample rate exactly 20 MSPS
- Check IQ swap (I/Q order)
- Adjust RX gain (slv_reg11)
- Verify OFDM FFT timing
- Check for DC offset or IQ imbalance

**5. MTS Phase Drift**

Symptoms: Phase coherence degrades over time

Solutions:
- Ensure stable temperature (add cooling)
- Recalibrate MTS periodically
- Check reference clock quality
- Use temperature-compensated crystal oscillator (TCXO)

### Debug Tools

**ILA Probe Points:**
```tcl
# Critical signals to monitor
create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 8192 [get_debug_cores u_ila_0]

# RFDC interface
set_property port_width 1 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets {rfdc/m00_axis_tvalid}]

set_property port_width 128 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets {rfdc/m00_axis_tdata[*]}]

# Sample rate converter
set_property port_width 64 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets {rfdc_adc_adapter/adc_data[*]}]
```

---

## Appendix

### A. Register Maps

*See main OpenWiFi documentation for complete register definitions.*

**RFSoC-Specific Additions:**

| Address | Name | Description |
|---------|------|-------------|
| 0xA005_0000 | RFDC_ADC_ADAPTER_CTRL | Decimation ratio, gain |
| 0xA005_0004 | RFDC_ADC_ADAPTER_STATUS | FIFO status, data valid |
| 0xA006_0000 | RFDC_DAC_ADAPTER_CTRL | Interpolation ratio |
| 0xA006_0004 | RFDC_DAC_ADAPTER_STATUS | FIFO status, underflow |

### B. References

1. Xilinx UG579: UltraScale Architecture DSP Slice
2. Xilinx PG269: RF Data Converter IP Product Guide
3. Xilinx XAPP1355: Multi-Tile Synchronization (MTS)
4. IEEE 802.11-2020: Wireless LAN Medium Access Control
5. OpenWiFi GitHub: https://github.com/open-sdr/openwifi

### C. Glossary

- **ADC**: Analog-to-Digital Converter
- **AXI**: Advanced eXtensible Interface (AMBA protocol)
- **CDC**: Clock Domain Crossing
- **CIC**: Cascaded Integrator-Comb (efficient decimation filter)
- **DAC**: Digital-to-Analog Converter
- **FIR**: Finite Impulse Response (filter)
- **MIMO**: Multiple-Input Multiple-Output
- **MTS**: Multi-Tile Synchronization
- **NCO**: Numerically Controlled Oscillator
- **OFDM**: Orthogonal Frequency Division Multiplexing
- **RFDC**: RF Data Converter (RFSoC integrated ADC/DAC)
- **SYSREF**: System Reference (for synchronization)

---

**Document Version History:**

- v1.0 (2025): Initial release for RFSoC4x2 platform

**Contact:**

For questions or contributions, please open an issue on the OpenWiFi GitHub repository.

