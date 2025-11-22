// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: vendor_ie_codec_tb
//
// Description:
//   Test bench for Vendor IE (Information Element) codec module.
//   Tests IE encoding (Remote ID → IE format), IE decoding (IE → Remote ID),
//   OUI validation, length validation, round-trip encoding/decoding.
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module vendor_ie_codec_tb;

// Parameters
parameter CLK_PERIOD = 10;  // 100 MHz
parameter MAX_PAYLOAD = 256;

// Signals
reg clk;
reg rstn;

// Encoder inputs
reg encode_start;
reg [23:0] oui;
reg [7:0] oui_type;
reg [7:0] payload_length;
reg [7:0] payload_data;
reg payload_valid;
reg payload_last;

// Decoder inputs
reg decode_start;
reg [7:0] ie_byte;
reg ie_byte_valid;
reg ie_byte_last;

// Encoder outputs
wire encode_done;
wire encode_error;
wire [7:0] ie_output;
wire ie_output_valid;
wire [15:0] total_ie_length;

// Decoder outputs
wire decode_done;
wire decode_error;
wire [23:0] decoded_oui;
wire [7:0] decoded_oui_type;
wire [7:0] decoded_payload_byte;
wire decoded_payload_valid;
wire decoded_payload_complete;
wire [7:0] decoded_payload_length;
wire error_wrong_oui;
wire error_length_mismatch;
wire error_truncated_ie;

// Test storage
reg [7:0] encoded_ie [0:MAX_PAYLOAD-1];
integer encoded_ie_length;
reg [7:0] decoded_payload [0:MAX_PAYLOAD-1];
integer decoded_payload_length;

// Test counters
integer test_count;
integer pass_count;
integer fail_count;
integer i;

// DUT instantiation
vendor_ie_codec dut (
    .clk(clk),
    .rstn(rstn),

    // Encoder interface
    .encode_start(encode_start),
    .oui(oui),
    .oui_type(oui_type),
    .payload_length(payload_length),
    .payload_data(payload_data),
    .payload_valid(payload_valid),
    .payload_last(payload_last),
    .encode_done(encode_done),
    .encode_error(encode_error),
    .ie_output(ie_output),
    .ie_output_valid(ie_output_valid),
    .total_ie_length(total_ie_length),

    // Decoder interface
    .decode_start(decode_start),
    .ie_byte(ie_byte),
    .ie_byte_valid(ie_byte_valid),
    .ie_byte_last(ie_byte_last),
    .decode_done(decode_done),
    .decode_error(decode_error),
    .decoded_oui(decoded_oui),
    .decoded_oui_type(decoded_oui_type),
    .decoded_payload_byte(decoded_payload_byte),
    .decoded_payload_valid(decoded_payload_valid),
    .decoded_payload_complete(decoded_payload_complete),
    .decoded_payload_length(decoded_payload_length),
    .error_wrong_oui(error_wrong_oui),
    .error_length_mismatch(error_length_mismatch),
    .error_truncated_ie(error_truncated_ie)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Task: Encode Remote ID payload to Vendor IE
task encode_vendor_ie(
    input [23:0] in_oui,
    input [7:0] in_oui_type,
    input integer in_payload_len,
    input [MAX_PAYLOAD*8-1:0] in_payload
);
integer j, idx;
begin
    $display("  [ENCODE] OUI=0x%06X, Type=0x%02X, Len=%0d", in_oui, in_oui_type, in_payload_len);

    // Start encoding
    @(posedge clk);
    encode_start = 1'b1;
    oui = in_oui;
    oui_type = in_oui_type;
    payload_length = in_payload_len;
    @(posedge clk);
    encode_start = 1'b0;

    // Send payload bytes
    idx = 0;
    for (j = 0; j < in_payload_len; j = j + 1) begin
        @(posedge clk);
        payload_data = in_payload[j*8 +: 8];
        payload_valid = 1'b1;
        payload_last = (j == in_payload_len - 1);
        @(posedge clk);
        payload_valid = 1'b0;
        payload_last = 1'b0;
    end

    // Wait for encoding to complete
    wait(encode_done);
    @(posedge clk);
    $display("  [ENCODE] Complete. Total IE length: %0d bytes", total_ie_length);
end
endtask

// Task: Decode Vendor IE
task decode_vendor_ie(
    input integer ie_len
);
integer j;
begin
    $display("  [DECODE] Decoding %0d bytes", ie_len);

    // Start decoding
    @(posedge clk);
    decode_start = 1'b1;
    @(posedge clk);
    decode_start = 1'b0;

    // Send IE bytes
    for (j = 0; j < ie_len; j = j + 1) begin
        @(posedge clk);
        ie_byte = encoded_ie[j];
        ie_byte_valid = 1'b1;
        ie_byte_last = (j == ie_len - 1);
        @(posedge clk);
        ie_byte_valid = 1'b0;
        ie_byte_last = 1'b0;
    end

    // Wait for decoding to complete
    wait(decode_done || decode_error);
    @(posedge clk);

    if (decode_error) begin
        $display("  [DECODE] Error detected");
    end else begin
        $display("  [DECODE] Complete. OUI=0x%06X, Type=0x%02X, PayloadLen=%0d",
                 decoded_oui, decoded_oui_type, decoded_payload_length);
    end
end
endtask

// Task: Check encoding result
task check_encode(
    input expected_done,
    input expected_error,
    input [15:0] expected_length,
    input [159:0] test_name
);
begin
    test_count = test_count + 1;
    #100;

    if (encode_done == expected_done &&
        encode_error == expected_error &&
        total_ie_length == expected_length) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("  Expected: done=%b, error=%b, length=%d",
                 expected_done, expected_error, expected_length);
        $display("  Got:      done=%b, error=%b, length=%d",
                 encode_done, encode_error, total_ie_length);
        fail_count = fail_count + 1;
    end
end
endtask

// Task: Check decoding result
task check_decode(
    input expected_done,
    input expected_error,
    input [23:0] expected_oui,
    input [7:0] expected_type,
    input [7:0] expected_len,
    input [159:0] test_name
);
begin
    test_count = test_count + 1;
    #100;

    if (decode_done == expected_done &&
        decode_error == expected_error &&
        decoded_oui == expected_oui &&
        decoded_oui_type == expected_type &&
        decoded_payload_length == expected_len) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("  Expected: done=%b, error=%b, OUI=0x%06X, type=0x%02X, len=%d",
                 expected_done, expected_error, expected_oui, expected_type, expected_len);
        $display("  Got:      done=%b, error=%b, OUI=0x%06X, type=0x%02X, len=%d",
                 decode_done, decode_error, decoded_oui, decoded_oui_type, decoded_payload_length);
        fail_count = fail_count + 1;
    end
end
endtask

// Capture encoded IE bytes
always @(posedge clk) begin
    if (ie_output_valid) begin
        encoded_ie[encoded_ie_length] <= ie_output;
        encoded_ie_length <= encoded_ie_length + 1;
    end
    if (encode_start) begin
        encoded_ie_length <= 0;
    end
end

// Capture decoded payload bytes
always @(posedge clk) begin
    if (decoded_payload_valid) begin
        decoded_payload[decoded_payload_length] <= decoded_payload_byte;
        decoded_payload_length <= decoded_payload_length + 1;
    end
    if (decode_start) begin
        decoded_payload_length <= 0;
    end
end

// Main test
initial begin
    // Initialize signals
    rstn = 0;
    encode_start = 0;
    oui = 0;
    oui_type = 0;
    payload_length = 0;
    payload_data = 0;
    payload_valid = 0;
    payload_last = 0;
    decode_start = 0;
    ie_byte = 0;
    ie_byte_valid = 0;
    ie_byte_last = 0;

    encoded_ie_length = 0;
    decoded_payload_length = 0;
    test_count = 0;
    pass_count = 0;
    fail_count = 0;

    $display("=== Vendor IE Codec Test Bench ===");
    $display("Starting tests at time %0t", $time);

    // Reset
    #100;
    rstn = 1;
    #100;

    //////////////////////////////////////////////////////////////////////////
    // Test 1: Encode Remote ID Vendor IE (WiFi Alliance OUI)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 1: Encode Remote ID Vendor IE ---");
    encode_vendor_ie(
        24'h506F9A,  // WiFi Alliance OUI
        8'h13,       // NAN OUI Type
        25,          // 25-byte Remote ID payload
        {8'h00, 8'h01, 8'h02, 8'h03, 8'h04,  // Basic ID message
         8'h05, 8'h06, 8'h07, 8'h08, 8'h09,
         8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E,
         8'h0F, 8'h10, 8'h11, 8'h12, 8'h13,
         8'h14, 8'h15, 8'h16, 8'h17, 8'h18,
         {(MAX_PAYLOAD-25)*8{1'b0}}}
    );
    // IE format: Element ID (1) + Length (1) + OUI (3) + OUI Type (1) + Payload (25) = 31 bytes
    check_encode(1'b1, 1'b0, 16'd31, "Encode Remote ID IE");

    //////////////////////////////////////////////////////////////////////////
    // Test 2: Decode the encoded IE from Test 1
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 2: Decode Remote ID IE ---");
    #200;
    decode_vendor_ie(encoded_ie_length);
    check_decode(1'b1, 1'b0, 24'h506F9A, 8'h13, 8'd25, "Decode Remote ID IE");

    //////////////////////////////////////////////////////////////////////////
    // Test 3: Round-trip encoding/decoding verification
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 3: Round-trip Verification ---");
    #200;
    test_count = test_count + 1;
    // Compare original payload with decoded payload
    if (decoded_payload_length == 25) begin
        for (i = 0; i < 25; i = i + 1) begin
            if (decoded_payload[i] !== i) begin
                $display("[FAIL] Test %0d: Round-trip payload mismatch at byte %0d", test_count, i);
                $display("  Expected: 0x%02X, Got: 0x%02X", i[7:0], decoded_payload[i]);
                fail_count = fail_count + 1;
                i = 25; // Break loop
            end
        end
        if (i == 25) begin
            $display("[PASS] Test %0d: Round-trip encoding/decoding", test_count);
            pass_count = pass_count + 1;
        end
    end else begin
        $display("[FAIL] Test %0d: Round-trip length mismatch", test_count);
        fail_count = fail_count + 1;
    end

    //////////////////////////////////////////////////////////////////////////
    // Test 4: Encode with different OUI (custom vendor)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 4: Encode Custom Vendor OUI ---");
    #200;
    encode_vendor_ie(
        24'hAABBCC,  // Custom OUI
        8'h42,       // Custom type
        10,          // 10-byte payload
        {8'hDE, 8'hAD, 8'hBE, 8'hEF, 8'hCA,
         8'hFE, 8'hBA, 8'hBE, 8'h12, 8'h34,
         {(MAX_PAYLOAD-10)*8{1'b0}}}
    );
    // IE: 1 + 1 + 3 + 1 + 10 = 16 bytes
    check_encode(1'b1, 1'b0, 16'd16, "Encode custom vendor IE");

    //////////////////////////////////////////////////////////////////////////
    // Test 5: Decode IE with wrong OUI (error case)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 5: Decode Wrong OUI Error ---");
    #200;
    // Manually create an IE with wrong OUI
    encoded_ie[0] = 8'hDD;      // Vendor Specific Element ID
    encoded_ie[1] = 8'h08;      // Length = 8 (3 OUI + 1 Type + 4 data)
    encoded_ie[2] = 8'h00;      // Wrong OUI
    encoded_ie[3] = 8'h00;
    encoded_ie[4] = 8'h00;
    encoded_ie[5] = 8'h99;      // OUI Type
    encoded_ie[6] = 8'hAA;      // Data
    encoded_ie[7] = 8'hBB;
    encoded_ie[8] = 8'hCC;
    encoded_ie[9] = 8'hDD;
    decode_vendor_ie(10);
    #100;
    if (error_wrong_oui) begin
        $display("[PASS] Test %0d: Wrong OUI error detected", test_count + 1);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: Wrong OUI error not detected", test_count + 1);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 6: Decode truncated IE (error case)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 6: Decode Truncated IE Error ---");
    #200;
    // Create truncated IE
    encoded_ie[0] = 8'hDD;      // Vendor Specific Element ID
    encoded_ie[1] = 8'h10;      // Length = 16 (claims 16 bytes)
    encoded_ie[2] = 8'h50;      // WiFi Alliance OUI
    encoded_ie[3] = 8'h6F;
    encoded_ie[4] = 8'h9A;
    encoded_ie[5] = 8'h13;      // NAN type
    encoded_ie[6] = 8'hAA;      // Only 2 data bytes
    encoded_ie[7] = 8'hBB;
    // Total only 8 bytes but claims 16
    decode_vendor_ie(8);
    #100;
    if (error_truncated_ie || error_length_mismatch) begin
        $display("[PASS] Test %0d: Truncated IE error detected", test_count + 1);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: Truncated IE error not detected", test_count + 1);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 7: Encode minimum payload (1 byte)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 7: Encode Minimum Payload ---");
    #200;
    encode_vendor_ie(
        24'h506F9A,
        8'h13,
        1,
        {8'hFF, {(MAX_PAYLOAD-1)*8{1'b0}}}
    );
    // IE: 1 + 1 + 3 + 1 + 1 = 7 bytes
    check_encode(1'b1, 1'b0, 16'd7, "Encode minimum 1-byte payload");

    //////////////////////////////////////////////////////////////////////////
    // Test 8: Encode maximum payload (255 bytes)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 8: Encode Maximum Payload ---");
    #200;
    // Create 255-byte repeating pattern
    for (i = 0; i < 255; i = i + 1) begin
        encoded_ie[i] = i[7:0];
    end
    encode_vendor_ie(
        24'h506F9A,
        8'h13,
        255,
        {256{8'hA5}}
    );
    // IE: 1 + 1 + 3 + 1 + 255 = 261 bytes
    check_encode(1'b1, 1'b0, 16'd261, "Encode maximum 255-byte payload");

    //////////////////////////////////////////////////////////////////////////
    // Test Summary
    //////////////////////////////////////////////////////////////////////////
    #1000;
    $display("\n=== Test Summary ===");
    $display("Total tests: %0d", test_count);
    $display("Passed:      %0d", pass_count);
    $display("Failed:      %0d", fail_count);

    if (fail_count == 0) begin
        $display("\nALL TESTS PASSED!");
    end else begin
        $display("\nSOME TESTS FAILED!");
    end

    $finish;
end

endmodule
