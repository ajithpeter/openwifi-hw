// SPDX-FileCopyrightText: 2025 UGent
// SPDX-License-Identifier: AGPL-3.0-or-later

`timescale 1 ns / 1 ps

// RFDC ADC Adapter for OpenWiFi
// Converts RFSoC RF Data Converter ADC output to OpenWiFi rx_intf format
// Handles:
// - AXI-Stream to parallel conversion
// - Sample rate conversion (RFDC rate → 20 MSPS WiFi baseband)
// - Data width adaptation
// - Multi-channel support

module rfdc_adc_adapter #(
    parameter integer RFDC_AXIS_TDATA_WIDTH = 128,  // RF-ADC AXI-Stream width
    parameter integer IQ_DATA_WIDTH = 16,            // OpenWiFi IQ width
    parameter integer OPENWIFI_DATA_WIDTH = 64,     // OpenWiFi expects 64-bit
    parameter integer NUM_CHANNELS = 2,              // Number of RF channels
    parameter integer DECIMATION_RATIO = 12          // RFDC rate / WiFi rate
)(
    // Clock and reset
    input wire rfdc_adc_clk,                        // ADC fabric clock (e.g., 250 MHz)
    input wire openwifi_clk,                        // OpenWiFi baseband clock (100 MHz)
    input wire rstn,

    // AXI-Stream input from RFDC ADC (Tile 0, Channel 0)
    input wire [RFDC_AXIS_TDATA_WIDTH-1:0] s_axis_adc0_tdata,
    input wire s_axis_adc0_tvalid,
    output wire s_axis_adc0_tready,

    // AXI-Stream input from RFDC ADC (Tile 1, Channel 0) - optional
    input wire [RFDC_AXIS_TDATA_WIDTH-1:0] s_axis_adc1_tdata,
    input wire s_axis_adc1_tvalid,
    output wire s_axis_adc1_tready,

    // Parallel output to OpenWiFi rx_intf (AD9361-compatible format)
    output wire [OPENWIFI_DATA_WIDTH-1:0] adc_data,
    output wire adc_data_valid,

    // Control/status
    input wire [2:0] bb_gain,                       // Baseband gain control
    input wire ant_sel,                             // Antenna selection (if not MIMO)
    output wire [7:0] status
);

    // Internal signals
    reg [IQ_DATA_WIDTH-1:0] i0_data, q0_data;
    reg [IQ_DATA_WIDTH-1:0] i1_data, q1_data;
    reg data_valid_int;

    // Decimation counter
    reg [$clog2(DECIMATION_RATIO)-1:0] decim_count;
    wire decim_strobe;

    // CDC FIFO for clock domain crossing
    wire [RFDC_AXIS_TDATA_WIDTH-1:0] adc0_fifo_out;
    wire adc0_fifo_valid, adc0_fifo_ready;

    // Decimation strobe generation
    assign decim_strobe = (decim_count == 0);

    always @(posedge rfdc_adc_clk) begin
        if (!rstn) begin
            decim_count <= 0;
        end else if (s_axis_adc0_tvalid && s_axis_adc0_tready) begin
            if (decim_count == DECIMATION_RATIO - 1)
                decim_count <= 0;
            else
                decim_count <= decim_count + 1;
        end
    end

    // Clock domain crossing FIFO (RFDC clock → OpenWiFi clock)
    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("auto"),
        .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(256),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(246),
        .RD_DATA_COUNT_WIDTH(8),
        .READ_DATA_WIDTH(RFDC_AXIS_TDATA_WIDTH),
        .READ_MODE("fwft"),
        .RELATED_CLOCKS(0),
        .USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(RFDC_AXIS_TDATA_WIDTH),
        .WR_DATA_COUNT_WIDTH(8)
    ) adc0_cdc_fifo (
        .rst(!rstn),
        .wr_clk(rfdc_adc_clk),
        .wr_en(s_axis_adc0_tvalid && decim_strobe),
        .din(s_axis_adc0_tdata),
        .full(),
        .rd_clk(openwifi_clk),
        .rd_en(adc0_fifo_ready),
        .dout(adc0_fifo_out),
        .empty(!adc0_fifo_valid),
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

    assign adc0_fifo_ready = 1'b1;  // Always ready to read
    assign s_axis_adc0_tready = 1'b1;  // Always ready for input
    assign s_axis_adc1_tready = 1'b1;

    // Data unpacking (RFDC format → OpenWiFi IQ format)
    // Assumes RFDC provides packed I/Q samples in lower bits
    // RFDC_AXIS_TDATA_WIDTH=128: [63:0]=CH0 I/Q, [127:64]=CH1 I/Q
    always @(posedge openwifi_clk) begin
        if (!rstn) begin
            i0_data <= 0;
            q0_data <= 0;
            i1_data <= 0;
            q1_data <= 0;
            data_valid_int <= 1'b0;
        end else begin
            if (adc0_fifo_valid) begin
                // Extract I/Q data (assuming 16-bit samples)
                i0_data <= adc0_fifo_out[15:0];
                q0_data <= adc0_fifo_out[31:16];
                i1_data <= adc0_fifo_out[47:32];
                q1_data <= adc0_fifo_out[63:48];

                // Apply baseband gain (bit shift)
                case (bb_gain)
                    3'd1: begin
                        i0_data <= adc0_fifo_out[14:0] << 1;
                        q0_data <= adc0_fifo_out[30:15] << 1;
                        i1_data <= adc0_fifo_out[46:31] << 1;
                        q1_data <= adc0_fifo_out[62:47] << 1;
                    end
                    3'd2: begin
                        i0_data <= adc0_fifo_out[13:0] << 2;
                        q0_data <= adc0_fifo_out[29:14] << 2;
                        i1_data <= adc0_fifo_out[45:30] << 2;
                        q1_data <= adc0_fifo_out[61:46] << 2;
                    end
                    // Add more gain settings as needed
                    default: begin
                        i0_data <= adc0_fifo_out[15:0];
                        q0_data <= adc0_fifo_out[31:16];
                        i1_data <= adc0_fifo_out[47:32];
                        q1_data <= adc0_fifo_out[63:48];
                    end
                endcase

                data_valid_int <= 1'b1;
            end else begin
                data_valid_int <= 1'b0;
            end
        end
    end

    // Pack to OpenWiFi format: {I1, Q1, I0, Q0}
    assign adc_data = {i1_data, q1_data, i0_data, q0_data};
    assign adc_data_valid = data_valid_int;

    // Status output
    assign status = {6'b0, adc0_fifo_valid, data_valid_int};

endmodule
