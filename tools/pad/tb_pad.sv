// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
// Regression test for the Wii Classic Controller integration.
//
// The pad path has four parts and only one of them is upstream's: the vendored
// `wii_pad_master` (byte-identical to TinyNES), the open-drain wiring, the
// clk16 synchroniser, and the button mapping onto GBA `joy_btns`.  This drives
// the first through a byte-level controller model and checks the last, so a
// change to either the mapping or the wiring fails here rather than on the
// board.
//
// `US_CLOCKS` is compressed from the synthesis value so the wake-up's tens of
// milliseconds of protocol waits simulate in milliseconds.  Everything the
// test checks -- command order, format selection, byte counts, ACK handling,
// button bit positions -- is independent of that compression.
//
// Run with tools/pad/run_pad_tb.sh.

module tb_pad;
  parameter bit    RECEIVER   = 1'b0;   // 1: 8BitDo Retro Receiver behaviour
  parameter integer US_CLOCKS = 4;
  parameter [11:0]  QUARTER   = 4;

  // Pad bit indices, from TinyNES `pad_test`'s table -- the map the operator
  // validated on this board against a genuine Classic Controller and a
  // Retro Receiver.
  localparam integer PAD_ZL=15, PAD_B=14, PAD_Y=13, PAD_A=12, PAD_X=11,
                     PAD_ZR=10, PAD_LEFT=9, PAD_UP=8, PAD_RIGHT=7, PAD_DOWN=6,
                     PAD_L=5, PAD_SELECT=4, PAD_HOME=3, PAD_START=2, PAD_R=1;
  // joy_btns order: (R L X A RT LT DN UP START SELECT Y B)
  localparam integer JB_R=11, JB_L=10, JB_A=8, JB_RT=7, JB_LT=6,
                     JB_DN=5, JB_UP=4, JB_ST=3, JB_SE=2, JB_B=0;

  reg clk = 0, clk16 = 0, resetn = 0;
  always #5  clk   = ~clk;
  always #40 clk16 = ~clk16;

  wire pad_scl, pad_sda, m_scl_low, m_sda_low, c_scl_low, c_sda_low;
  assign pad_scl = ~(m_scl_low | c_scl_low);
  assign pad_sda = ~(m_sda_low | c_sda_low);

  wire        present, classic;
  wire [15:0] reads;
  wire [7:0]  fails;
  wire [47:0] data;

  wii_pad_master #(.US_CLOCKS(US_CLOCKS)) dut (
      .clk(clk), .resetn(resetn), .restart(1'b0), .quarter(QUARTER),
      .scl_in(pad_scl), .sda_in(pad_sda),
      .scl_low(m_scl_low), .sda_low(m_sda_low),
      .present(present), .classic(classic),
      .reads(reads), .fails(fails), .data(data), .ident());

  wii_classic_model #(.INDEX(0), .RECEIVER(RECEIVER)) ctl (
      .clk(clk), .attached(1'b1), .scl(pad_scl), .sda(pad_sda),
      .scl_low(c_scl_low), .sda_low(c_sda_low));

  // ---- the TinyGBA glue, mirroring fpga/gba/src/gbatang_top.sv ----
  wire [15:0] pad_held = present & classic ? ~data[47:32] : 16'd0;
  reg [15:0] pad_held_m = 0, pad_held_s = 0;
  always @(posedge clk16) begin
    pad_held_m <= pad_held;
    pad_held_s <= pad_held_m;
  end
  wire [11:0] joy_wii = {
      pad_held_s[PAD_R]  | pad_held_s[PAD_ZR],
      pad_held_s[PAD_L]  | pad_held_s[PAD_ZL],
      1'b0,
      pad_held_s[PAD_A]  | pad_held_s[PAD_X],
      pad_held_s[PAD_RIGHT], pad_held_s[PAD_LEFT],
      pad_held_s[PAD_DOWN],  pad_held_s[PAD_UP],
      pad_held_s[PAD_START], pad_held_s[PAD_SELECT],
      1'b0,
      pad_held_s[PAD_B]  | pad_held_s[PAD_Y] };

  integer bad = 0;

  initial begin
    resetn = 0;
    repeat (20) @(posedge clk);
    resetn = 1;

    fork : wait_poll
      begin
        wait (reads >= 16'd1);
        disable wait_poll;
      end
      begin
        #20_000_000;
        $display("TIMEOUT: no poll; present=%b classic=%b fails=%0d",
                 present, classic, fails);
        $fatal(1);
      end
    join

    // Sample after the continuous assign and the synchroniser settle; reading
    // at the edge that raised `reads` races both.
    repeat (8) @(posedge clk16);

    $display("%0s: present=%b classic=%b reads=%0d fails=%0d data=%012x joy_wii=%03x",
             RECEIVER ? "receiver" : "classic ", present, classic, reads, fails,
             data, joy_wii);

    if (!present) begin $display("FAIL: controller not detected");  bad = bad + 1; end
    if (!classic) begin $display("FAIL: not a Classic Controller"); bad = bad + 1; end
    if (fails != 0) begin $display("FAIL: %0d I2C NACK(s)", fails); bad = bad + 1; end

    // The model holds exactly one button.  Per `pad_test`'s table that bit is
    // ZR (pad bit 10), which this project maps to GBA R.  Both models send the
    // same button bytes, so both must land on R.
    if (pad_held !== (16'd1 << PAD_ZR)) begin
      $display("FAIL: pad_held=%04x, expected only ZR (bit %0d)", pad_held, PAD_ZR);
      bad = bad + 1;
    end
    if (joy_wii !== (12'd1 << JB_R)) begin
      $display("FAIL: joy_wii=%03x, expected only R (bit %0d)", joy_wii, JB_R);
      bad = bad + 1;
    end

    if (bad == 0) $display("PASS: %0s path detected, identified, polled, mapped to R",
                           RECEIVER ? "receiver" : "classic");
    else begin $display("FAILED: %0d check(s)", bad); $fatal(1); end
    $finish;
  end
endmodule
