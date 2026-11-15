// SPDX-License-Identifier: GPL-3.0-only
//
// The cartridge EEPROM save window: 8 KB as the cartridge sees it, 64 Kbit as
// the EEPROM interface sees it, in four BSRAM blocks.
//
// The two ports are deliberately different widths, and that is the whole reason
// this memory is shaped the way it is.  Port A is the EEPROM's own serial
// interface -- the GBA talks to an EEPROM one bit at a time, so port A is 65536
// bits of one bit each.  Port B is the save engine's: `gba_save` and
// `rv_sdram_adapter` move whole bytes, so port B is 8192 bytes of eight bits
// each.  Two views of the same storage.
//
// Four blocks, because one BSRAM holds 16 Kbit at this width.  The blocks are
// banks: the block RAM takes only fourteen address bits, so the range is
// reached by telling each block which bank it is (`BLK_SEL_n`, fixed per
// instance) and telling all of them which bank the current request belongs to
// (`BLKSEL`, driven from the top address bits).  A block acts only when the two
// agree.
//
// Because a block presents its data the cycle after the address arrives, the
// bank select that feeds the output multiplexer is registered one cycle ahead,
// and it is gated by the read enables -- `cea & ~wrea` -- so that on a write
// cycle the select holds still and the output keeps its previous value rather
// than redirecting at the bytes being written.
//
// This file restates a memory that was formerly Gowin IP-generator output; see
// TCL-065 and TCL-069.  The primitive's port and parameter names are the
// device's published interface, not this project's invention.

module eeprom_ram (
    // Port A: the EEPROM's serial interface, 65536 x 1.
    input  wire        clka,
    input  wire        cea,
    input  wire        ocea,
    input  wire        reseta,
    input  wire        wrea,
    input  wire [15:0] ada,
    input  wire [0:0]  dina,
    output wire [0:0]  douta,

    // Port B: the save engine's byte interface, 8192 x 8.
    input  wire        clkb,
    input  wire        ceb,
    input  wire        oceb,
    input  wire        resetb,
    input  wire        wreb,
    input  wire [12:0] adb,
    input  wire [7:0]  dinb,
    output wire [7:0]  doutb
);

    // A block's data ports are sixteen bits; a one-bit port A and an
    // eight-bit port B each use part of theirs.
    wire [15:0] doa_blk [0:3];
    wire [15:0] dob_blk [0:3];

    wire [13:0] ada_blk = ada[13:0];
    wire [13:0] adb_blk = {adb[10:0], 3'b000};

    wire [15:0] dia_blk = {15'b0, dina[0]};
    wire [15:0] dib_blk = {8'b0,  dinb};

    wire [2:0] blksel_a = {1'b0, ada[15], ada[14]};
    wire [2:0] blksel_b = {1'b0, adb[12], adb[11]};

    // Bank select for the output mux, registered one cycle ahead of the data.
    reg  [1:0] bank_a;
    reg  [1:0] bank_b;

    always @(posedge clka)
        if (cea & ~wrea) bank_a <= ada[15:14];

    always @(posedge clkb)
        if (ceb & ~wreb) bank_b <= adb[12:11];

    assign douta = doa_blk[bank_a][0];
    assign doutb = dob_blk[bank_b][7:0];

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : bank
            DPB u_bank (
                .DOA     (doa_blk[i]),
                .DOB     (dob_blk[i]),
                .CLKA    (clka),
                .CEA     (cea),
                .OCEA    (ocea),
                .RESETA  (reseta),
                .WREA    (wrea),
                .BLKSELA (blksel_a),
                .ADA     (ada_blk),
                .DIA     (dia_blk),

                .CLKB    (clkb),
                .CEB     (ceb),
                .OCEB    (oceb),
                .RESETB  (resetb),
                .WREB    (wreb),
                .BLKSELB (blksel_b),
                .ADB     (adb_blk),
                .DIB     (dib_blk)
            );

            defparam u_bank.READ_MODE0  = 1'b0;
            defparam u_bank.READ_MODE1  = 1'b0;
            defparam u_bank.WRITE_MODE0 = 2'b00;
            defparam u_bank.WRITE_MODE1 = 2'b00;
            defparam u_bank.BIT_WIDTH_0 = 1;
            defparam u_bank.BIT_WIDTH_1 = 8;
            defparam u_bank.BLK_SEL_0   = i[2:0];
            defparam u_bank.BLK_SEL_1   = i[2:0];
            defparam u_bank.RESET_MODE  = "SYNC";
        end
    endgenerate

endmodule
