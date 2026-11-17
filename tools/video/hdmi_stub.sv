// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

// Stand-in for the HDMI serialiser, for simulation only.  Adapted from
// TinySNES `tools/tests/hdmi_stub.sv` (same author, GPL-3.0-only).
//
// gba2hdmi instantiates the hdl-util `hdmi` transmitter, built around Gowin
// OSER10 primitives and differential output buffers, none of which simulate
// here and none of which the boot-screen question needs: the serialiser
// has drawn pictures on this board since the first image (BRD-119 among others).
//
// So this keeps the transmitter's interface and replaces its body with a raster
// generator: cx and cy walk the 1650x750 frame exactly as the real one does,
// from zero at time zero, which is also how gba2hdmi drives it (`reset` is tied
// low).  Everything gba2hdmi does with cx and cy -- the scaling counters, the
// frame-buffer read, the colour decision -- runs unmodified against it.
module hdmi
#(
    parameter int  VIDEO_ID_CODE = 1,
    parameter bit  IT_CONTENT = 1'b1,
    parameter int  BIT_WIDTH = 11,
    parameter int  BIT_HEIGHT = 10,
    parameter bit  DVI_OUTPUT = 1'b0,
    parameter real VIDEO_REFRESH_RATE = 59.94,
    parameter int  AUDIO_RATE = 44100,
    parameter int  AUDIO_BIT_WIDTH = 16,
    parameter bit [8*8-1:0]   VENDOR_NAME = {"Unknown", 8'd0},
    parameter bit [8*16-1:0]  PRODUCT_DESCRIPTION = {"FPGA", 96'd0},
    parameter bit [7:0] SOURCE_DEVICE_INFORMATION = 8'h00,
    parameter int  START_X = 0,
    parameter int  START_Y = 0
)
(
    input  logic clk_pixel_x5,
    input  logic clk_pixel,
    input  logic clk_audio,
    input  logic reset,
    input  logic [23:0] rgb,
    input  logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],

    output logic [2:0] tmds,
    output logic tmds_clock,

    output logic [BIT_WIDTH-1:0]  cx = START_X,
    output logic [BIT_HEIGHT-1:0] cy = START_Y,
    output logic [BIT_WIDTH-1:0]  frame_width,
    output logic [BIT_HEIGHT-1:0] frame_height,
    output logic [BIT_WIDTH-1:0]  screen_width,
    output logic [BIT_HEIGHT-1:0] screen_height
);

    localparam int TOTALWIDTH  = 1650;
    localparam int TOTALHEIGHT = 750;

    initial begin
        frame_width   = TOTALWIDTH;
        frame_height  = TOTALHEIGHT;
        screen_width  = 1280;
        screen_height = 720;
    end

    always @(posedge clk_pixel) begin
        if (reset) begin
            cx <= START_X;
            cy <= START_Y;
        end else if (cx == TOTALWIDTH - 1) begin
            cx <= 0;
            cy <= (cy == TOTALHEIGHT - 1) ? '0 : cy + 1'b1;
        end else begin
            cx <= cx + 1'b1;
        end
    end

    assign tmds       = 3'b000;
    assign tmds_clock = 1'b0;

endmodule

// Stand-in for the Gowin differential output buffer.
module ELVDS_OBUF (input I, output O, output OB);
    assign O  = I;
    assign OB = ~I;
endmodule
