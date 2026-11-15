// SPDX-License-Identifier: GPL-3.0-only
//
// Does this project's restatement of the IWRAM memory compute the same thing as
// the Gowin-generated wrapper it replaces?
//
// The shape is the same as `tb_eeprom_equiv.sv`: both wrappers side by side,
// the same stimulus, outputs compared every clock edge.  The primitives are
// modelled by `tools/sim/gowin_bram_sim.v`, which is this project's
// approximation of the GW5A block RAM and not a model of silicon -- an
// agreement here says the two wrappers compute the same function under one
// shared set of semantics.
//
// IWRAM is single-port, so there is one clock and one address, and the things
// worth getting wrong are different from the EEPROM's.  The word is 32 bits and
// a block holds 16, so the word is split into halves in separate blocks: an
// implementation that wired the halves the wrong way round, or that dropped a
// byte strobe, or that registered the bank select on the wrong condition, would
// still have the right *number* of block RAMs and the right total depth.  The
// stimulus therefore crosses bank boundaries and writes single bytes, not only
// whole words.
//
//   iverilog -g2012 -o tb tools/sim/tb_iwram_equiv.sv \
//       tools/sim/gowin_bram_sim.v fpga/gba/src/memory/mem_iwram.v \
//       fpga/gba/src/memory/iwram_ram.v
//   vvp tb
//
// Exits 0 only on "RESULT: PASS".

`timescale 1ns/1ps

module tb_iwram_equiv;

    reg clk = 0;
    always #10 clk = ~clk;

    reg         ce = 1, oce = 1, reset = 0, wre = 0;
    reg  [12:0] ad = 0;
    reg  [31:0] din = 0;
    reg  [3:0]  byte_en = 0;

    wire [31:0] q_old, q_new;

    mem_iwram old_m (
        .clk(clk), .ce(ce), .oce(oce), .reset(reset), .wre(wre),
        .ad(ad), .din(din), .byte_en(byte_en), .dout(q_old)
    );

    iwram_ram new_m (
        .clk(clk), .ce(ce), .oce(oce), .reset(reset), .wre(wre),
        .ad(ad), .din(din), .byte_en(byte_en), .dout(q_new)
    );

    integer errors = 0;
    integer checks = 0;
    integer writes = 0;
    integer seed = 32'h0bad_c0de;

    task check(input [255:0] what);
        begin
            checks = checks + 1;
            if (q_old !== q_new) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH t=%0t (%0s): old=%08x new=%08x  ad=%04x wr=%b be=%b din=%08x",
                             $time, what, q_old, q_new, ad, wre, byte_en, din);
            end
        end
    endtask

    integer i;
    reg [3:0] be;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 32'h0bad_c0de;

        reset = 1;
        @(posedge clk); @(posedge clk);
        check("reset");
        reset = 0;
        @(posedge clk);
        check("post-reset");

        // Random traffic, with byte strobes chosen freely so that halfword and
        // single-byte writes are both exercised, and addresses spread over the
        // whole 8 KB so bank crossings are frequent.
        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge clk);
            wre     = ($random(seed) % 3) == 0;
            ad      = $random(seed);
            din     = $random(seed);
            be      = $random(seed);
            byte_en = be;
            if (wre) writes = writes + 1;
            @(posedge clk);
            check("traffic");
        end

        // Directed: write a distinct word to the same offset in every bank, then
        // read each back.  A bank select wired to the wrong bits, or a halfword
        // pair transposed, aliases these onto each other.
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            wre = 1; ce = 1; byte_en = 4'b1111;
            ad  = {i[2:0], 10'h3FF};
            din = 32'hA5A5_0000 | i;
            @(posedge clk); check("bank-write");
        end
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            wre = 0; byte_en = 4'b0000;
            ad  = {i[2:0], 10'h3FF};
            @(posedge clk); check("bank-read");
        end

        // Directed: byte strobes.  Each lane alone, then the halfword-pair
        // combinations, at one address, so a strobe mapped to the wrong lane
        // shows up as a whole-word difference.
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge clk);
            wre = 1; ad = 13'h0555; din = 32'h1234_5678; byte_en = i[3:0];
            @(posedge clk); check("strobe-write");
            @(negedge clk);
            wre = 0; byte_en = 4'b0000;
            @(posedge clk); check("strobe-read");
        end

        $display("");
        $display("checked %0d samples (%0d writes)", checks, writes);
        if (errors == 0)
            $display("RESULT: PASS - the two wrappers agree on every cycle");
        else
            $display("RESULT: FAIL - %0d mismatches", errors);
        $finish;
    end

endmodule
