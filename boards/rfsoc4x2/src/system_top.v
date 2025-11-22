`timescale 1 ns / 1 ps

//  OpenWiFi RFSoC4x2 Top-Level Module
//  RFSoC platform with integrated RF Data Converters
//  Replaces AD9361 external transceiver with on-chip ADC/DAC

module system_top
(
    // DDR4 interfaces (PS DDR)
    inout [15:0] ddr4_dq,
    inout [1:0] ddr4_dqs_n,
    inout [1:0] ddr4_dqs_p,
    output [16:0] ddr4_addr,
    output [0:0] ddr4_ba,
    output [0:0] ddr4_bg,
    output ddr4_ras_n,
    output ddr4_cas_n,
    output ddr4_we_n,
    output ddr4_reset_n,
    output [0:0] ddr4_ck_p,
    output [0:0] ddr4_ck_n,
    output [0:0] ddr4_cke,
    output [0:0] ddr4_cs_n,
    output [1:0] ddr4_dm_n,
    output [0:0] ddr4_odt,

    // GPIO LEDs (for status indication)
    output [1:0] gpio_led,

    // Optional: PMOD for debug
    // inout [7:0] pmod0,

    // Optional: External clock inputs (if not using internal clocks)
    // input sysref_in_p,
    // input sysref_in_n,
    // input ref_clk_p,
    // input ref_clk_n,

    // UART (for console/debug)
    // output uart_tx,
    // input uart_rx,

    // I2C (for clock chip configuration if external)
    // inout iic_scl,
    // inout iic_sda
);

// Note: RFSoC4x2 has integrated RF Data Converters
// No external RF pins needed (ADC/DAC tiles are internal)
// RF signal paths are through on-chip analog front-end

// Instantiate the block design wrapper
system_wrapper system_wrapper_i (
    // DDR4
    .ddr4_dq(ddr4_dq),
    .ddr4_dqs_n(ddr4_dqs_n),
    .ddr4_dqs_p(ddr4_dqs_p),
    .ddr4_addr(ddr4_addr),
    .ddr4_ba(ddr4_ba),
    .ddr4_bg(ddr4_bg),
    .ddr4_ras_n(ddr4_ras_n),
    .ddr4_cas_n(ddr4_cas_n),
    .ddr4_we_n(ddr4_we_n),
    .ddr4_reset_n(ddr4_reset_n),
    .ddr4_ck_p(ddr4_ck_p),
    .ddr4_ck_n(ddr4_ck_n),
    .ddr4_cke(ddr4_cke),
    .ddr4_cs_n(ddr4_cs_n),
    .ddr4_dm_n(ddr4_dm_n),
    .ddr4_odt(ddr4_odt),

    // GPIO
    .gpio_led(gpio_led)

    // Add other connections as needed
);

endmodule
