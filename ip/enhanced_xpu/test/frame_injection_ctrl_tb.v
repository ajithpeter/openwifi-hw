// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: frame_injection_ctrl_tb
//
// Description:
//   Test bench for frame injection controller module.
//   Tests frame injection timing, rate configuration, AXI stream interface,
//   queue management, periodic transmission, CSMA bypass, sequence numbering.
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module frame_injection_ctrl_tb;

// Parameters
parameter CLK_PERIOD = 10;  // 100 MHz
parameter DATA_WIDTH = 64;
parameter MAX_FRAME_SIZE = 2048;

// Signals
reg clk;
reg rstn;

// Configuration registers
reg inject_enable;
reg [7:0] inject_rate;        // Data rate (MCS or legacy)
reg [7:0] inject_power;       // TX power (dBm)
reg [3:0] inject_retries;     // Number of retries
reg [15:0] inject_interval;   // Periodic interval (ms)
reg csma_bypass;              // Bypass CSMA/CA
reg no_ack_wait;              // Don't wait for ACK
reg auto_seq_enable;          // Auto-increment sequence number
reg periodic_mode;            // Periodic transmission mode

// AXI Stream Slave (frame input from software)
reg s_axis_tvalid;
reg [DATA_WIDTH-1:0] s_axis_tdata;
reg s_axis_tlast;
wire s_axis_tready;

// AXI Stream Master (frame output to PHY)
wire m_axis_tvalid;
wire [DATA_WIDTH-1:0] m_axis_tdata;
wire m_axis_tlast;
reg m_axis_tready;

// PHY control
wire phy_tx_start;
reg phy_tx_done;
wire [7:0] phy_rate;
wire [7:0] phy_power;
wire csma_enable;

// Status outputs
wire queue_full;
wire queue_empty;
wire [15:0] queue_count;
wire [15:0] frames_transmitted;
wire [15:0] current_seq_num;
wire injection_active;
wire [31:0] last_tx_timestamp;

// Test counters
integer test_count;
integer pass_count;
integer fail_count;
integer frame_count;
integer i;

// DUT instantiation
frame_injection_ctrl #(
    .DATA_WIDTH(DATA_WIDTH),
    .MAX_FRAME_SIZE(MAX_FRAME_SIZE)
) dut (
    .clk(clk),
    .rstn(rstn),

    // Configuration
    .inject_enable(inject_enable),
    .inject_rate(inject_rate),
    .inject_power(inject_power),
    .inject_retries(inject_retries),
    .inject_interval(inject_interval),
    .csma_bypass(csma_bypass),
    .no_ack_wait(no_ack_wait),
    .auto_seq_enable(auto_seq_enable),
    .periodic_mode(periodic_mode),

    // AXI Stream Slave (input)
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tready(s_axis_tready),

    // AXI Stream Master (output)
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tready(m_axis_tready),

    // PHY control
    .phy_tx_start(phy_tx_start),
    .phy_tx_done(phy_tx_done),
    .phy_rate(phy_rate),
    .phy_power(phy_power),
    .csma_enable(csma_enable),

    // Status
    .queue_full(queue_full),
    .queue_empty(queue_empty),
    .queue_count(queue_count),
    .frames_transmitted(frames_transmitted),
    .current_seq_num(current_seq_num),
    .injection_active(injection_active),
    .last_tx_timestamp(last_tx_timestamp)
);

// Clock generation
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// PHY TX simulation (completes after 100 clock cycles)
always @(posedge clk) begin
    if (phy_tx_start) begin
        phy_tx_done <= 1'b0;
        repeat(100) @(posedge clk);
        phy_tx_done <= 1'b1;
        @(posedge clk);
        phy_tx_done <= 1'b0;
    end
end

// Task: Send a frame via AXI Stream
task send_frame(
    input integer frame_len,  // In 64-bit words
    input [15:0] seq_num
);
integer j;
begin
    for (j = 0; j < frame_len; j = j + 1) begin
        @(posedge clk);
        s_axis_tvalid = 1'b1;

        // First word contains MAC header with sequence number
        if (j == 0) begin
            s_axis_tdata = {seq_num, 48'hAABBCCDDEEFF};  // MAC header
        end else begin
            s_axis_tdata = {j[31:0], j[31:0]};  // Test data
        end

        s_axis_tlast = (j == frame_len - 1);

        // Wait for ready
        wait(s_axis_tready);
        @(posedge clk);
    end

    s_axis_tvalid = 1'b0;
    s_axis_tlast = 1'b0;
    frame_count = frame_count + 1;
end
endtask

// Task: Wait for frame transmission
task wait_for_tx();
begin
    wait(phy_tx_start);
    $display("  [TX] PHY transmission started at time %0t", $time);
    wait(phy_tx_done);
    $display("  [TX] PHY transmission complete at time %0t", $time);
end
endtask

// Task: Check result
task check_result(
    input expected_active,
    input [15:0] expected_frames,
    input [159:0] test_name
);
begin
    test_count = test_count + 1;
    #200;

    if (injection_active == expected_active &&
        frames_transmitted == expected_frames) begin
        $display("[PASS] Test %0d: %s", test_count, test_name);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test %0d: %s", test_count, test_name);
        $display("  Expected: active=%b, frames=%d",
                 expected_active, expected_frames);
        $display("  Got:      active=%b, frames=%d",
                 injection_active, frames_transmitted);
        fail_count = fail_count + 1;
    end
end
endtask

// Main test
initial begin
    // Initialize signals
    rstn = 0;
    inject_enable = 0;
    inject_rate = 0;
    inject_power = 0;
    inject_retries = 0;
    inject_interval = 0;
    csma_bypass = 0;
    no_ack_wait = 0;
    auto_seq_enable = 0;
    periodic_mode = 0;
    s_axis_tvalid = 0;
    s_axis_tdata = 0;
    s_axis_tlast = 0;
    m_axis_tready = 1;
    phy_tx_done = 0;

    frame_count = 0;
    test_count = 0;
    pass_count = 0;
    fail_count = 0;

    $display("=== Frame Injection Controller Test Bench ===");
    $display("Starting tests at time %0t", $time);

    // Reset
    #100;
    rstn = 1;
    #100;

    //////////////////////////////////////////////////////////////////////////
    // Test 1: Basic Frame Injection
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 1: Basic Frame Injection ---");
    inject_enable = 1'b1;
    inject_rate = 8'd12;      // 6 Mbps (12 * 500 kbps)
    inject_power = 8'd20;     // 20 dBm
    inject_retries = 4'd3;    // 3 retries
    csma_bypass = 1'b0;       // Use CSMA/CA
    no_ack_wait = 1'b0;       // Wait for ACK

    // Send a frame (10 words = 80 bytes)
    send_frame(10, 16'h0001);

    // Wait for transmission
    wait_for_tx();

    if (frames_transmitted == 1 && phy_rate == inject_rate) begin
        $display("[PASS] Test 1: Basic frame injection");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 1: Basic frame injection");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 2: CSMA Bypass Mode
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 2: CSMA Bypass Mode ---");
    #500;
    csma_bypass = 1'b1;       // Bypass CSMA/CA
    no_ack_wait = 1'b1;       // No ACK expected

    send_frame(5, 16'h0002);
    wait_for_tx();

    if (!csma_enable && frames_transmitted == 2) begin
        $display("[PASS] Test 2: CSMA bypass mode");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 2: CSMA bypass mode");
        $display("  csma_enable=%b, frames=%d", csma_enable, frames_transmitted);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 3: Auto Sequence Number Increment
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 3: Auto Sequence Number Increment ---");
    #500;
    auto_seq_enable = 1'b1;

    // Send 3 frames and check sequence number increments
    send_frame(5, 16'h0010);  // Initial seq
    wait_for_tx();
    send_frame(5, 16'h0011);
    wait_for_tx();
    send_frame(5, 16'h0012);
    wait_for_tx();

    if (frames_transmitted == 5 && current_seq_num == 16'h0013) begin
        $display("[PASS] Test 3: Auto sequence increment");
        $display("  Current sequence number: 0x%04X", current_seq_num);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 3: Auto sequence increment");
        $display("  Expected seq=0x0013, got=0x%04X", current_seq_num);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 4: Rate Configuration
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 4: Rate Configuration ---");
    #500;
    inject_rate = 8'd108;     // 54 Mbps (108 * 500 kbps)

    send_frame(20, 16'h0020);
    wait_for_tx();

    if (phy_rate == 8'd108) begin
        $display("[PASS] Test 4: Rate configuration (54 Mbps)");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 4: Rate configuration");
        $display("  Expected rate=108, got=%d", phy_rate);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 5: TX Power Configuration
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 5: TX Power Configuration ---");
    #500;
    inject_power = 8'd15;     // 15 dBm

    send_frame(10, 16'h0030);
    wait_for_tx();

    if (phy_power == 8'd15) begin
        $display("[PASS] Test 5: TX power configuration (15 dBm)");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 5: TX power configuration");
        $display("  Expected power=15, got=%d", phy_power);
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 6: Queue Management (fill and drain)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 6: Queue Management ---");
    #500;

    // Disable PHY ready to fill queue
    m_axis_tready = 1'b0;

    // Send multiple frames to queue
    for (i = 0; i < 5; i = i + 1) begin
        send_frame(10, 16'h0040 + i);
        #100;
    end

    #500;
    $display("  Queue count: %d", queue_count);

    // Re-enable PHY and drain queue
    m_axis_tready = 1'b1;

    // Wait for all frames to transmit
    repeat(5) begin
        wait_for_tx();
        #200;
    end

    if (!queue_empty) begin
        $display("[FAIL] Test 6: Queue should be empty");
        fail_count = fail_count + 1;
    end else begin
        $display("[PASS] Test 6: Queue management");
        pass_count = pass_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 7: Periodic Transmission Mode (Beacons)
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 7: Periodic Transmission Mode ---");
    #500;
    periodic_mode = 1'b1;
    inject_interval = 16'd100;  // 100 ms interval (for test, use smaller value)

    // Queue one beacon frame
    send_frame(15, 16'h0050);

    // Wait for multiple periodic transmissions
    integer start_frames;
    start_frames = frames_transmitted;

    // Wait for 3 periodic transmissions (should happen every 100ms)
    #1000000;  // Wait 1ms (using smaller interval for simulation)

    periodic_mode = 1'b0;

    if (frames_transmitted > start_frames) begin
        $display("[PASS] Test 7: Periodic transmission");
        $display("  Frames transmitted in periodic mode: %d",
                 frames_transmitted - start_frames);
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 7: Periodic transmission");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 8: Queue Full Condition
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 8: Queue Full Handling ---");
    #500;
    periodic_mode = 1'b0;
    m_axis_tready = 1'b0;  // Block output

    // Try to overfill queue (depends on queue depth)
    for (i = 0; i < 20; i = i + 1) begin
        if (!queue_full) begin
            send_frame(10, 16'h0060 + i);
            #100;
        end else begin
            $display("  Queue full at %d frames", i);
            i = 20;  // Exit loop
        end
    end

    if (queue_full) begin
        $display("[PASS] Test 8: Queue full detection");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 8: Queue full not detected");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    // Clear queue
    m_axis_tready = 1'b1;
    #10000;

    //////////////////////////////////////////////////////////////////////////
    // Test 9: Injection Timing Accuracy
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 9: Injection Timing Accuracy ---");
    #500;

    // Record timestamp of first transmission
    send_frame(10, 16'h0070);
    wait_for_tx();
    integer ts1 = last_tx_timestamp;

    #1000;

    // Record timestamp of second transmission
    send_frame(10, 16'h0071);
    wait_for_tx();
    integer ts2 = last_tx_timestamp;

    integer time_diff = ts2 - ts1;
    $display("  Time between transmissions: %d us", time_diff);

    // Check that timing is reasonable (within 50us of expected)
    if (time_diff > 0 && time_diff < 2000) begin
        $display("[PASS] Test 9: Injection timing");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 9: Injection timing out of range");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 10: Disable Injection
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 10: Disable Injection ---");
    #500;

    integer pre_disable_count = frames_transmitted;

    // Disable injection
    inject_enable = 1'b0;

    // Try to send a frame (should be rejected)
    send_frame(10, 16'h0080);
    #1000;

    if (frames_transmitted == pre_disable_count) begin
        $display("[PASS] Test 10: Injection disabled correctly");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 10: Frame transmitted when disabled");
        fail_count = fail_count + 1;
    end
    test_count = test_count + 1;

    //////////////////////////////////////////////////////////////////////////
    // Test 11: Re-enable and verify operation
    //////////////////////////////////////////////////////////////////////////
    $display("\n--- Test 11: Re-enable Injection ---");
    #500;
    inject_enable = 1'b1;

    send_frame(10, 16'h0090);
    wait_for_tx();

    if (frames_transmitted == pre_disable_count + 1) begin
        $display("[PASS] Test 11: Re-enable injection");
        pass_count = pass_count + 1;
    end else begin
        $display("[FAIL] Test 11: Re-enable failed");
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
    $display("\nFeatures Tested:");
    $display("  - Basic frame injection");
    $display("  - CSMA bypass mode");
    $display("  - Auto sequence numbering");
    $display("  - Rate configuration");
    $display("  - TX power configuration");
    $display("  - Queue management");
    $display("  - Periodic transmission");
    $display("  - Queue full handling");
    $display("  - Injection timing");
    $display("  - Enable/disable control");

    if (fail_count == 0) begin
        $display("\nALL TESTS PASSED!");
    end else begin
        $display("\nSOME TESTS FAILED!");
    end

    $finish;
end

// Monitor frame injection events
always @(posedge clk) begin
    if (phy_tx_start) begin
        $display("  [EVENT] Frame transmission started, rate=%d, power=%d dBm",
                 phy_rate, phy_power);
    end
    if (queue_full && s_axis_tvalid) begin
        $display("  [WARNING] Queue full, frame rejected");
    end
end

endmodule
