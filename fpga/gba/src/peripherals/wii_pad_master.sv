// SPDX-License-Identifier: GPL-3.0-only
// TinyGBA: vendored from TinyNES `fpga/ae350_soc/wii_pads.sv` (module
// `wii_pad_master`, GPL-3.0-only, https://github.com/aquasock/TinyNES at
// 7013393).  The module body below is byte-identical to upstream; only this
// header is added, so `diff` against the source still works.
//
// Why only this module.  Upstream's file carries a second module, `wii_pads`,
// which is an AHB slave with four bus masters and a register file at
// 0xe8040000 for the AE350 SoC.  TinyGBA has no AHB bus and no need for the
// register file: it wants exactly one controller's buttons folded into its
// keypad, so only the per-bus master is taken and the wiring lives in
// `gbatang_top.sv`.  That is a smaller change than porting the AHB layer and
// it keeps the GBA memory map untouched.
//
// What this module is.  An open-drain I2C master that owns a Wii extension
// bus: it wakes the controller unencrypted (0x55 to 0xF0, 0x00 to 0xFB),
// selects data format 3 (0x03 to 0xFE), reads the six-byte identity at 0xFA,
// then polls: set the pointer to 0x00, wait CONVERT_US, read eight bytes.  Each
// format-3 report is repacked into format 1's six bytes so the consumer sees
// the layout a genuine Classic Controller reports.  It tolerates clock
// stretching, retries after 100 ms when a byte is not acknowledged, and marks
// the controller absent on a NACK or on SCL held low for 1 ms.
//
// The button bit positions are upstream's and were validated on this board by
// TinyNES's `pad_test` against a genuine Classic Controller and an 8BitDo
// Retro Receiver; `data[47:32]` is report bytes 4 and 5, active low, byte 4 in
// bits 7:0.  See THIRD_PARTY.md and TCL-057.
//
// Registers are not exposed.  The outputs are the ones TinyGBA consumes:
// `present`, `classic`, the `data` report and read/fail counters for a future
// diagnostic page.
module wii_pad_master #(
    parameter integer US_CLOCKS = 75,
    parameter integer CONVERT_US = 200
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        restart,
    input  wire [11:0] quarter,
    input  wire        scl_in,
    input  wire        sda_in,
    output reg         scl_low,
    output reg         sda_low,
    output reg         present,
    output reg         classic,
    output reg  [15:0] reads,
    output reg  [7:0]  fails,
    output reg  [47:0] data,
    output reg  [47:0] ident
);
    localparam [7:0] ADDR_W = 8'hA4, ADDR_R = 8'hA5; // 0x52 shifted, R/W bit

    // Synchronised line levels.
    reg [1:0] scl_s = 2'b11, sda_s = 2'b11;
    wire scl = scl_s[1], sda = sda_s[1];

    // A microsecond tick for the sequencer's waits.
    reg [7:0] us_div = 8'd0;
    wire us_tick = us_div == US_CLOCKS - 1;

    // ---------------------------------------------------- transfer layer --
    // go starts one transfer: START, the address byte (read when rd), then
    // len bytes written from wbytes or rlen bytes read into rbytes (the last
    // one in 63:56), then STOP.
    // done pulses at the end, with nack set if a byte was not acknowledged
    // or SCL stayed low for 1 ms.
    localparam [3:0] T_IDLE = 4'd0, T_START0 = 4'd1, T_START1 = 4'd2, T_START2 = 4'd3,
                     T_BIT0 = 4'd4, T_BIT1 = 4'd5, T_BIT2 = 4'd6, T_BIT3 = 4'd7,
                     T_STOP0 = 4'd8, T_STOP1 = 4'd9, T_STOP2 = 4'd10, T_DONE = 4'd11;
    reg [3:0] t = T_IDLE;
    reg go = 1'b0, rd = 1'b0;
    reg [1:0] len = 2'd0;          // bytes written after the address
    reg [15:0] wbytes = 16'd0;     // first in 15:8
    reg [3:0] rlen = 4'd6;         // bytes read: 6 identity, 8 data
    reg [63:0] rbytes = 64'd0;
    reg done = 1'b0, nack = 1'b0;
    reg [11:0] qcount = 12'd0;
    reg [9:0] stretch_us = 10'd0;
    reg [7:0] shift = 8'd0;
    reg [3:0] bitn = 4'd0;         // 8 = the acknowledge bit
    reg [3:0] byten = 4'd0;        // 0 = address
    wire last_byte = rd ? byten == rlen : byten == {2'b0, len};
    wire q_end = qcount == quarter;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            t <= T_IDLE;
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            done <= 1'b0;
            nack <= 1'b0;
            qcount <= 12'd0;
            stretch_us <= 10'd0;
            scl_s <= 2'b11;
            sda_s <= 2'b11;
            us_div <= 8'd0;
        end else begin
            scl_s <= {scl_s[0], scl_in};
            sda_s <= {sda_s[0], sda_in};
            us_div <= us_tick ? 8'd0 : us_div + 1'b1;
            done <= 1'b0;
            qcount <= q_end ? 12'd0 : qcount + 1'b1;
            // A restart is the sequencer's alone: a transfer in flight runs
            // to its STOP, because one cut short leaves the controller
            // mid-byte and holding SDA, out of step with the next START.
            case (t)
                T_IDLE: begin
                    qcount <= 12'd0;
                    if (go) begin
                        nack <= 1'b0;
                        byten <= 4'd0;
                        bitn <= 4'd0;
                        shift <= rd ? ADDR_R : ADDR_W;
                        scl_low <= 1'b0;
                        sda_low <= 1'b0;
                        stretch_us <= 10'd0;
                        t <= T_START0;
                    end
                end
                // Both lines released and SCL high, then SDA falls, then SCL.
                T_START0:
                    if (!scl) begin
                        qcount <= 12'd0;
                        if (us_tick) stretch_us <= stretch_us + 1'b1;
                        if (stretch_us == 10'd1000) begin
                            nack <= 1'b1;
                            t <= T_DONE;
                        end
                    end else if (q_end) begin
                        sda_low <= 1'b1;
                        t <= T_START1;
                    end
                T_START1:
                    if (q_end) begin
                        scl_low <= 1'b1;
                        t <= T_START2;
                    end
                T_START2:
                    if (q_end)
                        t <= T_BIT0;
                // A bit: SCL low while SDA is set, SCL released, sampled in
                // the high half, SCL pulled low again.
                T_BIT0: begin
                    if (bitn == 4'd8)
                        // Acknowledge: we drive it after a read byte that is
                        // not the last; otherwise SDA is the controller's.
                        sda_low <= rd && byten != 4'd0 && !last_byte;
                    else if (rd && byten != 4'd0)
                        sda_low <= 1'b0;
                    else
                        sda_low <= !shift[7];
                    if (q_end) begin
                        scl_low <= 1'b0;
                        stretch_us <= 10'd0;
                        t <= T_BIT1;
                    end
                end
                T_BIT1:
                    // Wait for SCL to read high: a slow rise or stretching.
                    if (!scl) begin
                        qcount <= 12'd0;
                        if (us_tick) stretch_us <= stretch_us + 1'b1;
                        if (stretch_us == 10'd1000) begin
                            nack <= 1'b1;
                            t <= T_STOP0;
                        end
                    end else if (q_end) begin
                        t <= T_BIT2;
                    end
                T_BIT2:
                    if (q_end) begin
                        if (bitn == 4'd8) begin
                            if (!(rd && byten != 4'd0) && sda)
                                nack <= 1'b1;
                        end else begin
                            shift <= {shift[6:0], sda};
                        end
                        scl_low <= 1'b1;
                        t <= T_BIT3;
                    end
                T_BIT3:
                    if (q_end) begin
                        if (bitn != 4'd8) begin
                            bitn <= bitn + 1'b1;
                            t <= T_BIT0;
                        end else begin
                            bitn <= 4'd0;
                            if (rd && byten != 4'd0)
                                rbytes <= {shift, rbytes[63:8]};
                            if (nack || last_byte) begin
                                sda_low <= 1'b1;
                                t <= T_STOP0;
                            end else begin
                                byten <= byten + 1'b1;
                                shift <= rd ? 8'h00 : (byten == 4'd0 ? wbytes[15:8] : wbytes[7:0]);
                                t <= T_BIT0;
                            end
                        end
                    end
                // SDA low with SCL low, SCL released, then SDA released.
                T_STOP0: begin
                    sda_low <= 1'b1;
                    if (q_end) begin
                        scl_low <= 1'b0;
                        stretch_us <= 10'd0;
                        t <= T_STOP1;
                    end
                end
                T_STOP1:
                    if (!scl) begin
                        qcount <= 12'd0;
                        if (us_tick) stretch_us <= stretch_us + 1'b1;
                        if (stretch_us == 10'd1000) begin
                            nack <= 1'b1;
                            sda_low <= 1'b0;
                            t <= T_DONE;
                        end
                    end else if (q_end) begin
                        sda_low <= 1'b0;
                        t <= T_STOP2;
                    end
                T_STOP2:
                    if (q_end)
                        t <= T_DONE;
                T_DONE: begin
                    scl_low <= 1'b0;
                    sda_low <= 1'b0;
                    done <= 1'b1;
                    t <= T_IDLE;
                end
                default: t <= T_IDLE;
            endcase
        end
    end

    // --------------------------------------------------------- sequencer --
    localparam [3:0] Q_WAIT = 4'd0, Q_WAKE1 = 4'd1, Q_WAKE2 = 4'd2, Q_IDPTR = 4'd3,
                     Q_IDREAD = 4'd4, Q_PTR = 4'd5, Q_READ = 4'd6, Q_BUSY = 4'd7,
                     Q_FORMAT = 4'd8;
    reg [3:0] q = Q_WAIT, q_next = Q_WAKE1;
    reg [16:0] wait_us = 17'd20000;   // the first wake 20 ms after reset
    reg [16:0] after_us = 17'd0;      // the wait after the transfer in flight
    // The read in flight is the identity until the first data read.
    reg ident_pending = 1'b1;

    // The identity is the 6 bytes a 6-byte read leaves at the top of rbytes.
    wire [47:0] id_bytes = rbytes[63:16];
    // A format-3 report, byte 0 in 7:0, packed into format 1's six bytes:
    // byte 0 RX[4:3] LX[5:0], byte 1 RX[2:1] LY[5:0], byte 2 RX[0] LT[4:3]
    // RY[4:0], byte 3 LT[2:0] RT[4:0], bytes 4 and 5 the buttons, each 6-bit
    // axis the top of its byte and each 5-bit one likewise.
    wire [7:0] lx = rbytes[7:0],   rx = rbytes[15:8],  ly = rbytes[23:16];
    wire [7:0] ry = rbytes[31:24], lt = rbytes[39:32], rt = rbytes[47:40];
    wire [47:0] format1 = {rbytes[63:56], rbytes[55:48],
                           lt[5:3], rt[7:3],
                           rx[3], lt[7:6], ry[7:3],
                           rx[5:4], ly[7:2],
                           rx[7:6], lx[7:2]};

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            q <= Q_WAIT;
            q_next <= Q_WAKE1;
            wait_us <= 17'd20000;
            after_us <= 17'd0;
            go <= 1'b0;
            present <= 1'b0;
            classic <= 1'b0;
            reads <= 16'd0;
            fails <= 8'd0;
            data <= 48'd0;
            ident <= 48'd0;
        end else begin
            go <= 1'b0;
            if (restart) begin
                q <= Q_WAIT;
                q_next <= Q_WAKE1;
                wait_us <= 17'd20000;
                present <= 1'b0;
                classic <= 1'b0;
            end else case (q)
                Q_WAIT:
                    if (wait_us == 17'd0)
                        q <= q_next;
                    else if (us_tick)
                        wait_us <= wait_us - 1'b1;
                Q_WAKE1: begin
                    rd <= 1'b0; len <= 2'd2; wbytes <= 16'hF055;
                    after_us <= 17'd10000; q_next <= Q_WAKE2;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_WAKE2: begin
                    rd <= 1'b0; len <= 2'd2; wbytes <= 16'hFB00;
                    after_us <= 17'd20000; q_next <= Q_FORMAT;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_FORMAT: begin
                    rd <= 1'b0; len <= 2'd2; wbytes <= 16'hFE03;
                    after_us <= 17'd20000; q_next <= Q_IDPTR;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_IDPTR: begin
                    rd <= 1'b0; len <= 2'd1; wbytes <= 16'hFA00;
                    after_us <= CONVERT_US; q_next <= Q_IDREAD;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_IDREAD: begin
                    rd <= 1'b1; rlen <= 4'd6;
                    after_us <= 17'd1000; q_next <= Q_PTR;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_PTR: begin
                    rd <= 1'b0; len <= 2'd1; wbytes <= 16'h0000;
                    after_us <= CONVERT_US; q_next <= Q_READ;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_READ: begin
                    rd <= 1'b1; rlen <= 4'd8;
                    after_us <= 17'd1000; q_next <= Q_PTR;
                    go <= 1'b1; q <= Q_BUSY;
                end
                Q_BUSY:
                    if (done) begin
                        if (nack) begin
                            fails <= fails + 1'b1;
                            present <= 1'b0;
                            classic <= 1'b0;
                            wait_us <= 17'd100000;
                            q_next <= Q_WAKE1;
                        end else begin
                            wait_us <= after_us;
                            if (q_next == Q_PTR && rd) begin
                                if (ident_pending) begin
                                    ident <= id_bytes;
                                    // 0x0[01] 0x00 0xA4 0x20 0x0[0-3] 0x01
                                    classic <= id_bytes[7:1] == 7'd0 && id_bytes[15:8] == 8'h00 &&
                                               id_bytes[23:16] == 8'hA4 && id_bytes[31:24] == 8'h20 &&
                                               id_bytes[39:34] == 6'd0 && id_bytes[47:40] == 8'h01;
                                    present <= 1'b1;
                                end else begin
                                    data <= format1;
                                    reads <= reads + 1'b1;
                                end
                            end
                        end
                        q <= Q_WAIT;
                    end
                default: q <= Q_WAIT;
            endcase
        end
    end

    always @(posedge clk or negedge resetn)
        if (!resetn)
            ident_pending <= 1'b1;
        else if (restart || (q == Q_BUSY && done && nack))
            ident_pending <= 1'b1;
        else if (q == Q_IDREAD)
            ident_pending <= 1'b1;
        else if (q == Q_READ)
            ident_pending <= 1'b0;
endmodule
