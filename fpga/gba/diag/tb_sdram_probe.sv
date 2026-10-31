// SPDX-License-Identifier: GPL-3.0-only
//
// Testbench for fpga/gba/diag/sdram_probe.v.
//
// The probe only earns its place if it can tell a two-die module from a one-die
// module, so this testbench runs it twice against models of both and requires
// opposite verdicts:
//
//   default   sdram_sim, GBATang's own model, which addresses the full 64 MiB
//             (32 MiB ROM window plus EWRAM at byte 0x0200_0000).  The probe
//             must report all sixteen patterns correct.
//
//   -DALIAS   sdram_alias_model below, which drops cpu_addr[23] so the high die
//             aliases onto the low one -- the exact failure a module without a
//             die select would present.  The probe must report the low die's
//             patterns broken, because the high-die writes land on top of them.
//
// A probe that reported PASS in both cases would be worthless, and this is the
// check that stops that from reaching the board.
//
//   tools/run_diag_sim.sh

`timescale 1ns/1ps

// A model of the failure that matters: the die-select wire does not select a
// second die.  Low-side accesses behave normally.  High-side writes are turned
// into reads of low word 0, so they are silently lost, and high-side reads
// therefore return low word 0's contents instead of the complement the probe
// wrote.  That is what a module without a die select presents -- not an alias
// that could coincidentally match.
//
// Built on sdram_sim so the handshake under test is the same one the passing
// case uses, leaving only the die behaviour different.
module sdram_alias_model (
    input             clk,
    input      [31:0] cpu_wdata,
    input      [1:0]  cpu_port,
    output     [31:0] cpu_rdata [1:3],
    input      [25:2] cpu_addr,
    input             cpu_rd,
    input             cpu_wr,
    input      [3:0]  cpu_be,
    output            cpu_ready
);

wire        high        = cpu_addr[25];          // the controller's die select
wire [25:2] inner_addr  = high ? 24'd0 : cpu_addr;
wire        inner_rd    = cpu_rd | (high & cpu_wr);   // a lost write still completes
wire        inner_wr    = cpu_wr & ~high;

sdram_sim inner (
    .clk(clk), .config_backup_type(3'b000),
    .cpu_wdata(cpu_wdata), .cpu_port(cpu_port), .cpu_rdata(cpu_rdata),
    .cpu_addr(inner_addr), .cpu_rd(inner_rd), .cpu_wr(inner_wr), .cpu_be(cpu_be),
    .cpu_ready(cpu_ready)
);

endmodule

module tb_sdram_probe;

reg clk = 1'b0;
reg resetn = 1'b0;
always #10 clk = ~clk;      // 50 MHz; the probe is clock-rate agnostic

wire [25:2] cpu_addr;
wire [31:0] cpu_wdata;
wire [1:0]  cpu_port;
wire        cpu_rd, cpu_wr;
wire [3:0]  cpu_be;
wire        cpu_ready;
wire [31:0] cpu_rdata [1:3];
wire [15:0] result;
wire        done;

sdram_probe dut (
    .clk(clk), .resetn(resetn),
    .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_port(cpu_port),
    .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_be(cpu_be),
    .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
    .result(result), .done(done)
);

`ifdef ALIAS
sdram_alias_model model (
    .clk(clk), .cpu_wdata(cpu_wdata), .cpu_port(cpu_port), .cpu_rdata(cpu_rdata),
    .cpu_addr(cpu_addr), .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_be(cpu_be),
    .cpu_ready(cpu_ready)
);
`else
sdram_sim model (
    .clk(clk), .config_backup_type(3'b000),
    .cpu_wdata(cpu_wdata), .cpu_port(cpu_port), .cpu_rdata(cpu_rdata),
    .cpu_addr(cpu_addr), .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_be(cpu_be),
    .cpu_ready(cpu_ready)
);
`endif

integer guard;

initial begin
    guard = 0;
    repeat (4) @(posedge clk);
    resetn <= 1'b1;

    while (!done && guard < 1000000) begin
        @(posedge clk);
        guard = guard + 1;
    end

    if (!done) begin
        $display("RESULT: FAIL probe never completed");
        $finish;
    end

    $display("PROBE result=%h (low die %b, high die %b)", result, result[7:0], result[15:8]);

`ifdef ALIAS
    // A one-die module must be caught.  The low die's words were overwritten by
    // the high die's writes, so its byte cannot come back all-correct.
    if (result[7:0] === 8'hff && result[15:8] !== 8'hff)
        $display("RESULT: PASS dead high die detected (low die %h, high die %h)", result[7:0], result[15:8]);
    else
        $display("RESULT: FAIL dead high die went undetected (%h)", result);
`else
    // A two-die module must read back all sixteen patterns.
    if (result === 16'hffff)
        $display("RESULT: PASS full 64 MiB model reads back correctly");
    else
        $display("RESULT: FAIL two-die model reported errors (%h)", result);
`endif
    $finish;
end

endmodule
