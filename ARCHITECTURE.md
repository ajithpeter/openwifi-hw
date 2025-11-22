# OpenWiFi-HW Architecture Documentation

## Table of Contents
1. [System Overview](#system-overview)
2. [IP Core Architecture](#ip-core-architecture)
3. [OFDM PHY Layer](#ofdm-phy-layer)
4. [MAC Layer Implementation](#mac-layer-implementation)
5. [RF Frontend Integration](#rf-frontend-integration)
6. [Clock and Timing Architecture](#clock-and-timing-architecture)
7. [DMA and Memory Interfaces](#dma-and-memory-interfaces)
8. [Debug Infrastructure](#debug-infrastructure)
9. [Board Support](#board-support)
10. [Build System](#build-system)

---

## System Overview

OpenWiFi-HW is a complete IEEE 802.11a/g/n compliant WiFi transceiver implementation for Xilinx Zynq FPGAs with AD9361/AD9364 RF transceivers. The design is fully open-source and integrates with the Linux mac80211 stack.

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Linux (ARM Cortex-A9/A53)                        │
│              mac80211 WiFi Stack + OpenWiFi Driver                   │
└──────────────┬──────────────────────────────┬───────────────────────┘
               │ AXI DMA                      │ AXI DMA
               │ (TX)                         │ (RX)
               ▼                              ▼
    ┌──────────────────┐          ┌──────────────────┐
    │   TX_INTF        │          │   RX_INTF        │
    │  (TX Interface)  │          │  (RX Interface)  │
    └────┬───────────┬─┘          └────┬───────────┬─┘
         │           │                 │           │
    ┌────▼─────┐ ┌───▼─────────────────▼────┐     │
    │OPENOFDM_ │ │      XPU (MAC Control)   │     │
    │TX        │ │   CSMA/CA, Filtering,    │     │
    │          │ │   TSF, Retransmission    │     │
    └────┬─────┘ └───┬──────────────────────┘     │
         │           │                             │
         │      ┌────▼─────────────────────┐      │
         │      │   OPENOFDM_RX            │      │
         │      │   (OFDM Demodulation)    │      │
         │      └────┬─────────────────────┘      │
         │           │                             │
    ┌────▼───────────▼─────┐       ┌──────────────▼──┐
    │  DAC Interface       │       │  ADC Interface   │
    │  (40 MHz RF Domain)  │       │  (40 MHz Domain) │
    └────┬─────────────────┘       └──────────────┬───┘
         │                                        │
         ├────────────────────────────────────────┤
         │          AD9361/AD9364 Transceiver      │
         │          (RF Frontend IC)               │
         └─────────────────────────────────────────┘
                            │
                            ▼
                      [Antenna(s)]
```

### Key Features
- **Standards**: IEEE 802.11a/g/n (20 MHz channels)
- **Data Rates**: 6-72.2 Mbps (legacy + HT MCS0-7)
- **Modulation**: BPSK, QPSK, 16-QAM, 64-QAM
- **Channel Coding**: Convolutional (rate 1/2 with puncturing)
- **MAC Features**: CSMA/CA, ACK/Block ACK, A-MPDU, RTS/CTS
- **Timing**: IEEE 802.11 compliant TSF timer (64-bit, 1μs resolution)

---

## IP Core Architecture

### 1. XPU (eXtensible Processing Unit)

**Location:** `/ip/xpu/`
**Purpose:** MAC layer control and coordination engine

#### Key Modules
- **xpu.v** (867 lines): Main controller integrating all sub-modules
- **tx_control.v** (646 lines): TX state machine with ACK/retransmission
- **csma_ca.v** (450+ lines): CSMA/CA backoff and NAV management
- **pkt_filter_ctl.v** (550+ lines): Frame filtering and address matching
- **phy_rx_parse.v** (326 lines): MAC header extraction
- **tsf_timer.v** (57 lines): 64-bit IEEE 802.11 timing synchronization

#### Interfaces
```verilog
// From RX Path
input [15:0] ddc_i, ddc_q;               // IQ samples for RSSI
input pkt_header_valid;                   // PHY packet detection
input [7:0] pkt_rate;                     // Rate from SIGNAL field
input [15:0] pkt_len;                     // Length from SIGNAL field
input [7:0] byte_in;                      // Decoded bytes
input byte_in_strobe;                     // Byte valid strobe
input fcs_ok;                             // FCS validation result

// To RX Path
output mute_adc_out_to_bb;                // Mute during TX
output block_rx_dma_to_ps;                // Block unwanted frames
output [10:0] rssi_half_db_lock;          // Locked RSSI value

// TX Control
input phy_tx_done;                        // TX completion
output phy_tx_start;                      // Initiate TX
output [79:0] tx_status;                  // TX control/retrans info
output [47:0] mac_addr;                   // Source MAC address

// AXI Slave (S00_AXI)
// 32-bit register interface, 64 registers
```

#### Register Map (S00_AXI)
| Reg | Address | Name | Purpose |
|-----|---------|------|---------|
| 0 | 0x00 | Control | Module reset signals |
| 2-3 | 0x08-0x0C | TSF Load | 64-bit TSF timer load |
| 4 | 0x10 | Band/Channel | Band[19:16], Channel[15:0] |
| 11 | 0x2C | Retrans Limit | Max retransmission count |
| 16-17 | 0x40-0x44 | ACK Timeout | Per-band ACK timeout |
| 27 | 0x6C | Filter Flags | mac80211 filter configuration |
| 28-29 | 0x70-0x74 | BSSID | Basic Service Set ID |
| 30-31 | 0x78-0x7C | MAC Addr | Self MAC address |
| 57 | 0xE4 | Status | RSSI, channel idle, TX/RX status |
| 58-59 | 0xE8-0xEC | TSF Read | Current TSF value |
| 63 | 0xFC | Version | FPGA version info |

---

### 2. TX_INTF (Transmit Interface)

**Location:** `/ip/tx_intf/`
**Purpose:** TX data path from PS DMA to RF DAC

#### Key Modules
- **tx_intf.v** (19,326 lines): Main integration
- **tx_intf_s_axis.v** (10,085 lines): AXI Stream input (4 TX queues)
- **tx_bit_intf.v** (44,445 lines): Bit-level packet handling
- **tx_iq_intf.v** (6,371 lines): IQ sample generation and gain control
- **dac_intf.v** (5,041 lines): DAC interface with CDC
- **tx_status_fifo.v**: TX completion status tracking

#### Data Flow
```
PS DMA (64-bit AXI Stream)
  ↓
4x TX Queue FIFOs (8192 symbols each)
  ↓
TX Bit Interface (MAC processing, retransmission bits)
  ↓
TX IQ Interface (gain control, fuzzing)
  ↓
DAC Interface (clock domain crossing, antenna select)
  ↓
AD9361 DAC (40 MHz RF domain)
```

#### TX Queue Architecture
- **4 Independent Queues**: Support QoS with different priorities
- **FIFO Depth**: 8192 x 64-bit = 512 KB per queue
- **Total Buffer**: 2 MB for TX packets
- **Queue Selection**: Via register `tx_queue_idx_indication_from_ps[1:0]`

---

### 3. RX_INTF (Receive Interface)

**Location:** `/ip/rx_intf/`
**Purpose:** RX data path from RF ADC to PS DMA

#### Key Modules
- **rx_intf.v** (18,917 lines): Main integration
- **adc_intf.v** (8,551 lines): ADC input with CDC and digital gain
- **rx_iq_intf.v** (8,911 lines): IQ sample distribution
- **rx_intf_m_axis.v** (11,173 lines): AXI Stream output to DMA
- **gpio_status_rf_to_bb.v**: AGC status clock domain crossing

#### Data Flow
```
AD9361 ADC (40 MHz RF domain)
  ↓
ADC Interface (CDC, digital gain 0-64x)
  ↓
RX IQ Interface (sample distribution to OFDM RX)
  ↓
OPENOFDM_RX (demodulation, decoding)
  ↓
Byte-to-Word Conversion (FCS/SN insertion)
  ↓
M_AXIS Output FIFO (8192 symbols)
  ↓
PS DMA (64-bit AXI Stream)
```

#### Digital Gain Control
```verilog
// In adc_intf.v
bb_gain[2:0]     // 3-bit gain control (left shift)
// 0 = 1x, 1 = 2x, 2 = 4x, ..., 6 = 64x amplification
```

---

### 4. OPENOFDM_TX (OFDM Transmitter)

**Location:** `/ip/openofdm_tx/`
**Purpose:** PHY layer OFDM modulation and encoding

#### Key Modules
- **dot11_tx.v** (830 lines): Main TX FSM (3-stage state machine)
- **convenc.v**: Convolutional encoder (rate 1/2, K=7)
- **punc_interlv_lut.v** (2060 lines): Puncturing/interleaving LUT
- **modulation.v**: BPSK/QPSK/16-QAM/64-QAM constellation mapping
- **ifftmain.v**: 64-point pipelined IFFT
- **crc32_tx.v**: FCS calculation
- **l_stf_rom.v, l_ltf_rom.v**: Legacy preamble samples
- **ht_stf_rom.v, ht_ltf_rom.v**: HT preamble samples

#### TX Signal Processing Chain
```
MAC Frame (BRAM)
  ↓
L-SIG/HT-SIG Parsing → Rate/Length Extraction
  ↓
Scrambling (7-bit LFSR)
  ↓
Convolutional Encoding (rate 1/2, g0=133, g1=171)
  ↓
Puncturing & Interleaving (rate-dependent LUT)
  ↓
Modulation (BPSK/QPSK/16-QAM/64-QAM)
  ↓
Pilot/DC/Subcarrier Mapping (48 data + 4 pilot + DC/guards)
  ↓
64-Point IFFT (6-stage pipelined radix-2)
  ↓
Cyclic Prefix Addition (800ns or 400ns for short GI)
  ↓
Preamble Multiplexing (L-STF, L-LTF, L-SIG, HT fields)
  ↓
16-bit I/Q Output (20 MHz sample rate)
```

#### Supported Rates
| Rate | Modulation | Coding | N_DBPS | Rate Code |
|------|------------|--------|--------|-----------|
| 6 Mbps | BPSK | 1/2 | 24 | 0x0B |
| 12 Mbps | QPSK | 1/2 | 48 | 0x0A |
| 24 Mbps | 16-QAM | 1/2 | 96 | 0x09 |
| 48 Mbps | 64-QAM | 2/3 | 192 | 0x08 |
| 54 Mbps | 64-QAM | 3/4 | 216 | 0x0C |
| MCS0 (6.5) | BPSK | 1/2 | 26 | 0x10 |
| MCS3 (26) | 16-QAM | 1/2 | 104 | 0x13 |
| MCS7 (65) | 64-QAM | 5/6 | 260 | 0x17 |

---

### 5. OPENOFDM_RX (OFDM Receiver)

**Location:** `/ip/openofdm_rx/` (git submodule from https://github.com/open-sdr/openofdm.git)
**Purpose:** PHY layer OFDM demodulation and decoding

#### RX Signal Processing Chain
```
16-bit I/Q Samples (20 MHz)
  ↓
Preamble Detection (L-STF correlation)
  ↓
Timing Synchronization (±1 sample precision)
  ↓
Frequency Offset Estimation & Correction
  ↓
Channel Estimation (from L-LTF/HT-LTF)
  ↓
64-Point FFT
  ↓
Equalization (per-subcarrier ZF/MMSE)
  ↓
Pilot-Based Phase Tracking
  ↓
Symbol Demodulation (soft decisions)
  ↓
Deinterleaving & Depuncturing
  ↓
Viterbi Decoding (K=7, rate 1/2 base)
  ↓
Descrambling (7-bit LFSR)
  ↓
FCS Verification (CRC-32)
  ↓
Byte Output to MAC Layer
```

#### Key Outputs
```verilog
output pkt_header_valid;              // Frame detected
output pkt_header_valid_strobe;       // Header valid strobe
output [7:0] pkt_rate;                // Detected rate
output [15:0] pkt_len;                // Packet length
output [7:0] byte_in;                 // Decoded bytes
output byte_in_strobe;                // Byte valid
output fcs_ok;                        // FCS verification result
output [31:0] phase_offset_taken;     // Phase tracking info
output [31:0] equalizer;              // Equalizer coefficients
```

---

### 6. SIDE_CH (Side Channel Monitor)

**Location:** `/ip/side_ch/`
**Purpose:** Non-critical monitoring and CSI capture

#### Key Features
- **32 Trigger Modes**: Configurable event-based capture
- **6 Event Counters**: 16-bit independent counters
- **CSI Extraction**: Channel state information per subcarrier
- **IQ Capture**: Dual-channel TX/RX IQ samples
- **Metadata Logging**: RSSI, TSF, phase offset, equalization

#### Captured Signals
```verilog
input [7:0] gpio_status;              // RF frontend status
input signed [10:0] rssi_half_db;     // RSSI (0.5 dB units)
input [63:0] tsf_runtime_val;         // TSF timestamp
input [31:0] openofdm_tx_iq0/1;       // TX OFDM IQ
input [31:0] tx_intf_iq0/1;           // TX interface IQ
input [31:0] sample0/1_in;            // RX IQ samples
input [31:0] csi;                     // Channel state info
input [31:0] equalizer;               // Equalization data
input [31:0] phase_offset_taken;      // Phase correction
```

---

## OFDM PHY Layer

### Preamble Structure

#### Legacy (802.11a/g)
```
┌────────┬────────┬────────┬──────────────┐
│ L-STF  │ L-LTF  │ L-SIG  │ DATA Symbols │
│ 8 μs   │ 8 μs   │ 4 μs   │ Variable     │
└────────┴────────┴────────┴──────────────┘
```

#### HT (802.11n)
```
┌────────┬────────┬────────┬────────┬────────┬─────────┬──────────────┐
│ L-STF  │ L-LTF  │ L-SIG  │ HT-SIG │ HT-STF │ HT-LTF  │ HT-DATA      │
│ 8 μs   │ 8 μs   │ 4 μs   │ 8 μs   │ 4 μs   │ 4 μs    │ Variable     │
└────────┴────────┴────────┴────────┴────────┴─────────┴──────────────┘
```

### OFDM Symbol Structure (20 MHz)
- **FFT Size**: 64 subcarriers
- **Data Subcarriers**: 48
- **Pilot Subcarriers**: 4 (at indices 7, 21, 43, 57)
- **DC Subcarrier**: 1 (null)
- **Guard Bands**: 11 (nulls)
- **Symbol Duration**: 4 μs (3.2 μs FFT + 0.8 μs CP)
- **Short GI**: 3.6 μs (3.2 μs FFT + 0.4 μs CP) for HT

### Convolutional Encoder
```
Generator Polynomials:
  g0 = 133 (octal) = 1011011 (binary)
  g1 = 171 (octal) = 1111001 (binary)
Constraint Length: K = 7
Base Rate: 1/2
Punctured Rates: 2/3, 3/4, 5/6
```

### Modulation Constellations
```
BPSK:   2 symbols   (1 bit/symbol)
QPSK:   4 symbols   (2 bits/symbol)
16-QAM: 16 symbols  (4 bits/symbol)
64-QAM: 64 symbols  (6 bits/symbol)
```

---

## MAC Layer Implementation

### CSMA/CA State Machine

```
IDLE
  ├→ On TX trigger: Check channel
  └→ On RX: Update NAV
        ↓
BACKOFF_CH_BUSY
  └→ Wait for channel idle (DIFS/EIFS)
        ↓
BACKOFF_WAIT_1 (first transmission)
  └→ Count down DIFS
        ↓
BACKOFF_RUN
  ├→ Decrement backoff slots
  ├→ On channel busy: BACKOFF_SUSPEND
  └→ On backoff=0: BACKOFF_WAIT_FOR_OWN
        ↓
BACKOFF_WAIT_FOR_OWN
  └→ Signal ready (backoff_done=1)
```

### TX Control State Machine

```
IDLE
  └→ On packet ready: RECV_ACK_WAIT_TX_BB_DONE
  └→ On RX mgmt frame needing ACK: PREP_ACK
        ↓
PREP_ACK
  ├→ Calculate ACK duration
  └→ Route to: SEND_DFL_ACK or SEND_BLK_ACK
        ↓
SEND_DFL_ACK / SEND_BLK_ACK
  ├→ Write ACK frame to BRAM
  └→ Trigger PHY TX
        ↓
RECV_ACK_WAIT_TX_BB_DONE
  └→ Wait for baseband TX complete
        ↓
RECV_ACK_WAIT_SIG_VALID
  ├→ Wait for ACK SIGNAL header (timeout window)
  └→ On timeout: Retry or fail
        ↓
RECV_ACK
  ├→ On FCS OK + is_ack: Success
  ├→ On timeout: Retransmit (if retries < limit)
  └→ Return to IDLE
```

### Timing Parameters (configurable)
```
SIFS:       10 μs (2.4 GHz) / 16 μs (5 GHz)
Slot Time:  20 μs (2.4 GHz) / 9 μs (5 GHz)
DIFS:       SIFS + 2×Slot = 50 μs (2.4 GHz)
EIFS:       SIFS + DIFS + ACK_time ≈ 104 μs
```

### Frame Filtering

**Filter Flags (compatible with mac80211):**
- FIF_PROMISC_IN_BSS: Promiscuous mode
- FIF_ALLMULTI: All multicast
- FIF_FCSFAIL: Include FCS failures
- FIF_BCN_PRBRESP_PROMISC: Beacon/probe response
- FIF_OTHER_BSS: Frames from other BSSs

---

## RF Frontend Integration

### AD9361 Interface

#### Physical Connections
```verilog
// RX Path (Differential LVDS)
input rx_clk_in_p/n;             // RX clock
input rx_frame_in_p/n;           // RX frame sync
input [5:0] rx_data_in_p/n;      // 6 diff pairs (12-bit I/Q)

// TX Path (Differential LVDS)
output tx_clk_out_p/n;           // TX clock
output tx_frame_out_p/n;         // TX frame sync
output [5:0] tx_data_out_p/n;    // 6 diff pairs

// Control
inout spi_clk, spi_mosi, spi_miso, spi_csn;  // SPI config
inout iic_scl, iic_sda;                      // I2C aux
input [7:0] gpio_status;                     // AGC status
output enable, txnrx;                        // Mode control
```

#### Sample Rate and Clocking
```
RF Domain:       40 MHz (ADC/DAC sample clock)
WiFi Sample:     20 MHz (decimated 2x from RF)
Baseband Clock:  100/200/250 MHz (configurable)
TSF Resolution:  1 MHz (1 μs granularity)
```

#### Gain Control Architecture

**Two-Level Gain:**
1. **RF AGC (AD9361 Hardware)**
   - Automatic gain control in AD9361
   - 7-bit gain word + lock indicator
   - Feedback via gpio_status[7:0]

2. **Digital Baseband Gain (FPGA)**
   - RX: 3-bit (0-64x via left shift)
   - TX: 10-bit signed multiplier

---

## Clock and Timing Architecture

### Clock Domains

```
┌─────────────────────────────────────────────┐
│ AD9361 Internal PLL                          │
└───────────┬─────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────┐
│ util_ad9361_divclk (Xilinx IP)               │
│ Output: 40 MHz                               │
└───────┬─────────────────────────────────────┘
        │
        ├─→ adc_clk (40 MHz) ─→ [adc_intf, rx_intf]
        │
        └─→ dac_clk (40 MHz) ─→ [dac_intf, tx_intf]

┌─────────────────────────────────────────────┐
│ Zynq PS FCLK_CLK2                            │
│ Output: 100 MHz (default)                    │
└───────┬─────────────────────────────────────┘
        │
        └─→ m_axi_aclk (100/200/250 MHz) ─→ [All baseband IPs]
```

### Clock Domain Crossing

**Mechanism:** Xilinx XPM_CDC primitives
- **xpm_cdc_array_single**: Multi-bit synchronization
- **xpm_fifo_async**: Async FIFO for data
- **Sync Stages**: 4 (DEST_SYNC_FF=4) for robustness

**Critical Crossings:**
```
RF → Baseband:
  - ADC samples (xpm_fifo_async in adc_intf)
  - GPIO status (xpm_cdc with moving average)

Baseband → RF:
  - DAC samples (xpm_fifo_async in dac_intf)
  - Antenna selection (xpm_cdc_array_single)
  - Digital gain (xpm_cdc_array_single)
```

### TSF Timer (64-bit)

```verilog
// In tsf_timer.v
reg [63:0] tsf_runtime_val;
reg [6:0] count_1M;  // Divides baseband clock to 1 MHz

always @(posedge clk) begin
  if (count_1M == COUNT_TOP_1M) begin
    count_1M <= 0;
    tsf_runtime_val <= tsf_runtime_val + 1;
    tsf_pulse_1M <= 1;
  end else begin
    count_1M <= count_1M + 1;
    tsf_pulse_1M <= 0;
  end
end
```

---

## DMA and Memory Interfaces

### TX DMA Architecture

```
PS Memory
  ↓
AXI DMA MM2S (Memory-Mapped to Stream)
  ↓
S00_AXIS (64-bit AXI Stream) → TX_INTF
  ↓
4x TX Queue FIFOs (8192 x 64-bit each)
  ├─ Queue 0: Highest priority
  ├─ Queue 1: High priority
  ├─ Queue 2: Low priority
  └─ Queue 3: Background
  ↓
TX Bit Interface (packet assembly)
  ↓
OPENOFDM_TX (OFDM modulation)
  ↓
DAC Interface → AD9361
```

**TX Queue Selection:**
```c
// Software sets queue index
write_reg(TX_INTF_REG8, queue_idx << 18);

// DMA transfers packet to selected queue
dma_submit(packet_data, length);
```

### RX DMA Architecture

```
AD9361 → ADC Interface
  ↓
OPENOFDM_RX (OFDM demodulation)
  ↓
RX_INTF Byte Assembly
  ↓
M00_AXIS FIFO (8192 x 64-bit)
  ↓
M00_AXIS (64-bit AXI Stream) → RX_INTF
  ↓
AXI DMA S2MM (Stream to Memory-Mapped)
  ↓
PS Memory (packet buffer)
  ↓
Interrupt → Linux Driver
```

### Register Access (AXI4-Lite)

**Address Map Example (XPU):**
```c
#define XPU_BASE_ADDR       0x43C00000
#define XPU_REG_CONTROL     (XPU_BASE_ADDR + 0x00)
#define XPU_REG_TSF_LOAD_L  (XPU_BASE_ADDR + 0x08)
#define XPU_REG_TSF_LOAD_H  (XPU_BASE_ADDR + 0x0C)
#define XPU_REG_BAND_CH     (XPU_BASE_ADDR + 0x10)
#define XPU_REG_FILTER      (XPU_BASE_ADDR + 0x6C)
#define XPU_REG_MAC_ADDR_L  (XPU_BASE_ADDR + 0x78)
#define XPU_REG_MAC_ADDR_H  (XPU_BASE_ADDR + 0x7C)
#define XPU_REG_STATUS      (XPU_BASE_ADDR + 0xE4)
#define XPU_REG_TSF_READ_L  (XPU_BASE_ADDR + 0xE8)
#define XPU_REG_TSF_READ_H  (XPU_BASE_ADDR + 0xEC)
```

---

## Debug Infrastructure

### ILA (Integrated Logic Analyzer) Support

**Conditional Compilation:**
```verilog
`ifdef SIDE_CH_ENABLE_DBG
`define DEBUG_PREFIX (*mark_debug="true",DONT_TOUCH="TRUE"*)
`else
`define DEBUG_PREFIX
`endif

`DEBUG_PREFIX reg [3:0] state;
`DEBUG_PREFIX reg [31:0] data_capture;
```

**Enabled via Build Flag:**
```bash
./create_ip_repo.sh $XILINX_DIR \
  side_ch ENABLE_DBG \
  xpu ENABLE_DBG
```

### Side Channel Trigger Modes (32 total)

| Mode | Trigger Condition |
|------|-------------------|
| 0 | FCS strobe or free-run |
| 1-2 | FCS OK / FAIL |
| 3 | TX IQ non-zero (exclude retrans) |
| 4-5 | Header valid / invalid |
| 6-7 | HT / non-HT packet |
| 8-9 | Long / short preamble detected |
| 10-11 | RSSI rise / fall |
| 12-13 | AGC lock / unlock |
| 16 | TX control state change |
| 17 | PHY TX done |
| 24 | TX control state + PHY type match |
| 25 | MAC address match (addr1/addr2) |
| 28-30 | IQ magnitude threshold |
| 31 | TX start with ACK + IQ threshold |

### LED Debug Outputs

**XPU LED Signals:**
```verilog
output demod_is_ongoing_led;    // Toggles on RX demodulation
output cycle_start0_led;        // Toggles on RX cycle start
output phy_tx_started_led;      // Toggles on TX start
output sig_valid_led;           // Toggles on valid SIGNAL field
```

---

## Board Support

### Supported Boards

| Board | FPGA | RF IC | License | PlutoSDR-Like |
|-------|------|-------|---------|---------------|
| antsdr | Zynq7020 | AD9361 | No | ✓✓✓ |
| antsdr_e200 | Zynq7020 | AD9361 | No | ✓✓✓ |
| e310v2 | Zynq7020 | AD9361 | No | ✓✓ (+ GPS) |
| adrv9364z7020 | Zynq7020 | AD9364 | No | ✓✓ |
| adrv9361z7035 | Zynq7035 | AD9361 | Yes | ✓ (larger FPGA) |
| zed_fmcs2 | Zynq7020 | AD9361 | No | ✓ (eval board) |
| zc702_fmcs2 | Zynq7020 | AD9361 | No | ✓ (eval board) |
| zc706_fmcs2 | Zynq7045 | AD9361 | Yes | - (large FPGA) |
| zcu102_fmcs2 | ZU9EG | AD9361 | Yes | - (UltraScale+) |
| sdrpi | Zynq7020 | AD936x | No | ✓✓ |
| neptunesdr | Zynq7020 | AD936x | No | ✓✓ |

### Board Configuration Files

Each board directory contains:
```
boards/[board_name]/
├── set_files.tcl              # Source file list
├── synth_impl_strategy.tcl    # Optimization settings
└── src/
    ├── system.bd              # Vivado block design
    ├── system_top.v           # Top-level wrapper
    ├── system_wrapper.v       # Auto-generated BD wrapper
    └── *.xdc                  # Timing constraints
```

---

## Build System

### Prerequisites
```bash
# Required software
- Xilinx Vivado 2022.2 with Vitis
- Ubuntu 18/20/22 LTS
- libtinfo5 (for Vivado compatibility)

# Required licenses
- Xilinx Viterbi Decoder IP (evaluation license)
- For large FPGAs: Vivado Design Suite license
```

### Build Flow

```bash
# 1. Prepare ADI HDL library (once)
export XILINX_DIR=/opt/Xilinx
./prepare_adi_lib.sh $XILINX_DIR

# 2. Prepare board-specific ADI IP (once per board)
export BOARD_NAME=antsdr
./prepare_adi_board_ip.sh $XILINX_DIR $BOARD_NAME

# 3. Get openofdm_rx submodule (once)
./get_ip_openofdm_rx.sh

# 4. Generate IP repository
cd boards/$BOARD_NAME/
../create_ip_repo.sh $XILINX_DIR

# 5. Open Vivado and build
# In Vivado GUI:
source ../openwifi.tcl
# Click "Generate Bitstream"
# File → Export → Export Hardware (include bitstream)

# 6. Package FPGA files
cd ../..
./boards/sdk_update.sh $BOARD_NAME $OUTPUT_DIR
```

### Build Scripts

**create_ip_repo.sh:**
- Generates pre-definition files for each IP
- Launches Vivado with ip_repo_gen.tcl
- Packages all custom IPs

**ip_repo_gen.tcl:**
- Copies board definition files
- Loops through IPs: openofdm_rx, openofdm_tx, rx_intf, tx_intf, xpu, side_ch
- Packages each IP via package_ip_complex.tcl
- Sources openwifi.tcl to create main project

**openwifi.tcl:**
- Sets NUM_CLK_PER_US (100/200/250 MHz options)
- Generates clock_speed.v
- Creates Vivado project with all sources
- Configures synthesis/implementation strategies
- Exports .xsa file

### Conditional Compilation

**Enable Debug Features:**
```bash
cd boards/$BOARD_NAME/
../create_ip_repo.sh $XILINX_DIR \
  xpu ENABLE_DBG \
  tx_intf ENABLE_DBG \
  rx_intf ENABLE_DBG \
  openofdm_tx ENABLE_DBG \
  openofdm_rx ENABLE_DBG \
  side_ch ENABLE_DBG
```

**Small FPGA Optimization:**
```bash
# Automatically detected for Zynq7020 boards
# Reduces BRAM usage in side_ch and tx_intf
```

---

## Module Interconnections

### Data Path Connections

```
┌─────────────────────────────────────────────────────────────┐
│                     Processing System (PS)                   │
│                  ARM CPU + DDR Memory + DMA                  │
└──────┬────────────────────────────────────┬─────────────────┘
       │ AXI DMA 0 (TX)                     │ AXI DMA 1 (RX)
       │ MM2S (64-bit)                      │ S2MM (64-bit)
       ▼                                    ▼
┌─────────────────┐                  ┌─────────────────┐
│   TX_INTF       │                  │   RX_INTF       │
│  ┌───────────┐  │                  │  ┌───────────┐  │
│  │S_AXIS(4Q) │  │                  │  │M_AXIS     │  │
│  └─────┬─────┘  │                  │  └─────▲─────┘  │
│        │        │                  │        │        │
│  ┌─────▼─────┐  │                  │  ┌─────┴─────┐  │
│  │TX Bit Intf│  │                  │  │Byte2Word  │  │
│  └─────┬─────┘  │                  │  │+FCS/SN    │  │
│        │        │                  │  └─────▲─────┘  │
│  ┌─────▼─────┐  │                  │        │        │
│  │TX IQ Intf │  │                  │  ┌─────┴─────┐  │
│  └─────┬─────┘  │                  │  │RX IQ Intf │  │
│        │        │                  │  └─────▲─────┘  │
│  ┌─────▼─────┐  │                  │        │        │
│  │DAC Intf   │  │                  │  ┌─────┴─────┐  │
│  │(CDC,40MHz)│  │                  │  │ADC Intf   │  │
│  └─────┬─────┘  │                  │  │(CDC,40MHz)│  │
└────────┼────────┘                  └────────┼────────┘
         │                                    ▲
         │    ┌──────────────────────┐        │
         │    │   OPENOFDM_TX        │        │
         └───►│  ┌────────────────┐  │        │
              │  │ BRAM Interface │  │        │
              │  │ (from TX_INTF) │  │        │
              │  └────────┬───────┘  │        │
              │           │          │        │
              │  ┌────────▼───────┐  │        │
              │  │  OFDM Encoder  │  │        │
              │  │  + IFFT        │  │        │
              │  └────────┬───────┘  │        │
              │           │          │        │
              │  ┌────────▼───────┐  │        │
              │  │  IQ Output     │──┼────────┤
              │  └────────────────┘  │        │
              └──────────────────────┘        │
                                              │
         ┌────────────────────────────────────┼────┐
         │           OPENOFDM_RX              │    │
         │  ┌─────────────────────────────────▼──┐ │
         │  │  Sample Input (from RX_INTF)       │ │
         │  └──────┬──────────────────────────────┘ │
         │         │                                │
         │  ┌──────▼───────┐                        │
         │  │  Preamble    │                        │
         │  │  Detection   │                        │
         │  └──────┬───────┘                        │
         │         │                                │
         │  ┌──────▼───────┐                        │
         │  │  Sync + FFT  │                        │
         │  │  + Equalizer │                        │
         │  └──────┬───────┘                        │
         │         │                                │
         │  ┌──────▼───────┐                        │
         │  │  Viterbi     │                        │
         │  │  Decoder     │                        │
         │  └──────┬───────┘                        │
         │         │                                │
         │  ┌──────▼───────┐                        │
         │  │ Byte Output  │                        │
         │  │ + FCS Check  │──┐                     │
         │  └──────────────┘  │                     │
         └────────────────────┼─────────────────────┘
                              │
         ┌────────────────────▼─────────────────────┐
         │              XPU (MAC Control)           │
         │  ┌─────────────────────────────────────┐ │
         │  │  PHY RX Parse (extract MAC header)  │ │
         │  └───────┬─────────────────────────────┘ │
         │          │                               │
         │  ┌───────▼─────────┐  ┌──────────────┐  │
         │  │ Packet Filter   │  │   TSF Timer  │  │
         │  │ (addr matching) │  │   (64-bit)   │  │
         │  └───────┬─────────┘  └──────────────┘  │
         │          │                               │
         │  ┌───────▼─────────┐  ┌──────────────┐  │
         │  │    CSMA/CA      │  │  TX Control  │  │
         │  │   (backoff)     │  │ (ACK/retry)  │  │
         │  └─────────────────┘  └──────┬───────┘  │
         │                               │          │
         │  Control Signals to TX_INTF ◄─┘          │
         └──────────────────────────────────────────┘
                      │
                      ▼
         ┌──────────────────────────────────────────┐
         │         SIDE_CH (Monitoring)             │
         │  Captures: IQ, CSI, RSSI, TSF, etc.      │
         │  Output: M_AXIS to PS for analysis       │
         └──────────────────────────────────────────┘
```

### Control Signal Summary

| Signal | Source | Destination | Purpose |
|--------|--------|-------------|---------|
| pkt_header_valid | OPENOFDM_RX | XPU, RX_INTF | Frame detected |
| pkt_rate[7:0] | OPENOFDM_RX | XPU, RX_INTF | Detected rate |
| pkt_len[15:0] | OPENOFDM_RX | XPU, RX_INTF | Packet length |
| byte_in[7:0] | OPENOFDM_RX | XPU, RX_INTF | Decoded bytes |
| fcs_ok | OPENOFDM_RX | XPU, RX_INTF | FCS validation |
| sample0/1[31:0] | RX_INTF | OPENOFDM_RX | ADC IQ samples |
| phy_tx_start | TX_INTF | OPENOFDM_TX, XPU | TX initiation |
| phy_tx_done | OPENOFDM_TX | TX_INTF, XPU | TX completion |
| result_i/q[15:0] | OPENOFDM_TX | TX_INTF | OFDM IQ output |
| bram_addr[9:0] | TX_INTF | OPENOFDM_TX | Packet data addr |
| tx_status[79:0] | XPU | TX_INTF | Retrans control |
| mac_addr[47:0] | XPU | TX_INTF | Source MAC |
| backoff_done | XPU | TX_INTF | CSMA done |
| mute_adc | XPU | RX_INTF | Mute during TX |
| block_rx_dma | XPU | RX_INTF | Filter unwanted |

---

## Performance Characteristics

### Throughput
- **Maximum**: 72.2 Mbps (MCS7 with short GI, 802.11n)
- **Typical**: 54 Mbps (802.11a/g)
- **Link Budget**: Depends on RF frontend and antenna

### Latency
- **TX Path**: ~100 μs (PS DMA → RF output)
- **RX Path**: ~80 μs (RF input → PS DMA)
- **MAC Processing**: <10 μs (hardware-accelerated)

### Resource Utilization (Zynq7020)
| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUTs | ~45K | 53K | ~85% |
| FFs | ~38K | 106K | ~36% |
| BRAM | ~90 | 140 | ~64% |
| DSP48 | ~50 | 220 | ~23% |

---

## References

### External Dependencies
- **ADI HDL**: https://github.com/analogdevicesinc/hdl (2022_R2 branch)
- **OpenOFDM**: https://github.com/open-sdr/openofdm (dot11zynq branch)
- **Xilinx IP**: Viterbi Decoder, AXI DMA, Clock Wizard, etc.

### Standards Compliance
- **IEEE 802.11-2020**: OFDM PHY, MAC timing, frame formats
- **IEEE 802.11a**: 5 GHz OFDM
- **IEEE 802.11g**: 2.4 GHz OFDM
- **IEEE 802.11n**: High Throughput (HT) 20 MHz channels

### Documentation Files
- [README.md](README.md): Quick start guide
- [gpio_led.md](gpio_led.md): GPIO and LED definitions
- [CONTRIBUTING.md](CONTRIBUTING.md): Contribution guidelines

---

**Document Version:** 1.0
**Last Updated:** 2025-11-22
**Repository:** https://github.com/open-sdr/openwifi-hw
