// SPDX-License-Identifier: GPL-3.0-only
// Testbench for gba_save + rv_sdram_adapter.
//
// The pair is the whole save-persistence path: the engine pumps 128 bytes to or
// from the host across a clock boundary, and the adapter turns those into the
// 16-bit SDRAM transactions the cartridge's save window is stored in.  Both
// halves are checked here against a model of the controller's handshake, so a
// fault is found in a two-second run instead of a fifty-minute synthesis and a
// card swap.
//
// The model deliberately keeps the controller's timing shape -- request
// accepted, acknowledgement a couple of cycles later, read data a couple of
// cycles after that -- because that shape is what the adapter's state machine
// is written against.  A model that answered instantly would pass a broken
// adapter, which is the blind spot this project has been bitten by before.
//
//   tools/save/run_save_tb.sh
//
// Exits 0 when every check passes.

`timescale 1ns/1ps
`default_nettype none

module tb_save;

    // Two clocks in the ratio the board uses: clk67 is four times clk16 and is
    // not phase-related to it.
    reg clk16 = 0;
    reg clk67 = 0;
    always #30.0 clk16 = ~clk16;      // 60 ns  -> 16.67 MHz
    always #7.5  clk67 = ~clk67;      // 15 ns  -> 66.67 MHz

    reg resetn = 0;

    // ------------------------------------------------------------ engine + bus
    reg         start = 0;
    reg         start_we = 0;
    reg  [22:0] start_addr = 0;
    wire        busy;
    wire        d_valid;
    wire [7:0]  d_byte;
    reg         d_ready = 0;
    reg         w_valid = 0;
    reg  [7:0]  w_byte = 0;
    wire        w_ready;
    wire        err;

    wire [22:0] rv_addr;
    wire [31:0] rv_wdata;
    wire [3:0]  rv_wstrb;
    wire        rv_valid;
    wire        rv_ready;
    wire [31:0] rv_rdata;

    // adapter <-> controller
    wire [22:1] mem_addr;
    wire        mem_req;
    wire [1:0]  mem_ds;
    wire [15:0] mem_din;
    wire        mem_we;
    wire        mem_req_ack;
    reg  [15:0] mem_dout;

    // adapter <-> eeprom
    wire        eeprom_rd, eeprom_wr;
    wire [12:0] eeprom_addr;
    reg  [7:0]  eeprom_rdata;
    wire [7:0]  eeprom_wdata;

    reg  [2:0]  config_backup_type = 3'd3;   // SRAM by default

    parameter ADAPTER_CLK67 = 0;
    wire adapter_clk = ADAPTER_CLK67 ? clk67 : clk16;

    gba_save dut (
        .clk16(clk16), .clk67(clk16), .resetn(resetn),
        .start(start), .start_we(start_we), .start_addr(start_addr), .busy(busy),
        .d_valid(d_valid), .d_byte(d_byte), .d_ready(d_ready),
        .w_valid(w_valid), .w_byte(w_byte), .w_ready(w_ready), .err(err),
        .rv_addr(rv_addr), .rv_wdata(rv_wdata), .rv_wstrb(rv_wstrb),
        .rv_valid(rv_valid), .rv_ready(rv_ready), .rv_rdata(rv_rdata)
    );

    rv_sdram_adapter adapter (
        .clk(adapter_clk), .resetn(resetn), .config_backup_type(config_backup_type),
        .rv_valid(rv_valid), .rv_addr(rv_addr), .rv_wdata(rv_wdata),
        .rv_wstrb(rv_wstrb), .rv_ready(rv_ready), .rv_rdata(rv_rdata),
        .eeprom_rd(eeprom_rd), .eeprom_wr(eeprom_wr), .eeprom_addr(eeprom_addr),
        .eeprom_rdata(eeprom_rdata), .eeprom_wdata(eeprom_wdata),
        .mem_addr(mem_addr), .mem_req(mem_req), .mem_ds(mem_ds), .mem_din(mem_din),
        .mem_we(mem_we), .mem_req_ack(mem_req_ack), .mem_dout(mem_dout)
    );

    // --------------------------------------------------------- memory model
    //
    // 128 KB of cart RAM as the flash/SRAM window sees it: word address
    // mem_addr[22:2], halfword select mem_addr[1].  The byte image is little
    // endian, which is what the engine's low-byte-first pump assumes.
    reg [31:0] xmem [0:32767];
    reg [7:0]  emem [0:8191];

    // The controller model.  A 4-phase slot counter reproduces `sdram_gba`'s
    // `cycle` register: it runs on clk67 and is resynchronised to clk16, so
    // cycle[3] -- the slot in which the controller does its work -- comes round
    // once per clk16 period.  Everything the model does happens in that slot,
    // which is what makes the ack-to-data gap one clk16 cycle rather than
    // instant.
    reg [1:0] ph;
    reg       clk16_r;
    always @(posedge clk67) begin
        if (!resetn) begin
            ph      <= 2'd0;
            clk16_r <= 1'b0;
        end else begin
            clk16_r <= clk16;
            if (clk16 & ~clk16_r) ph <= 2'd2;
            else                  ph <= ph + 2'd1;
        end
    end
    wire slot = (ph == 2'd3);

    reg [22:1]  m_a;
    reg [1:0]   m_ds;
    reg [15:0]  m_din;
    reg         m_we;
    reg         m_ack;
    assign mem_req_ack = m_ack;

    // A read is published in the slot *after* the one that acknowledged it.
    reg         rd_v;
    reg [15:0]  rd_word;
    reg         rd_hi;

    // `sdram_gba` addresses cart RAM with `rv_addr[17:1]` -- 128 KB as
    // halfwords -- so the model must index the same 16 bits, not the whole
    // 22-bit bus.  Using [22:2] here indexes far outside the array and every
    // read comes back x, which is what the first version of this model did.
    wire [15:0] m_word = m_a[17:2];
    wire        m_hi   = m_a[1];

    always @(posedge clk67) begin : model
        if (!resetn) begin
            m_ack    <= 1'b0;
            rd_v     <= 1'b0;
            rd_word  <= 21'd0;
            rd_hi    <= 1'b0;
            mem_dout <= 16'd0;
        end else if (slot) begin
            // 1. publish the read accepted in the previous slot
            if (rd_v) begin
                mem_dout <= rd_hi ? xmem[rd_word][31:16] : xmem[rd_word][15:0];
                rd_v     <= 1'b0;
            end

            // 2. accept a request presented now.  Writes land at acceptance,
            //    which is what `sdram_gba` does; reads are queued for the next
            //    slot.
            if (mem_req != mem_req_ack) begin
                if (mem_we) begin
                    if (mem_ds[0]) xmem[mem_addr[17:2]][(mem_addr[1]?16:0) +: 8]     <= mem_din[7:0];
                    if (mem_ds[1]) xmem[mem_addr[17:2]][(mem_addr[1]?16:0) + 8 +: 8] <= mem_din[15:8];
                    rd_v <= 1'b0;
                end else begin
                    rd_v    <= 1'b1;
                    rd_word <= mem_addr[17:2];
                    rd_hi   <= mem_addr[1];
                end
                m_a   <= mem_addr;
                m_ds  <= mem_ds;
                m_din <= mem_din;
                m_we  <= mem_we;
                m_ack <= mem_req;
            end
        end
    end

    // EEPROM model.  Port B of `mem_eeprom` is a clk16 memory -- `gba_memory`
    // runs on clk16 and passes its own clock down -- so this must be clk16, not
    // clk67.  Registered read, write when wreb, matching `gba_eeprom`.
    //
    // The store has two views and this models both, because modelling only one
    // is how a byte-order defect went unnoticed.  `emem` holds the bytes as the
    // CARTRIDGE sees them -- port A, serial, a byte's most significant bit first,
    // so the first bit of byte n lands at bit address 8n.  Port B, the view the
    // adapter uses, maps bit k of byte n to bit address 8n+k, which makes bit
    // address 8n the byte's LEAST significant bit.  The two conventions are
    // therefore bit-reversed with respect to one another, and a port-B byte is
    // the reversal of the cartridge-visible byte.
    //
    // That reversal is not this testbench's invention: measured on hardware
    // 2026-11-16 against mGBA, the board's port-B window equalled the bit
    // reversal of the emulator's save at all 1504 positions where both held
    // data (BRD-114).  `rv_sdram_adapter` converts at the host boundary, so the
    // bytes above this model are in cartridge order.  With this model the
    // assertions below check the property that actually matters and would fail
    // if the adapter stopped converting.
    function [7:0] rev8;
        input [7:0] b;
        begin
            rev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
        end
    endfunction

    always @(posedge clk16) begin
        if (eeprom_wr) emem[eeprom_addr] <= rev8(eeprom_wdata);
        eeprom_rdata <= rev8(emem[eeprom_addr]);
    end

    // ------------------------------------------------------------- checking
    integer errors = 0;
    integer i;
    integer refused;
    reg [7:0] got [0:127];
    reg [7:0] want;

    function automatic [7:0] pat(input integer a);
        pat = (a * 31 + 7) & 8'hFF;
    endfunction

    function automatic [7:0] rpat(input integer a);
        rpat = ((a * 31 + 7) & 8'hFF) ^ 8'hC3;
    endfunction

    task automatic fail(input [255:0] what, input integer idx,
                        input [7:0] g, input [7:0] w);
        begin
            if (errors < 12)
                $display("FAIL %0s [%0d] got %02x want %02x", what, idx, g, w);
            errors = errors + 1;
        end
    endtask

    // One 128-byte dump.  The consumer takes a byte every other clk16 edge,
    // which is far slower than the engine can produce them, so the FIFO fills
    // and the engine throttles -- exactly what the real UART does.
    //
    // Every drive here happens on a negedge and every sample on a posedge.  The
    // first version drove and cleared in the same time step as the sampling
    // edge, and iverilog ran the clearing statement first, so `start` was never
    // seen at all and the dump hung with the bus idle.  Half a cycle of
    // separation makes the drive unambiguous.
    task automatic dump_chunk(input [22:0] addr);
        integer n;
        begin
            while (busy) @(posedge clk16);
            @(negedge clk16);
            start = 1; start_we = 0; start_addr = addr;
            @(negedge clk16);
            start = 0;
            n = 0;
            while (n < 128) begin
                while (!d_valid) @(posedge clk16);
                got[n] = d_byte;          // sample in the cycle it is offered
                n = n + 1;
                @(negedge clk16);
                d_ready = 1;
                @(negedge clk16);
                d_ready = 0;
            end
            while (busy) @(posedge clk16);
        end
    endtask

    // Push one byte into the restore pipe.
    task automatic push_byte(input [7:0] b);
        begin
            while (!w_ready) @(posedge clk16);
            @(negedge clk16);
            w_byte  = b;
            w_valid = 1;
            @(negedge clk16);
            w_valid = 0;
        end
    endtask

    task automatic restore_chunk(input [22:0] addr);
        integer n;
        begin
            while (busy) @(posedge clk16);
            @(negedge clk16);
            start = 1; start_we = 1; start_addr = addr;
            @(negedge clk16);
            start = 0;
            for (n = 0; n < 128; n = n + 1)
                push_byte(rpat(addr + n));
            while (busy) @(posedge clk16);
        end
    endtask

    // A restore chunk that stops short, the way a truncated frame or a byte the
    // link lost would.  The engine must report it and must not wedge: without
    // the stall bound it waits for a fourth byte that never comes, `busy` never
    // falls, and every later save command is stuck behind it.
    //
    // Overrun -- a host outrunning the FIFO -- is not modelled here because it
    // cannot happen at this link's rate.  The UART delivers a byte every ~84
    // clk16 cycles; the engine drains one per ~2, so a 16-deep FIFO is roughly
    // forty times over-provisioned.  The overflow detection exists for a host
    // that violates the protocol, not for the field condition.
    task automatic restore_truncated(input [22:0] addr, output integer refused);
        integer n;
        begin
            while (busy) @(posedge clk16);
            @(negedge clk16);
            start = 1; start_we = 1; start_addr = addr;
            @(negedge clk16);
            start = 0;
            refused = 0;
            for (n = 0; n < 64; n = n + 1) begin
                @(negedge clk16);
                w_byte  = 8'hA5;
                w_valid = 1;
                @(negedge clk16);
                w_valid = 0;
                if (!w_ready) refused = refused + 1;
            end
            // and then the host stops, mid-chunk
            while (busy) @(posedge clk16);
        end
    endtask

    // Compare `got` against the flash/SRAM image starting at byte offset `off`.
    task automatic check_mem(input [255:0] what, input integer off);
        integer k;
        begin
            for (k = 0; k < 128; k = k + 1) begin
                want = xmem[(off + k) / 4][((off + k) % 4) * 8 +: 8];
                if (got[k] !== want) fail(what, k, got[k], want);
            end
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_save.vcd");
            $dumpvars(0, tb_save);
        end

        for (i = 0; i < 32768; i = i + 1) xmem[i] = 32'd0;
        // Byte image so distinctive that an off-by-one word or an endian slip
        // cannot look like a pass.
        for (i = 0; i < 131072; i = i + 1)
            xmem[i/4][(i%4)*8 +: 8] = (i * 31 + 7) & 8'hFF;
        for (i = 0; i < 8192; i = i + 1) emem[i] = (i * 13 + 5) & 8'hFF;

        resetn = 0;
        repeat (8) @(posedge clk16);
        resetn = 1;
        repeat (8) @(posedge clk16);

        // ---- dumps at three addresses inside the first 64 KB of cart RAM
        dump_chunk(23'h700000);  check_mem("dump 0x700000", 0);
        dump_chunk(23'h700080);  check_mem("dump 0x700080", 128);
        dump_chunk(23'h701F80);  check_mem("dump 0x701F80", 16'h1f80);

        // ---- the flash bank bit is address bit 16: 0x710000 is the second
        // 64 KB half, so it must read the image at byte offset 0x10000.
        dump_chunk(23'h710000);  check_mem("dump 0x710000 bank 1", 17'h10000);

        // ---- restore then read back
        restore_chunk(23'h700200);
        for (i = 0; i < 128; i = i + 1) begin
            want = rpat(16'h200 + i);
            if (xmem[(16'h200+i)/4][((16'h200+i)%4)*8 +: 8] !== want)
                fail("restore landed 0x700200", i,
                     xmem[(16'h200+i)/4][((16'h200+i)%4)*8 +: 8], want);
        end
        dump_chunk(23'h700200);  check_mem("read back 0x700200", 16'h200);
        dump_chunk(23'h700100);  check_mem("neighbour untouched", 16'h100);

        // ---- EEPROM path.  With config_backup_type == 4 the adapter sends the
        // same window to the eeprom port, so a dump of 0x700000 reads the
        // first 128 bytes of the 8 KB EEPROM image.
        config_backup_type = 3'd4;
        repeat (8) @(posedge clk16);
        dump_chunk(23'h700000);
        $display("  eeprom: 128 bytes dumped through the adapter");
        for (i = 0; i < 128; i = i + 1)
            if (got[i] !== emem[i]) fail("eeprom dump", i, got[i], emem[i]);

        restore_chunk(23'h700040);
        for (i = 0; i < 128; i = i + 1) begin
            want = rpat(16'h40 + i);
            if (emem[16'h40+i] !== want)
                fail("eeprom restore", i, emem[16'h40+i], want);
        end
        dump_chunk(23'h700040);
        for (i = 0; i < 128; i = i + 1)
            if (got[i] !== emem[16'h40+i]) fail("eeprom readback", i, got[i], emem[16'h40+i]);

        // ---- back to the flash window: the SRAM image must be unharmed by the
        // EEPROM traffic, and the restored chunk must still be there.
        config_backup_type = 3'd3;
        repeat (8) @(posedge clk16);
        dump_chunk(23'h700200);  check_mem("xmem survives eeprom mode", 16'h200);

        // ---- truncated-chunk reporting.  A chunk that stops short must raise
        // `err`, so the host refuses it instead of recording a save it did not
        // write.  Silence here would be the worst outcome this feature can
        // have: a save that claims success and is wrong.
        config_backup_type = 3'd3;
        repeat (4) @(posedge clk16);
        restore_truncated(23'h700300, refused);
        if (err !== 1'b1)
            fail("truncated chunk not reported", 0, err, 1'b1);
        $display("  truncated chunk: err=%b", err);

        // A fresh transfer must clear it again, or one bad chunk would condemn
        // every later one.
        restore_chunk(23'h700380);
        if (err !== 1'b0)
            fail("err not cleared by the next transfer", 0, err, 1'b0);
        dump_chunk(23'h700380);
        for (i = 0; i < 128; i = i + 1) begin
            want = rpat(16'h380 + i);
            if (got[i] !== want) fail("post-overrun restore", i, got[i], want);
        end

        if (errors == 0)
            $display("RESULT: PASS - save engine and adapter agree with the memory model");
        else
            $display("RESULT: FAIL - %0d mismatched bytes", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("RESULT: FAIL - timeout");
        $finish;
    end

endmodule

`default_nettype wire
