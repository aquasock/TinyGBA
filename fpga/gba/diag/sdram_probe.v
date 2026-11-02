// SPDX-License-Identifier: GPL-3.0-only
//
// TinyGBA SDRAM occupancy probe.
//
// Answers one question on hardware: is the second 32 MiB die on the SDRAM module
// reachable through the single chip-select wire the dock connector carries?
//
// The question exists because the module Sipeed ships for the Tang Console is
// advertised as 64 MiB and physically carries two Winbond W9825G6KH-6 dies, one
// 32 MiB device each, while the 40-pin header brings out exactly 38 signal
// conductors -- 16 DQ, 13 A, 2 BA, 2 DQM, CLK, WE, RAS, CAS, CS -- which is one
// die's worth and no second select.  GBATang's controller selects between two
// dies by driving that one CS wire from address bit 25 (sdram_gba.v:332, :489)
// and refreshes each die in turn (:341, :344), so the arrangement only works if
// the module treats the wire as a die index rather than a plain chip select.
// Either it does, and 64 MiB is already live, or it does not, and every address
// with bit 25 set reads nothing back.
//
// How the test discriminates.  A naive "write to the high die, read it back"
// passes on a broken module: if bit 25 is ignored, the write lands on the low
// die and the read returns exactly what was written.  So the order is:
//
//   1. write pattern A to words 0-7 of the low die,
//   2. write the inverse of A to words 0-7 of the high die,
//   3. read words 0-7 of the low die back -- they must still be A.  An aliased
//      high die has overwritten them with ~A, and that is the tell,
//   4. read words 0-7 of the high die back -- they must be ~A.
//
// Eight patterns per die, chosen so a stuck data line, a stuck address line and
// a shifted address each break at least one of them.  The result is 16 bits, one
// per pattern, low byte for the low die and high byte for the high die, which
// the diagnostic video pattern draws as sixteen bars: green is a bit that read
// back correctly, red is one that did not.
//
// Two modes, because a pass/fail bit per pattern cannot say why a pattern failed.
//
//   TINYGBA_SDRAM_TEST (default)  the occupancy test above: eight patterns per
//                                 die, one pass/fail bit each.
//   TINYGBA_SDRAM_LANES           a data-lane readout.  Writes $FFFF_FFFF to one
//                                 word with all four byte enables, reads the word
//                                 back, and puts the sixteen bits of the result
//                                 straight into `result`, so each bar is a DATA
//                                 BIT rather than a verdict: green is a lane that
//                                 returned 1, red a lane that returned 0.
//
// The lane mode exists because the occupancy test reported eight green bits and
// named nothing.  Reading the pattern table against the observed bars shows the
// split is per byte -- every pattern whose non-zero bytes are confined to byte 0
// passed, every other pattern failed -- which means DQ[15:8] is not returning its
// value, and only a raw readback can separate "the controller masked it" from
// "the wire never carried it".
//
// Only built under TINYGBA_SDRAM_TEST, where it owns the SDRAM CPU port and the
// machine is held in reset.  It drives the same requester-side contract as
// gba_memory: hold the request until cpu_ready, then take the data from
// cpu_rdata[cpu_port].  TinySNES learned that a probe owning the CPU port from
// reset disconnects the ROM loader's writes, so this is a diagnostic-only build
// and never runs in a production configuration.

module sdram_probe (
    input               clk,
    input               resetn,

    // SDRAM CPU port, requester side
    output reg [25:2]   cpu_addr,
    output reg [31:0]   cpu_wdata,
    output reg [1:0]    cpu_port,
    output reg          cpu_rd,
    output reg          cpu_wr,
    output reg [3:0]    cpu_be,
    input               cpu_ready,
    input      [31:0]   cpu_rdata [1:3],

    // Result: {high_die[7:0], low_die[7:0]}, 1 = that pattern read back correctly
    output reg [15:0]   result,
    output reg          done
);

localparam [1:0] S_SETTLE = 2'd0,
                 S_REQ    = 2'd1,
                 S_WAIT   = 2'd2,
                 S_NEXT   = 2'd3;

// The controller needs its init sequence and first refreshes before it answers.
// sdram_gba.v takes a few hundred microseconds; 2^17 clk16 cycles is about 7.8
// ms, far beyond that, and costs nothing in a diagnostic build.
localparam [16:0] SETTLE_COUNT = 17'd131071;

// Word addresses.  cpu_addr is a word address, so byte address 0x0200_0000 --
// the first byte of the EWRAM window, and the first byte of the high die -- is
// word 0x80_0000.  That is bit 23 of cpu_addr, which is byte address bit 25.
localparam [23:0] LOW_BASE  = 24'h00_0000;
localparam [23:0] HIGH_BASE = 24'h80_0000;

localparam [1:0] PORT = 2'd1;   // cpu_rdata[1]; any non-zero port will do

reg [1:0]  state;
reg [16:0] settle;
reg        rd_settle;   // one clock between cpu_ready and the data
reg [1:0]  phase;      // 0 write low die, 1 write high die, 2 read low, 3 read high
reg [3:0]  idx;        // word index within the phase, 0-7
reg        is_read_r;

function [31:0] pattern(input [3:0] i);
    case (i)
        4'd0: pattern = 32'h0000_0001;
        4'd1: pattern = 32'h0000_0010;
        4'd2: pattern = 32'h0001_0000;
        4'd3: pattern = 32'h1000_0000;
        4'd4: pattern = 32'hAAAA_5555;
        4'd5: pattern = 32'h5555_AAAA;
        4'd6: pattern = 32'hFFFF_0000;
        default: pattern = 32'h0000_FFFF;
    endcase
endfunction

// The high die carries the complement, so a low word clobbered by a high write
// can never coincidentally match the value the low die was given.
function [31:0] pattern_hi(input [3:0] i);
    pattern_hi = ~pattern(i);
endfunction

wire low_side  = (phase == 2'd0) || (phase == 2'd2);
wire is_read   = phase[1];
wire [23:0] base       = low_side ? LOW_BASE : HIGH_BASE;
wire [23:0] word_addr  = base + {20'd0, idx};
`ifdef TINYGBA_SDRAM_LANES
wire [31:0] write_data = 32'hFFFF_FFFF;
`else
wire [31:0] write_data = low_side ? pattern(idx) : pattern_hi(idx);
`endif

always @(posedge clk) begin
    if (~resetn) begin
        state     <= S_SETTLE;
        settle    <= 17'd0;
        phase     <= 2'd0;
        idx       <= 4'd0;
        is_read_r <= 1'b0;
        cpu_rd    <= 1'b0;
        cpu_wr    <= 1'b0;
        cpu_addr  <= 24'd0;
        cpu_wdata <= 32'd0;
        cpu_be    <= 4'b1111;
        cpu_port  <= PORT;
        result    <= 16'd0;
        done      <= 1'b0;
        rd_settle <= 1'b0;
    end else begin
        case (state)
        S_SETTLE: begin
            if (settle == SETTLE_COUNT) state <= S_REQ;
            else                        settle <= settle + 1'b1;
        end

        S_REQ: begin
            cpu_addr  <= word_addr;
            cpu_be    <= 4'b1111;
            cpu_port  <= PORT;
            cpu_wdata <= write_data;
            cpu_wr    <= ~is_read;
            cpu_rd    <= is_read;
            is_read_r <= is_read;
            state     <= S_WAIT;
        end

        S_WAIT: begin
            // Hold the request until the controller takes it.  A read's data is
            // in cpu_rdata[cpu_port] from the ready cycle.
            // `cpu_ready` marks the cycle BEFORE the data, not the cycle the
            // data is on.  gba_memory.sv documents a 32-bit SDRAM read as
            //
            //   sdram  |rd_lo| wait|rd_hi|ready| data
            //   ready                        |  1  |
            //
            // so for a two-halfword access cpu_rdata at the ready cycle holds
            // only the low halfword and the PREVIOUS high halfword.  Sampling
            // there made eight of the sixteen patterns report a fault that did
            // not exist -- every pattern whose high halfword was stale failed --
            // and the pattern of results is exactly what that predicts, which is
            // how the mistake was identified rather than guessed.
            // Two steps, not one: `cpu_ready` in the first, the data in the
            // second.  Taking the sample on the ready cycle itself is one clock
            // early, and the second step must not depend on ready still being
            // high -- it is a registered pulse and is gone by then.
            if (~rd_settle) begin
                if (cpu_ready) rd_settle <= 1'b1;
            end else begin
                rd_settle <= 1'b0;
                cpu_rd <= 1'b0;
                cpu_wr <= 1'b0;
                if (is_read_r) begin
`ifdef TINYGBA_SDRAM_LANES
                    // Raw readback: bars are data bits, not verdicts.  Written
                    // $FFFF_FFFF with be=1111 and read back, so a lane that is
                    // masked by DQM or never driven shows as red.
                    result <= cpu_rdata[PORT][15:0];
`else
                    if (low_side) result[idx]     <= (cpu_rdata[PORT] === pattern(idx));
                    else          result[8 + idx] <= (cpu_rdata[PORT] === pattern_hi(idx));
`endif
                end
                state <= S_NEXT;
            end
        end

        S_NEXT: begin
            if (idx != 4'd7) begin
                idx   <= idx + 1'b1;
                state <= S_REQ;
            end else begin
                idx <= 4'd0;
`ifdef TINYGBA_SDRAM_LANES
                // one word, written then read: phases 0 -> 2 -> done
                if (phase == 2'd2) begin
                    done  <= 1'b1;
                    state <= S_NEXT;    // park; result is final
                end else begin
                    phase <= 2'd2;
                    state <= S_REQ;
                end
`else
                if (phase == 2'd3) begin
                    done  <= 1'b1;
                    state <= S_NEXT;    // park; result is final
                end else begin
                    phase <= phase + 1'b1;
                    state <= S_REQ;
                end
`endif
            end
        end

        default: state <= S_SETTLE;
        endcase
    end
end

endmodule
