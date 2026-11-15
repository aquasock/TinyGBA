// SPDX-License-Identifier: GPL-3.0-only
//
// The framebuffer: 38400 words of 18 bits, in 38 BSRAM blocks.
//
// Eighteen bits is two 9-bit slices, so each bank is a pair of blocks -- one
// carrying bits [8:0] and one carrying [17:9] -- and 38400 words over 19 banks
// at 2048 words per block.  Nineteen banks times two slices is the 38 blocks.
//
// The bank select is the interesting part and it is not the shape the other
// memories in this tree use.  `BLK_SEL_n` is only three bits wide, so it can
// name eight distinct blocks; with nineteen banks it cannot name them all.  The
// vendor therefore does not name them at all: every instance carries the same
// `BLK_SEL = 3'b001`, and each instance receives its own one-hot decode of the
// bank field on `BLKSEL` bit 0.  A block is enabled when the two agree, which
// happens for exactly one bank at a time.  That is why this file carries one
// decode term per bank rather than an indexed select, and reproducing it is the
// difference between a faithful restatement and one that silently enables the
// wrong block.
//
// Address: bits [15:11] are the bank, bits [10:0] are the word address inside a
// block.  There are no byte strobes here -- the memory is not byte-enabled --
// so the block's spare address bits are tied low rather than carrying strobes
// the way `iwram_ram` uses them.
//
// The bank is registered on the launching edge and gated by the read enables,
// as in the other two memories: a block returns its word the cycle after its
// address arrives, so the output mux has to be selecting on the previous
// address, and a write must not redirect it.
//
// This file restates a memory that was formerly Gowin IP-generator output; see
// TCL-065 and TCL-073.  The primitive's port and parameter names are the
// device's published interface, not this project's invention.

module fb_ram (
    input  wire        clka,
    input  wire        cea,
    input  wire        ocea,
    input  wire        reseta,
    input  wire        wrea,
    input  wire [15:0] ada,
    input  wire [17:0] dina,
    output wire [17:0] douta,

    input  wire        clkb,
    input  wire        ceb,
    input  wire        oceb,
    input  wire        resetb,
    input  wire        wreb,
    input  wire [15:0] adb,
    input  wire [17:0] dinb,
    output wire [17:0] doutb
);

    localparam BANKS = 19;

    // One low slice and one high slice per bank; the primitive's data port is
    // 18 bits and a 9-bit block drives the half its BIT_WIDTH selects.
    wire [17:0] doa_lo [0:BANKS-1];
    wire [17:0] doa_hi [0:BANKS-1];
    wire [17:0] dob_lo [0:BANKS-1];
    wire [17:0] dob_hi [0:BANKS-1];

    wire [13:0] ada_blk = {ada[10:0], 3'b000};
    wire [13:0] adb_blk = {adb[10:0], 3'b000};

    // Each block takes only its own nine bits: the low slice carries
    // `dina[8:0]` and the high slice `dina[17:9]`.  A single concatenation fed
    // to both would be truncated to 18 bits and give both slices the low half.
    wire [17:0] dia_lo = {9'b0, dina[8:0]};
    wire [17:0] dia_hi = {9'b0, dina[17:9]};
    wire [17:0] dib_lo = {9'b0, dinb[8:0]};
    wire [17:0] dib_hi = {9'b0, dinb[17:9]};

    // The bank a request belongs to, and the same for the output mux one cycle
    // later.
    wire [4:0] bank_a = ada[15:11];
    wire [4:0] bank_b = adb[15:11];
    reg  [4:0] bank_a_q, bank_b_q;

    always @(posedge clka)
        if (cea & ~wrea) bank_a_q <= bank_a;

    always @(posedge clkb)
        if (ceb & ~wreb) bank_b_q <= bank_b;

    // The block enables are combinational in the address, not registered: the
    // vendor's decode LUTs read the live bank field, and only the output mux
    // select is delayed by a cycle.  Getting this the other way round would
    // enable the bank belonging to the *previous* address.
    wire [BANKS-1:0] sel_a = {
        bank_a == 5'd18, bank_a == 5'd17, bank_a == 5'd16, bank_a == 5'd15,
        bank_a == 5'd14, bank_a == 5'd13, bank_a == 5'd12, bank_a == 5'd11,
        bank_a == 5'd10, bank_a == 5'd9,  bank_a == 5'd8,  bank_a == 5'd7,
        bank_a == 5'd6,  bank_a == 5'd5,  bank_a == 5'd4,  bank_a == 5'd3,
        bank_a == 5'd2,  bank_a == 5'd1,  bank_a == 5'd0 };

    wire [BANKS-1:0] sel_b = {
        bank_b == 5'd18, bank_b == 5'd17, bank_b == 5'd16, bank_b == 5'd15,
        bank_b == 5'd14, bank_b == 5'd13, bank_b == 5'd12, bank_b == 5'd11,
        bank_b == 5'd10, bank_b == 5'd9,  bank_b == 5'd8,  bank_b == 5'd7,
        bank_b == 5'd6,  bank_b == 5'd5,  bank_b == 5'd4,  bank_b == 5'd3,
        bank_b == 5'd2,  bank_b == 5'd1,  bank_b == 5'd0 };

    assign douta = {doa_hi[bank_a_q][8:0], doa_lo[bank_a_q][8:0]};
    assign doutb = {dob_hi[bank_b_q][8:0], dob_lo[bank_b_q][8:0]};

    genvar i;
    generate
        for (i = 0; i < BANKS; i = i + 1) begin : bank_i
            wire [2:0] blksel_a = {2'b00, sel_a[i]};
            wire [2:0] blksel_b = {2'b00, sel_b[i]};

            // Low nine bits of the word.
            DPX9B u_lo (
                .DOA     (doa_lo[i]),
                .DOB     (dob_lo[i]),
                .CLKA    (clka),
                .CEA     (cea),
                .OCEA    (ocea),
                .RESETA  (reseta),
                .WREA    (wrea),
                .BLKSELA (blksel_a),
                .ADA     (ada_blk),
                .DIA     (dia_lo),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB (blksel_b),
                .ADB     (adb_blk),
                .DIB     (dib_lo)
            );
            defparam u_lo.READ_MODE0  = 1'b0;
            defparam u_lo.READ_MODE1  = 1'b0;
            defparam u_lo.WRITE_MODE0 = 2'b00;
            defparam u_lo.WRITE_MODE1 = 2'b00;
            defparam u_lo.BIT_WIDTH_0 = 9;
            defparam u_lo.BIT_WIDTH_1 = 9;
            defparam u_lo.BLK_SEL_0   = 3'b001;
            defparam u_lo.BLK_SEL_1   = 3'b001;
            defparam u_lo.RESET_MODE  = "SYNC";

            // High nine bits of the same word, same bank, same enable.
            DPX9B u_hi (
                .DOA     (doa_hi[i]),
                .DOB     (dob_hi[i]),
                .CLKA    (clka),
                .CEA     (cea),
                .OCEA    (ocea),
                .RESETA  (reseta),
                .WREA    (wrea),
                .BLKSELA (blksel_a),
                .ADA     (ada_blk),
                .DIA     (dia_hi),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB (blksel_b),
                .ADB     (adb_blk),
                .DIB     (dib_hi)
            );
            defparam u_hi.READ_MODE0  = 1'b0;
            defparam u_hi.READ_MODE1  = 1'b0;
            defparam u_hi.WRITE_MODE0 = 2'b00;
            defparam u_hi.WRITE_MODE1 = 2'b00;
            defparam u_hi.BIT_WIDTH_0 = 9;
            defparam u_hi.BIT_WIDTH_1 = 9;
            defparam u_hi.BLK_SEL_0   = 3'b001;
            defparam u_hi.BLK_SEL_1   = 3'b001;
            defparam u_hi.RESET_MODE  = "SYNC";
        end
    endgenerate

endmodule
