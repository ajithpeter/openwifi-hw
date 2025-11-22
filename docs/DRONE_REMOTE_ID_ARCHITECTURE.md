# Enhanced WiFi Monitor & Drone Remote ID Architecture

## Table of Contents
1. [System Overview](#system-overview)
2. [ASTM F3411 / ASD-STAN Remote ID Requirements](#astm-f3411--asd-stan-remote-id-requirements)
3. [WiFi Standards Support Matrix](#wifi-standards-support-matrix)
4. [WiFi Aware/NAN Implementation](#wifi-awarenan-implementation)
5. [Monitor Mode Architecture](#monitor-mode-architecture)
6. [Frame Injection Engine](#frame-injection-engine)
7. [Module Design](#module-design)
8. [Implementation Phases](#implementation-phases)

---

## System Overview

### Enhanced Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Linux User Space                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │ Remote ID    │  │ WiFi Monitor │  │ Frame Injector     │    │
│  │ Application  │  │ (tcpdump/    │  │ (wfb-ng style)     │    │
│  │ (ASTM F3411) │  │  wireshark)  │  │                    │    │
│  └──────┬───────┘  └──────┬───────┘  └────────┬───────────┘    │
│         │                 │                    │                │
│  ┌──────▼─────────────────▼────────────────────▼───────────┐   │
│  │        Enhanced OpenWiFi Driver (monitor + inject)       │   │
│  │  - NAN/Aware support                                     │   │
│  │  - Vendor IE handling                                    │   │
│  │  - Raw frame injection                                   │   │
│  │  - Radiotap headers                                      │   │
│  └──────────────────────┬───────────────────────────────────┘   │
└─────────────────────────┼───────────────────────────────────────┘
                          │ AXI DMA
┌─────────────────────────▼───────────────────────────────────────┐
│                    FPGA (Zynq7020)                               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Enhanced XPU (MAC Processor)                              │  │
│  │  ┌─────────────────┐  ┌──────────────────────────────┐   │  │
│  │  │ Beacon Scanner  │  │ Vendor IE Parser/Generator   │   │  │
│  │  │ - All standards │  │ - Remote ID encoder/decoder  │   │  │
│  │  │ - NAN support   │  │ - Custom IE injection        │   │  │
│  │  └─────────────────┘  └──────────────────────────────┘   │  │
│  │  ┌─────────────────┐  ┌──────────────────────────────┐   │  │
│  │  │ Monitor Filter  │  │ Frame Injection Controller   │   │  │
│  │  │ - All frame     │  │ - Raw frame TX               │   │  │
│  │  │   types         │  │ - Rate/power control         │   │  │
│  │  │ - Promiscuous   │  │ - Sequence numbering         │   │  │
│  │  └─────────────────┘  └──────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Multi-Rate PHY (OPENOFDM_TX/RX + CCK)                    │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │  │
│  │  │ 802.11b  │  │ 802.11a  │  │ 802.11g  │  │ 802.11n  │ │  │
│  │  │   CCK    │  │   OFDM   │  │   OFDM   │  │ HT-OFDM  │ │  │
│  │  │ 1-11Mbps │  │ 6-54Mbps │  │ 6-54Mbps │  │ MCS0-15  │ │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Enhanced RX/TX Interfaces                                 │  │
│  │  - Radiotap metadata injection                            │  │
│  │  - RSSI/SNR/Channel info                                  │  │
│  │  - Timestamp precision                                    │  │
│  └───────────────────────────────────────────────────────────┘  │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            ▼
                     AD9361 Transceiver
                     70 MHz - 6 GHz
```

---

## ASTM F3411 / ASD-STAN Remote ID Requirements

### Standards Overview

**ASTM F3411-22:** Standard Specification for Remote ID and Tracking
**ASD-STAN prEN 4709-002:** European UAS Remote Identification

### Remote ID Message Types

```c
// ASTM F3411 Message Types
typedef enum {
    REMOTE_ID_BASIC_ID = 0,           // Static drone information
    REMOTE_ID_LOCATION = 1,           // Current location/velocity
    REMOTE_ID_AUTH = 2,               // Authentication data
    REMOTE_ID_SELF_ID = 3,            // Operator ID/description
    REMOTE_ID_SYSTEM = 4,             // System information
    REMOTE_ID_OPERATOR_ID = 5,        // Operator location
    REMOTE_ID_MESSAGE_PACK = 0xF      // Multi-message pack
} remote_id_msg_type_t;
```

### WiFi Aware/NAN Broadcast Format

**Frame Structure:**
```
┌────────────────────────────────────────────────────────────┐
│ IEEE 802.11 Management Frame (Action)                      │
├────────────────────────────────────────────────────────────┤
│ Frame Control: Type=00 (Mgmt), Subtype=1101 (Action)      │
│ Duration: 0                                                 │
│ Address 1 (DA): FF:FF:FF:FF:FF:FF (broadcast)             │
│ Address 2 (SA): Transmitter MAC                            │
│ Address 3 (BSSID): FF:FF:FF:FF:FF:FF                       │
│ Sequence Control                                           │
├────────────────────────────────────────────────────────────┤
│ Action Frame Body                                          │
│  ├─ Category: Vendor Specific (127 / 0x7F)                │
│  ├─ OUI: WiFi Alliance (0x506F9A)                         │
│  ├─ OUI Type: NAN (0x13)                                  │
│  └─ NAN Attributes                                         │
│     ├─ Service Descriptor Attribute (SDA)                 │
│     │  └─ Service Info: Remote ID Payload                 │
│     └─ Other NAN attributes                               │
└────────────────────────────────────────────────────────────┘
```

### Remote ID Payload Format (ASTM F3411)

**Basic ID Message (Type 0):**
```c
struct remote_id_basic_id {
    uint8_t  msg_type;              // 0x00
    uint8_t  id_type;               // 0=Serial, 1=CAA, 2=UTM, 3=Specific
    uint8_t  ua_type;               // 0=None, 1=Aero, 2=Heli, etc.
    uint8_t  uas_id[20];            // UAS ID (Serial number, etc.)
    uint8_t  reserved[2];
} __attribute__((packed));          // 25 bytes total
```

**Location/Vector Message (Type 1):**
```c
struct remote_id_location {
    uint8_t  msg_type;              // 0x01
    uint8_t  status;                // Operational status flags
    uint8_t  direction;             // Heading (0-360 deg, 1 deg res)
    uint8_t  speed_horiz;           // 0-255 m/s (0.25 m/s res)
    int8_t   speed_vert;            // -127 to +127 m/s (0.5 m/s res)
    int32_t  latitude;              // ±90 deg (1e-7 deg res)
    int32_t  longitude;             // ±180 deg (1e-7 deg res)
    int16_t  altitude_baro;         // -1000 to +31767.5 m (0.5 m res)
    int16_t  altitude_geo;          // -1000 to +31767.5 m (0.5 m res)
    uint16_t height_agl;            // 0-1000 m (1 m res)
    uint8_t  horiz_accuracy;        // Encoded accuracy
    uint8_t  vert_accuracy;         // Encoded accuracy
    uint8_t  baro_accuracy;         // Encoded accuracy
    uint8_t  speed_accuracy;        // Encoded accuracy
    uint16_t timestamp;             // Seconds since hour (0.1 s res)
    uint8_t  reserved;
} __attribute__((packed));          // 25 bytes total
```

### WiFi Aware Transmission Parameters

**Transmission Frequency:**
- **Rate**: 1 Hz minimum (once per second)
- **Discovery Window (DW)**: Every 512 TUs (524.288 ms)
- **Channel**: 2.4 GHz (Channel 6) or 5 GHz (depending on region)

**NAN Synchronization:**
- Master: Sends synchronization beacons
- Non-Master: Listens and synchronizes to master
- Discovery Window: 16 TU (16.384 ms) every DW interval

---

## WiFi Standards Support Matrix

### Implemented Standards

| Standard | Frequency | Modulation | Data Rates | Status |
|----------|-----------|------------|------------|--------|
| **802.11b** | 2.4 GHz | DSSS/CCK | 1, 2, 5.5, 11 Mbps | ⚠️ Partial (needs CCK PHY) |
| **802.11a** | 5 GHz | OFDM | 6, 9, 12, 18, 24, 36, 48, 54 Mbps | ✅ Full |
| **802.11g** | 2.4 GHz | OFDM | 6, 9, 12, 18, 24, 36, 48, 54 Mbps | ✅ Full |
| **802.11n** | 2.4/5 GHz | HT-OFDM | MCS 0-15 (6.5-150 Mbps, 20 MHz) | ✅ Full (20 MHz only) |
| **802.11ac** | 5 GHz | VHT-OFDM | MCS 0-9, 80/160 MHz | 🔧 Future (needs VHT PHY) |
| **802.11ax** | 2.4/5/6 GHz | HE-OFDM | MCS 0-11, OFDMA | 🔧 Future (needs HE PHY) |

**Legend:**
- ✅ Full: Fully implemented
- ⚠️ Partial: Basic support, missing features
- 🔧 Future: Requires additional FPGA resources

### Current FPGA Limitations

**Zynq7020 Resources:**
```
Available:        Used (current):   Projected (full):
LUTs:   53,200    ~45,000 (85%)     ~50,000 (94%)
BRAMs:  140       ~90 (64%)         ~120 (86%)
DSP48:  220       ~50 (23%)         ~80 (36%)
```

**Feasibility:**
- **802.11b CCK**: Feasible (requires ~5K LUTs, 10 DSP48)
- **802.11ac VHT**: Challenging (requires 128/256-point FFT, ~15K LUTs)
- **802.11ax HE**: Not feasible on Zynq7020 (requires OFDMA scheduler, 1024-QAM)

### Implementation Approach

**Phase 1 (Current):**
- 802.11a/g/n OFDM (already implemented)
- Enhanced beacon support
- Monitor mode for OFDM frames

**Phase 2 (This Release):**
- 802.11b CCK basic support (BPSK/QPSK only)
- WiFi Aware/NAN action frames
- Remote ID vendor IE handling
- Raw frame injection

**Phase 3 (Future):**
- 802.11ac VHT (requires Zynq7035 or larger FPGA)
- 802.11ax HE (requires UltraScale+ FPGA)

---

## WiFi Aware/NAN Implementation

### NAN Protocol Stack

```
┌─────────────────────────────────────────────────────────┐
│ Application Layer                                        │
│  - Remote ID encoding/decoding                           │
│  - Service discovery                                     │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│ NAN Protocol Layer (Software)                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ NAN Data Path│  │ NAN Mgmt     │  │ Sync & Timing│  │
│  │ Layer (NDP)  │  │ Layer (NMF)  │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│ MAC Layer (FPGA)                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Action Frame Handler                             │   │
│  │  - Category: Vendor Specific (127)               │   │
│  │  - OUI: WiFi Alliance (0x506F9A)                 │   │
│  │  - Type: NAN (0x13)                              │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Discovery Window Timing                          │   │
│  │  - DW Interval: 512 TUs (524.288 ms)            │   │
│  │  - DW Duration: 16 TUs (16.384 ms)              │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### NAN Frame Format

**Action Frame Header:**
```c
struct nan_action_frame {
    // MAC Header
    uint16_t frame_control;         // 0xD0 (Action, no ToDS/FromDS)
    uint16_t duration;              // 0
    uint8_t  da[6];                 // FF:FF:FF:FF:FF:FF (broadcast)
    uint8_t  sa[6];                 // Source address
    uint8_t  bssid[6];              // NAN cluster ID
    uint16_t seq_ctrl;

    // Action Frame Body
    uint8_t  category;              // 127 (Vendor Specific)
    uint8_t  oui[3];                // 0x506F9A (WiFi Alliance)
    uint8_t  oui_type;              // 0x13 (NAN)

    // NAN Header
    uint8_t  nan_oui_subtype;       // 0x00
    uint16_t dialog_token;

    // NAN Attributes (TLV format)
    // [Type|Length|Value] repeated
} __attribute__((packed));
```

**NAN Attribute TLV Format:**
```c
struct nan_attribute {
    uint8_t  attr_id;               // Attribute ID
    uint16_t length;                // Length (little-endian)
    uint8_t  value[];               // Variable length data
} __attribute__((packed));

// Common NAN Attribute IDs
#define NAN_ATTR_MASTER_INDICATION      0x00
#define NAN_ATTR_CLUSTER                0x01
#define NAN_ATTR_SERVICE_ID             0x02
#define NAN_ATTR_SERVICE_DESCRIPTOR     0x03
#define NAN_ATTR_VENDOR_SPECIFIC        0xDD
```

### Remote ID Service Descriptor

```c
struct nan_service_descriptor {
    uint8_t  attr_id;               // 0x03
    uint16_t length;
    uint8_t  service_id[6];         // Hash of "org.astm.f3411"
    uint8_t  instance_id;
    uint8_t  requestor_instance_id;
    uint8_t  service_control;
    uint8_t  binding_bitmap;
    uint8_t  service_info_len;
    uint8_t  service_info[];        // Remote ID payload (25 bytes)
} __attribute__((packed));

// Service ID for Remote ID
// SHA-256("org.astm.f3411.remoteid")[0:6]
const uint8_t REMOTE_ID_SERVICE_ID[6] = {
    0x88, 0x69, 0x19, 0x9D, 0x92, 0x09
};
```

---

## Monitor Mode Architecture

### Enhanced Packet Filter

```verilog
// In enhanced_pkt_filter.v
module enhanced_pkt_filter (
    input wire clk,
    input wire rstn,

    // Frame classification inputs
    input wire [1:0] fc_type,           // 00=mgmt, 01=ctrl, 10=data
    input wire [3:0] fc_subtype,
    input wire [47:0] addr1,            // DA
    input wire [47:0] addr2,            // SA
    input wire [47:0] addr3,            // BSSID or DA
    input wire fcs_ok,

    // Monitor mode configuration
    input wire monitor_mode_en,         // Enable monitor mode
    input wire capture_mgmt,            // Capture management frames
    input wire capture_ctrl,            // Capture control frames
    input wire capture_data,            // Capture data frames
    input wire capture_beacon,          // Specific: beacons
    input wire capture_probe_req,       // Specific: probe requests
    input wire capture_probe_resp,      // Specific: probe responses
    input wire capture_nan,             // Specific: NAN action frames
    input wire capture_fcs_fail,        // Include FCS failures
    input wire promiscuous,             // True promiscuous (no addr filter)

    // Filter outputs
    output reg allow_to_dma,            // Allow packet to DMA
    output reg [7:0] packet_type        // Classified packet type
);

// Frame type classification
localparam TYPE_MGMT     = 2'b00;
localparam TYPE_CTRL     = 2'b01;
localparam TYPE_DATA     = 2'b10;

// Management subtypes
localparam SUBTYPE_ASSOC_REQ    = 4'h0;
localparam SUBTYPE_ASSOC_RESP   = 4'h1;
localparam SUBTYPE_PROBE_REQ    = 4'h4;
localparam SUBTYPE_PROBE_RESP   = 4'h5;
localparam SUBTYPE_BEACON       = 4'h8;
localparam SUBTYPE_DISASSOC     = 4'hA;
localparam SUBTYPE_AUTH         = 4'hB;
localparam SUBTYPE_DEAUTH       = 4'hC;
localparam SUBTYPE_ACTION       = 4'hD;

// Classification logic
always @(posedge clk) begin
    if (!rstn) begin
        allow_to_dma <= 0;
        packet_type <= 0;
    end else if (monitor_mode_en) begin
        // In monitor mode, check each filter
        case (fc_type)
            TYPE_MGMT: begin
                if (capture_mgmt) begin
                    case (fc_subtype)
                        SUBTYPE_BEACON:     allow_to_dma <= capture_beacon;
                        SUBTYPE_PROBE_REQ:  allow_to_dma <= capture_probe_req;
                        SUBTYPE_PROBE_RESP: allow_to_dma <= capture_probe_resp;
                        SUBTYPE_ACTION:     allow_to_dma <= capture_nan;
                        default:            allow_to_dma <= 1;
                    endcase
                    packet_type <= {fc_type, fc_subtype, 2'b00};
                end
            end

            TYPE_CTRL: begin
                allow_to_dma <= capture_ctrl;
                packet_type <= {fc_type, fc_subtype, 2'b00};
            end

            TYPE_DATA: begin
                allow_to_dma <= capture_data;
                packet_type <= {fc_type, fc_subtype, 2'b00};
            end
        endcase

        // Override for FCS failures
        if (!fcs_ok && !capture_fcs_fail) begin
            allow_to_dma <= 0;
        end

        // Override for promiscuous
        if (promiscuous) begin
            allow_to_dma <= (fcs_ok || capture_fcs_fail);
        end
    end
end

endmodule
```

### Radiotap Header Generation

```c
// In rx_intf module, add radiotap metadata
struct radiotap_header {
    uint8_t  it_version;            // 0
    uint8_t  it_pad;                // 0
    uint16_t it_len;                // Total header length
    uint32_t it_present;            // Bitmap of present fields

    // Present fields (if bits set in it_present):
    uint64_t tsft;                  // Timestamp (μs)
    uint8_t  flags;                 // RX flags
    uint8_t  rate;                  // Data rate (500 kbps units)
    uint16_t channel_freq;          // Channel frequency (MHz)
    uint16_t channel_flags;         // Channel type
    int8_t   dbm_antsignal;         // Signal strength (dBm)
    int8_t   dbm_antnoise;          // Noise level (dBm)
    uint8_t  antenna;               // Antenna index
    uint8_t  mcs_known;             // MCS known fields
    uint8_t  mcs_flags;             // MCS flags
    uint8_t  mcs_index;             // MCS index (0-31)
} __attribute__((packed));

// Present field bitmask
#define RADIOTAP_TSFT           (1 << 0)
#define RADIOTAP_FLAGS          (1 << 1)
#define RADIOTAP_RATE           (1 << 2)
#define RADIOTAP_CHANNEL        (1 << 3)
#define RADIOTAP_DBM_ANTSIGNAL  (1 << 5)
#define RADIOTAP_DBM_ANTNOISE   (1 << 6)
#define RADIOTAP_ANTENNA        (1 << 11)
#define RADIOTAP_MCS            (1 << 19)
```

---

## Frame Injection Engine

### Raw Frame Injection Architecture

```
User Space Application
  ↓ write() or sendto()
Socket Layer (AF_PACKET, SOCK_RAW)
  ↓
OpenWiFi Driver (inject mode)
  ├─ Parse radiotap header
  ├─ Extract rate/power/retries
  ├─ Validate frame format
  └─ Queue to TX DMA
  ↓
TX_INTF (FPGA)
  ├─ Read frame from BRAM
  ├─ Apply rate/power from radiotap
  ├─ Bypass CSMA/CA (if requested)
  └─ Send to OPENOFDM_TX
  ↓
OPENOFDM_TX
  ├─ Generate OFDM symbols
  └─ Output to DAC
  ↓
AD9361 → Antenna
```

### Injection Control Registers

```verilog
// Additional TX_INTF registers for injection
module tx_inject_ctrl (
    input wire clk,
    input wire rstn,

    // AXI slave interface (registers)
    input wire [31:0] slv_reg_inject_ctrl,
    input wire [31:0] slv_reg_inject_rate,
    input wire [31:0] slv_reg_inject_power,
    input wire [31:0] slv_reg_inject_retries,

    // Frame injection control
    output reg inject_mode_en,          // Bypass CSMA/CA
    output reg [7:0] inject_rate,       // Override rate
    output reg [7:0] inject_power,      // Override TX power
    output reg [3:0] inject_retries,    // Override retries
    output reg no_ack_wait,             // Don't wait for ACK
    output reg no_seq_update            // Don't update sequence number
);

// Register mapping
always @(posedge clk) begin
    if (!rstn) begin
        inject_mode_en <= 0;
        inject_rate <= 0;
        inject_power <= 0;
        inject_retries <= 0;
        no_ack_wait <= 0;
        no_seq_update <= 0;
    end else begin
        inject_mode_en <= slv_reg_inject_ctrl[0];
        no_ack_wait <= slv_reg_inject_ctrl[1];
        no_seq_update <= slv_reg_inject_ctrl[2];
        inject_rate <= slv_reg_inject_rate[7:0];
        inject_power <= slv_reg_inject_power[7:0];
        inject_retries <= slv_reg_inject_retries[3:0];
    end
end

endmodule
```

### wfb-ng Style Video Streaming Support

**Key Requirements:**
1. **Low Latency**: Minimize processing delay
2. **Forward Error Correction (FEC)**: Reed-Solomon or LDPC
3. **Adaptive Bitrate**: Adjust to channel conditions
4. **Multiple Receivers**: Broadcast to multiple ground stations

**Implementation:**
```c
// FEC encoding (user space)
void fec_encode_block(uint8_t *data, size_t data_len,
                      uint8_t *fec_packets, int k, int n)
{
    // Reed-Solomon (k data packets, n total packets)
    // Uses libfec or similar
    encode_rs_8(data, fec_packets, k, n);
}

// Injection loop
void inject_video_stream(int sock_fd, uint8_t *video_data, size_t len)
{
    struct {
        struct radiotap_header rt;
        struct ieee80211_header hdr;
        uint8_t payload[1500];
    } __attribute__((packed)) frame;

    // Set radiotap
    frame.rt.it_version = 0;
    frame.rt.it_len = sizeof(struct radiotap_header);
    frame.rt.it_present = RADIOTAP_RATE | RADIOTAP_TX_FLAGS;
    frame.rt.rate = 12;  // 6 Mbps (12 × 500 kbps)
    frame.rt.tx_flags = 0x0008;  // No ACK

    // Set 802.11 header
    frame.hdr.frame_control = 0x0008;  // Data, no ToDS/FromDS
    memset(frame.hdr.addr1, 0xFF, 6);  // Broadcast
    memcpy(frame.hdr.addr2, src_mac, 6);
    memcpy(frame.hdr.addr3, bssid, 6);

    // Fragment and send
    size_t offset = 0;
    uint16_t seq = 0;
    while (offset < len) {
        size_t chunk = (len - offset > 1500) ? 1500 : (len - offset);
        memcpy(frame.payload, video_data + offset, chunk);
        frame.hdr.seq_ctrl = (seq++) << 4;

        send(sock_fd, &frame, sizeof(frame.rt) + sizeof(frame.hdr) + chunk, 0);
        offset += chunk;

        usleep(100);  // Rate limiting
    end
}
```

---

## Module Design

### New IP Cores

#### 1. enhanced_xpu (Enhanced MAC Processor)

**Location:** `/ip/enhanced_xpu/`

**Additions to XPU:**
- NAN action frame handler
- Vendor IE parser/generator
- Remote ID encoder/decoder
- Enhanced monitor mode filter
- Injection mode controller

**New Files:**
```
enhanced_xpu/
├── src/
│   ├── enhanced_xpu.v              # Top wrapper
│   ├── nan_action_handler.v        # NAN frame processing
│   ├── vendor_ie_codec.v           # IE encoding/decoding
│   ├── remote_id_codec.v           # ASTM F3411 codec
│   ├── enhanced_pkt_filter.v       # Monitor mode filter
│   ├── inject_controller.v         # Frame injection control
│   └── (inherit from xpu/)
├── test/
│   ├── nan_action_handler_tb.v
│   ├── vendor_ie_codec_tb.v
│   └── remote_id_codec_tb.v
└── enhanced_xpu.tcl
```

#### 2. cck_modem (802.11b CCK Modulator/Demodulator)

**Location:** `/ip/cck_modem/`

**Purpose:** Add 802.11b DSSS/CCK support

**Files:**
```
cck_modem/
├── src/
│   ├── cck_modem.v                 # Top wrapper
│   ├── cck_tx.v                    # CCK transmitter
│   │   ├── barker_spread.v         # DBPSK/DQPSK (1/2 Mbps)
│   │   ├── cck_spread.v            # CCK (5.5/11 Mbps)
│   │   └── scrambler_11b.v         # 11b scrambler
│   ├── cck_rx.v                    # CCK receiver
│   │   ├── correlator.v            # Barker correlator
│   │   ├── cck_demod.v             # CCK demodulation
│   │   └── descrambler_11b.v       # 11b descrambler
│   └── plcp_header.v               # PLCP preamble/header
├── test/
│   ├── cck_tx_tb.v
│   ├── cck_rx_tb.v
│   └── test_vectors/
│       ├── 11b_1mbps.txt
│       ├── 11b_2mbps.txt
│       ├── 11b_5_5mbps.txt
│       └── 11b_11mbps.txt
└── cck_modem.tcl
```

**CCK Modulation:**
```
1 Mbps:   DBPSK with Barker-11 spreading (11 chips/bit)
2 Mbps:   DQPSK with Barker-11 spreading (11 chips/2 bits)
5.5 Mbps: CCK with 8-chip codes (8 chips/4 bits)
11 Mbps:  CCK with 8-chip codes (8 chips/8 bits)
```

---

## Implementation Phases

### Phase 1: Enhanced Monitor & Beacon (Week 1-2)

**Deliverables:**
- [x] Architecture documentation (this file)
- [ ] Enhanced XPU with monitor mode filter
- [ ] Beacon scanner for all OFDM modes
- [ ] Radiotap header support
- [ ] Basic NAN action frame parsing

**Testing:**
- Unit tests for packet filter
- Integration test: capture beacons from real AP
- Monitor mode test with tcpdump/wireshark

### Phase 2: Remote ID & NAN (Week 3-4)

**Deliverables:**
- [ ] Vendor IE encoder/decoder
- [ ] ASTM F3411 message codec
- [ ] NAN service descriptor handling
- [ ] Remote ID transmission at 1 Hz
- [ ] Remote ID reception and parsing

**Testing:**
- Unit tests for IE codec
- Unit tests for Remote ID messages
- Integration test: transmit Remote ID, capture with OpenDroneID app
- Compliance test: verify ASTM F3411 format

### Phase 3: Frame Injection (Week 5-6)

**Deliverables:**
- [ ] Raw frame injection engine
- [ ] Rate/power override controls
- [ ] Sequence number management
- [ ] wfb-ng compatibility layer
- [ ] FEC support (user space)

**Testing:**
- Unit tests for injection controller
- Integration test: inject custom beacons
- Video streaming test: wfb-ng style transmission
- Performance test: measure latency and throughput

### Phase 4: CCK Support (Week 7-8)

**Deliverables:**
- [ ] CCK modulator (1, 2, 5.5, 11 Mbps)
- [ ] CCK demodulator
- [ ] PLCP preamble/header handling
- [ ] Integration with enhanced_xpu

**Testing:**
- Unit tests for CCK modem
- Integration test: transmit 802.11b beacons
- Interoperability test: receive from commercial 802.11b devices

### Phase 5: Integration & Validation (Week 9-10)

**Deliverables:**
- [ ] Complete system integration
- [ ] Build for all PlutoSDR boards
- [ ] Performance optimization
- [ ] Documentation and examples

**Testing:**
- Full system test: Monitor + Inject + Remote ID
- Stress test: High packet rate capture/injection
- Compliance test: ASTM F3411, WiFi Alliance NAN
- Field test: Real drone Remote ID broadcast

---

## Performance Targets

### Monitor Mode
- **Capture Rate**: >1000 packets/second
- **Latency**: <5 ms (packet arrival to DMA)
- **CPU Usage**: <10% at 100 packets/second

### Frame Injection
- **Injection Rate**: >500 packets/second
- **Latency**: <10 ms (user space to RF)
- **Accuracy**: Sequence numbers, timestamps within ±100 μs

### Remote ID
- **Transmission Rate**: 1 Hz (per ASTM F3411)
- **Reception Range**: >500m (open field, 2.4 GHz)
- **Latency**: <100 ms (GPS data to RF transmission)

---

**Document Version:** 1.0
**Author:** OpenWiFi Team
**Last Updated:** 2025-11-22
**License:** AGPL-3.0
