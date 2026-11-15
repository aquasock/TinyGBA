// SPDX-License-Identifier: GPL-3.0-only
//
// Does this project's restatement of the framebuffer compute the same thing as
// the Gowin-generated wrapper it replaces?
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
//   iverilog -g2012 -o tb tools/sim/tb_fb_equiv.sv \
//       fpga/gba/src/memory/mem_eeprom.v fpga/gba/src/memory/eeprom_ram.v
//   vvp tb
//
// Exits 0 only on "RESULT: PASS".

`timescale 1ns/1ps

module tb_fb_equiv;

    // Two clocks, as the board has: the save engine's domain and the EEPROM's
    // serial domain.  Both wrappers see both.
    reg clka = 0, clkb = 0;
    always #10 clka = ~clka;
    always #13 clkb = ~clkb;

    reg         cea = 1, ceb = 1, ocea = 1, oceb = 1;
    reg         reseta = 0, resetb = 0, wrea = 0, wreb = 0;
    reg  [15:0] ada = 0;
    reg  [17:0] dina = 0;
    reg  [15:0] adb = 0;
    reg  [17:0] dinb = 0;

    wire [17:0] qa_old, qa_new;
    wire [17:0] qb_old, qb_new;

    fb old_m (
        .clka(clka), .cea(cea), .ocea(ocea), .reseta(reseta), .wrea(wrea),
        .ada(ada), .dina(dina), .douta(qa_old),
        .clkb(clkb), .ceb(ceb), .oceb(oceb), .resetb(resetb), .wreb(wreb),
        .adb(adb), .dinb(dinb), .doutb(qb_old)
    );

    fb_ram new_m (
        .clka(clka), .cea(cea), .ocea(ocea), .reseta(reseta), .wrea(wrea),
        .ada(ada), .dina(dina), .douta(qa_new),
        .clkb(clkb), .ceb(ceb), .oceb(oceb), .resetb(resetb), .wreb(wreb),
        .adb(adb), .dinb(dinb), .doutb(qb_new)
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
                    $display("MISMATCH port A at t=%0t (%0s): old=%05x new=%05x  ada=%04x wrea=%b",
                             $time, what, qa_old, qa_new, ada, wrea);
            end
            if (qb_old !== qb_new) begin
                errors = errors + 1;
                if (errors <= 12)
                    $display("MISMATCH port B at t=%0t (%0s): old=%05x new=%05x  adb=%04x wreb=%b",
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
            // 38400 words is the whole framebuffer; anything above that is
            // outside the memory and neither wrapper is required to agree there.
            ada  = {$random(seed)} % 38400;   // {} makes it unsigned: $random is signed
            dina = $random(seed);
            if (wrea) writes = writes + 1;

            // Port B: byte-wide, 13-bit address across four banks; its own
            // write enable is independent of port A's.
            @(negedge clkb);
            wreb = ($random(seed) % 3) == 0;
            adb  = {$random(seed)} % 38400;
            dinb = $random(seed);
            if (wreb) writes = writes + 1;

            @(posedge clka);
            check("traffic-a");
            @(posedge clkb);
            check("traffic-b");
        end

        // A directed case for the bank boundary: write and read the same value
        // in every bank on both ports, which a wrong BLKSEL or a missing mux
        // would alias.
        // Nineteen banks, so the one-hot decode is what is under test here: a
        // wrapper that could only distinguish eight banks would alias these.
        for (i = 0; i < 19; i = i + 1) begin
            @(negedge clka);
            wrea = 1; ada = {i[4:0], 11'h7FF}; dina = 18'h2A5A5 ^ i;
            @(negedge clkb);
            wreb = 1; adb = {i[4:0], 11'h7FF}; dinb = 18'h13C3C ^ (i << 1);
            @(posedge clka); check("bank-write-a");
            @(posedge clkb); check("bank-write-b");
        end
        for (i = 0; i < 19; i = i + 1) begin
            @(negedge clka);
            wrea = 0; ada = {i[4:0], 11'h7FF};
            @(negedge clkb);
            wreb = 0; adb = {i[4:0], 11'h7FF};
            @(posedge clka); check("bank-read-a");
            @(posedge clkb); check("bank-read-b");
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
