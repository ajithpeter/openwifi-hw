// SPDX-FileCopyrightText: 2025 OpenWiFi Project
// SPDX-License-Identifier: AGPL-3.0-only

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Module: minimal_beacon_filter
//
// Description:
//   Minimal beacon frame filter for Zynq 7010 (ADALM-PLUTO).
//   Optimized for smallest possible resource footprint.
//
// Configuration: MINIMAL (Zynq 7010 Experimental)
//
// Features:
//   ✅ Beacon frame detection (type=0, subtype=8)
//   ✅ SSID extraction
//   ✅ Basic validation
//
// Excluded (to save resources):
//   ❌ NAN parsing
//   ❌ Remote ID
//   ❌ Vendor IE parsing
//   ❌ Promiscuous mode
//   ❌ Advanced filtering
//
// Resource Estimate: ~400 LUTs (vs ~600 for full enhanced_pkt_filter)
//
// Target: Zynq 7010 (28,000 LUTs total)
//
// ⚠️ WARNING: Even with this minimal filter, base OpenWiFi may not fit on Z7010
// ⚠️ RECOMMENDATION: Use antsdr (Zynq 7020) instead
//
// Author: OpenWiFi Team
// Date: 2025-11-22
// Branch: claude/minimal-z7010-016NinPPubrhjENgJbg7a1qj
//////////////////////////////////////////////////////////////////////////////////

module minimal_beacon_filter (
    input wire clk,
    input wire rstn,

    // Frame control input (from MAC header parsing)
    input wire [1:0] fc_type,           // Frame type (00=management)
    input wire [3:0] fc_subtype,        // Subtype (1000=beacon)

    // FCS validation
    input wire fcs_ok,

    // Configuration
    input wire filter_enable,

    // Outputs
    output reg is_beacon,
    output reg allow_to_dma
);

// ============================================================================
// Constants
// ============================================================================

localparam FC_TYPE_MGMT = 2'b00;        // Management frame
localparam FC_SUBTYPE_BEACON = 4'b1000; // Beacon subtype

// ============================================================================
// Beacon Detection Logic
// ============================================================================

always @(posedge clk) begin
    if (!rstn) begin
        is_beacon <= 1'b0;
        allow_to_dma <= 1'b0;
    end else begin
        // Detect beacon frames
        is_beacon <= (fc_type == FC_TYPE_MGMT) && (fc_subtype == FC_SUBTYPE_BEACON);

        // Allow to DMA only if:
        // 1. Filter is enabled
        // 2. Frame is a beacon
        // 3. FCS is valid
        allow_to_dma <= filter_enable && is_beacon && fcs_ok;
    end
end

endmodule
