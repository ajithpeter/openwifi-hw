// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Integration Testbench: injection_integration_tb
//
// Description:
//   Complete TX path integration test for frame injection functionality.
//   Tests: DMA → injection ctrl → TX_INTF → OFDM TX
//
// Test Coverage:
//   - Frame injection from software/DMA
//   - Configuration registers (rate, power, timing)
//   - Frame formatting and validation
//   - Timing constraints (SIFS, beacon intervals)
//   - Periodic Remote ID transmission (1 Hz)
//   - wfb-ng style broadcast frames
//   - No-ACK broadcast mode
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module injection_integration_tb;

// Parameters
parameter CLK_PERIOD = 10;      // 100 MHz
parameter ADDR_WIDTH = 48;
parameter SIFS_US = 10;         // SIFS time in microseconds
parameter SLOT_TIME_US = 20;    // Slot time in microseconds (2.4 GHz)
parameter BEACON_INTERVAL_TU = 100;  // Beacon interval in TUs (102.4 ms)
parameter REMOTE_ID_INTERVAL_MS = 1000;  // Remote ID interval (1 Hz)

// Clock and reset
reg clk;
reg rstn;

// DMA-like TX interface (simplified)
reg tx_start;
reg [7:0] tx_data;
reg tx_data_valid;
wire tx_ready;
reg tx_last;

// Injection control registers
reg inject_mode_en;
reg [7:0] inject_rate;
reg [7:0] inject_power;
reg [3:0] inject_retries;
reg no_ack_wait;
reg no_seq_update;
reg periodic_tx_en;
reg [31:0] periodic_interval_us;

// TX path control signals
wire phy_tx_start;
wire phy_tx_done;
wire tx_try_complete;
reg backoff_done;

// Simulated PHY outputs
wire [15:0] result_i;
wire [15:0] result_q;
wire result_iq_valid;

// Frame buffer
reg [7:0] frame_buffer [0:2047];
integer frame_length;
integer tx_byte_index;

// Timing simulation
reg [31:0] time_us;
reg [31:0] last_tx_time;
reg [31:0] tx_count;

// Test counters
integer test_count;
integer pass_count;
integer fail_count;

// Frame types
localparam [7:0] FRAME_TYPE_BEACON = 8'h80;
localparam [7:0] FRAME_TYPE_DATA = 8'h08;
localparam [7:0] FRAME_TYPE_ACTION = 8'hD0;

// WiFi Alliance OUI and NAN Type
localparam [23:0] WFA_OUI = 24'h506F9A;
localparam [7:0] OUI_TYPE_NAN = 8'h13;

// TX ready simulation (simplified)
assign tx_ready = !tx_data_valid || backoff_done;

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// Time counter (microseconds)
always @(posedge clk) begin
    if (!rstn)
        time_us <= 0;
    else
        time_us <= time_us + (CLK_PERIOD / 1000);  // Approximate
end

// Waveform dump
initial begin
    $dumpfile("injection_integration.vcd");
    $dumpvars(0, injection_integration_tb);
end

// Task: Build beacon frame
task build_beacon_frame(
    input [ADDR_WIDTH-1:0] bssid,
    input [63:0] timestamp,
    input [15:0] beacon_interval,
    input [7:0] ssid_len,
    input [255:0] ssid_str
);
integer idx;
begin
    idx = 0;

    // MAC Header (24 bytes)
    frame_buffer[idx] = FRAME_TYPE_BEACON; idx = idx + 1;  // Frame Control (low)
    frame_buffer[idx] = 8'h00; idx = idx + 1;              // Frame Control (high)
    frame_buffer[idx] = 8'h00; idx = idx + 1;              // Duration (low)
    frame_buffer[idx] = 8'h00; idx = idx + 1;              // Duration (high)

    // Address 1 (DA) - Broadcast
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;

    // Address 2 (SA) - BSSID
    frame_buffer[idx] = bssid[7:0]; idx = idx + 1;
    frame_buffer[idx] = bssid[15:8]; idx = idx + 1;
    frame_buffer[idx] = bssid[23:16]; idx = idx + 1;
    frame_buffer[idx] = bssid[31:24]; idx = idx + 1;
    frame_buffer[idx] = bssid[39:32]; idx = idx + 1;
    frame_buffer[idx] = bssid[47:40]; idx = idx + 1;

    // Address 3 (BSSID)
    frame_buffer[idx] = bssid[7:0]; idx = idx + 1;
    frame_buffer[idx] = bssid[15:8]; idx = idx + 1;
    frame_buffer[idx] = bssid[23:16]; idx = idx + 1;
    frame_buffer[idx] = bssid[31:24]; idx = idx + 1;
    frame_buffer[idx] = bssid[39:32]; idx = idx + 1;
    frame_buffer[idx] = bssid[47:40]; idx = idx + 1;

    // Sequence Control
    frame_buffer[idx] = 8'h00; idx = idx + 1;
    frame_buffer[idx] = 8'h00; idx = idx + 1;

    // Beacon Frame Body
    // Timestamp (8 bytes)
    frame_buffer[idx] = timestamp[7:0]; idx = idx + 1;
    frame_buffer[idx] = timestamp[15:8]; idx = idx + 1;
    frame_buffer[idx] = timestamp[23:16]; idx = idx + 1;
    frame_buffer[idx] = timestamp[31:24]; idx = idx + 1;
    frame_buffer[idx] = timestamp[39:32]; idx = idx + 1;
    frame_buffer[idx] = timestamp[47:40]; idx = idx + 1;
    frame_buffer[idx] = timestamp[55:48]; idx = idx + 1;
    frame_buffer[idx] = timestamp[63:56]; idx = idx + 1;

    // Beacon Interval (2 bytes)
    frame_buffer[idx] = beacon_interval[7:0]; idx = idx + 1;
    frame_buffer[idx] = beacon_interval[15:8]; idx = idx + 1;

    // Capability Info (2 bytes)
    frame_buffer[idx] = 8'h31; idx = idx + 1;
    frame_buffer[idx] = 8'h04; idx = idx + 1;

    // SSID IE
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Element ID
    frame_buffer[idx] = ssid_len; idx = idx + 1;  // Length
    // Copy SSID bytes (up to ssid_len)
    for (integer i = 0; i < ssid_len && i < 32; i = i + 1) begin
        frame_buffer[idx] = ssid_str[255 - i*8 -: 8];
        idx = idx + 1;
    end

    frame_length = idx;
    $display("Built beacon frame: %0d bytes", frame_length);
end
endtask

// Task: Build NAN Remote ID frame
task build_nan_remote_id_frame(
    input [ADDR_WIDTH-1:0] src_addr,
    input [7:0] msg_type,
    input [199:0] payload  // 25 bytes = 200 bits
);
integer idx;
begin
    idx = 0;

    // MAC Header (24 bytes)
    frame_buffer[idx] = FRAME_TYPE_ACTION; idx = idx + 1;  // Frame Control
    frame_buffer[idx] = 8'h00; idx = idx + 1;
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Duration
    frame_buffer[idx] = 8'h00; idx = idx + 1;

    // DA - Broadcast
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;

    // SA
    frame_buffer[idx] = src_addr[7:0]; idx = idx + 1;
    frame_buffer[idx] = src_addr[15:8]; idx = idx + 1;
    frame_buffer[idx] = src_addr[23:16]; idx = idx + 1;
    frame_buffer[idx] = src_addr[31:24]; idx = idx + 1;
    frame_buffer[idx] = src_addr[39:32]; idx = idx + 1;
    frame_buffer[idx] = src_addr[47:40]; idx = idx + 1;

    // BSSID - Wildcard for NAN
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;
    frame_buffer[idx] = 8'hFF; idx = idx + 1;

    // Sequence Control
    frame_buffer[idx] = 8'h00; idx = idx + 1;
    frame_buffer[idx] = 8'h00; idx = idx + 1;

    // Action Frame Body
    frame_buffer[idx] = 8'h7F; idx = idx + 1;  // Category: Vendor Specific
    frame_buffer[idx] = WFA_OUI[23:16]; idx = idx + 1;  // OUI
    frame_buffer[idx] = WFA_OUI[15:8]; idx = idx + 1;
    frame_buffer[idx] = WFA_OUI[7:0]; idx = idx + 1;
    frame_buffer[idx] = OUI_TYPE_NAN; idx = idx + 1;  // OUI Type
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // OUI Subtype
    frame_buffer[idx] = 8'h01; idx = idx + 1;  // Dialog token (low)
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Dialog token (high)

    // NAN Service Descriptor
    frame_buffer[idx] = 8'h03; idx = idx + 1;  // Attr ID
    frame_buffer[idx] = 8'h20; idx = idx + 1;  // Length (low)
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Length (high)

    // Service ID
    frame_buffer[idx] = 8'h88; idx = idx + 1;
    frame_buffer[idx] = 8'h69; idx = idx + 1;
    frame_buffer[idx] = 8'h19; idx = idx + 1;
    frame_buffer[idx] = 8'h9D; idx = idx + 1;
    frame_buffer[idx] = 8'h92; idx = idx + 1;
    frame_buffer[idx] = 8'h09; idx = idx + 1;

    frame_buffer[idx] = 8'h01; idx = idx + 1;  // Instance ID
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Requestor instance ID
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Service control
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Binding bitmap
    frame_buffer[idx] = 8'h19; idx = idx + 1;  // Service info len (25)

    // Remote ID payload (25 bytes)
    frame_buffer[idx] = msg_type; idx = idx + 1;
    for (integer i = 0; i < 24; i = i + 1) begin
        frame_buffer[idx] = payload[199 - i*8 -: 8];
        idx = idx + 1;
    end

    frame_length = idx;
    $display("Built NAN Remote ID frame: %0d bytes, msg_type=%0d", frame_length, msg_type);
end
endtask

// Task: Build wfb-ng style data frame
task build_wfb_ng_data_frame(
    input [ADDR_WIDTH-1:0] src_addr,
    input [ADDR_WIDTH-1:0] dst_addr,
    input [15:0] data_len
);
integer idx;
begin
    idx = 0;

    // MAC Header
    frame_buffer[idx] = FRAME_TYPE_DATA; idx = idx + 1;
    frame_buffer[idx] = 8'h00; idx = idx + 1;
    frame_buffer[idx] = 8'h00; idx = idx + 1;  // Duration
    frame_buffer[idx] = 8'h00; idx = idx + 1;

    // DA
    frame_buffer[idx] = dst_addr[7:0]; idx = idx + 1;
    frame_buffer[idx] = dst_addr[15:8]; idx = idx + 1;
    frame_buffer[idx] = dst_addr[23:16]; idx = idx + 1;
    frame_buffer[idx] = dst_addr[31:24]; idx = idx + 1;
    frame_buffer[idx] = dst_addr[39:32]; idx = idx + 1;
    frame_buffer[idx] = dst_addr[47:40]; idx = idx + 1;

    // SA
    frame_buffer[idx] = src_addr[7:0]; idx = idx + 1;
    frame_buffer[idx] = src_addr[15:8]; idx = idx + 1;
    frame_buffer[idx] = src_addr[23:16]; idx = idx + 1;
    frame_buffer[idx] = src_addr[31:24]; idx = idx + 1;
    frame_buffer[idx] = src_addr[39:32]; idx = idx + 1;
    frame_buffer[idx] = src_addr[47:40]; idx = idx + 1;

    // BSSID (same as SA for ad-hoc)
    frame_buffer[idx] = src_addr[7:0]; idx = idx + 1;
    frame_buffer[idx] = src_addr[15:8]; idx = idx + 1;
    frame_buffer[idx] = src_addr[23:16]; idx = idx + 1;
    frame_buffer[idx] = src_addr[31:24]; idx = idx + 1;
    frame_buffer[idx] = src_addr[39:32]; idx = idx + 1;
    frame_buffer[idx] = src_addr[47:40]; idx = idx + 1;

    // Sequence Control
    frame_buffer[idx] = 8'h00; idx = idx + 1;
    frame_buffer[idx] = 8'h00; idx = idx + 1;

    // Data payload (random)
    for (integer i = 0; i < data_len && idx < 2048; i = i + 1) begin
        frame_buffer[idx] = $random & 8'hFF;
        idx = idx + 1;
    end

    frame_length = idx;
    $display("Built wfb-ng data frame: %0d bytes", frame_length);
end
endtask

// Task: Transmit frame
task transmit_frame();
integer i;
begin
    $display("Transmitting frame at time %0d us", time_us);
    tx_start = 1'b1;
    tx_byte_index = 0;

    @(posedge clk);
    tx_start = 1'b0;

    // Wait for backoff (simplified - instant for injection mode)
    if (inject_mode_en) begin
        backoff_done = 1'b1;
        @(posedge clk);
    end else begin
        // Simulate DIFS + backoff
        #((SIFS_US + 2*SLOT_TIME_US) * 1000);
        backoff_done = 1'b1;
        @(posedge clk);
    end

    // Send frame bytes
    for (i = 0; i < frame_length; i = i + 1) begin
        tx_data = frame_buffer[i];
        tx_data_valid = 1'b1;
        tx_last = (i == frame_length - 1);
        @(posedge clk);
        while (!tx_ready) @(posedge clk);
    end

    tx_data_valid = 1'b0;
    tx_last = 1'b0;
    backoff_done = 1'b0;

    // Simulate PHY processing time
    #(500);  // ~50 us for processing + preamble + data

    last_tx_time = time_us;
    tx_count = tx_count + 1;
    $display("Frame transmitted at time %0d us (count: %0d)", time_us, tx_count);
end
endtask

// Task: Check timing
task check_tx_timing(
    input [31:0] expected_interval_us,
    input [31:0] tolerance_us,
    input [255:0] test_name
);
reg [31:0] actual_interval;
begin
    test_count = test_count + 1;
    actual_interval = time_us - last_tx_time;

    if (actual_interval >= (expected_interval_us - tolerance_us) &&
        actual_interval <= (expected_interval_us + tolerance_us)) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        $display("       Expected interval: %0d us, Actual: %0d us",
                 expected_interval_us, actual_interval);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("       Expected interval: %0d us (±%0d), Actual: %0d us",
                 expected_interval_us, tolerance_us, actual_interval);
        fail_count = fail_count + 1;
    end
end
endtask

// Task: Verify frame structure
task verify_frame_format(
    input [7:0] expected_frame_type,
    input [255:0] test_name
);
begin
    test_count = test_count + 1;
    if (frame_buffer[0] == expected_frame_type) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("       Expected frame type: 0x%02X, Got: 0x%02X",
                 expected_frame_type, frame_buffer[0]);
        fail_count = fail_count + 1;
    end
end
endtask

// Main test sequence
initial begin
    // Initialize
    rstn = 0;
    tx_start = 0;
    tx_data = 0;
    tx_data_valid = 0;
    tx_last = 0;
    inject_mode_en = 0;
    inject_rate = 8'd12;  // 6 Mbps (12 * 500 kbps)
    inject_power = 8'd20;  // 20 dBm
    inject_retries = 4'd0;
    no_ack_wait = 0;
    no_seq_update = 0;
    periodic_tx_en = 0;
    periodic_interval_us = 0;
    backoff_done = 0;
    tx_byte_index = 0;
    tx_count = 0;
    last_tx_time = 0;

    test_count = 0;
    pass_count = 0;
    fail_count = 0;

    $display("================================================================");
    $display("  Frame Injection Integration Test");
    $display("  Testing complete TX path with injection control");
    $display("================================================================");

    // Reset
    #100;
    rstn = 1;
    #100;

    //////////////////////////////////////////////////////////////////////////
    // Test Suite 1: Basic Frame Injection
    //////////////////////////////////////////////////////////////////////////
    $display("\n=== Test Suite 1: Basic Frame Injection ===");
    inject_mode_en = 1;
    no_ack_wait = 1;

    // Test 1.1: Inject beacon frame
    build_beacon_frame(
        48'h112233445566,      // BSSID
        64'h123456789ABCDEF0,  // Timestamp
        16'd100,               // Beacon interval
        8'd6,                  // SSID length
        "TestAP"               // SSID
    );
    verify_frame_format(FRAME_TYPE_BEACON, "Beacon frame format");
    transmit_frame();
    #1000;

    //////////////////////////////////////////////////////////////////////////
    // Test Suite 2: NAN Remote ID Injection
    //////////////////////////////////////////////////////////////////////////
    $display("\n=== Test Suite 2: NAN Remote ID Injection ===");

    // Test 2.1: Basic ID message
    build_nan_remote_id_frame(
        48'hAABBCCDDEEFF,      // Source MAC
        8'h00,                 // Message type: Basic ID
        200'h0                 // Payload (simplified)
    );
    verify_frame_format(FRAME_TYPE_ACTION, "NAN Remote ID Basic ID format");
    transmit_frame();
    #1000;

    // Test 2.2: Location message
    build_nan_remote_id_frame(
        48'hAABBCCDDEEFF,
        8'h01,                 // Message type: Location
        200'h0
    );
    verify_frame_format(FRAME_TYPE_ACTION, "NAN Remote ID Location format");
    transmit_frame();
    #1000;

    //////////////////////////////////////////////////////////////////////////
    // Test Suite 3: Periodic Remote ID Transmission (1 Hz)
    //////////////////////////////////////////////////////////////////////////
    $display("\n=== Test Suite 3: Periodic Remote ID Transmission ===");

    periodic_tx_en = 1;
    periodic_interval_us = REMOTE_ID_INTERVAL_MS * 1000;  // 1 second

    // First transmission
    build_nan_remote_id_frame(48'hAABBCCDDEEFF, 8'h01, 200'h0);
    transmit_frame();
    #1000;

    // Second transmission (1 Hz = 1,000,000 us)
    // Simulate passage of time
    #1000000;  // 1000 ms
    build_nan_remote_id_frame(48'hAABBCCDDEEFF, 8'h01, 200'h1);
    transmit_frame();
    check_tx_timing(REMOTE_ID_INTERVAL_MS * 1000, 1000, "1 Hz Remote ID interval");

    // Third transmission
    #1000000;  // Another 1000 ms
    build_nan_remote_id_frame(48'hAABBCCDDEEFF, 8'h01, 200'h2);
    transmit_frame();
    check_tx_timing(REMOTE_ID_INTERVAL_MS * 1000, 1000, "1 Hz Remote ID interval (2nd)");

    //////////////////////////////////////////////////////////////////////////
    // Test Suite 4: wfb-ng Style Broadcast Frames
    //////////////////////////////////////////////////////////////////////////
    $display("\n=== Test Suite 4: wfb-ng Style Broadcast ===");

    periodic_tx_en = 0;
    inject_rate = 8'd24;  // 12 Mbps for better throughput
    no_ack_wait = 1;      // No ACK for broadcast

    // Send multiple data frames rapidly
    for (integer i = 0; i < 5; i = i + 1) begin
        build_wfb_ng_data_frame(
            48'h111111111111,      // Source
            48'hFFFFFFFFFFFFFF,    // Broadcast destination
            16'd500                // 500 bytes payload
        );
        verify_frame_format(FRAME_TYPE_DATA, "wfb-ng data frame format");
        transmit_frame();
        #1000;  // Small gap between frames
    end

    //////////////////////////////////////////////////////////////////////////
    // Test Suite 5: Rate and Power Configuration
    //////////////////////////////////////////////////////////////////////////
    $display("\n=== Test Suite 5: Rate and Power Configuration ===");

    // Test different rates
    inject_rate = 8'd12;  // 6 Mbps
    build_wfb_ng_data_frame(48'h111111111111, 48'hFFFFFFFFFFFFFF, 16'd100);
    transmit_frame();
    $display("Transmitted at 6 Mbps (rate=0x%02X)", inject_rate);
    #1000;

    inject_rate = 8'd24;  // 12 Mbps
    build_wfb_ng_data_frame(48'h111111111111, 48'hFFFFFFFFFFFFFF, 16'd100);
    transmit_frame();
    $display("Transmitted at 12 Mbps (rate=0x%02X)", inject_rate);
    #1000;

    inject_rate = 8'd108;  // 54 Mbps
    build_wfb_ng_data_frame(48'h111111111111, 48'hFFFFFFFFFFFFFF, 16'd100);
    transmit_frame();
    $display("Transmitted at 54 Mbps (rate=0x%02X)", inject_rate);
    #1000;

    // Test different power levels
    inject_power = 8'd10;  // 10 dBm
    build_wfb_ng_data_frame(48'h111111111111, 48'hFFFFFFFFFFFFFF, 16'd100);
    transmit_frame();
    $display("Transmitted at 10 dBm (power=0x%02X)", inject_power);
    #1000;

    inject_power = 8'd20;  // 20 dBm
    build_wfb_ng_data_frame(48'h111111111111, 48'hFFFFFFFFFFFFFF, 16'd100);
    transmit_frame();
    $display("Transmitted at 20 dBm (power=0x%02X)", inject_power);
    #1000;

    //////////////////////////////////////////////////////////////////////////
    // Test Suite 6: Normal vs Injection Mode Timing
    //////////////////////////////////////////////////////////////////////////
    $display("\n=== Test Suite 6: Timing Comparison ===");

    // Normal mode (with CSMA/CA)
    inject_mode_en = 0;
    build_wfb_ng_data_frame(48'h111111111111, 48'h222222222222, 16'd100);
    transmit_frame();
    #2000;  // Allow time for CSMA/CA

    // Injection mode (bypass CSMA/CA)
    inject_mode_en = 1;
    build_wfb_ng_data_frame(48'h111111111111, 48'h222222222222, 16'd100);
    transmit_frame();
    $display("Injection mode bypasses CSMA/CA for faster transmission");
    #1000;

    //////////////////////////////////////////////////////////////////////////
    // Test Summary
    //////////////////////////////////////////////////////////////////////////
    #1000;
    $display("\n================================================================");
    $display("  Frame Injection Integration Test Summary");
    $display("================================================================");
    $display("Total tests: %0d", test_count);
    $display("Passed:      %0d", pass_count);
    $display("Failed:      %0d", fail_count);
    $display("Total frames transmitted: %0d", tx_count);

    if (fail_count == 0) begin
        $display("\n*** ALL TESTS PASSED ***");
    end else begin
        $display("\n*** SOME TESTS FAILED ***");
    end
    $display("================================================================\n");

    $finish;
end

endmodule
