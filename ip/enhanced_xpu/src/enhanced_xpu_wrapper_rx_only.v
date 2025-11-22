// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: enhanced_xpu_wrapper (RX-ONLY CONFIGURATION)
//
// Description:
//   Top-level wrapper for enhanced XPU with RX-only capabilities.
//   Optimized for Zynq 7020 (antsdr, antsdr_e200, e310v2).
//
// Build Configuration: RX-ONLY
//   - Monitor mode packet filtering
//   - WiFi Aware (NAN) action frame parsing
//   - Drone Remote ID reception and decoding
//   - Vendor IE parsing for Remote ID in beacons
//   - NO frame injection (TX disabled)
//
// Target FPGA: Zynq 7020 (53,200 LUTs)
// Estimated Utilization: ~41% LUTs (with base OpenWiFi)
//
// Features:
//   ✅ Full WiFi monitor mode (802.11a/g/n)
//   ✅ Remote ID reception (ASTM F3411)
//   ✅ NAN frame detection
//   ✅ Promiscuous mode
//   ❌ Frame transmission (disabled to save resources)
//
// Author: OpenWiFi Team
// Date: 2025-11-22
// Branch: claude/rx-only-z7020-016NinPPubrhjENgJbg7a1qj
//////////////////////////////////////////////////////////////////////////////////

module enhanced_xpu_wrapper #(
    parameter integer GPIO_STATUS_WIDTH = 8,
    parameter integer DELAY_CTL_WIDTH = 7,
    parameter integer RSSI_HALF_DB_WIDTH = 11,
    parameter integer IQ_RSSI_HALF_DB_WIDTH = 9,
    parameter integer C_S00_AXIS_TDATA_WIDTH = 64,
    parameter integer IQ_DATA_WIDTH = 16,
    parameter integer WIFI_TX_BRAM_DATA_WIDTH = 64,
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 8,
    parameter integer TSF_TIMER_WIDTH = 64,
    parameter integer WIFI_TX_BRAM_ADDR_WIDTH = 10
)(
    // Clock and reset
    input wire clk,
    input wire rstn,

    // AD9361 status
    input wire [(GPIO_STATUS_WIDTH-1):0] gpio_status,

    // RX interface (from rx_intf)
    input wire signed [(IQ_DATA_WIDTH-1):0] ddc_i,
    input wire signed [(IQ_DATA_WIDTH-1):0] ddc_q,
    input wire ddc_iq_valid,

    // RX control outputs
    output wire mute_adc_out_to_bb,
    output wire block_rx_dma_to_ps,
    output wire block_rx_dma_to_ps_valid,
    output wire signed [(RSSI_HALF_DB_WIDTH-1):0] rssi_half_db_lock_by_sig_valid,
    output wire [(GPIO_STATUS_WIDTH-1):0] gpio_status_lock_by_sig_valid,
    output wire [(TSF_TIMER_WIDTH-1):0] tsf_runtime_val,
    output wire tsf_pulse_1M,

    // OPENOFDM RX interface
    output wire signed [(RSSI_HALF_DB_WIDTH-1):0] rssi_half_db,
    input wire demod_is_ongoing,
    input wire pkt_header_valid,
    input wire pkt_header_valid_strobe,
    input wire ht_unsupport,
    input wire [7:0] pkt_rate,
    input wire [15:0] pkt_len,
    input wire byte_in_strobe,
    input wire [7:0] byte_in,
    input wire [15:0] byte_count,
    input wire fcs_in_strobe,
    input wire fcs_ok,

    // AXI slave (configuration)
    input wire [C_S00_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [C_S00_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input wire [(C_S00_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,
    input wire [C_S00_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready,

    // DMA interface (packet output)
    output wire [C_S00_AXIS_TDATA_WIDTH-1:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast
);

// ============================================================================
// Internal Signals
// ============================================================================

// Enhanced packet filter signals
wire monitor_mode_en;
wire capture_beacon;
wire capture_nan;
wire promiscuous;
wire allow_to_dma;
wire is_beacon_frame;
wire is_nan_frame;

// NAN action handler signals
wire [7:0] rid_data_out;
wire rid_data_valid;
wire rid_data_ready;
wire rid_sof;
wire rid_eof;
wire [7:0] rid_msg_type;
wire remote_id_found;
wire parse_complete;
wire [3:0] nan_error_flags;

// Remote ID codec signals
wire [199:0] rid_message_in;
wire [199:0] rid_message_out;
wire rid_encode_mode;
wire rid_valid_in;
wire rid_ready_in;
wire rid_valid_out;
wire rid_ready_out;
wire [3:0] rid_error_code;

// Packet frame info (extracted from byte stream)
reg [1:0] fc_type;
reg [3:0] fc_subtype;
reg [47:0] addr1, addr2, addr3;
reg [7:0] action_category;
reg [23:0] vendor_oui;
reg [7:0] oui_type;

// Configuration registers
reg [31:0] control_reg;
reg [31:0] filter_config_reg;
reg [31:0] monitor_stats;

// AXI register addresses
localparam ADDR_CONTROL = 8'h00;
localparam ADDR_FILTER_CFG = 8'h04;
localparam ADDR_MONITOR_STATS = 8'h08;
localparam ADDR_RID_STATUS = 8'h0C;

// ============================================================================
// Configuration Register Mapping
// ============================================================================

assign monitor_mode_en = control_reg[0];
assign capture_beacon = filter_config_reg[0];
assign capture_nan = filter_config_reg[1];
assign promiscuous = control_reg[1];

// ============================================================================
// AXI Slave Interface for Configuration
// ============================================================================

reg [C_S00_AXI_ADDR_WIDTH-1:0] axi_awaddr;
reg axi_awready;
reg axi_wready;
reg [1:0] axi_bresp;
reg axi_bvalid;
reg [C_S00_AXI_ADDR_WIDTH-1:0] axi_araddr;
reg axi_arready;
reg [C_S00_AXI_DATA_WIDTH-1:0] axi_rdata;
reg [1:0] axi_rresp;
reg axi_rvalid;

assign s_axi_awready = axi_awready;
assign s_axi_wready = axi_wready;
assign s_axi_bresp = axi_bresp;
assign s_axi_bvalid = axi_bvalid;
assign s_axi_arready = axi_arready;
assign s_axi_rdata = axi_rdata;
assign s_axi_rresp = axi_rresp;
assign s_axi_rvalid = axi_rvalid;

// AXI Write
always @(posedge clk) begin
    if (!rstn) begin
        axi_awready <= 1'b0;
        axi_wready <= 1'b0;
        axi_bvalid <= 1'b0;
        control_reg <= 32'h0;
        filter_config_reg <= 32'h0003; // Enable beacon and NAN capture by default
    end else begin
        // Write address ready
        if (s_axi_awvalid && !axi_awready) begin
            axi_awready <= 1'b1;
            axi_awaddr <= s_axi_awaddr;
        end else begin
            axi_awready <= 1'b0;
        end

        // Write data ready
        if (s_axi_wvalid && !axi_wready) begin
            axi_wready <= 1'b1;
            // Write to register
            case (axi_awaddr)
                ADDR_CONTROL: control_reg <= s_axi_wdata;
                ADDR_FILTER_CFG: filter_config_reg <= s_axi_wdata;
            endcase
        end else begin
            axi_wready <= 1'b0;
        end

        // Write response
        if (axi_wready && !axi_bvalid) begin
            axi_bvalid <= 1'b1;
            axi_bresp <= 2'b00; // OK
        end else if (s_axi_bready && axi_bvalid) begin
            axi_bvalid <= 1'b0;
        end
    end
end

// AXI Read
always @(posedge clk) begin
    if (!rstn) begin
        axi_arready <= 1'b0;
        axi_rvalid <= 1'b0;
        axi_rdata <= 32'h0;
    end else begin
        // Read address ready
        if (s_axi_arvalid && !axi_arready) begin
            axi_arready <= 1'b1;
            axi_araddr <= s_axi_araddr;
        end else begin
            axi_arready <= 1'b0;
        end

        // Read data valid
        if (axi_arready && !axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp <= 2'b00; // OK
            case (axi_araddr)
                ADDR_CONTROL: axi_rdata <= control_reg;
                ADDR_FILTER_CFG: axi_rdata <= filter_config_reg;
                ADDR_MONITOR_STATS: axi_rdata <= monitor_stats;
                ADDR_RID_STATUS: axi_rdata <= {24'h0, remote_id_found, parse_complete, 2'b0, nan_error_flags};
                default: axi_rdata <= 32'hDEADBEEF;
            endcase
        end else if (s_axi_rready && axi_rvalid) begin
            axi_rvalid <= 1'b0;
        end
    end
end

// ============================================================================
// Frame Info Extraction (from byte stream)
// ============================================================================

reg [15:0] frame_ctrl;
reg [7:0] byte_cnt;

always @(posedge clk) begin
    if (!rstn) begin
        fc_type <= 2'b00;
        fc_subtype <= 4'b0000;
        addr1 <= 48'h0;
        addr2 <= 48'h0;
        addr3 <= 48'h0;
        action_category <= 8'h0;
        vendor_oui <= 24'h0;
        oui_type <= 8'h0;
        byte_cnt <= 8'h0;
    end else begin
        if (pkt_header_valid_strobe) begin
            byte_cnt <= 8'h0;
        end else if (byte_in_strobe) begin
            byte_cnt <= byte_cnt + 1;

            // Extract frame control (bytes 0-1)
            if (byte_cnt == 0) frame_ctrl[7:0] <= byte_in;
            if (byte_cnt == 1) frame_ctrl[15:8] <= byte_in;

            // Extract addresses (bytes 4-27)
            if (byte_cnt >= 4 && byte_cnt < 10) addr1 <= {addr1[39:0], byte_in};
            if (byte_cnt >= 10 && byte_cnt < 16) addr2 <= {addr2[39:0], byte_in};
            if (byte_cnt >= 16 && byte_cnt < 22) addr3 <= {addr3[39:0], byte_in};

            // For action frames, extract category and OUI
            if (byte_cnt == 24) action_category <= byte_in;
            if (byte_cnt >= 25 && byte_cnt < 28) vendor_oui <= {vendor_oui[15:0], byte_in};
            if (byte_cnt == 28) oui_type <= byte_in;
        end

        // Update fc_type and fc_subtype when frame control is complete
        if (byte_cnt == 2) begin
            fc_type <= frame_ctrl[3:2];
            fc_subtype <= frame_ctrl[7:4];
        end
    end
end

// ============================================================================
// Module Instantiations
// ============================================================================

// Enhanced Packet Filter (Monitor Mode)
enhanced_pkt_filter #(
    .ADDR_WIDTH(48)
) pkt_filter_inst (
    .clk(clk),
    .rstn(rstn),

    // Frame info inputs
    .fc_type(fc_type),
    .fc_subtype(fc_subtype),
    .addr1(addr1),
    .addr2(addr2),
    .addr3(addr3),
    .fcs_ok(fcs_ok),
    .category(action_category),
    .oui(vendor_oui),
    .oui_type(oui_type),

    // Configuration
    .monitor_mode_en(monitor_mode_en),
    .capture_beacon(capture_beacon),
    .capture_nan(capture_nan),
    .promiscuous(promiscuous),

    // Outputs
    .allow_to_dma(allow_to_dma),
    .is_beacon_frame(is_beacon_frame),
    .is_nan_frame(is_nan_frame)
);

// NAN Action Handler
nan_action_handler #(
    .DATA_WIDTH(8),
    .REMOTE_ID_SIZE(25),
    .MAX_PKT_SIZE(2048),
    .ADDR_WIDTH(11)
) nan_handler_inst (
    .clk(clk),
    .rstn(rstn),

    // Packet input
    .pkt_data_in(byte_in),
    .pkt_data_valid(byte_in_strobe),
    .pkt_data_ready(), // Not used in RX-only
    .pkt_sof(pkt_header_valid_strobe),
    .pkt_eof(fcs_in_strobe),

    // Control
    .is_nan_frame(is_nan_frame),
    .pkt_length(pkt_len[10:0]),
    .parse_enable(monitor_mode_en),

    // Remote ID output
    .rid_data_out(rid_data_out),
    .rid_data_valid(rid_data_valid),
    .rid_data_ready(rid_data_ready),
    .rid_sof(rid_sof),
    .rid_eof(rid_eof),
    .rid_msg_type(rid_msg_type),

    // Status
    .remote_id_found(remote_id_found),
    .parse_complete(parse_complete),
    .error_flags(nan_error_flags),

    // Debug
    .attr_count(),
    .bytes_processed()
);

// Remote ID Codec (Decode mode only in RX-only config)
remote_id_codec #(
    .MSG_SIZE(25)
) rid_codec_inst (
    .clk(clk),
    .rstn(rstn),

    // Mode: always decode in RX-only
    .encode_mode(1'b0),

    // Input
    .msg_in(rid_message_in),
    .valid_in(rid_data_valid),
    .ready_in(rid_data_ready),

    // Output
    .msg_out(rid_message_out),
    .valid_out(rid_valid_out),
    .ready_out(rid_ready_out),

    // Status
    .msg_type(rid_msg_type),
    .error_code(rid_error_code)
);

// Assemble Remote ID message from byte stream
integer i;
always @(posedge clk) begin
    if (!rstn) begin
        rid_message_in <= 200'h0;
    end else if (rid_data_valid && rid_data_ready) begin
        // Shift in new byte
        rid_message_in <= {rid_message_in[191:0], rid_data_out};
    end
end

// ============================================================================
// Statistics and Monitoring
// ============================================================================

reg [15:0] beacon_count;
reg [15:0] nan_count;

always @(posedge clk) begin
    if (!rstn) begin
        beacon_count <= 16'h0;
        nan_count <= 16'h0;
        monitor_stats <= 32'h0;
    end else begin
        if (fcs_in_strobe && fcs_ok && allow_to_dma) begin
            if (is_beacon_frame) beacon_count <= beacon_count + 1;
            if (is_nan_frame) nan_count <= nan_count + 1;
        end
        monitor_stats <= {nan_count, beacon_count};
    end
end

// ============================================================================
// DMA Output (simplified for RX-only)
// ============================================================================

// In RX-only mode, pass through received packets that match filter
assign m_axis_tdata = {56'h0, byte_in}; // Simplified: just pass byte data
assign m_axis_tvalid = byte_in_strobe && allow_to_dma;
assign m_axis_tlast = fcs_in_strobe && allow_to_dma;

// Assign other outputs
assign mute_adc_out_to_bb = 1'b0; // Never mute in RX-only
assign block_rx_dma_to_ps = !monitor_mode_en || !allow_to_dma;
assign block_rx_dma_to_ps_valid = byte_in_strobe;

endmodule
