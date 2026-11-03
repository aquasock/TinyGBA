// SPDX-License-Identifier: GPL-3.0-only
//
// Pin-level SDRAM model, for simulating the real controller.
//
// Why this exists.  `sdram_sim.v` is the model every existing testbench uses, and
// it sits at the *logic* side: it takes `cpu_be`, `cpu_wdata` and `cpu_addr` and
// does array reads and writes.  `sdram_gba.v` -- the controller that actually
// turns those into SDRAM commands -- is never compiled by any testbench, so a
// bug inside it cannot fail a simulation.  That is not hypothetical: on hardware
// the controller returns only byte 0 of a 32-bit word, every pattern whose
// non-zero bytes are confined to byte 0 passes and every other pattern fails, and
// `tools/run_diag_sim.sh` reports PASS because the probe is correct and the model
// below it does not exist.
//
// This module is the missing half.  It sits at the pins -- DQ, A, BA, nCS, nRAS,
// nCAS, nWE, DQM -- decodes real SDRAM commands, and honours the two things that
// the logic-side model does not model at all and that decide this bug:
//
//   * the part is 16 bits wide, so one 32-bit word is two commands;
//   * DQM masks bytes on write *and* on read.  A write with DQM[1] high must not
//     change the upper byte, and a read with DQM high must drive Z rather than
//     the stored value.  Byte-lane faults are invisible without this.
//
// What is modelled: bank activate, read, write, precharge (with the A[10]
// all-banks form), auto-refresh, mode register set, and the CAS latency the mode
// register selects.  What is not modelled, deliberately: refresh intervals (the
// controller may refresh as often as it likes), timing violations (a command
// issued too early is executed rather than rejected), and the second die (each
// instance is one 32 MiB device; the testbench decides how CS reaches it).
//
//   snes_sdram_model #(.SIZE_WORDS(16*1024*1024), .NAME("low"))
//
// A DQ write with DQM both high leaves the word untouched, so a controller that
// asserts DQM on the halfword it means to write will read back stale data -- which
// is exactly the distinction the hardware probe cannot make.
module snes_sdram_model #(
    parameter integer SIZE_WORDS = 16 * 1024 * 1024,   // 16-bit words; 32 MiB default
    parameter         TRACE      = 0
)(
    inout      [15:0] SDRAM_DQ,
    input      [12:0] SDRAM_A,
    input      [1:0]  SDRAM_BA,
    input      [1:0]  SDRAM_DQM,
    input             SDRAM_nCS,
    input             SDRAM_nRAS,
    input             SDRAM_nCAS,
    input             SDRAM_nWE,
    // The SDRAM clock.  A real part has it on a pin; here it is passed in so the
    // model can be instanced beside the controller it is testing and sampled on
    // the same edges.  Verilog will not resolve `clk` implicitly from the
    // enclosing scope.
    input             clk
);

    // ---------------------------------------------------------------- storage
    reg [15:0] mem [0:SIZE_WORDS-1];

    // ------------------------------------------------------------- command set
    // {nCS, nRAS, nCAS, nWE}; nCS low means a command is present.
    localparam CMD_MRS   = 3'b000;   // mode register set
    localparam CMD_REF   = 3'b001;   // auto refresh
    localparam CMD_PRE   = 3'b010;   // precharge
    localparam CMD_ACT   = 3'b011;   // bank activate
    localparam CMD_WR    = 3'b100;   // write
    localparam CMD_RD    = 3'b101;   // read
    localparam CMD_NOP   = 3'b111;

    wire [2:0] command = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
    wire       cs      = (SDRAM_nCS === 1'b0);

    // ------------------------------------------------- per-bank row registers
    reg [12:0] row [0:3];
    reg        row_valid [0:3];
    integer    b;

    // Mode register: CAS latency and burst length.  Only CAS latency is acted
    // on; the controller issues one word per command, so burst length 1 is
    // assumed regardless of what was written.
    reg [2:0]  cas_latency = 3'd2;

    // ------------------------------------------------------- read data pipeline
    // A read returns its word `cas_latency` clocks after the command.  A small
    // shift register models that, and a read with DQM high drives Z instead.
    reg [15:0] rd_pipe [0:4];
    reg [1:0]  dqm_pipe [0:4];
    reg        rd_valid_pipe [0:4];
    integer    k;

    // ------------------------------------------------------------- DQ tri-state
    // TinyGBA: zero, not z.  A z-valued initialiser on a reg is the construct
    // this simulator refuses, and dq_oen gates the bus anyway so the register's
    // idle value is unobservable.  (A comment line must not begin with the
    // simulator's name: that is parsed as a pragma directive.)
    reg  [15:0] dq_out = 16'h0000;
    reg         dq_oen = 1'b1;          // 1 = high-Z
    // TinyGBA: the tristate is driven from a wire rather than from the register
    // directly.  Verilator refuses a tristate whose data term is a `reg` assigned
    // in an always block -- "Unsupported tristate construct (not in propagation
    // graph): VARREF 'dq_out'" -- and accepts the identical logic once the reg is
    // copied to a wire first.  Same behaviour, and it is what lets this model be
    // compiled into the simulation at all.
    wire [15:0] dq_out_w = dq_out;
    assign SDRAM_DQ = dq_oen ? 16'hzzzz : dq_out_w;
    wire [15:0] dq_in = SDRAM_DQ;

    integer w;

    initial begin
        for (w = 0; w < SIZE_WORDS; w = w + 1) mem[w] = 16'h0000;
        for (b = 0; b < 4; b = b + 1) begin row[b] = 13'd0; row_valid[b] = 1'b0; end
        for (k = 0; k < 5; k = k + 1) begin
            rd_pipe[k] = 16'h0000; dqm_pipe[k] = 2'b00; rd_valid_pipe[k] = 1'b0;
        end
    end

    always @(posedge SDRAM_nCS) begin
        if (TRACE) $display("sdram: cs deasserted");
    end

    always @(posedge clk) begin
        // Shift the read pipeline every clock; a read command inserts into it.
        for (k = 4; k > 0; k = k - 1) begin
            rd_pipe[k]       <= rd_pipe[k-1];
            dqm_pipe[k]      <= dqm_pipe[k-1];
            rd_valid_pipe[k] <= rd_valid_pipe[k-1];
        end
        rd_pipe[0]       <= 16'h0000;
        dqm_pipe[0]      <= 2'b00;
        rd_valid_pipe[0] <= 1'b0;

        if (cs) begin
            case (command)
            CMD_MRS: begin
                // A[6:4] is the CAS latency; clamp to something usable.
                cas_latency <= (SDRAM_A[6:4] == 3'd0) ? 3'd1 :
                               (SDRAM_A[6:4] > 3'd4)  ? 3'd4 : SDRAM_A[6:4];
                if (TRACE) $display("sdram: MRS A=%04X cas=%0d", SDRAM_A, SDRAM_A[6:4]);
            end
            CMD_ACT: begin
                row[SDRAM_BA]       <= SDRAM_A;
                row_valid[SDRAM_BA] <= 1'b1;
                if (TRACE) $display("sdram: ACT bank %0d row %04X", SDRAM_BA, SDRAM_A);
            end
            CMD_WR: begin
                // DQM masks on write: a high bit leaves that byte alone.  This is
                // the behaviour the logic-side model lacks, and the reason a
                // controller that asserts DQM wrongly looks correct there.
                w = {SDRAM_BA, row[SDRAM_BA], SDRAM_A[9:0]};
                if (w < SIZE_WORDS) begin
                    if (!SDRAM_DQM[0]) mem[w][7:0]  <= dq_in[7:0];
                    if (!SDRAM_DQM[1]) mem[w][15:8] <= dq_in[15:8];
                    if (TRACE) $display("sdram: WR  [%07X] dq=%04X dqm=%b -> %04X",
                                        w, dq_in, SDRAM_DQM, mem[w]);
                end
                if (SDRAM_A[10]) row_valid[SDRAM_BA] <= 1'b0;   // auto precharge
            end
            CMD_RD: begin
                w = {SDRAM_BA, row[SDRAM_BA], SDRAM_A[9:0]};
                rd_pipe[0]       <= (w < SIZE_WORDS) ? mem[w] : 16'h0000;
                dqm_pipe[0]      <= SDRAM_DQM;      // masks on read too
                rd_valid_pipe[0] <= 1'b1;
                if (TRACE) $display("sdram: RD  [%07X] dqm=%b -> %04X",
                                    w, SDRAM_DQM, mem[w]);
                if (SDRAM_A[10]) row_valid[SDRAM_BA] <= 1'b0;   // auto precharge
            end
            CMD_PRE: begin
                if (SDRAM_A[10]) begin
                    for (b = 0; b < 4; b = b + 1) row_valid[b] <= 1'b0;
                end else begin
                    row_valid[SDRAM_BA] <= 1'b0;
                end
            end
            CMD_REF: ;       // nothing to do: this model has no data to lose
            default: ;
            endcase
        end

        // Drive DQ when a read's data is due, and KEEP driving it until the next
        // command -- which is what a real part does.  Driving for a single clock
        // makes the model's answer depend on exactly which cycle the controller
        // samples, and the controller samples at its own rotate slot rather than
        // at the standard CAS point; that mismatch shows up as ZZZZ rather than
        // as a wrong value, and it hides the fault being investigated behind an
        // artefact of the model.
        // A read's data becomes valid `cas_latency` clocks after the command and
        // stays valid until the next READ, which is what a real part does.  The
        // controller here issues its READ in the CAS slot and samples in its DAT
        // slot, three clocks later rather than at the CL=2 point a standard part
        // would use; driving for exactly `cas_latency` clocks therefore put Z on
        // the bus at the moment of the sample and produced ZZZZ rather than a
        // wrong value.  Holding to the next READ models the part and leaves the
        // controller's choice of sample point to the controller.
        if (cs && command == CMD_RD) begin
            dq_oen <= 1'b1;             // a new READ replaces the previous data
        end else if (cas_latency >= 3'd1 && cas_latency <= 3'd4 &&
                     rd_valid_pipe[cas_latency-1]) begin
            if (dqm_pipe[cas_latency-1] == 2'b11) begin
                dq_oen <= 1'b1;
            end else begin
                dq_oen <= 1'b0;
            end
        end else if (cs && (command == CMD_WR)) begin
            dq_oen <= 1'b1;             // the controller drives DQ for a write
        end

        // Separate the data register from the enable so the value does not have
        // to survive in rd_pipe until the enable is withdrawn.
        //
        // TinyGBA: driven as a whole word rather than per byte.  The original
        // built dq_out from `{dqm ? 8'hzz : hi, dqm ? 8'hzz : lo}`, which is a
        // concatenation mixing data and high-impedance; Verilator rejects that
        // outright ("Unsupported tristate construct ... CONCAT"), so the model
        // could not be compiled into the simulation at all.  The difference is
        // unobservable for this controller: it issues every read with
        // `SDRAM_DQM <= 2'b00`, so no byte lane is ever masked on a read, and
        // DQM still gates writes exactly as before.  A partial-DQM read -- which
        // nothing in this design performs -- would now return both bytes instead
        // of one byte and one high-impedance lane.
        if (cas_latency >= 3'd1 && cas_latency <= 3'd4 && rd_valid_pipe[cas_latency-1]) begin
            dq_out <= rd_pipe[cas_latency-1];
        end
    end

endmodule
