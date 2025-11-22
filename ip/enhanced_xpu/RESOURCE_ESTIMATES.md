# Resource Utilization Estimates for Enhanced XPU on Zynq7020

## Target Device: Xilinx Zynq7020 (xc7z020clg400-1)

### Device Resources Available:
- **LUTs**: 53,200
- **Flip-Flops**: 106,400
- **Block RAM (36Kb)**: 140
- **DSP48 Slices**: 220

---

## Module-by-Module Resource Breakdown

### 1. Base XPU Module (from original openwifi-hw)
**Estimated Resources** (based on typical synthesis results):
- **LUTs**: ~22,000 (41% of device)
- **FFs**: ~18,000 (17% of device)
- **BRAM**: ~45 (32% of device)
- **DSP**: ~8 (4% of device)

**Key Submodules**:
- AXI slave interface
- Packet filter control
- PHY RX parser
- TX control state machine
- CSMA/CA and backoff logic
- TSF timer
- RSSI calculation

### 2. Enhanced Packet Filter
**Component**: `enhanced_pkt_filter.v`

**Estimated Resources**:
- **LUTs**: ~600
  - Frame type decoder: ~100 LUTs
  - Subtype matching: ~150 LUTs
  - Address comparators (3x 48-bit): ~200 LUTs
  - Monitor mode logic: ~150 LUTs
- **FFs**: ~150
  - Output registers
  - State registers
- **BRAM**: 0
- **DSP**: 0

### 3. NAN Action Handler
**Component**: `nan_action_handler.v`

**Estimated Resources**:
- **LUTs**: ~1,800
  - State machine (12 states): ~200 LUTs
  - Byte counter (11-bit): ~50 LUTs
  - Attribute parsing logic: ~400 LUTs
  - Service ID comparison (48-bit): ~100 LUTs
  - Service ID buffer shift register: ~300 LUTs
  - Length checking and validation: ~200 LUTs
  - Output data path multiplexing: ~300 LUTs
  - Error detection logic: ~250 LUTs
- **FFs**: ~400
  - State registers
  - Counters and buffers
  - Service ID buffer (48 bits)
- **BRAM**: 0
  - Uses distributed RAM for small buffers
- **DSP**: 0

### 4. Remote ID Codec
**Component**: `remote_id_codec.v`

**Estimated Resources** (assuming minimal decoding):
- **LUTs**: ~1,200
  - Byte extraction state machine: ~200 LUTs
  - Field parsers (lat/lon/alt): ~600 LUTs
  - CRC/checksum validation: ~200 LUTs
  - Output formatting: ~200 LUTs
- **FFs**: ~300
  - Parsing state
  - Field buffers
- **BRAM**: 0
- **DSP**: 0

### 5. Vendor IE Codec
**Component**: `vendor_ie_codec.v`

**Estimated Resources**:
- **LUTs**: ~800
  - IE parser state machine: ~200 LUTs
  - OUI matching: ~100 LUTs
  - Length validation: ~150 LUTs
  - Data extraction: ~350 LUTs
- **FFs**: ~200
- **BRAM**: 0
- **DSP**: 0

### 6. Frame Injection Controller
**Component**: `frame_injection_ctrl.v`

**Estimated Resources**:
- **LUTs**: ~2,500
  - AXI slave interface: ~800 LUTs
  - State machine: ~300 LUTs
  - Frame buffer addressing: ~200 LUTs
  - Timing control: ~400 LUTs
  - Data path multiplexing: ~800 LUTs
- **FFs**: ~500
  - AXI registers
  - State and counters
- **BRAM**: 8 blocks (1KB frame buffer)
  - Frame buffer: 128 x 64-bit = 8 BRAMs (36Kb each)
- **DSP**: 0

### 7. Enhanced XPU Wrapper Integration
**Component**: `enhanced_xpu_wrapper.v`

**Estimated Resources**:
- **LUTs**: ~500
  - Signal routing and muxing: ~300 LUTs
  - Enhanced AXI interface logic: ~200 LUTs
- **FFs**: ~100
- **BRAM**: 0
- **DSP**: 0

---

## Total Resource Utilization Summary

### RX-Only Build (Monitor Mode + Remote ID Detection)
**Excludes**: Frame injection controller

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| **LUTs** | ~26,900 | 53,200 | **50.6%** |
| **FFs** | ~19,150 | 106,400 | **18.0%** |
| **BRAM** | ~45 | 140 | **32.1%** |
| **DSP** | ~8 | 220 | **3.6%** |

**Analysis**: This configuration fits comfortably on Zynq7020 with ~50% LUT headroom.

### Full Build (with Frame Injection)
**Includes**: All modules

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| **LUTs** | ~29,400 | 53,200 | **55.3%** |
| **FFs** | ~19,650 | 106,400 | **18.5%** |
| **BRAM** | ~53 | 140 | **37.9%** |
| **DSP** | ~8 | 220 | **3.6%** |

**Analysis**: Full build with frame injection still fits well on Zynq7020 with ~45% LUT headroom.

---

## Critical Path Analysis

### Expected Clock Frequency: 100 MHz
**Longest combinational paths** (estimated):

1. **AXI Read Path** (~8 ns)
   - Address decode → Register mux → Output register
   
2. **NAN Parser Service ID Match** (~7.5 ns)
   - 48-bit comparison + state transition logic
   
3. **Enhanced Packet Filter** (~6 ns)
   - 3x 48-bit address compare + type/subtype logic

**Timing Margin**: Should meet 100 MHz (10 ns period) with ~2 ns margin

---

## Resource Optimization Strategies

### If Resources Are Tight:

1. **Reduce Frame Buffer Size** (saves 4-6 BRAM)
   - 1KB → 512B: saves 4 BRAM blocks
   - Only affects frame injection max frame size

2. **Simplify NAN Parser** (saves ~800 LUTs)
   - Remove multi-attribute support
   - Parse only first Service Descriptor

3. **Disable Frame Injection** (saves ~2,500 LUTs + 8 BRAM)
   - RX-only mode sufficient for most Remote ID applications

4. **Optimize Address Comparators** (saves ~300 LUTs)
   - Use single comparator with time-multiplexing
   - Slight performance penalty

---

## Build Configuration Recommendations

### For antsdr (Zynq7020):

**Recommended Configuration**: RX-Only Build
- Target utilization: **~51% LUTs**
- Leaves headroom for user logic
- Sufficient for drone monitoring applications

**Alternative Configuration**: Full Build
- Target utilization: **~55% LUTs**
- Enables frame injection for testing
- Still reasonable margin for timing closure

### Synthesis Strategy:
- **Strategy**: `Flow_PerfOptimized_high`
- **Directives**: `PerformanceOptimized`
- **Retiming**: Enabled
- **FSM Extraction**: `one_hot`

### Implementation Strategy:
- **Strategy**: `Performance_ExplorePostRoutePhysOpt`
- **Place Directive**: `Explore`
- **Route Directive**: `Explore`
- **Post-Route Phys Opt**: Enabled

---

## Verification Notes

These estimates are based on:
- Manual analysis of module complexity
- Comparison with similar modules in openwifi-hw
- Typical Xilinx 7-series synthesis results
- Conservative estimates (actual may be 10-20% lower)

**Actual utilization will be determined by**:
- Vivado synthesis optimizations
- Specific coding patterns
- Build configuration options
- Tool version differences

**Recommended Action**: Run synthesis to get precise numbers.

---

## Build Time Estimates

On typical workstation (8-core, 32GB RAM):
- **Synthesis**: ~15-25 minutes
- **Implementation**: ~20-35 minutes
- **Bitstream Generation**: ~5 minutes
- **Total**: **40-65 minutes**

For faster builds:
- Use incremental compilation
- Reduce implementation effort (fewer routing iterations)
- Use SSD for project directory
