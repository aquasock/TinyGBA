// gba_save - save persistence engine for TinyGBA.
//
// The cartridge's save memory already has a second way in.  `sdram_gba` exposes
// a lowest-priority 16-bit port whose cart-RAM window starts at RV address
// 0x700000, and `rv_sdram_adapter` turns a 32-bit RV bus into it -- including
// the EEPROM, which the adapter reaches whenever `config_backup_type` is 4.
// Both were inherited from upstream and neither is instantiated in this tree:
// they exist for GBATang's RISC-V menu, which TinyGBA does not have.  Before
// this module the RV wires in `gbatang_top.sv` were driven by nothing, and the
// EEPROM's port-B write enable (`eeprom_wr`, which lands on `wreb` of
// `mem_eeprom`) was one of them.
//
// That port is the right way to read a save back, and much the right way to
// write one:
//
//   * It bypasses the flash command state machine, so a dump is a dump and a
//     restore is a plain write.  No 0xAA/0x55 unlock, no bank switch, no erase
//     timing -- and a 1 Mbit flash's second bank is reachable, which the
//     loader's stage-2 write path cannot do because it aliases at 64 KB.
//   * It is the lowest-priority user of the SDRAM controller, so a dump during
//     gameplay steals cycles rather than blocking, and it cannot disturb the
//     CPU path's handshake.
//
// What this module adds is the piece that was missing: a byte pump.  One
// request moves 128 bytes to or from the host in 32-bit RV transactions, and
// the bytes cross to `iosys_bl616`'s clock domain through a pair of small
// asynchronous FIFOs.
//
// Rates, so the buffering below can be justified rather than guessed.  A 32-bit
// RV read is two halfword SDRAM transactions; at 67 MHz that is tens of cycles,
// so the engine can produce a byte in a fraction of a clk16 cycle while the
// UART at 2 Mbaud consumes one every 83 clk16 cycles -- roughly sixty times
// slower.  The engine therefore runs ahead and is throttled by the FIFO, which
// is why 16 bytes of depth is ample and why the restore direction never comes
// close to overflowing.
//
// The transfer length is a compile-time 128 bytes on purpose: 128 divides
// 8 KB (EEPROM), 32 KB (SRAM), 64 KB (flash512) and 128 KB (flash1M) exactly,
// so there is no partial-chunk case anywhere in the RTL or the firmware.

`default_nettype none

// Dual-clock FIFO: Gray-coded pointers across the boundary, two flops of
// synchronisation on each side, and storage made of flip-flops on purpose.
//
// Two deliberate choices, both about not repeating a recorded fault.
//
// The storage is flip-flops with an explicit read mux rather than an inferred
// array.  `synth_gowin` maps a small array to `RAM16SDP4` on its own, which this
// project's census gate reports as a finding (TCL-033) because the sibling
// Tang-Tiny-GPU project records distributed RAM built by these open tools
// misbehaving on hardware while passing simulation.  These FIFOs are the one
// path in the design that would be debugged blind -- a broken save looks
// exactly like an empty save -- so they are built from the primitives this
// project has no such record against.  Four entries deep costs 32 flops and a
// 4:1 mux per FIFO, and four is ample: a 32-bit RV read is two halfword SDRAM
// transactions, so the engine can produce a byte in a fraction of a clk16
// cycle while the UART at 2 Mbaud takes one per ~100 clk16 cycles.  The engine
// runs far ahead and is throttled by fullness whatever the depth.
//
// There is no block-RAM variant for the same reason and one more: nextpnr's
// Gowin model does not time the setup path into a true dual-port BSRAM's B-port
// address, which is why `tools/bsram_addr_check.py` exists.  Using BSRAM here
// would put an untimed path in the middle of the transfer.
module save_afifo #(
    parameter integer DEPTH_LOG = 2,
    parameter integer W = 8
) (
    input  wire          wclk,
    input  wire          wresetn,
    input  wire          wr_en,
    input  wire [W-1:0]  wdata,
    output wire          full,

    input  wire          rclk,
    input  wire          rresetn,
    input  wire          rd_en,
    output wire [W-1:0]  rdata,
    output wire          empty
);
    localparam integer DEPTH = 1 << DEPTH_LOG;

    reg [W-1:0]        mem [0:DEPTH-1];
    reg [DEPTH_LOG:0]  wbin, wgray, rbin, rgray;

    reg [DEPTH_LOG:0]  rgray_w1, rgray_w2;
    reg [DEPTH_LOG:0]  wgray_r1, wgray_r2;

    function automatic [DEPTH_LOG:0] bin2gray(input [DEPTH_LOG:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // Write pointer
    wire [DEPTH_LOG:0] wbin_next = wbin + {{DEPTH_LOG{1'b0}}, (wr_en & ~full)};
    always @(posedge wclk) begin
        if (!wresetn) begin
            wbin  <= 0;
            wgray <= 0;
        end else begin
            wbin  <= wbin_next;
            wgray <= bin2gray(wbin_next);
        end
    end
    always @(posedge wclk)
        if (wr_en & ~full)
            mem[wbin[DEPTH_LOG-1:0]] <= wdata;

    // Read pointer
    wire [DEPTH_LOG:0] rbin_next = rbin + {{DEPTH_LOG{1'b0}}, (rd_en & ~empty)};
    always @(posedge rclk) begin
        if (!rresetn) begin
            rbin  <= 0;
            rgray <= 0;
        end else begin
            rbin  <= rbin_next;
            rgray <= bin2gray(rbin_next);
        end
    end

    // Combinational read: the reader may take `rdata` in the same cycle it
    // asserts `rd_en`, which is what lets the engine retire a byte on the edge
    // the FIFO accepts it.  A registered read port would put a byte of latency
    // inside the transfer and, worse, hide the offer/accept relationship that
    // an earlier version of this FIFO got wrong.
    genvar gi;
    generate
        for (gi = 0; gi < W; gi = gi + 1) begin : g_read_mux
            reg b;
            integer k;
            always @* begin
                b = mem[0][gi];
                for (k = 1; k < DEPTH; k = k + 1)
                    if (rbin[DEPTH_LOG-1:0] == k[DEPTH_LOG-1:0])
                        b = mem[k][gi];
            end
            assign rdata[gi] = b;
        end
    endgenerate

    // Pointer synchronisers.  (* async_reg *) so a tool that honours it does not
    // retime these into one flop; the pair is the standard MTBF argument.
    always @(posedge wclk) begin
        (* async_reg *) rgray_w1 <= rgray;
        (* async_reg *) rgray_w2 <= rgray_w1;
    end
    always @(posedge rclk) begin
        (* async_reg *) wgray_r1 <= wgray;
        (* async_reg *) wgray_r2 <= wgray_r1;
    end

    // Full when the next write pointer would meet the read pointer with the two
    // top bits inverted; empty when the read pointer has caught the write
    // pointer exactly.
    assign full  = (wgray == { ~rgray_w2[DEPTH_LOG:DEPTH_LOG-1],
                               rgray_w2[DEPTH_LOG-2:0] });
    assign empty = (rgray == wgray_r2);
endmodule

module gba_save (
    input  wire         clk16,        // iosys domain
    input  wire         clk67,        // SDRAM controller domain
    input  wire         resetn,

    // Request, asserted for one clk16 cycle while `busy` is low.  The address
    // is a byte address in the window the adapter understands: 0x700000 is the
    // first byte of cart RAM, bit 16 selects the flash bank, and 0x700000 is
    // also the first byte of the EEPROM when the configured save type is 4.
    input  wire         start,
    input  wire         start_we,     // 1: restore (write), 0: dump (read)
    input  wire [22:0]  start_addr,
    output wire         busy,         // clk16; high until the transfer is done

    // Dump stream, clk16: `d_valid` says a byte is waiting, `d_ready` takes it.
    output wire         d_valid,
    output wire [7:0]   d_byte,
    input  wire         d_ready,

    // Restore stream, clk16.
    input  wire         w_valid,
    input  wire [7:0]   w_byte,
    output wire         w_ready,

    // Sticky per-transfer failure: a restore byte arrived with nowhere to put
    // it.  Cleared when a new request is accepted and sampled by the caller at
    // the end of the transfer, so a chunk either lands whole or reports that it
    // did not.  The dump direction has no equivalent: the engine retires a byte
    // only on the cycle the FIFO accepts it, so it cannot overrun.
    output reg          err,
    // The engine's own failure flag, in clk67.  Sticky until the next transfer
    // is accepted; the caller synchronises it into its own domain and folds it
    // into `err`, so that `err` keeps a single driver.
    output reg          eng_fail,

    // 32-bit RV master into rv_sdram_adapter, clk67.
    output reg  [22:0]  rv_addr,
    output reg  [31:0]  rv_wdata,
    output reg  [3:0]   rv_wstrb,
    output reg          rv_valid,
    input  wire         rv_ready,
    input  wire [31:0]  rv_rdata
);
    localparam integer CHUNK_WORDS = 32;      // 128 bytes

    // ---------------------------------------------------------------- request
    //
    // clk16 latches the request and toggles `req_tog`.  clk67 sees the toggle
    // change and runs the transfer; when it finishes it toggles `ack_tog` back.
    // The address and direction are stable for as long as the toggle is out,
    // because clk16 will not accept a new request until `busy` falls, and
    // `busy` falls only on the returning toggle.  A toggle is used instead of a
    // pulse because a one-cycle clk16 pulse is not guaranteed to be seen by a
    // clock that is four times faster and not phase-related to it.
    reg          req_tog;
    reg  [22:0]  req_addr;
    reg          req_we;
    reg          req_pending;
    reg          ack_tog;
    reg          ack_tog_s1, ack_tog_s2;

    // The engine's own clk67 failure flag, synchronized in.  `err` has one
    // owning process -- this one, in clk16 -- because two always blocks driving
    // one register is the fault class BRD-064 records and the build's step-1a
    // gate refuses.  The engine therefore reports its stall timeout through
    // this flag instead of writing `err` itself.  Two flops, and it is only
    // ever sampled at the end of a transfer, long after the crossing settles.
    // `eng_fail` is only sampled at the acknowledged edge, so it needs no
    // arming and no clearing discipline: the engine clears it when it accepts
    // the next transfer, which is after that edge, and a stale high level from
    // the previous transfer therefore cannot leak into this one.  The earlier
    // version latched it continuously and needed an `fail_armed` guard, which
    // both raced and gave one register two writers.
    reg  eng_fail_s1, eng_fail_s2;
    always @(posedge clk16) begin
        if (!resetn) begin
            eng_fail_s1 <= 1'b0;
            eng_fail_s2 <= 1'b0;
        end else begin
            (* async_reg *) eng_fail_s1 <= eng_fail;
            (* async_reg *) eng_fail_s2 <= eng_fail_s1;
        end
    end

    assign busy = req_pending;

    always @(posedge clk16) begin
        if (!resetn) begin
            req_tog     <= 1'b0;
            err         <= 1'b0;
            req_addr    <= 23'd0;
            req_we      <= 1'b0;
            req_pending <= 1'b0;
            ack_tog_s1  <= 1'b0;
            ack_tog_s2  <= 1'b0;
        end else begin
            (* async_reg *) ack_tog_s1 <= ack_tog;
            (* async_reg *) ack_tog_s2 <= ack_tog_s1;

            if (start & ~req_pending) begin
                req_addr    <= start_addr;
                req_we      <= start_we;
                req_tog     <= ~req_tog;
                req_pending <= 1'b1;
                err         <= 1'b0;
                end

            // Sticky for the rest of this transfer.  Both terms are seen in
            // clk16: the overrun directly, the engine's flag through the
            // synchroniser above.
            // Decided at the acknowledged edge: the transfer is over, the
            // synchronised engine flag has long settled, and the value describes
            // the transfer that just finished rather than the one that follows.
            //
            // A restore byte that arrives with no room is NOT detected here.  An
            // earlier version tried, with `w_valid & rx_full`, and it was dead
            // logic: `save_w_valid` at the iosys end already ANDs `save_w_ready`,
            // so a byte is never *offered* to a full FIFO -- it is gated and
            // dropped upstream.  The loss is still caught, by the other route:
            // the engine waits for a byte that never arrives, the stall bound in
            // ST_WR_C fires, `eng_fail` latches, and this reports status 2.
            if (req_pending && (ack_tog_s2 == req_tog))
                err <= eng_fail_s2;

            if (req_pending && (ack_tog_s2 == req_tog))
                req_pending <= 1'b0;
        end
    end

    // ------------------------------------------------------------- byte pipes
    //
    // dump bytes:    produced in clk67, consumed in clk16.
    // restore bytes: produced in clk16, consumed in clk67.
    //
    // Both FIFO controls (tx_wr, rx_rd) are combinational functions of the
    // engine's state, so the engine can retire a byte on the same edge the FIFO
    // accepts it.  An earlier version registered tx_wr and decided to retire on
    // the following cycle, having checked `full` one cycle before the FIFO
    // sampled `wr_en`; whenever `full` rose in between, the byte was counted but
    // never written.  The testbench measured 89 of 128 bytes arriving.  Keeping
    // offer and retire in the same cycle removes the window rather than narrowing
    // it.
    wire        tx_full, tx_empty;
    wire        tx_wr;
    wire [7:0]  tx_data;
    wire        tx_rd;

    save_afifo #(.DEPTH_LOG(4), .W(8)) dump_fifo (
        .wclk(clk67), .wresetn(resetn), .wr_en(tx_wr), .wdata(tx_data), .full(tx_full),
        .rclk(clk16), .rresetn(resetn), .rd_en(tx_rd), .rdata(d_byte), .empty(tx_empty)
    );
    assign d_valid = ~tx_empty;
    assign tx_rd   = d_ready & ~tx_empty;

    wire        rx_full, rx_empty;
    wire        rx_wr;
    wire [7:0]  rx_data;
    wire        rx_rd;
    wire [7:0]  rx_q;

    save_afifo #(.DEPTH_LOG(4), .W(8)) restore_fifo (
        .wclk(clk16), .wresetn(resetn), .wr_en(rx_wr), .wdata(rx_data), .full(rx_full),
        .rclk(clk67), .rresetn(resetn), .rd_en(rx_rd), .rdata(rx_q), .empty(rx_empty)
    );
    assign w_ready = ~rx_full;
    assign rx_wr   = w_valid & ~rx_full;
    assign rx_data = w_byte;



    // ------------------------------------------------------------ clk67 engine
    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_FLUSH = 3'd6,
                     ST_RD    = 3'd1,  // issue a 32-bit read
                     ST_RD_P  = 3'd2,  // push its four bytes into the dump FIFO
                     ST_WR_C  = 3'd3,  // collect four bytes from the restore FIFO
                     ST_WR    = 3'd4,  // issue a 32-bit write, wait for ready
                     ST_DONE  = 3'd5;

    reg [2:0]   st;
    reg         req_tog_s1, req_tog_s2;
    reg [22:0]  base_addr;
    reg         base_we;
    reg [4:0]   word_i;               // 0..CHUNK_WORDS-1
    reg [31:0]  hold;                 // read data, drained a byte at a time
    reg [2:0]   hold_n;               // bytes still to push
    reg [31:0]  collect;              // write data, filled a byte at a time
    reg [2:0]   collect_n;
    reg [12:0]  wr_stall;             // clk67 cycles spent waiting for the next
                                      // restore byte; see ST_WR_C

    // Combinational FIFO controls: the FIFO's own write/read enable, the data it
    // presents, and the same condition the FIFO uses to decide it happened.
    // `tx_data` is combinational for the same reason `tx_wr` is: a registered
    // data bus behind a combinational enable hands the FIFO the previous byte,
    // which the testbench measured as a one-byte lag with a leading zero.  It is
    // assigned below, next to `hold`, which it reads.
    assign tx_wr   = (st == ST_RD_P) & (hold_n != 3'd0);
    wire   tx_ok   = tx_wr & ~tx_full;
    // The flush state pops unconditionally; the collect state pops one byte per
    // cycle until it has four.  Both are the same wire because the FIFO read
    // port has one enable.
    assign rx_rd   = ((st == ST_WR_C) & (collect_n != 3'd4)) | (st == ST_DONE);
    wire   rx_ok   = rx_rd & ~rx_empty;
    assign tx_data = hold[7:0];

    always @(posedge clk67) begin
        if (!resetn) begin
            st          <= ST_IDLE;
            req_tog_s1  <= 1'b0;
            req_tog_s2  <= 1'b0;
            ack_tog     <= 1'b0;
            rv_valid    <= 1'b0;
            rv_addr     <= 23'd0;
            rv_wdata    <= 32'd0;
            rv_wstrb    <= 4'd0;
            base_addr   <= 23'd0;
            base_we     <= 1'b0;
            word_i      <= 5'd0;
            hold        <= 32'd0;
            hold_n      <= 3'd0;
            collect     <= 32'd0;
            collect_n   <= 3'd0;
            wr_stall    <= 13'd0;
            eng_fail    <= 1'b0;
        end else begin
            (* async_reg *) req_tog_s1 <= req_tog;
            (* async_reg *) req_tog_s2 <= req_tog_s1;

            case (st)
            ST_IDLE: begin
                rv_valid <= 1'b0;
                if (req_tog_s2 != ack_tog) begin
                    base_addr <= req_addr;
                    base_we   <= req_we;
                    word_i    <= 5'd0;
                    hold_n    <= 3'd0;
                    collect_n <= 3'd0;
                    // Must be cleared here as well as on a successful word, or
                    // the previous transfer's terminal count makes the next
                    // transfer abort at word 0 without moving anything -- a
                    // truncated chunk would then poison every chunk after it.
                    wr_stall  <= 13'd0;
                    eng_fail  <= 1'b0;
                    st        <= req_we ? ST_WR_C : ST_RD;
                end
            end

            ST_RD: begin
                if (!rv_valid) begin
                    // A read carries a zero write mask.  rv_sdram_adapter
                    // derives the direction from it (`mem_we = rv_wstrb != 0`),
                    // so asserting 1111 here turns a dump into a write of
                    // rv_wdata -- which is zeros -- and erases the save it was
                    // asked to read.  Measured in tools/save/tb_save.sv: the
                    // first dump returned 0x00 and destroyed the image.
                    rv_addr  <= base_addr + {word_i, 2'b00};
                    rv_wstrb <= 4'b0000;
                    rv_valid <= 1'b1;
                end else if (rv_ready) begin
                    rv_valid <= 1'b0;
                    hold     <= rv_rdata;
                    hold_n   <= 3'd4;
                    st       <= ST_RD_P;
                end
            end

            // One byte per cycle, low byte first, so the host sees memory
            // order.  Stopped whole when the dump FIFO fills; that is the
            // throttle that keeps the engine behind the UART.
            ST_RD_P: begin
                if (tx_ok) begin
                    hold   <= {8'd0, hold[31:8]};
                    hold_n <= hold_n - 3'd1;
                    if (hold_n == 3'd1) begin
                        if (word_i == CHUNK_WORDS-1)
                            st <= ST_DONE;
                        else begin
                            word_i <= word_i + 5'd1;
                            st     <= ST_RD;
                        end
                    end
                end
            end

            // Gather four bytes, then write them as one 32-bit RV access.
            // Nothing can arrive out of order or be lost: the FIFO is filled by
            // the iosys frame decoder in stream order and drained only here.
            ST_WR_C: begin
                if (collect_n != 3'd4) begin
                    if (rx_ok) begin
                        collect   <= {rx_q, collect[31:8]};
                        collect_n <= collect_n + 3'd1;
                        wr_stall  <= 13'd0;
                    end else if (wr_stall == 13'd4096) begin
                        // The host stopped mid-chunk -- a truncated frame, or a
                        // byte the link lost.  Without this bound the engine
                        // waits for a fourth byte that will never come, `busy`
                        // never falls, and every later save command is wedged
                        // behind it.  Report instead: the chunk did not land.
                        // The bound is far longer than the 5 us a byte takes at
                        // 2 Mbaud, so it cannot fire on a live transfer.
                        eng_fail <= 1'b1;
                        st       <= ST_DONE;
                    end else
                        wr_stall <= wr_stall + 13'd1;
                end else begin
                    rv_addr  <= base_addr + {word_i, 2'b00};
                    rv_wdata <= collect;
                    rv_wstrb <= 4'b1111;
                    rv_valid <= 1'b1;
                    collect_n <= 3'd0;
                    wr_stall  <= 13'd0;
                    st       <= ST_WR;
                end
            end

            ST_WR: begin
                if (rv_ready) begin
                    rv_valid <= 1'b0;
                    if (word_i == CHUNK_WORDS-1)
                        st <= ST_DONE;
                    else begin
                        word_i <= word_i + 5'd1;
                        st     <= ST_WR_C;
                    end
                end
            end

            // Do not acknowledge until the restore pipe is empty.  A transfer
            // that ended early -- a host that sent more bytes than a chunk
            // holds, or one the stall bound above cut short -- leaves the
            // surplus queued, and acknowledging before draining it would hand
            // that tail to the next chunk as its first bytes.  Measured in
            // tools/save/tb_save.sv: a 512-byte flood followed by a clean
            // 128-byte restore landed the flood's filler in the second chunk.
            //
            // This has to happen at the end of a transfer and not at the start:
            // a drain on accept races the new chunk's first bytes, which the
            // host may already be sending, and eats them -- measured as a
            // one-byte shift through the whole second chunk.  The exchange is
            // strictly one request to one answer, so nothing can arrive between
            // here and the next request.
            ST_DONE: begin
                if (rx_empty) begin
                    ack_tog <= req_tog_s2;
                    st      <= ST_IDLE;
                end
            end

            default: st <= ST_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
