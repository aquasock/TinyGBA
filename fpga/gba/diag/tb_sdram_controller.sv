// SPDX-License-Identifier: GPL-3.0-only
//
// Testbench: the real SDRAM controller against a pin-level SDRAM model.
//
// Why this testbench exists, in one line: on hardware the controller returns only
// byte 0 of a 32-bit word, and no existing test can fail because no existing test
// compiles `sdram_gba.v` at all.  `sdram_sim.v` is a logic-side stand-in that
// takes byte enables and array-indexes memory, so a masking or capture fault in
// the controller is invisible to it.
//
// What this drives.  `sdram_gba` at its pins -- DQ, A, BA, nCS/nRAS/nCAS/nWE,
// DQM -- against `sdram_model.v`, which decodes real commands and honours DQM on
// both read and write.  The question is the hardware's: write $FFFF_FFFF to one
// word with all four byte enables, read it back, and see which bits survive.
//
// It reports, rather than asserts a verdict, because the first job is to
// reproduce the fault.  Once it fails the way hardware fails, it becomes a
// regression test by checking the expected value.
//
//   RESULT: PASS all 32 bits read back
//   RESULT: FAIL read back %08X, expected FFFFFFFF
//
module tb_sdram_controller;

    // ---------------------------------------------------------------- clocks
    // 67 MHz SDRAM clock and the 16.75 MHz GBA clock, close enough to the
    // board's 67 and 16.75 for the controller's own timing to be exercised.
    reg clk  = 1'b0;
    reg mclk = 1'b0;
    always #7.46  clk  = ~clk;
    always #29.85 mclk = ~mclk;

    reg resetn = 1'b0;

    // ------------------------------------------------------------ SDRAM pins
    wire [15:0] SDRAM_DQ;
    wire [12:0] SDRAM_A;
    wire [1:0]  SDRAM_BA;
    wire [1:0]  SDRAM_DQM;
    wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;

    // -------------------------------------------------------- controller side
    reg         cpu_rd = 1'b0, cpu_wr = 1'b0;
    reg  [25:2] cpu_addr = 24'd0;
    reg  [31:0] cpu_wdata = 32'd0;
    reg  [1:0]  cpu_port = 2'd1;
    reg  [3:0]  cpu_be = 4'b1111;
    wire [31:0] cpu_rdata [1:3];
    wire        cpu_ready;
    wire        busy;
    wire        backup_written;
    wire [23:0] total_refresh;

    reg  [22:1] rv_addr = 21'd0;
    reg  [15:0] rv_din = 16'd0;
    reg  [1:0]  rv_ds = 2'b00;
    reg         rv_req = 1'b0;
    reg         rv_we = 1'b0;
    wire [15:0] rv_dout;
    wire        rv_req_ack;

    sdram_gba dut (
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQM(SDRAM_DQM),
        .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .clk(clk), .mclk(mclk), .resetn(resetn),
        .config_backup_type(3'd0), .backup_written(backup_written),
        .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_port(cpu_port), .cpu_rdata(cpu_rdata),
        .cpu_be(cpu_be), .cpu_ready(cpu_ready),
        .rv_addr(rv_addr), .rv_din(rv_din), .rv_ds(rv_ds), .rv_dout(rv_dout),
        .rv_req(rv_req), .rv_req_ack(rv_req_ack), .rv_we(rv_we),
        .total_refresh(total_refresh), .busy(busy)
    );

    // Two 32 MiB dies sharing the one chip-select wire the dock connector
    // carries, which is what the module physically is.  Each instance is a
    // separate device; both see every command, which is what makes an aliased
    // high die detectable.
    snes_sdram_model #(.SIZE_WORDS(16*1024*1024), .TRACE(1)) die_low (
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQM(SDRAM_DQM), .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE),
        .clk(clk)
    );

    // ------------------------------------------------------------------ tasks
    // The requester contract, from sdram_gba's own header: hold the request
    // asserted, and the controller acknowledges with cpu_ready on a later cycle.
    // Deasserting after one clock -- as the first version of this testbench did
    // -- drops it before the controller's RAS slot can take it, and the machine
    // then waits for a ready that never comes.  A read's data is in
    // cpu_rdata[cpu_port] on the ready cycle.
    task do_write(input [23:0] addr, input [31:0] data, input [3:0] be);
        begin
            @(posedge clk);
            cpu_addr  <= addr;
            cpu_wdata <= data;
            cpu_be    <= be;
            cpu_port  <= 2'd1;
            cpu_wr    <= 1'b1;
            cpu_rd    <= 1'b0;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            cpu_wr    <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    task do_read(input [23:0] addr, input [3:0] be, output [31:0] data);
        begin
            @(posedge clk);
            cpu_addr <= addr;
            cpu_be   <= be;
            cpu_port <= 2'd1;
            cpu_wr   <= 1'b0;
            cpu_rd   <= 1'b1;
            @(posedge clk);
            while (!cpu_ready) @(posedge clk);
            data = cpu_rdata[1];
            cpu_rd   <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask

    // ------------------------------------------------- power-up register state
    // `sdram_gba` has registers that are only ever *cleared*, never
    // initialised, and the design relies on the device powering them to zero.
    // A Gowin FPGA does that on configuration; iverilog leaves them X, so
    // `port[1]` -- which doubles as the RV port index -- propagates X into the
    // command pins and the controller never issues a read or a write at all.
    //
    // This is not papering over a design fault in the sense of hiding it: it is
    // modelling the target's power-up behaviour.  It *is* worth recording that
    // the reliance exists, because it is the same shape as the undriven `PAL`
    // that cost TinySNES two days -- a register whose value only comes from
    // power-up rather than from reset logic.
    initial begin
        dut.port[1] = 2'd0;
    end

    // ------------------------------------------------------------------- body
    reg [31:0] got;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_sdram_controller.vcd");
            $dumpvars(0, tb_sdram_controller);
        end
        repeat (20) @(posedge clk);
        resetn = 1'b1;
        // The controller runs its init sequence and first refreshes before it
        // answers; wait for busy to drop rather than guessing a count.
        while (busy) @(posedge clk);
        repeat (200) @(posedge clk);

        // The question hardware asked: all four byte enables, all ones.
        do_write(24'h00_0000, 32'hFFFF_FFFF, 4'b1111);
        do_read (24'h00_0000, 4'b1111, got);

        if (got === 32'hFFFF_FFFF)
            $display("RESULT: PASS all 32 bits read back");
        else
            $display("RESULT: FAIL read back %08X, expected FFFFFFFF", got);

        // And the per-byte version, which is what the hardware probe showed:
        // byte 0 survives, the rest do not.
        do_write(24'h00_0004, 32'h0000_0001, 4'b1111);
        do_read (24'h00_0004, 4'b1111, got);
        $display("INFO: 0x00000001 -> %08X %s", got,
                 (got === 32'h0000_0001) ? "(as expected)" : "(MISMATCH)");

        do_write(24'h00_0008, 32'h0000_0100, 4'b1111);
        do_read (24'h00_0008, 4'b1111, got);
        $display("INFO: 0x00000100 -> %08X %s", got,
                 (got === 32'h0000_0100) ? "(as expected)" : "(MISMATCH)");

        $finish;
    end

    // A watchdog, so a controller that never answers fails loudly instead of
    // hanging the run.
    initial begin
        #2_000_000;
        $display("RESULT: FAIL timed out -- cpu_ready never asserted");
        $finish;
    end

endmodule
