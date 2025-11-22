// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: ssid_extractor
//
// Description:
//   Minimal SSID extraction from beacon frames for Zynq 7010.
//   Extracts only the SSID information element (ID=0).
//
// Configuration: MINIMAL (Zynq 7010 Experimental)
//
// Beacon Frame Structure:
//   [0-1]   Frame Control
//   [2-3]   Duration
//   [4-9]   Destination Address (FF:FF:FF:FF:FF:FF for beacons)
//   [10-15] Source Address (BSSID)
//   [16-21] BSSID
//   [22-23] Sequence Control
//   [24+]   Frame Body:
//           [24-31] Timestamp (8 bytes)
//           [32-33] Beacon Interval
//           [34-35] Capability Info
//           [36+]   Information Elements:
//                   [0] Element ID (0 = SSID)
//                   [1] Length (0-32 bytes)
//                   [2+] SSID string
//
// Resource Estimate: ~300 LUTs
//
// Author: OpenWiFi Team
// Date: 2025-11-22
// Branch: claude/minimal-z7010-016NinPPubrhjENgJbg7a1qj
//////////////////////////////////////////////////////////////////////////////////

module ssid_extractor #(
    parameter MAX_SSID_LEN = 32
)(
    input wire clk,
    input wire rstn,

    // Packet input (byte stream)
    input wire [7:0] byte_in,
    input wire byte_in_valid,
    input wire pkt_start,          // Start of packet
    input wire pkt_end,            // End of packet

    // Control
    input wire is_beacon,          // From minimal_beacon_filter

    // SSID output
    output reg [8*MAX_SSID_LEN-1:0] ssid,        // SSID string
    output reg [7:0] ssid_len,                    // SSID length (0-32)
    output reg ssid_valid,                        // SSID extraction complete
    output reg [47:0] bssid                       // BSSID (MAC address)
);

// ============================================================================
// State Machine
// ============================================================================

localparam ST_IDLE = 0;
localparam ST_HEADER = 1;
localparam ST_BSSID = 2;
localparam ST_BEACON_BODY = 3;
localparam ST_FIND_SSID_IE = 4;
localparam ST_EXTRACT_SSID = 5;

reg [2:0] state;
reg [7:0] byte_count;
reg [7:0] ssid_bytes_read;
reg [7:0] ssid_ie_len;

// ============================================================================
// Byte Counter and State Machine
// ============================================================================

always @(posedge clk) begin
    if (!rstn) begin
        state <= ST_IDLE;
        byte_count <= 8'h0;
        ssid_bytes_read <= 8'h0;
        ssid_ie_len <= 8'h0;
        ssid <= 0;
        ssid_len <= 8'h0;
        ssid_valid <= 1'b0;
        bssid <= 48'h0;
    end else begin
        case (state)
            ST_IDLE: begin
                ssid_valid <= 1'b0;
                if (pkt_start && is_beacon) begin
                    state <= ST_HEADER;
                    byte_count <= 8'h0;
                    ssid <= 0;
                    ssid_len <= 8'h0;
                end
            end

            ST_HEADER: begin
                if (byte_in_valid) begin
                    byte_count <= byte_count + 1;

                    // Extract BSSID (bytes 10-15)
                    if (byte_count >= 10 && byte_count < 16) begin
                        bssid <= {bssid[39:0], byte_in};
                    end

                    // Move to beacon body after MAC header (24 bytes)
                    if (byte_count == 23) begin
                        state <= ST_BEACON_BODY;
                        byte_count <= 8'h0;
                    end
                end
            end

            ST_BEACON_BODY: begin
                if (byte_in_valid) begin
                    byte_count <= byte_count + 1;

                    // Skip fixed fields:
                    // - Timestamp (8 bytes)
                    // - Beacon Interval (2 bytes)
                    // - Capability Info (2 bytes)
                    // Total: 12 bytes before IEs
                    if (byte_count == 11) begin
                        state <= ST_FIND_SSID_IE;
                        byte_count <= 8'h0;
                    end
                end
            end

            ST_FIND_SSID_IE: begin
                if (byte_in_valid) begin
                    if (byte_count == 0) begin
                        // Check Element ID
                        if (byte_in == 8'h00) begin
                            // Found SSID IE (ID=0)
                            byte_count <= 8'h01;
                        end else begin
                            // Wrong IE, skip to next
                            byte_count <= 8'h01; // Will read length next
                        end
                    end else if (byte_count == 1) begin
                        // Read length
                        if (ssid_ie_len == 8'h0) begin
                            // First time reading length for SSID IE
                            ssid_ie_len <= byte_in;
                            if (byte_in > 0 && byte_in <= MAX_SSID_LEN) begin
                                // Valid SSID length, extract it
                                state <= ST_EXTRACT_SSID;
                                ssid_len <= byte_in;
                                ssid_bytes_read <= 8'h0;
                                byte_count <= 8'h0;
                            end else begin
                                // Empty SSID or too long, mark as complete
                                ssid_len <= 8'h0;
                                ssid_valid <= 1'b1;
                                state <= ST_IDLE;
                            end
                        end
                    end
                end

                if (pkt_end) begin
                    state <= ST_IDLE;
                end
            end

            ST_EXTRACT_SSID: begin
                if (byte_in_valid) begin
                    // Shift in SSID byte
                    ssid <= {ssid[8*(MAX_SSID_LEN-1)-1:0], byte_in};
                    ssid_bytes_read <= ssid_bytes_read + 1;

                    // Done when we've read all SSID bytes
                    if (ssid_bytes_read == ssid_len - 1) begin
                        ssid_valid <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                if (pkt_end) begin
                    state <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
