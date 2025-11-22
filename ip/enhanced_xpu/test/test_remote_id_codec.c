/* SPDX-FileCopyrightText: 2025 OpenWiFi Project
 * SPDX-License-Identifier: AGPL-3.0-only
 */

/**
 * @file test_remote_id_codec.c
 * @brief Unit tests for Remote ID encoder/decoder
 *
 * Comprehensive test suite for ASTM F3411 Remote ID encoding and decoding.
 * Tests all 6 message types, edge cases, error conditions, and NAN frame
 * encoding/decoding.
 *
 * @author OpenWiFi Team
 * @date 2025-11-22
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include "../include/remote_id_types.h"

// Test counters
static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

// Color codes for output
#define COLOR_GREEN  "\033[0;32m"
#define COLOR_RED    "\033[0;31m"
#define COLOR_YELLOW "\033[0;33m"
#define COLOR_RESET  "\033[0m"

/**
 * @brief Test assertion macro
 */
#define TEST_ASSERT(condition, message) do { \
    tests_run++; \
    if (condition) { \
        tests_passed++; \
        printf(COLOR_GREEN "[PASS]" COLOR_RESET " %s\n", message); \
    } else { \
        tests_failed++; \
        printf(COLOR_RED "[FAIL]" COLOR_RESET " %s\n", message); \
    } \
} while(0)

/**
 * @brief Test section header
 */
#define TEST_SECTION(name) \
    printf("\n" COLOR_YELLOW "=== %s ===" COLOR_RESET "\n", name)

/* ========================================================================
 * Test Helper Functions
 * ======================================================================== */

/**
 * @brief Print message in hex format
 */
static void print_message_hex(const uint8_t *msg, size_t len) {
    printf("  ");
    for (size_t i = 0; i < len; i++) {
        printf("%02X ", msg[i]);
        if ((i + 1) % 8 == 0) printf("\n  ");
    }
    printf("\n");
}

/**
 * @brief Compare two messages
 */
static int compare_messages(const remote_id_message_t *msg1,
                           const remote_id_message_t *msg2) {
    return memcmp(msg1->raw, msg2->raw, REMOTE_ID_MESSAGE_SIZE) == 0;
}

/* ========================================================================
 * Accuracy Encoding/Decoding Tests
 * ======================================================================== */

static void test_accuracy_encoding(void) {
    TEST_SECTION("Accuracy Encoding/Decoding Tests");

    // Test accuracy encoding
    TEST_ASSERT(remote_id_encode_accuracy(0.0f) == 0, "Encode accuracy: 0m -> 0 (Unknown)");
    TEST_ASSERT(remote_id_encode_accuracy(-1.0f) == 0, "Encode accuracy: -1m -> 0 (Unknown)");
    TEST_ASSERT(remote_id_encode_accuracy(2.5f) == 1, "Encode accuracy: 2.5m -> 1 (<3m)");
    TEST_ASSERT(remote_id_encode_accuracy(5.0f) == 2, "Encode accuracy: 5m -> 2 (<10m)");
    TEST_ASSERT(remote_id_encode_accuracy(15.0f) == 3, "Encode accuracy: 15m -> 3 (<30m)");
    TEST_ASSERT(remote_id_encode_accuracy(50.0f) == 4, "Encode accuracy: 50m -> 4 (<92.6m)");
    TEST_ASSERT(remote_id_encode_accuracy(100.0f) == 5, "Encode accuracy: 100m -> 5 (<185.2m)");
    TEST_ASSERT(remote_id_encode_accuracy(300.0f) == 6, "Encode accuracy: 300m -> 6 (<555.6m)");
    TEST_ASSERT(remote_id_encode_accuracy(1000.0f) == 7, "Encode accuracy: 1000m -> 7 (<1852m)");
    TEST_ASSERT(remote_id_encode_accuracy(10000.0f) == 8, "Encode accuracy: 10000m -> 8 (<18520m)");
    TEST_ASSERT(remote_id_encode_accuracy(100000.0f) == 9, "Encode accuracy: 100000m -> 9 (<185200m)");
    TEST_ASSERT(remote_id_encode_accuracy(200000.0f) == 15, "Encode accuracy: 200000m -> 15 (>185200m)");
    TEST_ASSERT(remote_id_encode_accuracy(NAN) == 0, "Encode accuracy: NaN -> 0 (Unknown)");

    // Test accuracy decoding
    TEST_ASSERT(fabs(remote_id_decode_accuracy(0) - 0.0f) < 0.01f, "Decode accuracy: 0 -> 0m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(1) - 3.0f) < 0.01f, "Decode accuracy: 1 -> 3m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(2) - 10.0f) < 0.01f, "Decode accuracy: 2 -> 10m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(3) - 30.0f) < 0.01f, "Decode accuracy: 3 -> 30m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(4) - 92.6f) < 0.01f, "Decode accuracy: 4 -> 92.6m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(5) - 185.2f) < 0.01f, "Decode accuracy: 5 -> 185.2m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(6) - 555.6f) < 0.01f, "Decode accuracy: 6 -> 555.6m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(7) - 1852.0f) < 0.01f, "Decode accuracy: 7 -> 1852m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(8) - 18520.0f) < 0.01f, "Decode accuracy: 8 -> 18520m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(9) - 185200.0f) < 0.01f, "Decode accuracy: 9 -> 185200m");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(10) - 0.0f) < 0.01f, "Decode accuracy: 10 -> 0m (Reserved)");
    TEST_ASSERT(fabs(remote_id_decode_accuracy(15) - 0.0f) < 0.01f, "Decode accuracy: 15 -> 0m (>185200m)");

    // Test round-trip encoding/decoding
    float test_values[] = {2.5f, 5.0f, 15.0f, 50.0f, 100.0f, 300.0f, 1000.0f, 10000.0f, 100000.0f};
    for (size_t i = 0; i < sizeof(test_values) / sizeof(test_values[0]); i++) {
        uint8_t encoded = remote_id_encode_accuracy(test_values[i]);
        float decoded = remote_id_decode_accuracy(encoded);
        char msg[256];
        snprintf(msg, sizeof(msg), "Round-trip accuracy: %.1fm -> %d -> %.1fm",
                 test_values[i], encoded, decoded);
        TEST_ASSERT(decoded >= test_values[i], msg);
    }
}

/* ========================================================================
 * Basic ID Message Tests
 * ======================================================================== */

static void test_basic_id_message(void) {
    TEST_SECTION("Basic ID Message Tests");

    remote_id_message_t msg;
    memset(&msg, 0, sizeof(msg));

    // Create valid Basic ID message
    msg.basic_id.msg_type = REMOTE_ID_BASIC_ID;
    msg.basic_id.id_type = 0;  // Serial number
    msg.basic_id.ua_type = 1;  // Aeroplane
    strcpy((char *)msg.basic_id.uas_id, "ABC123XYZ");

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Valid Basic ID message");

    // Test invalid ID type
    msg.basic_id.id_type = 10;  // Invalid
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Basic ID: bad id_type");

    // Reset to valid
    msg.basic_id.id_type = 0;

    // Test invalid UA type
    msg.basic_id.ua_type = 20;  // Invalid
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Basic ID: bad ua_type");

    // Reset to valid
    msg.basic_id.ua_type = 1;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Basic ID validation restored");

    printf("  Basic ID structure size: %zu bytes\n", sizeof(remote_id_basic_id_t));
}

/* ========================================================================
 * Location Message Tests
 * ======================================================================== */

static void test_location_message(void) {
    TEST_SECTION("Location Message Tests");

    remote_id_message_t msg;
    memset(&msg, 0, sizeof(msg));

    // Create valid Location message
    msg.location.msg_type = REMOTE_ID_LOCATION;
    msg.location.status = 0x02;  // Airborne
    msg.location.direction = 180;  // South
    msg.location.speed_horiz = 100;  // 25 m/s (100 * 0.25)
    msg.location.speed_vert = 10;  // 5 m/s (10 * 0.5)

    // Latitude: 37.7749 degrees (San Francisco)
    msg.location.latitude = 377749000;  // 37.7749 * 1e7

    // Longitude: -122.4194 degrees
    msg.location.longitude = -1224194000;  // -122.4194 * 1e7

    msg.location.altitude_baro = 1000;  // 500m (1000 * 0.5)
    msg.location.altitude_geo = 1020;  // 510m
    msg.location.height_agl = 50;  // 50m

    // Set accuracy values
    msg.location.horiz_accuracy = remote_id_encode_accuracy(10.0f);
    msg.location.vert_accuracy = remote_id_encode_accuracy(5.0f);
    msg.location.baro_accuracy = remote_id_encode_accuracy(15.0f);
    msg.location.speed_accuracy = remote_id_encode_accuracy(3.0f);

    msg.location.timestamp = 36000;  // 3600.0 seconds

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Valid Location message");

    // Test invalid direction
    msg.location.direction = 361;
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Location: bad direction");
    msg.location.direction = 180;

    // Test invalid speed
    msg.location.speed_horiz = 255;  // Invalid marker
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Location: bad speed");
    msg.location.speed_horiz = 100;

    // Test invalid accuracy (bits set in upper nibble)
    msg.location.horiz_accuracy = 0x1F;  // Invalid
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Location: bad accuracy");
    msg.location.horiz_accuracy = 2;

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Location validation restored");

    printf("  Location structure size: %zu bytes\n", sizeof(remote_id_location_t));
}

/* ========================================================================
 * Authentication Message Tests
 * ======================================================================== */

static void test_auth_message(void) {
    TEST_SECTION("Authentication Message Tests");

    remote_id_message_t msg;
    memset(&msg, 0, sizeof(msg));

    // Create valid Authentication message
    msg.auth.msg_type = REMOTE_ID_AUTH;
    msg.auth.auth_type = 10;  // Specific authentication
    msg.auth.auth_page = 0;
    msg.auth.last_page_index = 2;
    msg.auth.length = 17;
    msg.auth.timestamp = 1700000000;  // Unix timestamp
    memset(msg.auth.auth_data, 0xAA, 17);

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Valid Authentication message");

    // Test invalid page number
    msg.auth.auth_page = 5;
    msg.auth.last_page_index = 2;
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Auth: page > last_page");
    msg.auth.auth_page = 0;

    // Test invalid last_page_index
    msg.auth.last_page_index = 20;
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Auth: last_page > 15");
    msg.auth.last_page_index = 2;

    // Test invalid length
    msg.auth.length = 20;
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid Auth: length > 17");
    msg.auth.length = 17;

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Auth validation restored");

    printf("  Auth structure size: %zu bytes\n", sizeof(remote_id_auth_t));
}

/* ========================================================================
 * Self-ID Message Tests
 * ======================================================================== */

static void test_self_id_message(void) {
    TEST_SECTION("Self-ID Message Tests");

    remote_id_message_t msg;
    memset(&msg, 0, sizeof(msg));

    // Create valid Self-ID message
    msg.self_id.msg_type = REMOTE_ID_SELF_ID;
    msg.self_id.description_type = 0;  // Text
    strcpy((char *)msg.self_id.description, "Test Drone");

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Valid Self-ID message");

    // Test with different description types
    msg.self_id.description_type = 200;  // Specific
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Self-ID with specific type");

    printf("  Self-ID structure size: %zu bytes\n", sizeof(remote_id_self_id_t));
}

/* ========================================================================
 * System Message Tests
 * ======================================================================== */

static void test_system_message(void) {
    TEST_SECTION("System Message Tests");

    remote_id_message_t msg;
    memset(&msg, 0, sizeof(msg));

    // Create valid System message
    msg.system.msg_type = REMOTE_ID_SYSTEM;
    msg.system.operator_location_type = 1;  // Live/Dynamic
    msg.system.classification_type = 0;
    msg.system.operator_latitude = 377749000;  // 37.7749
    msg.system.operator_longitude = -1224194000;  // -122.4194
    msg.system.area_count = 1;
    msg.system.area_radius = 100;  // 10000m (100 * 100)
    msg.system.area_ceiling = 500.0f;
    msg.system.area_floor = 0.0f;
    msg.system.category_eu = 0;
    msg.system.class_eu = 0;
    msg.system.operator_altitude_geo = 100.0f;
    msg.system.timestamp = 36000;

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Valid System message");

    // Test invalid operator location type
    msg.system.operator_location_type = 5;
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid System: bad location type");
    msg.system.operator_location_type = 1;

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "System validation restored");

    printf("  System structure size: %zu bytes\n", sizeof(remote_id_system_t));
}

/* ========================================================================
 * Operator ID Message Tests
 * ======================================================================== */

static void test_operator_id_message(void) {
    TEST_SECTION("Operator ID Message Tests");

    remote_id_message_t msg;
    memset(&msg, 0, sizeof(msg));

    // Create valid Operator ID message
    msg.operator_id.msg_type = REMOTE_ID_OPERATOR_ID;
    msg.operator_id.operator_id_type = 0;
    strcpy((char *)msg.operator_id.operator_id, "OPERATOR-12345");

    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Valid Operator ID message");

    printf("  Operator ID structure size: %zu bytes\n", sizeof(remote_id_operator_id_t));
}

/* ========================================================================
 * NAN Frame Encoding/Decoding Tests
 * ======================================================================== */

static void test_nan_frame_encoding(void) {
    TEST_SECTION("NAN Frame Encoding/Decoding Tests");

    remote_id_message_t msg_in, msg_out;
    uint8_t frame_buffer[256];
    nan_action_frame_t *nan_frame = (nan_action_frame_t *)frame_buffer;

    // Create a Location message
    memset(&msg_in, 0, sizeof(msg_in));
    msg_in.location.msg_type = REMOTE_ID_LOCATION;
    msg_in.location.status = 0x02;
    msg_in.location.direction = 90;
    msg_in.location.speed_horiz = 80;
    msg_in.location.latitude = 377749000;
    msg_in.location.longitude = -1224194000;
    msg_in.location.altitude_baro = 1000;
    msg_in.location.altitude_geo = 1020;
    msg_in.location.height_agl = 50;
    msg_in.location.horiz_accuracy = 2;
    msg_in.location.vert_accuracy = 1;
    msg_in.location.baro_accuracy = 3;
    msg_in.location.speed_accuracy = 1;
    msg_in.location.timestamp = 36000;

    // Encode to NAN frame
    int frame_len = remote_id_encode_nan_frame(&msg_in, nan_frame, sizeof(frame_buffer));
    TEST_ASSERT(frame_len > 0, "NAN frame encoding successful");
    printf("  Encoded NAN frame size: %d bytes\n", frame_len);

    // Decode from NAN frame
    memset(&msg_out, 0, sizeof(msg_out));
    int result = remote_id_decode_nan_frame(nan_frame, frame_len, &msg_out);
    TEST_ASSERT(result == 0, "NAN frame decoding successful");

    // Compare input and output messages
    TEST_ASSERT(compare_messages(&msg_in, &msg_out), "Round-trip NAN encoding/decoding");

    // Test with Basic ID message
    memset(&msg_in, 0, sizeof(msg_in));
    msg_in.basic_id.msg_type = REMOTE_ID_BASIC_ID;
    msg_in.basic_id.id_type = 0;
    msg_in.basic_id.ua_type = 1;
    strcpy((char *)msg_in.basic_id.uas_id, "TEST-DRONE-001");

    frame_len = remote_id_encode_nan_frame(&msg_in, nan_frame, sizeof(frame_buffer));
    TEST_ASSERT(frame_len > 0, "NAN frame encoding (Basic ID) successful");

    memset(&msg_out, 0, sizeof(msg_out));
    result = remote_id_decode_nan_frame(nan_frame, frame_len, &msg_out);
    TEST_ASSERT(result == 0, "NAN frame decoding (Basic ID) successful");
    TEST_ASSERT(compare_messages(&msg_in, &msg_out), "Round-trip NAN (Basic ID)");

    // Test error conditions
    TEST_ASSERT(remote_id_encode_nan_frame(NULL, nan_frame, sizeof(frame_buffer)) < 0,
                "NAN encode with NULL message");
    TEST_ASSERT(remote_id_encode_nan_frame(&msg_in, NULL, sizeof(frame_buffer)) < 0,
                "NAN encode with NULL frame");
    TEST_ASSERT(remote_id_encode_nan_frame(&msg_in, nan_frame, 10) < 0,
                "NAN encode with insufficient buffer");
    TEST_ASSERT(remote_id_decode_nan_frame(NULL, frame_len, &msg_out) < 0,
                "NAN decode with NULL frame");
    TEST_ASSERT(remote_id_decode_nan_frame(nan_frame, frame_len, NULL) < 0,
                "NAN decode with NULL message");
    TEST_ASSERT(remote_id_decode_nan_frame(nan_frame, 10, &msg_out) < 0,
                "NAN decode with invalid length");
}

/* ========================================================================
 * Edge Case Tests
 * ======================================================================== */

static void test_edge_cases(void) {
    TEST_SECTION("Edge Case Tests");

    remote_id_message_t msg;

    // Test maximum latitude (90 degrees)
    memset(&msg, 0, sizeof(msg));
    msg.location.msg_type = REMOTE_ID_LOCATION;
    msg.location.latitude = 900000000;  // 90.0 degrees
    msg.location.longitude = 0;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Max latitude (90 deg)");

    // Test minimum latitude (-90 degrees)
    msg.location.latitude = -900000000;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Min latitude (-90 deg)");

    // Test maximum longitude (180 degrees)
    msg.location.latitude = 0;
    msg.location.longitude = 1800000000;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Max longitude (180 deg)");

    // Test minimum longitude (-180 degrees)
    msg.location.longitude = -1800000000;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Min longitude (-180 deg)");

    // Test maximum speed (254.25 m/s)
    msg.location.speed_horiz = 254;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Max horizontal speed");

    // Test maximum direction (360 degrees)
    msg.location.direction = 360;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Max direction (360 deg)");

    // Test minimum direction (0 degrees)
    msg.location.direction = 0;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Min direction (0 deg)");

    // Test all message types
    for (int type = 0; type <= 5; type++) {
        memset(&msg, 0, sizeof(msg));
        msg.raw[0] = type;
        int result = remote_id_validate_message(&msg);
        char test_msg[64];
        snprintf(test_msg, sizeof(test_msg), "Message type %d validation", type);
        TEST_ASSERT(result == 0, test_msg);
    }

    // Test invalid message type
    msg.raw[0] = 6;  // Invalid
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid message type 6");

    msg.raw[0] = 14;  // Invalid
    TEST_ASSERT(remote_id_validate_message(&msg) != 0, "Invalid message type 14");

    // Test message pack (type 15)
    msg.raw[0] = REMOTE_ID_MESSAGE_PACK;
    TEST_ASSERT(remote_id_validate_message(&msg) == 0, "Message pack type");
}

/* ========================================================================
 * Main Test Runner
 * ======================================================================== */

int main(int argc, char **argv) {
    printf("\n");
    printf("========================================\n");
    printf("  Remote ID Codec Unit Tests\n");
    printf("  ASTM F3411-22 Implementation\n");
    printf("========================================\n");

    // Run all test suites
    test_accuracy_encoding();
    test_basic_id_message();
    test_location_message();
    test_auth_message();
    test_self_id_message();
    test_system_message();
    test_operator_id_message();
    test_nan_frame_encoding();
    test_edge_cases();

    // Print summary
    printf("\n");
    printf("========================================\n");
    printf("  Test Summary\n");
    printf("========================================\n");
    printf("  Total tests:  %d\n", tests_run);
    printf("  " COLOR_GREEN "Passed:       %d" COLOR_RESET "\n", tests_passed);
    printf("  " COLOR_RED "Failed:       %d" COLOR_RESET "\n", tests_failed);
    printf("  Success rate: %.1f%%\n",
           tests_run > 0 ? (100.0 * tests_passed / tests_run) : 0.0);
    printf("========================================\n");

    return (tests_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
