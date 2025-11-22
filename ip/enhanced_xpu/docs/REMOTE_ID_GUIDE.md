# Drone Remote ID Implementation Guide

**OpenWiFi Project**
**ASTM F3411-22 Compliant**
**Last Updated: 2025-11-22**

## Table of Contents

1. [Introduction](#introduction)
2. [ASTM F3411 Overview](#astm-f3411-overview)
3. [Message Format Details](#message-format-details)
4. [WiFi NAN Transport](#wifi-nan-transport)
5. [Transmitter Implementation](#transmitter-implementation)
6. [Receiver Implementation](#receiver-implementation)
7. [Compliance Considerations](#compliance-considerations)
8. [Flight Controller Integration](#flight-controller-integration)
9. [Testing and Validation](#testing-and-validation)
10. [Regulatory Information](#regulatory-information)

---

## Introduction

Drone Remote ID (or Remote Identification) is a system that broadcasts identification and telemetry information from unmanned aircraft (drones) to enable authorities and the public to identify drones in flight.

### Why Remote ID?

- **Regulatory Compliance**: Required by FAA (USA), EASA (Europe), and other aviation authorities
- **Safety**: Enables identification of unauthorized or unsafe drone operations
- **Accountability**: Links drones to operators for enforcement
- **Airspace Integration**: Foundation for UTM (UAS Traffic Management)

### Standards

This implementation follows:

- **ASTM F3411-22**: Standard Specification for Remote ID and Tracking
- **ASD-STAN prEN 4709-002**: European standard (harmonized with ASTM)
- **IEEE 802.11**: WiFi Aware (NAN) transport mechanism

### Regulatory Status

| Region | Regulation | Effective Date | Status |
|--------|------------|----------------|--------|
| USA (FAA) | 14 CFR Part 89 | Sept 16, 2023 | Mandatory |
| Europe (EASA) | Commission Regulation 2019/945 | Dec 31, 2023 | Mandatory |
| Canada | RPAS Regulations | TBD | Proposed |
| Australia | CASA Part 101 | TBD | Under review |

---

## ASTM F3411 Overview

### Architecture

```
┌────────────────────────────────────────────────────────┐
│                    UAS (Drone)                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │  Flight  │  │   GPS    │  │  Remote ID Module    │ │
│  │Controller│──│ Receiver │──│  (enhanced_xpu)      │ │
│  └──────────┘  └──────────┘  └──────────────────────┘ │
│                                        │               │
│                                        ▼               │
│                              ┌──────────────────┐     │
│                              │  WiFi NAN TX     │     │
│                              │  (2.4 GHz)       │     │
│                              └──────────────────┘     │
└────────────────────────────────────┬───────────────────┘
                                     │ Broadcast
                                     │ @ 1 Hz
                                     ▼
          ┌──────────────────────────────────────────┐
          │         Observation Area                  │
          │  ┌─────────────┐  ┌────────────────────┐ │
          │  │  Observer   │  │  Law Enforcement   │ │
          │  │  (Phone)    │  │  (Receiver)        │ │
          │  └─────────────┘  └────────────────────┘ │
          └──────────────────────────────────────────┘
```

### Message Types

ASTM F3411 defines 6 message types (all 25 bytes):

| Type | Name | Required | Purpose |
|------|------|----------|---------|
| 0 | Basic ID | Yes | UAS identification |
| 1 | Location/Vector | Yes | Position, velocity, altitude |
| 2 | Authentication | No | Signature/certificate |
| 3 | Self-ID | No | Operator description |
| 4 | System | No | Operator location, multiple UAS |
| 5 | Operator ID | No | Operator identifier |

### Transmission Requirements

- **Rate**: At least 1 Hz (once per second)
- **Messages**: Must transmit Basic ID (Type 0) and Location (Type 1)
- **Range**: Minimum 400 meters line-of-sight
- **Latency**: Location data must be < 1 second old

---

## Message Format Details

All Remote ID messages are exactly **25 bytes**.

### Type 0: Basic ID

Contains static identification information.

```c
struct remote_id_basic_id {
    uint8_t  msg_type;        // 0x00
    uint8_t  id_type;         // ID Type (see table below)
    uint8_t  ua_type;         // UA Type (see table below)
    uint8_t  uas_id[20];      // UAS ID (Serial number, etc.)
    uint8_t  reserved[2];     // Must be 0
} __attribute__((packed));
```

**ID Types**:
| Value | Type | Description | Example |
|-------|------|-------------|---------|
| 0 | None | No ID (not allowed for compliance) | - |
| 1 | Serial Number | Manufacturer serial number | "DJIM3E12345678" |
| 2 | CAA Registration ID | Civil Aviation Authority ID | "FA12345678" |
| 3 | UTM Assigned UUID | UUID from UTM system | UUID string |
| 4 | Specific Session ID | Session-specific ID | - |

**UA Types**:
| Value | Type | Description |
|-------|------|-------------|
| 0 | None/Other | Unspecified |
| 1 | Aeroplane | Fixed-wing |
| 2 | Helicopter | Rotary-wing |
| 3 | Gyroplane | Autogyro |
| 4 | Hybrid Lift | VTOL |
| 5 | Ornithopter | Flapping wing |
| 6 | Glider | Unpowered fixed-wing |
| 7 | Kite | Tethered |
| 8 | Free Balloon | Lighter-than-air |
| 9 | Captive Balloon | Tethered balloon |
| 10 | Airship | Powered lighter-than-air |
| 11 | Free Fall/Parachute | Descending |
| 12 | Rocket | Ascending |
| 13 | Tethered Powered Aircraft | Tethered multirotor |
| 14 | Ground Obstacle | Non-flying |
| 15 | Other | Other |

**Example**:
```c
remote_id_basic_id_t msg = {
    .msg_type = 0,
    .id_type = 1,  // Serial Number
    .ua_type = 3,  // Multirotor (Quadcopter)
    .uas_id = "MYCO12345678",  // Padded with zeros
    .reserved = {0, 0}
};
```

---

### Type 1: Location/Vector

Contains current position, altitude, and velocity.

```c
struct remote_id_location {
    uint8_t  msg_type;          // 0x01
    uint8_t  status;            // Operational status
    uint8_t  direction;         // Track direction (0-360°, 1° res)
    uint8_t  speed_horiz;       // Horiz speed (0.25 m/s res)
    int8_t   speed_vert;        // Vert speed (0.5 m/s res)
    int32_t  latitude;          // Latitude (1e-7° res)
    int32_t  longitude;         // Longitude (1e-7° res)
    int16_t  altitude_baro;     // Baro altitude (0.5 m res)
    int16_t  altitude_geo;      // Geodetic altitude (0.5 m res)
    uint16_t height_agl;        // Height AGL (1 m res)
    uint8_t  horiz_accuracy;    // Horizontal accuracy (encoded)
    uint8_t  vert_accuracy;     // Vertical accuracy (encoded)
    uint8_t  baro_accuracy;     // Barometric accuracy (encoded)
    uint8_t  speed_accuracy;    // Speed accuracy (encoded)
    uint16_t timestamp;         // Timestamp (0.1 s res since hour)
    uint8_t  reserved;          // Must be 0
} __attribute__((packed));
```

**Status Field** (bits 0-7):
```
Bits 0-3: Operational Status
  0 = Undeclared
  1 = Ground
  2 = Airborne
  3-15 = Reserved

Bits 4-5: Height Type
  0 = Above Takeoff
  1 = AGL (Above Ground Level)

Bits 6-7: EW Direction Segment (European, optional)
```

**Direction**: Track direction in degrees (0 = North, 90 = East, etc.)

**Speed Horizontal**: Horizontal ground speed in 0.25 m/s increments
- Value 0 = 0 m/s
- Value 100 = 25 m/s
- Value 255 = Invalid

**Speed Vertical**: Vertical speed in 0.5 m/s increments (-63 to +62 m/s)
- Value -126 = -63 m/s (descending)
- Value 0 = 0 m/s (level)
- Value 124 = +62 m/s (ascending)
- Value 127 = Invalid

**Latitude/Longitude**: WGS-84 coordinates in 1e-7 degree increments
- Latitude range: -90° to +90°
- Longitude range: -180° to +180°
- Example: 37.7749000° → 377749000 (as int32)

**Altitude Barometric**: Pressure altitude in 0.5 m increments
- Range: -1000 m to +31767.5 m
- Referenced to standard pressure (1013.25 hPa)

**Altitude Geodetic**: WGS-84 ellipsoid height in 0.5 m increments
- Range: -1000 m to +31767.5 m
- GPS altitude (MSL approximation)

**Height AGL**: Height above ground level in 1 m increments
- Range: 0 to 1000 m

**Accuracy Encoding** (logarithmic scale):
| Code | Horizontal | Vertical |
|------|-----------|----------|
| 0 | Unknown | Unknown |
| 1 | < 3 m | < 1 m |
| 2 | < 10 m | < 3 m |
| 3 | < 30 m | < 10 m |
| 4 | < 100 m | < 25 m |
| 5 | < 300 m | < 45 m |
| 6 | < 1 km | < 75 m |
| 7 | < 3 km | < 100 m |
| 8 | < 10 km | < 150 m |
| 9 | >= 10 km | >= 150 m |
| 10-14 | Reserved | Reserved |
| 15 | Invalid | Invalid |

**Timestamp**: Tenths of seconds since the hour (0-35999)
- Example: 12:34:56.7 → (34*60 + 56) * 10 + 7 = 20967

**Example**:
```c
remote_id_location_t msg = {
    .msg_type = 1,
    .status = 0x02,  // Airborne
    .direction = 123,  // 123° (ESE)
    .speed_horiz = 20,  // 5 m/s (20 * 0.25)
    .speed_vert = 4,  // 2 m/s ascending (4 * 0.5)
    .latitude = 377749000,  // 37.7749°
    .longitude = -1224194000,  // -122.4194°
    .altitude_baro = 100,  // 50 m (100 * 0.5)
    .altitude_geo = 100,
    .height_agl = 50,  // 50 m
    .horiz_accuracy = 2,  // < 10 m
    .vert_accuracy = 2,  // < 3 m
    .baro_accuracy = 1,  // < 1 m
    .speed_accuracy = 1,  // < 1 m/s
    .timestamp = 20967,  // 34:56.7
    .reserved = 0
};
```

---

### Type 4: System

Contains operator location and multi-UAS information.

```c
struct remote_id_system {
    uint8_t  msg_type;                // 0x04
    uint8_t  operator_location_type;  // 0=Takeoff, 1=Live, 2=Fixed
    uint8_t  classification_type;     // EU classification
    int32_t  operator_latitude;       // Operator latitude (1e-7° res)
    int32_t  operator_longitude;      // Operator longitude (1e-7° res)
    uint16_t area_count;              // Number of aircraft in group
    uint16_t area_radius;             // Area radius (100 m res)
    float    area_ceiling;            // Area ceiling (m)
    float    area_floor;              // Area floor (m)
    uint8_t  category_eu;             // EU UAS category
    uint8_t  class_eu;                // EU UAS class
    float    operator_altitude_geo;   // Operator altitude (m)
    uint16_t timestamp;               // Timestamp (0.1 s res)
} __attribute__((packed));
```

**Operator Location Type**:
- 0 = Takeoff location
- 1 = Live/Dynamic operator location (for moving GCS)
- 2 = Fixed location

This message is optional but recommended if:
- Operating multiple drones from one location
- Using a mobile ground control station
- Required by European regulations

---

### Type 3: Self-ID

Free-text description field (23 bytes).

```c
struct remote_id_self_id {
    uint8_t  msg_type;            // 0x03
    uint8_t  description_type;    // 0=Text, 200+=Specific
    uint8_t  description[23];     // UTF-8 text
} __attribute__((packed));
```

**Example**:
```c
remote_id_self_id_t msg = {
    .msg_type = 3,
    .description_type = 0,
    .description = "Survey Flight ABC123"  // Padded/truncated to 23 bytes
};
```

---

## WiFi NAN Transport

Remote ID uses **WiFi Aware** (also called **NAN** - Neighbor Awareness Networking) as defined in IEEE 802.11.

### Why NAN?

- **Range**: 500+ meters (vs ~100m for Bluetooth)
- **Broadcast**: No pairing or association required
- **Standardized**: IEEE 802.11 compliant
- **Receiver Availability**: Supported on most modern smartphones

### NAN Frame Structure

```
┌────────────────────────────────────────────────┐
│  IEEE 802.11 MAC Header (24 bytes)             │
├────────────────────────────────────────────────┤
│  Action Frame Header (8 bytes)                 │
│    - Category: 0x04 (Public) or 0x7F (Vendor)  │
│    - OUI: 0x506F9A (WiFi Alliance)             │
│    - OUI Type: 0x13 (NAN)                      │
├────────────────────────────────────────────────┤
│  NAN Attributes (TLV format)                   │
│    ┌──────────────────────────────────────┐   │
│    │ Service Descriptor Attribute         │   │
│    │   - Attr ID: 0x03                    │   │
│    │   - Length: varies                   │   │
│    │   - Service ID: 0x886919_9D9209      │   │
│    │     (SHA-256 hash of                 │   │
│    │      "org.astm.f3411.remoteid")      │   │
│    │   - Service Info: [25 byte msg]      │   │
│    └──────────────────────────────────────┘   │
└────────────────────────────────────────────────┘
```

### NAN Service ID

The Remote ID service is identified by a 6-byte hash:

```
Service Name: "org.astm.f3411.remoteid"
SHA-256 Hash: 88 69 19 9D 92 09 6D 0B ... (32 bytes)
Service ID: First 6 bytes = 88 69 19 9D 92 09
```

This is defined in the ASTM standard and must not be changed.

### Frame Details

**MAC Header**:
- Frame Control: 0x00D0 (Action frame, no ACK)
- DA: FF:FF:FF:FF:FF:FF (Broadcast)
- SA: Drone's MAC address (can be random locally-administered)
- BSSID: 50:6F:9A:01:00:00 (NAN cluster ID)

**NAN Service Descriptor Attribute**:
```c
struct nan_service_descriptor {
    uint8_t  attr_id;                 // 0x03
    uint16_t length;                  // Attribute length (LE)
    uint8_t  service_id[6];           // 0x886919_9D9209
    uint8_t  instance_id;             // Local instance (0x01)
    uint8_t  requestor_instance_id;   // 0x00 (not used)
    uint8_t  service_control;         // 0x00
    uint8_t  binding_bitmap;          // 0x00
    uint8_t  service_info_len;        // 25 (0x19)
    uint8_t  service_info[25];        // Remote ID message
} __attribute__((packed));
```

### Channel

NAN typically operates on **Channel 6** (2.437 GHz) for maximum compatibility.

Alternative channels may be used in specific regions or for testing.

---

## Transmitter Implementation

### Hardware Setup

1. **GPS Module**: Connect NMEA GPS to UART port
2. **WiFi SDR**: ANTSDR or compatible
3. **Antenna**: 2.4 GHz omnidirectional, low gain (2-3 dBi)
4. **Power**: Ensure stable 5V supply

### Software Flow

```
┌────────────────────────────────────────┐
│  Initialize                            │
│  - Open /dev/sdr0                      │
│  - Open GPS port                       │
│  - Set channel 6                       │
└──────────────┬─────────────────────────┘
               │
               ▼
┌────────────────────────────────────────┐
│  Main Loop (1 Hz)                      │
│  ┌──────────────────────────────────┐  │
│  │ 1. Read GPS data (NMEA)          │  │
│  │ 2. Parse GPGGA, GPRMC sentences  │  │
│  │ 3. Extract lat, lon, alt, speed  │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │ 4. Build Basic ID message        │  │
│  │ 5. Encode as NAN frame           │  │
│  │ 6. Inject frame via ioctl        │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │ 7. Wait 100ms                    │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │ 8. Build Location message        │  │
│  │ 9. Encode as NAN frame           │  │
│  │ 10. Inject frame via ioctl       │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │ 11. Sleep until next second      │  │
│  └──────────────────────────────────┘  │
└──────────────┬─────────────────────────┘
               │
               ▼ (repeat)
```

### Code Example

See `examples/remote_id_transmitter.c` for complete implementation.

Key functions:

```c
/* Parse GPS NMEA data */
int read_gps_data(struct gps_data *gps);

/* Create Location message from GPS */
void create_location_message(remote_id_message_t *msg,
                              const struct gps_data *gps);

/* Encode as NAN frame */
int build_nan_remote_id_frame(uint8_t *buf, size_t buflen,
                               const remote_id_message_t *msg);

/* Inject via ioctl */
int transmit_remote_id(const remote_id_message_t *msg);
```

### Transmission Timing

Per ASTM F3411:
- **Minimum rate**: 1 Hz (once per second)
- **Recommended**: Send Basic ID and Location every second
- **Allowed**: Up to 5 Hz for improved reliability

**Implementation**:
```c
while (running) {
    read_gps_data(&gps);

    // Send Basic ID
    create_basic_id_message(&msg, uas_id, ua_type);
    transmit_remote_id(&msg);

    usleep(100000);  // 100ms delay

    // Send Location
    create_location_message(&msg, &gps);
    transmit_remote_id(&msg);

    // Wait until next second
    sleep(1);
}
```

---

## Receiver Implementation

### Hardware Setup

1. **WiFi SDR**: ANTSDR or compatible
2. **Antenna**: 2.4 GHz omnidirectional
3. **Storage**: SD card or USB drive for logging (optional)

### Software Flow

```
┌────────────────────────────────────────┐
│  Initialize                            │
│  - Open /dev/sdr0                      │
│  - Enable monitor mode                 │
│  - Set channel 6                       │
│  - Set filter: NAN frames              │
└──────────────┬─────────────────────────┘
               │
               ▼
┌────────────────────────────────────────┐
│  Receive Loop                          │
│  ┌──────────────────────────────────┐  │
│  │ 1. Read frame from /dev/sdr0     │  │
│  │ 2. Check if NAN Remote ID frame  │  │
│  │ 3. Extract Remote ID message     │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │ 4. Decode message type           │  │
│  │    - Type 0: Update Basic ID     │  │
│  │    - Type 1: Display Location    │  │
│  │    - Type 4: Show Operator loc   │  │
│  └──────────────────────────────────┘  │
│  ┌──────────────────────────────────┐  │
│  │ 5. Update drone tracking DB      │  │
│  │ 6. Log to file (optional)        │  │
│  │ 7. Display on screen             │  │
│  └──────────────────────────────────┘  │
└──────────────┬─────────────────────────┘
               │
               ▼ (repeat)
```

### Code Example

See `examples/remote_id_receiver.c` for complete implementation.

Key functions:

```c
/* Check if frame is NAN Remote ID */
int is_nan_remote_id_frame(const uint8_t *frame, size_t len);

/* Decode message from NAN frame */
int decode_remote_id_from_nan(const uint8_t *frame, size_t len,
                                remote_id_message_t *msg);

/* Process message by type */
void process_basic_id(const remote_id_basic_id_t *msg);
void process_location(const remote_id_location_t *msg);
```

### Multi-Drone Tracking

The receiver can track multiple drones simultaneously using a database:

```c
struct drone_info {
    char uas_id[21];
    double latitude, longitude, altitude;
    time_t last_seen;
    uint32_t message_count;
};

struct drone_info drones[MAX_DRONES];
```

---

## Compliance Considerations

### FAA Requirements (USA)

Per 14 CFR Part 89:

✅ **Broadcast Required Fields**:
- UAS ID (serial number or registration)
- Control station location (optional for < 250g)
- UAS latitude, longitude, altitude
- UAS velocity
- Emergency status
- Time mark (timestamp)

✅ **Transmission Rate**: At least 1 Hz

✅ **Range**: Minimum 400m line-of-sight

✅ **Latency**: Position data < 1 second old

### EASA Requirements (Europe)

Commission Implementing Regulation (EU) 2019/947:

✅ **Broadcast Required**:
- UAS operator registration number
- Timestamp
- UAS position (lat/lon/alt)
- Height above surface
- Horizontal and vertical speed
- Position of pilot/take-off point

✅ **Update Rate**: At least 1 Hz

✅ **Range**: Not specified (follow ASTM)

### Exemptions

Both FAA and EASA provide exemptions for:
- Indoor flights
- Flights within FAA-Recognized Identification Areas (FRIAs)
- Certain amateur/recreational uses (varies by region)

### Certification

For commercial compliance, Remote ID modules should be:
- Tested per ASTM F3411 test procedures
- Declared compliant by manufacturer (DoC)
- Listed with authority (FAA/EASA)

**Note**: This OpenWiFi implementation is intended for development, testing, and research. Commercial deployment may require additional certification.

---

## Flight Controller Integration

### ArduPilot

ArduPilot can output telemetry for Remote ID:

```
# Configure MAVLink output (Serial 1)
SERIAL1_PROTOCOL = 1  # MAVLink 1
SERIAL1_BAUD = 57600

# GPS parameters
GPS_TYPE = 1  # Auto
```

Read MAVLink messages in Remote ID transmitter:

```c
/* Read MAVLink GPS_RAW_INT message */
mavlink_message_t msg;
mavlink_gps_raw_int_t gps;

if (mavlink_parse_char(MAVLINK_COMM_0, byte, &msg, &status)) {
    if (msg.msgid == MAVLINK_MSG_ID_GPS_RAW_INT) {
        mavlink_msg_gps_raw_int_decode(&msg, &gps);

        /* Convert to Remote ID format */
        rid_loc.latitude = gps.lat;  /* Already 1e-7 deg */
        rid_loc.longitude = gps.lon;
        rid_loc.altitude_geo = gps.alt / 1000 / 0.5;  /* mm to 0.5m */
    }
}
```

### PX4

Similar to ArduPilot, configure MAVLink telemetry output.

### Betaflight (for FPV racers)

Betaflight doesn't have integrated GPS support. Options:
1. Use external GPS module connected to OpenWiFi board
2. Use smartphone app to relay phone GPS (for proximity pilot)

### DJI Integration

DJI drones have proprietary Remote ID. This implementation is for custom/DIY drones.

---

## Testing and Validation

### Ground Testing

**Equipment Needed**:
- Transmitter: OpenWiFi board with GPS
- Receiver: Smartphone with Remote ID app or OpenWiFi receiver
- GPS simulator (optional)

**Test Procedure**:
1. Power on transmitter with GPS lock
2. Verify beacon transmission (use spectrum analyzer or WiFi scanner)
3. Run receiver and verify messages appear
4. Check update rate (should be 1 Hz)
5. Verify accuracy of GPS data
6. Test range (walk away until signal lost, should be > 400m)

### Range Test

```bash
# Terminal 1: Transmitter
sudo ./remote_id_transmitter -i "TEST001" -c 6 -g /dev/ttyUSB0

# Terminal 2: Receiver (at various distances)
sudo ./remote_id_receiver -c 6 -l range_test.log -v

# Analyze log for RSSI vs distance
```

**Expected Range**:
- Open field, line-of-sight: 500-1000m
- Urban environment: 200-400m
- Indoor: 50-100m

### Smartphone Apps

**Android**:
- **OpenDroneID**: Open-source Remote ID receiver
- **DroneScanner**: Commercial app

**iOS**:
- Limited support (iOS restricts background WiFi scanning)

### Compliance Testing

Per ASTM F3411, test:
1. ✅ All required message fields present
2. ✅ Update rate ≥ 1 Hz
3. ✅ Range ≥ 400m
4. ✅ Latency < 1 second
5. ✅ Message format correctness

---

## Regulatory Information

### United States (FAA)

**Regulation**: 14 CFR Part 89 (Remote Identification of Unmanned Aircraft)

**Key Points**:
- Effective September 16, 2023
- Applies to all UAS operated under Part 107 or 44809
- Three compliance methods:
  1. Standard Remote ID (broadcasts from drone)
  2. Broadcast module (add-on device)
  3. FAA-Recognized Identification Area (FRIA) exemption

**Links**:
- [14 CFR Part 89](https://www.ecfr.gov/current/title-14/chapter-I/subchapter-F/part-89)
- [FAA Remote ID](https://www.faa.gov/uas/getting_started/remote_id)

### European Union (EASA)

**Regulation**: Commission Implementing Regulation (EU) 2019/947

**Key Points**:
- Effective December 31, 2023 (with transition period)
- Applies to "open" and "specific" categories
- Similar to FAA requirements with some differences (operator ID, EU classification)

**Links**:
- [EASA UAS Regulations](https://www.easa.europa.eu/domains/civil-drones)

### Other Regions

- **Canada**: Transport Canada is developing Remote ID requirements
- **Australia**: CASA reviewing regulations
- **UK**: CAA aligning with EASA post-Brexit

### Frequency Regulations

**2.4 GHz ISM Band**:
- Generally unlicensed worldwide
- Subject to power limits (typically 100 mW - 1 W EIRP)
- Must not cause harmful interference

**Check Local Regulations**:
- FCC Part 15 (USA)
- ETSI EN 300 328 (Europe)
- Local spectrum authority

---

## Additional Resources

### Standards Documents

- [ASTM F3411-22](https://www.astm.org/f3411-22.html) - Remote ID Standard
- [ASD-STAN prEN 4709-002](https://www.asd-stan.org/) - European Standard
- [IEEE 802.11](https://standards.ieee.org/standard/802_11-2020.html) - WiFi Standard

### Open-Source Projects

- [OpenDroneID](https://github.com/opendroneid) - Open-source Remote ID implementation
- [OpenWiFi](https://github.com/open-sdr/openwifi) - Main OpenWiFi project

### Developer Tools

- **Wireshark**: Capture and analyze NAN frames
- **SDR Console**: Spectrum analyzer for 2.4 GHz
- **GPS Simulator**: Test without real GPS (e.g., GPSd fake mode)

---

**Copyright © 2025 OpenWiFi Project**
**License: AGPL-3.0-only**

**Disclaimer**: This document is for informational purposes. Users are responsible for compliance with local regulations. The OpenWiFi Project provides no warranty for regulatory compliance.
