/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file remote_id_types.h
 * @brief ASTM F3411 / ASD-STAN prEN 4709-002 Remote ID Data Structures
 *
 * This header defines the data structures for drone Remote ID according to:
 * - ASTM F3411-22: Standard Specification for Remote ID and Tracking
 * - ASD-STAN prEN 4709-002: European UAS Remote Identification
 * - WiFi Aware/NAN (IEEE 802.11): Transport mechanism
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#ifndef _REMOTE_ID_TYPES_H_
#define _REMOTE_ID_TYPES_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ========================================================================
 * WiFi Aware / NAN Constants
 * ======================================================================== */

/** WiFi Alliance OUI */
#define WFA_OUI                     0x506F9A

/** NAN OUI Type */
#define NAN_OUI_TYPE                0x13

/** NAN Action Frame Category */
#define NAN_ACTION_CATEGORY         0x04  /* Public Action */
#define NAN_VENDOR_CATEGORY         0x7F  /* Vendor Specific */

/** Remote ID Service ID (SHA-256 hash of "org.astm.f3411.remoteid") */
#define REMOTE_ID_SERVICE_ID        { 0x88, 0x69, 0x19, 0x9D, 0x92, 0x09 }

/* ========================================================================
 * ASTM F3411 Message Types
 * ======================================================================== */

typedef enum {
    REMOTE_ID_BASIC_ID = 0,          /**< Basic ID (static info) */
    REMOTE_ID_LOCATION = 1,          /**< Location/Vector Message */
    REMOTE_ID_AUTH = 2,              /**< Authentication Message */
    REMOTE_ID_SELF_ID = 3,           /**< Self-ID Message */
    REMOTE_ID_SYSTEM = 4,            /**< System Message */
    REMOTE_ID_OPERATOR_ID = 5,       /**< Operator ID */
    REMOTE_ID_MESSAGE_PACK = 0xF     /**< Message Pack */
} remote_id_msg_type_t;

/* ========================================================================
 * ASTM F3411 Message Structures (All 25 bytes)
 * ======================================================================== */

/**
 * @brief Basic ID Message (Type 0)
 * Contains static identification information about the UA.
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x00 */
    uint8_t  id_type;                /**< ID Type: 0=Serial, 1=CAA, 2=UTM, 3=Specific, 4=UUID */
    uint8_t  ua_type;                /**< UA Type: 0=None, 1=Aero, 2=Helicopter, etc. */
    uint8_t  uas_id[20];             /**< UAS ID (Serial number, registration, etc.) */
    uint8_t  reserved[2];            /**< Reserved for future use */
} remote_id_basic_id_t;

/**
 * @brief Location/Vector Message (Type 1)
 * Contains current position, altitude, velocity, and accuracy.
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x01 */
    uint8_t  status;                 /**< Operational Status: bits 0-3=status, 4-5=height type, 6-7=EU category */
    uint8_t  direction;              /**< Track direction (0-360 deg, 1 deg resolution, 0=North) */
    uint8_t  speed_horiz;            /**< Horizontal speed (0-254.25 m/s, 0.25 m/s resolution) */
    int8_t   speed_vert;             /**< Vertical speed (-63 to +62 m/s, 0.5 m/s resolution) */
    int32_t  latitude;               /**< Latitude (±90 deg, 1e-7 deg resolution, little-endian) */
    int32_t  longitude;              /**< Longitude (±180 deg, 1e-7 deg resolution, little-endian) */
    int16_t  altitude_baro;          /**< Barometric altitude (-1000 to +31767.5 m, 0.5 m resolution) */
    int16_t  altitude_geo;           /**< Geodetic altitude (WGS84, -1000 to +31767.5 m, 0.5 m resolution) */
    uint16_t height_agl;             /**< Height above ground level (0-1000 m, 1 m resolution) */
    uint8_t  horiz_accuracy;         /**< Horizontal accuracy (encoded) */
    uint8_t  vert_accuracy;          /**< Vertical accuracy (encoded) */
    uint8_t  baro_accuracy;          /**< Barometric accuracy (encoded) */
    uint8_t  speed_accuracy;         /**< Speed accuracy (encoded) */
    uint16_t timestamp;              /**< Timestamp (seconds since hour, 0.1 s resolution) */
    uint8_t  reserved;               /**< Reserved */
} remote_id_location_t;

/**
 * @brief Authentication Message (Type 2)
 * Contains authentication data (signature, etc.)
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x02 */
    uint8_t  auth_type;              /**< Auth Type: 0=None, 1-9=Reserved, 10+=Specific */
    uint8_t  auth_page;              /**< Page number (0-15 for multi-page auth data) */
    uint8_t  last_page_index;        /**< Last page index */
    uint8_t  length;                 /**< Length of auth data in this message */
    uint32_t timestamp;              /**< Unix timestamp (seconds since epoch) */
    uint8_t  auth_data[17];          /**< Authentication data payload */
} remote_id_auth_t;

/**
 * @brief Self-ID Message (Type 3)
 * Contains operator description text.
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x03 */
    uint8_t  description_type;       /**< 0=Text, 1-199=Reserved, 200+=Specific */
    uint8_t  description[23];        /**< Free-form UTF-8 text description */
} remote_id_self_id_t;

/**
 * @brief System Message (Type 4)
 * Contains operator location and system information.
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x04 */
    uint8_t  operator_location_type; /**< 0=Takeoff, 1=Live/Dynamic, 2=Fixed */
    uint8_t  classification_type;    /**< EU classification */
    int32_t  operator_latitude;      /**< Operator latitude (±90 deg, 1e-7 deg resolution) */
    int32_t  operator_longitude;     /**< Operator longitude (±180 deg, 1e-7 deg resolution) */
    uint16_t area_count;             /**< Area count (aircraft group size) */
    uint16_t area_radius;            /**< Area radius (0-25500 m, 100 m resolution) */
    float    area_ceiling;           /**< Area ceiling altitude (m) */
    float    area_floor;             /**< Area floor altitude (m) */
    uint8_t  category_eu;            /**< EU UAS category */
    uint8_t  class_eu;               /**< EU UAS class */
    float    operator_altitude_geo;  /**< Operator geodetic altitude (m) */
    uint16_t timestamp;              /**< Timestamp (seconds since hour, 0.1 s resolution) */
} remote_id_system_t;

/**
 * @brief Operator ID Message (Type 5)
 * Contains operator ID (reserved for future use).
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x05 */
    uint8_t  operator_id_type;       /**< Operator ID type */
    uint8_t  operator_id[20];        /**< Operator ID string */
    uint8_t  reserved[3];            /**< Reserved */
} remote_id_operator_id_t;

/**
 * @brief Message Pack (Type 0xF)
 * Contains multiple messages packed together.
 */
typedef struct __attribute__((packed)) {
    uint8_t  msg_type;               /**< 0x0F */
    uint8_t  msg_size;               /**< Size of each message (typically 25) */
    uint8_t  msg_count;              /**< Number of messages (1-9) */
    uint8_t  messages[22];           /**< Packed messages (variable length) */
} remote_id_message_pack_t;

/**
 * @brief Union of all Remote ID message types
 */
typedef union {
    uint8_t                  msg_type;
    remote_id_basic_id_t     basic_id;
    remote_id_location_t     location;
    remote_id_auth_t         auth;
    remote_id_self_id_t      self_id;
    remote_id_system_t       system;
    remote_id_operator_id_t  operator_id;
    remote_id_message_pack_t message_pack;
    uint8_t                  raw[25];  /**< Raw 25-byte message */
} remote_id_message_t;

/* ========================================================================
 * WiFi NAN Frame Structures
 * ======================================================================== */

/**
 * @brief NAN Attribute Header (TLV format)
 */
typedef struct __attribute__((packed)) {
    uint8_t  attr_id;                /**< Attribute ID */
    uint16_t length;                 /**< Length of value (little-endian) */
    uint8_t  value[];                /**< Variable-length value */
} nan_attribute_t;

/** NAN Attribute IDs */
#define NAN_ATTR_MASTER_INDICATION   0x00
#define NAN_ATTR_CLUSTER             0x01
#define NAN_ATTR_SERVICE_ID          0x02
#define NAN_ATTR_SERVICE_DESCRIPTOR  0x03
#define NAN_ATTR_CONNECTION_CAPABILITY 0x04
#define NAN_ATTR_WLAN_INFRA          0x05
#define NAN_ATTR_P2P_OPERATION       0x06
#define NAN_ATTR_IBSS                0x07
#define NAN_ATTR_MESH                0x08
#define NAN_ATTR_FURTHER_SERVICE_DISCOVERY 0x09
#define NAN_ATTR_FURTHER_AVAILABILITY_MAP  0x0A
#define NAN_ATTR_COUNTRY_CODE        0x0B
#define NAN_ATTR_RANGING             0x0C
#define NAN_ATTR_CLUSTER_DISCOVERY   0x0D
#define NAN_ATTR_VENDOR_SPECIFIC     0xDD

/**
 * @brief NAN Service Descriptor Attribute (for Remote ID)
 */
typedef struct __attribute__((packed)) {
    uint8_t  attr_id;                /**< 0x03 */
    uint16_t length;                 /**< Total length of following fields */
    uint8_t  service_id[6];          /**< Service ID hash (REMOTE_ID_SERVICE_ID) */
    uint8_t  instance_id;            /**< Instance ID (local) */
    uint8_t  requestor_instance_id;  /**< Requestor instance ID */
    uint8_t  service_control;        /**< Service control flags */
    uint8_t  binding_bitmap;         /**< Binding bitmap */
    uint8_t  service_info_len;       /**< Length of service_info */
    uint8_t  service_info[];         /**< Remote ID payload (25 bytes) */
} nan_service_descriptor_t;

/**
 * @brief NAN Action Frame Structure
 */
typedef struct __attribute__((packed)) {
    /* IEEE 802.11 MAC Header (24 bytes) */
    uint16_t frame_control;          /**< Frame control */
    uint16_t duration;               /**< Duration */
    uint8_t  da[6];                  /**< Destination address (broadcast) */
    uint8_t  sa[6];                  /**< Source address */
    uint8_t  bssid[6];               /**< BSSID (NAN cluster ID) */
    uint16_t seq_ctrl;               /**< Sequence control */

    /* Public Action Frame Body */
    uint8_t  category;               /**< 0x04 (Public Action) or 0x7F (Vendor) */
    uint8_t  action;                 /**< Public action code or OUI[0] */
    uint8_t  oui[3];                 /**< OUI (0x506F9A for WFA) */
    uint8_t  oui_type;               /**< 0x13 (NAN) */
    uint8_t  oui_subtype;            /**< 0x00 */
    uint16_t dialog_token;           /**< Dialog token */

    /* NAN Attributes (TLV) */
    uint8_t  attributes[];           /**< Variable-length NAN attributes */
} nan_action_frame_t;

/* ========================================================================
 * Helper Macros
 * ======================================================================== */

/** Size of all Remote ID messages */
#define REMOTE_ID_MESSAGE_SIZE      25

/** NAN Discovery Window interval (in TUs, 1 TU = 1024 μs) */
#define NAN_DW_INTERVAL_TU          512   /* 524.288 ms */

/** NAN Discovery Window duration (in TUs) */
#define NAN_DW_DURATION_TU          16    /* 16.384 ms */

/** Remote ID transmission interval (per ASTM F3411) */
#define REMOTE_ID_TX_INTERVAL_MS    1000  /* 1 Hz (1000 ms) */

/* ========================================================================
 * Validation & Encoding Functions (implemented in C)
 * ======================================================================== */

/**
 * @brief Validate Remote ID message format
 * @param msg Pointer to message
 * @return 0 on success, -1 on error
 */
int remote_id_validate_message(const remote_id_message_t *msg);

/**
 * @brief Encode Remote ID message into NAN service descriptor
 * @param msg Remote ID message to encode
 * @param nan_frame Output NAN action frame
 * @param max_len Maximum length of output buffer
 * @return Length of encoded frame, or -1 on error
 */
int remote_id_encode_nan_frame(const remote_id_message_t *msg,
                                nan_action_frame_t *nan_frame,
                                size_t max_len);

/**
 * @brief Decode Remote ID message from NAN service descriptor
 * @param nan_frame NAN action frame to decode
 * @param frame_len Length of NAN frame
 * @param msg Output Remote ID message
 * @return 0 on success, -1 on error
 */
int remote_id_decode_nan_frame(const nan_action_frame_t *nan_frame,
                                size_t frame_len,
                                remote_id_message_t *msg);

/**
 * @brief Calculate accuracy encoding (meters to code)
 * @param accuracy_meters Accuracy in meters
 * @return Encoded accuracy value (0-15)
 */
uint8_t remote_id_encode_accuracy(float accuracy_meters);

/**
 * @brief Decode accuracy (code to meters)
 * @param encoded Encoded accuracy value
 * @return Accuracy in meters
 */
float remote_id_decode_accuracy(uint8_t encoded);

#ifdef __cplusplus
}
#endif

#endif /* _REMOTE_ID_TYPES_H_ */
