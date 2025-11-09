/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_79054_soc_maveric (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
  wire uart_rx;
  wire uart_tx;


  // All output pins must be assigned. If not used, assign to 0.
  assign uo_out[0] = 1'b1;
  assign uo_out[7:1] = 7'b0;
  assign uart_rx = ui_in[0];

  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, 1'b0, ui_in[7:1], uio_in, uart_rx};


  soc SOC_TOP (
    .clock   (clk),
    .reset   (~rst_n)
    // .uart_rx (uart_rx),
    // .uart_tx (uart_tx)
  );

endmodule
