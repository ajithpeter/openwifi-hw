# Enhanced XPU IP Core - Board Support Documentation

## Overview

This document provides board-specific information for the Enhanced XPU IP core, including hardware differences, pin mappings, clock domains, and integration considerations for each supported board variant.

## Supported Boards

### Summary Table

| Board        | FPGA Part         | Package  | Speed | AD9361 | Ethernet Location | Notes                    |
|--------------|-------------------|----------|-------|--------|-------------------|--------------------------|
| ANTSDR       | xc7z020clg400-1   | CLG400   | -1    | Yes    | PS Side           | Standard configuration   |
| ANTSDR E200  | xc7z020clg400-1   | CLG400   | -1    | Yes    | PL Side           | Compact, high bandwidth  |

## ANTSDR (Standard)

### Hardware Overview

- **FPGA**: Zynq7020 (xc7z020clg400-1)
- **RAM**: 512MB DDR3
- **RF**: AD9361 (70 MHz - 6 GHz)
- **Ethernet**: GEM controller on PS side
- **Form Factor**: Standard PCB design

### Pin Assignments

#### AD9361 Interface (LVDS)

Located in `boards/antsdr/src/antsdr_constr.xdc`:

```verilog
// RX Data (LVDS)
rx_clk_in_p      -> Pin N20 (LVDS_25, DIFF_TERM)
rx_frame_in_p    -> Pin Y16 (LVDS_25, DIFF_TERM)
rx_data_in_p[5:0] -> Pins W14, V20, R16, W18, V17, Y18

// TX Data (LVDS)
tx_clk_out_p     -> Pin N18 (LVDS_25)
tx_frame_out_p   -> Pin V16 (LVDS_25)
tx_data_out_p[5:0] -> Pins V15, T12, V12, U14, U18, T16

// Control Signals (LVCMOS25)
enable           -> Pin R18
txnrx            -> Pin P14
gpio_resetb      -> Pin N17
gpio_en_agc      -> Pin P16
gpio_sync        -> Pin U20

// SPI Interface
spi_csn          -> Pin P18 (PULLUP)
spi_clk          -> Pin R14
spi_mosi         -> Pin P15
spi_miso         -> Pin R19
```

#### I2C Interface

```verilog
iic_scl          -> Pin H18 (LVCMOS33, PULLUP)
iic_sda          -> Pin G17 (LVCMOS33, PULLUP)
```

#### GPIO Status/Control

```verilog
gpio_status[7:0] -> Pins T11, T14, T15, T17, T19, T20, U13, V13
gpio_ctl[3:0]    -> Pins T10, Y12, Y13, V11
```

### Clock Domains

#### Primary Clocks

| Clock        | Frequency  | Source           | Domain            |
|--------------|------------|------------------|-------------------|
| rx_clk       | 245.76 MHz | AD9361 RX        | RF RX domain      |
| tx_clk       | 245.76 MHz | AD9361 TX        | RF TX domain      |
| S_AXI_ACLK   | 100 MHz    | PS CLK          | AXI control       |
| clkin_10m    | 10 MHz     | External (opt)   | Reference         |

#### Clock Constraints

From `boards/antsdr/src/system.xdc`:

```tcl
create_clock -name rx_clk -period 4 [get_ports rx_clk_in_p]
```

### Synthesis Strategy

- **Strategy**: Flow_PerfOptimized_high
- **Retiming**: Enabled
- **FSM Extraction**: one_hot
- **Resource Sharing**: Disabled
- **LUT Combining**: Disabled

### Resource Availability

| Resource       | Total  | Note                              |
|----------------|--------|-----------------------------------|
| Slice LUTs     | 53,200 | Logic and routing                 |
| Slice Registers| 106,400| Flip-flops                        |
| Block RAM      | 140    | 36Kb blocks                       |
| DSP48E1        | 220    | Multiply-accumulate               |
| BUFG           | 32     | Global clock buffers              |
| MMCM/PLL       | 4      | Clock management                  |

### AXI Address Map

Recommended addresses for Enhanced XPU integration:

```
0x43C00000 - 0x43C00FFF  Enhanced XPU registers (4KB)
0x83C00000 - 0x83C0FFFF  High memory alias (if needed)
```

### Special Considerations

1. **Multiple Constraint Files**:
   - `antsdr_constr.xdc` - Main AD9361 interface
   - `antsdr_constr_lvds.xdc` - LVDS timing constraints
   - `ccbob_constr.xdc` - Optional carrier board constraints

2. **Clock Domain Crossings**:
   - Enhanced XPU operates in both AXI (100 MHz) and RF (245.76 MHz) domains
   - Use provided CDC (Clock Domain Crossing) constraints from `system.xdc`

3. **Timing**:
   - Critical path typically in packet classification logic
   - Meet timing with Performance_ExplorePostRoutePhysOpt strategy

## ANTSDR E200

### Hardware Overview

- **FPGA**: Zynq7020 (xc7z020clg400-1) - Same as ANTSDR
- **RAM**: 512MB DDR3
- **RF**: AD9361 (70 MHz - 6 GHz)
- **Ethernet**: **Moved to PL side** for higher bandwidth
- **Form Factor**: Compact design

### Key Hardware Differences from ANTSDR

1. **Ethernet Location**:
   - PL-based Ethernet controller (not PS GEM)
   - Supports higher bandwidth (>15 MSPS for SDR applications)
   - Reduces PS CPU load
   - Enables UHD driver support

2. **Pin Mapping**:
   - Different I/O bank assignments
   - Consolidated constraints in single file

3. **Size**:
   - Smaller form factor
   - Optimized for embedded applications

### Pin Assignments

#### AD9361 Interface (LVDS)

Located in `boards/antsdr_e200/src/system.xdc`:

```verilog
// Same AD9361 control signals as ANTSDR but different pin locations
gpio_status[7:0] -> Pins T15, K16, P14, P15, R14, J16, J15, T10
gpio_ctl[3:0]    -> Pins T11, V13, T14, U13
enable           -> Pin R18
txnrx            -> Pin N17
gpio_resetb      -> Pin T17
gpio_en_agc      -> Pin P16
gpio_sync        -> Pin U20

// SPI Interface
spi_csn          -> Pin T20 (PULLUP)
spi_clk          -> Pin R19
spi_mosi         -> Pin P18
spi_miso         -> Pin T19
```

#### RGMII Ethernet (PL Side)

**Note**: This is unique to E200!

```verilog
// RGMII Transmit
rgmii_td[3:0]    -> Pins C20, D19, D20, F19 (LVCMOS18)
rgmii_tx_ctl     -> Pin F20 (LVCMOS18)
rgmii_txc        -> Pin D18 (LVCMOS18)

// RGMII Receive
rgmii_rd[3:0]    -> Pins E18, E19, E17, F16 (LVCMOS18)
rgmii_rx_ctl     -> Pin G17 (LVCMOS18)
rgmii_rxc        -> Pin H16 (LVCMOS18)

// PHY Management
phy_rst_n        -> Pin B19 (LVCMOS18)
mdio_phy_mdio_io -> Pin A20 (LVCMOS18)
mdio_phy_mdc     -> Pin B20 (LVCMOS18)
```

#### I2C Interface

```verilog
iic_scl          -> Pin L20 (LVCMOS18, PULLUP)
iic_sda          -> Pin L19 (LVCMOS18, PULLUP)
```

### Clock Domains

#### Primary Clocks

Same as ANTSDR, plus:

| Clock        | Frequency  | Source           | Domain            |
|--------------|------------|------------------|-------------------|
| rgmii_rxc    | 125 MHz    | Ethernet PHY     | RGMII RX          |
| rgmii_txc    | 125 MHz    | RGMII TX logic   | RGMII TX          |

#### Additional Timing Constraints

```tcl
# RGMII timing (in system.xdc)
set_max_delay 5 -datapath_only -from [TX IQ path] -to [DAC interface]
set_false_path -through [CDC paths]
```

### Synthesis Strategy

- **Strategy**: Vivado Synthesis Defaults
- **Retiming**: Disabled (default)
- **FSM Extraction**: Auto
- **Resource Sharing**: Auto

**Note**: Less aggressive optimization than ANTSDR to accommodate Ethernet logic.

### Resource Availability

Same as ANTSDR (Zynq7020), but with additional PL resources allocated for Ethernet:

| Resource       | Total  | Used by Ethernet | Available for IP |
|----------------|--------|------------------|------------------|
| Slice LUTs     | 53,200 | ~3,000-4,000     | ~49,000          |
| Slice Registers| 106,400| ~2,000-3,000     | ~103,000         |
| Block RAM      | 140    | 4-8              | ~132             |

### AXI Address Map

Recommended addresses (same as ANTSDR):

```
0x43C00000 - 0x43C00FFF  Enhanced XPU registers (4KB)
0x44A00000 - 0x44A0FFFF  Ethernet MAC (if using AXI Ethernet)
```

### Special Considerations

1. **Ethernet Integration**:
   - PL Ethernet may require AXI Ethernet IP or AXI DMA
   - Ensure sufficient AXI bandwidth for concurrent WiFi + Ethernet
   - Priority arbitration recommended

2. **Single Constraint File**:
   - All constraints in `system.xdc`
   - Simpler than ANTSDR's multiple files

3. **UHD Support**:
   - E200 supports UHD driver (see [antsdr_uhd](https://github.com/MicroPhase/antsdr_uhd))
   - Enhanced XPU compatible with UHD workflow

4. **Bandwidth Considerations**:
   - Ethernet on PL enables >60 MB/s for baseband signals
   - Enhanced XPU should not impact Ethernet performance
   - Monitor AXI interconnect congestion

## Board Comparison for IP Integration

### Pin Mapping Differences

| Signal Type     | ANTSDR Pins                | E200 Pins                  | Impact on IP   |
|-----------------|----------------------------|----------------------------|----------------|
| AD9361 Control  | Mixed LVCMOS25/33          | Consolidated LVCMOS18/25   | None (abstracted) |
| I2C             | LVCMOS33, H18/G17          | LVCMOS18, L20/L19          | None           |
| Ethernet        | PS GEM (not in PL)         | RGMII on PL                | AXI bandwidth  |

### Clock Domain Differences

Both boards have identical RF clock domains. E200 adds RGMII clocks (125 MHz) but these do not directly affect Enhanced XPU.

### Synthesis Strategy Impact

| Aspect               | ANTSDR (Optimized)        | E200 (Default)             | Impact          |
|----------------------|---------------------------|----------------------------|-----------------|
| LUT Utilization      | Typically lower           | Slightly higher            | ~5-10% difference |
| Timing Closure       | Aggressive optimization   | Standard optimization      | Easier on E200  |
| Build Time           | Longer                    | Shorter                    | ~20-30% faster  |

## Integration Guidelines

### Common to Both Boards

1. **AXI Interface**:
   - Both use AXI4-Lite at 100 MHz
   - Same address width (32-bit)
   - Same data width (32-bit)

2. **Reset**:
   - Active-low reset (ARESETN)
   - Synchronized to AXI clock

3. **RF Interface**:
   - 245.76 MHz RX/TX clocks from AD9361
   - LVDS signaling
   - Proper termination required

### Board-Specific Recommendations

#### For ANTSDR

```tcl
# Example instantiation in block design
# Create instance
create_bd_cell -type ip -vlnv OpenWiFi:user:enhanced_xpu:1.0 enhanced_xpu_0

# Connect to AXI interconnect
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
                    [get_bd_intf_pins enhanced_xpu_0/S_AXI]

# Connect clocks
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins enhanced_xpu_0/S_AXI_ACLK]

# Connect reset
connect_bd_net [get_bd_pins rst_ps7_0_100M/peripheral_aresetn] \
               [get_bd_pins enhanced_xpu_0/S_AXI_ARESETN]

# Assign address
assign_bd_address [get_bd_addr_segs {enhanced_xpu_0/S_AXI/reg0 }]
set_property offset 0x43C00000 [get_bd_addr_segs {processing_system7_0/Data/SEG_enhanced_xpu_0_reg0}]
set_property range 4K [get_bd_addr_segs {processing_system7_0/Data/SEG_enhanced_xpu_0_reg0}]
```

#### For ANTSDR E200

Same as ANTSDR, plus consider:

```tcl
# Add Ethernet IP if not already present
# Ensure AXI interconnect has sufficient slave/master ports

# Optional: Add AXI Performance Monitor
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_perf_mon:5.0 axi_perf_mon_0

# Monitor Enhanced XPU traffic
connect_bd_intf_net [get_bd_intf_pins axi_perf_mon_0/SLOT_0_AXI] \
                    [get_bd_intf_pins enhanced_xpu_0/S_AXI]
```

## Flash and Boot Instructions

### ANTSDR

#### Programming via JTAG

```bash
# Generate bitstream
vivado -mode batch -source build_bitstream.tcl

# Program FPGA
vivado -mode batch -source program_fpga.tcl
```

#### SD Card Boot

1. Copy bitstream to SD card FAT partition
2. Rename to `BOOT.BIN` (or configure boot.scr)
3. Insert SD card and power on

### ANTSDR E200

Same procedure as ANTSDR. Additionally:

#### Network Programming (if Ethernet configured)

```bash
# Via SSH to embedded Linux
scp system.bit.bin root@antsdr:/lib/firmware/
cd /sys/class/fpga_manager/fpga0
echo system.bit.bin > firmware
```

## Validation and Testing

### Functional Tests

Both boards should pass:

1. **AXI Register Access**:
   ```bash
   devmem 0x43C00000 32  # Read control register
   devmem 0x43C00000 32 0x00000001  # Write enable bit
   ```

2. **Packet Filter Test**:
   - Inject test beacon frames
   - Verify NAN action frame detection
   - Check Remote ID frame classification

3. **Performance Test**:
   - Measure packet throughput
   - Verify no dropped frames at max rate
   - Check CPU load impact

### Resource Verification

After synthesis and implementation:

```tcl
# In Vivado TCL console
report_utilization -file util_report.txt
report_timing_summary -file timing_report.txt
```

Expected results should match estimates in BUILD_INSTRUCTIONS.md.

## Troubleshooting Board-Specific Issues

### ANTSDR

**Issue**: Timing violations in RF domain

**Solution**:
- Review `antsdr_constr_lvds.xdc`
- Ensure DIFF_TERM attribute on LVDS pins
- Check `set_max_delay` constraints

**Issue**: Multiple constraint files conflict

**Solution**:
- Check constraint file order in `set_files.tcl`
- system.xdc should be last

### ANTSDR E200

**Issue**: Ethernet and Enhanced XPU contention

**Solution**:
- Review AXI interconnect QoS settings
- Add AXI Performance Monitor
- Consider time-division multiplexing

**Issue**: Different pin assignments causing errors

**Solution**:
- Verify using correct `system.xdc` for E200
- Don't mix ANTSDR and E200 constraints

## Future Board Support

To add a new board variant:

1. Create board directory structure
2. Define pin constraints
3. Create board-specific build script
4. Update `build_all_variants.sh`
5. Test and document in this file

## References

- [ANTSDR Hardware Manual](https://github.com/MicroPhase/antsdr_docs)
- [ANTSDR E200 Documentation](https://github.com/MicroPhase/antsdr_uhd)
- [Zynq7020 Datasheet](https://www.xilinx.com/support/documentation/data_sheets/ds190-Zynq-7000-Overview.pdf)
- [AD9361 Reference Manual](https://www.analog.com/media/en/technical-documentation/data-sheets/AD9361.pdf)

## License

SPDX-FileCopyrightText: 2025 OpenWiFi Project
SPDX-License-Identifier: AGPL-3.0-only
