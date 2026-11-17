// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

// Blank-save-store bench: does gba_memory give a cartridge with no `.sav` an
// erased (all-ones) save store, without ever overwriting one that was restored?
//
// The real gba_memory is driven through its loader interface exactly as TinyTang
// drives it -- stage 1 streams the ROM a byte at a time, stage 3 sets the save
// type, the save engine may restore a `.sav`, then `loading` drops to 0 -- and its
// SDRAM port is answered by a word-addressed model with byte enables.  The model's
// save store is seeded with junk first, so "every word reads 0xFFFFFFFF" cannot
// pass by accident.
//
// Scenarios:
//   A  no restore    -> 32,768 words of 0xFFFFFFFF across both 64 KB banks, the
//                       machine held until the last one, the ROM bytes intact,
//                       on a flash512K cartridge whose controller would discard
//                       the writes if it were told the real type
//   B  restore seen  -> no fill write at all, released at once, store untouched
//   C  reload mid-fill -> the fill stops, the machine stays held, and the next
//                       load's fill runs again from the first word
//   D  slow SDRAM    -> the same as A with every acknowledgement three cycles late
//   E  the EEPROM's all-ones walk restarts at the start of every ROM load
//
//   tools/save/run_fill_tb.sh

module tb_fill;

    localparam integer WORDS = 32768;
    // tosdram() of the cart-RAM window, word address [25:2], bank 0 and bank 1.
    localparam [23:0] STORE0 = {9'b1000_0001_0, 15'd0};

    reg clk = 0;
    always #30 clk = ~clk;

    reg        resetn = 0;
    reg  [2:0] loading = 0;
    reg  [7:0] loader_data = 0;
    reg        loader_valid = 0;
    reg        host_save_wr = 0;

    wire [1:0]  sdram_port;
    wire [25:2] sdram_addr;
    wire [31:0] sdram_wdata;
    wire [31:0] sdram_rdata [1:3];
    wire        sdram_rd, sdram_wr;
    wire [3:0]  sdram_be;
    reg         sdram_ready = 0;
    wire        gbaon;
    wire [2:0]  config_backup_type;
    wire [2:0]  sdram_backup_type;

    assign sdram_rdata[1] = 32'h0;
    assign sdram_rdata[2] = 32'h0;
    assign sdram_rdata[3] = 32'h0;

    gba_memory dut (
        .clk(clk), .resetn(resetn), .ce(1'b1),
        .rom_en(1'b0), .rom_addr(32'h0), .thumb(1'b0),
        .ram_cen(1'b0), .ram_wen(1'b0), .ram_addr(32'h0), .ram_wdata(32'h0), .ram_be(4'h0),
        .dma_on(1'b0), .dma_addr(32'h0), .dma_wdata(32'h0), .dma_ena(1'b0), .dma_wr(1'b0),
        .dma_be(4'h0), .dma_eepromcount(17'h0),
        .gb_bus_dout(32'h0),
        .sdram_port(sdram_port), .sdram_addr(sdram_addr), .sdram_wdata(sdram_wdata),
        .sdram_rdata(sdram_rdata), .sdram_rd(sdram_rd), .sdram_wr(sdram_wr),
        .sdram_be(sdram_be), .sdram_ready(sdram_ready), .backup_written(1'b0),
        .eeprom_rd(1'b0), .eeprom_wr(4'h0), .eeprom_addr(13'h0), .eeprom_wdata(8'h0),
        .loading(loading), .loader_data(loader_data), .loader_valid(loader_valid),
        .gbaon(gbaon), .config_backup_type(config_backup_type),
        .cartram_dirty_clear(1'b0),
        .host_save_wr(host_save_wr),
        .sdram_backup_type(sdram_backup_type),
        .vram_lo_dout(32'h0), .vram_hi_dout(32'h0), .oamram_dout(32'h0),
        .palette_bg_dout(32'h0), .palette_oam_dout(32'h0)
    );

    // ------------------------------------------------------------ SDRAM model
    // A request is a one-cycle pulse of sdram_wr or sdram_rd; it is acknowledged
    // by a one-cycle sdram_ready `lat` edges later.  lat = 1 is the board's
    // timing (sdram_gba answers inside the issuing clk16 period).
    //
    // The model also does what sdram_gba does with a flash save type (1 or 2):
    // a write to the cart-RAM window (addr[25:16] == 10'h204) is a flash command,
    // not data, and is discarded.  It is fed `sdram_backup_type`, the type
    // gba_memory presents to the controller.  The first board run of the fill
    // found exactly this -- every fill write swallowed on a flash512K cartridge --
    // and a model without it had passed.
    reg [31:0] mem [bit [23:0]];
    integer swallowed = 0;
    integer lat = 1;
    integer pend = 0;
    integer fill_writes = 0, other_writes = 0, rom_writes = 0;

    always @(posedge clk) begin
        sdram_ready <= 0;
        if (pend > 0) begin
            pend = pend - 1;
            if (pend == 0) sdram_ready <= 1;
        end
        if (sdram_wr && (sdram_backup_type == 3'd1 || sdram_backup_type == 3'd2) &&
            sdram_addr[25:16] == 10'h204) begin
            swallowed = swallowed + 1;
        end else if (sdram_wr) begin
            reg [31:0] w;
            w = mem.exists(sdram_addr) ? mem[sdram_addr] : 32'h0;
            for (int b = 0; b < 4; b++)
                if (sdram_be[b]) w[b*8 +: 8] = sdram_wdata[b*8 +: 8];
            mem[sdram_addr] = w;
            if (sdram_addr[25:17] == 9'b1000_0001_0 && sdram_be == 4'b1111 &&
                sdram_wdata == 32'hFFFF_FFFF)
                fill_writes = fill_writes + 1;
            else if (sdram_addr[25] == 1'b0)
                rom_writes = rom_writes + 1;
            else
                other_writes = other_writes + 1;
        end
        if (sdram_wr | sdram_rd) pend = lat;
    end

    // ------------------------------------------------------------ helpers
    integer errors = 0;
    task check(input bit cond, input [8*80-1:0] what);
        if (!cond) begin errors++; $display("FAIL  %0s", what); end
        else             $display("ok    %0s", what);
    endtask

    task seed_store(input [7:0] v);
        for (int i = 0; i < 2*WORDS/2; i++) mem[STORE0 + i] = {4{v}};
    endtask

    function automatic int store_ff();
        int n = 0;
        for (int i = 0; i < WORDS; i++)
            if (mem.exists(STORE0 + i) && mem[STORE0 + i] == 32'hFFFF_FFFF) n++;
        return n;
    endfunction

    // One loader byte, as iosys presents it: a one-cycle valid, then enough idle
    // for the loader's three-cycle write (the link is far slower than this).
    task send(input [7:0] b);
        @(posedge clk) begin loader_data <= b; loader_valid <= 1; end
        @(posedge clk) loader_valid <= 0;
        repeat (10) @(posedge clk);
    endtask

    localparam integer ROMLEN = 64;
    function automatic [7:0] rom_byte(input int i); return (i * 37 + 11) & 8'hFF; endfunction

    task load_rom;
        @(posedge clk) loading <= 1;
        repeat (4) @(posedge clk);
        for (int i = 0; i < ROMLEN; i++) send(rom_byte(i));
        @(posedge clk) loading <= 3;
        repeat (4) @(posedge clk);
        send(8'd1);                         // save type flash512K
        send(8'd0); send(8'd0); send(8'd0);
    endtask

    task release_load;
        @(posedge clk) loading <= 0;
    endtask

    // Cycles from the release until gbaon rises (or the limit).
    integer held;
    task wait_on(input int limit);
        held = 0;
        while (!gbaon && held < limit) begin @(posedge clk); held++; end
    endtask

    function automatic int rom_ok();
        int n = 0;
        for (int i = 0; i < ROMLEN; i++) begin
            bit [23:0] a = {1'b0, 23'h0} | (i >> 2);   // tosdram(0x08000000+i) = i[24:2]
            if (mem.exists(a) && mem[a][(i & 3)*8 +: 8] == rom_byte(i)) n++;
        end
        return n;
    endfunction

    integer f0, e0;
    initial begin
        $display("tb_fill: blank save store for a cartridge with no .sav");
        repeat (5) @(posedge clk);
        resetn <= 1;
        repeat (5) @(posedge clk);

        // ---------------------------------------------------- A: no restore
        $display("A  no restore:");
        seed_store(8'h5A);
        f0 = fill_writes;
        load_rom();
        release_load();
        wait_on(400000);
        $display("      held for %0d cycles after the release", held);
        check(gbaon, "machine released after the fill");
        check(fill_writes - f0 == WORDS, "exactly 32768 fill writes");
        check(store_ff() == WORDS, "every word of both banks reads 0xFFFFFFFF");
        check(held >= WORDS, "machine held until the last fill write");
        check(rom_ok() == ROMLEN, "every ROM byte landed where the loader put it");
        check(swallowed == 0, "no fill write was taken as a flash command");
        check(sdram_backup_type == 3'd1, "the controller is told flash512K again after the fill");

        // ---------------------------------------------------- B: restore seen
        $display("B  restore seen:");
        seed_store(8'hC3);
        f0 = fill_writes;
        load_rom();
        @(posedge clk) host_save_wr <= 1;           // the engine's first write
        @(posedge clk) host_save_wr <= 0;
        repeat (20) @(posedge clk);
        release_load();
        wait_on(400000);
        $display("      held for %0d cycles after the release", held);
        check(gbaon, "machine released");
        check(held <= 4, "released at once, as before this change");
        repeat (100) @(posedge clk);
        check(fill_writes == f0, "no fill write when a save was restored");
        check(store_ff() == 0, "the restored store is untouched");

        // ---------------------------------------------------- C: reload mid-fill
        $display("C  reload during a fill:");
        seed_store(8'h3C);
        load_rom();
        release_load();
        repeat (2000) @(posedge clk);
        check(!gbaon, "machine still held during the fill");
        load_rom();                                  // a new load starts mid-fill
        f0 = fill_writes;
        repeat (200) @(posedge clk);
        check(fill_writes == f0, "the fill stops when a new load starts");
        check(!gbaon, "machine still held by the new load");
        seed_store(8'h3C);
        f0 = fill_writes;
        release_load();
        wait_on(400000);
        check(gbaon && fill_writes - f0 == WORDS && store_ff() == WORDS,
              "the next release fills the whole store again");

        // ---------------------------------------------------- D: slow SDRAM
        $display("D  acknowledgements three cycles late (fill only):");
        // The ROM stream relies on lat = 1 by design (the loader's fixed window),
        // so the late SDRAM is switched in only for the release.
        seed_store(8'h77);
        load_rom();
        lat = 3;
        f0 = fill_writes;
        release_load();
        wait_on(800000);
        lat = 1;
        check(gbaon && fill_writes - f0 == WORDS && store_ff() == WORDS,
              "a slow controller still gets every word, once");

        // ---------------------------------------------------- E: EEPROM walk
        $display("E  EEPROM all-ones walk restarts on a ROM load:");
        e0 = 0;
        @(posedge clk) loading <= 1;
        for (int i = 0; i < 8; i++) begin
            @(posedge clk);
            if (dut.eeprom_reinit) e0++;
        end
        check(e0 == 1, "one restart pulse at the start of the ROM load");
        check(dut.eeprom.state == 4'd0, "the EEPROM is in its INIT walk");
        @(posedge clk) loading <= 0;
        repeat (10) @(posedge clk);

        $display("");
        if (errors == 0) $display("PASS  blank store for no .sav, restored stores untouched");
        else             $display("FAIL  %0d check(s) failed", errors);
        $finish;
    end

endmodule
