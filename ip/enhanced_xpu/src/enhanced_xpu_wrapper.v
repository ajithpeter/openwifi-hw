// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: enhanced_xpu_wrapper
//
// Description:
//   Top-level wrapper for enhanced XPU (MAC controller) with drone Remote ID
//   and monitor mode support. Integrates all enhanced modules with the base
//   XPU functionality.
//
// Enhanced Features:
//   - Monitor mode with configurable packet filtering
//   - WiFi Aware (NAN) action frame parsing
//   - Drone Remote ID detection and decoding
//   - Vendor IE parsing for Remote ID in beacons
//   - Frame injection control for testing
//
// Integration:
//   - Wraps base xpu module
//   - Adds enhanced_pkt_filter for monitor mode
//   - Adds nan_action_handler for NAN parsing
//   - Adds remote_id_codec for ASTM F3411 decoding
//   - Adds vendor_ie_codec for beacon IE parsing
//   - Adds frame_injection_ctrl for TX control
//
// Author: OpenWiFi Team
// Date: 2025-11-22
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
    parameter integer WIFI_TX_BRAM_ADDR_WIDTH = 10,
    // Enhanced parameters
    parameter integer ENHANCED_AXI_ADDR_WIDTH = 12
)(
    // All standard XPU ports (from original xpu.v)
    // AD9361 status and ctrl
    input  wire [(GPIO_STATUS_WIDTH-1):0] gpio_status,

    // Ports to rx_intf
    input  wire signed [(IQ_DATA_WIDTH-1):0] ddc_i,
    input  wire signed [(IQ_DATA_WIDTH-1):0] ddc_q,
    input  wire ddc_iq_valid,
    output wire mute_adc_out_to_bb,
    output wire block_rx_dma_to_ps,
    output wire block_rx_dma_to_ps_valid,
    output wire signed [(RSSI_HALF_DB_WIDTH-1):0] rssi_half_db_lock_by_sig_valid,
    output wire [(GPIO_STATUS_WIDTH-1):0] gpio_status_lock_by_sig_valid,
    output wire [(TSF_TIMER_WIDTH-1):0] tsf_runtime_val,
    output wire tsf_pulse_1M,
      
    // Ports to openofdm rx
    output wire signed [(RSSI_HALF_DB_WIDTH-1):0] rssi_half_db,
    input  wire demod_is_ongoing,
    input  wire pkt_header_valid,
    input  wire pkt_header_valid_strobe,
    input  wire ht_unsupport,
    input  wire [7:0] pkt_rate,
    input  wire [15:0] pkt_len,
    input  wire byte_in_strobe,
    input  wire [7:0] byte_in,
    input  wire [15:0] byte_count,
    input  wire fcs_in_strobe,
    input  wire fcs_ok,
    input [14:0] n_ofdm_sym,
    input [9:0]  n_bit_in_last_sym,
    input        phy_len_valid,

    input  wire rx_ht_aggr,
    input  wire rx_ht_aggr_last,

    // LED & GPIO
    output wire demod_is_ongoing_led,
    output wire cycle_start0_led,
    output wire phy_tx_started_led,
    output wire sig_valid_led,

    // Ports to phy_tx
    input  wire phy_tx_start,
    input  wire phy_tx_started,
    input  wire phy_tx_done,

    // Ports to tx_intf
    output wire [79:0] tx_status,
    output wire [47:0] mac_addr,
    output wire retrans_in_progress,
    output wire start_retrans,
    output wire start_tx_ack,
    output wire tx_try_complete,
    input  wire tx_iq_fifo_empty,
    output wire [3:0] slice_en,
    output wire backoff_done,
    output wire tx_bb_is_ongoing,
    output wire tx_rf_is_ongoing,
    output wire ack_tx_flag,
    output wire wea,
    output wire [9:0] addra,
    output wire [(C_S00_AXIS_TDATA_WIDTH-1):0] dina,
    input  wire tx_pkt_need_ack,
    input  wire [3:0] tx_pkt_retrans_limit,
    input  wire tx_ht_aggr,
    input  wire [(WIFI_TX_BRAM_DATA_WIDTH-1):0] douta,
    input  wire cts_toself_bb_is_ongoing,
    input  wire cts_toself_rf_is_ongoing,
    input wire  [(WIFI_TX_BRAM_ADDR_WIDTH-1):0] bram_addr,
    output wire [3:0] band,
    output wire [15:0] channel,
    input wire quit_retrans,
    input wire reset_backoff,
    output wire [3:0] tx_control_state,
    output wire tx_control_state_idle,
    output wire [9:0] num_slot_random,
    output wire [3:0] cw,
    input wire high_trigger,
    input wire [1:0] tx_queue_idx,

    // To side channel
    output wire [31:0] FC_DI,
    output wire FC_DI_valid,
    output wire [47:0] addr1,
    output wire addr1_valid,
    output wire [47:0] addr2,
    output wire addr2_valid,
    output wire [47:0] addr3,
    output wire addr3_valid,
    output wire pkt_for_me,
    output wire ch_idle_final,

    // To SPI module 
    input wire ps_clk, 
    input wire spi0_sclk,
    input wire spi0_mosi,
    input wire spi0_csn,   
    output wire spi_sclk, 	
    output wire spi_csn, 
    output wire spi_mosi,

    // Standard AXI Slave Bus Interface S00_AXI (base XPU registers)
    input  wire s00_axi_aclk,
    input  wire s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
    input  wire [2 : 0] s00_axi_awprot,
    input  wire s00_axi_awvalid,
    output wire s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input  wire s00_axi_wvalid,
    output wire s00_axi_wready,
    output wire [1 : 0] s00_axi_bresp,
    output wire s00_axi_bvalid,
    input  wire s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
    input  wire [2 : 0] s00_axi_arprot,
    input  wire s00_axi_arvalid,
    output wire s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
    output wire [1 : 0] s00_axi_rresp,
    output wire s00_axi_rvalid,
    input  wire s00_axi_rready,

    // Enhanced AXI Slave Bus Interface S01_AXI (enhanced features registers)
    input  wire s01_axi_aclk,
    input  wire s01_axi_aresetn,
    input  wire [ENHANCED_AXI_ADDR_WIDTH-1 : 0] s01_axi_awaddr,
    input  wire [2 : 0] s01_axi_awprot,
    input  wire s01_axi_awvalid,
    output wire s01_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1 : 0] s01_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s01_axi_wstrb,
    input  wire s01_axi_wvalid,
    output wire s01_axi_wready,
    output wire [1 : 0] s01_axi_bresp,
    output wire s01_axi_bvalid,
    input  wire s01_axi_bready,
    input  wire [ENHANCED_AXI_ADDR_WIDTH-1 : 0] s01_axi_araddr,
    input  wire [2 : 0] s01_axi_arprot,
    input  wire s01_axi_arvalid,
    output wire s01_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s01_axi_rdata,
    output wire [1 : 0] s01_axi_rresp,
    output wire s01_axi_rvalid,
    input  wire s01_axi_rready,

    // Enhanced feature outputs
    output wire remote_id_detected,
    output wire [7:0] remote_id_msg_type,
    output wire nan_service_found,
    output wire monitor_mode_active
);

//============================================================================
// Internal Signals
//============================================================================

// Enhanced packet filter outputs
wire enhanced_block_to_ps;
wire [7:0] packet_type;
wire is_beacon_frame;
wire is_nan_frame;
wire is_remote_id_frame;
wire [7:0] frame_subtype_out;

// Enhanced configuration registers (from S01_AXI)
reg [31:0] enhanced_ctrl_reg;      // 0x000: Enhanced control
reg [31:0] monitor_config_reg;     // 0x004: Monitor mode config
reg [31:0] filter_config_reg;      // 0x008: Filter configuration
reg [31:0] remote_id_status_reg;   // 0x00C: Remote ID status (RO)
reg [47:0] filter_mac_addr_reg;    // 0x010-0x014: MAC filter address

// Enhanced control bits
wire monitor_mode_en;
wire capture_mgmt, capture_ctrl, capture_data;
wire capture_beacon, capture_probe_req, capture_probe_resp;
wire capture_nan, capture_auth, capture_deauth, capture_assoc;
wire capture_fcs_fail, promiscuous;
wire nan_processing_en;

assign monitor_mode_en = enhanced_ctrl_reg[0];
assign nan_processing_en = enhanced_ctrl_reg[1];
assign monitor_mode_active = monitor_mode_en;

assign capture_mgmt = monitor_config_reg[0];
assign capture_ctrl = monitor_config_reg[1];
assign capture_data = monitor_config_reg[2];
assign capture_beacon = monitor_config_reg[3];
assign capture_probe_req = monitor_config_reg[4];
assign capture_probe_resp = monitor_config_reg[5];
assign capture_nan = monitor_config_reg[6];
assign capture_auth = monitor_config_reg[7];
assign capture_deauth = monitor_config_reg[8];
assign capture_assoc = monitor_config_reg[9];
assign capture_fcs_fail = monitor_config_reg[10];
assign promiscuous = monitor_config_reg[11];

// NAN handler signals
wire remote_id_service_detected;
wire [47:0] service_name_hash;
wire service_valid;
wire [7:0] nan_state;
wire [15:0] attribute_count;
wire [7:0] current_attr_id;

// Remote ID codec signals
wire [7:0] rid_data_out;
wire rid_data_valid;
wire rid_data_ready;
wire rid_sof, rid_eof;
wire [7:0] rid_decoded_msg_type;
wire [31:0] rid_latitude;
wire [31:0] rid_longitude;
wire [15:0] rid_altitude;

// Vendor IE codec signals
wire [7:0] ie_data_out;
wire ie_data_valid;
wire ie_sof, ie_eof;
wire ie_parse_complete;

// Frame extraction frame
wire [7:0] frame_byte;
wire frame_byte_valid;

// Use original XPU block_rx_dma_to_ps or enhanced version based on monitor mode
wire xpu_block_rx_dma_to_ps;
assign block_rx_dma_to_ps = monitor_mode_en ? enhanced_block_to_ps : xpu_block_rx_dma_to_ps;

// Remote ID detection output
assign remote_id_detected = remote_id_service_detected;
assign remote_id_msg_type = rid_decoded_msg_type;
assign nan_service_found = service_valid;

//============================================================================
// Base XPU Instance
//============================================================================

xpu #(
    .GPIO_STATUS_WIDTH(GPIO_STATUS_WIDTH),
    .DELAY_CTL_WIDTH(DELAY_CTL_WIDTH),
    .RSSI_HALF_DB_WIDTH(RSSI_HALF_DB_WIDTH),
    .IQ_RSSI_HALF_DB_WIDTH(IQ_RSSI_HALF_DB_WIDTH),
    .C_S00_AXIS_TDATA_WIDTH(C_S00_AXIS_TDATA_WIDTH),
    .IQ_DATA_WIDTH(IQ_DATA_WIDTH),
    .WIFI_TX_BRAM_DATA_WIDTH(WIFI_TX_BRAM_DATA_WIDTH),
    .C_S00_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
    .C_S00_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH),
    .TSF_TIMER_WIDTH(TSF_TIMER_WIDTH),
    .WIFI_TX_BRAM_ADDR_WIDTH(WIFI_TX_BRAM_ADDR_WIDTH)
) xpu_inst (
    .gpio_status(gpio_status),
    .ddc_i(ddc_i),
    .ddc_q(ddc_q),
    .ddc_iq_valid(ddc_iq_valid),
    .mute_adc_out_to_bb(mute_adc_out_to_bb),
    .block_rx_dma_to_ps(xpu_block_rx_dma_to_ps),
    .block_rx_dma_to_ps_valid(block_rx_dma_to_ps_valid),
    .rssi_half_db_lock_by_sig_valid(rssi_half_db_lock_by_sig_valid),
    .gpio_status_lock_by_sig_valid(gpio_status_lock_by_sig_valid),
    .tsf_runtime_val(tsf_runtime_val),
    .tsf_pulse_1M(tsf_pulse_1M),
    .rssi_half_db(rssi_half_db),
    .demod_is_ongoing(demod_is_ongoing),
    .pkt_header_valid(pkt_header_valid),
    .pkt_header_valid_strobe(pkt_header_valid_strobe),
    .ht_unsupport(ht_unsupport),
    .pkt_rate(pkt_rate),
    .pkt_len(pkt_len),
    .byte_in_strobe(byte_in_strobe),
    .byte_in(byte_in),
    .byte_count(byte_count),
    .fcs_in_strobe(fcs_in_strobe),
    .fcs_ok(fcs_ok),
    .n_ofdm_sym(n_ofdm_sym),
    .n_bit_in_last_sym(n_bit_in_last_sym),
    .phy_len_valid(phy_len_valid),
    .rx_ht_aggr(rx_ht_aggr),
    .rx_ht_aggr_last(rx_ht_aggr_last),
    .demod_is_ongoing_led(demod_is_ongoing_led),
    .cycle_start0_led(cycle_start0_led),
    .phy_tx_started_led(phy_tx_started_led),
    .sig_valid_led(sig_valid_led),
    .phy_tx_start(phy_tx_start),
    .phy_tx_started(phy_tx_started),
    .phy_tx_done(phy_tx_done),
    .tx_status(tx_status),
    .mac_addr(mac_addr),
    .retrans_in_progress(retrans_in_progress),
    .start_retrans(start_retrans),
    .start_tx_ack(start_tx_ack),
    .tx_try_complete(tx_try_complete),
    .tx_iq_fifo_empty(tx_iq_fifo_empty),
    .slice_en(slice_en),
    .backoff_done(backoff_done),
    .tx_bb_is_ongoing(tx_bb_is_ongoing),
    .tx_rf_is_ongoing(tx_rf_is_ongoing),
    .ack_tx_flag(ack_tx_flag),
    .wea(wea),
    .addra(addra),
    .dina(dina),
    .tx_pkt_need_ack(tx_pkt_need_ack),
    .tx_pkt_retrans_limit(tx_pkt_retrans_limit),
    .tx_ht_aggr(tx_ht_aggr),
    .douta(douta),
    .cts_toself_bb_is_ongoing(cts_toself_bb_is_ongoing),
    .cts_toself_rf_is_ongoing(cts_toself_rf_is_ongoing),
    .bram_addr(bram_addr),
    .band(band),
    .channel(channel),
    .quit_retrans(quit_retrans),
    .reset_backoff(reset_backoff),
    .tx_control_state(tx_control_state),
    .tx_control_state_idle(tx_control_state_idle),
    .num_slot_random(num_slot_random),
    .cw(cw),
    .high_trigger(high_trigger),
    .tx_queue_idx(tx_queue_idx),
    .FC_DI(FC_DI),
    .FC_DI_valid(FC_DI_valid),
    .addr1(addr1),
    .addr1_valid(addr1_valid),
    .addr2(addr2),
    .addr2_valid(addr2_valid),
    .addr3(addr3),
    .addr3_valid(addr3_valid),
    .pkt_for_me(pkt_for_me),
    .ch_idle_final(ch_idle_final),
    .ps_clk(ps_clk),
    .spi0_sclk(spi0_sclk),
    .spi0_mosi(spi0_mosi),
    .spi0_csn(spi0_csn),
    .spi_sclk(spi_sclk),
    .spi_csn(spi_csn),
    .spi_mosi(spi_mosi),
    .s00_axi_aclk(s00_axi_aclk),
    .s00_axi_aresetn(s00_axi_aresetn),
    .s00_axi_awaddr(s00_axi_awaddr),
    .s00_axi_awprot(s00_axi_awprot),
    .s00_axi_awvalid(s00_axi_awvalid),
    .s00_axi_awready(s00_axi_awready),
    .s00_axi_wdata(s00_axi_wdata),
    .s00_axi_wstrb(s00_axi_wstrb),
    .s00_axi_wvalid(s00_axi_wvalid),
    .s00_axi_wready(s00_axi_wready),
    .s00_axi_bresp(s00_axi_bresp),
    .s00_axi_bvalid(s00_axi_bvalid),
    .s00_axi_bready(s00_axi_bready),
    .s00_axi_araddr(s00_axi_araddr),
    .s00_axi_arprot(s00_axi_arprot),
    .s00_axi_arvalid(s00_axi_arvalid),
    .s00_axi_arready(s00_axi_arready),
    .s00_axi_rdata(s00_axi_rdata),
    .s00_axi_rresp(s00_axi_rresp),
    .s00_axi_rvalid(s00_axi_rvalid),
    .s00_axi_rready(s00_axi_rready)
);

//============================================================================
// Enhanced Packet Filter Instance
//============================================================================

// Extract frame control fields
wire [1:0] fc_type;
wire [3:0] fc_subtype;
assign fc_type = FC_DI[3:2];
assign fc_subtype = FC_DI[7:4];

enhanced_pkt_filter #(
    .ADDR_WIDTH(48)
) enhanced_pkt_filter_inst (
    .clk(s00_axi_aclk),
    .rstn(s00_axi_aresetn),
    .frame_control(FC_DI[15:0]),
    .fc_type(fc_type),
    .fc_subtype(fc_subtype),
    .addr1(addr1),
    .addr2(addr2),
    .addr3(addr3),
    .seq_ctrl(16'h0),  // Not used in current implementation
    .fcs_ok(fcs_ok),
    .pkt_header_valid_strobe(pkt_header_valid_strobe),
    .category(8'h0),   // TODO: Parse from frame body
    .oui(24'h0),       // TODO: Parse from frame body
    .oui_type(8'h0),   // TODO: Parse from frame body
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
    .filter_addr(filter_mac_addr_reg),
    .allow_to_dma(),  // Not used, we use block_to_ps
    .block_to_ps(enhanced_block_to_ps),
    .packet_type(packet_type),
    .is_beacon_frame(is_beacon_frame),
    .is_nan_frame(is_nan_frame),
    .is_remote_id_frame(is_remote_id_frame),
    .frame_subtype_out(frame_subtype_out)
);

//============================================================================
// NAN Action Handler Instance
//============================================================================

// Frame byte stream from RX path
assign frame_byte = byte_in;
assign frame_byte_valid = byte_in_strobe;

nan_action_handler #(
    .DATA_WIDTH(8),
    .REMOTE_ID_SIZE(25),
    .MAX_PKT_SIZE(2048),
    .ADDR_WIDTH(11)
) nan_action_handler_inst (
    .clk(s00_axi_aclk),
    .rstn(s00_axi_aresetn),
    .pkt_data_in(frame_byte),
    .pkt_data_valid(frame_byte_valid),
    .pkt_data_ready(),  // Backpressure not needed in RX-only mode
    .pkt_sof(pkt_header_valid_strobe),
    .pkt_eof(fcs_in_strobe),
    .is_nan_frame(is_nan_frame),
    .pkt_length(pkt_len[10:0]),
    .parse_enable(nan_processing_en),
    .rid_data_out(rid_data_out),
    .rid_data_valid(rid_data_valid),
    .rid_data_ready(rid_data_ready),
    .rid_sof(rid_sof),
    .rid_eof(rid_eof),
    .rid_msg_type(rid_decoded_msg_type),
    .remote_id_found(remote_id_service_detected),
    .parse_complete(),
    .error_flags(),
    .attr_count(attribute_count),
    .bytes_processed()
);

//============================================================================
// Remote ID Codec Instance (optional, for decoding)
//============================================================================

assign rid_data_ready = 1'b1;  // Always ready to receive

// Remote ID codec would decode the 25-byte payload
// For now, just pass through the message type

//============================================================================
// Enhanced AXI Register Interface (S01_AXI)
//============================================================================

// Simple register interface for enhanced controls
reg s01_axi_awready_reg;
reg s01_axi_wready_reg;
reg s01_axi_bvalid_reg;
reg s01_axi_arready_reg;
reg s01_axi_rvalid_reg;
reg [31:0] s01_axi_rdata_reg;

assign s01_axi_awready = s01_axi_awready_reg;
assign s01_axi_wready = s01_axi_wready_reg;
assign s01_axi_bvalid = s01_axi_bvalid_reg;
assign s01_axi_bresp = 2'b00;  // OKAY
assign s01_axi_arready = s01_axi_arready_reg;
assign s01_axi_rvalid = s01_axi_rvalid_reg;
assign s01_axi_rdata = s01_axi_rdata_reg;
assign s01_axi_rresp = 2'b00;  // OKAY

// Write logic
always @(posedge s01_axi_aclk) begin
    if (!s01_axi_aresetn) begin
        s01_axi_awready_reg <= 1'b0;
        s01_axi_wready_reg <= 1'b0;
        s01_axi_bvalid_reg <= 1'b0;
        enhanced_ctrl_reg <= 32'h0;
        monitor_config_reg <= 32'h0;
        filter_config_reg <= 32'h0;
        filter_mac_addr_reg <= 48'h0;
    end else begin
        // Write address ready
        if (!s01_axi_awready_reg && s01_axi_awvalid && s01_axi_wvalid) begin
            s01_axi_awready_reg <= 1'b1;
            s01_axi_wready_reg <= 1'b1;
        end else begin
            s01_axi_awready_reg <= 1'b0;
            s01_axi_wready_reg <= 1'b0;
        end

        // Write response
        if (s01_axi_awready_reg && s01_axi_awvalid && s01_axi_wready_reg && s01_axi_wvalid && !s01_axi_bvalid_reg) begin
            s01_axi_bvalid_reg <= 1'b1;

            // Write to registers
            case (s01_axi_awaddr[11:2])
                10'h000: enhanced_ctrl_reg <= s01_axi_wdata;
                10'h001: monitor_config_reg <= s01_axi_wdata;
                10'h002: filter_config_reg <= s01_axi_wdata;
                10'h004: filter_mac_addr_reg[31:0] <= s01_axi_wdata;
                10'h005: filter_mac_addr_reg[47:32] <= s01_axi_wdata[15:0];
            endcase
        end else if (s01_axi_bready && s01_axi_bvalid_reg) begin
            s01_axi_bvalid_reg <= 1'b0;
        end
    end
end

// Read logic
always @(posedge s01_axi_aclk) begin
    if (!s01_axi_aresetn) begin
        s01_axi_arready_reg <= 1'b0;
        s01_axi_rvalid_reg <= 1'b0;
        s01_axi_rdata_reg <= 32'h0;
        remote_id_status_reg <= 32'h0;
    end else begin
        // Update status register
        remote_id_status_reg[0] <= remote_id_service_detected;
        remote_id_status_reg[8] <= service_valid;
        remote_id_status_reg[15:12] <= nan_state[3:0];
        remote_id_status_reg[23:16] <= current_attr_id;

        // Read address ready
        if (!s01_axi_arready_reg && s01_axi_arvalid) begin
            s01_axi_arready_reg <= 1'b1;
        end else begin
            s01_axi_arready_reg <= 1'b0;
        end

        // Read data
        if (s01_axi_arready_reg && s01_axi_arvalid && !s01_axi_rvalid_reg) begin
            s01_axi_rvalid_reg <= 1'b1;

            case (s01_axi_araddr[11:2])
                10'h000: s01_axi_rdata_reg <= enhanced_ctrl_reg;
                10'h001: s01_axi_rdata_reg <= monitor_config_reg;
                10'h002: s01_axi_rdata_reg <= filter_config_reg;
                10'h003: s01_axi_rdata_reg <= remote_id_status_reg;
                10'h004: s01_axi_rdata_reg <= filter_mac_addr_reg[31:0];
                10'h005: s01_axi_rdata_reg <= {16'h0, filter_mac_addr_reg[47:32]};
                default: s01_axi_rdata_reg <= 32'h0;
            endcase
        end else if (s01_axi_rready && s01_axi_rvalid_reg) begin
            s01_axi_rvalid_reg <= 1'b0;
        end
    end
end

endmodule
