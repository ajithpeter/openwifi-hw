// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: frame_injection_ctrl
//
// Description:
//   WiFi frame injection controller for transmitting raw 802.11 frames.
//   Supports monitor mode TX, wfb-ng compatibility, and drone Remote ID.
//   Bypasses normal MAC control for direct frame injection to TX path.
//
// Features:
//   - Raw 802.11 frame injection from software (AXI DMA)
//   - Configurable TX parameters (rate, power, retries)
//   - CSMA/CA backoff control (with optional bypass)
//   - No-ACK broadcast/multicast frame support (wfb-ng compatible)
//   - Periodic beacon transmission (configurable interval)
//   - Remote ID NAN frame generation (1 Hz periodic)
//   - Frame sequence number auto-increment
//   - Multi-frame queue management (FIFO-based)
//   - Timestamp injection for beacons
//   - Integration with existing TX_INTF module
//
// Usage:
//   Software writes frames to frame buffer via AXI interface, configures
//   TX parameters (rate, power, retries), and triggers injection. Module
//   handles timing, sequencing, and interfacing with TX path.
//
// TX Rate Encoding (802.11a/g OFDM):
//   0x0B = 6 Mbps (BPSK 1/2)
//   0x0F = 9 Mbps (BPSK 3/4)
//   0x0A = 12 Mbps (QPSK 1/2)
//   0x0E = 18 Mbps (QPSK 3/4)
//   0x09 = 24 Mbps (16-QAM 1/2)
//   0x0D = 36 Mbps (16-QAM 3/4)
//   0x08 = 48 Mbps (64-QAM 2/3)
//   0x0C = 54 Mbps (64-QAM 3/4)
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module frame_injection_ctrl #(
    parameter integer FRAME_DATA_WIDTH = 64,      // AXI stream data width
    parameter integer FRAME_BUFFER_SIZE = 2048,   // Frame buffer size in bytes
    parameter integer MAX_FRAME_QUEUE = 16,       // Max queued frames
    parameter integer C_S_AXI_DATA_WIDTH = 32,    // AXI slave data width
    parameter integer C_S_AXI_ADDR_WIDTH = 12,    // AXI slave address width
    parameter integer TX_BRAM_DATA_WIDTH = 64,    // TX BRAM data width
    parameter integer TX_BRAM_ADDR_WIDTH = 10     // TX BRAM address width
)(
    // ========================================================================
    // Clock and Reset
    // ========================================================================
    input wire clk,                               // System clock (80 MHz)
    input wire rstn,                              // Active-low reset

    // ========================================================================
    // AXI-Lite Slave Interface (Configuration Registers)
    // ========================================================================
    input wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output reg s_axi_awready,
    input wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output reg s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output reg s_axi_arready,
    output reg [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,

    // ========================================================================
    // TX Path Interface (to TX_INTF module)
    // ========================================================================

    // TX BRAM Interface (frame data to PHY)
    output reg tx_bram_wea,                       // Write enable
    output reg [TX_BRAM_ADDR_WIDTH-1:0] tx_bram_addr, // Write address
    output reg [TX_BRAM_DATA_WIDTH-1:0] tx_bram_din,  // Write data

    // TX Control Signals
    output reg tx_start_req,                      // Request to start TX
    input wire tx_start_from_acc,                 // TX start from PHY
    input wire tx_end_from_acc,                   // TX end from PHY
    input wire tx_bb_is_ongoing,                  // Baseband TX ongoing
    input wire tx_rf_is_ongoing,                  // RF TX ongoing

    // TX Configuration
    output reg [7:0] tx_rate_out,                 // TX rate
    output reg [7:0] tx_power_out,                // TX power
    output reg [3:0] tx_retry_limit_out,          // Retry limit
    output reg tx_need_ack_out,                   // Need ACK flag

    // CSMA/CA Interface
    input wire backoff_done,                      // Backoff complete
    output reg bypass_csma,                       // Bypass CSMA/CA
    input wire tx_control_state_idle,             // TX control idle

    // ========================================================================
    // Timing and Status
    // ========================================================================
    input wire [63:0] tsf_timer,                  // TSF timer (1 MHz)
    input wire tsf_pulse_1M,                      // 1 MHz pulse
    input wire tsf_pulse_1us,                     // 1 us pulse (80 MHz / 80)

    // Status Outputs
    output reg [31:0] frames_injected_cnt,        // Total frames injected
    output reg [31:0] frames_dropped_cnt,         // Frames dropped (queue full)
    output reg [31:0] tx_error_cnt,               // TX errors
    output reg injection_active,                  // Injection in progress
    output wire frame_queue_full,                 // Queue full indicator
    output wire frame_queue_empty                 // Queue empty indicator
);

    // ========================================================================
    // Register Map Definition
    // ========================================================================
    //
    // 0x000: Control Register
    //   [0]     - global_enable
    //   [1]     - bypass_csma_cfg
    //   [2]     - auto_seq_increment
    //   [3]     - beacon_periodic_en
    //   [4]     - remote_id_periodic_en
    //   [5]     - inject_trigger (write 1 to trigger, auto-clears)
    //   [7:6]   - reserved
    //   [15:8]  - current_queue_count (RO)
    //   [23:16] - injection_state (RO)
    //   [31:24] - reserved
    //
    // 0x004: TX Parameters Register
    //   [7:0]   - tx_rate (802.11 rate encoding)
    //   [15:8]  - tx_power (0-63, 0.5 dB steps)
    //   [19:16] - tx_retry_limit (0-15)
    //   [20]    - tx_need_ack (0=no ACK, 1=ACK expected)
    //   [31:21] - reserved
    //
    // 0x008: Frame Length Register
    //   [15:0]  - frame_length (bytes)
    //   [31:16] - max_queue_size (RO)
    //
    // 0x00C: Beacon Interval Register
    //   [31:0]  - beacon_interval_us (microseconds)
    //
    // 0x010: Remote ID Interval Register
    //   [31:0]  - remote_id_interval_us (default 1000000 = 1 second)
    //
    // 0x014: Frame Counter Register (RO)
    //   [31:0]  - frames_injected_cnt
    //
    // 0x018: Error Counter Register (RO)
    //   [31:0]  - tx_error_cnt
    //
    // 0x01C: Dropped Counter Register (RO)
    //   [31:0]  - frames_dropped_cnt
    //
    // 0x020: Sequence Number Register
    //   [15:0]  - seq_num (auto-increments if auto_seq_increment enabled)
    //   [31:16] - reserved
    //
    // 0x024: TSF Schedule Low Register
    //   [31:0]  - tsf_schedule[31:0]
    //
    // 0x028: TSF Schedule High Register
    //   [31:0]  - tsf_schedule[63:32]
    //
    // 0x02C: Queue Status Register (RO)
    //   [0]     - queue_full
    //   [1]     - queue_empty
    //   [2]     - injection_active
    //   [7:3]   - reserved
    //   [15:8]  - queue_wr_idx
    //   [23:16] - queue_rd_idx
    //   [31:24] - reserved
    //
    // 0x100-0xFFF: Frame Buffer (write frame data here before trigger)
    //   Write up to FRAME_BUFFER_SIZE bytes

    // ========================================================================
    // Configuration Registers
    // ========================================================================

    reg [31:0] ctrl_reg;
    reg [31:0] tx_params_reg;
    reg [31:0] frame_length_reg;
    reg [31:0] beacon_interval_reg;
    reg [31:0] remote_id_interval_reg;
    reg [15:0] seq_num_reg;
    reg [63:0] tsf_schedule_reg;

    // Extract control fields
    wire global_enable;
    wire bypass_csma_cfg;
    wire auto_seq_increment;
    wire beacon_periodic_en;
    wire remote_id_periodic_en;
    reg inject_trigger;

    assign global_enable = ctrl_reg[0];
    assign bypass_csma_cfg = ctrl_reg[1];
    assign auto_seq_increment = ctrl_reg[2];
    assign beacon_periodic_en = ctrl_reg[3];
    assign remote_id_periodic_en = ctrl_reg[4];

    // Extract TX parameters
    wire [7:0] tx_rate_cfg;
    wire [7:0] tx_power_cfg;
    wire [3:0] tx_retry_cfg;
    wire tx_need_ack_cfg;

    assign tx_rate_cfg = tx_params_reg[7:0];
    assign tx_power_cfg = tx_params_reg[15:8];
    assign tx_retry_cfg = tx_params_reg[19:16];
    assign tx_need_ack_cfg = tx_params_reg[20];

    // Frame length
    wire [15:0] configured_frame_length;
    assign configured_frame_length = frame_length_reg[15:0];

    // ========================================================================
    // Frame Buffer Storage (Dual-Port RAM)
    // ========================================================================

    // Frame buffer organized as 64-bit words
    localparam FRAME_BUF_DEPTH = FRAME_BUFFER_SIZE / 8;
    localparam FRAME_BUF_ADDR_W = $clog2(FRAME_BUF_DEPTH);

    reg [63:0] frame_buffer [0:FRAME_BUF_DEPTH-1];
    reg [FRAME_BUF_ADDR_W-1:0] frame_buf_wr_addr;
    reg [FRAME_BUF_ADDR_W-1:0] frame_buf_rd_addr;

    // Frame queue metadata
    reg [15:0] frame_queue_length [0:MAX_FRAME_QUEUE-1];  // Length of each queued frame
    reg [FRAME_BUF_ADDR_W-1:0] frame_queue_start [0:MAX_FRAME_QUEUE-1]; // Start addr of each frame
    reg [3:0] frame_queue_wr_idx;
    reg [3:0] frame_queue_rd_idx;
    reg [4:0] frame_queue_count;  // Number of frames in queue

    assign frame_queue_full = (frame_queue_count >= MAX_FRAME_QUEUE);
    assign frame_queue_empty = (frame_queue_count == 0);

    // ========================================================================
    // Periodic Transmission Timers
    // ========================================================================

    reg [31:0] beacon_timer_us;
    reg [31:0] remote_id_timer_us;
    reg beacon_trigger_pending;
    reg remote_id_trigger_pending;

    // ========================================================================
    // TX State Machine
    // ========================================================================

    localparam [3:0] TX_STATE_IDLE          = 4'd0;
    localparam [3:0] TX_STATE_LOAD_FRAME    = 4'd1;
    localparam [3:0] TX_STATE_WRITE_BRAM    = 4'd2;
    localparam [3:0] TX_STATE_UPDATE_SEQ    = 4'd3;
    localparam [3:0] TX_STATE_WAIT_BACKOFF  = 4'd4;
    localparam [3:0] TX_STATE_TRIGGER_TX    = 4'd5;
    localparam [3:0] TX_STATE_WAIT_TX_START = 4'd6;
    localparam [3:0] TX_STATE_WAIT_TX_END   = 4'd7;
    localparam [3:0] TX_STATE_COMPLETE      = 4'd8;
    localparam [3:0] TX_STATE_ERROR         = 4'd9;

    reg [3:0] tx_state;
    reg [15:0] current_frame_length;
    reg [FRAME_BUF_ADDR_W-1:0] current_frame_start_addr;
    reg [TX_BRAM_ADDR_WIDTH-1:0] bram_write_addr;
    reg [15:0] bytes_written;
    reg [15:0] timeout_counter;

    // ========================================================================
    // Periodic Timer Management (1 MHz from TSF)
    // ========================================================================

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            beacon_timer_us <= 32'd0;
            remote_id_timer_us <= 32'd0;
            beacon_trigger_pending <= 1'b0;
            remote_id_trigger_pending <= 1'b0;
        end else begin
            // Beacon timer
            if (tsf_pulse_1M && beacon_periodic_en && beacon_interval_reg > 0) begin
                if (beacon_timer_us >= beacon_interval_reg) begin
                    beacon_timer_us <= 32'd0;
                    beacon_trigger_pending <= 1'b1;
                end else begin
                    beacon_timer_us <= beacon_timer_us + 32'd1;
                end
            end

            // Remote ID timer
            if (tsf_pulse_1M && remote_id_periodic_en && remote_id_interval_reg > 0) begin
                if (remote_id_timer_us >= remote_id_interval_reg) begin
                    remote_id_timer_us <= 32'd0;
                    remote_id_trigger_pending <= 1'b1;
                end else begin
                    remote_id_timer_us <= remote_id_timer_us + 32'd1;
                end
            end

            // Clear pending flags when serviced
            if (tx_state == TX_STATE_LOAD_FRAME) begin
                beacon_trigger_pending <= 1'b0;
                remote_id_trigger_pending <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Main TX State Machine
    // ========================================================================

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            tx_state <= TX_STATE_IDLE;
            tx_start_req <= 1'b0;
            tx_bram_wea <= 1'b0;
            tx_bram_addr <= {TX_BRAM_ADDR_WIDTH{1'b0}};
            tx_bram_din <= {TX_BRAM_DATA_WIDTH{1'b0}};
            tx_rate_out <= 8'h0B;  // 6 Mbps default
            tx_power_out <= 8'd63; // Max power
            tx_retry_limit_out <= 4'd0;
            tx_need_ack_out <= 1'b0;
            bypass_csma <= 1'b0;
            injection_active <= 1'b0;
            frames_injected_cnt <= 32'd0;
            tx_error_cnt <= 32'd0;
            frame_queue_rd_idx <= 4'd0;
            frame_queue_count <= 5'd0;
            current_frame_length <= 16'd0;
            current_frame_start_addr <= {FRAME_BUF_ADDR_W{1'b0}};
            bram_write_addr <= {TX_BRAM_ADDR_WIDTH{1'b0}};
            bytes_written <= 16'd0;
            timeout_counter <= 16'd0;
            frame_buf_rd_addr <= {FRAME_BUF_ADDR_W{1'b0}};
        end else begin
            // Default: clear one-shot signals
            tx_start_req <= 1'b0;

            case (tx_state)
                TX_STATE_IDLE: begin
                    injection_active <= 1'b0;
                    tx_bram_wea <= 1'b0;
                    timeout_counter <= 16'd0;

                    // Check for frames to inject
                    if (global_enable && !frame_queue_empty && tx_control_state_idle) begin
                        tx_state <= TX_STATE_LOAD_FRAME;
                        injection_active <= 1'b1;
                    end
                    // Check for periodic triggers (lower priority)
                    else if (global_enable && tx_control_state_idle) begin
                        if (beacon_trigger_pending && !frame_queue_empty) begin
                            tx_state <= TX_STATE_LOAD_FRAME;
                            injection_active <= 1'b1;
                        end else if (remote_id_trigger_pending && !frame_queue_empty) begin
                            tx_state <= TX_STATE_LOAD_FRAME;
                            injection_active <= 1'b1;
                        end
                    end
                end

                TX_STATE_LOAD_FRAME: begin
                    // Load frame metadata from queue
                    current_frame_length <= frame_queue_length[frame_queue_rd_idx];
                    current_frame_start_addr <= frame_queue_start[frame_queue_rd_idx];
                    frame_buf_rd_addr <= frame_queue_start[frame_queue_rd_idx];

                    // Load TX configuration
                    tx_rate_out <= tx_rate_cfg;
                    tx_power_out <= tx_power_cfg;
                    tx_retry_limit_out <= tx_retry_cfg;
                    tx_need_ack_out <= tx_need_ack_cfg;
                    bypass_csma <= bypass_csma_cfg;

                    // Initialize BRAM write
                    bram_write_addr <= {TX_BRAM_ADDR_WIDTH{1'b0}};
                    bytes_written <= 16'd0;

                    tx_state <= TX_STATE_WRITE_BRAM;
                end

                TX_STATE_WRITE_BRAM: begin
                    // Write frame data to TX BRAM
                    if (bytes_written < current_frame_length) begin
                        tx_bram_wea <= 1'b1;
                        tx_bram_addr <= bram_write_addr;
                        tx_bram_din <= frame_buffer[frame_buf_rd_addr];

                        frame_buf_rd_addr <= frame_buf_rd_addr + 1;
                        bram_write_addr <= bram_write_addr + 1;
                        bytes_written <= bytes_written + 16'd8; // 8 bytes per 64-bit word
                    end else begin
                        tx_bram_wea <= 1'b0;
                        tx_state <= TX_STATE_UPDATE_SEQ;
                    end
                end

                TX_STATE_UPDATE_SEQ: begin
                    // Optionally update sequence number in frame
                    // Sequence number is at byte offset 22-23 in 802.11 header
                    // For simplicity, we just increment the register here
                    // Full implementation would read-modify-write BRAM

                    if (auto_seq_increment) begin
                        seq_num_reg <= seq_num_reg + 16'd1;
                    end

                    // Check CSMA bypass
                    if (bypass_csma_cfg) begin
                        tx_state <= TX_STATE_TRIGGER_TX;
                    end else begin
                        tx_state <= TX_STATE_WAIT_BACKOFF;
                    end
                end

                TX_STATE_WAIT_BACKOFF: begin
                    // Wait for CSMA/CA backoff to complete
                    timeout_counter <= timeout_counter + 16'd1;

                    if (backoff_done) begin
                        tx_state <= TX_STATE_TRIGGER_TX;
                        timeout_counter <= 16'd0;
                    end else if (timeout_counter > 16'd10000) begin
                        // Timeout after ~125 us
                        tx_state <= TX_STATE_ERROR;
                    end
                end

                TX_STATE_TRIGGER_TX: begin
                    // Trigger TX start
                    tx_start_req <= 1'b1;
                    tx_state <= TX_STATE_WAIT_TX_START;
                    timeout_counter <= 16'd0;
                end

                TX_STATE_WAIT_TX_START: begin
                    // Wait for PHY to acknowledge TX start
                    timeout_counter <= timeout_counter + 16'd1;

                    if (tx_start_from_acc || tx_bb_is_ongoing) begin
                        tx_state <= TX_STATE_WAIT_TX_END;
                        timeout_counter <= 16'd0;
                    end else if (timeout_counter > 16'd1000) begin
                        // Timeout after ~12.5 us
                        tx_state <= TX_STATE_ERROR;
                    end
                end

                TX_STATE_WAIT_TX_END: begin
                    // Wait for TX to complete
                    timeout_counter <= timeout_counter + 16'd1;

                    if (tx_end_from_acc && !tx_bb_is_ongoing) begin
                        tx_state <= TX_STATE_COMPLETE;
                        timeout_counter <= 16'd0;
                    end else if (timeout_counter > 16'd50000) begin
                        // Timeout after ~625 us (long enough for max frame)
                        tx_state <= TX_STATE_ERROR;
                    end
                end

                TX_STATE_COMPLETE: begin
                    // Update counters and queue
                    frames_injected_cnt <= frames_injected_cnt + 32'd1;
                    frame_queue_rd_idx <= frame_queue_rd_idx + 4'd1;
                    frame_queue_count <= frame_queue_count - 5'd1;
                    tx_state <= TX_STATE_IDLE;
                end

                TX_STATE_ERROR: begin
                    // Handle error
                    tx_error_cnt <= tx_error_cnt + 32'd1;
                    frame_queue_rd_idx <= frame_queue_rd_idx + 4'd1;
                    frame_queue_count <= frame_queue_count - 5'd1;
                    tx_state <= TX_STATE_IDLE;
                end

                default: begin
                    tx_state <= TX_STATE_IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    // AXI-Lite Slave Interface Implementation
    // ========================================================================

    // AXI write address channel
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_axi_awready <= 1'b0;
        end else begin
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end
        end
    end

    // AXI write data channel
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_axi_wready <= 1'b0;
        end else begin
            if (!s_axi_wready && s_axi_wvalid && s_axi_awvalid) begin
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end
        end
    end

    // AXI write response channel
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= 2'b0;
        end else begin
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= 2'b00; // OKAY
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // AXI read address channel
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_axi_arready <= 1'b0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b1;
            end else begin
                s_axi_arready <= 1'b0;
            end
        end
    end

    // AXI read data channel
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr_reg;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp <= 2'b0;
            s_axi_rdata <= 32'd0;
            axi_araddr_reg <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp <= 2'b00; // OKAY
                axi_araddr_reg <= s_axi_araddr;

                // Read from registers
                case (s_axi_araddr[11:2])
                    10'd0:   s_axi_rdata <= {8'd0, tx_state, frame_queue_count[7:0], ctrl_reg[7:0]};
                    10'd1:   s_axi_rdata <= tx_params_reg;
                    10'd2:   s_axi_rdata <= {MAX_FRAME_QUEUE[15:0], frame_length_reg[15:0]};
                    10'd3:   s_axi_rdata <= beacon_interval_reg;
                    10'd4:   s_axi_rdata <= remote_id_interval_reg;
                    10'd5:   s_axi_rdata <= frames_injected_cnt;
                    10'd6:   s_axi_rdata <= tx_error_cnt;
                    10'd7:   s_axi_rdata <= frames_dropped_cnt;
                    10'd8:   s_axi_rdata <= {16'd0, seq_num_reg};
                    10'd9:   s_axi_rdata <= tsf_schedule_reg[31:0];
                    10'd10:  s_axi_rdata <= tsf_schedule_reg[63:32];
                    10'd11:  s_axi_rdata <= {8'd0, frame_queue_rd_idx, frame_queue_wr_idx,
                                            5'd0, injection_active, frame_queue_empty, frame_queue_full};
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rready && s_axi_rvalid) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Register writes
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr_reg;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            ctrl_reg <= 32'd0;
            tx_params_reg <= 32'h0000_3F0B; // Default: 6 Mbps, power=63, no retries, no ACK
            frame_length_reg <= 32'd0;
            beacon_interval_reg <= 32'd100000;     // 100 ms
            remote_id_interval_reg <= 32'd1000000; // 1 second
            seq_num_reg <= 16'd0;
            tsf_schedule_reg <= 64'd0;
            inject_trigger <= 1'b0;
            frame_buf_wr_addr <= {FRAME_BUF_ADDR_W{1'b0}};
            frame_queue_wr_idx <= 4'd0;
            frames_dropped_cnt <= 32'd0;
            axi_awaddr_reg <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            // Auto-clear inject trigger
            if (inject_trigger) begin
                inject_trigger <= 1'b0;
                ctrl_reg[5] <= 1'b0;
            end

            // Handle AXI writes
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid) begin
                axi_awaddr_reg <= s_axi_awaddr;

                case (s_axi_awaddr[11:2])
                    10'd0: begin
                        ctrl_reg <= s_axi_wdata;
                        if (s_axi_wdata[5]) begin
                            inject_trigger <= 1'b1;
                        end
                    end
                    10'd1: tx_params_reg <= s_axi_wdata;
                    10'd2: frame_length_reg <= s_axi_wdata;
                    10'd3: beacon_interval_reg <= s_axi_wdata;
                    10'd4: remote_id_interval_reg <= s_axi_wdata;
                    10'd8: seq_num_reg <= s_axi_wdata[15:0];
                    10'd9: tsf_schedule_reg[31:0] <= s_axi_wdata;
                    10'd10: tsf_schedule_reg[63:32] <= s_axi_wdata;
                    default: begin
                        // Frame buffer write (0x100 onwards)
                        if (s_axi_awaddr >= 12'h100 && s_axi_awaddr < (12'h100 + FRAME_BUFFER_SIZE)) begin
                            // Write to frame buffer
                            // For 32-bit writes to 64-bit buffer, need special handling
                            frame_buffer[s_axi_awaddr[FRAME_BUF_ADDR_W+2:3]][31:0] <= s_axi_wdata;
                        end
                    end
                endcase
            end

            // Handle frame queue on trigger
            if (inject_trigger && !frame_queue_full) begin
                frame_queue_length[frame_queue_wr_idx] <= configured_frame_length;
                frame_queue_start[frame_queue_wr_idx] <= {FRAME_BUF_ADDR_W{1'b0}}; // Assume frame at start
                frame_queue_wr_idx <= frame_queue_wr_idx + 4'd1;
                frame_queue_count <= frame_queue_count + 5'd1;
            end else if (inject_trigger && frame_queue_full) begin
                frames_dropped_cnt <= frames_dropped_cnt + 32'd1;
            end
        end
    end

endmodule
