// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: nan_action_handler
//
// Description:
//   NAN (Neighbor Awareness Networking) Action Frame Handler for Remote ID.
//   Parses WiFi Aware/NAN action frames and extracts ASTM F3411 Remote ID
//   payloads from Service Descriptor attributes.
//
// NAN Frame Structure:
//   - MAC Header (24 bytes)
//   - Action Frame Body:
//     * Category: 0x7F (Vendor Specific) or 0x04 (Public Action)
//     * OUI: 0x506F9A (WiFi Alliance)
//     * OUI Type: 0x13 (NAN)
//     * OUI Subtype: 0x00
//     * Dialog Token: 2 bytes
//   - NAN Attributes (TLV format):
//     * Type (1 byte): Attribute ID
//     * Length (2 bytes, little-endian): Value length
//     * Value (variable): Attribute data
//
// Remote ID Service Descriptor (attr_id = 0x03):
//   - Service ID (6 bytes): 0x88 0x69 0x19 0x9D 0x92 0x09
//   - Instance ID (1 byte)
//   - Requestor Instance ID (1 byte)
//   - Service Control (1 byte)
//   - Binding Bitmap (1 byte)
//   - Service Info Length (1 byte): Should be 25 for Remote ID
//   - Service Info (25 bytes): ASTM F3411 Remote ID message
//
// Features:
//   - TLV attribute parsing with state machine
//   - Service ID validation against Remote ID hash
//   - 25-byte Remote ID payload extraction
//   - Multiple attributes per frame support
//   - Length validation and error checking
//   - AXI stream interface for DMA transfer
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module nan_action_handler #(
    parameter DATA_WIDTH = 8,           // Byte-wide data path
    parameter REMOTE_ID_SIZE = 25,      // ASTM F3411 message size
    parameter MAX_PKT_SIZE = 2048,      // Maximum packet size
    parameter ADDR_WIDTH = 11           // Address width for packet size (2^11 = 2048)
)(
    input wire clk,
    input wire rstn,

    // Packet input stream (from RX buffer/FIFO)
    input wire [DATA_WIDTH-1:0] pkt_data_in,
    input wire pkt_data_valid,
    output reg pkt_data_ready,
    input wire pkt_sof,                 // Start of frame
    input wire pkt_eof,                 // End of frame

    // Control inputs
    input wire is_nan_frame,            // From enhanced_pkt_filter
    input wire [ADDR_WIDTH-1:0] pkt_length, // Total packet length
    input wire parse_enable,            // Enable parsing

    // Remote ID output stream (AXI-Stream to DMA)
    output reg [DATA_WIDTH-1:0] rid_data_out,
    output reg rid_data_valid,
    input wire rid_data_ready,
    output reg rid_sof,                 // Start of Remote ID data
    output reg rid_eof,                 // End of Remote ID data
    output reg [7:0] rid_msg_type,      // Remote ID message type

    // Status outputs
    output reg remote_id_found,         // Valid Remote ID service found
    output reg parse_complete,          // Parsing complete
    output reg [3:0] error_flags,       // Error flags

    // Debug outputs
    output reg [7:0] attr_count,        // Number of attributes parsed
    output reg [ADDR_WIDTH-1:0] bytes_processed // Bytes processed counter
);

// NAN Attribute IDs
localparam [7:0] NAN_ATTR_SERVICE_DESCRIPTOR = 8'h03;
localparam [7:0] NAN_ATTR_VENDOR_SPECIFIC    = 8'hDD;

// Remote ID Service ID (SHA-256 hash of "org.astm.f3411.remoteid", first 6 bytes)
localparam [47:0] REMOTE_ID_SERVICE_ID = 48'h886919_9D9209;

// MAC header and action frame header sizes
localparam [7:0] MAC_HEADER_SIZE = 24;         // IEEE 802.11 MAC header
localparam [7:0] ACTION_HEADER_SIZE = 7;       // Category + OUI + Type + Subtype + Token
localparam [7:0] NAN_HEADER_SIZE = MAC_HEADER_SIZE + ACTION_HEADER_SIZE; // 31 bytes

// Service Descriptor header size (before service_info)
localparam [7:0] SVC_DESC_HEADER_SIZE = 11;    // Service ID(6) + IDs(2) + Control(1) + Bitmap(1) + Len(1)

// Error flag bit positions
localparam ERR_INVALID_LENGTH    = 0;  // Invalid attribute length
localparam ERR_SERVICE_ID_MISMATCH = 1;  // Service ID doesn't match Remote ID
localparam ERR_PAYLOAD_SIZE      = 2;  // Service info length != 25
localparam ERR_PARSE_OVERFLOW    = 3;  // Parsing beyond packet length

// State machine states
localparam [3:0] ST_IDLE           = 4'd0;
localparam [3:0] ST_SKIP_HEADERS   = 4'd1;
localparam [3:0] ST_ATTR_TYPE      = 4'd2;
localparam [3:0] ST_ATTR_LEN_LOW   = 4'd3;
localparam [3:0] ST_ATTR_LEN_HIGH  = 4'd4;
localparam [3:0] ST_ATTR_VALUE     = 4'd5;
localparam [3:0] ST_SVC_DESC_ID    = 4'd6;
localparam [3:0] ST_SVC_DESC_HDR   = 4'd7;
localparam [3:0] ST_REMOTE_ID_DATA = 4'd8;
localparam [3:0] ST_SKIP_ATTR      = 4'd9;
localparam [3:0] ST_COMPLETE       = 4'd10;
localparam [3:0] ST_ERROR          = 4'd11;

// State registers
reg [3:0] state, next_state;
reg [ADDR_WIDTH-1:0] byte_counter;
reg [ADDR_WIDTH-1:0] skip_counter;
reg [7:0] current_attr_id;
reg [15:0] current_attr_len;
reg [15:0] attr_value_counter;

// Service Descriptor parsing
reg [47:0] service_id_buffer;
reg [2:0] service_id_byte_count;
reg [7:0] service_info_len;
reg [4:0] rid_byte_count;
reg service_id_match;

// Internal control signals
reg parsing_active;
reg advance_state;

//============================================================================
// Main State Machine
//============================================================================

always @(posedge clk) begin
    if (!rstn) begin
        state <= ST_IDLE;
    end else begin
        state <= next_state;
    end
end

// Next state logic
always @(*) begin
    next_state = state;

    case (state)
        ST_IDLE: begin
            if (pkt_sof && is_nan_frame && parse_enable) begin
                next_state = ST_SKIP_HEADERS;
            end
        end

        ST_SKIP_HEADERS: begin
            if (pkt_data_valid && skip_counter >= NAN_HEADER_SIZE - 1) begin
                next_state = ST_ATTR_TYPE;
            end else if (pkt_eof) begin
                next_state = ST_ERROR;
            end
        end

        ST_ATTR_TYPE: begin
            if (pkt_data_valid) begin
                if (byte_counter >= pkt_length - 3) begin
                    // Not enough bytes for complete attribute (type + 2-byte length)
                    next_state = ST_COMPLETE;
                end else begin
                    next_state = ST_ATTR_LEN_LOW;
                end
            end else if (pkt_eof) begin
                next_state = ST_COMPLETE;
            end
        end

        ST_ATTR_LEN_LOW: begin
            if (pkt_data_valid) begin
                next_state = ST_ATTR_LEN_HIGH;
            end else if (pkt_eof) begin
                next_state = ST_ERROR;
            end
        end

        ST_ATTR_LEN_HIGH: begin
            if (pkt_data_valid) begin
                if (current_attr_id == NAN_ATTR_SERVICE_DESCRIPTOR) begin
                    next_state = ST_SVC_DESC_ID;
                end else begin
                    // Skip this attribute
                    next_state = ST_SKIP_ATTR;
                end
            end else if (pkt_eof) begin
                next_state = ST_ERROR;
            end
        end

        ST_SVC_DESC_ID: begin
            if (pkt_data_valid) begin
                if (service_id_byte_count >= 5) begin
                    // All 6 bytes of service ID received
                    if (service_id_match) begin
                        next_state = ST_SVC_DESC_HDR;
                    end else begin
                        // Not a Remote ID service, skip rest of attribute
                        next_state = ST_SKIP_ATTR;
                    end
                end
            end else if (pkt_eof) begin
                next_state = ST_ERROR;
            end
        end

        ST_SVC_DESC_HDR: begin
            if (pkt_data_valid) begin
                if (attr_value_counter >= SVC_DESC_HEADER_SIZE - 1) begin
                    // Header complete, check service_info_len
                    if (service_info_len == REMOTE_ID_SIZE) begin
                        next_state = ST_REMOTE_ID_DATA;
                    end else begin
                        next_state = ST_SKIP_ATTR;
                    end
                end
            end else if (pkt_eof) begin
                next_state = ST_ERROR;
            end
        end

        ST_REMOTE_ID_DATA: begin
            if (pkt_data_valid) begin
                if (rid_byte_count >= REMOTE_ID_SIZE - 1) begin
                    // All Remote ID bytes received
                    next_state = ST_ATTR_TYPE;  // Look for more attributes
                end
            end else if (pkt_eof) begin
                if (rid_byte_count >= REMOTE_ID_SIZE - 1) begin
                    next_state = ST_COMPLETE;
                end else begin
                    next_state = ST_ERROR;
                end
            end
        end

        ST_SKIP_ATTR: begin
            if (pkt_data_valid) begin
                if (attr_value_counter >= current_attr_len - 1) begin
                    next_state = ST_ATTR_TYPE;  // Next attribute
                end
            end else if (pkt_eof) begin
                next_state = ST_COMPLETE;
            end
        end

        ST_COMPLETE: begin
            next_state = ST_IDLE;
        end

        ST_ERROR: begin
            next_state = ST_IDLE;
        end

        default: begin
            next_state = ST_IDLE;
        end
    endcase

    // Force return to idle on EOF in most states
    if (pkt_eof && (state != ST_REMOTE_ID_DATA) && (state != ST_COMPLETE) && (state != ST_ERROR)) begin
        next_state = ST_ERROR;
    end
end

//============================================================================
// Data Path and Control Logic
//============================================================================

always @(posedge clk) begin
    if (!rstn) begin
        // Reset all registers
        byte_counter <= 0;
        skip_counter <= 0;
        current_attr_id <= 0;
        current_attr_len <= 0;
        attr_value_counter <= 0;
        service_id_buffer <= 0;
        service_id_byte_count <= 0;
        service_info_len <= 0;
        rid_byte_count <= 0;
        service_id_match <= 0;

        pkt_data_ready <= 0;
        rid_data_out <= 0;
        rid_data_valid <= 0;
        rid_sof <= 0;
        rid_eof <= 0;
        rid_msg_type <= 0;

        remote_id_found <= 0;
        parse_complete <= 0;
        error_flags <= 0;
        attr_count <= 0;
        bytes_processed <= 0;

    end else begin
        // Default values
        pkt_data_ready <= 0;
        rid_data_valid <= 0;
        rid_sof <= 0;
        rid_eof <= 0;
        parse_complete <= 0;

        case (state)
            ST_IDLE: begin
                byte_counter <= 0;
                skip_counter <= 0;
                attr_count <= 0;
                bytes_processed <= 0;
                remote_id_found <= 0;
                error_flags <= 0;
                rid_byte_count <= 0;
                service_id_match <= 0;

                if (pkt_sof && is_nan_frame && parse_enable) begin
                    pkt_data_ready <= 1;
                    byte_counter <= byte_counter + 1;
                    skip_counter <= 1;
                end
            end

            ST_SKIP_HEADERS: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    byte_counter <= byte_counter + 1;
                    skip_counter <= skip_counter + 1;
                    bytes_processed <= byte_counter;
                end
            end

            ST_ATTR_TYPE: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    current_attr_id <= pkt_data_in;
                    byte_counter <= byte_counter + 1;
                    attr_value_counter <= 0;
                    attr_count <= attr_count + 1;
                    bytes_processed <= byte_counter;
                end
            end

            ST_ATTR_LEN_LOW: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    current_attr_len[7:0] <= pkt_data_in;
                    byte_counter <= byte_counter + 1;
                    bytes_processed <= byte_counter;
                end
            end

            ST_ATTR_LEN_HIGH: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    current_attr_len[15:8] <= pkt_data_in;
                    byte_counter <= byte_counter + 1;
                    bytes_processed <= byte_counter;

                    // Validate length
                    if ({pkt_data_in, current_attr_len[7:0]} > (pkt_length - byte_counter)) begin
                        error_flags[ERR_INVALID_LENGTH] <= 1;
                    end

                    // Initialize service descriptor parsing
                    if (current_attr_id == NAN_ATTR_SERVICE_DESCRIPTOR) begin
                        service_id_byte_count <= 0;
                        service_id_buffer <= 0;
                    end
                end
            end

            ST_SVC_DESC_ID: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    byte_counter <= byte_counter + 1;
                    attr_value_counter <= attr_value_counter + 1;
                    bytes_processed <= byte_counter;

                    // Shift in service ID bytes (little-endian)
                    service_id_buffer <= {pkt_data_in, service_id_buffer[47:8]};
                    service_id_byte_count <= service_id_byte_count + 1;

                    // Check for match after receiving all 6 bytes
                    if (service_id_byte_count == 5) begin
                        if ({pkt_data_in, service_id_buffer[47:8]} == REMOTE_ID_SERVICE_ID) begin
                            service_id_match <= 1;
                        end else begin
                            error_flags[ERR_SERVICE_ID_MISMATCH] <= 1;
                        end
                    end
                end
            end

            ST_SVC_DESC_HDR: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    byte_counter <= byte_counter + 1;
                    attr_value_counter <= attr_value_counter + 1;
                    bytes_processed <= byte_counter;

                    // Capture service_info_len at the correct position
                    // Position in header: Service ID(6) + Instance(1) + Req Instance(1) +
                    //                     Service Ctrl(1) + Binding(1) = 10, so byte 10 is length
                    if (attr_value_counter == 10) begin
                        service_info_len <= pkt_data_in;
                        if (pkt_data_in != REMOTE_ID_SIZE) begin
                            error_flags[ERR_PAYLOAD_SIZE] <= 1;
                        end
                    end
                end
            end

            ST_REMOTE_ID_DATA: begin
                if (pkt_data_valid && rid_data_ready) begin
                    pkt_data_ready <= 1;
                    byte_counter <= byte_counter + 1;
                    attr_value_counter <= attr_value_counter + 1;
                    bytes_processed <= byte_counter;

                    // Output Remote ID data
                    rid_data_out <= pkt_data_in;
                    rid_data_valid <= 1;
                    rid_byte_count <= rid_byte_count + 1;

                    // Start of frame on first byte
                    if (rid_byte_count == 0) begin
                        rid_sof <= 1;
                        rid_msg_type <= pkt_data_in;  // First byte is message type
                        remote_id_found <= 1;
                    end

                    // End of frame on last byte
                    if (rid_byte_count == REMOTE_ID_SIZE - 1) begin
                        rid_eof <= 1;
                    end
                end
            end

            ST_SKIP_ATTR: begin
                if (pkt_data_valid) begin
                    pkt_data_ready <= 1;
                    byte_counter <= byte_counter + 1;
                    attr_value_counter <= attr_value_counter + 1;
                    bytes_processed <= byte_counter;
                end
            end

            ST_COMPLETE: begin
                parse_complete <= 1;
            end

            ST_ERROR: begin
                parse_complete <= 1;
                if (byte_counter > pkt_length) begin
                    error_flags[ERR_PARSE_OVERFLOW] <= 1;
                end
            end

            default: begin
                // Do nothing
            end
        endcase
    end
end

endmodule
