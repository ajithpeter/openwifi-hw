/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file remote_id_codec.c
 * @brief ASTM F3411 Remote ID Encoder/Decoder for WiFi NAN
 *
 * This module provides encoding and decoding functions for drone Remote ID
 * messages according to ASTM F3411 standard, transported over WiFi Aware/NAN.
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <string.h>
#include <stdio.h>
#include <math.h>
#include <arpa/inet.h>
#include "../include/remote_id_types.h"

/* ========================================================================
 * Helper Functions
 * ======================================================================== */

/**
 * @brief Calculate accuracy encoding (meters to code)
 * Encoding per ASTM F3411 Table 4:
 * 0 = Unknown, 1 = <3m, 2 = <10m, 3 = <30m, 4 = <92.6m, ...
 */
uint8_t remote_id_encode_accuracy(float accuracy_meters)
{
    if (accuracy_meters < 0 || isnan(accuracy_meters))
        return 0;  /* Unknown */

    if (accuracy_meters < 3.0f)    return 1;
    if (accuracy_meters < 10.0f)   return 2;
    if (accuracy_meters < 30.0f)   return 3;
    if (accuracy_meters < 92.6f)   return 4;
    if (accuracy_meters < 185.2f)  return 5;
    if (accuracy_meters < 555.6f)  return 6;
    if (accuracy_meters < 1852.0f) return 7;

    return 8;  /* >= 1852m */
}

/**
 * @brief Decode accuracy (code to meters)
 */
float remote_id_decode_accuracy(uint8_t encoded)
{
    static const float accuracy_table[] = {
        -1.0f,   /* 0: Unknown */
        3.0f,    /* 1: <3m */
        10.0f,   /* 2: <10m */
        30.0f,   /* 3: <30m */
        92.6f,   /* 4: <92.6m */
        185.2f,  /* 5: <185.2m */
        555.6f,  /* 6: <555.6m */
        1852.0f, /* 7: <1852m */
        10000.0f /* 8: >=1852m */
    };

    if (encoded > 8)
        return -1.0f;

    return accuracy_table[encoded];
}

/* ========================================================================
 * Message Validation
 * ======================================================================== */

/**
 * @brief Validate Remote ID message format
 */
int remote_id_validate_message(const remote_id_message_t *msg)
{
    if (!msg)
        return -1;

    /* Validate message type */
    if (msg->msg_type > REMOTE_ID_MESSAGE_PACK &&
        msg->msg_type < REMOTE_ID_MESSAGE_PACK)
        return -1;

    /* Type-specific validation */
    switch (msg->msg_type) {
    case REMOTE_ID_BASIC_ID:
        /* Validate ID type (0-4) */
        if (msg->basic_id.id_type > 4)
            return -1;
        /* Validate UA type (0-15) */
        if (msg->basic_id.ua_type > 15)
            return -1;
        break;

    case REMOTE_ID_LOCATION:
        /* Validate latitude (-90 to +90) */
        if (msg->location.latitude < -900000000 ||
            msg->location.latitude > 900000000)
            return -1;
        /* Validate longitude (-180 to +180) */
        if (msg->location.longitude < -1800000000 ||
            msg->location.longitude > 1800000000)
            return -1;
        break;

    case REMOTE_ID_AUTH:
        /* Validate page index */
        if (msg->auth.auth_page > msg->auth.last_page_index)
            return -1;
        /* Validate length */
        if (msg->auth.length > 17)
            return -1;
        break;

    case REMOTE_ID_SELF_ID:
        /* Validate description type */
        if (msg->self_id.description_type > 0 &&
            msg->self_id.description_type < 200)
            return -1;  /* Reserved range */
        break;

    case REMOTE_ID_SYSTEM:
        /* Validate operator location type (0-2) */
        if (msg->system.operator_location_type > 2)
            return -1;
        break;

    case REMOTE_ID_OPERATOR_ID:
        /* No specific validation needed */
        break;

    case REMOTE_ID_MESSAGE_PACK:
        /* Validate message count (1-9) */
        if (msg->message_pack.msg_count < 1 ||
            msg->message_pack.msg_count > 9)
            return -1;
        /* Validate message size (typically 25) */
        if (msg->message_pack.msg_size != REMOTE_ID_MESSAGE_SIZE)
            return -1;
        break;

    default:
        return -1;  /* Unknown message type */
    }

    return 0;
}

/* ========================================================================
 * NAN Frame Encoding/Decoding
 * ======================================================================== */

/**
 * @brief Encode Remote ID message into NAN service descriptor
 */
int remote_id_encode_nan_frame(const remote_id_message_t *msg,
                                nan_action_frame_t *nan_frame,
                                size_t max_len)
{
    if (!msg || !nan_frame)
        return -1;

    /* Validate message */
    if (remote_id_validate_message(msg) < 0)
        return -1;

    /* Calculate required size */
    size_t required_size = sizeof(nan_action_frame_t) +
                          sizeof(nan_service_descriptor_t) +
                          REMOTE_ID_MESSAGE_SIZE;

    if (max_len < required_size)
        return -1;

    memset(nan_frame, 0, required_size);

    /* Fill MAC header */
    nan_frame->frame_control = 0xD000;  /* Public Action Frame */
    nan_frame->duration = 0;

    /* Broadcast destination */
    memset(nan_frame->da, 0xFF, 6);

    /* Source address would be filled by hardware/driver */
    memset(nan_frame->sa, 0, 6);

    /* NAN Cluster ID (broadcast) */
    uint8_t nan_cluster[6] = {0x50, 0x6F, 0x9A, 0x01, 0x00, 0x00};
    memcpy(nan_frame->bssid, nan_cluster, 6);

    nan_frame->seq_ctrl = 0;

    /* Fill Public Action frame body */
    nan_frame->category = NAN_ACTION_CATEGORY;
    nan_frame->action = 0x09;  /* Vendor-specific protected */

    /* WFA OUI */
    nan_frame->oui[0] = (WFA_OUI >> 16) & 0xFF;
    nan_frame->oui[1] = (WFA_OUI >> 8) & 0xFF;
    nan_frame->oui[2] = WFA_OUI & 0xFF;

    nan_frame->oui_type = NAN_OUI_TYPE;
    nan_frame->oui_subtype = 0x00;
    nan_frame->dialog_token = 0x0001;

    /* Build NAN Service Descriptor attribute */
    nan_service_descriptor_t *desc = (nan_service_descriptor_t *)nan_frame->attributes;
    desc->attr_id = NAN_ATTR_SERVICE_DESCRIPTOR;

    /* Service ID for Remote ID */
    uint8_t service_id[] = REMOTE_ID_SERVICE_ID;
    memcpy(desc->service_id, service_id, 6);

    desc->instance_id = 0x01;
    desc->requestor_instance_id = 0x00;
    desc->service_control = 0x00;  /* Publish */
    desc->binding_bitmap = 0x00;
    desc->service_info_len = REMOTE_ID_MESSAGE_SIZE;

    /* Copy Remote ID message to service info */
    memcpy(desc->service_info, msg->raw, REMOTE_ID_MESSAGE_SIZE);

    /* Set descriptor length (all fields after length field) */
    desc->length = 6 + 1 + 1 + 1 + 1 + 1 + REMOTE_ID_MESSAGE_SIZE;

    return required_size;
}

/**
 * @brief Decode Remote ID message from NAN service descriptor
 */
int remote_id_decode_nan_frame(const nan_action_frame_t *nan_frame,
                                size_t frame_len,
                                remote_id_message_t *msg)
{
    if (!nan_frame || !msg)
        return -1;

    /* Minimum frame size check */
    if (frame_len < sizeof(nan_action_frame_t))
        return -1;

    /* Verify it's a NAN frame */
    if (nan_frame->category != NAN_ACTION_CATEGORY)
        return -1;

    /* Verify WFA OUI */
    uint32_t oui = (nan_frame->oui[0] << 16) |
                   (nan_frame->oui[1] << 8) |
                   nan_frame->oui[2];
    if (oui != WFA_OUI)
        return -1;

    /* Verify NAN OUI type */
    if (nan_frame->oui_type != NAN_OUI_TYPE)
        return -1;

    /* Parse attributes */
    const uint8_t *attr_ptr = nan_frame->attributes;
    size_t attrs_len = frame_len - sizeof(nan_action_frame_t);

    while (attrs_len > 3) {
        uint8_t attr_id = attr_ptr[0];
        uint16_t attr_len = attr_ptr[1] | (attr_ptr[2] << 8);

        if (attr_len + 3 > attrs_len)
            break;  /* Invalid length */

        if (attr_id == NAN_ATTR_SERVICE_DESCRIPTOR) {
            const nan_service_descriptor_t *desc =
                (const nan_service_descriptor_t *)attr_ptr;

            /* Verify Remote ID service ID */
            uint8_t service_id[] = REMOTE_ID_SERVICE_ID;
            if (memcmp(desc->service_id, service_id, 6) != 0)
                return -1;  /* Not Remote ID */

            /* Extract Remote ID message */
            if (desc->service_info_len >= REMOTE_ID_MESSAGE_SIZE) {
                memcpy(msg->raw, desc->service_info, REMOTE_ID_MESSAGE_SIZE);

                /* Validate extracted message */
                if (remote_id_validate_message(msg) < 0)
                    return -1;

                return 0;  /* Success */
            }
        }

        /* Move to next attribute */
        attr_ptr += 3 + attr_len;
        attrs_len -= 3 + attr_len;
    }

    return -1;  /* Remote ID service descriptor not found */
}

/* ========================================================================
 * Helper Functions for Building Messages
 * ======================================================================== */

/**
 * @brief Build a Basic ID message
 */
int remote_id_build_basic_id(remote_id_message_t *msg,
                              uint8_t id_type,
                              uint8_t ua_type,
                              const char *uas_id)
{
    if (!msg || !uas_id)
        return -1;

    memset(msg, 0, sizeof(remote_id_message_t));

    msg->basic_id.msg_type = REMOTE_ID_BASIC_ID;
    msg->basic_id.id_type = id_type;
    msg->basic_id.ua_type = ua_type;

    /* Copy UAS ID (up to 20 bytes) */
    strncpy((char *)msg->basic_id.uas_id, uas_id, 20);

    return remote_id_validate_message(msg);
}

/**
 * @brief Build a Location message
 */
int remote_id_build_location(remote_id_message_t *msg,
                              uint8_t status,
                              double latitude,
                              double longitude,
                              float altitude_baro,
                              float altitude_geo,
                              float speed_horiz,
                              float speed_vert,
                              uint16_t direction,
                              uint16_t timestamp)
{
    if (!msg)
        return -1;

    memset(msg, 0, sizeof(remote_id_message_t));

    msg->location.msg_type = REMOTE_ID_LOCATION;
    msg->location.status = status;

    /* Encode latitude/longitude (1e-7 degree resolution) */
    msg->location.latitude = (int32_t)(latitude * 1e7);
    msg->location.longitude = (int32_t)(longitude * 1e7);

    /* Encode altitudes (0.5m resolution) */
    msg->location.altitude_baro = (int16_t)(altitude_baro * 2.0f);
    msg->location.altitude_geo = (int16_t)(altitude_geo * 2.0f);

    /* Encode speeds */
    msg->location.speed_horiz = (uint8_t)(speed_horiz * 4.0f);  /* 0.25 m/s resolution */
    msg->location.speed_vert = (int8_t)(speed_vert * 2.0f);     /* 0.5 m/s resolution */

    msg->location.direction = (uint8_t)direction;
    msg->location.timestamp = timestamp;

    /* Set default accuracy (unknown) */
    msg->location.horiz_accuracy = 0;
    msg->location.vert_accuracy = 0;
    msg->location.baro_accuracy = 0;
    msg->location.speed_accuracy = 0;

    return remote_id_validate_message(msg);
}

/**
 * @brief Build a Self-ID message
 */
int remote_id_build_self_id(remote_id_message_t *msg,
                             uint8_t description_type,
                             const char *description)
{
    if (!msg || !description)
        return -1;

    memset(msg, 0, sizeof(remote_id_message_t));

    msg->self_id.msg_type = REMOTE_ID_SELF_ID;
    msg->self_id.description_type = description_type;

    /* Copy description (up to 23 bytes) */
    strncpy((char *)msg->self_id.description, description, 23);

    return remote_id_validate_message(msg);
}

/**
 * @brief Build an Operator ID message
 */
int remote_id_build_operator_id(remote_id_message_t *msg,
                                 uint8_t operator_id_type,
                                 const char *operator_id)
{
    if (!msg || !operator_id)
        return -1;

    memset(msg, 0, sizeof(remote_id_message_t));

    msg->operator_id.msg_type = REMOTE_ID_OPERATOR_ID;
    msg->operator_id.operator_id_type = operator_id_type;

    /* Copy operator ID (up to 20 bytes) */
    strncpy((char *)msg->operator_id.operator_id, operator_id, 20);

    return remote_id_validate_message(msg);
}

/**
 * @brief Format Remote ID message as human-readable string
 */
int remote_id_format_message(const remote_id_message_t *msg,
                              char *buf,
                              size_t buf_len)
{
    if (!msg || !buf || buf_len < 512)
        return -1;

    int offset = 0;

    switch (msg->msg_type) {
    case REMOTE_ID_BASIC_ID:
        offset = snprintf(buf, buf_len,
            "Basic ID:\n"
            "  ID Type: %u\n"
            "  UA Type: %u\n"
            "  UAS ID: %.20s\n",
            msg->basic_id.id_type,
            msg->basic_id.ua_type,
            msg->basic_id.uas_id);
        break;

    case REMOTE_ID_LOCATION:
        offset = snprintf(buf, buf_len,
            "Location:\n"
            "  Status: 0x%02X\n"
            "  Latitude: %.7f°\n"
            "  Longitude: %.7f°\n"
            "  Altitude (baro): %.1f m\n"
            "  Altitude (geo): %.1f m\n"
            "  Speed (horiz): %.2f m/s\n"
            "  Speed (vert): %.2f m/s\n"
            "  Direction: %u°\n"
            "  Timestamp: %u\n",
            msg->location.status,
            msg->location.latitude / 1e7,
            msg->location.longitude / 1e7,
            msg->location.altitude_baro * 0.5f,
            msg->location.altitude_geo * 0.5f,
            msg->location.speed_horiz * 0.25f,
            msg->location.speed_vert * 0.5f,
            msg->location.direction,
            msg->location.timestamp);
        break;

    case REMOTE_ID_SELF_ID:
        offset = snprintf(buf, buf_len,
            "Self-ID:\n"
            "  Description Type: %u\n"
            "  Description: %.23s\n",
            msg->self_id.description_type,
            msg->self_id.description);
        break;

    case REMOTE_ID_OPERATOR_ID:
        offset = snprintf(buf, buf_len,
            "Operator ID:\n"
            "  Type: %u\n"
            "  ID: %.20s\n",
            msg->operator_id.operator_id_type,
            msg->operator_id.operator_id);
        break;

    default:
        offset = snprintf(buf, buf_len,
            "Message Type: %u (unsupported format)\n",
            msg->msg_type);
        break;
    }

    return offset;
}
