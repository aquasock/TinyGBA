// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps

// Boot-screen bench: what does gba2hdmi draw before a cartridge is running, and
// what surrounds the picture once one is?  Adapted from TinySNES
// `tools/tests/bootscreen_tb.sv` (same author, GPL-3.0-only), which checks the
// same boot screen in that core, so the two are held to one definition.
//
// The module's own registered colour (`dut.rgb`) is captured against the stub
// raster's own position (`dut.cx`, `dut.cy`), so the bench knows exactly which
// pixel each colour belongs to.  Everything between the boot-screen decision
// and the serialiser is the real code; only the serialiser is stubbed.
//
// Two phases:
//   rom_loaded = 0  -> eight equal vertical colour bars across the active raster
//   rom_loaded = 1  -> bars gone, and black either side of the 1080-wide picture
//
//   tools/video/run_bootscreen_tb.sh

module bootscreen_tb;

    localparam integer TOTALW = 1650;
    localparam integer TOTALH = 750;
    localparam integer ROW    = 400;      // a row well inside the active area

    // white, yellow, cyan, green, magenta, red, blue, black; on 0xC0, off 0x10.
    localparam [23:0] BAR0 = 24'hC0C0C0;
    localparam [23:0] BAR1 = 24'hC0C010;
    localparam [23:0] BAR2 = 24'h10C0C0;
    localparam [23:0] BAR3 = 24'h10C010;
    localparam [23:0] BAR4 = 24'hC010C0;
    localparam [23:0] BAR5 = 24'hC01010;
    localparam [23:0] BAR6 = 24'h1010C0;
    localparam [23:0] BAR7 = 24'h101010;

    // The GBA picture's columns, XSTART..XSTOP-1 in gba2hdmi: 1080 wide, centred.
    localparam integer PIC_X0 = (1280 - 1080) / 2;
    localparam integer PIC_X1 = (1280 + 1080) / 2;

    reg clk_pixel  = 0;
    reg clk_5x     = 0;
    reg clk        = 0;
    reg clk27      = 0;
    reg resetn     = 0;
    reg rom_loaded = 0;

    always #3  clk_pixel = ~clk_pixel;
    always #1  clk_5x    = ~clk_5x;
    always #10 clk       = ~clk;
    always #18 clk27     = ~clk27;

    wire [6:0]  tr_sel;
    wire [10:0] ovl_x;
    wire [9:0]  ovl_y;
    wire tmds_clk_p, tmds_clk_n;
    wire [2:0] tmds_d_p, tmds_d_n;

    gba2hdmi dut (
        .clk(clk), .clk27(clk27), .resetn(resetn),
        .clk_pixel(clk_pixel), .clk_pixel_x5(clk_5x),
        .dbg_bits(16'h0000), .dbg_done(1'b0),
        .tr_sel(tr_sel), .tr_word(32'h0), .tr_valid(16'h0),
        .pixel_data(18'h0), .pixel_x(8'h0), .pixel_y(8'h0), .pixel_we(1'b0),
        .sound_left(16'h0), .sound_right(16'h0),
        .overlay(1'b0), .overlay_x(ovl_x), .overlay_y(ovl_y), .overlay_color(16'h0),
        .desk_on(1'b0), .desk_wr_tog(1'b0), .desk_wr_addr(12'd0), .desk_wr_data(37'd0),
        .rom_loaded(rom_loaded),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p),
        .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // ------------------------------------------------------------ capture
    // `rgb` is registered from the position the raster held one clock earlier,
    // so that position is delayed by one clock to pair with it.
    reg [23:0] line [0:TOTALW-1];
    reg [10:0] pcx = 0;
    reg [9:0]  pcy = 0;

    always @(posedge clk_pixel) begin
        pcx <= dut.cx;
        pcy <= dut.cy;
        if (pcy == ROW && pcx < TOTALW)
            line[pcx] <= dut.rgb;
    end

    // ------------------------------------------------------------ checking
    integer errors = 0;

    task check(input bit cond, input [8*72-1:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL  %0s", what);
            end else begin
                $display("ok    %0s", what);
            end
        end
    endtask

    integer x, runs, run_start, run_len, i, k, bad;
    reg [23:0] cur;
    reg [23:0] expect_bar [0:7];

    // Report the row as runs and check them: eight bars of one eighth of the
    // active width each, in the expected order.
    task analyse_bars;
        begin
            expect_bar[0] = BAR0; expect_bar[1] = BAR1;
            expect_bar[2] = BAR2; expect_bar[3] = BAR3;
            expect_bar[4] = BAR4; expect_bar[5] = BAR5;
            expect_bar[6] = BAR6; expect_bar[7] = BAR7;
            runs = 0;
            cur = line[0];
            run_start = 0;
            for (x = 1; x <= 1280; x = x + 1) begin
                if (x == 1280 || line[x] !== cur) begin
                    run_len = x - run_start;
                    $display("      bar %0d: x %0d..%0d  width %0d  colour %06h",
                             runs, run_start, x - 1, run_len, cur);
                    if (runs < 8) begin
                        check(cur === expect_bar[runs], "bar colour is the expected one");
                        check(run_len >= 158 && run_len <= 162,
                              "bar width is one eighth of active");
                    end
                    runs = runs + 1;
                    if (x < 1280) begin
                        cur = line[x];
                        run_start = x;
                    end
                end
            end
            check(runs == 8, "the row is exactly eight bars");
        end
    endtask

    initial begin
        for (k = 0; k < TOTALW; k = k + 1) line[k] = 24'hDEADBE;

        $display("bootscreen bench: gba2hdmi before and after a cartridge is running");

        // --- phase 1: nothing loaded -> bars
        resetn = 0; rom_loaded = 0;
        repeat (16) @(posedge clk_pixel);
        resetn = 1;
        repeat (TOTALW * (TOTALH + 4)) @(posedge clk_pixel);

        $display("  rom_loaded = 0:");
        analyse_bars();
        bad = 0;
        for (x = 0; x < 1280; x = x + 1)
            if (line[x] !== BAR0 && line[x] !== BAR1 && line[x] !== BAR2 &&
                line[x] !== BAR3 && line[x] !== BAR4 && line[x] !== BAR5 &&
                line[x] !== BAR6 && line[x] !== BAR7) bad = bad + 1;
        check(bad == 0, "every active pixel on the row is a bar colour");

        // --- phase 2: loaded -> no bars, black surround
        rom_loaded = 1;
        repeat (TOTALW * (TOTALH + 4)) @(posedge clk_pixel);

        $display("  rom_loaded = 1:");
        k = 0;
        for (i = 0; i < 1280; i = i + 1)
            if (line[i] === BAR0 || line[i] === BAR1 || line[i] === BAR2 ||
                line[i] === BAR3 || line[i] === BAR4 || line[i] === BAR5 ||
                line[i] === BAR6) k = k + 1;
        check(k == 0, "no colour bar survives once a cartridge is running");

        bad = 0;
        for (i = 0; i < PIC_X0; i = i + 1)
            if (line[i] !== 24'h000000) bad = bad + 1;
        for (i = PIC_X1 + 1; i < 1280; i = i + 1)
            if (line[i] !== 24'h000000) bad = bad + 1;
        if (bad == 0)
            $display("ok    surround is black on both sides of the picture");
        else begin
            errors = errors + 1;
            $display("FAIL  %0d surround pixels are not black (left %06h, right %06h)",
                     bad, line[20], line[1260]);
        end

        // --- phase 3: a reload drops gbaon again -> bars return
        rom_loaded = 0;
        repeat (TOTALW * (TOTALH + 4)) @(posedge clk_pixel);
        $display("  rom_loaded = 0 again (a reload):");
        check(line[80] === BAR0 && line[1200] === BAR7, "bars return while a cartridge reloads");

        $display("");
        if (errors == 0) $display("PASS  colour bars until a cartridge runs, black surround after");
        else             $display("FAIL  %0d check(s) failed", errors);
        $finish;
    end

endmodule
