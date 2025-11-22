// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////////////////////
// Corrected Testbench: vendor_ie_codec_tb
//
// Description:
//   Comprehensive test bench for Vendor IE codec module.
//   Tests both TX (encode) and RX (decode) modes with parallel interface.
//
// Module Interface:
//   - TX: 25-byte Remote ID message → 31-byte Vendor IE
//   - RX: 31-byte Vendor IE → 25-byte Remote ID message (if valid)
//   - Parallel word-based (not streaming byte-based)
//
// Author: OpenWiFi Team (Corrected)
// Date: 2025-11-22
////////////////////////////////////////////////////////////////////////////////

module vendor_ie_codec_tb;

// Parameters
parameter CLK_PERIOD = 10;  // 100 MHz

// Clock and reset
reg clk;
reg rstn;

// Control signals
reg mode;           // 0=TX, 1=RX
reg start;
reg oui_override;
reg [23:0] oui_config;
reg [7:0] oui_type_config;

// TX Interface
reg [199:0] tx_remote_id_msg;
wire [247:0] tx_ie_output;

// RX Interface
reg [247:0] rx_ie_input;
wire [199:0] rx_remote_id_msg;

// Status outputs
wire busy, done, valid, error;
wire [7:0] ie_element_id, ie_length, ie_oui_type, error_code;
wire [23:0] ie_oui;

// Test tracking
integer test_count = 0;
integer pass_count = 0;
integer fail_count = 0;

// DUT Instantiation
vendor_ie_codec dut (
    .clk(clk),
    .rstn(rstn),
    .mode(mode),
    .start(start),
    .busy(busy),
    .done(done),
    .valid(valid),
    .error(error),
    .oui_config(oui_config),
    .oui_type_config(oui_type_config),
    .oui_override(oui_override),
    .tx_remote_id_msg(tx_remote_id_msg),
    .tx_ie_output(tx_ie_output),
    .rx_ie_input(rx_ie_input),
    .rx_remote_id_msg(rx_remote_id_msg),
    .ie_element_id(ie_element_id),
    .ie_length(ie_length),
    .ie_oui(ie_oui),
    .ie_oui_type(ie_oui_type),
    .error_code(error_code)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Test Task: TX Encoding
task test_tx_encode(
    input [199:0] payload,
    input use_custom_oui,
    input [23:0] custom_oui,
    input [7:0] custom_type,
    input [8*20:1] test_name
);
begin
    test_count = test_count + 1;

    // Setup inputs
    mode = 1'b0;  // TX mode
    tx_remote_id_msg = payload;
    oui_override = use_custom_oui ? 1'b1 : 1'b0;
    if (use_custom_oui) begin
        oui_config = custom_oui;
        oui_type_config = custom_type;
    end

    // Wait for stable input
    #1;

    // Trigger operation
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    // Wait for done
    wait(done);
    @(posedge clk);

    // Verify outputs
    if (valid && !error && ie_element_id == 8'hDD && ie_length == 8'h1D) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);

        // Additional verification
        $display("       Element ID: 0x%02X (expected 0xDD)", ie_element_id);
        $display("       Length: %0d (expected 29)", ie_length);
        $display("       OUI: 0x%06X", ie_oui);
        $display("       OUI Type: 0x%02X", ie_oui_type);
        $display("       IE Output (first 6 bytes): 0x%02X%02X%02X%02X%02X%02X",
                 tx_ie_output[7:0], tx_ie_output[15:8], tx_ie_output[23:16],
                 tx_ie_output[31:24], tx_ie_output[39:32], tx_ie_output[47:40]);

        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("       Expected: valid=1, error=0, ID=0xDD, Len=0x1D");
        $display("       Got:      valid=%b, error=%b, ID=0x%02X, Len=0x%02X",
                 valid, error, ie_element_id, ie_length);
        fail_count = fail_count + 1;
    end

    // Reset for next test
    @(posedge clk);
    @(posedge clk);
end
endtask

// Test Task: RX Decoding with Validation
task test_rx_decode(
    input [247:0] ie_input,
    input expect_valid,
    input expect_error,
    input [7:0] expect_error_code,
    input [8*20:1] test_name
);
begin
    test_count = test_count + 1;

    // Setup inputs
    mode = 1'b1;  // RX mode
    rx_ie_input = ie_input;
    oui_override = 1'b0;  // Use defaults

    // Wait for stable input
    #1;

    // Trigger operation
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;

    // Wait for done
    wait(done);
    @(posedge clk);

    // Verify outputs
    if (valid == expect_valid && error == expect_error &&
        (expect_error ? error_code == expect_error_code : 1'b1)) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);

        if (expect_valid) begin
            $display("       OUI: 0x%06X", ie_oui);
            $display("       OUI Type: 0x%02X", ie_oui_type);
            $display("       Payload (first 8 bytes): 0x%02X%02X%02X%02X%02X%02X%02X%02X",
                     rx_remote_id_msg[7:0], rx_remote_id_msg[15:8], rx_remote_id_msg[23:16],
                     rx_remote_id_msg[31:24], rx_remote_id_msg[39:32], rx_remote_id_msg[47:40],
                     rx_remote_id_msg[55:48], rx_remote_id_msg[63:56]);
        end else if (expect_error) begin
            $display("       Error Code: 0x%02X (expected 0x%02X)", error_code, expect_error_code);
        end

        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        if (expect_error) begin
            $display("       Expected: valid=%b, error=%b, error_code=0x%02X",
                     expect_valid, expect_error, expect_error_code);
            $display("       Got:      valid=%b, error=%b, error_code=0x%02X",
                     valid, error, error_code);
        end else begin
            $display("       Expected: valid=1, error=0");
            $display("       Got:      valid=%b, error=%b", valid, error);
        end
        fail_count = fail_count + 1;
    end

    // Reset for next test
    @(posedge clk);
    @(posedge clk);
end
endtask

// Helper task for round-trip test
task test_roundtrip();
reg [199:0] reference_payload;
reg [247:0] encoded_ie;
reg [199:0] decoded_payload;
integer i;
begin
    test_count = test_count + 1;

    // Create test payload: 0x00, 0x01, 0x02, ..., 0x18
    for (i = 0; i < 25; i = i + 1) begin
        reference_payload[i*8 +: 8] = i[7:0];
    end

    $display("\n--- Round-trip Test: TX → RX ---");

    // TX: Encode payload to IE
    mode = 1'b0;
    tx_remote_id_msg = reference_payload;
    oui_override = 1'b0;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    wait(done);
    @(posedge clk);
    encoded_ie = tx_ie_output;

    if (!valid || error) begin
        $display("[FAIL] Test %0d: Round-trip (TX failed)", test_count);
        fail_count = fail_count + 1;
        return;
    end

    $display("TX Phase: Payload → IE");
    $display("  IE Header: [0]=0x%02X, [1]=0x%02X, [2]=0x%02X, [3]=0x%02X, [4]=0x%02X, [5]=0x%02X",
             encoded_ie[7:0], encoded_ie[15:8], encoded_ie[23:16],
             encoded_ie[31:24], encoded_ie[39:32], encoded_ie[47:40]);

    // RX: Decode IE back to payload
    @(posedge clk);
    @(posedge clk);

    mode = 1'b1;
    rx_ie_input = encoded_ie;
    oui_override = 1'b0;
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    wait(done);
    @(posedge clk);
    decoded_payload = rx_remote_id_msg;

    if (!valid || error) begin
        $display("[FAIL] Test %0d: Round-trip (RX failed)", test_count);
        $display("  Error: valid=%b, error=%b, error_code=0x%02X", valid, error, error_code);
        fail_count = fail_count + 1;
        return;
    end

    $display("RX Phase: IE → Payload");
    $display("  Decoded OUI: 0x%06X (expected 0x506F9A)", ie_oui);
    $display("  Decoded Type: 0x%02X (expected 0x09)", ie_oui_type);

    // Verify payload matches
    if (decoded_payload == reference_payload) begin
        $display("[PASS] Test %0d: Round-trip encoding/decoding", test_count);
        $display("  Payload verification: PASSED (25 bytes match)");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: Round-trip encoding/decoding", test_count);
        $display("  Payload mismatch!");
        for (i = 0; i < 25; i = i + 1) begin
            if (decoded_payload[i*8 +: 8] != reference_payload[i*8 +: 8]) begin
                $display("    Byte %0d: Expected 0x%02X, Got 0x%02X",
                         i, reference_payload[i*8 +: 8], decoded_payload[i*8 +: 8]);
            end
        end
        fail_count = fail_count + 1;
    end
end
endtask

// Main test procedure
initial begin
    // Initialize
    rstn = 0;
    clk = 0;
    mode = 0;
    start = 0;
    oui_override = 0;
    oui_config = 24'h0;
    oui_type_config = 8'h0;
    tx_remote_id_msg = 200'h0;
    rx_ie_input = 248'h0;

    $display("===============================================");
    $display("  Vendor IE Codec - Corrected Test Bench");
    $display("===============================================");
    $display("Starting at time %0t", $time);
    $display("");

    // Reset sequence
    #100;
    rstn = 1;
    #100;

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 1: TX Mode - Default OUI
    ///////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Group 1: TX Mode (Default OUI 0x506F9A) ---");
    test_tx_encode(
        200'h18_17_16_15_14_13_12_11_10_0F_0E_0D_0C_0B_0A_09_08_07_06_05_04_03_02_01_00,
        1'b0, 24'h0, 8'h0,
        "TX: Default OUI encoding"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 2: TX Mode - Custom OUI
    ///////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Group 2: TX Mode (Custom OUI 0xAABBCC) ---");
    test_tx_encode(
        200'hFF_FE_FD_FC_FB_FA_F9_F8_F7_F6_F5_F4_F3_F2_F1_F0_EF_EE_ED_EC_EB_EA_E9_E8_E7,
        1'b1, 24'hAABBCC, 8'h42,
        "TX: Custom OUI encoding"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 3: RX Mode - Valid IE (Default OUI)
    ///////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Group 3: RX Mode (Valid IE) ---");
    // Create valid IE: [0xDD, 0x1D, 0x9A, 0x6F, 0x50, 0x09, then 25 bytes payload]
    test_rx_decode(
        248'h00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_09_50_6F_9A_1D_DD,
        1'b1, 1'b0, 8'h00,
        "RX: Valid IE decode"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 4: RX Mode - Invalid Element ID
    ///////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Group 4: RX Mode (Error Cases) ---");
    test_rx_decode(
        248'h00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_09_50_6F_9A_1D_AA,
        1'b0, 1'b1, 8'h01,  // ERR_INVALID_ID
        "RX: Invalid Element ID error"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 5: RX Mode - Invalid Length
    ///////////////////////////////////////////////////////////////////////////
    test_rx_decode(
        248'h00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_09_50_6F_9A_1E_DD,
        1'b0, 1'b1, 8'h02,  // ERR_INVALID_LENGTH
        "RX: Invalid Length error"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 6: RX Mode - Invalid OUI
    ///////////////////////////////////////////////////////////////////////////
    test_rx_decode(
        248'h00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_09_00_00_00_1D_DD,
        1'b0, 1'b1, 8'h03,  // ERR_INVALID_OUI
        "RX: Invalid OUI error"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 7: RX Mode - Invalid OUI Type
    ///////////////////////////////////////////////////////////////////////////
    test_rx_decode(
        248'h00_01_02_03_04_05_06_07_08_09_0A_0B_0C_0D_0E_0F_10_11_12_13_14_15_16_17_18_FF_50_6F_9A_1D_DD,
        1'b0, 1'b1, 8'h04,  // ERR_INVALID_TYPE
        "RX: Invalid OUI Type error"
    );

    ///////////////////////////////////////////////////////////////////////////
    // Test Group 8: Round-trip TX → RX
    ///////////////////////////////////////////////////////////////////////////
    test_roundtrip();

    ///////////////////////////////////////////////////////////////////////////
    // Test Summary
    ///////////////////////////////////////////////////////////////////////////
    #500;
    $display("\n===============================================");
    $display("  Test Summary");
    $display("===============================================");
    $display("Total Tests: %0d", test_count);
    $display("Passed:      %0d", pass_count);
    $display("Failed:      %0d", fail_count);

    if (fail_count == 0) begin
        $display("\n✓ ALL TESTS PASSED!");
    end else begin
        $display("\n✗ SOME TESTS FAILED!");
    end

    $display("===============================================\n");

    $finish;
end

endmodule
