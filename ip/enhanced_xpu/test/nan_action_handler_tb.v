// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: nan_action_handler_tb
//
// Description:
//   Test bench for NAN action frame handler module.
//   Tests TLV attribute parsing, Service Descriptor extraction,
//   Service ID validation, payload extraction, and error handling.
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module nan_action_handler_tb;

// Parameters
parameter CLK_PERIOD = 10;  // 100 MHz
parameter PAYLOAD_SIZE = 25;  // Remote ID payload size

// Signals
reg clk;
reg rstn;

// Input frame data
reg frame_valid;
reg [7:0] frame_byte;
reg frame_last;
reg [15:0] frame_length;

// Configuration
reg [47:0] service_id;  // Expected Remote ID service ID

// Outputs
wire nan_frame_detected;
wire service_id_match;
wire [7:0] attr_type;
wire [15:0] attr_length;
wire attr_valid;
wire [7:0] payload_byte;
wire payload_valid;
wire payload_complete;
wire [7:0] payload_length;
wire error_invalid_length;
wire error_wrong_service_id;
wire error_truncated_attr;

// Test counters
integer test_count;
integer pass_count;
integer fail_count;

// DUT instantiation (module interface based on architecture)
nan_action_handler dut (
    .clk(clk),
    .rstn(rstn),

    // Frame input
    .frame_valid(frame_valid),
    .frame_byte(frame_byte),
    .frame_last(frame_last),
    .frame_length(frame_length),

    // Configuration
    .expected_service_id(service_id),

    // Outputs
    .nan_frame_detected(nan_frame_detected),
    .service_id_match(service_id_match),
    .attr_type(attr_type),
    .attr_length(attr_length),
    .attr_valid(attr_valid),
    .payload_byte(payload_byte),
    .payload_valid(payload_valid),
    .payload_complete(payload_complete),
    .payload_length(payload_length),
    .error_invalid_length(error_invalid_length),
    .error_wrong_service_id(error_wrong_service_id),
    .error_truncated_attr(error_truncated_attr)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Task: Send a byte to the handler
task send_byte(input [7:0] data, input is_last);
begin
    @(posedge clk);
    frame_valid = 1'b1;
    frame_byte = data;
    frame_last = is_last;
    @(posedge clk);
    frame_valid = 1'b0;
    frame_last = 1'b0;
end
endtask

// Task: Send NAN action frame header
task send_nan_header();
begin
    // MAC Header (24 bytes) - simplified, just send category and OUI
    send_byte(8'h7F, 1'b0);  // Category: Vendor Specific
    send_byte(8'h50, 1'b0);  // OUI[0]: WiFi Alliance
    send_byte(8'h6F, 1'b0);  // OUI[1]
    send_byte(8'h9A, 1'b0);  // OUI[2]
    send_byte(8'h13, 1'b0);  // OUI Type: NAN
    send_byte(8'h00, 1'b0);  // NAN OUI Subtype
    send_byte(8'h01, 1'b0);  // Dialog Token[0]
    send_byte(8'h00, 1'b0);  // Dialog Token[1]
end
endtask

// Task: Send TLV attribute header
task send_tlv_header(input [7:0] attr_id, input [15:0] length);
begin
    send_byte(attr_id, 1'b0);           // Attribute ID
    send_byte(length[7:0], 1'b0);       // Length LSB (little-endian)
    send_byte(length[15:8], 1'b0);      // Length MSB
end
endtask

// Task: Send Service Descriptor Attribute
task send_service_descriptor(
    input [47:0] svc_id,
    input [7:0] instance_id,
    input [7:0] svc_info_len,
    input [199:0] svc_info  // 25 bytes max
);
integer i;
begin
    // Service Descriptor Attribute ID = 0x03
    // Length = 6 (service_id) + 1 (instance) + 1 (requestor) + 1 (control) + 1 (binding) + 1 (info_len) + info_len
    send_tlv_header(8'h03, 16'd11 + svc_info_len);

    // Service ID (6 bytes)
    send_byte(svc_id[7:0], 1'b0);
    send_byte(svc_id[15:8], 1'b0);
    send_byte(svc_id[23:16], 1'b0);
    send_byte(svc_id[31:24], 1'b0);
    send_byte(svc_id[39:32], 1'b0);
    send_byte(svc_id[47:40], 1'b0);

    // Instance ID, Requestor Instance ID, Service Control, Binding Bitmap
    send_byte(instance_id, 1'b0);
    send_byte(8'h00, 1'b0);  // Requestor Instance ID
    send_byte(8'h00, 1'b0);  // Service Control
    send_byte(8'h00, 1'b0);  // Binding Bitmap

    // Service Info Length
    send_byte(svc_info_len, 1'b0);

    // Service Info (payload)
    for (i = 0; i < svc_info_len; i = i + 1) begin
        send_byte(svc_info[i*8 +: 8], (i == svc_info_len - 1));
    end
end
endtask

// Task: Check result
task check_result(
    input expected_detected,
    input expected_match,
    input expected_complete,
    input [7:0] expected_len,
    input [159:0] test_name
);
begin
    test_count = test_count + 1;
    #100;  // Wait for processing

    if (nan_frame_detected == expected_detected &&
        service_id_match == expected_match &&
        payload_complete == expected_complete &&
        payload_length == expected_len) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("  Expected: detected=%b, match=%b, complete=%b, len=%d",
                 expected_detected, expected_match, expected_complete, expected_len);
        $display("  Got:      detected=%b, match=%b, complete=%b, len=%d",
                 nan_frame_detected, service_id_match, payload_complete, payload_length);
        fail_count = fail_count + 1;
    end
end
endtask

// Main test
initial begin
    // Initialize signals
    rstn = 0;
    frame_valid = 0;
    frame_byte = 0;
    frame_last = 0;
    frame_length = 0;

    // Remote ID Service ID: SHA-256("org.astm.f3411.remoteid")[0:6]
    service_id = 48'h886919_9D9209;

    test_count = 0;
    pass_count = 0;
    fail_count = 0;

    $display("=== NAN Action Handler Test Bench ===");
    $display("Starting tests at time %0t", $time);

    // Reset
    #100;
    rstn = 1;
    #100;

    //////////////////////////////////////////////////////////////////////////
    // Test 1: Valid Remote ID Service Descriptor (25-byte payload)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 1: Valid Remote ID Service Descriptor ---");
    send_nan_header();
    send_service_descriptor(
        48'h886919_9D9209,  // Correct Remote ID Service ID
        8'h01,              // Instance ID
        8'd25,              // Service Info Length = 25 bytes
        {8'h00, 8'h01, 8'h02, 8'h03, 8'h04,  // Basic ID message type 0
         8'h05, 8'h06, 8'h07, 8'h08, 8'h09,
         8'h0A, 8'h0B, 8'h0C, 8'h0D, 8'h0E,
         8'h0F, 8'h10, 8'h11, 8'h12, 8'h13,
         8'h14, 8'h15, 8'h16, 8'h17, 8'h18}
    );
    check_result(1'b1, 1'b1, 1'b1, 8'd25, "Valid Remote ID with 25-byte payload");

    //////////////////////////////////////////////////////////////////////////
    // Test 2: Valid Service Descriptor with Location Message
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 2: Location Message Type ---");
    #200;
    send_nan_header();
    send_service_descriptor(
        48'h886919_9D9209,  // Correct Service ID
        8'h02,              // Instance ID
        8'd25,              // Payload length
        {8'h01, 8'h00, 8'hB4, 8'h14, 8'h00,  // Location message (type 1)
         8'hE0, 8'h93, 8'h04, 8'h00, 8'h20,  // Lat/Lon data
         8'hF1, 8'h24, 8'h00, 8'h64, 8'h00,
         8'h32, 8'h00, 8'h0A, 8'h05, 8'h06,
         8'h07, 8'h08, 8'hE8, 8'h03, 8'h00}
    );
    check_result(1'b1, 1'b1, 1'b1, 8'd25, "Location message type");

    //////////////////////////////////////////////////////////////////////////
    // Test 3: Wrong Service ID (should detect NAN but not match service)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 3: Wrong Service ID ---");
    #200;
    send_nan_header();
    send_service_descriptor(
        48'hDEADBEEF_CAFE,  // Wrong Service ID
        8'h03,
        8'd25,
        {25{8'hAA}}
    );
    check_result(1'b1, 1'b0, 1'b0, 8'd0, "Wrong service ID detected");

    //////////////////////////////////////////////////////////////////////////
    // Test 4: Invalid Length (service info length > 255)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 4: Invalid Service Info Length ---");
    #200;
    send_nan_header();
    // Send attribute with invalid length field
    send_tlv_header(8'h03, 16'd300);  // Length too large
    send_byte(8'h88, 1'b0);
    send_byte(8'h69, 1'b1);  // Truncate early
    #100;
    if (error_invalid_length || error_truncated_attr) begin
        $display("[PASS] Test %0d: Invalid length error detected", test_count + 1);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: Invalid length error not detected", test_count + 1);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 5: Multiple Attributes in Single Frame
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 5: Multiple Attributes ---");
    #200;
    send_nan_header();

    // First attribute: Master Indication (ID=0x00)
    send_tlv_header(8'h00, 16'd2);
    send_byte(8'h01, 1'b0);
    send_byte(8'h00, 1'b0);

    // Second attribute: Service Descriptor with Remote ID
    send_service_descriptor(
        48'h886919_9D9209,
        8'h04,
        8'd25,
        {8'h02, {24{8'h55}}}  // Auth message type
    );
    check_result(1'b1, 1'b1, 1'b1, 8'd25, "Multiple attributes with Remote ID");

    //////////////////////////////////////////////////////////////////////////
    // Test 6: Truncated Attribute (frame ends before payload complete)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 6: Truncated Attribute ---");
    #200;
    send_nan_header();
    send_tlv_header(8'h03, 16'd36);  // Claim 36 bytes
    send_byte(8'h88, 1'b0);
    send_byte(8'h69, 1'b0);
    send_byte(8'h19, 1'b0);
    send_byte(8'h9D, 1'b0);
    send_byte(8'h92, 1'b0);
    send_byte(8'h09, 1'b0);
    send_byte(8'h05, 1'b0);  // Instance ID
    send_byte(8'h00, 1'b1);  // LAST - truncated!
    #100;
    if (error_truncated_attr) begin
        $display("[PASS] Test %0d: Truncated attribute error detected", test_count + 1);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: Truncated attribute error not detected", test_count + 1);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 7: Minimum Valid Payload (1 byte)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 7: Minimum Valid Payload ---");
    #200;
    send_nan_header();
    send_service_descriptor(
        48'h886919_9D9209,
        8'h06,
        8'd1,               // Just 1 byte
        {8'h03, {24{8'h00}}}
    );
    check_result(1'b1, 1'b1, 1'b1, 8'd1, "Minimum 1-byte payload");

    //////////////////////////////////////////////////////////////////////////
    // Test 8: Maximum Valid Payload (25 bytes - ASTM F3411 standard)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 8: Maximum Valid Payload ---");
    #200;
    send_nan_header();
    send_service_descriptor(
        48'h886919_9D9209,
        8'h07,
        8'd25,
        {8'h04, 8'h00, 8'h00, 8'h00, 8'h00,  // System message (type 4)
         8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
         8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
         8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
         8'h00, 8'h00, 8'h00, 8'h00, 8'h00}
    );
    check_result(1'b1, 1'b1, 1'b1, 8'd25, "Maximum 25-byte payload");

    //////////////////////////////////////////////////////////////////////////
    // Test 9: Empty Service Info (0 bytes)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 9: Empty Service Info ---");
    #200;
    send_nan_header();
    send_service_descriptor(
        48'h886919_9D9209,
        8'h08,
        8'd0,               // No service info
        200'h0
    );
    check_result(1'b1, 1'b1, 1'b1, 8'd0, "Empty service info");

    //////////////////////////////////////////////////////////////////////////
    // Test 10: Non-NAN Action Frame (wrong category)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 10: Non-NAN Action Frame ---");
    #200;
    send_byte(8'h04, 1'b0);  // Category: Public Action (not Vendor)
    send_byte(8'h09, 1'b0);  // Action: Vendor Specific Protected
    send_byte(8'h00, 1'b1);  // End
    #100;
    if (!nan_frame_detected) begin
        $display("[PASS] Test %0d: Non-NAN frame rejected", test_count + 1);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: Non-NAN frame incorrectly detected", test_count + 1);
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

    if (fail_count == 0) begin
        $display("\nALL TESTS PASSED!");
    end else begin
        $display("\nSOME TESTS FAILED!");
    end

    $finish;
end

// Monitor payload bytes (for debug)
always @(posedge clk) begin
    if (payload_valid) begin
        $display("  [DEBUG] Payload byte: 0x%02X", payload_byte);
    end
end

endmodule
