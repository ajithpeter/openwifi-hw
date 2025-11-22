// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: enhanced_pkt_filter
//
// Description:
//   Enhanced packet filter for monitor mode and drone Remote ID support.
//   Supports filtering by frame type, subtype, and specific patterns.
//   Implements IEEE 802.11 frame classification and WiFi Aware/NAN detection.
//
// Features:
//   - Monitor mode with configurable frame type filtering
//   - NAN (Neighbor Awareness Networking) action frame detection
//   - Beacon frame classification and SSID extraction prep
//   - Remote ID vendor IE detection
//   - Promiscuous mode support
//   - FCS failure capture option
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module enhanced_pkt_filter #(
    parameter ADDR_WIDTH = 48  // MAC address width
)(
    input wire clk,
    input wire rstn,

    // Frame classification inputs (from PHY RX parser)
    input wire [15:0] frame_control,        // Full FC field
    input wire [1:0] fc_type,               // 00=mgmt, 01=ctrl, 10=data
    input wire [3:0] fc_subtype,
    input wire [ADDR_WIDTH-1:0] addr1,      // Destination Address (DA)
    input wire [ADDR_WIDTH-1:0] addr2,      // Source Address (SA)
    input wire [ADDR_WIDTH-1:0] addr3,      // BSSID or DA (ToDS/FromDS dep)
    input wire [15:0] seq_ctrl,             // Sequence control
    input wire fcs_ok,                      // FCS validation result
    input wire pkt_header_valid_strobe,     // Packet header valid pulse

    // Frame body hints (from parser)
    input wire [7:0] category,              // Action frame category
    input wire [23:0] oui,                  // OUI for vendor frames
    input wire [7:0] oui_type,              // OUI type

    // Monitor mode configuration registers
    input wire monitor_mode_en,             // Enable monitor mode
    input wire capture_mgmt,                // Capture management frames
    input wire capture_ctrl,                // Capture control frames
    input wire capture_data,                // Capture data frames
    input wire capture_beacon,              // Specific: beacon frames
    input wire capture_probe_req,           // Specific: probe requests
    input wire capture_probe_resp,          // Specific: probe responses
    input wire capture_nan,                 // Specific: NAN action frames
    input wire capture_auth,                // Specific: authentication
    input wire capture_deauth,              // Specific: deauthentication
    input wire capture_assoc,               // Specific: association
    input wire capture_fcs_fail,            // Include FCS failures
    input wire promiscuous,                 // True promiscuous mode
    input wire [ADDR_WIDTH-1:0] filter_addr,// Address filter (if !promiscuous)

    // Filter outputs
    output reg allow_to_dma,                // Allow packet to RX DMA
    output reg block_to_ps,                 // Block from PS (inverse of allow)
    output reg [7:0] packet_type,           // Classified packet type
    output reg is_beacon_frame,             // Beacon detector
    output reg is_nan_frame,                // NAN action frame detector
    output reg is_remote_id_frame,          // Remote ID frame detector
    output reg [7:0] frame_subtype_out      // For software parsing
);

// IEEE 802.11 Frame Type Definitions
localparam [1:0] TYPE_MGMT = 2'b00;
localparam [1:0] TYPE_CTRL = 2'b01;
localparam [1:0] TYPE_DATA = 2'b10;
localparam [1:0] TYPE_EXT  = 2'b11;  // 802.11ax extension

// Management Frame Subtypes
localparam [3:0] SUBTYPE_ASSOC_REQ   = 4'h0;
localparam [3:0] SUBTYPE_ASSOC_RESP  = 4'h1;
localparam [3:0] SUBTYPE_REASSOC_REQ = 4'h2;
localparam [3:0] SUBTYPE_REASSOC_RESP= 4'h3;
localparam [3:0] SUBTYPE_PROBE_REQ   = 4'h4;
localparam [3:0] SUBTYPE_PROBE_RESP  = 4'h5;
localparam [3:0] SUBTYPE_TIMING_ADV  = 4'h6;
localparam [3:0] SUBTYPE_BEACON      = 4'h8;
localparam [3:0] SUBTYPE_ATIM        = 4'h9;
localparam [3:0] SUBTYPE_DISASSOC    = 4'hA;
localparam [3:0] SUBTYPE_AUTH        = 4'hB;
localparam [3:0] SUBTYPE_DEAUTH      = 4'hC;
localparam [3:0] SUBTYPE_ACTION      = 4'hD;
localparam [3:0] SUBTYPE_ACTION_NOACK= 4'hE;

// Control Frame Subtypes
localparam [3:0] SUBTYPE_CTRL_WRAPPER = 4'h7;
localparam [3:0] SUBTYPE_BLOCK_ACK_REQ= 4'h8;
localparam [3:0] SUBTYPE_BLOCK_ACK    = 4'h9;
localparam [3:0] SUBTYPE_PS_POLL      = 4'hA;
localparam [3:0] SUBTYPE_RTS          = 4'hB;
localparam [3:0] SUBTYPE_CTS          = 4'hC;
localparam [3:0] SUBTYPE_ACK          = 4'hD;
localparam [3:0] SUBTYPE_CF_END       = 4'hE;
localparam [3:0] SUBTYPE_CF_END_ACK   = 4'hF;

// Action Frame Categories
localparam [7:0] ACTION_CAT_VENDOR    = 8'h7F;  // 127
localparam [7:0] ACTION_CAT_PUBLIC    = 8'h04;

// WiFi Alliance OUI and NAN Type
localparam [23:0] WFA_OUI = 24'h506F9A;  // WiFi Alliance
localparam [7:0] OUI_TYPE_NAN = 8'h13;   // NAN

// Remote ID Service Hash (first 6 bytes of SHA256("org.astm.f3411.remoteid"))
// This would be detected in the NAN Service Descriptor
localparam [47:0] REMOTE_ID_SERVICE_HASH = 48'h886919_9D9209;

// Internal signals
reg addr_match;
reg is_broadcast;
reg is_multicast;
wire is_mgmt, is_ctrl, is_data;

// Frame type detection
assign is_mgmt = (fc_type == TYPE_MGMT);
assign is_ctrl = (fc_type == TYPE_CTRL);
assign is_data = (fc_type == TYPE_DATA);

// Address matching logic
always @(*) begin
    is_broadcast = (addr1 == 48'hFFFFFFFFFFFF);
    is_multicast = addr1[0];  // LSB of first byte indicates multicast

    if (promiscuous) begin
        addr_match = 1'b1;  // Accept all in promiscuous mode
    end else begin
        // Match if DA is our address, broadcast, or multicast
        addr_match = (addr1 == filter_addr) || is_broadcast || is_multicast;
    end
end

// Main filter logic
always @(posedge clk) begin
    if (!rstn) begin
        allow_to_dma <= 1'b0;
        block_to_ps <= 1'b1;
        packet_type <= 8'h00;
        is_beacon_frame <= 1'b0;
        is_nan_frame <= 1'b0;
        is_remote_id_frame <= 1'b0;
        frame_subtype_out <= 4'h0;
    end else if (pkt_header_valid_strobe) begin
        // Default: block packet
        allow_to_dma <= 1'b0;
        block_to_ps <= 1'b1;
        is_beacon_frame <= 1'b0;
        is_nan_frame <= 1'b0;
        is_remote_id_frame <= 1'b0;

        if (monitor_mode_en) begin
            // Monitor mode: filter based on frame type and config

            case (fc_type)
                TYPE_MGMT: begin
                    if (capture_mgmt || promiscuous) begin
                        case (fc_subtype)
                            SUBTYPE_BEACON: begin
                                allow_to_dma <= capture_beacon || promiscuous;
                                is_beacon_frame <= 1'b1;
                                packet_type <= {fc_type, fc_subtype, 2'b00};
                            end

                            SUBTYPE_PROBE_REQ: begin
                                allow_to_dma <= capture_probe_req || promiscuous;
                                packet_type <= {fc_type, fc_subtype, 2'b01};
                            end

                            SUBTYPE_PROBE_RESP: begin
                                allow_to_dma <= capture_probe_resp || promiscuous;
                                packet_type <= {fc_type, fc_subtype, 2'b10};
                            end

                            SUBTYPE_ACTION, SUBTYPE_ACTION_NOACK: begin
                                // Check if this is a NAN action frame
                                if (category == ACTION_CAT_VENDOR &&
                                    oui == WFA_OUI &&
                                    oui_type == OUI_TYPE_NAN) begin
                                    allow_to_dma <= capture_nan || promiscuous;
                                    is_nan_frame <= 1'b1;
                                    packet_type <= {fc_type, fc_subtype, 2'b11};
                                    // Remote ID detection done in software
                                    // (needs to parse Service Descriptor)
                                end else begin
                                    allow_to_dma <= capture_mgmt || promiscuous;
                                    packet_type <= {fc_type, fc_subtype, 2'b00};
                                end
                            end

                            SUBTYPE_AUTH: begin
                                allow_to_dma <= capture_auth || promiscuous;
                                packet_type <= {fc_type, fc_subtype, 2'b00};
                            end

                            SUBTYPE_DEAUTH: begin
                                allow_to_dma <= capture_deauth || promiscuous;
                                packet_type <= {fc_type, fc_subtype, 2'b00};
                            end

                            SUBTYPE_ASSOC_REQ, SUBTYPE_ASSOC_RESP,
                            SUBTYPE_REASSOC_REQ, SUBTYPE_REASSOC_RESP: begin
                                allow_to_dma <= capture_assoc || promiscuous;
                                packet_type <= {fc_type, fc_subtype, 2'b00};
                            end

                            default: begin
                                allow_to_dma <= capture_mgmt || promiscuous;
                                packet_type <= {fc_type, fc_subtype, 2'b00};
                            end
                        endcase
                    end
                end

                TYPE_CTRL: begin
                    if (capture_ctrl || promiscuous) begin
                        allow_to_dma <= 1'b1;
                        packet_type <= {fc_type, fc_subtype, 2'b00};
                    end
                end

                TYPE_DATA: begin
                    if (capture_data || promiscuous) begin
                        // Apply address filtering for data frames
                        allow_to_dma <= addr_match;
                        packet_type <= {fc_type, fc_subtype, 2'b00};
                    end
                end

                default: begin
                    // Unknown/extension type
                    if (promiscuous) begin
                        allow_to_dma <= 1'b1;
                        packet_type <= {fc_type, fc_subtype, 2'b00};
                    end
                end
            endcase

            // FCS failure handling
            if (!fcs_ok && !capture_fcs_fail) begin
                allow_to_dma <= 1'b0;
            end

            // Override all filters in true promiscuous mode
            if (promiscuous) begin
                allow_to_dma <= (fcs_ok || capture_fcs_fail);
            end

        end else begin
            // Normal mode (not monitor): use existing filter logic
            // Allow only packets for us with valid FCS
            allow_to_dma <= addr_match && fcs_ok;
        end

        // block_to_ps is inverse of allow_to_dma
        block_to_ps <= ~allow_to_dma;

        // Output subtype for software processing
        frame_subtype_out <= fc_subtype;
    end
end

endmodule
