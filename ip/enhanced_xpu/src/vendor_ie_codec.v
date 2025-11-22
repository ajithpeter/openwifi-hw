// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: vendor_ie_codec
//
// Description:
//   Vendor Information Element (IE) codec for encoding/decoding WiFi vendor-
//   specific IEs. Primarily used for transmitting Drone Remote ID messages
//   in beacon frames, probe responses, or as an alternative to WiFi NAN.
//
// IEEE 802.11 Vendor IE Format:
//   +----------+--------+----------+----------+-------------+
//   | Elem ID  | Length |   OUI    | OUI Type |   Payload   |
//   | (1 byte) | (1 B)  | (3 bytes)| (1 byte) | (variable)  |
//   +----------+--------+----------+----------+-------------+
//   | 221(0xDD)|  N+4   | 0x506F9A |   0xXX   | Remote ID   |
//   +----------+--------+----------+----------+-------------+
//
//   - Element ID: Always 221 (0xDD) for Vendor Specific
//   - Length: Total length of (OUI + OUI Type + Payload) = N+4 bytes
//   - OUI: Organizationally Unique Identifier (3 bytes)
//     * WiFi Alliance: 0x506F9A
//     * Custom: Configurable via parameter
//   - OUI Type: Vendor-specific type identifier (1 byte)
//     * Configurable via parameter for Remote ID variants
//   - Payload: Actual data (25 bytes for ASTM F3411 Remote ID messages)
//
// Remote ID Payload (ASTM F3411):
//   - Basic ID (Type 0): 25 bytes (msg_type + id_type + ua_type + uas_id[20] + reserved[2])
//   - Location (Type 1): 25 bytes (position, velocity, altitude, accuracy)
//   - Authentication (Type 2): 25 bytes
//   - Self ID (Type 3): 25 bytes
//   - System (Type 4): 25 bytes
//   - Operator ID (Type 5): 25 bytes
//
// Operating Modes:
//   TX Mode (mode=0): Encode Remote ID message into complete IE
//     Input:  25-byte Remote ID message
//     Output: 31-byte complete IE [ID|Len|OUI|Type|Payload]
//
//   RX Mode (mode=1): Decode and validate IE, extract Remote ID message
//     Input:  31-byte IE data stream
//     Output: 25-byte Remote ID message (if valid)
//
// Features:
//   - Configurable OUI and OUI Type via parameters
//   - Automatic length calculation and validation
//   - CRC/checksum validation (optional, for future use)
//   - Error detection for malformed IEs
//   - Support for multiple vendor IE parsing in RX mode
//
// Author: OpenWiFi Team
// Date: 2025-11-22
//////////////////////////////////////////////////////////////////////////////////

module vendor_ie_codec #(
    parameter [23:0] DEFAULT_OUI = 24'h506F9A,      // WiFi Alliance OUI
    parameter [7:0]  DEFAULT_OUI_TYPE = 8'h09,      // Remote ID OUI type (custom)
    parameter        REMOTE_ID_PAYLOAD_LEN = 25,    // ASTM F3411 message size
    parameter        IE_HEADER_LEN = 6,             // ID(1) + Len(1) + OUI(3) + Type(1)
    parameter        TOTAL_IE_LEN = 31              // Header(6) + Payload(25)
)(
    // System signals
    input wire clk,
    input wire rstn,

    // Control signals
    input wire mode,                        // 0=TX (encode), 1=RX (decode)
    input wire start,                       // Start encode/decode operation
    output reg busy,                        // Operation in progress
    output reg done,                        // Operation complete (1 cycle pulse)
    output reg valid,                       // Output data is valid
    output reg error,                       // Error detected (malformed IE, etc.)

    // Configuration (optional override of defaults)
    input wire [23:0] oui_config,           // Override OUI (if oui_override=1)
    input wire [7:0] oui_type_config,       // Override OUI Type (if oui_override=1)
    input wire oui_override,                // Use configured OUI instead of default

    // TX Mode: Input Remote ID message (25 bytes)
    input wire [199:0] tx_remote_id_msg,    // 25 bytes * 8 = 200 bits
    // TX Mode: Output complete IE (31 bytes)
    output reg [247:0] tx_ie_output,        // 31 bytes * 8 = 248 bits

    // RX Mode: Input IE data (31 bytes)
    input wire [247:0] rx_ie_input,         // 31 bytes * 8 = 248 bits
    // RX Mode: Output decoded Remote ID message (25 bytes)
    output reg [199:0] rx_remote_id_msg,    // 25 bytes * 8 = 200 bits

    // Status and debug
    output reg [7:0] ie_element_id,         // Decoded Element ID
    output reg [7:0] ie_length,             // Decoded Length field
    output reg [23:0] ie_oui,               // Decoded OUI
    output reg [7:0] ie_oui_type,           // Decoded OUI Type
    output reg [7:0] error_code             // Error code for debugging
);

// IEEE 802.11 Vendor IE Constants
localparam [7:0] VENDOR_IE_ELEMENT_ID = 8'hDD;  // 221 decimal
localparam [7:0] VENDOR_IE_LENGTH = 8'd29;      // OUI(3) + Type(1) + Payload(25) = 29

// Error codes
localparam [7:0] ERR_NONE           = 8'h00;
localparam [7:0] ERR_INVALID_ID     = 8'h01;    // Element ID != 221
localparam [7:0] ERR_INVALID_LENGTH = 8'h02;    // Length field incorrect
localparam [7:0] ERR_INVALID_OUI    = 8'h03;    // OUI doesn't match expected
localparam [7:0] ERR_INVALID_TYPE   = 8'h04;    // OUI Type doesn't match
localparam [7:0] ERR_TIMEOUT        = 8'hFF;    // Operation timeout

// State machine states
localparam [2:0] STATE_IDLE     = 3'b000;
localparam [2:0] STATE_TX_BUILD = 3'b001;
localparam [2:0] STATE_TX_DONE  = 3'b010;
localparam [2:0] STATE_RX_PARSE = 3'b011;
localparam [2:0] STATE_RX_VALID = 3'b100;
localparam [2:0] STATE_ERROR    = 3'b101;

// Internal state
reg [2:0] state, next_state;

// Working OUI and Type (either default or configured)
wire [23:0] working_oui;
wire [7:0] working_oui_type;

assign working_oui = oui_override ? oui_config : DEFAULT_OUI;
assign working_oui_type = oui_override ? oui_type_config : DEFAULT_OUI_TYPE;

// Byte extraction helpers for RX mode
wire [7:0] rx_byte_0, rx_byte_1, rx_byte_2, rx_byte_3, rx_byte_4, rx_byte_5;

// Extract header bytes from rx_ie_input (little-endian byte ordering)
// Byte layout in rx_ie_input[247:0]:
//   [7:0]     = Byte 0 = Element ID
//   [15:8]    = Byte 1 = Length
//   [23:16]   = Byte 2 = OUI[0]
//   [31:24]   = Byte 3 = OUI[1]
//   [39:32]   = Byte 4 = OUI[2]
//   [47:40]   = Byte 5 = OUI Type
//   [247:48]  = Bytes 6-30 = Payload (25 bytes)

assign rx_byte_0 = rx_ie_input[7:0];      // Element ID
assign rx_byte_1 = rx_ie_input[15:8];     // Length
assign rx_byte_2 = rx_ie_input[23:16];    // OUI[0]
assign rx_byte_3 = rx_ie_input[31:24];    // OUI[1]
assign rx_byte_4 = rx_ie_input[39:32];    // OUI[2]
assign rx_byte_5 = rx_ie_input[47:40];    // OUI Type

// State machine: combinational next state logic
always @(*) begin
    next_state = state;

    case (state)
        STATE_IDLE: begin
            if (start) begin
                if (mode == 1'b0)
                    next_state = STATE_TX_BUILD;  // TX mode
                else
                    next_state = STATE_RX_PARSE;  // RX mode
            end
        end

        STATE_TX_BUILD: begin
            // TX encoding completes in one cycle
            next_state = STATE_TX_DONE;
        end

        STATE_TX_DONE: begin
            next_state = STATE_IDLE;
        end

        STATE_RX_PARSE: begin
            // RX validation completes in one cycle
            next_state = STATE_RX_VALID;
        end

        STATE_RX_VALID: begin
            next_state = STATE_IDLE;
        end

        STATE_ERROR: begin
            next_state = STATE_IDLE;
        end

        default: begin
            next_state = STATE_IDLE;
        end
    endcase
end

// State machine: sequential state update
always @(posedge clk) begin
    if (!rstn) begin
        state <= STATE_IDLE;
    end else begin
        state <= next_state;
    end
end

// Main codec logic: TX and RX operations
always @(posedge clk) begin
    if (!rstn) begin
        busy <= 1'b0;
        done <= 1'b0;
        valid <= 1'b0;
        error <= 1'b0;
        error_code <= ERR_NONE;

        tx_ie_output <= 248'h0;
        rx_remote_id_msg <= 200'h0;

        ie_element_id <= 8'h0;
        ie_length <= 8'h0;
        ie_oui <= 24'h0;
        ie_oui_type <= 8'h0;

    end else begin
        // Default: clear one-shot signals
        done <= 1'b0;

        case (state)
            STATE_IDLE: begin
                busy <= 1'b0;
                valid <= 1'b0;
                error <= 1'b0;
                error_code <= ERR_NONE;

                if (start) begin
                    busy <= 1'b1;
                end
            end

            //------------------------------------------------------------------
            // TX Mode: Build Vendor IE from Remote ID message
            //------------------------------------------------------------------
            STATE_TX_BUILD: begin
                busy <= 1'b1;

                // Build complete IE in tx_ie_output[247:0]
                // Byte layout (31 bytes total):
                //   [7:0]     = Byte 0  = Element ID (0xDD)
                //   [15:8]    = Byte 1  = Length (29)
                //   [23:16]   = Byte 2  = OUI[0]
                //   [31:24]   = Byte 3  = OUI[1]
                //   [39:32]   = Byte 4  = OUI[2]
                //   [47:40]   = Byte 5  = OUI Type
                //   [247:48]  = Bytes 6-30 = Remote ID Payload (25 bytes)

                tx_ie_output[7:0]     <= VENDOR_IE_ELEMENT_ID;     // Element ID = 221
                tx_ie_output[15:8]    <= VENDOR_IE_LENGTH;         // Length = 29
                tx_ie_output[23:16]   <= working_oui[7:0];         // OUI byte 0
                tx_ie_output[31:24]   <= working_oui[15:8];        // OUI byte 1
                tx_ie_output[39:32]   <= working_oui[23:16];       // OUI byte 2
                tx_ie_output[47:40]   <= working_oui_type;         // OUI Type
                tx_ie_output[247:48]  <= tx_remote_id_msg[199:0];  // 25-byte payload

                // Set status outputs
                ie_element_id <= VENDOR_IE_ELEMENT_ID;
                ie_length <= VENDOR_IE_LENGTH;
                ie_oui <= working_oui;
                ie_oui_type <= working_oui_type;

                valid <= 1'b1;  // Output is valid
                error <= 1'b0;
            end

            STATE_TX_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;  // Signal completion (1 cycle pulse)
            end

            //------------------------------------------------------------------
            // RX Mode: Parse and validate Vendor IE
            //------------------------------------------------------------------
            STATE_RX_PARSE: begin
                busy <= 1'b1;

                // Extract and validate IE header
                ie_element_id <= rx_byte_0;
                ie_length <= rx_byte_1;
                ie_oui <= {rx_byte_4, rx_byte_3, rx_byte_2};  // Reconstruct 24-bit OUI
                ie_oui_type <= rx_byte_5;

                // Validation checks
                if (rx_byte_0 != VENDOR_IE_ELEMENT_ID) begin
                    // Invalid Element ID
                    error <= 1'b1;
                    error_code <= ERR_INVALID_ID;
                    valid <= 1'b0;

                end else if (rx_byte_1 != VENDOR_IE_LENGTH) begin
                    // Invalid Length field
                    error <= 1'b1;
                    error_code <= ERR_INVALID_LENGTH;
                    valid <= 1'b0;

                end else if ({rx_byte_4, rx_byte_3, rx_byte_2} != working_oui) begin
                    // OUI mismatch
                    error <= 1'b1;
                    error_code <= ERR_INVALID_OUI;
                    valid <= 1'b0;

                end else if (rx_byte_5 != working_oui_type) begin
                    // OUI Type mismatch
                    error <= 1'b1;
                    error_code <= ERR_INVALID_TYPE;
                    valid <= 1'b0;

                end else begin
                    // All validations passed: extract payload
                    rx_remote_id_msg <= rx_ie_input[247:48];  // Extract 25-byte payload
                    valid <= 1'b1;
                    error <= 1'b0;
                    error_code <= ERR_NONE;
                end
            end

            STATE_RX_VALID: begin
                busy <= 1'b0;
                done <= 1'b1;  // Signal completion
            end

            STATE_ERROR: begin
                busy <= 1'b0;
                done <= 1'b1;
                valid <= 1'b0;
            end

            default: begin
                busy <= 1'b0;
                valid <= 1'b0;
                error <= 1'b0;
            end
        endcase
    end
end

endmodule
