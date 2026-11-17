// SPDX-License-Identifier: GPL-3.0-only
//
// TinyGBA: colour-bar test pattern for the TinyDesk overlay.
//
// Why this exists.  The desk layer is vendored from TinySNES and draws cells
// that TinyTang's desktop normally sends over the OSD link.  Before trusting a
// live desktop, the layer, its cell store, its glyph ROM and the compositing
// all need to be shown working on THIS port -- the geometry here is a different
// raster from TinyNES/TinyGBC/TinySNES, and a fault anywhere in the chain would
// otherwise show up as a garbled desktop that gives no clue which part is wrong.
//
// So this module fills the cell grid with a fixed pattern and nothing else:
// eight vertical colour bars as cell backgrounds, with a row of glyphs across
// the top so the font path is exercised too.  It drives the same write port the
// desktop uses, so what it tests is exactly the path the desktop will take.
//
// Expected picture: eight equal vertical bars, left to right white, yellow,
// cyan, green, magenta, red, blue, black, each 160 pixels wide and the full
// 720-pixel height, with "TINYGBA DESK" in black across the top-left.  A wrong
// bar order means a colour channel is swapped; bars of the wrong width mean the
// cell addressing is wrong; missing text means the font ROM or glyph row
// addressing is wrong; no bars at all means the enable or compositing path is
// wrong.  Each of those is a different fault and this pattern separates them.
//
// Selected with -DTINYGBA_DESK_TEST.  Production builds do not instantiate it.

module desk_test_pattern (
    input  wire        clk,        // machine clock, the desk layer's wr_tog domain
    input  wire        resetn,
    output reg         wr_tog,
    output reg  [11:0] wr_addr,
    output reg  [36:0] wr_data,    // {char[6:0], fg[14:0], bg[14:0]}, colours {b,g,r}
    output reg         ready       // high once every cell has been written
);

    localparam integer COLS  = 80;
    localparam integer ROWS  = 45;

    // A 5-bit-per-channel colour, packed the way desk_layer unpacks it:
    // red is c[4:0], green c[9:5], blue c[14:10].
    function automatic [14:0] rgb15(input [7:0] r, input [7:0] g, input [7:0] b);
        rgb15 = {b[7:3], g[7:3], r[7:3]};
    endfunction

    // Eight bars of ten columns each, in the order a colour-bar generator uses,
    // so a channel swap shows up as an out-of-order bar rather than as a
    // plausible-looking gradient.
    function automatic [14:0] bar_colour(input [2:0] idx);
        case (idx)
        3'd0: bar_colour = rgb15(8'hFF, 8'hFF, 8'hFF);   // white
        3'd1: bar_colour = rgb15(8'hFF, 8'hFF, 8'h00);   // yellow
        3'd2: bar_colour = rgb15(8'h00, 8'hFF, 8'hFF);   // cyan
        3'd3: bar_colour = rgb15(8'h00, 8'hFF, 8'h00);   // green
        3'd4: bar_colour = rgb15(8'hFF, 8'h00, 8'hFF);   // magenta
        3'd5: bar_colour = rgb15(8'hFF, 8'h00, 8'h00);   // red
        3'd6: bar_colour = rgb15(8'h00, 8'h00, 8'hFF);   // blue
        default: bar_colour = rgb15(8'h00, 8'h00, 8'h00); // black
        endcase
    endfunction

    // "TINYGBA DESK" on the top row, in black so it reads against every bar
    // beneath it except the last.
    localparam integer LABEL_LEN = 12;
    function automatic [6:0] label_char(input [3:0] i);
        case (i)
        4'd0:  label_char = 7'h54;  // T
        4'd1:  label_char = 7'h49;  // I
        4'd2:  label_char = 7'h4E;  // N
        4'd3:  label_char = 7'h59;  // Y
        4'd4:  label_char = 7'h47;  // G
        4'd5:  label_char = 7'h42;  // B
        4'd6:  label_char = 7'h41;  // A
        4'd7:  label_char = 7'h20;  // space
        4'd8:  label_char = 7'h44;  // D
        4'd9:  label_char = 7'h45;  // E
        4'd10: label_char = 7'h53;  // S
        default: label_char = 7'h4B; // K
        endcase
    endfunction

    // ---------------------------------------------------------- the sweep --
    //
    // Row and column are counted separately rather than derived from a linear
    // index: eighty is not a power of two, so `idx / 80` would ask synthesis for
    // a divider to produce a number that two counters already have.
    //
    // Each cell is presented for four clocks and the toggle moves once per cell.
    // The layer samples wr_tog through a four-deep synchroniser and writes on
    // the edge it sees, so a toggle every clock would be faster than that
    // synchroniser can follow and cells would be dropped -- the same reason
    // TinyTang's firmware toggles once per completed cell rather than per byte.
    // col needs SEVEN bits: COLS is 80, and a six-bit counter tops out at 63,
    // so `col == COLS-1` never fires and the row counter never advances.  That
    // is not a hypothetical -- it is what the first hardware run of this module
    // did, drawing six colour bars and then overwriting them forever.  row
    // needs six bits for 0..44.
    reg [6:0]  col   = 7'd0;
    reg [5:0]  row   = 6'd0;
    reg [2:0]  tick  = 3'd0;
    reg        done  = 1'b0;

    // Ten columns per bar, as a priority chain rather than `col / 10`: eighty
    // is not a power of two, and a divide on the clock path is worth avoiding
    // even in a one-shot sweep because it is the kind of cell that quietly
    // changes where synthesis puts everything else.
    function automatic [2:0] bar_of(input [6:0] c);
        if      (c < 6'd10) bar_of = 3'd0;
        else if (c < 6'd20) bar_of = 3'd1;
        else if (c < 6'd30) bar_of = 3'd2;
        else if (c < 6'd40) bar_of = 3'd3;
        else if (c < 6'd50) bar_of = 3'd4;
        else if (c < 6'd60) bar_of = 3'd5;
        else if (c < 6'd70) bar_of = 3'd6;
        else                bar_of = 3'd7;
    endfunction

    wire [2:0] bar       = bar_of(col);
    wire       on_label  = (row == 6'd0) && (col < LABEL_LEN);

    always @(posedge clk) begin
        if (~resetn) begin
            col     <= 7'd0;
            row     <= 6'd0;
            tick    <= 3'd0;
            done    <= 1'b0;
            wr_tog  <= 1'b0;
            wr_addr <= 12'd0;
            wr_data <= 37'd0;
            ready   <= 1'b0;
        end else if (~done) begin
            // Address and data hold for the whole four-clock period, which is
            // what the layer requires of wr_addr/wr_data about wr_tog.
            wr_addr <= row * COLS + col;
            wr_data <= {on_label ? label_char(col[3:0]) : 7'h20,   // char
                        15'd0,                                     // fg: black
                        bar_colour(bar)};                          // bg: the bar
            // The layer registers wr_tog through a four-deep synchroniser and
            // writes on the edge it sees, so the write lands four clocks after
            // the toggle.  The address must therefore still be held at that
            // point: toggling in a four-clock period puts the write one clock
            // after the address advances, which writes the NEXT cell, and a
            // four-deep period is what the arithmetic below rules out.  Eight
            // clocks leaves the address stable for the whole latency.
            if (tick == 3'd1)
                wr_tog <= ~wr_tog;             // one edge per cell, mid-period
            tick <= tick + 2'd1;
            if (tick == 3'd7) begin
                if (col == COLS - 1) begin
                    col <= 7'd0;
                    if (row == ROWS - 1) begin
                        done  <= 1'b1;
                        ready <= 1'b1;
                    end else begin
                        row <= row + 6'd1;
                    end
                end else begin
                    col <= col + 7'd1;
                end
            end
        end
    end

endmodule
