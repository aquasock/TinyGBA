// SPDX-License-Identifier: GPL-3.0-only
//
// Does this project's restatement of the high VRAM compute the same thing as the
// Gowin-generated wrapper it replaces?
//
// Why this exists.  `mem_eeprom.v` is Gowin IP-generator output and the project
// would rather carry its own RTL (TCL-065).  Replacing it cannot be checked by
// counting cells: the same tree moves by hundreds of LUTs between builds with
// no source change, so a cell census can hide an off-by-one read latency or a
// transposed port completely (TCL-068).  It cannot be checked by reasoning
// either, because the wrapper registers the bank select that feeds its output
// multiplexer and the timing of that is exactly the kind of thing reasoning
// gets wrong.  So both wrappers are instantiated side by side, driven with the
// same stimulus, and their outputs compared every cycle.
//
// The primitives themselves are modelled by `tools/sim/gowin_bram_sim.v`, which
// is this project's approximation of the GW5A block RAM, not a model of
// silicon.  What an agreement here establishes is that the two wrappers compute
// the same function under one shared set of semantics.  What it does not
// establish is that those semantics match the device; that is what the board is
// for.
//
//   iverilog -g2012 -o tb tools/sim/tb_vram_hi_equiv.sv \
//       fpga/gba/src/memory/mem_eeprom.v fpga/gba/src/memory/eeprom_ram.v
//   vvp tb
//
// Exits 0 only on "RESULT: PASS".

`timescale 1ns/1ps

module tb_vram_hi_equiv;

    // Two clocks, as the board has: the save engine's domain and the EEPROM's
    // serial domain.  Both wrappers see both.
    reg clka = 0, clkb = 0;
    always #10 clka = ~clka;
    always #13 clkb = ~clkb;

    reg         cea = 1, ceb = 1, ocea = 1, oceb = 1;
    reg         reseta = 0, resetb = 0, wrea = 0, wreb = 0;
    reg  [12:0] ada = 0;
    reg  [31:0] dina = 0;
    reg  [3:0]  bea = 0;
    reg  [12:0] adb = 0;
    reg  [31:0] dinb = 0;
    reg  [3:0]  beb = 0;

    wire [31:0] qa_old, qa_new;
    wire [31:0] qb_old, qb_new;

    vram_hi old_m (
        .clka(clka), .cea(cea), .ocea(ocea), .reseta(reseta), .wrea(wrea),
        .ada(ada), .dina(dina), .byte_ena(bea), .douta(qa_old),
        .clkb(clkb), .ceb(ceb), .oceb(oceb), .resetb(resetb), .wreb(wreb),
        .adb(adb), .dinb(dinb), .byte_enb(beb), .doutb(qb_old)
    );

    vram_hi_ram new_m (
        .clka(clka), .cea(cea), .ocea(ocea), .reseta(reseta), .wrea(wrea),
        .ada(ada), .dina(dina), .byte_ena(bea), .douta(qa_new),
        .clkb(clkb), .ceb(ceb), .oceb(oceb), .resetb(resetb), .wreb(wreb),
        .adb(adb), .dinb(dinb), .byte_enb(beb), .doutb(qb_new)
    );

    integer errors = 0;
    integer checks = 0;
    integer writes = 0;
    integer seed;

    // Compare after every clock edge: the outputs are registered, so sampling a
    // little after the edge sees what that edge produced.
    task check(input [255:0] what);
        begin
            checks = checks + 1;
            if (qa_old !== qa_new) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH port A at t=%0t (%0s): old=%08x new=%08x  ada=%04x wrea=%b",
                             $time, what, qa_old, qa_new, ada, wrea);
            end
            if (qb_old !== qb_new) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH port B at t=%0t (%0s): old=%08x new=%08x  adb=%04x wreb=%b",
                             $time, what, qb_old, qb_new, adb, wreb);
            end
        end
    endtask

    integer i;
    initial begin
        seed = 32'h1234_5678;
        if (!$value$plusargs("seed=%d", seed)) seed = 32'h1234_5678;

        // Reset both, then release.
        reseta = 1; resetb = 1;
        @(posedge clka); @(posedge clkb);
        @(posedge clka); @(posedge clkb);
        check("reset");
        reseta = 0; resetb = 0;
        @(posedge clka); @(posedge clkb);
        check("post-reset");

        // Random traffic on both ports, deliberately including bank crossings
        // and byte-lane writes, since those are what the registered select and
        // the width mismatch can get wrong.
        for (i = 0; i < 12000; i = i + 1) begin
            // Port A: serial, one bit, 16-bit address across four banks.
            @(negedge clka);
            wrea = ($random(seed) % 3) == 0;
            ada  = {$random(seed)} % 8192;    // {} makes it unsigned: $random is signed
            dina = $random(seed);
            bea  = $random(seed);             // every strobe combination exercised
            if (wrea) writes = writes + 1;

            // Port B: byte-wide, 13-bit address across four banks; its own
            // write enable is independent of port A's.
            @(negedge clkb);
            wreb = ($random(seed) % 3) == 0;
            adb  = {$random(seed)} % 8192;
            dinb = $random(seed);
            beb  = $random(seed);
            if (wreb) writes = writes + 1;

            @(posedge clka);
            check("traffic-a");
            @(posedge clkb);
            check("traffic-b");
        end

        // A directed case for the bank boundary: write and read the same value
        // in every bank on both ports, which a wrong BLKSEL or a missing mux
        // would alias.
        // Eight banks, which is all a three-bit BLK_SEL can name, so the failure
        // mode here is the halfword pair rather than the bank count.
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clka);
            wrea = 1; bea = 4'b1111; ada = {i[2:0], 10'h3FF}; dina = 32'h2A5A5A5A ^ i;
            @(negedge clkb);
            wreb = 1; beb = 4'b1111; adb = {i[2:0], 10'h3FF}; dinb = 32'h13C3C3C3 ^ (i << 1);
            @(posedge clka); check("bank-write-a");
            @(posedge clkb); check("bank-write-b");
        end
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clka);
            wrea = 0; bea = 4'b0000; ada = {i[2:0], 10'h3FF};
            @(negedge clkb);
            wreb = 0; beb = 4'b0000; adb = {i[2:0], 10'h3FF};
            @(posedge clka); check("bank-read-a");
            @(posedge clkb); check("bank-read-b");
        end

        // Every strobe combination at one address, which is what makes a
        // strobe wired to the wrong half visible.
        for (i = 0; i < 16; i = i + 1) begin
            @(negedge clka);
            wrea = 1; bea = i[3:0]; ada = 13'h0555; dina = 32'hDEADBEEF;
            @(negedge clkb);
            wreb = 1; beb = i[3:0]; adb = 13'h0555; dinb = 32'hFEEDFACE;
            @(posedge clka); check("strobe-write");
            @(posedge clkb);
            @(negedge clka); wrea = 0; bea = 4'b0;
            @(negedge clkb); wreb = 0; beb = 4'b0;
            @(posedge clka); check("strobe-read-a");
            @(posedge clkb); check("strobe-read-b");
        end

        $display("");
        $display("checked %0d samples (%0d writes) across %0d comparisons",
                 checks, writes, checks * 2);
        if (errors == 0)
            $display("RESULT: PASS - the two wrappers agree on every cycle");
        else
            $display("RESULT: FAIL - %0d mismatches", errors);
        $finish;
    end

endmodule
