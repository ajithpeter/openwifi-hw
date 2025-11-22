// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: remote_id_codec_tb
//
// Description:
//   Test bench for Remote ID (ASTM F3411) codec module.
//   Tests encoding/decoding of all 6 message types, coordinate conversion,
//   accuracy encoding, timestamp handling, and little-endian byte order.
//
// Message Types:
//   0: Basic ID - UAS identification
//   1: Location/Vector - Position, velocity, altitude
//   2: Authentication - Signature data
//   3: Self-ID - Operator description
//   4: System - Operator location
//   5: Operator ID - Future use
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module remote_id_codec_tb;

// Parameters
parameter CLK_PERIOD = 10;  // 100 MHz
parameter MSG_SIZE = 25;    // All Remote ID messages are 25 bytes

// Signals
reg clk;
reg rstn;

// Encoder inputs (structured)
reg encode_start;
reg [7:0] msg_type;

// Basic ID fields
reg [7:0] id_type;
reg [7:0] ua_type;
reg [159:0] uas_id;  // 20 bytes

// Location fields
reg [7:0] status;
reg [7:0] direction;
reg [7:0] speed_horiz;
reg signed [7:0] speed_vert;
reg signed [31:0] latitude;   // 1e-7 degrees
reg signed [31:0] longitude;  // 1e-7 degrees
reg signed [15:0] altitude_baro;
reg signed [15:0] altitude_geo;
reg [15:0] height_agl;
reg [7:0] horiz_accuracy;
reg [7:0] vert_accuracy;
reg [7:0] baro_accuracy;
reg [7:0] speed_accuracy;
reg [15:0] timestamp;

// Authentication/Self-ID/System/Operator ID fields
reg [159:0] auth_data;     // 20 bytes auth data
reg [7:0] auth_page;
reg [159:0] self_id_desc;  // 20 bytes description
reg [7:0] desc_type;

// Encoder outputs
wire encode_done;
wire encode_error;
wire [7:0] encoded_byte;
wire encoded_valid;
wire [7:0] encoded_length;

// Decoder inputs
reg decode_start;
reg [7:0] decode_byte;
reg decode_valid;
reg decode_last;

// Decoder outputs
wire decode_done;
wire decode_error;
wire [7:0] decoded_msg_type;
wire [7:0] decoded_id_type;
wire [7:0] decoded_ua_type;
wire [159:0] decoded_uas_id;
wire [7:0] decoded_status;
wire [7:0] decoded_direction;
wire [7:0] decoded_speed_horiz;
wire signed [7:0] decoded_speed_vert;
wire signed [31:0] decoded_latitude;
wire signed [31:0] decoded_longitude;
wire signed [15:0] decoded_altitude_baro;
wire signed [15:0] decoded_altitude_geo;
wire [15:0] decoded_height_agl;
wire [7:0] decoded_horiz_accuracy;
wire [15:0] decoded_timestamp;
wire validation_error;

// Test storage
reg [7:0] encoded_msg [0:MSG_SIZE-1];
integer encoded_idx;

// Test counters
integer test_count;
integer pass_count;
integer fail_count;
integer i;

// DUT instantiation
remote_id_codec dut (
    .clk(clk),
    .rstn(rstn),

    // Encoder interface
    .encode_start(encode_start),
    .msg_type(msg_type),
    .id_type(id_type),
    .ua_type(ua_type),
    .uas_id(uas_id),
    .status(status),
    .direction(direction),
    .speed_horiz(speed_horiz),
    .speed_vert(speed_vert),
    .latitude(latitude),
    .longitude(longitude),
    .altitude_baro(altitude_baro),
    .altitude_geo(altitude_geo),
    .height_agl(height_agl),
    .horiz_accuracy(horiz_accuracy),
    .vert_accuracy(vert_accuracy),
    .baro_accuracy(baro_accuracy),
    .speed_accuracy(speed_accuracy),
    .timestamp(timestamp),
    .auth_data(auth_data),
    .auth_page(auth_page),
    .self_id_desc(self_id_desc),
    .desc_type(desc_type),
    .encode_done(encode_done),
    .encode_error(encode_error),
    .encoded_byte(encoded_byte),
    .encoded_valid(encoded_valid),
    .encoded_length(encoded_length),

    // Decoder interface
    .decode_start(decode_start),
    .decode_byte(decode_byte),
    .decode_valid(decode_valid),
    .decode_last(decode_last),
    .decode_done(decode_done),
    .decode_error(decode_error),
    .decoded_msg_type(decoded_msg_type),
    .decoded_id_type(decoded_id_type),
    .decoded_ua_type(decoded_ua_type),
    .decoded_uas_id(decoded_uas_id),
    .decoded_status(decoded_status),
    .decoded_direction(decoded_direction),
    .decoded_speed_horiz(decoded_speed_horiz),
    .decoded_speed_vert(decoded_speed_vert),
    .decoded_latitude(decoded_latitude),
    .decoded_longitude(decoded_longitude),
    .decoded_altitude_baro(decoded_altitude_baro),
    .decoded_altitude_geo(decoded_altitude_geo),
    .decoded_height_agl(decoded_height_agl),
    .decoded_horiz_accuracy(decoded_horiz_accuracy),
    .decoded_timestamp(decoded_timestamp),
    .validation_error(validation_error)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Task: Start encoding
task start_encode();
begin
    @(posedge clk);
    encode_start = 1'b1;
    @(posedge clk);
    encode_start = 1'b0;

    // Wait for encoding to complete
    wait(encode_done || encode_error);
    @(posedge clk);
end
endtask

// Task: Decode message
task decode_message();
integer j;
begin
    @(posedge clk);
    decode_start = 1'b1;
    @(posedge clk);
    decode_start = 1'b0;

    // Send all 25 bytes
    for (j = 0; j < MSG_SIZE; j = j + 1) begin
        @(posedge clk);
        decode_byte = encoded_msg[j];
        decode_valid = 1'b1;
        decode_last = (j == MSG_SIZE - 1);
        @(posedge clk);
        decode_valid = 1'b0;
        decode_last = 1'b0;
    end

    // Wait for decoding to complete
    wait(decode_done || decode_error);
    @(posedge clk);
end
endtask

// Task: Compare signed 32-bit values
task check_signed32(
    input signed [31:0] expected,
    input signed [31:0] actual,
    input [159:0] field_name
);
begin
    if (expected !== actual) begin
        $display("  [MISMATCH] %s: expected=%d (0x%08X), got=%d (0x%08X)",
                 field_name, expected, expected, actual, actual);
    end
end
endtask

// Capture encoded bytes
always @(posedge clk) begin
    if (encoded_valid) begin
        encoded_msg[encoded_idx] <= encoded_byte;
        encoded_idx <= encoded_idx + 1;
        $display("  [ENCODE] Byte %0d: 0x%02X", encoded_idx, encoded_byte);
    end
    if (encode_start) begin
        encoded_idx <= 0;
    end
end

// Main test
initial begin
    // Initialize signals
    rstn = 0;
    encode_start = 0;
    msg_type = 0;
    id_type = 0;
    ua_type = 0;
    uas_id = 0;
    status = 0;
    direction = 0;
    speed_horiz = 0;
    speed_vert = 0;
    latitude = 0;
    longitude = 0;
    altitude_baro = 0;
    altitude_geo = 0;
    height_agl = 0;
    horiz_accuracy = 0;
    vert_accuracy = 0;
    baro_accuracy = 0;
    speed_accuracy = 0;
    timestamp = 0;
    auth_data = 0;
    auth_page = 0;
    self_id_desc = 0;
    desc_type = 0;
    decode_start = 0;
    decode_byte = 0;
    decode_valid = 0;
    decode_last = 0;

    encoded_idx = 0;
    test_count = 0;
    pass_count = 0;
    fail_count = 0;

    $display("=== Remote ID Codec Test Bench ===");
    $display("Starting tests at time %0t", $time);
    $display("Testing ASTM F3411-22 message encoding/decoding\n");

    // Reset
    #100;
    rstn = 1;
    #100;

    //////////////////////////////////////////////////////////////////////////
    // Test 1: Basic ID Message (Type 0) - Encoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 1: Basic ID Message Encoding ---");
    msg_type = 8'h00;
    id_type = 8'h01;   // CAA Assigned Registration ID
    ua_type = 8'h04;   // Multirotor
    uas_id = 160'h4142_4344_4546_4748_494A_4B4C_4D4E_4F50_5152_5354;  // "ABCDEFGHIJKLMNOPQRST"
    start_encode();

    if (!encode_error && encoded_length == 25) begin
        $display("[PASS] Test 1: Basic ID encoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 1: Basic ID encoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 2: Basic ID Message - Decoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 2: Basic ID Message Decoding ---");
    #200;
    decode_message();

    if (!decode_error && decoded_msg_type == 8'h00 &&
        decoded_id_type == 8'h01 && decoded_ua_type == 8'h04) begin
        $display("[PASS] Test 2: Basic ID decoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 2: Basic ID decoding failed");
        $display("  msg_type=%02X, id_type=%02X, ua_type=%02X",
                 decoded_msg_type, decoded_id_type, decoded_ua_type);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 3: Location Message (Type 1) - Encoding with GPS coordinates
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 3: Location Message Encoding (GPS coordinates) ---");
    #200;
    msg_type = 8'h01;
    status = 8'h01;         // Airborne
    direction = 8'd180;     // 180 degrees (South)
    speed_horiz = 8'd20;    // 5.0 m/s (20 * 0.25)
    speed_vert = 8'sd10;    // 5.0 m/s upward (10 * 0.5)
    latitude = 32'sd374502340;    // 37.4502340° N (37.4502340 * 1e7)
    longitude = 32'sd-1221960080; // -122.1960080° W (-122.1960080 * 1e7)
    altitude_baro = 16'sd500;     // 250.0 m (500 * 0.5)
    altitude_geo = 16'sd480;      // 240.0 m
    height_agl = 16'd100;         // 100 m AGL
    horiz_accuracy = 8'd3;        // 3 meters
    vert_accuracy = 8'd1;         // 1 meter
    baro_accuracy = 8'd2;         // 2 meters
    speed_accuracy = 8'd0;        // 0.3 m/s
    timestamp = 16'd36001;        // 3600.1 seconds (1 hour + 0.1s)
    start_encode();

    if (!encode_error && encoded_length == 25 && encoded_msg[0] == 8'h01) begin
        $display("[PASS] Test 3: Location encoding successful");
        $display("  Lat=%d (0x%08X), Lon=%d (0x%08X)", latitude, latitude, longitude, longitude);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 3: Location encoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 4: Location Message - Decoding and verification
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 4: Location Message Decoding ---");
    #200;
    decode_message();

    if (!decode_error && decoded_msg_type == 8'h01) begin
        // Verify coordinates (1e-7 precision)
        check_signed32(latitude, decoded_latitude, "Latitude");
        check_signed32(longitude, decoded_longitude, "Longitude");

        if (decoded_latitude == latitude &&
            decoded_longitude == longitude &&
            decoded_direction == direction) begin
            $display("[PASS] Test 4: Location decoding successful");
            $display("  Decoded Lat=%d, Lon=%d, Dir=%d",
                     decoded_latitude, decoded_longitude, decoded_direction);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test 4: Location field mismatch");
            fail_count = fail_count + 1;
        end
    end else begin
        $display("[FAIL] Test 4: Location decoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 5: Authentication Message (Type 2) - Encoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 5: Authentication Message Encoding ---");
    #200;
    msg_type = 8'h02;
    auth_page = 8'h00;  // First page
    auth_data = 160'h0123456789ABCDEF0123456789ABCDEF01234567;  // 20 bytes of auth data
    start_encode();

    if (!encode_error && encoded_length == 25 && encoded_msg[0] == 8'h02) begin
        $display("[PASS] Test 5: Authentication encoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 5: Authentication encoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 6: Authentication Message - Decoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 6: Authentication Message Decoding ---");
    #200;
    decode_message();

    if (!decode_error && decoded_msg_type == 8'h02) begin
        $display("[PASS] Test 6: Authentication decoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 6: Authentication decoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 7: Self-ID Message (Type 3) - Encoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 7: Self-ID Message Encoding ---");
    #200;
    msg_type = 8'h03;
    desc_type = 8'h00;  // Free-form text
    self_id_desc = 160'h44726f6e65204f70657261746f722031323300000000;  // "Drone Operator 123"
    start_encode();

    if (!encode_error && encoded_length == 25 && encoded_msg[0] == 8'h03) begin
        $display("[PASS] Test 7: Self-ID encoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 7: Self-ID encoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 8: Self-ID Message - Decoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 8: Self-ID Message Decoding ---");
    #200;
    decode_message();

    if (!decode_error && decoded_msg_type == 8'h03) begin
        $display("[PASS] Test 8: Self-ID decoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 8: Self-ID decoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 9: System Message (Type 4) - Encoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 9: System Message Encoding ---");
    #200;
    msg_type = 8'h04;
    // System message contains operator location
    latitude = 32'sd374500000;    // Operator at 37.45° N
    longitude = 32'sd-1222000000; // Operator at -122.2° W
    altitude_geo = 16'sd200;      // Operator at 100m elevation
    timestamp = 16'd36000;
    start_encode();

    if (!encode_error && encoded_length == 25 && encoded_msg[0] == 8'h04) begin
        $display("[PASS] Test 9: System encoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 9: System encoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 10: System Message - Decoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 10: System Message Decoding ---");
    #200;
    decode_message();

    if (!decode_error && decoded_msg_type == 8'h04) begin
        $display("[PASS] Test 10: System decoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 10: System decoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 11: Operator ID Message (Type 5) - Encoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 11: Operator ID Message Encoding ---");
    #200;
    msg_type = 8'h05;
    // Operator ID format (future use)
    start_encode();

    if (!encode_error && encoded_length == 25 && encoded_msg[0] == 8'h05) begin
        $display("[PASS] Test 11: Operator ID encoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 11: Operator ID encoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 12: Operator ID Message - Decoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 12: Operator ID Message Decoding ---");
    #200;
    decode_message();

    if (!decode_error && decoded_msg_type == 8'h05) begin
        $display("[PASS] Test 12: Operator ID decoding successful");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 12: Operator ID decoding failed");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 13: Little-Endian Byte Order Verification
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 13: Little-Endian Byte Order ---");
    #200;
    msg_type = 8'h01;
    latitude = 32'h12345678;   // Test value
    longitude = 32'hABCDEF00;  // Test value
    start_encode();

    // Check byte order: latitude at bytes 5-8 (little-endian)
    if (encoded_msg[5] == 8'h78 && encoded_msg[6] == 8'h56 &&
        encoded_msg[7] == 8'h34 && encoded_msg[8] == 8'h12) begin
        $display("[PASS] Test 13: Little-endian byte order correct");
        $display("  Latitude bytes: %02X %02X %02X %02X (should be 78 56 34 12)",
                 encoded_msg[5], encoded_msg[6], encoded_msg[7], encoded_msg[8]);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 13: Little-endian byte order incorrect");
        $display("  Expected: 78 56 34 12");
        $display("  Got:      %02X %02X %02X %02X",
                 encoded_msg[5], encoded_msg[6], encoded_msg[7], encoded_msg[8]);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 14: Accuracy Encoding
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 14: Accuracy Encoding ---");
    #200;
    msg_type = 8'h01;
    horiz_accuracy = 8'd10;   // 10 meters
    vert_accuracy = 8'd5;     // 5 meters
    start_encode();
    decode_message();

    if (decoded_horiz_accuracy == horiz_accuracy) begin
        $display("[PASS] Test 14: Accuracy encoding/decoding correct");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 14: Accuracy mismatch");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 15: Timestamp Encoding (0.1 second precision)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 15: Timestamp Encoding ---");
    #200;
    msg_type = 8'h01;
    timestamp = 16'd36001;  // 3600.1 seconds
    start_encode();
    decode_message();

    if (decoded_timestamp == timestamp) begin
        $display("[PASS] Test 15: Timestamp encoding/decoding correct");
        $display("  Timestamp: %d (%.1f seconds)", timestamp, timestamp / 10.0);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 15: Timestamp mismatch");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test Summary
    //////////////////////////////////////////////////////////////////////////
    #1000;
    $display("\n=== Test Summary ===");
    $display("Total tests: %0d", test_count);
    $display("Passed:      %0d", pass_count);
    $display("Failed:      %0d", fail_count);
    $display("\nMessage Types Tested:");
    $display("  - Type 0: Basic ID");
    $display("  - Type 1: Location/Vector");
    $display("  - Type 2: Authentication");
    $display("  - Type 3: Self-ID");
    $display("  - Type 4: System");
    $display("  - Type 5: Operator ID");

    if (fail_count == 0) begin
        $display("\nALL TESTS PASSED!");
    end else begin
        $display("\nSOME TESTS FAILED!");
    end

    $finish;
end

endmodule
