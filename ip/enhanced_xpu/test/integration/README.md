# Enhanced XPU Integration Tests

## Overview

This directory contains comprehensive integration tests for the enhanced_xpu modules, validating complete data flow paths and interactions between all components in the OpenWiFi hardware design.

## Test Suite Organization

### 1. Monitor Mode Integration Test (`monitor_mode_integration_tb.v`)

**Purpose:** Validates the complete RX path from antenna reception through packet filtering to DMA.

**Test Coverage:**
- Complete RX chain with real NAN Remote ID frames
- Packet filter correctly identifies NAN frames
- NAN handler extracts Remote ID payload
- Data reaches DMA in correct format
- Multiple frame types (beacons, data, NAN action frames)
- Promiscuous mode vs filtered mode
- FCS validation and error handling
- Address filtering (unicast, broadcast, multicast)

**Key Test Scenarios:**
1. **Basic Monitor Mode - Beacon Capture:** Verifies beacon frame detection and filtering
2. **NAN Remote ID Frame Detection:** Tests all 6 ASTM F3411 message types
3. **Promiscuous Mode:** Validates capture of all frames regardless of address
4. **Filtered Mode:** Tests selective frame acceptance based on configuration
5. **FCS Failure Handling:** Verifies optional capture of frames with CRC errors
6. **Mixed Frame Types:** Tests beacon, probe request/response, and NAN frames

**Expected Results:**
- All beacon frames captured when `capture_beacon` enabled
- NAN frames identified by OUI (0x506F9A) and OUI type (0x13)
- Correct frame type classification
- Proper address matching in non-promiscuous mode
- FCS failures blocked unless `capture_fcs_fail` enabled

**Run Time:** ~5-10 seconds

---

### 2. Frame Injection Integration Test (`injection_integration_tb.v`)

**Purpose:** Validates the complete TX path from DMA through frame injection to PHY transmission.

**Test Coverage:**
- Frame injection from software/DMA interface
- Configuration registers (rate, power, timing)
- Frame formatting and validation
- Timing constraints (SIFS, beacon intervals)
- Periodic Remote ID transmission (1 Hz per ASTM F3411)
- wfb-ng style broadcast frames (no-ACK mode)
- Rate and power control

**Key Test Scenarios:**
1. **Basic Frame Injection:** Tests beacon frame construction and transmission
2. **NAN Remote ID Injection:** Validates all message types (Basic ID, Location, System, etc.)
3. **Periodic Remote ID Transmission:** Verifies 1 Hz transmission interval
4. **wfb-ng Style Broadcast:** Tests high-throughput broadcast data frames
5. **Rate and Power Configuration:** Validates configuration register control
6. **Normal vs Injection Mode Timing:** Compares CSMA/CA vs direct injection

**Expected Results:**
- Frames transmitted with correct structure (MAC header + payload)
- Injection mode bypasses CSMA/CA for deterministic timing
- Periodic transmission maintains 1 Hz ±1ms accuracy
- Rate configuration correctly sets PHY transmission rate
- No-ACK mode skips ACK waiting period

**Run Time:** ~10-15 seconds

---

### 3. Remote ID End-to-End Test (`remote_id_e2e_tb.v`)

**Purpose:** Validates complete Remote ID round-trip: encode → transmit → receive → decode → verify.

**Test Coverage:**
- TX side: Generate Location message → encode NAN → inject → transmit
- RX side: Receive → filter → parse NAN → decode Remote ID → verify match
- All 6 ASTM F3411 message types
- Round-trip accuracy verification
- Real-world coordinates and speeds
- Edge cases (max altitude, equator, date line)

**Key Test Scenarios:**
1. **Basic ID Message (Type 0):** Static drone identification
2. **Location Message (Type 1):**
   - San Francisco coordinates (37.7487°N, 122.4203°W)
   - New York coordinates (40.7128°N, 74.0060°W)
   - London coordinates (51.4504°N, 0.1278°W)
3. **Self-ID Message (Type 3):** Operator description text
4. **System Message (Type 4):** Operator location and area information
5. **Operator ID Message (Type 5):** Operator identification
6. **Authentication Message (Type 2):** Cryptographic signature
7. **Flight Scenario Sequence:** Continuous location updates at 1 Hz
8. **Edge Cases:**
   - Maximum altitude (31,767.5 m)
   - Negative altitude (below sea level)
   - Equator crossing (latitude = 0)
   - International date line (longitude = ±180°)

**ASTM F3411 Message Format:**
```
All messages are exactly 25 bytes:
- Byte 0: Message type (0-5, 0xF for message pack)
- Bytes 1-24: Type-specific payload

Location Message (Type 1):
  Latitude: ±90° with 1e-7° resolution (32-bit signed)
  Longitude: ±180° with 1e-7° resolution (32-bit signed)
  Altitude: -1000 to +31767.5 m with 0.5 m resolution
  Speed: 0-254.25 m/s with 0.25 m/s resolution
  Direction: 0-360° with 1° resolution
```

**Expected Results:**
- Perfect round-trip match: TX payload == RX payload
- Coordinate precision maintained through encoding/decoding
- Message type correctly identified on RX
- NAN frame properly encapsulated with WiFi Alliance OUI
- Service ID hash matches: 0x886919_9D9209

**Run Time:** ~20-25 seconds

---

### 4. Stress Test (`stress_test_tb.v`)

**Purpose:** Validates system behavior under extreme high-load conditions.

**Test Coverage:**
- Continuous beacon transmission while receiving
- Multiple NAN frames in rapid succession
- Buffer overflow/underflow conditions
- Simultaneous TX and RX operations
- Maximum packet rate scenarios
- FPGA resource utilization monitoring
- Timing constraint validation
- Error recovery mechanisms

**Key Test Scenarios:**
1. **Beacon Storm:** 1000 beacons @ 10 MHz packet rate
2. **NAN Frame Burst:** 500 NAN frames @ 5 MHz packet rate
3. **Mixed Traffic High Load:** 2000 mixed packets with random types
4. **Sustained High Rate:** 10 seconds continuous operation
5. **Promiscuous Mode Stress:** 5000 packets with all frames captured
6. **Rapid TX/RX Switching:** Frequent context switching
7. **Resource Usage Validation:** FPGA utilization monitoring
8. **Error Recovery:** 100 FCS errors properly rejected

**Performance Targets:**
- **Monitor Mode Throughput:** >1000 packets/second
- **Injection Throughput:** >500 packets/second
- **Latency (RX):** <5 ms from antenna to DMA
- **Latency (TX):** <10 ms from user space to RF
- **Buffer Depth:** 256 packets (configurable)
- **No Overflows:** 0 buffer overflows under normal load

**Resource Usage (Zynq 7020):**
```
Target utilization:
  LUTs:   45,000-50,000 / 53,200 (85-94%)
  BRAMs:  90-120 / 140 (64-86%)
  DSP48s: 50-80 / 220 (23-36%)
```

**Expected Results:**
- No buffer overflows or underflows
- Stable operation under sustained load
- All FCS errors properly rejected
- Resource usage within target limits
- Throughput meets or exceeds targets

**Run Time:** ~30-40 seconds

---

## Running the Tests

### Prerequisites

1. **Vivado Simulator (xsim)** or **ModelSim/QuestaSim**
2. **Enhanced XPU source files:**
   - `ip/enhanced_xpu/src/enhanced_pkt_filter.v`
   - `ip/enhanced_xpu/include/remote_id_types.h`

### Manual Test Execution

#### Using Vivado xsim:

```bash
# Navigate to integration test directory
cd ip/enhanced_xpu/test/integration/

# Compile and run monitor mode test
xvlog -sv ../src/enhanced_pkt_filter.v monitor_mode_integration_tb.v
xelab -debug typical monitor_mode_integration_tb -s monitor_sim
xsim monitor_sim -runall

# Compile and run injection test
xvlog -sv ../src/enhanced_pkt_filter.v injection_integration_tb.v
xelab -debug typical injection_integration_tb -s injection_sim
xsim injection_sim -runall

# Compile and run Remote ID E2E test
xvlog -sv ../src/enhanced_pkt_filter.v remote_id_e2e_tb.v
xelab -debug typical remote_id_e2e_tb -s remote_id_e2e_sim
xsim remote_id_e2e_sim -runall

# Compile and run stress test
xvlog -sv ../src/enhanced_pkt_filter.v stress_test_tb.v
xelab -debug typical stress_test_tb -s stress_sim
xsim stress_sim -runall
```

#### Using Icarus Verilog (iverilog):

```bash
# Compile and run monitor mode test
iverilog -g2012 -o monitor_mode_sim \
  ../src/enhanced_pkt_filter.v \
  monitor_mode_integration_tb.v
vvp monitor_mode_sim

# Compile and run injection test
iverilog -g2012 -o injection_sim \
  ../src/enhanced_pkt_filter.v \
  injection_integration_tb.v
vvp injection_sim

# Compile and run Remote ID E2E test
iverilog -g2012 -o remote_id_e2e_sim \
  ../src/enhanced_pkt_filter.v \
  remote_id_e2e_tb.v
vvp remote_id_e2e_sim

# Compile and run stress test
iverilog -g2012 -o stress_sim \
  ../src/enhanced_pkt_filter.v \
  stress_test_tb.v
vvp stress_sim
```

### Automated Test Execution

Use the provided script to run all tests automatically:

```bash
./run_integration_tests.sh
```

This script will:
1. Check for required tools (xsim or iverilog)
2. Compile all testbenches
3. Run all tests sequentially
4. Collect results and generate summary
5. Generate waveform files (.vcd) for debugging
6. Create HTML report with pass/fail status

---

## Viewing Waveforms

### GTKWave (for .vcd files):

```bash
# View monitor mode waveforms
gtkwave monitor_mode_integration.vcd

# View injection waveforms
gtkwave injection_integration.vcd

# View Remote ID E2E waveforms
gtkwave remote_id_e2e.vcd

# View stress test waveforms
gtkwave stress_test.vcd
```

### Vivado Simulator (for .wdb files):

```bash
xsim monitor_sim -gui
# File → Open Waveform Configuration
```

---

## Test Output Format

Each test produces console output in the following format:

```
================================================================
  Test Name
  Description
================================================================

=== Test Suite 1: Description ===
[PASS] Test 1: Test description
[PASS] Test 2: Test description
[FAIL] Test 3: Test description
  Expected: value
  Got:      value

...

================================================================
  Test Summary
================================================================
Total tests: 15
Passed:      14
Failed:      1

*** SOME TESTS FAILED ***
================================================================
```

---

## Interpreting Results

### Success Criteria

A test is considered successful if:
- **Pass Count** = **Total Test Count**
- **Fail Count** = 0
- No buffer overflows or underflows (stress test)
- Throughput meets minimum targets (stress test)
- Message integrity maintained (Remote ID E2E)

### Common Failure Modes

#### Monitor Mode Test

| Failure | Cause | Solution |
|---------|-------|----------|
| Beacon not captured | `capture_beacon` not set | Enable beacon capture flag |
| NAN frame not detected | Incorrect OUI or OUI type | Verify WFA OUI (0x506F9A) and NAN type (0x13) |
| Promiscuous mode rejects frames | Filter logic error | Check `promiscuous` flag propagation |
| FCS failure not blocked | `capture_fcs_fail` incorrectly set | Verify FCS filter configuration |

#### Injection Test

| Failure | Cause | Solution |
|---------|-------|----------|
| Frame format incorrect | MAC header construction error | Verify frame_control, addresses |
| Timing interval off | Clock period misconfiguration | Check CLK_PERIOD parameter |
| Rate/power not applied | Register write timing | Ensure config written before TX |

#### Remote ID E2E Test

| Failure | Cause | Solution |
|---------|-------|----------|
| Payload mismatch | Endianness error | Check little-endian encoding |
| Coordinate precision lost | Integer overflow | Use signed 32-bit for lat/lon |
| Message type wrong | Encoding error | Verify message type byte |

#### Stress Test

| Failure | Cause | Solution |
|---------|-------|----------|
| Buffer overflow | FIFO too small | Increase FIFO_DEPTH parameter |
| Throughput low | Packet rate too high | Reduce packet injection rate |
| Resource usage high | Additional logic | Optimize filter/handler |

---

## Debugging Tips

### Enable Debug Messages

Uncomment `$display` statements in testbenches for detailed debug output.

### Waveform Analysis

Key signals to monitor:
- **Monitor Mode:**
  - `pkt_header_valid_strobe` - Frame header arrival
  - `is_nan_frame` - NAN detection
  - `allow_to_dma` - Filter decision
  - `fc_type`, `fc_subtype` - Frame classification

- **Injection:**
  - `tx_start` - Transmission trigger
  - `backoff_done` - CSMA/CA completion
  - `phy_tx_start` - PHY transmission start
  - `tx_data_valid` - Data stream

- **Remote ID E2E:**
  - `tx_msg_type` vs `rx_msg_type` - Type match
  - `tx_payload` vs `rx_payload` - Payload match
  - `is_nan_frame` - NAN detection on RX

- **Stress Test:**
  - `tx_fifo_full`, `rx_fifo_empty` - Buffer status
  - `total_packets_rx` - Packet counter
  - `tx_overflow_count`, `rx_underflow_count` - Error counters

### Common Issues

1. **Simulation hangs:** Check for missing `$finish` or infinite loops
2. **All tests fail:** Verify DUT instantiation and signal connections
3. **Waveform file empty:** Ensure `$dumpfile` and `$dumpvars` called
4. **Timing errors:** Adjust clock period or add wait cycles

---

## Continuous Integration

These tests are designed to run in CI/CD pipelines:

```yaml
# Example GitHub Actions workflow
name: Integration Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install Icarus Verilog
        run: sudo apt-get install -y iverilog gtkwave
      - name: Run Integration Tests
        run: |
          cd ip/enhanced_xpu/test/integration
          ./run_integration_tests.sh
      - name: Archive Results
        uses: actions/upload-artifact@v2
        with:
          name: test-results
          path: |
            ip/enhanced_xpu/test/integration/*.vcd
            ip/enhanced_xpu/test/integration/test_report.html
```

---

## Test Maintenance

### Adding New Tests

1. Create new testbench file: `new_test_tb.v`
2. Follow existing naming conventions and structure
3. Include comprehensive test scenarios
4. Add to `run_integration_tests.sh`
5. Update this README with test documentation

### Updating Existing Tests

When modifying module interfaces:
1. Update all affected testbenches
2. Verify signal widths and types match
3. Re-run all tests to ensure no regressions
4. Update expected results if behavior changed

---

## Reference Documents

- **ASTM F3411-22:** Standard Specification for Remote ID and Tracking
- **ASD-STAN prEN 4709-002:** European UAS Remote Identification
- **IEEE 802.11-2020:** Wireless LAN Medium Access Control and Physical Layer Specifications
- **WiFi Alliance NAN Specification:** Neighbor Awareness Networking

---

## Contact

For questions or issues with integration tests:
- **Project:** OpenWiFi (https://github.com/open-sdr/openwifi)
- **Issue Tracker:** https://github.com/open-sdr/openwifi-hw/issues
- **Documentation:** /docs/DRONE_REMOTE_ID_ARCHITECTURE.md

---

**Last Updated:** 2025-11-22
**Version:** 1.0
**License:** AGPL-3.0
