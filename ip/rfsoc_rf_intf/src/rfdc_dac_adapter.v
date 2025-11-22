// SPDX-FileCopyrightText: 2025 UGent
// SPDX-License-Identifier: AGPL-3.0-or-later

`timescale 1 ns / 1 ps

// RFDC DAC Adapter for OpenWiFi
// Converts OpenWiFi tx_intf output to RFSoC RF Data Converter DAC format
// Handles:
// - Parallel to AXI-Stream conversion
// - Sample rate conversion (20 MSPS WiFi → RFDC rate)
// - Data width adaptation
// - Multi-channel support

module rfdc_dac_adapter #(
    parameter integer RFDC_AXIS_TDATA_WIDTH = 128,  // RF-DAC AXI-Stream width
    parameter integer IQ_DATA_WIDTH = 16,            // OpenWiFi IQ width
    parameter integer OPENWIFI_DATA_WIDTH = 64,     // OpenWiFi provides 64-bit
    parameter integer NUM_CHANNELS = 2,              // Number of RF channels
    parameter integer INTERPOLATION_RATIO = 12       // RFDC rate / WiFi rate
)(
    // Clock and reset
    input wire openwifi_clk,                        // OpenWiFi baseband clock (100 MHz)
    input wire rfdc_dac_clk,                        // DAC fabric clock (e.g., 250 MHz)
    input wire rstn,

    // Parallel input from OpenWiFi tx_intf (AD9361-compatible format)
    input wire [OPENWIFI_DATA_WIDTH-1:0] dac_data,
    input wire dac_data_valid,

    // AXI-Stream output to RFDC DAC (Tile 0, Channel 0)
    output wire [RFDC_AXIS_TDATA_WIDTH-1:0] m_axis_dac0_tdata,
    output wire m_axis_dac0_tvalid,
    input wire m_axis_dac0_tready,

    // AXI-Stream output to RFDC DAC (Tile 1, Channel 0) - optional
    output wire [RFDC_AXIS_TDATA_WIDTH-1:0] m_axis_dac1_tdata,
    output wire m_axis_dac1_tvalid,
    input wire m_axis_dac1_tready,

    // Control
    input wire [1:0] ant_sel,                       // Antenna selection/diversity
    input wire [1:0] mimo_mode,                     // 0=SISO, 1=CDD, 2=MIMO
    output wire [7:0] status
);

    // Internal signals
    wire [IQ_DATA_WIDTH-1:0] i0_data, q0_data;
    wire [IQ_DATA_WIDTH-1:0] i1_data, q1_data;

    // Unpack OpenWiFi format: {I1, Q1, I0, Q0}
    assign i0_data = dac_data[15:0];
    assign q0_data = dac_data[31:16];
    assign i1_data = dac_data[47:32];
    assign q1_data = dac_data[63:48];

    // CDC FIFO for clock domain crossing
    wire [RFDC_AXIS_TDATA_WIDTH-1:0] dac_fifo_in;
    wire dac_fifo_wr_en;
    wire [RFDC_AXIS_TDATA_WIDTH-1:0] dac_fifo_out;
    wire dac_fifo_rd_en;
    wire dac_fifo_empty, dac_fifo_full;

    // Pack to RFDC format
    // Format: [63:0]=CH0 I/Q, [127:64]=CH1 I/Q (or duplicate for diversity)
    assign dac_fifo_in = {q1_data, i1_data, q0_data, i0_data,
                          q1_data, i1_data, q0_data, i0_data};  // Duplicate for both channels
    assign dac_fifo_wr_en = dac_data_valid;

    // Clock domain crossing FIFO (OpenWiFi clock → RFDC clock)
    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("auto"),
        .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(512),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(500),
        .RD_DATA_COUNT_WIDTH(9),
        .READ_DATA_WIDTH(RFDC_AXIS_TDATA_WIDTH),
        .READ_MODE("fwft"),
        .RELATED_CLOCKS(0),
        .USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(RFDC_AXIS_TDATA_WIDTH),
        .WR_DATA_COUNT_WIDTH(9)
    ) dac_cdc_fifo (
        .rst(!rstn),
        .wr_clk(openwifi_clk),
        .wr_en(dac_fifo_wr_en),
        .din(dac_fifo_in),
        .full(dac_fifo_full),
        .rd_clk(rfdc_dac_clk),
        .rd_en(dac_fifo_rd_en),
        .dout(dac_fifo_out),
        .empty(dac_fifo_empty),
        .rd_data_count(),
        .wr_data_count(),
        .overflow(),
        .underflow(),
        .prog_full(),
        .prog_empty(),
        .sleep(1'b0),
        .injectdbiterr(1'b0),
        .injectsbiterr(1'b0),
        .dbiterr(),
        .sbiterr()
    );

    // Interpolation logic
    reg [$clog2(INTERPOLATION_RATIO)-1:0] interp_count;
    reg [RFDC_AXIS_TDATA_WIDTH-1:0] dac_data_hold;
    reg dac_valid_reg;

    always @(posedge rfdc_dac_clk) begin
        if (!rstn) begin
            interp_count <= 0;
            dac_data_hold <= 0;
            dac_valid_reg <= 1'b0;
        end else begin
            if (m_axis_dac0_tready) begin
                if (interp_count == 0) begin
                    // Load new sample from FIFO
                    if (!dac_fifo_empty) begin
                        dac_data_hold <= dac_fifo_out;
                        dac_valid_reg <= 1'b1;
                        interp_count <= INTERPOLATION_RATIO - 1;
                    end else begin
                        dac_data_hold <= 0;  // Output zeros when no data
                        dac_valid_reg <= 1'b0;
                    end
                end else begin
                    // Interpolate (zero-stuffing for simplicity)
                    // For better quality, could use FIR interpolation filter
                    dac_data_hold <= 0;
                    dac_valid_reg <= 1'b1;  // Keep valid to maintain rate
                    interp_count <= interp_count - 1;
                end
            end
        end
    end

    assign dac_fifo_rd_en = (interp_count == 0) && m_axis_dac0_tready && !dac_fifo_empty;

    // Output AXI-Stream
    assign m_axis_dac0_tdata = dac_data_hold;
    assign m_axis_dac0_tvalid = dac_valid_reg;

    // For dual channel, could split or duplicate data
    assign m_axis_dac1_tdata = dac_data_hold;
    assign m_axis_dac1_tvalid = dac_valid_reg;

    // Status
    assign status = {5'b0, dac_fifo_full, dac_fifo_empty, dac_valid_reg};

endmodule
