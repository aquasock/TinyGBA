// SPDX-License-Identifier: GPL-3.0-only
//
// TinyGBA: vendored verbatim from TinySNES `fpga/snes/src/desk_layer.v` at the
// revision this port started from.  The body below is byte-identical to
// upstream -- only this header is added -- so an upstream defect stays
// distinguishable from a local edit, which is the rule entry 74 of the project
// log set when it vendored the Wii pad master the same way.  Do not edit the
// body; make changes in TinyGBA's own wrapper or in a separate module.
//
// Why it is vendored rather than rewritten.  TinyTang's desktop draws an 80x45
// character grid into whichever core is loaded, and TinyNES, TinyGBC and
// TinySNES all render that grid with this layer; TinyGBA had only the older
// `textdisp` menu, which draws a single character row in one fixed palette and
// cannot show a cell's own foreground and background colours.  Reimplementing
// it would be a second implementation of a solved problem.
//
// Provenance: TinySNES is GPL-3.0, the same licence this repository already
// carries for the GBATang core, and the attribution is recorded in
// THIRD_PARTY.md.  THIRD-PARTY font: the glyph ROM is `font8x8_basic` by
// Daniel Hepper, public domain (see desk_font.hex).
//
// Geometry on this port.  The layer draws cells of 16x16 pixels over the whole
// 1280x720 picture, so 80 columns by 45 rows tile it exactly.  TinyGBA's
// `gba2hdmi` also has a 960x720 window for the legacy text overlay; the desk is
// independent of that window and composites over the full frame.
//
// TinyDesk overlay layer: TinyTang's 80x45 character desk drawn over the whole
// 1280x720 picture, the same layer TinyNES and TinyGBC draw in video.sv.
//
// Cells arrive from iosys_bl616 on the machine clock, one per toggle of wr_tog
// with wr_addr and wr_data already stable; they are written here on the pixel
// clock, so the cell store has a single clock (TOOL-020: a cross-clock block RAM
// is the shape this toolchain has got wrong before).  Each cell is 16x16 pixels:
// an 8x8 glyph from desk_font.hex (font8x8, bit 0 the leftmost pixel) doubled in
// both directions, in a foreground and a background colour.
//
// Timing.  hdmi.sv takes `rgb <= f(cx, cy)` registered once.  The layer runs
// LEAD = 4 pixels ahead: stage 0 registers the position cx+4, stage 1 reads the
// cell, stage 2 the glyph row, stage 3 the colour, so `px`/`rgb` are for the
// current cx and the caller registers them the same way as the rest of the
// picture.  `shown` switches only as row 720 starts, so a frame is never split
// between the desk and the game.
// The font path is relative to this file under read_slang, as the DSP's hex
// files are; simulators resolve it against their working directory, so a bench
// defines TINYSNES_DESK_FONT as the absolute path instead.
`ifndef TINYSNES_DESK_FONT
`define TINYSNES_DESK_FONT "desk_font.hex"
`endif
module desk_layer #(
    parameter FONT_FILE = `TINYSNES_DESK_FONT
) (
    input             clk,          // pixel clock
    input      [10:0] cx,           // hdmi raster, 0..1649
    input      [9:0]  cy,           // 0..749
    input             on,           // iosys desk_on, machine clock
    input             wr_tog,       // iosys, machine clock
    input      [11:0] wr_addr,
    input      [36:0] wr_data,      // {char[6:0], fg[14:0], bg[14:0]}, colours {b,g,r}
    output reg        px = 1'b0,    // the desk owns this pixel
    output reg [23:0] rgb           // {r, g, b}
);
    localparam integer LEAD = 4;
    localparam integer TOTALW = 1650, TOTALH = 750;
    localparam integer W = 1280, H = 720;

    // ------------------------------------------------------ crossings --
    reg [2:0] on_s = 3'd0;
    reg [3:0] tog_s = 4'd0;
    always @(posedge clk) begin
        on_s <= {on_s[1:0], on};
        tog_s <= {tog_s[2:0], wr_tog};
    end
    wire wr = tog_s[3] ^ tog_s[2];

    // ---------------------------------------------------- the stores --
    (* ram_style = "block" *) reg [36:0] cells [0:4095];
    reg [7:0] font [0:1023];
    initial $readmemh(FONT_FILE, font);

    always @(posedge clk)
        if (wr)
            cells[wr_addr] <= wr_data;

    // ------------------------------------------- stage 0: position --
    reg [10:0] hcnt = 11'd0;
    reg [9:0]  vcnt = 10'd0;
    always @(posedge clk) begin
        if (cx >= TOTALW - LEAD) begin
            hcnt <= cx - (TOTALW - LEAD);
            vcnt <= cy == TOTALH - 1 ? 10'd0 : cy + 10'd1;
        end else begin
            hcnt <= cx + LEAD;
            vcnt <= cy;
        end
    end

    reg shown = 1'b0;
    always @(posedge clk)
        if (hcnt == 11'd0 && vcnt == H)
            shown <= on_s[2];

    // ----------------------------------------------- stage 1: cell ----
    wire [11:0] addr = {vcnt[9:4], 6'd0} + {2'd0, vcnt[9:4], 4'd0} + {5'd0, hcnt[10:4]};
    reg [36:0] cell_q;
    reg [2:0] col1, row1;
    reg de1 = 1'b0;
    always @(posedge clk) begin
        cell_q <= cells[addr];
        col1 <= hcnt[3:1];
        row1 <= vcnt[3:1];
        de1 <= shown && hcnt < W && vcnt < H;
    end

    // ---------------------------------------------- stage 2: glyph --
    reg [7:0] glyph;
    reg [29:0] colours;
    reg [2:0] col2;
    reg de2 = 1'b0;
    always @(posedge clk) begin
        glyph <= font[{cell_q[36:30], row1}];
        colours <= cell_q[29:0];
        col2 <= col1;
        de2 <= de1;
    end

    // --------------------------------------------- stage 3: colour --
    wire [14:0] c = glyph[col2] ? colours[29:15] : colours[14:0];
    always @(posedge clk) begin
        px <= de2;
        rgb <= {c[4:0], c[4:2], c[9:5], c[9:7], c[14:10], c[14:12]};
    end
endmodule
