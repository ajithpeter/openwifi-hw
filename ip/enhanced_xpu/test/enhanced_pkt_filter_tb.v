// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: enhanced_pkt_filter_tb
//
// Description:
//   Test bench for enhanced packet filter module.
//   Tests monitor mode, NAN detection, beacon filtering, and promiscuous mode.
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module enhanced_pkt_filter_tb;

// Parameters
parameter ADDR_WIDTH = 48;
parameter CLK_PERIOD = 10;  // 100 MHz

// Signals
reg clk;
reg rstn;
reg [15:0] frame_control;
reg [1:0] fc_type;
reg [3:0] fc_subtype;
reg [ADDR_WIDTH-1:0] addr1;
reg [ADDR_WIDTH-1:0] addr2;
reg [ADDR_WIDTH-1:0] addr3;
reg [15:0] seq_ctrl;
reg fcs_ok;
reg pkt_header_valid_strobe;
reg [7:0] category;
reg [23:0] oui;
reg [7:0] oui_type;

// Configuration
reg monitor_mode_en;
reg capture_mgmt;
reg capture_ctrl;
reg capture_data;
reg capture_beacon;
reg capture_probe_req;
reg capture_probe_resp;
reg capture_nan;
reg capture_auth;
reg capture_deauth;
reg capture_assoc;
reg capture_fcs_fail;
reg promiscuous;
reg [ADDR_WIDTH-1:0] filter_addr;

// Outputs
wire allow_to_dma;
wire block_to_ps;
wire [7:0] packet_type;
wire is_beacon_frame;
wire is_nan_frame;
wire is_remote_id_frame;
wire [7:0] frame_subtype_out;

// Test counters
integer test_count;
integer pass_count;
integer fail_count;

// DUT instantiation
enhanced_pkt_filter #(
    .ADDR_WIDTH(ADDR_WIDTH)
) dut (
    .clk(clk),
    .rstn(rstn),
    .frame_control(frame_control),
    .fc_type(fc_type),
    .fc_subtype(fc_subtype),
    .addr1(addr1),
    .addr2(addr2),
    .addr3(addr3),
    .seq_ctrl(seq_ctrl),
    .fcs_ok(fcs_ok),
    .pkt_header_valid_strobe(pkt_header_valid_strobe),
    .category(category),
    .oui(oui),
    .oui_type(oui_type),
    .monitor_mode_en(monitor_mode_en),
    .capture_mgmt(capture_mgmt),
    .capture_ctrl(capture_ctrl),
    .capture_data(capture_data),
    .capture_beacon(capture_beacon),
    .capture_probe_req(capture_probe_req),
    .capture_probe_resp(capture_probe_resp),
    .capture_nan(capture_nan),
    .capture_auth(capture_auth),
    .capture_deauth(capture_deauth),
    .capture_assoc(capture_assoc),
    .capture_fcs_fail(capture_fcs_fail),
    .promiscuous(promiscuous),
    .filter_addr(filter_addr),
    .allow_to_dma(allow_to_dma),
    .block_to_ps(block_to_ps),
    .packet_type(packet_type),
    .is_beacon_frame(is_beacon_frame),
    .is_nan_frame(is_nan_frame),
    .is_remote_id_frame(is_remote_id_frame),
    .frame_subtype_out(frame_subtype_out)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Test vectors
task send_frame(
    input [1:0] fc_type_in,
    input [3:0] fc_subtype_in,
    input [ADDR_WIDTH-1:0] da,
    input [ADDR_WIDTH-1:0] sa,
    input fcs_valid,
    input [7:0] cat,
    input [23:0] oui_in,
    input [7:0] oui_type_in
);
begin
    @(posedge clk);
    fc_type = fc_type_in;
    fc_subtype = fc_subtype_in;
    addr1 = da;
    addr2 = sa;
    fcs_ok = fcs_valid;
    category = cat;
    oui = oui_in;
    oui_type = oui_type_in;
    pkt_header_valid_strobe = 1'b1;
    @(posedge clk);
    pkt_header_valid_strobe = 1'b0;
    @(posedge clk);
    @(posedge clk);
end
endtask

// Check result task
task check_result(
    input expected_allow,
    input expected_beacon,
    input expected_nan,
    input [79:0] test_name
);
begin
    test_count = test_count + 1;
    if (allow_to_dma == expected_allow &&
        is_beacon_frame == expected_beacon &&
        is_nan_frame == expected_nan) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("  Expected: allow=%b, beacon=%b, nan=%b",
                 expected_allow, expected_beacon, expected_nan);
        $display("  Got:      allow=%b, beacon=%b, nan=%b",
                 allow_to_dma, is_beacon_frame, is_nan_frame);
        fail_count = fail_count + 1;
    end
end
endtask

// Main test
initial begin
    // Initialize signals
    rstn = 0;
    frame_control = 0;
    fc_type = 0;
    fc_subtype = 0;
    addr1 = 0;
    addr2 = 0;
    addr3 = 0;
    seq_ctrl = 0;
    fcs_ok = 1;
    pkt_header_valid_strobe = 0;
    category = 0;
    oui = 0;
    oui_type = 0;

    monitor_mode_en = 0;
    capture_mgmt = 0;
    capture_ctrl = 0;
    capture_data = 0;
    capture_beacon = 0;
    capture_probe_req = 0;
    capture_probe_resp = 0;
    capture_nan = 0;
    capture_auth = 0;
    capture_deauth = 0;
    capture_assoc = 0;
    capture_fcs_fail = 0;
    promiscuous = 0;
    filter_addr = 48'h001122334455;

    test_count = 0;
    pass_count = 0;
    fail_count = 0;

    $display("=== Enhanced Packet Filter Test Bench ===");
    $display("Starting tests at time %0t", $time);

    // Reset
    #100;
    rstn = 1;
    #100;

    //////////////////////////////////////////////////////////////////////////
    // Test 1: Monitor Mode - Beacon Capture
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Suite 1: Beacon Capture ---");
    monitor_mode_en = 1;
    capture_beacon = 1;

    send_frame(
        2'b00,                      // Type: Management
        4'h8,                       // Subtype: Beacon
        48'hFFFFFFFFFFFFFF,         // DA: Broadcast
        48'h112233445566,           // SA
        1'b1,                       // FCS OK
        8'h00,                      // Category (N/A)
        24'h000000,                 // OUI (N/A)
        8'h00                       // OUI Type (N/A)
    );
    check_result(1'b1, 1'b1, 1'b0, "Beacon frame capture");

    //////////////////////////////////////////////////////////////////////////
    // Test 2: Monitor Mode - NAN Action Frame
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Suite 2: NAN Action Frame ---");
    capture_mgmt = 1;
    capture_nan = 1;

    send_frame(
        2'b00,                      // Type: Management
        4'hD,                       // Subtype: Action
        48'hFFFFFFFFFFFFFF,         // DA: Broadcast
        48'h112233445566,           // SA
        1'b1,                       // FCS OK
        8'h7F,                      // Category: Vendor Specific
        24'h506F9A,                 // OUI: WiFi Alliance
        8'h13                       // OUI Type: NAN
    );
    check_result(1'b1, 1'b0, 1'b1, "NAN action frame detection");

    //////////////////////////////////////////////////////////////////////////
    // Test 3: Promiscuous Mode
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Suite 3: Promiscuous Mode ---");
    promiscuous = 1;

    send_frame(
        2'b10,                      // Type: Data
        4'h0,                       // Subtype: Data
        48'h998877665544,           // DA: Different address
        48'h112233445566,           // SA
        1'b1,                       // FCS OK
        8'h00,
        24'h000000,
        8'h00
    );
    check_result(1'b1, 1'b0, 1'b0, "Promiscuous mode accepts all");

    //////////////////////////////////////////////////////////////////////////
    // Test 4: FCS Failure Filtering
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test Suite 4: FCS Failure ---");
    promiscuous = 0;
    capture_fcs_fail = 0;

    send_frame(
        2'b00,                      // Type: Management
        4'h8,                       // Subtype: Beacon
        48'hFFFFFFFFFFFFFF,         // DA: Broadcast
        48'h112233445566,           // SA
        1'b0,                       // FCS FAIL
        8'h00,
        24'h000000,
        8'h00
    );
    check_result(1'b0, 1'b1, 1'b0, "FCS failure blocked");

    // Allow FCS failures
    capture_fcs_fail = 1;
    send_frame(
        2'b00,                      // Type: Management
        4'h8,                       // Subtype: Beacon
        48'hFFFFFFFFFFFFFF,         // DA: Broadcast
        48'h112233445566,           // SA
        1'b0,                       // FCS FAIL
        8'h00,
        24'h000000,
        8'h00
    );
    check_result(1'b1, 1'b1, 1'b0, "FCS failure allowed when enabled");

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
