// SPDX-License-Identifier: GPL-3.0-only
//
// The high half of VRAM: 8192 words of 32 bits, in sixteen BSRAM blocks.
//
// Structurally the same as `iwram_ram`: sixteen blocks are eight banks of two
// halfword slices, not sixteen banks. A block is sixteen bits at its widest and
// the word is thirty-two, so instances 0..7 carry `dina[15:0]` and 8..15 carry
// `dina[31:16]`, and two instances always share a `BLK_SEL` value because they
// are the two halves of one bank, addressed and enabled together.
//
// The difference from `iwram_ram` is that this memory is genuinely dual-port
// with independent clocks: `clka` and `clkb` run on different domains, so the
// bank select feeding each port's output multiplexer is registered separately,
// on that port's own clock. Six registers in the vendor's version -- three bits
// per port -- and each port's group is gated by `~wre & ce` for that port, so a
// write on one side leaves that side's select where it was and its output at
// the previous value.
//
// Address: bits [12:10] are the bank and are what `BLKSEL` carries; bits [9:0]
// are the word address inside a block, with the block's two spare address bits
// carrying the byte write strobes for that halfword. A 16-bit port is written
// in halfword units, so a strobe pair gates its slice.
//
// This file restates a memory that was formerly Gowin IP-generator output; see
// TCL-065 and TCL-075. The primitive's port and parameter names are the
// device's published interface, not this project's invention.

module vram_hi_ram (
    input  wire        clka,
    input  wire        cea,
    input  wire        ocea,
    input  wire        reseta,
    input  wire        wrea,
    input  wire [12:0] ada,
    input  wire [31:0] dina,
    input  wire [3:0]  byte_ena,
    output wire [31:0] douta,

    input  wire        clkb,
    input  wire        ceb,
    input  wire        oceb,
    input  wire        resetb,
    input  wire        wreb,
    input  wire [12:0] adb,
    input  wire [31:0] dinb,
    input  wire [3:0]  byte_enb,
    output wire [31:0] doutb
);

    // Eight banks, each a low halfword and a high halfword.
    wire [15:0] doa_lo [0:7];
    wire [15:0] doa_hi [0:7];
    wire [15:0] dob_lo [0:7];
    wire [15:0] dob_hi [0:7];

    // Each half needs its own strobe pair: the low halfword is gated by
    // `byte_en[1:0]` and the high by `byte_en[3:2]`, and both go in the block's
    // two spare address bits.
    wire [13:0] ada_lo_blk = {ada[9:0], 2'b00, byte_ena[1:0]};
    wire [13:0] ada_hi_blk = {ada[9:0], 2'b00, byte_ena[3:2]};
    wire [13:0] adb_lo_blk = {adb[9:0], 2'b00, byte_enb[1:0]};
    wire [13:0] adb_hi_blk = {adb[9:0], 2'b00, byte_enb[3:2]};

    wire [2:0] bank_a = ada[12:10];
    wire [2:0] bank_b = adb[12:10];

    // Bank select for each port's output mux, registered on that port's clock
    // and held through a write, so a write does not redirect the mux at the
    // bytes being written.
    reg  [2:0] bank_a_q, bank_b_q;

    always @(posedge clka)
        if (cea & ~wrea) bank_a_q <= bank_a;

    always @(posedge clkb)
        if (ceb & ~wreb) bank_b_q <= bank_b;

    assign douta = {doa_hi[bank_a_q], doa_lo[bank_a_q]};
    assign doutb = {dob_hi[bank_b_q], dob_lo[bank_b_q]};

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : bank_i
            // Low halfword of the word: `dina[15:0]`, strobes [1:0].
            DPB u_lo (
                .DOA     (doa_lo[i]),
                .DOB     (dob_lo[i]),
                .CLKA    (clka),
                .CEA     (cea),
                .OCEA    (ocea),
                .RESETA  (reseta),
                .WREA    (wrea),
                .BLKSELA (bank_a),
                .ADA     (ada_lo_blk),
                .DIA     (dina[15:0]),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB (bank_b),
                .ADB     (adb_lo_blk),
                .DIB     (dinb[15:0])
            );
            defparam u_lo.READ_MODE0  = 1'b0;
            defparam u_lo.READ_MODE1  = 1'b0;
            defparam u_lo.WRITE_MODE0 = 2'b00;
            defparam u_lo.WRITE_MODE1 = 2'b00;
            defparam u_lo.BIT_WIDTH_0 = 16;
            defparam u_lo.BIT_WIDTH_1 = 16;
            defparam u_lo.BLK_SEL_0   = i[2:0];
            defparam u_lo.BLK_SEL_1   = i[2:0];
            defparam u_lo.RESET_MODE  = "SYNC";

            // High halfword of the same word, same bank, same enable.
            DPB u_hi (
                .DOA     (doa_hi[i]),
                .DOB     (dob_hi[i]),
                .CLKA    (clka),
                .CEA     (cea),
                .OCEA    (ocea),
                .RESETA  (reseta),
                .WREA    (wrea),
                .BLKSELA (bank_a),
                .ADA     (ada_hi_blk),
                .DIA     (dina[31:16]),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB (bank_b),
                .ADB     (adb_hi_blk),
                .DIB     (dinb[31:16])
            );
            defparam u_hi.READ_MODE0  = 1'b0;
            defparam u_hi.READ_MODE1  = 1'b0;
            defparam u_hi.WRITE_MODE0 = 2'b00;
            defparam u_hi.WRITE_MODE1 = 2'b00;
            defparam u_hi.BIT_WIDTH_0 = 16;
            defparam u_hi.BIT_WIDTH_1 = 16;
            defparam u_hi.BLK_SEL_0   = i[2:0];
            defparam u_hi.BLK_SEL_1   = i[2:0];
            defparam u_hi.RESET_MODE  = "SYNC";
        end
    endgenerate

endmodule
