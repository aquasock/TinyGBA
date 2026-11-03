// SPDX-License-Identifier: GPL-3.0-only
//
// The real SDRAM controller and a pin-level memory model, for simulation.
//
// Why this exists.  The Verilator build has always substituted `sdram_sim.v` for
// `sdram_gba.v` -- a behavioural array that answers correctly and instantly.  So
// the 534-line controller that runs on the board had never been simulated in this
// project at all, and every simulation result about memory (RetroRegen's
// `ALL REGIONS PASS`, the bus timing figures, the whole memory verdict) described
// an array rather than the controller.  That is the same blind spot the sibling
// SNES project records in its entry 68: their GSU's memory reads only worked when
// the other master happened to be reading, and "no simulation in this project
// could have found it, because every bench models BSRAM as an array that always
// answers".
//
// This wrapper closes it without disturbing the shipped design: `gbatang_top.sv`
// instantiates it instead of `sdram_sim` when `TINYGBA_SDRAM_RTL` is defined, and
// the definition exists only in the simulation build.
//
// Two dies, selected by chip select, matching `tosdram()` in gba_memory.sv:
//
//   cartridge   {1'b0,        addr[24:2]}       -> nCS = 0 -> die 0, 32 MiB
//   EWRAM       {8'b1000_0000, addr[17:2]}      -> nCS = 1 -> die 1
//   cart RAM    {10'b1000_0001_00, addr[15:2]}  -> nCS = 1 -> die 1
//
// The board brings out a single `O_sdram_cs_n`, and the controller drives it from
// `cmd[3]`, which is `addr_latch[p][25]`.  So nCS low selects die 0 and nCS high
// selects die 1 -- the two dies are addressed by the chip-select bit rather than
// by a second pin, which is why the earlier SDRAM probe tested both by writing
// complements to each.
//
// What this can and cannot settle.  It exercises the controller's real state
// machine, its halfword sequencing, its `cpu_ready` timing and its command
// encoding against a part that decodes ACT/READ/WRITE/PRE/MRS and honours DQM.
// It does not model refresh intervals, timing violations or the second die's
// physical timing, so it can find logic and sequencing faults and cannot find
// signal-integrity or clock-skew faults.  Its read-data window is a model of a
// real part rather than a measurement of this board's, so a passing run is
// evidence that the controller is logically correct and is not evidence that it
// meets setup and hold on the Tang.
module gba_sdram_rtl (
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output reg [1:0]  SDRAM_DQM,
    output reg [1:0]  SDRAM_BA,
    output            SDRAM_nCS,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,

    input             clk,
    input             mclk,
    input             resetn,

    // cpu interface
    input      [25:2] cpu_addr,
    input      [31:0] cpu_wdata,
    output reg [31:0] cpu_rdata [1:3],
    input             cpu_rd,
    input             cpu_wr,
    input       [3:0] cpu_be,
    output reg        cpu_ready,
    input       [1:0] cpu_port,

    input       [2:0] config_backup_type,
    output reg        backup_written,

    // RV port.  The adapter that would drive it is not instantiated in this
    // project, so the port is tied off here: idle, never requesting.
    output reg [15:0] rv_dout,
    output reg        rv_req_ack,

    output reg [23:0] total_refresh,
    output reg        busy,

`ifdef TINYGBA_SDRAM_DEBUG
    input      [2:0]  dbg_mem_state,
    input      [7:0]  dbg_loader_writes,
    input             dbg_loader_writing,
`endif
    input             clk67_unused
);

    // Die 0: 32 MiB of cartridge, selected when nCS is LOW.
    wire cs_die0 = SDRAM_nCS;
    // Die 1: EWRAM and cart RAM, selected when nCS is HIGH.  The controller
    // drives nCS high for those accesses, so invert to make an active-low CS.
    wire cs_die1 = ~SDRAM_nCS;

    sdram_gba controller (
        .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_A(SDRAM_A),
        .SDRAM_DQM(SDRAM_DQM),
        .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),

        .clk(clk), .mclk(mclk), .resetn(resetn),

        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata),
        .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_be(cpu_be),
        .cpu_ready(cpu_ready), .cpu_port(cpu_port),
        .config_backup_type(config_backup_type), .backup_written(backup_written),

        .rv_addr(23'd0), .rv_din(16'd0), .rv_ds(2'd0),
        .rv_dout(rv_dout), .rv_req_ack(rv_req_ack),
        .rv_req(1'b0), .rv_we(1'b0),

        .total_refresh(total_refresh), .busy(busy)
    );

`ifdef TINYGBA_SDRAM_DEBUG
    // Count how the CPU's request pulse lines up with the controller's own
    // sampling slot.  The controller only sees a request when `cycle[3]` is high,
    // and its four-cycle rotate is re-seeded by every clk16 edge, so a pulse that
    // is one clk16 wide could in principle miss the slot entirely.  That is the
    // hypothesis; these counters test it instead of arguing about it.
    integer n_cycles = 0, n_rd = 0, n_rd_at_slot = 0, n_ready = 0, n_port0 = 0;
    integer n_first_rd = 0, n_ready_mclk = 0, n_mclk = 0;
    reg mclk_r = 0;
    reg burst = 0;
    integer n_burst = 0;
    always @(posedge clk) begin
        // Settle the timing model on evidence: dump the controller's rotate
        // register, its mclk-edge detector and the CPU request around the first
        // request, so the clk67-to-clk16 relationship is measured, not assumed.
        // Trigger on the first REQ2_START well after the cartridge has loaded, so
        // the dump lands on a real EWRAM access by the CPU rather than the loader.
        if (!burst && dbg_mem_state == 3'd4 && n_cycles > 800000) burst <= 1;
        if (burst && n_burst < 24) begin
            n_burst <= n_burst + 1;
            $display("  clk[%0d] cycle=%b clkref=%b req=%b ready=%b st=%0d be=%b port0=%0d",
                     n_burst, controller.cycle[3:0], controller.clkref,
                     cpu_rd | cpu_wr, cpu_ready, dbg_mem_state,
                     controller.ds_latch[0], controller.port[0]);
        end
    end

    always @(posedge mclk) begin
        n_mclk <= n_mclk + 1;
        if (cpu_ready) begin
            n_ready_mclk <= n_ready_mclk + 1;
            // Which memory-FSM state is the consumer in on the one clk16 edge
            // that can see the ack?  The ack is a single clk16-wide pulse; if it
            // lands while the FSM is in REQ1_START rather than REQ1_WAIT, the
            // `state == REQ1_WAIT & sdram_ready` term never fires and the FSM
            // waits for an ack that has already been and gone.
            if (n_ready_mclk < 8)
                $display("ack@mclk=%0d memstate=%0d port0=%0d be=%b",
                         n_mclk, dbg_mem_state, controller.port[0], controller.ds_latch[0]);
        end
    end

    always @(posedge clk) begin
        n_cycles <= n_cycles + 1;
        if (cpu_rd | cpu_wr) begin
            n_rd <= n_rd + 1;
            if (n_first_rd == 0) n_first_rd <= n_cycles;
            if (controller.cycle[3]) n_rd_at_slot <= n_rd_at_slot + 1;
        end
        // Count ready as gba_memory sees it: sampled on the clk16 edge, which is
        // the domain that consumes it.  A clk67 pulse that no clk16 edge lands on
        // is invisible to the memory FSM however wide it looks at 67 MHz.
        if (cpu_ready)     n_ready <= n_ready + 1;
        if (controller.port[0] != 0) n_port0 <= n_port0 + 1;
        if (n_cycles % 2000000 == 0)
            $display("sdram: cyc=%0d rd=%0d slot=%0d ready=%0d port0=%0d memstate=%0d ldrWrites=%0d readyAtClk16=%0d",
                     n_cycles, n_rd, n_rd_at_slot, n_ready, n_port0,
                     dbg_mem_state, dbg_loader_writes, n_ready_mclk);
    end
    // One-shot dump of what the loader actually left in the cartridge die.  The
    // expected first four halfwords of the test cartridge are 002e ea00 ff24 51ae,
    // so a mismatch here localises a fault to the write path rather than to the
    // CPU or the BIOS.
    integer dumped = 0, i;
    always @(posedge clk) begin
        if (!dumped && n_cycles == 3000000) begin
            dumped <= 1;
            for (i = 0; i < 16; i = i + 1)
                $display("cart[%0d]=%h", i, die0.mem[i]);
        end
    end
`endif

    snes_sdram_model #(.SIZE_WORDS(16 * 1024 * 1024)) die0 (
        .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_A(SDRAM_A),
        .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQM(SDRAM_DQM),
        .SDRAM_nCS(cs_die0),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_nWE(SDRAM_nWE),
        .clk(clk)
    );

    snes_sdram_model #(.SIZE_WORDS(4 * 1024 * 1024)) die1 (
        .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_A(SDRAM_A),
        .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQM(SDRAM_DQM),
        .SDRAM_nCS(cs_die1),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_nWE(SDRAM_nWE),
        .clk(clk)
    );

endmodule
