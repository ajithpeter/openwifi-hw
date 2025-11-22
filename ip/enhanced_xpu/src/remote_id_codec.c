/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file remote_id_codec.c
 * @brief Software Remote ID Encoder/Decoder for ASTM F3411
 *
 * This file implements encoding and decoding of ASTM F3411 Remote ID messages
 * in software (ARM processor). It provides full NAN frame construction, message
 * validation, and accuracy encoding/decoding according to ASTM F3411-22.
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <string.h>
#include <math.h>
#include <arpa/inet.h>
#include "../include/remote_id_types.h"

/* ========================================================================
 * Helper Functions
 * ======================================================================== */

/**
 * @brief Check if a message type is valid
 */
static inline int is_valid_msg_type(uint8_t type) {
    return (type == REMOTE_ID_BASIC_ID) ||
           (type == REMOTE_ID_LOCATION) ||
           (type == REMOTE_ID_AUTH) ||
           (type == REMOTE_ID_SELF_ID) ||
           (type == REMOTE_ID_SYSTEM) ||
           (type == REMOTE_ID_OPERATOR_ID) ||
           (type == REMOTE_ID_MESSAGE_PACK);
}

/**
 * @brief Validate Basic ID message fields
 */
static int validate_basic_id(const remote_id_basic_id_t *msg) {
    // ID Type: 0=Serial, 1=CAA, 2=UTM, 3=Specific, 4=UUID
    if (msg->id_type > 4) {
        return -1;
    }

    // UA Type: 0=None, 1=Aero, 2=Helicopter, 3=Gyroplane, 4=Hybrid Lift,
    // 5=Ornithopter, 6=Glider, 7=Kite, 8=Free Balloon, 9=Captive Balloon,
    // 10=Airship, 11=Free Fall/Parachute, 12=Rocket, 13=Tethered,
    // 14=Ground Obstacle, 15=Other
    if (msg->ua_type > 15) {
        return -1;
    }

    return 0;
}

/**
 * @brief Validate Location message fields
 */
static int validate_location(const remote_id_location_t *msg) {
    // Status field validation (bits 0-3: operational status)
    uint8_t op_status = msg->status & 0x0F;
    if (op_status > 2) {  // 0=Undeclared, 1=Ground, 2=Airborne
        return -1;
    }

    // Direction: 0-360 degrees
    if (msg->direction > 360) {
        return -1;
    }

    // Speed horizontal: 0-254.25 m/s (255 = invalid)
    if (msg->speed_horiz == 255) {
        return -1;
    }

    // Accuracy codes: 0-15
    if ((msg->horiz_accuracy & 0xF0) || (msg->vert_accuracy & 0xF0) ||
        (msg->baro_accuracy & 0xF0) || (msg->speed_accuracy & 0xF0)) {
        return -1;
    }

    return 0;
}

/**
 * @brief Validate Authentication message fields
 */
static int validate_auth(const remote_id_auth_t *msg) {
    // Page number must be <= last_page_index
    if (msg->auth_page > msg->last_page_index) {
        return -1;
    }

    // Last page index: 0-15
    if (msg->last_page_index > 15) {
        return -1;
    }

    // Length must be <= 17 (size of auth_data field)
    if (msg->length > 17) {
        return -1;
    }

    return 0;
}

/**
 * @brief Validate Self-ID message fields
 */
static int validate_self_id(const remote_id_self_id_t *msg) {
    // Description type: 0=Text, 1-199=Reserved, 200+=Specific
    // Allow all values as per spec
    return 0;
}

/**
 * @brief Validate System message fields
 */
static int validate_system(const remote_id_system_t *msg) {
    // Operator location type: 0=Takeoff, 1=Live, 2=Fixed
    if (msg->operator_location_type > 2) {
        return -1;
    }

    return 0;
}

/**
 * @brief Validate Operator ID message fields
 */
static int validate_operator_id(const remote_id_operator_id_t *msg) {
    // All operator_id_type values are currently reserved
    return 0;
}

/* ========================================================================
 * Public API Implementation
 * ======================================================================== */

/**
 * @brief Validate Remote ID message format
 */
int remote_id_validate_message(const remote_id_message_t *msg) {
    if (!msg) {
        return -1;
    }

    // Check message type
    if (!is_valid_msg_type(msg->msg_type)) {
        return -1;
    }

    // Validate specific message type fields
    switch (msg->msg_type) {
        case REMOTE_ID_BASIC_ID:
            return validate_basic_id(&msg->basic_id);

        case REMOTE_ID_LOCATION:
            return validate_location(&msg->location);

        case REMOTE_ID_AUTH:
            return validate_auth(&msg->auth);

        case REMOTE_ID_SELF_ID:
            return validate_self_id(&msg->self_id);

        case REMOTE_ID_SYSTEM:
            return validate_system(&msg->system);

        case REMOTE_ID_OPERATOR_ID:
            return validate_operator_id(&msg->operator_id);

        case REMOTE_ID_MESSAGE_PACK:
            // Message pack validation would require unpacking
            return 0;

        default:
            return -1;
    }
}

/**
 * @brief Encode Remote ID message into NAN service descriptor
 */
int remote_id_encode_nan_frame(const remote_id_message_t *msg,
                                nan_action_frame_t *nan_frame,
                                size_t max_len) {
    if (!msg || !nan_frame) {
        return -1;
    }

    // Validate message first
    if (remote_id_validate_message(msg) != 0) {
        return -1;
    }

    // Calculate required frame size
    // MAC header (24) + Action header (8) + Service Descriptor attribute header (3) +
    // service_id (6) + instance_id (1) + requestor_instance_id (1) +
    // service_control (1) + binding_bitmap (1) + service_info_len (1) +
    // service_info (25)
    const size_t frame_size = 24 + 8 + 3 + 6 + 1 + 1 + 1 + 1 + 1 + REMOTE_ID_MESSAGE_SIZE;

    if (max_len < frame_size) {
        return -1;
    }

    // Clear the frame
    memset(nan_frame, 0, frame_size);

    // MAC Header (24 bytes)
    nan_frame->frame_control = 0x00D0;  // Public Action, no retry, not protected
    nan_frame->duration = 0;

    // Destination: NAN cluster address (broadcast)
    memset(nan_frame->da, 0xFF, 6);

    // Source: Will be set by lower layers (MAC address)
    memset(nan_frame->sa, 0, 6);

    // BSSID: NAN cluster ID (typically 50:6F:9A:01:00:00)
    nan_frame->bssid[0] = 0x50;
    nan_frame->bssid[1] = 0x6F;
    nan_frame->bssid[2] = 0x9A;
    nan_frame->bssid[3] = 0x01;
    nan_frame->bssid[4] = 0x00;
    nan_frame->bssid[5] = 0x00;

    nan_frame->seq_ctrl = 0;  // Will be set by lower layers

    // Public Action Frame Body
    nan_frame->category = NAN_ACTION_CATEGORY;  // 0x04 (Public Action)
    nan_frame->action = 0x09;  // Vendor-specific protected
    nan_frame->oui[0] = 0x50;  // WiFi Alliance OUI
    nan_frame->oui[1] = 0x6F;
    nan_frame->oui[2] = 0x9A;
    nan_frame->oui_type = NAN_OUI_TYPE;  // 0x13 (NAN)
    nan_frame->oui_subtype = 0x00;
    nan_frame->dialog_token = 0x0000;

    // NAN Service Descriptor Attribute
    uint8_t *attr_ptr = nan_frame->attributes;

    // Attribute ID
    *attr_ptr++ = NAN_ATTR_SERVICE_DESCRIPTOR;  // 0x03

    // Length (little-endian, 16-bit)
    uint16_t attr_len = 6 + 1 + 1 + 1 + 1 + 1 + REMOTE_ID_MESSAGE_SIZE;
    *attr_ptr++ = (attr_len & 0xFF);
    *attr_ptr++ = (attr_len >> 8) & 0xFF;

    // Service ID (6 bytes) - SHA-256 hash of "org.astm.f3411.remoteid"
    const uint8_t service_id[6] = REMOTE_ID_SERVICE_ID;
    memcpy(attr_ptr, service_id, 6);
    attr_ptr += 6;

    // Instance ID (local)
    *attr_ptr++ = 0x01;

    // Requestor Instance ID
    *attr_ptr++ = 0x00;

    // Service Control (bit 0: Publish, bit 1: Subscribe)
    *attr_ptr++ = 0x01;  // Publish

    // Binding Bitmap
    *attr_ptr++ = 0x00;

    // Service Info Length
    *attr_ptr++ = REMOTE_ID_MESSAGE_SIZE;

    // Service Info (Remote ID payload - 25 bytes)
    memcpy(attr_ptr, msg->raw, REMOTE_ID_MESSAGE_SIZE);

    return frame_size;
}

/**
 * @brief Decode Remote ID message from NAN service descriptor
 */
int remote_id_decode_nan_frame(const nan_action_frame_t *nan_frame,
                                size_t frame_len,
                                remote_id_message_t *msg) {
    if (!nan_frame || !msg) {
        return -1;
    }

    // Minimum frame size check
    const size_t min_size = 24 + 8 + 3 + 6 + 1 + 1 + 1 + 1 + 1 + REMOTE_ID_MESSAGE_SIZE;
    if (frame_len < min_size) {
        return -1;
    }

    // Verify it's a NAN frame
    if (nan_frame->category != NAN_ACTION_CATEGORY) {
        return -1;
    }

    // Verify OUI (WiFi Alliance)
    if (nan_frame->oui[0] != 0x50 || nan_frame->oui[1] != 0x6F ||
        nan_frame->oui[2] != 0x9A) {
        return -1;
    }

    // Verify OUI Type (NAN)
    if (nan_frame->oui_type != NAN_OUI_TYPE) {
        return -1;
    }

    // Parse attributes
    const uint8_t *attr_ptr = nan_frame->attributes;
    const uint8_t *frame_end = (const uint8_t *)nan_frame + frame_len;

    while (attr_ptr < frame_end) {
        uint8_t attr_id = *attr_ptr++;

        // Check bounds
        if (attr_ptr + 2 > frame_end) {
            return -1;
        }

        // Read length (little-endian)
        uint16_t attr_len = attr_ptr[0] | (attr_ptr[1] << 8);
        attr_ptr += 2;

        // Check bounds
        if (attr_ptr + attr_len > frame_end) {
            return -1;
        }

        // Look for Service Descriptor attribute
        if (attr_id == NAN_ATTR_SERVICE_DESCRIPTOR) {
            // Verify minimum length
            if (attr_len < 6 + 1 + 1 + 1 + 1 + 1) {
                return -1;
            }

            // Verify Service ID matches Remote ID
            const uint8_t expected_service_id[6] = REMOTE_ID_SERVICE_ID;
            if (memcmp(attr_ptr, expected_service_id, 6) != 0) {
                return -1;
            }
            attr_ptr += 6;

            // Skip instance_id, requestor_instance_id, service_control, binding_bitmap
            attr_ptr += 4;

            // Read service_info_len
            uint8_t service_info_len = *attr_ptr++;

            // Verify it's 25 bytes
            if (service_info_len != REMOTE_ID_MESSAGE_SIZE) {
                return -1;
            }

            // Check bounds
            if (attr_ptr + REMOTE_ID_MESSAGE_SIZE > frame_end) {
                return -1;
            }

            // Copy Remote ID message
            memcpy(msg->raw, attr_ptr, REMOTE_ID_MESSAGE_SIZE);

            // Validate the message
            return remote_id_validate_message(msg);
        }

        // Skip to next attribute
        attr_ptr += attr_len;
    }

    // Service Descriptor not found
    return -1;
}

/**
 * @brief Calculate accuracy encoding (meters to code)
 *
 * Accuracy codes per ASTM F3411-22:
 * 0: Unknown
 * 1: <3m
 * 2: <10m
 * 3: <30m
 * 4: <92.6m (0.05 NM)
 * 5: <185.2m (0.1 NM)
 * 6: <555.6m (0.3 NM)
 * 7: <1852m (1 NM)
 * 8: <18520m (10 NM)
 * 9: <185200m (100 NM)
 * 10-14: Reserved
 * 15: >185200m or unknown
 */
uint8_t remote_id_encode_accuracy(float accuracy_meters) {
    if (accuracy_meters <= 0.0f || isnan(accuracy_meters)) {
        return 0;  // Unknown
    } else if (accuracy_meters < 3.0f) {
        return 1;
    } else if (accuracy_meters < 10.0f) {
        return 2;
    } else if (accuracy_meters < 30.0f) {
        return 3;
    } else if (accuracy_meters < 92.6f) {
        return 4;
    } else if (accuracy_meters < 185.2f) {
        return 5;
    } else if (accuracy_meters < 555.6f) {
        return 6;
    } else if (accuracy_meters < 1852.0f) {
        return 7;
    } else if (accuracy_meters < 18520.0f) {
        return 8;
    } else if (accuracy_meters < 185200.0f) {
        return 9;
    } else {
        return 15;  // >185200m
    }
}

/**
 * @brief Decode accuracy (code to meters)
 *
 * Returns the upper bound of the accuracy range.
 */
float remote_id_decode_accuracy(uint8_t encoded) {
    switch (encoded & 0x0F) {
        case 0:  return 0.0f;       // Unknown
        case 1:  return 3.0f;       // <3m
        case 2:  return 10.0f;      // <10m
        case 3:  return 30.0f;      // <30m
        case 4:  return 92.6f;      // <92.6m
        case 5:  return 185.2f;     // <185.2m
        case 6:  return 555.6f;     // <555.6m
        case 7:  return 1852.0f;    // <1852m (1 NM)
        case 8:  return 18520.0f;   // <18520m (10 NM)
        case 9:  return 185200.0f;  // <185200m (100 NM)
        default: return 0.0f;       // Reserved/Unknown
    }
}
