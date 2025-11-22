# enhanced_xpu API Reference

**OpenWiFi Project**
**Version: 1.0**
**Last Updated: 2025-11-22**

## Table of Contents

1. [Overview](#overview)
2. [Device Interface](#device-interface)
3. [ioctl Commands](#ioctl-commands)
4. [Data Structures](#data-structures)
5. [AXI Register Map](#axi-register-map)
6. [Helper Functions](#helper-functions)
7. [Code Examples](#code-examples)

---

## Overview

The enhanced_xpu module provides a user-space API for advanced WiFi packet filtering and frame injection through the `/dev/sdr0` character device.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    User Space Application                    │
│                  (monitor_beacons, inject_beacon, etc.)      │
└───────────────────┬─────────────────────────────────────────┘
                    │ ioctl(), read(), write()
                    │
┌───────────────────▼─────────────────────────────────────────┐
│                   /dev/sdr0 Character Device                 │
│                   (sdr.ko Kernel Driver)                     │
└───────────────────┬─────────────────────────────────────────┘
                    │ AXI MMIO, DMA
                    │
┌───────────────────▼─────────────────────────────────────────┐
│                     FPGA (Zynq PL)                           │
│  ┌───────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │enhanced_pkt_  │  │frame_injection│  │    openofdm     │  │
│  │filter         │  │ctrl           │  │    tx / rx      │  │
│  └───────────────┘  └──────────────┘  └─────────────────┘  │
└───────────────────┬─────────────────────────────────────────┘
                    │
                    ▼
              ┌──────────┐
              │ AD9361   │ RF Transceiver
              │ (2x2)    │
              └──────────┘
```

---

## Device Interface

### Opening the Device

```c
#include <fcntl.h>
#include <sys/ioctl.h>

int fd = open("/dev/sdr0", O_RDWR);
if (fd < 0) {
    perror("Failed to open /dev/sdr0");
    return -1;
}
```

**Returns**: File descriptor on success, -1 on error

**Permissions**: Requires root or membership in `sdr` group

### Reading Frames (Monitor Mode)

```c
#include <unistd.h>

uint8_t buffer[4096];
ssize_t nread;

nread = read(fd, buffer, sizeof(buffer));
if (nread < 0) {
    perror("read");
    return -1;
}

// Process frame
process_frame(buffer, nread);
```

**Returns**: Number of bytes read, or -1 on error

**Frame Format**: Raw 802.11 frame (may include radiotap header if enabled)

### Writing Frames (Not Recommended)

For frame injection, use `IOCTL_INJECT_FRAME` instead of `write()`.

### Closing the Device

```c
close(fd);
```

---

## ioctl Commands

All ioctl commands use the magic number `'o'` (0x6F).

### Summary Table

| ioctl | Code | R/W | Description |
|-------|------|-----|-------------|
| IOCTL_SET_MONITOR_MODE | 10 | W | Enable/disable monitor mode |
| IOCTL_SET_CHANNEL | 11 | W | Set WiFi channel |
| IOCTL_SET_FILTER | 12 | W | Configure packet filter |
| IOCTL_GET_STATS | 13 | R | Get statistics |
| IOCTL_SET_TX_POWER | 21 | W | Set TX power |
| IOCTL_SET_DATA_RATE | 22 | W | Set data rate |
| IOCTL_INJECT_FRAME | 20 | W | Inject WiFi frame |
| IOCTL_GET_RSSI | 30 | R | Get RSSI of last frame |
| IOCTL_SET_MAC_ADDR | 31 | W | Set MAC address |

### IOCTL_SET_MONITOR_MODE

Enable or disable monitor mode.

**Definition**:
```c
#define IOCTL_SET_MONITOR_MODE  _IOW('o', 10, uint32_t)
```

**Parameters**:
- `arg`: `1` to enable, `0` to disable

**Example**:
```c
uint32_t enable = 1;
if (ioctl(fd, IOCTL_SET_MONITOR_MODE, enable) < 0) {
    perror("ioctl IOCTL_SET_MONITOR_MODE");
    return -1;
}
```

**Returns**: 0 on success, -1 on error

---

### IOCTL_SET_CHANNEL

Set the WiFi channel.

**Definition**:
```c
#define IOCTL_SET_CHANNEL  _IOW('o', 11, uint32_t)
```

**Parameters**:
- `arg`: Channel number (1-14 for 2.4 GHz, 36-165 for 5 GHz)

**Example**:
```c
uint32_t channel = 6;
if (ioctl(fd, IOCTL_SET_CHANNEL, channel) < 0) {
    perror("ioctl IOCTL_SET_CHANNEL");
    return -1;
}
```

**Channel Mapping (2.4 GHz)**:
| Channel | Frequency (MHz) | Allowed Regions |
|---------|-----------------|-----------------|
| 1 | 2412 | Worldwide |
| 6 | 2437 | Worldwide |
| 11 | 2462 | Worldwide |
| 14 | 2484 | Japan only |

**Channel Mapping (5 GHz)**:
| Channel | Frequency (MHz) | Notes |
|---------|-----------------|-------|
| 36 | 5180 | UNII-1 |
| 40 | 5200 | UNII-1 |
| 149 | 5745 | UNII-3, common for FPV |
| 165 | 5825 | UNII-3 |

**Returns**: 0 on success, -1 on error

---

### IOCTL_SET_FILTER

Configure packet filter for monitor mode.

**Definition**:
```c
#define IOCTL_SET_FILTER  _IOW('o', 12, uint32_t)
```

**Parameters**:
- `arg`: Bitmask of filter flags (see below)

**Filter Flags**:
```c
#define FILTER_BEACON       (1 << 0)  /* 0x01 */
#define FILTER_PROBE_REQ    (1 << 1)  /* 0x02 */
#define FILTER_PROBE_RESP   (1 << 2)  /* 0x04 */
#define FILTER_DATA         (1 << 3)  /* 0x08 */
#define FILTER_NAN          (1 << 4)  /* 0x10 */
#define FILTER_AUTH         (1 << 5)  /* 0x20 */
#define FILTER_DEAUTH       (1 << 6)  /* 0x40 */
#define FILTER_ASSOC        (1 << 7)  /* 0x80 */
#define FILTER_CTRL         (1 << 8)  /* 0x100 */
#define FILTER_FCS_FAIL     (1 << 9)  /* 0x200 */
#define FILTER_PROMISCUOUS  (1 << 15) /* 0x8000 */
```

**Example**:
```c
// Capture beacons and NAN frames
uint32_t filter = FILTER_BEACON | FILTER_NAN;
ioctl(fd, IOCTL_SET_FILTER, filter);

// Capture everything (promiscuous)
uint32_t filter_all = FILTER_PROMISCUOUS;
ioctl(fd, IOCTL_SET_FILTER, filter_all);
```

**Returns**: 0 on success, -1 on error

---

### IOCTL_INJECT_FRAME

Inject a WiFi frame for transmission.

**Definition**:
```c
#define IOCTL_INJECT_FRAME  _IOW('o', 20, void*)
```

**Parameters**:
- `arg`: Pointer to `struct inject_params`

**Structure**:
```c
struct inject_params {
    uint8_t  *frame;     /* Pointer to frame data */
    uint32_t  length;    /* Frame length in bytes */
    uint32_t  rate;      /* Data rate in Mbps (1, 6, 12, 18, 24, 36, 48, 54) */
    uint32_t  retries;   /* Number of retries (0 = no retries) */
    uint32_t  flags;     /* Injection flags (see below) */
} __attribute__((packed));
```

**Injection Flags**:
```c
#define INJECT_NO_ACK       (1 << 0)  /* Don't wait for ACK */
#define INJECT_USE_CTS      (1 << 1)  /* Use CTS-to-self */
#define INJECT_USE_RTS      (1 << 2)  /* Use RTS/CTS */
#define INJECT_NO_SEQ       (1 << 3)  /* Don't auto-increment sequence */
#define INJECT_OVERRIDE_RATE (1 << 4) /* Override rate control */
```

**Example**:
```c
uint8_t frame[256];
int frame_len = build_beacon_frame(frame, sizeof(frame));

struct inject_params params = {
    .frame = frame,
    .length = frame_len,
    .rate = 6,          /* 6 Mbps */
    .retries = 0,       /* No retries (broadcast) */
    .flags = INJECT_NO_ACK
};

if (ioctl(fd, IOCTL_INJECT_FRAME, &params) < 0) {
    perror("ioctl IOCTL_INJECT_FRAME");
    return -1;
}
```

**Returns**: 0 on success, -1 on error

**Error Codes**:
- `EINVAL`: Invalid parameters (bad rate, length too large, etc.)
- `EBUSY`: TX queue full, try again later
- `EIO`: Hardware error

---

### IOCTL_SET_TX_POWER

Set transmission power.

**Definition**:
```c
#define IOCTL_SET_TX_POWER  _IOW('o', 21, uint32_t)
```

**Parameters**:
- `arg`: TX power in dBm (range: 0-20 for most hardware)

**Example**:
```c
uint32_t tx_power = 15;  /* 15 dBm */
ioctl(fd, IOCTL_SET_TX_POWER, tx_power);
```

**Returns**: 0 on success, -1 on error

**Note**: Actual TX power may be limited by hardware and regulatory constraints.

---

### IOCTL_GET_STATS

Get driver and hardware statistics.

**Definition**:
```c
#define IOCTL_GET_STATS  _IOR('o', 13, struct sdr_stats)
```

**Structure**:
```c
struct sdr_stats {
    uint64_t rx_packets;      /* Total RX packets */
    uint64_t tx_packets;      /* Total TX packets */
    uint64_t rx_bytes;        /* Total RX bytes */
    uint64_t tx_bytes;        /* Total TX bytes */
    uint32_t rx_errors;       /* RX errors (FCS, etc.) */
    uint32_t tx_errors;       /* TX errors */
    uint32_t rx_dropped;      /* RX packets dropped */
    uint32_t tx_dropped;      /* TX packets dropped */
    int8_t   last_rssi;       /* RSSI of last RX frame (dBm) */
    uint32_t channel;         /* Current channel */
};
```

**Example**:
```c
struct sdr_stats stats;
if (ioctl(fd, IOCTL_GET_STATS, &stats) < 0) {
    perror("ioctl IOCTL_GET_STATS");
    return -1;
}

printf("RX packets: %lu\n", stats.rx_packets);
printf("TX packets: %lu\n", stats.tx_packets);
printf("Last RSSI: %d dBm\n", stats.last_rssi);
```

**Returns**: 0 on success, -1 on error

---

## Data Structures

### IEEE 802.11 Frame Structures

#### MAC Header

```c
struct ieee80211_hdr {
    uint16_t frame_control;
    uint16_t duration;
    uint8_t  addr1[6];  /* Destination Address (DA) */
    uint8_t  addr2[6];  /* Source Address (SA) */
    uint8_t  addr3[6];  /* BSSID */
    uint16_t seq_ctrl;
} __attribute__((packed));
```

**Frame Control Field**:
```
Bits 0-1:   Protocol Version (always 0)
Bits 2-3:   Type (00=Mgmt, 01=Ctrl, 10=Data, 11=Extension)
Bits 4-7:   Subtype
Bit  8:     To DS
Bit  9:     From DS
Bit  10:    More Fragments
Bit  11:    Retry
Bit  12:    Power Management
Bit  13:    More Data
Bit  14:    Protected Frame
Bit  15:    Order
```

**Frame Types and Subtypes**:
```c
/* Management (Type = 00) */
#define SUBTYPE_ASSOC_REQ    0x0
#define SUBTYPE_ASSOC_RESP   0x1
#define SUBTYPE_PROBE_REQ    0x4
#define SUBTYPE_PROBE_RESP   0x5
#define SUBTYPE_BEACON       0x8
#define SUBTYPE_DISASSOC     0xA
#define SUBTYPE_AUTH         0xB
#define SUBTYPE_DEAUTH       0xC
#define SUBTYPE_ACTION       0xD

/* Control (Type = 01) */
#define SUBTYPE_RTS          0xB
#define SUBTYPE_CTS          0xC
#define SUBTYPE_ACK          0xD

/* Data (Type = 10) */
#define SUBTYPE_DATA         0x0
#define SUBTYPE_QOS_DATA     0x8
```

#### Beacon Frame

```c
struct beacon_frame {
    uint64_t timestamp;
    uint16_t beacon_interval;  /* In TUs (1 TU = 1024 μs) */
    uint16_t capability_info;
    uint8_t  ies[];            /* Information Elements */
} __attribute__((packed));
```

**Capability Info Bits**:
```c
#define CAP_ESS             0x0001  /* Infrastructure BSS */
#define CAP_IBSS            0x0002  /* IBSS (Ad-hoc) */
#define CAP_PRIVACY         0x0010  /* Encryption enabled */
#define CAP_SHORT_PREAMBLE  0x0020  /* Short preamble */
#define CAP_SHORT_SLOT      0x0400  /* Short slot time */
```

#### Information Element (IE)

```c
struct ieee80211_ie {
    uint8_t id;
    uint8_t len;
    uint8_t data[];
} __attribute__((packed));
```

**Common IE IDs**:
```c
#define IE_SSID                 0
#define IE_SUPPORTED_RATES      1
#define IE_DS_PARAM             3   /* Channel */
#define IE_TIM                  5   /* Traffic Indication Map */
#define IE_ERP                  42  /* Extended Rate PHY */
#define IE_RSN                  48  /* WPA2/WPA3 */
#define IE_EXT_RATES            50
#define IE_HT_CAP               45  /* 802.11n HT capabilities */
#define IE_VENDOR_SPECIFIC      221
```

### Remote ID Structures

See [remote_id_types.h](../include/remote_id_types.h) for complete definitions.

#### Basic ID Message (Type 0)

```c
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;        /* 0x00 */
    uint8_t  id_type;         /* 0=Serial, 1=CAA, 2=UTM, etc. */
    uint8_t  ua_type;         /* 0=None, 1=Aeroplane, 2=Helicopter, 3=Multirotor, etc. */
    uint8_t  uas_id[20];      /* UAS ID (Serial number, registration, etc.) */
    uint8_t  reserved[2];
} remote_id_basic_id_t;
```

#### Location Message (Type 1)

```c
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;        /* 0x01 */
    uint8_t  status;
    uint8_t  direction;       /* 0-360 degrees */
    uint8_t  speed_horiz;     /* Horizontal speed * 4 (m/s) */
    int8_t   speed_vert;      /* Vertical speed * 2 (m/s) */
    int32_t  latitude;        /* Degrees * 1e7 */
    int32_t  longitude;       /* Degrees * 1e7 */
    int16_t  altitude_baro;   /* Meters * 2 */
    int16_t  altitude_geo;    /* Meters * 2 */
    uint16_t height_agl;      /* Meters */
    uint8_t  horiz_accuracy;  /* Encoded */
    uint8_t  vert_accuracy;   /* Encoded */
    uint8_t  baro_accuracy;   /* Encoded */
    uint8_t  speed_accuracy;  /* Encoded */
    uint16_t timestamp;       /* Tenths of seconds since hour */
    uint8_t  reserved;
} remote_id_location_t;
```

---

## AXI Register Map

The enhanced_xpu FPGA module is mapped to AXI MMIO space.

### Base Address

- **Zynq-7000**: `0x43C00000` (configurable in Vivado)
- **ZynqMP**: `0xA0000000`

### Register Offsets

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | CONTROL | W | Control register |
| 0x04 | STATUS | R | Status register |
| 0x08 | FILTER_CONFIG | W | Filter configuration |
| 0x0C | FILTER_ADDR_LO | W | Filter MAC address (low 32 bits) |
| 0x10 | FILTER_ADDR_HI | W | Filter MAC address (high 16 bits) |
| 0x14 | PKT_COUNT | R | Packet count |
| 0x18 | ERROR_COUNT | R | Error count |
| 0x1C | RSSI | R | Last RSSI value |
| 0x20 | INJECT_CTRL | W | Frame injection control |
| 0x24 | INJECT_ADDR | W | Injection buffer address |
| 0x28 | INJECT_LEN | W | Injection frame length |

### Control Register (0x00)

```
Bits 0:     Enable (1=enabled, 0=disabled)
Bit  1:     Monitor Mode (1=monitor, 0=normal)
Bit  2:     Promiscuous Mode
Bit  3:     FCS Check Enable
Bits 4-7:   Reserved
Bits 8-15:  TX Power (dBm)
Bits 16-23: Data Rate (Mbps)
Bits 24-31: Reserved
```

### Status Register (0x04)

```
Bit  0:     RX Active
Bit  1:     TX Active
Bit  2:     RX Error
Bit  3:     TX Error
Bits 4-7:   Reserved
Bits 8-15:  Current Channel
Bits 16-31: Reserved
```

### Filter Configuration Register (0x08)

```
Bit  0:     Capture Beacons
Bit  1:     Capture Probe Requests
Bit  2:     Capture Probe Responses
Bit  3:     Capture Data Frames
Bit  4:     Capture NAN Frames
Bit  5:     Capture Auth Frames
Bit  6:     Capture Deauth Frames
Bit  7:     Capture Assoc Frames
Bit  8:     Capture Control Frames
Bit  9:     Capture FCS Failures
Bits 10-14: Reserved
Bit  15:    Promiscuous Mode
Bits 16-31: Reserved
```

### Direct Register Access (Advanced)

```c
#include <sys/mman.h>

#define AXI_BASE_ADDR   0x43C00000
#define AXI_SIZE        0x10000

int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
volatile uint32_t *axi_regs = mmap(NULL, AXI_SIZE,
                                   PROT_READ | PROT_WRITE,
                                   MAP_SHARED, mem_fd, AXI_BASE_ADDR);

// Enable monitor mode via direct register access
axi_regs[0] = 0x00000002;  /* Control: Monitor Mode = 1 */

// Set filter
axi_regs[2] = 0x00000011;  /* Filter: Beacons + NAN */

munmap((void *)axi_regs, AXI_SIZE);
close(mem_fd);
```

**Note**: Direct register access bypasses the kernel driver and should only be used for debugging or when the driver is not loaded.

---

## Helper Functions

### Accuracy Encoding

ASTM F3411 uses logarithmic encoding for accuracy values.

```c
/**
 * @brief Encode accuracy from meters to code (0-15)
 * @param accuracy_meters Accuracy in meters
 * @return Encoded value
 */
uint8_t remote_id_encode_accuracy(float accuracy_meters) {
    if (accuracy_meters < 0.0) return 0;  /* Unknown */
    if (accuracy_meters <= 3.0) return 1;
    if (accuracy_meters <= 10.0) return 2;
    if (accuracy_meters <= 30.0) return 3;
    if (accuracy_meters <= 100.0) return 4;
    if (accuracy_meters <= 300.0) return 5;
    if (accuracy_meters <= 1000.0) return 6;
    if (accuracy_meters <= 3000.0) return 7;
    if (accuracy_meters <= 10000.0) return 8;
    return 9;  /* >= 10 km */
}

/**
 * @brief Decode accuracy from code to meters
 * @param encoded Encoded value (0-15)
 * @return Accuracy in meters
 */
float remote_id_decode_accuracy(uint8_t encoded) {
    static const float accuracy_table[] = {
        0.0,    /* Unknown */
        3.0,    /* < 3m */
        10.0,   /* < 10m */
        30.0,   /* < 30m */
        100.0,  /* < 100m */
        300.0,  /* < 300m */
        1000.0, /* < 1km */
        3000.0, /* < 3km */
        10000.0,/* < 10km */
        30000.0 /* >= 10km */
    };

    if (encoded >= 10) encoded = 9;
    return accuracy_table[encoded];
}
```

### Frame Building Helpers

```c
/**
 * @brief Build SSID Information Element
 * @param buf Output buffer
 * @param ssid SSID string
 * @return Number of bytes written
 */
size_t build_ssid_ie(uint8_t *buf, const char *ssid) {
    size_t ssid_len = strlen(ssid);
    if (ssid_len > 32) ssid_len = 32;

    buf[0] = 0;  /* IE ID: SSID */
    buf[1] = ssid_len;
    memcpy(&buf[2], ssid, ssid_len);

    return 2 + ssid_len;
}

/**
 * @brief Calculate FCS (Frame Check Sequence / CRC32)
 * @param data Frame data
 * @param len Frame length
 * @return FCS value
 */
uint32_t calculate_fcs(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFF;
    size_t i, j;

    for (i = 0; i < len; i++) {
        crc ^= data[i];
        for (j = 0; j < 8; j++) {
            if (crc & 1)
                crc = (crc >> 1) ^ 0xEDB88320;
            else
                crc = crc >> 1;
        }
    }

    return ~crc;
}
```

---

## Code Examples

### Example 1: Simple Monitor Mode

```c
#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define IOCTL_SET_MONITOR_MODE  _IOW('o', 10, uint32_t)
#define IOCTL_SET_CHANNEL       _IOW('o', 11, uint32_t)
#define IOCTL_SET_FILTER        _IOW('o', 12, uint32_t)

#define FILTER_BEACON           0x01

int main() {
    int fd;
    uint8_t buffer[4096];
    ssize_t nread;

    /* Open device */
    fd = open("/dev/sdr0", O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    /* Enable monitor mode */
    uint32_t enable = 1;
    ioctl(fd, IOCTL_SET_MONITOR_MODE, enable);

    /* Set channel 6 */
    uint32_t channel = 6;
    ioctl(fd, IOCTL_SET_CHANNEL, channel);

    /* Capture beacons only */
    uint32_t filter = FILTER_BEACON;
    ioctl(fd, IOCTL_SET_FILTER, filter);

    printf("Monitoring beacons on channel 6...\n");

    /* Receive loop */
    while (1) {
        nread = read(fd, buffer, sizeof(buffer));
        if (nread > 0) {
            printf("Received frame: %zd bytes\n", nread);
        }
    }

    close(fd);
    return 0;
}
```

### Example 2: Frame Injection

```c
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>

#define IOCTL_SET_CHANNEL      _IOW('o', 11, uint32_t)
#define IOCTL_INJECT_FRAME     _IOW('o', 20, void*)

struct inject_params {
    uint8_t  *frame;
    uint32_t  length;
    uint32_t  rate;
    uint32_t  retries;
    uint32_t  flags;
};

int main() {
    int fd;
    uint8_t frame[256];
    int frame_len = 0;

    /* Build 802.11 beacon frame */
    /* Frame Control: Beacon (0x0080) */
    frame[0] = 0x80;
    frame[1] = 0x00;

    /* Duration */
    frame[2] = 0x00;
    frame[3] = 0x00;

    /* DA: Broadcast */
    memset(&frame[4], 0xFF, 6);

    /* SA: 02:00:00:00:00:01 */
    frame[10] = 0x02;
    frame[11] = 0x00;
    frame[12] = 0x00;
    frame[13] = 0x00;
    frame[14] = 0x00;
    frame[15] = 0x01;

    /* BSSID: same as SA */
    memcpy(&frame[16], &frame[10], 6);

    /* Sequence Control */
    frame[22] = 0x00;
    frame[23] = 0x00;

    frame_len = 24;  /* MAC header */

    /* Beacon body (timestamp, interval, capability) */
    memset(&frame[frame_len], 0, 12);
    frame_len += 12;

    /* SSID IE */
    frame[frame_len++] = 0;    /* IE ID */
    frame[frame_len++] = 4;    /* Length */
    memcpy(&frame[frame_len], "Test", 4);
    frame_len += 4;

    /* Open device */
    fd = open("/dev/sdr0", O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    /* Set channel */
    uint32_t channel = 6;
    ioctl(fd, IOCTL_SET_CHANNEL, channel);

    /* Inject frame */
    struct inject_params params = {
        .frame = frame,
        .length = frame_len,
        .rate = 6,
        .retries = 0,
        .flags = 0x0001  /* NO_ACK */
    };

    if (ioctl(fd, IOCTL_INJECT_FRAME, &params) < 0) {
        perror("ioctl IOCTL_INJECT_FRAME");
        close(fd);
        return 1;
    }

    printf("Beacon injected successfully!\n");

    close(fd);
    return 0;
}
```

### Example 3: Get Statistics

```c
#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>

#define IOCTL_GET_STATS  _IOR('o', 13, struct sdr_stats)

struct sdr_stats {
    uint64_t rx_packets;
    uint64_t tx_packets;
    uint64_t rx_bytes;
    uint64_t tx_bytes;
    uint32_t rx_errors;
    uint32_t tx_errors;
    uint32_t rx_dropped;
    uint32_t tx_dropped;
    int8_t   last_rssi;
    uint32_t channel;
};

int main() {
    int fd;
    struct sdr_stats stats;

    fd = open("/dev/sdr0", O_RDWR);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    if (ioctl(fd, IOCTL_GET_STATS, &stats) < 0) {
        perror("ioctl");
        close(fd);
        return 1;
    }

    printf("Statistics:\n");
    printf("  RX packets: %lu\n", stats.rx_packets);
    printf("  TX packets: %lu\n", stats.tx_packets);
    printf("  RX bytes:   %lu\n", stats.rx_bytes);
    printf("  TX bytes:   %lu\n", stats.tx_bytes);
    printf("  RX errors:  %u\n", stats.rx_errors);
    printf("  TX errors:  %u\n", stats.tx_errors);
    printf("  Last RSSI:  %d dBm\n", stats.last_rssi);
    printf("  Channel:    %u\n", stats.channel);

    close(fd);
    return 0;
}
```

---

## See Also

- [User Guide](USER_GUIDE.md) - Complete user documentation
- [Remote ID Guide](REMOTE_ID_GUIDE.md) - Remote ID implementation details
- [Quick Start](../QUICKSTART.md) - 5-minute getting started guide

---

**Copyright © 2025 OpenWiFi Project**
**License: AGPL-3.0-only**
