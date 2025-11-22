# OpenWiFi-HW Module Interactions and Data Flow

## Table of Contents
1. [TX Data Path Detailed Flow](#tx-data-path-detailed-flow)
2. [RX Data Path Detailed Flow](#rx-data-path-detailed-flow)
3. [MAC Control Flow](#mac-control-flow)
4. [Clock Domain Crossing Details](#clock-domain-crossing-details)
5. [Interrupt and Event Flow](#interrupt-and-event-flow)
6. [Register Access Sequences](#register-access-sequences)

---

## TX Data Path Detailed Flow

### Complete TX Chain with Timing

```
Time: T0
├─ Software Layer (Linux mac80211)
│  └─ mac80211_tx() prepares WiFi frame
│     ├─ Adds MAC header (24+ bytes)
│     ├─ Selects rate based on link quality
│     └─ Queues frame to netdev queue
│
Time: T0 + ~50μs
├─ DMA Layer
│  └─ AXI DMA MM2S Channel
│     ├─ Reads frame from DDR memory
│     ├─ Transfers via S00_AXIS (64-bit chunks)
│     └─ Checks TX queue availability via TREADY
│
Time: T0 + ~100μs
├─ TX_INTF Module (/ip/tx_intf/src/tx_intf.v)
│  │
│  ├─ tx_intf_s_axis.v (Queue Selection)
│  │  ├─ Reads tx_queue_idx_indication_from_ps[1:0]
│  │  ├─ Routes S_AXIS_TDATA to selected FIFO (0-3)
│  │  ├─ Monitors FIFO full status
│  │  └─ Stores packet (up to 8192 x 64-bit words)
│  │
│  ├─ tx_bit_intf.v (Bit-Level Processing)
│  │  ├─ Reads queue FIFO sequentially
│  │  ├─ Extracts PHY header (rate, length)
│  │  ├─ Stores frame in DPRAM (1024 x 64-bit)
│  │  ├─ Manages retry bit (FC bit 11)
│  │  ├─ Sets up TX config FIFO entry
│  │  └─ Waits for backoff_done from XPU
│  │
│  ├─ Coordination with XPU
│  │  ├─ Monitors tx_status[79:0] from XPU
│  │  ├─ Checks slice_en[3:0] for queue permissions
│  │  ├─ Waits for backoff_done signal
│  │  └─ On backoff_done: triggers phy_tx_start
│  │
│  ├─ tx_iq_intf.v (IQ Generation)
│  │  ├─ Applies baseband gain (bb_gain[9:0])
│  │  ├─ Optional CSI fuzzing (bb_gain1, bb_gain2)
│  │  ├─ Formats IQ pairs (I[15:0], Q[15:0])
│  │  └─ Buffers in IQ FIFO
│  │
│  └─ dac_intf.v (DAC Interface)
│     ├─ Clock domain crossing: 100MHz → 40MHz
│     ├─ Antenna selection (ant_flag)
│     ├─ Cyclic delay diversity (simple_cdd_flag)
│     └─ Output to util_ad9361_dac_upack
│
Time: T0 + ~120μs
├─ OPENOFDM_TX Module (/ip/openofdm_tx/src/)
│  │
│  ├─ dot11_tx.v (Main Controller)
│  │  │
│  │  ├─ FSM1: Data Collection
│  │  │  ├─ State: S1_WAIT_PKT
│  │  │  │  └─ Waits for phy_tx_start
│  │  │  ├─ State: S1_L_SIG
│  │  │  │  ├─ Reads bram_din[63:0] via bram_addr[9:0]
│  │  │  │  ├─ Extracts rate[3:0], length[11:0]
│  │  │  │  ├─ Calculates N_OFDM_SYM (OFDM symbols needed)
│  │  │  │  └─ Configures encoder for rate
│  │  │  ├─ State: S1_HT_SIG (if HT packet)
│  │  │  │  ├─ Extracts MCS, HT-specific params
│  │  │  │  └─ Configures HT processing
│  │  │  └─ State: S1_DATA
│  │  │     ├─ Reads PSDU data byte-by-byte
│  │  │     ├─ Applies scrambler (7-bit LFSR)
│  │  │     ├─ Convolutional encoding (rate 1/2)
│  │  │     └─ Stores encoded bits in bits_enc_fifo
│  │  │
│  │  ├─ FSM2: OFDM Symbol Processing
│  │  │  ├─ State: S2_PUNC_INTERLV
│  │  │  │  ├─ Reads punc_interlv_lut.v (2060-line LUT)
│  │  │  │  ├─ Applies puncturing pattern (rate-dependent)
│  │  │  │  ├─ Interleaves bits across subcarriers
│  │  │  │  └─ Writes to ram_simo (bits RAM)
│  │  │  ├─ State: S2_PILOT_DC_SB
│  │  │  │  ├─ Inserts pilot symbols (subcarriers 7,21,43,57)
│  │  │  │  ├─ Sets DC subcarrier to 0
│  │  │  │  └─ Nulls guard bands
│  │  │  ├─ State: S2_MOD_IFFT_INPUT
│  │  │  │  ├─ Modulates bits via modulation.v
│  │  │  │  │  ├─ BPSK: 1 bit → {±0x4000, 0}
│  │  │  │  │  ├─ QPSK: 2 bits → 4 constellation points
│  │  │  │  │  ├─ 16-QAM: 4 bits → 16 points
│  │  │  │  │  └─ 64-QAM: 6 bits → 64 points
│  │  │  │  ├─ Prepares 64-point IFFT input
│  │  │  │  ├─ Triggers IFFT computation
│  │  │  │  └─ Adds cyclic prefix (CP_fifo)
│  │  │  └─ State: S2_RESET
│  │  │     └─ Resets after frame complete
│  │  │
│  │  └─ FSM3: Sample Output Sequencing
│  │     ├─ State: S3_L_STF
│  │     │  ├─ Reads l_stf_rom.v (16 samples)
│  │     │  ├─ Outputs 10 repetitions (160 samples, 8μs)
│  │     │  └─ Used for AGC, initial sync
│  │     ├─ State: S3_L_LTF
│  │     │  ├─ Reads l_ltf_rom.v (80 samples)
│  │     │  ├─ Outputs 2 symbols (160 samples, 8μs)
│  │     │  └─ Used for channel estimation
│  │     ├─ State: S3_L_SIG
│  │     │  ├─ Outputs SIGNAL field (80 samples, 4μs)
│  │     │  ├─ Contains rate + length info
│  │     │  └─ BPSK modulated at 6 Mbps
│  │     ├─ State: S3_HT_SIG, S3_HT_STF, S3_HT_LTF (if HT)
│  │     │  ├─ HT-SIG: 2 OFDM symbols (160 samples, 8μs)
│  │     │  ├─ HT-STF: 1 symbol (80 samples, 4μs)
│  │     │  └─ HT-LTF: 1+ symbols (80+ samples)
│  │     └─ State: S3_DATA
│  │        ├─ Reads CP_fifo and pkt_fifo
│  │        ├─ Outputs data OFDM symbols
│  │        ├─ Each symbol: 80 samples (4μs) or 72 (short GI)
│  │        └─ Continues until all N_OFDM_SYM transmitted
│  │
│  ├─ IFFT Pipeline (ifftmain.v)
│  │  ├─ 64-point complex IFFT
│  │  ├─ 6-stage radix-2 butterfly
│  │  ├─ Latency: 6 clock cycles to first output
│  │  ├─ Throughput: 1 sample/clock after fill
│  │  └─ Bit-reversal output reordering
│  │
│  └─ Output: result_i[15:0], result_q[15:0], result_iq_valid
│
Time: T0 + ~150μs (packet-dependent)
├─ Back to TX_INTF dac_intf.v
│  ├─ Receives result_iq from OPENOFDM_TX
│  ├─ Packs into 64-bit dac_data format
│  └─ Outputs to util_ad9361_dac_upack
│
Time: T0 + ~160μs
├─ ADI IP Cores
│  ├─ util_ad9361_dac_upack (Xilinx/ADI)
│  │  └─ Unpacks 64-bit to dual 12-bit I/Q streams
│  └─ axi_ad9361 (Xilinx/ADI)
│     └─ Interfaces to AD9361 LVDS pins
│
Time: T0 + ~165μs
├─ AD9361 Transceiver
│  ├─ DAC converts digital IQ → analog baseband
│  ├─ Upconverts to RF frequency
│  ├─ Power amplifier
│  └─ Transmits via antenna
│
Time: T0 + ~170μs + packet_duration
├─ Transmission Complete
│  ├─ OPENOFDM_TX asserts phy_tx_done
│  ├─ TX_INTF captures tx_try_complete
│  ├─ Writes TX status FIFO
│  ├─ Triggers tx_itrpt interrupt
│  └─ Software reads TX completion status
```

### TX Timing Budget Breakdown

| Stage | Duration | Notes |
|-------|----------|-------|
| Software → DMA | ~50 μs | Varies with CPU load |
| DMA Transfer | ~10-50 μs | Depends on packet size |
| TX Queue FIFO | Minimal | Pipelined |
| CSMA/CA Backoff | 50-500+ μs | DIFS + random backoff |
| OFDM Encoding | ~20-40 μs | Parallel processing |
| Preamble + Data TX | Packet-dependent | ~100 μs for 500-byte frame |
| **Total Latency** | **~200-700 μs** | From mac80211 to RF |

---

## RX Data Path Detailed Flow

### Complete RX Chain with Timing

```
Time: T0
├─ Antenna Receives RF Signal
│  └─ AD9361 Transceiver
│     ├─ Low-noise amplifier (LNA)
│     ├─ Downconverts RF → baseband
│     ├─ ADC converts analog → digital (12-bit I/Q)
│     └─ Outputs 40 MHz sample rate to FPGA
│
Time: T0 + ~1μs
├─ ADI IP Cores
│  ├─ axi_ad9361 (Xilinx/ADI)
│  │  └─ Receives LVDS differential pairs
│  └─ util_ad9361_adc_pack (Xilinx/ADI)
│     ├─ Packs 6x differential to 64-bit format
│     └─ Outputs: adc_data[63:0], adc_valid
│
Time: T0 + ~2μs
├─ RX_INTF Module (/ip/rx_intf/src/rx_intf.v)
│  │
│  ├─ adc_intf.v (ADC Interface)
│  │  ├─ Clock domain crossing: 40MHz (RF) → 100MHz (BB)
│  │  ├─ Uses xpm_fifo_async for samples
│  │  ├─ Applies digital gain (bb_gain[2:0])
│  │  │  └─ Left shift: 0-6 bits (1x to 64x amplification)
│  │  ├─ Decimates 2:1 (40 MSPS → 20 MSPS effective)
│  │  └─ Outputs: sample0[31:0], sample1[31:0]
│  │
│  ├─ gpio_status_rf_to_bb.v (AGC Status)
│  │  ├─ Captures gpio_status[7:0] from AD9361
│  │  ├─ Clock domain crossing via async FIFO
│  │  ├─ Applies moving average (32-sample window)
│  │  ├─ Bits[6:0]: AGC gain level
│  │  └─ Bit[7]: AGC lock status (inverted)
│  │
│  └─ rx_iq_intf.v (IQ Distribution)
│     ├─ Formats samples for OPENOFDM_RX
│     ├─ Dual-channel output (MIMO-ready)
│     └─ Generates sample_strobe (20 MHz valid)
│
Time: T0 + ~3μs
├─ OPENOFDM_RX Module (git submodule)
│  │
│  ├─ Preamble Detection
│  │  ├─ Cross-correlates with known L-STF pattern
│  │  ├─ Detects short training (threshold crossing)
│  │  ├─ Asserts short_preamble_detected
│  │  ├─ Continues to L-LTF detection
│  │  └─ Asserts long_preamble_detected
│  │
│  ├─ Synchronization
│  │  ├─ Coarse timing from STF correlation peak
│  │  ├─ Fine timing from LTF (±1 sample precision)
│  │  ├─ Frequency offset estimation (±80 ppm typical)
│  │  ├─ Corrects CFO in frequency domain
│  │  └─ Symbol timing locked
│  │
│  ├─ Channel Estimation
│  │  ├─ Uses L-LTF (2 symbols)
│  │  ├─ Computes per-subcarrier H[k] (channel response)
│  │  ├─ For HT: additional HT-LTF symbols
│  │  └─ Stores equalizer coefficients
│  │
│  ├─ SIGNAL Field Decoding
│  │  ├─ Reads 1 OFDM symbol (L-SIG or HT-SIG)
│  │  ├─ Demodulates BPSK
│  │  ├─ Viterbi decodes (rate 1/2)
│  │  ├─ Extracts rate[3:0] or MCS[6:0]
│  │  ├─ Extracts length[11:0] or [15:0]
│  │  ├─ Validates parity/CRC
│  │  ├─ Asserts pkt_header_valid
│  │  └─ Outputs pkt_rate[7:0], pkt_len[15:0]
│  │
│  ├─ Data Symbol Processing
│  │  ├─ For each OFDM symbol:
│  │  │  ├─ Remove cyclic prefix
│  │  │  ├─ 64-point FFT
│  │  │  ├─ Equalization: Y[k] / H[k]
│  │  │  ├─ Pilot-based phase tracking
│  │  │  ├─ Symbol demodulation (soft decisions)
│  │  │  └─ Outputs bits to deinterleaver
│  │  ├─ Deinterleaving (inverse of TX interleaving)
│  │  ├─ Depuncturing (insert known bits for deleted positions)
│  │  ├─ Viterbi decoding
│  │  │  ├─ Trellis-based maximum likelihood
│  │  │  ├─ Traceback for bit decisions
│  │  │  └─ Outputs decoded bytes
│  │  ├─ Descrambling (7-bit LFSR, same as TX)
│  │  └─ FCS verification (CRC-32 check)
│  │
│  └─ Byte Output
│     ├─ Asserts byte_in_strobe for each byte
│     ├─ Outputs byte_in[7:0]
│     ├─ At packet end:
│     │  ├─ Asserts fcs_in_strobe
│     │  ├─ Sets fcs_ok (1=pass, 0=fail)
│     │  └─ Outputs byte_count[15:0]
│     └─ For A-MPDU:
│        ├─ Asserts ht_aggr at start
│        └─ Asserts ht_aggr_last at end
│
Time: T0 + ~10μs + packet_duration
├─ XPU Module (/ip/xpu/src/xpu.v)
│  │
│  ├─ phy_rx_parse.v (MAC Header Extraction)
│  │  ├─ Receives byte_in stream
│  │  ├─ Extracts byte-by-byte:
│  │  │  ├─ Bytes 0-1: Frame Control (FC)
│  │  │  ├─ Bytes 2-3: Duration/ID
│  │  │  ├─ Bytes 4-9: Address 1 (RA)
│  │  │  ├─ Bytes 10-15: Address 2 (TA)
│  │  │  ├─ Bytes 16-21: Address 3 (DA/BSSID)
│  │  │  ├─ Bytes 22-23: Sequence Control
│  │  │  └─ Bytes 24+: QoS, Address 4 (if applicable)
│  │  └─ Outputs: FC_DI[31:0], addr1/2/3[47:0], SC[15:0]
│  │
│  ├─ pkt_filter_ctl.v (Packet Filtering)
│  │  ├─ FSM: FILTER_IDLE → WAIT_FOR_ADDR1 → WAIT_FOR_ADDR2
│  │  │        → WAIT_FOR_ADDR3 → FILTER_ACTION
│  │  ├─ Checks frame type/subtype:
│  │  │  ├─ FC_type[1:0]: 0=mgmt, 1=ctrl, 2=data
│  │  │  ├─ FC_subtype[3:0]: beacon=8, probe req=4, etc.
│  │  │  └─ Detects: is_beacon, is_ack, is_rts, is_cts, etc.
│  │  ├─ Address matching:
│  │  │  ├─ Compare addr1 with self_mac_addr
│  │  │  ├─ Check broadcast (addr1 = FF:FF:FF:FF:FF:FF)
│  │  │  ├─ Check multicast (addr1[0] = 1)
│  │  │  └─ Compare BSSID with configured value
│  │  ├─ Filter flags (from slv_reg27):
│  │  │  ├─ FIF_PROMISC_IN_BSS: Accept all in BSS
│  │  │  ├─ FIF_FCSFAIL: Accept FCS failures
│  │  │  ├─ FIF_BCN_PRBRESP_PROMISC: All beacons
│  │  │  └─ FIF_OTHER_BSS: Other BSS frames
│  │  └─ Output: allow_rx_dma_to_ps or block_rx_dma_to_ps
│  │
│  ├─ RSSI Calculation (rssi.v, iq_rssi_to_db.v)
│  │  ├─ Receives ddc_i[15:0], ddc_q[15:0]
│  │  ├─ Computes power: I² + Q²
│  │  ├─ Applies moving average (smoothing)
│  │  ├─ Converts to dBm using LUT
│  │  ├─ Locks value on pkt_header_valid_strobe
│  │  └─ Outputs: rssi_half_db_lock_by_sig_valid[10:0]
│  │
│  ├─ NAV Update (in csma_ca.v)
│  │  ├─ Extracts duration[15:0] from RX frame
│  │  ├─ If frame not for me: update NAV
│  │  │  └─ nav_count <= duration (in microseconds)
│  │  └─ Prevents TX while NAV > 0
│  │
│  └─ ACK Generation (in tx_control.v)
│     ├─ If frame needs ACK (FC_retry=0, data/mgmt for me):
│     │  ├─ State: PREP_ACK
│     │  ├─ Calculate ACK duration field
│     │  ├─ State: SEND_DFL_ACK
│     │  ├─ Write ACK frame to BRAM:
│     │  │  ├─ FC: Type=Control, Subtype=ACK
│     │  │  ├─ Duration: 0
│     │  │  ├─ RA: addr2 from RX frame
│     │  │  └─ No FCS (added by PHY)
│     │  ├─ Trigger phy_tx_start
│     │  └─ Wait SIFS (10 or 16 μs) before TX
│     └─ For Block ACK:
│        ├─ State: SEND_BLK_ACK
│        ├─ Include bitmap of received MPDUs
│        └─ Trigger TX
│
Time: T0 + packet_duration + processing_time
├─ Back to RX_INTF
│  │
│  ├─ byte_to_word_fcs_sn_insert.v
│  │  ├─ Assembles bytes into 64-bit words
│  │  ├─ Inserts FCS status in last word
│  │  ├─ Inserts sequence number from MAC header
│  │  └─ Writes to RX FIFO
│  │
│  └─ rx_intf_m_axis.v (M_AXIS Output)
│     ├─ Reads RX FIFO (8192 x 64-bit)
│     ├─ FSM: IDLE → INIT_COUNTER → SEND_STREAM
│     ├─ Outputs M_AXIS_TDATA[63:0]
│     ├─ Asserts M_AXIS_TVALID
│     ├─ Checks M_AXIS_TREADY from DMA
│     ├─ Asserts M_AXIS_TLAST at packet end
│     └─ Triggers rx_pkt_intr interrupt
│
Time: T0 + packet_duration + ~50μs
├─ AXI DMA S2MM (Stream to Memory-Mapped)
│  ├─ Receives M_AXIS stream
│  ├─ Writes to DDR memory buffer
│  ├─ Updates descriptor ring
│  └─ Triggers s2mm_intr to PS
│
Time: T0 + packet_duration + ~80μs
└─ Software Layer (Linux)
   ├─ Interrupt handler wakes up
   ├─ Reads RX descriptor
   ├─ Reads packet from DDR
   ├─ Passes to mac80211 stack
   ├─ mac80211 processes frame:
   │  ├─ Checks FCS (if not done in HW)
   │  ├─ Updates link quality stats
   │  ├─ Handles management frames
   │  └─ Delivers data to network stack
   └─ Updates RX statistics
```

### RX Timing Budget Breakdown

| Stage | Duration | Notes |
|-------|----------|-------|
| RF → ADC | ~1 μs | Hardware latency |
| ADC → RX_INTF | ~1 μs | Clock domain crossing |
| Preamble Detection | ~8-16 μs | STF+LTF processing |
| SIGNAL Decode | ~5 μs | 1 OFDM symbol + Viterbi |
| Data Decoding | Packet-dependent | ~200 μs for 500-byte frame |
| MAC Processing | ~5-10 μs | Filter, RSSI, ACK decision |
| DMA Transfer | ~10-30 μs | Depends on packet size |
| Interrupt + SW | ~20-50 μs | Varies with CPU load |
| **Total Latency** | **~50-300 μs** | From RF to mac80211 |

---

## MAC Control Flow

### CSMA/CA Detailed Timing

```
Event: Software Requests TX
  │
  ├─ XPU receives tx_start signal from TX_INTF
  │  └─ tx_control.v sets tx_try_complete = 0
  │
  ├─ csma_ca.v IDLE State
  │  ├─ Input: high_trigger (new TX request)
  │  ├─ Check: ch_idle_final
  │  │  └─ ch_idle = !demod_is_ongoing && (rssi < threshold)
  │  └─ If channel busy → BACKOFF_CH_BUSY
  │     If channel idle → BACKOFF_WAIT_1 or BACKOFF_WAIT_2
  │
  ├─ BACKOFF_CH_BUSY State
  │  ├─ Wait for ch_idle_final = 1
  │  ├─ Duration: unbounded (until channel clear)
  │  └─ Transition: → BACKOFF_WAIT_2 on channel idle
  │
  ├─ BACKOFF_WAIT_1 State (first transmission attempt)
  │  ├─ Wait DIFS (Distributed IFS)
  │  │  └─ DIFS = SIFS + 2×SlotTime
  │  │     = 10μs + 2×20μs = 50μs (2.4 GHz)
  │  │     = 16μs + 2×9μs = 34μs (5 GHz)
  │  ├─ Counter: difs_count_top (from slv_reg6)
  │  └─ Transition: → BACKOFF_WAIT_FOR_OWN (skip random backoff)
  │
  ├─ BACKOFF_WAIT_2 State (retransmission or after busy)
  │  ├─ Wait DIFS/EIFS
  │  │  └─ EIFS = SIFS + DIFS + ACK_time (if previous RX failed)
  │  ├─ Generate random backoff
  │  │  ├─ Use LFSR for random number generation
  │  │  ├─ backoff_slots = random[31:0] % (CW + 1)
  │  │  └─ CW (Contention Window):
  │  │     - Initial: CW_min = 15 (slv_reg19[3:0])
  │  │     - After collision/timeout: CW = min(2×(CW+1)-1, CW_max)
  │  │     - CW_max = 1023 (slv_reg19[13:4])
  │  └─ Transition: → BACKOFF_RUN
  │
  ├─ BACKOFF_RUN State
  │  ├─ Decrement backoff_count every SlotTime
  │  │  └─ SlotTime = 20μs (2.4 GHz) or 9μs (5 GHz)
  │  ├─ If ch_idle_final = 0: → BACKOFF_SUSPEND
  │  ├─ If backoff_count = 0: → BACKOFF_WAIT_FOR_OWN
  │  └─ Example: CW=15 → backoff=0-15 slots → 0-300μs (2.4GHz)
  │
  ├─ BACKOFF_SUSPEND State
  │  ├─ Pause backoff_count (save current value)
  │  ├─ Wait for ch_idle_final = 1
  │  └─ Transition: → BACKOFF_RUN (resume countdown)
  │
  ├─ BACKOFF_WAIT_FOR_OWN State
  │  ├─ Assert backoff_done = 1
  │  ├─ TX_INTF sees backoff_done
  │  │  └─ Triggers phy_tx_start to OPENOFDM_TX
  │  └─ Transition: → IDLE
  │
  └─ Meanwhile in tx_control.v:
     │
     ├─ RECV_ACK_WAIT_TX_BB_DONE State
     │  ├─ Wait for pulse_tx_bb_end (baseband TX complete)
     │  ├─ Duration: preamble + data symbols
     │  │  └─ Example: 500-byte frame ≈ 100-200μs
     │  └─ Transition: → RECV_ACK_WAIT_SIG_VALID
     │
     ├─ RECV_ACK_WAIT_SIG_VALID State
     │  ├─ Wait for ACK SIGNAL field detection
     │  ├─ Timeout: recv_ack_sig_valid_timeout_top
     │  │  └─ Configured per band (slv_reg16, slv_reg17)
     │  │     Typical: 30-50μs
     │  ├─ Check: pkt_header_valid && (pkt_len == 14)
     │  │  └─ ACK frame is 14 bytes total
     │  └─ Transition:
     │     - On valid ACK header: → RECV_ACK
     │     - On timeout: → Retry or Fail
     │
     ├─ RECV_ACK State
     │  ├─ Wait for FCS verification
     │  ├─ Timeout: recv_ack_timeout_top_adj
     │  ├─ Check: fcs_ok && is_ack
     │  │  └─ is_ack = (FC_type==1) && (FC_subtype==13)
     │  ├─ On success:
     │  │  ├─ tx_try_complete = 1
     │  │  ├─ CW reset to CW_min
     │  │  └─ Transition: → IDLE
     │  └─ On timeout/failure:
     │     ├─ Increment num_retrans
     │     ├─ If num_retrans < retrans_limit (slv_reg11[3:0]):
     │     │  ├─ CW = min(2×(CW+1)-1, CW_max)
     │     │  ├─ Set retry bit in frame (FC bit 11)
     │     │  ├─ Trigger retransmission
     │     │  └─ Return to csma_ca BACKOFF_WAIT_2
     │     └─ If num_retrans >= limit:
     │        ├─ tx_try_complete = 1 (fail)
     │        └─ Transition: → IDLE
     │
     └─ TX Status Captured
        ├─ Writes to tx_status_fifo (4x FIFOs)
        │  ├─ FIFO1: CW, num_retrans, queue_idx, priority
        │  ├─ FIFO2: Block ACK SSN, packet count
        │  ├─ FIFO3: Block ACK bitmap[31:0]
        │  └─ FIFO4: Block ACK bitmap[63:32]
        └─ Triggers tx_itrpt interrupt
```

### Example Timing Scenario: Successful TX with ACK

```
T=0μs:     Software submits 500-byte frame to queue 0
T=50μs:    DMA transfer completes
T=60μs:    TX_INTF stores frame in DPRAM
T=65μs:    XPU csma_ca checks channel (idle)
T=70μs:    DIFS countdown starts
T=120μs:   DIFS complete (50μs), backoff_done asserted
T=125μs:   phy_tx_start triggers OPENOFDM_TX
T=133μs:   Preamble transmission starts (L-STF)
T=141μs:   L-LTF transmission
T=149μs:   L-SIG transmission
T=153μs:   Data symbol transmission begins
T=353μs:   Last data symbol completes
T=358μs:   phy_tx_done asserted, pulse_tx_bb_end
T=368μs:   SIFS wait (10μs)
T=378μs:   Remote station ACK preamble detected
T=402μs:   ACK FCS validated, fcs_ok=1, is_ack=1
T=405μs:   tx_try_complete=1, TX success
T=410μs:   tx_itrpt interrupt to PS
T=420μs:   Software reads TX status (success, 0 retries)
```

---

## Clock Domain Crossing Details

### Critical CDC Paths

#### 1. ADC Domain (40 MHz) to Baseband (100 MHz)

**In adc_intf.v:**
```verilog
xpm_fifo_async #(
  .FIFO_WRITE_DEPTH(16),
  .WRITE_DATA_WIDTH(64),
  .READ_DATA_WIDTH(64),
  .READ_MODE("fwft"),
  .RELATED_CLOCKS(0),  // Asynchronous
  .PROG_FULL_THRESH(14)
) adc_sample_fifo (
  .wr_clk(adc_clk),           // 40 MHz write
  .wr_en(adc_valid),
  .din(adc_data),
  .rd_clk(acc_clk),           // 100 MHz read
  .rd_en(fifo_rd_en),
  .dout(sample_data),
  .empty(fifo_empty),
  .full(fifo_full)
);
```

**Data Flow:**
```
AD9361 ADC (40 MHz domain)
  ↓ adc_data[63:0], adc_valid
xpm_fifo_async (write at 40 MHz, read at 100 MHz)
  ↓ sample_data[63:0], ~fifo_empty
Baseband Processing (100 MHz domain)
```

**Timing Constraints (system.xdc):**
```tcl
set_max_delay 5 -datapath_only \
  -from [get_pins -hier -filter {NAME =~ *adc_clk*}] \
  -to [get_pins -hier -filter {NAME =~ *acc_clk*}]

set_false_path -through [get_pins -hier -filter \
  {NAME =~ *xpm_cdc*/dest_graysync_ff*}]
```

#### 2. Baseband (100 MHz) to DAC Domain (40 MHz)

**In dac_intf.v:**
```verilog
// Control signals CDC
xpm_cdc_array_single #(
  .DEST_SYNC_FF(4),
  .WIDTH(4)
) cdc_control (
  .src_clk(acc_clk),
  .src_in({ant_flag, simple_cdd_flag}),
  .dest_clk(dac_clk),
  .dest_out({ant_flag_sync, cdd_flag_sync})
);

// Data FIFO CDC
xpm_fifo_async #(
  .FIFO_WRITE_DEPTH(32),
  .WRITE_DATA_WIDTH(64),
  .READ_DATA_WIDTH(64)
) iq_fifo (
  .wr_clk(acc_clk),           // 100 MHz write
  .wr_en(iq_valid),
  .din(iq_data),
  .rd_clk(dac_clk),           // 40 MHz read
  .rd_en(dac_ready),
  .dout(dac_data),
  .empty(fifo_empty)
);
```

#### 3. GPIO Status (RF Domain) to Baseband

**In gpio_status_rf_to_bb.v:**
```verilog
// Async FIFO for AGC status
xpm_fifo_async #(
  .FIFO_WRITE_DEPTH(8),
  .WRITE_DATA_WIDTH(8),
  .READ_DATA_WIDTH(8)
) gpio_fifo (
  .wr_clk(rf_clk),            // 40 MHz RF
  .wr_en(gpio_status_valid),
  .din(gpio_status_rf),
  .rd_clk(bb_clk),            // 100 MHz BB
  .rd_en(~fifo_empty),
  .dout(gpio_status_bb_raw)
);

// Moving average filter (32-sample window)
mv_avg_dual_ch #(.LOG2_AVG_LEN(5)) avg (
  .clk(bb_clk),
  .rstn(bb_rstn),
  .data_in(gpio_status_bb_raw),
  .data_out(gpio_status_bb)
);
```

### CDC Synchronization Stages

All xpm_cdc_* primitives use **4-stage synchronization** (DEST_SYNC_FF=4):
```
Source Domain          Destination Domain
     │                       │
     ├─ Reg[0] ──────────────┼─ Sync[0] (metastable)
     │                       ├─ Sync[1] (settling)
     │                       ├─ Sync[2] (settling)
     │                       ├─ Sync[3] (stable)
     │                       └─ Output
```

**MTBF Calculation:**
```
MTBF = e^(Ts/τ) / (f_src × f_dest × τ)

Where:
  Ts = synchronization time = 4 clock cycles
  τ = flip-flop metastability time constant ≈ 200 ps
  f_src = 100 MHz (worst case)
  f_dest = 100 MHz

MTBF ≈ 10^15 hours (extremely reliable)
```

---

## Interrupt and Event Flow

### TX Interrupt Sources (Selectable via REG14[2:0])

```c
typedef enum {
  TX_INTR_SRC_TLAST = 0,      // S_AXIS_TLAST (packet end to FIFO)
  TX_INTR_SRC_PHY_START = 1,  // phy_tx_start (OFDM encoding starts)
  TX_INTR_SRC_TX_START = 2,   // tx_start_from_acc (RF TX begins)
  TX_INTR_SRC_TX_END = 3,     // tx_end_from_acc (RF TX completes)
  TX_INTR_SRC_TRY_COMPLETE = 4 // tx_try_complete (ACK received/failed)
} tx_intr_src_t;
```

**Interrupt Generation Logic:**
```verilog
// In tx_interrupt_selection.v
wire [4:0] intr_sources = {
  tx_try_complete,
  tx_end_from_acc,
  tx_start_from_acc,
  phy_tx_start,
  s00_axis_tlast
};

assign tx_itrpt_internal = intr_sources[src_sel];

assign tx_itrpt = (slv_reg14[17]==0) ?  // Global gate
                  (slv_reg14[8] ? tx_itrpt_internal :
                   (tx_itrpt_internal & (~ack_tx_flag))) : 1'b0;
```

### RX Interrupt Flow

```
OPENOFDM_RX detects packet
  ↓ fcs_in_strobe asserted
RX_INTF byte_to_word completes packet assembly
  ↓ Writes last 64-bit word to FIFO
rx_intf_m_axis.v FSM reaches end of packet
  ↓ Asserts M_AXIS_TLAST
AXI DMA S2MM writes to memory
  ↓ Updates descriptor
AXI DMA asserts s2mm_intr
  ↓ (copied to rx_pkt_intr output)
PS Interrupt Controller (GIC)
  ↓ IRQ to ARM CPU
Linux Driver IRQ Handler
  ├─ Reads RX descriptor
  ├─ Maps packet memory
  ├─ Parses 802.11 frame
  ├─ Updates statistics (RSSI, FCS, rate)
  └─ Passes to mac80211
```

### Event Counter Updates

**In side_ch_counter.v (6 independent counters):**
```verilog
// Counter 0: Preamble detection or TX start
always @(posedge clk) begin
  if (rstn && event0_trigger) begin
    counter0 <= counter0 + 1;
  end
end

// Write to slv_reg26 resets counter0
assign counter0_reset = slv_reg_wren && (axi_awaddr == 7'h1A);
```

**Event Source Configuration (side_ch_counter_event_cfg.v):**
```verilog
// Counter 0 sources
assign event0 = event_sel[0] ?
                (short_preamble_detected | long_preamble_detected) :
                phy_tx_start;

// Counter 5 sources (FCS with filtering)
assign event5 = event_sel[5] ?
                (fcs_in_strobe & addr2_match & pkt_for_me & is_data) :
                (fcs_ok & addr2_match & pkt_for_me & is_data);
```

---

## Register Access Sequences

### Example 1: Configure WiFi for RX

```c
// 1. Reset all modules
write_reg(XPU_REG_CONTROL, 0xFFFF);      // Assert all resets
usleep(10);
write_reg(XPU_REG_CONTROL, 0x0000);      // Deassert resets

// 2. Configure MAC address
write_reg(XPU_REG_MAC_ADDR_L, 0xABCDEF00);
write_reg(XPU_REG_MAC_ADDR_H, 0x00001234);

// 3. Configure BSSID (for infrastructure mode)
write_reg(XPU_REG_BSSID_L, 0x44332211);
write_reg(XPU_REG_BSSID_H, 0x0000AABB);

// 4. Set band and channel (2.4 GHz, channel 6)
write_reg(XPU_REG_BAND_CH, (0 << 16) | 6);

// 5. Configure filter flags (receive beacons and data)
uint32_t filter = FIF_BCN_PRBRESP_PROMISC | FIF_FCSFAIL;
write_reg(XPU_REG_FILTER, filter);

// 6. Set RSSI threshold for CCA
write_reg(XPU_REG_LBT_TH, -80);  // -80 dBm

// 7. Configure RX_INTF digital gain
write_reg(RX_INTF_REG11, 2);  // 4x gain (left shift by 2)

// 8. Enable RX
write_reg(RX_INTF_REG0, 0x01);
```

### Example 2: Transmit a Packet

```c
// 1. Select TX queue (priority 0 = highest)
write_reg(TX_INTF_REG8, (0 << 18));  // Queue 0

// 2. Check queue availability
uint32_t status = read_reg(TX_INTF_REG21);
if (status & 0x01) {
  // Queue 0 above threshold, may need to wait
  usleep(100);
}

// 3. DMA transfer packet to queue
struct sk_buff *skb = ...;  // WiFi frame
dma_map_single(dev, skb->data, skb->len, DMA_TO_DEVICE);
dma_submit_tx(queue=0, addr=skb->dma, len=skb->len);

// 4. Enable TX interrupt on completion
write_reg(TX_INTF_REG14, (1 << 8) | (4 << 0));
//  Bit[8]: Interrupt enable
//  Bit[2:0]: Source = 4 (tx_try_complete)

// 5. Wait for interrupt
wait_for_interrupt(tx_itrpt);

// 6. Read TX status
uint32_t status1 = read_reg(TX_INTF_REG22);
uint32_t num_retrans = status1 & 0xF;
uint32_t cw = (status1 >> 28) & 0xF;
if (num_retrans > 0) {
  printk("TX retried %d times, final CW=%d\n", num_retrans, cw);
}

// 7. For Block ACK, read bitmap
if (block_ack_mode) {
  uint32_t ssn = read_reg(TX_INTF_REG23);
  uint32_t bitmap_l = read_reg(TX_INTF_REG24);
  uint32_t bitmap_h = read_reg(TX_INTF_REG25);
  printk("Block ACK: SSN=%d, bitmap=0x%08X%08X\n",
         ssn, bitmap_h, bitmap_l);
}
```

### Example 3: Read TSF Timer

```c
// TSF is 64-bit, read in two steps
// Must read high word first, then low word
uint32_t tsf_h = read_reg(XPU_REG_TSF_READ_H);
uint32_t tsf_l = read_reg(XPU_REG_TSF_READ_L);
uint64_t tsf = ((uint64_t)tsf_h << 32) | tsf_l;

printk("Current TSF: %llu μs\n", tsf);
```

### Example 4: Synchronize TSF with AP

```c
// AP beacon contains TSF timestamp
uint64_t ap_tsf = parse_beacon_tsf(beacon_frame);

// Add RX processing delay (~80 μs)
uint64_t local_tsf = ap_tsf + 80;

// Load TSF timer
write_reg(XPU_REG_TSF_LOAD_L, (uint32_t)(local_tsf & 0xFFFFFFFF));
write_reg(XPU_REG_TSF_LOAD_H, (uint32_t)(local_tsf >> 32));
//  Writing high word triggers load on rising edge of MSB
```

---

## Summary

This document provides detailed timing diagrams and interaction sequences for:
- **TX Path**: Software → DMA → TX_INTF → OPENOFDM_TX → DAC → AD9361 (200-700μs latency)
- **RX Path**: AD9361 → ADC → RX_INTF → OPENOFDM_RX → XPU → DMA → Software (50-300μs latency)
- **MAC Control**: CSMA/CA backoff, ACK handling, retransmission logic
- **Clock Domains**: RF (40 MHz), Baseband (100 MHz), robust CDC with 4-stage sync
- **Interrupts**: TX completion, RX packet, event counters
- **Register Access**: Configuration sequences for TX, RX, TSF sync

These flows demonstrate the complete hardware/software co-design approach, with timing-critical MAC operations in hardware and higher-level protocol handling in software.
