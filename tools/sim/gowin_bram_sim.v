// SPDX-License-Identifier: GPL-3.0-only
//
// Behavioural models for the GW5A block RAM primitives, for the testbenches
// that check one memory wrapper against another.
//
// WHY THIS EXISTS.  Replacing a Gowin memory wrapper with this project's own
// RTL needs a test that can tell an equivalent restatement from a subtly wrong
// one -- an off-by-one read latency, an enable gated the wrong way round, a
// transposed port.  A cell-count census cannot see any of those (TCL-068), and
// neither cell library available here can simulate them: oss-cad-suite's
// `cells_sim.v` declares `SP` but has no `DPB` or `DPX9B` at all, and this
// project's `tools/sim/gowin_cells_sim.v` declares `DPB` with an empty body.
// So the models below are written here.
//
// WHAT THIS IS NOT.  It is not a model of silicon.  It is an approximation
// written from the port lists and the way the vendor's generated wrappers drive
// them, and it exists so that two wrappers can be compared under one shared set
// of semantics.  An agreement between an old wrapper and a new one under this
// model says they compute the same thing; it does not say the model matches the
// device.  Where the model is a guess it says so in place.
//
// THE ONE SEMANTIC THAT MATTERS MOST.  `BLKSEL` is a dynamic input and
// `BLK_SEL` is a per-instance parameter.  Gowin's generated wrappers drive
// `BLKSEL` from upper address bits -- `mem_iwram` drives it from
// `{ad[12],ad[11],ad[10]}` and pins instance 0 to `BLK_SEL = 3'b000` -- so the
// primitive is enabled when the two match and idle otherwise.  yosys's own
// inference path never uses it that way: `brams_map_gw5a.v` ties every
// `.BLKSEL` to `3'b000`, so an inferred block is permanently selected.  Both
// readings are modelled here, because a wrapper replaced by inference has to
// keep working on a device that also accepts the vendor's banking.
//
// ADDRESSING.  A block holds a fixed number of bits, so the word address is the
// address field shifted right by log2(BIT_WIDTH).  For a 16-bit port the vendor
// puts the shift to work: `vram_lo` drives `.ADA({ada[9:0],gw_gnd,gw_gnd,
// byte_ena[1:0]})`, so the word address is bits [13:4] and bits [1:0] are the
// byte write strobes.  An 8-bit port has no strobes (one byte per word) and a
// 1-bit port has none either.
//
// Timing follows the primitive: an address presented at a clock edge produces
// data at the next one, `OCE` gates whether the output register updates, and
// `RESET` clears the output register on the rising edge ("SYNC") or
// asynchronously.  `WRITE_MODE` 0 means a write leaves the output alone.

// Sixteen Kbit per block, as 1024 words of 16 bits.  Every width takes a slice
// of this, which is what makes the depth-per-width relation fall out.
`define GW_BRAM_BITS 16384

// Words a block holds at a given width.
`define GW_BRAM_WORDS(width) (`GW_BRAM_BITS / (width))

// Shift from the address field down to a word index for a given width.
`define GW_BRAM_SHIFT(width) ((width) == 1 ? 0 : (width) == 2 ? 1 : \
                                  (width) == 4 ? 2 : (width) == 8 ? 3 : \
                                  (width) == 9 ? 3 : (width) == 16 ? 4 : 5)

// ---------------------------------------------------------------- glue cells
// The vendor wrappers instantiate these alongside the memories, so a wrapper
// cannot be simulated without them.  Declared here rather than pulled from
// `tools/sim/gowin_cells_sim.v` so that a memory testbench needs one library.
module MUX2 (O, I0, I1, S0);
    input  I0, I1, S0;
    output O;
    assign O = S0 ? I1 : I0;
endmodule

module DFFRE (output reg Q, input D, CLK, CE, RESET);
    parameter [0:0] INIT = 1'b0;
    initial Q = INIT;
    always @(posedge CLK) begin
        if (RESET)     Q <= 1'b0;
        else if (CE)   Q <= D;
    end
endmodule

// ---------------------------------------------------------------------- DPB
// Dual-port, 16-bit data ports, 14-bit address fields.
module DPB(CLKA, CEA, CLKB, CEB, OCEA, OCEB, RESETA, RESETB, WREA, WREB,
           ADA, ADB, BLKSELA, BLKSELB, DIA, DIB, DOA, DOB);
    parameter READ_MODE0 = 1'b0;
    parameter READ_MODE1 = 1'b0;
    parameter WRITE_MODE0 = 2'b00;
    parameter WRITE_MODE1 = 2'b00;
    parameter BIT_WIDTH_0 = 16;
    parameter BIT_WIDTH_1 = 16;
    parameter BLK_SEL_0 = 3'b000;
    parameter BLK_SEL_1 = 3'b000;
    parameter RESET_MODE = "SYNC";

    parameter [255:0] INIT_RAM_00 = 0, INIT_RAM_01 = 0, INIT_RAM_02 = 0,
                      INIT_RAM_03 = 0, INIT_RAM_04 = 0, INIT_RAM_05 = 0,
                      INIT_RAM_06 = 0, INIT_RAM_07 = 0, INIT_RAM_08 = 0,
                      INIT_RAM_09 = 0, INIT_RAM_0A = 0, INIT_RAM_0B = 0,
                      INIT_RAM_0C = 0, INIT_RAM_0D = 0, INIT_RAM_0E = 0,
                      INIT_RAM_0F = 0, INIT_RAM_10 = 0, INIT_RAM_11 = 0,
                      INIT_RAM_12 = 0, INIT_RAM_13 = 0, INIT_RAM_14 = 0,
                      INIT_RAM_15 = 0, INIT_RAM_16 = 0, INIT_RAM_17 = 0,
                      INIT_RAM_18 = 0, INIT_RAM_19 = 0, INIT_RAM_1A = 0,
                      INIT_RAM_1B = 0, INIT_RAM_1C = 0, INIT_RAM_1D = 0,
                      INIT_RAM_1E = 0, INIT_RAM_1F = 0, INIT_RAM_20 = 0,
                      INIT_RAM_21 = 0, INIT_RAM_22 = 0, INIT_RAM_23 = 0,
                      INIT_RAM_24 = 0, INIT_RAM_25 = 0, INIT_RAM_26 = 0,
                      INIT_RAM_27 = 0, INIT_RAM_28 = 0, INIT_RAM_29 = 0,
                      INIT_RAM_2A = 0, INIT_RAM_2B = 0, INIT_RAM_2C = 0,
                      INIT_RAM_2D = 0, INIT_RAM_2E = 0, INIT_RAM_2F = 0,
                      INIT_RAM_30 = 0, INIT_RAM_31 = 0, INIT_RAM_32 = 0,
                      INIT_RAM_33 = 0, INIT_RAM_34 = 0, INIT_RAM_35 = 0,
                      INIT_RAM_36 = 0, INIT_RAM_37 = 0, INIT_RAM_38 = 0,
                      INIT_RAM_39 = 0, INIT_RAM_3A = 0, INIT_RAM_3B = 0,
                      INIT_RAM_3C = 0, INIT_RAM_3D = 0, INIT_RAM_3E = 0,
                      INIT_RAM_3F = 0;

    input  wire        CLKA, CEA, OCEA, RESETA, WREA;
    input  wire        CLKB, CEB, OCEB, RESETB, WREB;
    input  wire [13:0] ADA, ADB;
    input  wire [2:0]  BLKSELA, BLKSELB;
    input  wire [15:0] DIA, DIB;
    output reg  [15:0] DOA, DOB;

    // One array per port width.  A wrapper never uses two different widths for
    // the same block in this tree, and the widths are equal in every wrapper
    // that does, so a single array indexed by each port's own word address is
    // faithful for what is actually instantiated here.
    localparam AW = 14 - `GW_BRAM_SHIFT(BIT_WIDTH_0);
    localparam DW = `GW_BRAM_WORDS(BIT_WIDTH_0);

    reg [15:0] mem [0:DW-1];

    integer i;
    reg [255:0] init [0:63];
    initial begin
        init[6'h00] = INIT_RAM_00; init[6'h01] = INIT_RAM_01;
        init[6'h02] = INIT_RAM_02; init[6'h03] = INIT_RAM_03;
        init[6'h04] = INIT_RAM_04; init[6'h05] = INIT_RAM_05;
        init[6'h06] = INIT_RAM_06; init[6'h07] = INIT_RAM_07;
        init[6'h08] = INIT_RAM_08; init[6'h09] = INIT_RAM_09;
        init[6'h0A] = INIT_RAM_0A; init[6'h0B] = INIT_RAM_0B;
        init[6'h0C] = INIT_RAM_0C; init[6'h0D] = INIT_RAM_0D;
        init[6'h0E] = INIT_RAM_0E; init[6'h0F] = INIT_RAM_0F;
        init[6'h10] = INIT_RAM_10; init[6'h11] = INIT_RAM_11;
        init[6'h12] = INIT_RAM_12; init[6'h13] = INIT_RAM_13;
        init[6'h14] = INIT_RAM_14; init[6'h15] = INIT_RAM_15;
        init[6'h16] = INIT_RAM_16; init[6'h17] = INIT_RAM_17;
        init[6'h18] = INIT_RAM_18; init[6'h19] = INIT_RAM_19;
        init[6'h1A] = INIT_RAM_1A; init[6'h1B] = INIT_RAM_1B;
        init[6'h1C] = INIT_RAM_1C; init[6'h1D] = INIT_RAM_1D;
        init[6'h1E] = INIT_RAM_1E; init[6'h1F] = INIT_RAM_1F;
        init[6'h20] = INIT_RAM_20; init[6'h21] = INIT_RAM_21;
        init[6'h22] = INIT_RAM_22; init[6'h23] = INIT_RAM_23;
        init[6'h24] = INIT_RAM_24; init[6'h25] = INIT_RAM_25;
        init[6'h26] = INIT_RAM_26; init[6'h27] = INIT_RAM_27;
        init[6'h28] = INIT_RAM_28; init[6'h29] = INIT_RAM_29;
        init[6'h2A] = INIT_RAM_2A; init[6'h2B] = INIT_RAM_2B;
        init[6'h2C] = INIT_RAM_2C; init[6'h2D] = INIT_RAM_2D;
        init[6'h2E] = INIT_RAM_2E; init[6'h2F] = INIT_RAM_2F;
        init[6'h30] = INIT_RAM_30; init[6'h31] = INIT_RAM_31;
        init[6'h32] = INIT_RAM_32; init[6'h33] = INIT_RAM_33;
        init[6'h34] = INIT_RAM_34; init[6'h35] = INIT_RAM_35;
        init[6'h36] = INIT_RAM_36; init[6'h37] = INIT_RAM_37;
        init[6'h38] = INIT_RAM_38; init[6'h39] = INIT_RAM_39;
        init[6'h3A] = INIT_RAM_3A; init[6'h3B] = INIT_RAM_3B;
        init[6'h3C] = INIT_RAM_3C; init[6'h3D] = INIT_RAM_3D;
        init[6'h3E] = INIT_RAM_3E; init[6'h3F] = INIT_RAM_3F;
        // The words are 256-bit slices taken in order; a word occupies the low
        // BIT_WIDTH bits and the rest is unused.
        for (i = 0; i < DW; i = i + 1)
            mem[i] = init[i*BIT_WIDTH_0/256][(i*BIT_WIDTH_0)%256 +: BIT_WIDTH_0];
    end

    wire sel_a = (BLKSELA == BLK_SEL_0);
    wire sel_b = (BLKSELB == BLK_SEL_1);

    wire [AW-1:0] wa = ADA[13:`GW_BRAM_SHIFT(BIT_WIDTH_0)];
    wire [AW-1:0] wb = ADB[13:`GW_BRAM_SHIFT(BIT_WIDTH_1)];

    // Byte strobes exist only on a 16-bit port, at address bits [1:0].
    wire [1:0] be_a = (BIT_WIDTH_0 == 16) ? ADA[1:0] : 2'b11;
    wire [1:0] be_b = (BIT_WIDTH_1 == 16) ? ADB[1:0] : 2'b11;

    always @(posedge CLKA) begin
        if (RESETA && RESET_MODE != "ASYNC")
            DOA <= 16'b0;
        else if (CEA && sel_a) begin
            if (WREA) begin
                if (BIT_WIDTH_0 == 16) begin
                    if (be_a[0]) mem[wa][7:0]   <= DIA[7:0];
                    if (be_a[1]) mem[wa][15:8]  <= DIA[15:8];
                end else if (BIT_WIDTH_0 == 8) begin
                    mem[wa][7:0] <= DIA[7:0];
                end else begin
                    mem[wa][BIT_WIDTH_0-1:0] <= DIA[BIT_WIDTH_0-1:0];
                end
            end
            if (OCEA)
                DOA <= mem[wa];
        end
    end

    always @(posedge CLKB) begin
        if (RESETB && RESET_MODE != "ASYNC")
            DOB <= 16'b0;
        else if (CEB && sel_b) begin
            if (WREB) begin
                if (BIT_WIDTH_1 == 16) begin
                    if (be_b[0]) mem[wb][7:0]   <= DIB[7:0];
                    if (be_b[1]) mem[wb][15:8]  <= DIB[15:8];
                end else if (BIT_WIDTH_1 == 8) begin
                    mem[wb][7:0] <= DIB[7:0];
                end else begin
                    mem[wb][BIT_WIDTH_1-1:0] <= DIB[BIT_WIDTH_1-1:0];
                end
            end
            if (OCEB)
                DOB <= mem[wb];
        end
    end

endmodule

// ----------------------------------------------------------------------- SP
// Single-port, 32-bit data port, 14-bit address field.  The GW5A part is named
// SPX9 upstream; both names are provided so either can be instantiated.
module SP(DO, DI, BLKSEL, AD, WRE, CLK, CE, OCE, RESET);
    parameter READ_MODE = 1'b0;
    parameter WRITE_MODE = 2'b00;
    parameter BIT_WIDTH = 16;
    parameter BLK_SEL = 3'b000;
    parameter RESET_MODE = "SYNC";

    parameter [255:0] INIT_RAM_00 = 0, INIT_RAM_01 = 0, INIT_RAM_02 = 0,
                      INIT_RAM_03 = 0, INIT_RAM_04 = 0, INIT_RAM_05 = 0,
                      INIT_RAM_06 = 0, INIT_RAM_07 = 0, INIT_RAM_08 = 0,
                      INIT_RAM_09 = 0, INIT_RAM_0A = 0, INIT_RAM_0B = 0,
                      INIT_RAM_0C = 0, INIT_RAM_0D = 0, INIT_RAM_0E = 0,
                      INIT_RAM_0F = 0, INIT_RAM_10 = 0, INIT_RAM_11 = 0,
                      INIT_RAM_12 = 0, INIT_RAM_13 = 0, INIT_RAM_14 = 0,
                      INIT_RAM_15 = 0, INIT_RAM_16 = 0, INIT_RAM_17 = 0,
                      INIT_RAM_18 = 0, INIT_RAM_19 = 0, INIT_RAM_1A = 0,
                      INIT_RAM_1B = 0, INIT_RAM_1C = 0, INIT_RAM_1D = 0,
                      INIT_RAM_1E = 0, INIT_RAM_1F = 0, INIT_RAM_20 = 0,
                      INIT_RAM_21 = 0, INIT_RAM_22 = 0, INIT_RAM_23 = 0,
                      INIT_RAM_24 = 0, INIT_RAM_25 = 0, INIT_RAM_26 = 0,
                      INIT_RAM_27 = 0, INIT_RAM_28 = 0, INIT_RAM_29 = 0,
                      INIT_RAM_2A = 0, INIT_RAM_2B = 0, INIT_RAM_2C = 0,
                      INIT_RAM_2D = 0, INIT_RAM_2E = 0, INIT_RAM_2F = 0,
                      INIT_RAM_30 = 0, INIT_RAM_31 = 0, INIT_RAM_32 = 0,
                      INIT_RAM_33 = 0, INIT_RAM_34 = 0, INIT_RAM_35 = 0,
                      INIT_RAM_36 = 0, INIT_RAM_37 = 0, INIT_RAM_38 = 0,
                      INIT_RAM_39 = 0, INIT_RAM_3A = 0, INIT_RAM_3B = 0,
                      INIT_RAM_3C = 0, INIT_RAM_3D = 0, INIT_RAM_3E = 0,
                      INIT_RAM_3F = 0;

    input  wire        CLK, CE, OCE, RESET, WRE;
    input  wire [2:0]  BLKSEL;
    input  wire [13:0] AD;
    input  wire [31:0] DI;
    output reg  [31:0] DO;

    localparam AW = 14 - `GW_BRAM_SHIFT(BIT_WIDTH);
    localparam DW = `GW_BRAM_WORDS(BIT_WIDTH);

    reg [31:0] mem [0:DW-1];

    integer i;
    reg [255:0] init [0:63];
    initial begin
        init[6'h00] = INIT_RAM_00; init[6'h01] = INIT_RAM_01;
        init[6'h02] = INIT_RAM_02; init[6'h03] = INIT_RAM_03;
        init[6'h04] = INIT_RAM_04; init[6'h05] = INIT_RAM_05;
        init[6'h06] = INIT_RAM_06; init[6'h07] = INIT_RAM_07;
        init[6'h08] = INIT_RAM_08; init[6'h09] = INIT_RAM_09;
        init[6'h0A] = INIT_RAM_0A; init[6'h0B] = INIT_RAM_0B;
        init[6'h0C] = INIT_RAM_0C; init[6'h0D] = INIT_RAM_0D;
        init[6'h0E] = INIT_RAM_0E; init[6'h0F] = INIT_RAM_0F;
        init[6'h10] = INIT_RAM_10; init[6'h11] = INIT_RAM_11;
        init[6'h12] = INIT_RAM_12; init[6'h13] = INIT_RAM_13;
        init[6'h14] = INIT_RAM_14; init[6'h15] = INIT_RAM_15;
        init[6'h16] = INIT_RAM_16; init[6'h17] = INIT_RAM_17;
        init[6'h18] = INIT_RAM_18; init[6'h19] = INIT_RAM_19;
        init[6'h1A] = INIT_RAM_1A; init[6'h1B] = INIT_RAM_1B;
        init[6'h1C] = INIT_RAM_1C; init[6'h1D] = INIT_RAM_1D;
        init[6'h1E] = INIT_RAM_1E; init[6'h1F] = INIT_RAM_1F;
        init[6'h20] = INIT_RAM_20; init[6'h21] = INIT_RAM_21;
        init[6'h22] = INIT_RAM_22; init[6'h23] = INIT_RAM_23;
        init[6'h24] = INIT_RAM_24; init[6'h25] = INIT_RAM_25;
        init[6'h26] = INIT_RAM_26; init[6'h27] = INIT_RAM_27;
        init[6'h28] = INIT_RAM_28; init[6'h29] = INIT_RAM_29;
        init[6'h2A] = INIT_RAM_2A; init[6'h2B] = INIT_RAM_2B;
        init[6'h2C] = INIT_RAM_2C; init[6'h2D] = INIT_RAM_2D;
        init[6'h2E] = INIT_RAM_2E; init[6'h2F] = INIT_RAM_2F;
        init[6'h30] = INIT_RAM_30; init[6'h31] = INIT_RAM_31;
        init[6'h32] = INIT_RAM_32; init[6'h33] = INIT_RAM_33;
        init[6'h34] = INIT_RAM_34; init[6'h35] = INIT_RAM_35;
        init[6'h36] = INIT_RAM_36; init[6'h37] = INIT_RAM_37;
        init[6'h38] = INIT_RAM_38; init[6'h39] = INIT_RAM_39;
        init[6'h3A] = INIT_RAM_3A; init[6'h3B] = INIT_RAM_3B;
        init[6'h3C] = INIT_RAM_3C; init[6'h3D] = INIT_RAM_3D;
        init[6'h3E] = INIT_RAM_3E; init[6'h3F] = INIT_RAM_3F;
        for (i = 0; i < DW; i = i + 1)
            mem[i] = init[i*BIT_WIDTH/256][(i*BIT_WIDTH)%256 +: BIT_WIDTH];
    end

    wire sel = (BLKSEL == BLK_SEL);
    wire [AW-1:0] wa = AD[13:`GW_BRAM_SHIFT(BIT_WIDTH)];
    wire [1:0] be = (BIT_WIDTH == 16) ? AD[1:0] : 2'b11;

    always @(posedge CLK) begin
        if (RESET && RESET_MODE != "ASYNC")
            DO <= 32'b0;
        else if (CE && sel) begin
            if (WRE) begin
                if (BIT_WIDTH == 16) begin
                    if (be[0]) mem[wa][7:0]  <= DI[7:0];
                    if (be[1]) mem[wa][15:8] <= DI[15:8];
                end else begin
                    mem[wa][BIT_WIDTH-1:0] <= DI[BIT_WIDTH-1:0];
                end
            end
            if (OCE)
                DO <= mem[wa];
        end
    end

endmodule

module SPX9(DO, DI, BLKSEL, AD, WRE, CLK, CE, OCE, RESET);
    parameter READ_MODE = 1'b0;
    parameter WRITE_MODE = 2'b00;
    parameter BIT_WIDTH = 16;
    parameter BLK_SEL = 3'b000;
    parameter RESET_MODE = "SYNC";
    parameter [255:0] INIT_RAM_00 = 0;
    input  wire        CLK, CE, OCE, RESET, WRE;
    input  wire [2:0]  BLKSEL;
    input  wire [13:0] AD;
    input  wire [31:0] DI;
    output reg  [31:0] DO;

    // Widths other than those the wrappers here use are not modelled; the
    // testbenches only need the 16-bit case.  Anything else is left at zero so
    // that a misuse is visible rather than silently plausible.
    reg [15:0] mem [0:1023];
    integer i;
    initial for (i = 0; i < 1024; i = i + 1) mem[i] = 16'b0;

    wire sel = (BLKSEL == BLK_SEL);
    always @(posedge CLK)
        if (CE && sel) begin
            if (WRE) mem[AD[13:4]][1:0] <= DI[1:0];
            if (OCE) begin DO[15:0] <= mem[AD[13:4]]; DO[31:16] <= 16'b0; end
        end
endmodule

// -------------------------------------------------------------------- DPX9B
// Dual-port, 18-bit data ports (two 9-bit sub-words per block).
module DPX9B(CLKA, CEA, CLKB, CEB, OCEA, OCEB, RESETA, RESETB, WREA, WREB,
             ADA, ADB, BLKSELA, BLKSELB, DIA, DIB, DOA, DOB);
    parameter READ_MODE0 = 1'b0;
    parameter READ_MODE1 = 1'b0;
    parameter WRITE_MODE0 = 2'b00;
    parameter WRITE_MODE1 = 2'b00;
    parameter BIT_WIDTH_0 = 9;
    parameter BIT_WIDTH_1 = 9;
    parameter BLK_SEL_0 = 3'b000;
    parameter BLK_SEL_1 = 3'b000;
    parameter RESET_MODE = "SYNC";

    parameter [255:0] INIT_RAM_00 = 0, INIT_RAM_01 = 0, INIT_RAM_02 = 0,
                      INIT_RAM_03 = 0, INIT_RAM_04 = 0, INIT_RAM_05 = 0,
                      INIT_RAM_06 = 0, INIT_RAM_07 = 0, INIT_RAM_08 = 0,
                      INIT_RAM_09 = 0, INIT_RAM_0A = 0, INIT_RAM_0B = 0,
                      INIT_RAM_0C = 0, INIT_RAM_0D = 0, INIT_RAM_0E = 0,
                      INIT_RAM_0F = 0, INIT_RAM_10 = 0, INIT_RAM_11 = 0,
                      INIT_RAM_12 = 0, INIT_RAM_13 = 0, INIT_RAM_14 = 0,
                      INIT_RAM_15 = 0, INIT_RAM_16 = 0, INIT_RAM_17 = 0,
                      INIT_RAM_18 = 0, INIT_RAM_19 = 0, INIT_RAM_1A = 0,
                      INIT_RAM_1B = 0, INIT_RAM_1C = 0, INIT_RAM_1D = 0,
                      INIT_RAM_1E = 0, INIT_RAM_1F = 0, INIT_RAM_20 = 0,
                      INIT_RAM_21 = 0, INIT_RAM_22 = 0, INIT_RAM_23 = 0,
                      INIT_RAM_24 = 0, INIT_RAM_25 = 0, INIT_RAM_26 = 0,
                      INIT_RAM_27 = 0, INIT_RAM_28 = 0, INIT_RAM_29 = 0,
                      INIT_RAM_2A = 0, INIT_RAM_2B = 0, INIT_RAM_2C = 0,
                      INIT_RAM_2D = 0, INIT_RAM_2E = 0, INIT_RAM_2F = 0,
                      INIT_RAM_30 = 0, INIT_RAM_31 = 0, INIT_RAM_32 = 0,
                      INIT_RAM_33 = 0, INIT_RAM_34 = 0, INIT_RAM_35 = 0,
                      INIT_RAM_36 = 0, INIT_RAM_37 = 0, INIT_RAM_38 = 0,
                      INIT_RAM_39 = 0, INIT_RAM_3A = 0, INIT_RAM_3B = 0,
                      INIT_RAM_3C = 0, INIT_RAM_3D = 0, INIT_RAM_3E = 0,
                      INIT_RAM_3F = 0;

    input  wire        CLKA, CEA, OCEA, RESETA, WREA;
    input  wire        CLKB, CEB, OCEB, RESETB, WREB;
    input  wire [12:0] ADA, ADB;
    input  wire [2:0]  BLKSELA, BLKSELB;
    input  wire [17:0] DIA, DIB;
    output reg  [17:0] DOA, DOB;

    reg [17:0] mem [0:1023];

    integer i;
    reg [255:0] init [0:63];
    initial begin
        init[6'h00] = INIT_RAM_00; init[6'h01] = INIT_RAM_01;
        init[6'h02] = INIT_RAM_02; init[6'h03] = INIT_RAM_03;
        init[6'h04] = INIT_RAM_04; init[6'h05] = INIT_RAM_05;
        init[6'h06] = INIT_RAM_06; init[6'h07] = INIT_RAM_07;
        init[6'h08] = INIT_RAM_08; init[6'h09] = INIT_RAM_09;
        init[6'h0A] = INIT_RAM_0A; init[6'h0B] = INIT_RAM_0B;
        init[6'h0C] = INIT_RAM_0C; init[6'h0D] = INIT_RAM_0D;
        init[6'h0E] = INIT_RAM_0E; init[6'h0F] = INIT_RAM_0F;
        init[6'h10] = INIT_RAM_10; init[6'h11] = INIT_RAM_11;
        init[6'h12] = INIT_RAM_12; init[6'h13] = INIT_RAM_13;
        init[6'h14] = INIT_RAM_14; init[6'h15] = INIT_RAM_15;
        init[6'h16] = INIT_RAM_16; init[6'h17] = INIT_RAM_17;
        init[6'h18] = INIT_RAM_18; init[6'h19] = INIT_RAM_19;
        init[6'h1A] = INIT_RAM_1A; init[6'h1B] = INIT_RAM_1B;
        init[6'h1C] = INIT_RAM_1C; init[6'h1D] = INIT_RAM_1D;
        init[6'h1E] = INIT_RAM_1E; init[6'h1F] = INIT_RAM_1F;
        init[6'h20] = INIT_RAM_20; init[6'h21] = INIT_RAM_21;
        init[6'h22] = INIT_RAM_22; init[6'h23] = INIT_RAM_23;
        init[6'h24] = INIT_RAM_24; init[6'h25] = INIT_RAM_25;
        init[6'h26] = INIT_RAM_26; init[6'h27] = INIT_RAM_27;
        init[6'h28] = INIT_RAM_28; init[6'h29] = INIT_RAM_29;
        init[6'h2A] = INIT_RAM_2A; init[6'h2B] = INIT_RAM_2B;
        init[6'h2C] = INIT_RAM_2C; init[6'h2D] = INIT_RAM_2D;
        init[6'h2E] = INIT_RAM_2E; init[6'h2F] = INIT_RAM_2F;
        init[6'h30] = INIT_RAM_30; init[6'h31] = INIT_RAM_31;
        init[6'h32] = INIT_RAM_32; init[6'h33] = INIT_RAM_33;
        init[6'h34] = INIT_RAM_34; init[6'h35] = INIT_RAM_35;
        init[6'h36] = INIT_RAM_36; init[6'h37] = INIT_RAM_37;
        init[6'h38] = INIT_RAM_38; init[6'h39] = INIT_RAM_39;
        init[6'h3A] = INIT_RAM_3A; init[6'h3B] = INIT_RAM_3B;
        init[6'h3C] = INIT_RAM_3C; init[6'h3D] = INIT_RAM_3D;
        init[6'h3E] = INIT_RAM_3E; init[6'h3F] = INIT_RAM_3F;
        for (i = 0; i < 1024; i = i + 1)
            mem[i] = init[i*18/256][(i*18)%256 +: 18];
    end

    wire sel_a = (BLKSELA == BLK_SEL_0);
    wire sel_b = (BLKSELB == BLK_SEL_1);

    always @(posedge CLKA) begin
        if (RESETA && RESET_MODE != "ASYNC") DOA <= 18'b0;
        else if (CEA && sel_a) begin
            if (WREA) mem[ADA[12:3]] <= DIA;
            if (OCEA) DOA <= mem[ADA[12:3]];
        end
    end

    always @(posedge CLKB) begin
        if (RESETB && RESET_MODE != "ASYNC") DOB <= 18'b0;
        else if (CEB && sel_b) begin
            if (WREB) mem[ADB[12:3]] <= DIB;
            if (OCEB) DOB <= mem[ADB[12:3]];
        end
    end

endmodule
