// SPDX-License-Identifier: GPL-3.0-only
//
// Internal work RAM: 32 KB, single-port, 32 bits wide.
//
// Sixteen BSRAM blocks, but not sixteen banks: the word is 32 bits and a block
// holds 16 bits at its widest, so the word is split into a low and a high
// halfword, each with its own eight banks.  Blocks 0..7 carry `din[15:0]` and
// blocks 8..15 carry `din[31:16]`, which is why two instances always share a
// `BLK_SEL` value -- they are the two halves of one bank, addressed together
// and enabled together, and only their data slices differ.
//
// The address splits three ways.  Bits [12:10] choose the bank, and are what
// `BLKSEL` carries.  Bits [9:4] are the word address inside a block, since a
// 16-bit port shifts the 14-bit block address field by four and leaves bits
// [1:0] free.  Those two free bits are the byte write strobes: an SP block
// writes in 16-bit units, so a halfword write is enabled only when either of
// its bytes is.
//
// The bank select is registered on the launching edge and gated by `ce & ~wre`,
// the same discipline the EEPROM window uses: block RAM returns its word the
// cycle after the address arrives, so the select must be held for that cycle,
// and gating it on the read enable keeps the output at its previous value
// through a write instead of redirecting it at the bytes being written.
//
// This file restates a memory that was formerly Gowin IP-generator output; see
// TCL-065 and TCL-072.  The primitive's port and parameter names are the
// device's published interface, not this project's invention.

module iwram_ram (
    input  wire        clk,
    input  wire        ce,
    input  wire        oce,
    input  wire        reset,
    input  wire        wre,
    input  wire [12:0] ad,
    input  wire [31:0] din,
    input  wire [3:0]  byte_en,
    output wire [31:0] dout
);

    // Eight banks, each a low halfword and a high halfword.
    // The primitive's data port is 32 bits wide; a 16-bit block drives the
    // half its BIT_WIDTH selects, so the array is 32 bits and sliced here.
    wire [31:0] do_lo [0:7];
    wire [31:0] do_hi [0:7];

    wire [2:0] blksel = ad[12:10];
    wire [13:0] ad_blk = {ad[9:0], 2'b00, 2'b00};

    // Bank select for the output mux, one cycle ahead of the data it selects.
    reg  [2:0] bank;
    always @(posedge clk)
        if (ce & ~wre) bank <= blksel;

    assign dout = {do_hi[bank][15:0], do_lo[bank][15:0]};

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : bank_i
            // Byte strobes pass straight into the block's free address bits:
            // an SP block writes 16 bits at a time, and these two bits select
            // which half of that 16-bit word the write applies to.
            // Low halfword of the word.
            SP u_lo (
                .DO      (do_lo[i]),
                .DI      ({16'b0, din[15:0]}),
                .BLKSEL  (blksel),
                .AD      ({ad[9:0], 2'b00, byte_en[1:0]}),
                .WRE     (wre),
                .CLK     (clk),
                .CE      (ce),
                .OCE     (oce),
                .RESET   (reset)
            );
            defparam u_lo.READ_MODE  = 1'b0;
            defparam u_lo.WRITE_MODE = 2'b00;
            defparam u_lo.BIT_WIDTH  = 16;
            defparam u_lo.BLK_SEL    = i[2:0];
            defparam u_lo.RESET_MODE = "SYNC";

            // High halfword of the same word, same bank, same enable.
            SP u_hi (
                .DO      (do_hi[i]),
                .DI      ({16'b0, din[31:16]}),
                .BLKSEL  (blksel),
                .AD      ({ad[9:0], 2'b00, byte_en[3:2]}),
                .WRE     (wre),
                .CLK     (clk),
                .CE      (ce),
                .OCE     (oce),
                .RESET   (reset)
            );
            defparam u_hi.READ_MODE  = 1'b0;
            defparam u_hi.WRITE_MODE = 2'b00;
            defparam u_hi.BIT_WIDTH  = 16;
            defparam u_hi.BLK_SEL    = i[2:0];
            defparam u_hi.RESET_MODE = "SYNC";
        end
    endgenerate

endmodule
