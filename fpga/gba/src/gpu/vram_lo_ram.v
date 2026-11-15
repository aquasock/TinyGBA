// SPDX-License-Identifier: GPL-3.0-only
//
// The low half of VRAM: 16384 words of 32 bits, in 32 BSRAM blocks.
//
// Unlike `vram_hi_ram` next door, this one cannot use the indexed block select.
// Sixteen banks is more than the three bits of `BLK_SEL` can name, so the vendor
// takes the same route the framebuffer does (TCL-073): every instance carries
// the same `BLK_SEL = 3'b001`, and each receives its own one-hot decode of the
// bank field on `BLKSEL` bit 0, so a block acts when the two agree. Those
// decodes are the 32 `LUT4` cells in the generated wrapper, sixteen per port.
//
// The rest is the shape `iwram_ram` established: the word is thirty-two bits
// and a block sixteen, so each bank is a low halfword block and a high halfword
// block -- instances 0..15 and 16..31 -- sharing an address and an enable and
// differing only in their data slice and their strobe pair. The two ports have
// independent clocks, so each port's bank select is registered on its own clock
// and gated by that port's `~wre & ce`.
//
// Address: bits [13:10] are the bank (four bits, sixteen banks) and [9:0] the
// word address inside a block; the block's two spare address bits carry the
// byte write strobes for that halfword.
//
// This file restates a memory that was formerly Gowin IP-generator output; see
// TCL-065 and TCL-076. The primitive's port and parameter names are the
// device's published interface, not this project's invention.

module vram_lo_ram (
    input  wire        clka,
    input  wire        cea,
    input  wire        ocea,
    input  wire        reseta,
    input  wire        wrea,
    input  wire [13:0] ada,
    input  wire [31:0] dina,
    input  wire [3:0]  byte_ena,
    output wire [31:0] douta,

    input  wire        clkb,
    input  wire        ceb,
    input  wire        oceb,
    input  wire        resetb,
    input  wire        wreb,
    input  wire [13:0] adb,
    input  wire [31:0] dinb,
    input  wire [3:0]  byte_enb,
    output wire [31:0] doutb
);

    // Eight banks, each a low halfword and a high halfword.
    wire [15:0] doa_lo [0:BANKS-1];
    wire [15:0] doa_hi [0:BANKS-1];
    wire [15:0] dob_lo [0:BANKS-1];
    wire [15:0] dob_hi [0:BANKS-1];

    // Each half needs its own strobe pair: the low halfword is gated by
    // `byte_en[1:0]` and the high by `byte_en[3:2]`, and both go in the block's
    // two spare address bits.
    wire [13:0] ada_lo_blk = {ada[9:0], 2'b00, byte_ena[1:0]};
    wire [13:0] ada_hi_blk = {ada[9:0], 2'b00, byte_ena[3:2]};
    wire [13:0] adb_lo_blk = {adb[9:0], 2'b00, byte_enb[1:0]};
    wire [13:0] adb_hi_blk = {adb[9:0], 2'b00, byte_enb[3:2]};

    localparam BANKS = 16;

    wire [3:0] bank_a = ada[13:10];
    wire [3:0] bank_b = adb[13:10];

    // Bank select for each port's output mux, registered on that port's clock
    // and held through a write, so a write does not redirect the mux at the
    // bytes being written.
    reg  [3:0] bank_a_q, bank_b_q;

    always @(posedge clka)
        if (cea & ~wrea) bank_a_q <= bank_a;

    always @(posedge clkb)
        if (ceb & ~wreb) bank_b_q <= bank_b;

    // One-hot enables, one per bank, combinational in the address as the
    // vendor's decode LUTs are; only the mux select is delayed by a cycle.
    wire [BANKS-1:0] sel_a = {
        bank_a == 4'd15, bank_a == 4'd14, bank_a == 4'd13, bank_a == 4'd12,
        bank_a == 4'd11, bank_a == 4'd10, bank_a == 4'd9,  bank_a == 4'd8,
        bank_a == 4'd7,  bank_a == 4'd6,  bank_a == 4'd5,  bank_a == 4'd4,
        bank_a == 4'd3,  bank_a == 4'd2,  bank_a == 4'd1,  bank_a == 4'd0 };

    wire [BANKS-1:0] sel_b = {
        bank_b == 4'd15, bank_b == 4'd14, bank_b == 4'd13, bank_b == 4'd12,
        bank_b == 4'd11, bank_b == 4'd10, bank_b == 4'd9,  bank_b == 4'd8,
        bank_b == 4'd7,  bank_b == 4'd6,  bank_b == 4'd5,  bank_b == 4'd4,
        bank_b == 4'd3,  bank_b == 4'd2,  bank_b == 4'd1,  bank_b == 4'd0 };

    assign douta = {doa_hi[bank_a_q], doa_lo[bank_a_q]};
    assign doutb = {dob_hi[bank_b_q], dob_lo[bank_b_q]};

    genvar i;
    generate
        for (i = 0; i < BANKS; i = i + 1) begin : bank_i
            // Low halfword of the word: `dina[15:0]`, strobes [1:0].
            DPB u_lo (
                .DOA     (doa_lo[i]),
                .DOB     (dob_lo[i]),
                .CLKA    (clka),
                .CEA     (cea),
                .OCEA    (ocea),
                .RESETA  (reseta),
                .WREA    (wrea),
                .BLKSELA ({2'b00, sel_a[i]}),
                .ADA     (ada_lo_blk),
                .DIA     (dina[15:0]),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB ({2'b00, sel_b[i]}),
                .ADB     (adb_lo_blk),
                .DIB     (dinb[15:0])
            );
            defparam u_lo.READ_MODE0  = 1'b0;
            defparam u_lo.READ_MODE1  = 1'b0;
            defparam u_lo.WRITE_MODE0 = 2'b00;
            defparam u_lo.WRITE_MODE1 = 2'b00;
            defparam u_lo.BIT_WIDTH_0 = 16;
            defparam u_lo.BIT_WIDTH_1 = 16;
            defparam u_lo.BLK_SEL_0   = 3'b001;
            defparam u_lo.BLK_SEL_1   = 3'b001;
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
                .BLKSELA ({2'b00, sel_a[i]}),
                .ADA     (ada_hi_blk),
                .DIA     (dina[31:16]),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB ({2'b00, sel_b[i]}),
                .ADB     (adb_hi_blk),
                .DIB     (dinb[31:16])
            );
            defparam u_hi.READ_MODE0  = 1'b0;
            defparam u_hi.READ_MODE1  = 1'b0;
            defparam u_hi.WRITE_MODE0 = 2'b00;
            defparam u_hi.WRITE_MODE1 = 2'b00;
            defparam u_hi.BIT_WIDTH_0 = 16;
            defparam u_hi.BIT_WIDTH_1 = 16;
            defparam u_hi.BLK_SEL_0   = 3'b001;
            defparam u_hi.BLK_SEL_1   = 3'b001;
            defparam u_hi.RESET_MODE  = "SYNC";
        end
    endgenerate

endmodule
