// GBA video and sound to HDMI converter
// nand2mario, 2024.7

module gba2hdmi (
	input clk,      // clock
    input clk27,
	input resetn,
    input clk_pixel,    // TinyGBA: 74.25 MHz, divided in gbatang_top.sv
    input clk_pixel_x5, // TinyGBA: 371.25 MHz serialiser bit clock (was pll_74 clkout1)

    // TinyGBA diagnostics (fpga/gba/diag/).  Tied to zero in production builds.
    input [15:0] dbg_bits,
    input        dbg_done,

    // gba video signals
    input [17:0] pixel_data,    // RGB6
    input [7:0] pixel_x,
    input [7:0] pixel_y,
    input pixel_we,

    // audio input
    input [15:0] sound_left,
    input [15:0] sound_right,

    // overlay interface
    input overlay,
    output [10:0] overlay_x,
    output [9:0] overlay_y,
    input [15:0] overlay_color,

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

// include from tang_primer_25k/config.sv and tang_nano_20k/config.sv

localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;

localparam IDIV_SEL_X5 = 3;
localparam FBDIV_SEL_X5 = 54;
localparam ODIV_SEL_X5 = 2;
localparam DUTYDA_SEL_X5 = "1000";
localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 74250;

localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;

localparam POWERUPNS = 100000000.0;
localparam CLKPERNS = (1.0/CLKFRQ)*1000000.0;
localparam int POWERUPCYCLES = $rtoi($ceil( POWERUPNS/CLKPERNS ));

// TinyGBA: the pixel clock is an input here, generated in gbatang_top.sv from a
// single-output 371.25 MHz PLL and a CLKDIV.  The removed `pll_74` drove
// clkout0 = 74.25 MHz and clkout1 = 371.25 MHz, and under nextpnr the second
// output took the dedicated fast-clock lanes while the first was routed
// through tile-local hops, so the OSER10s had no usable PCLK/FCLK pair and the
// board produced no signal on three separate images (TinySNES TCL-006).  Both
// replacement cells are pinned in fpga/gba/tinygba.cst.
// Both clocks are now inputs from gbatang_top.sv: `hclk` (the CLKDIV'd pixel
// clock) and `hclk5` (the PLL's 371.25 MHz output).  The removed wrapper is
// `pll_74`, whose two outputs could not both reach usable lanes.

// video stuff
wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// BRAM frame buffer
//
logic [17:0] mem_portA_wdata;

localparam WIDTH=240, width=240;
localparam HEIGHT=160, height=160;
localparam COLOR_BITS=6;

localparam FB_DEPTH = WIDTH * HEIGHT;
localparam COLOR_WIDTH = COLOR_BITS * 3;
localparam FB_AWIDTH = $clog2(FB_DEPTH);
// reg [COLOR_WIDTH-1:0] mem [0:FB_DEPTH-1];
reg [FB_AWIDTH-1:0] mem_portA_addr;
reg mem_portA_we;

wire [FB_AWIDTH-1:0] mem_portB_addr;
reg [COLOR_WIDTH-1:0] mem_portB_rdata;

fb u_fb(
    .clka(clk), .clkb(clk_pixel), .reseta('b0), .resetb(1'b0), .cea('b1), .ceb('b1), 
    // port A write
    .ada(mem_portA_addr), .douta(), .ocea(1'b0), .wrea(mem_portA_we), .dina(mem_portA_wdata),
    // port B read
    .adb(mem_portB_addr), .doutb(mem_portB_rdata), .oceb(1'b1), .wreb('b0), .dinb('b0)
);

// 
// Data input and initial background loading
//
logic [8:0] r_scanline;
logic [8:0] r_cycle;
`ifdef TINYGBA_SDRAM_TEST
// TinyGBA: SDRAM occupancy readout.  Sixteen bars, one per pattern the probe
// tested: green means that pattern read back correctly, red means it did not.
// Bars 0-7 are the low die, bars 8-15 the high die, so a module with no die
// select shows eight green followed by eight red.  The band across the top is
// blue while the probe is still running and green once it has finished, which
// separates 'the probe has not run yet' from 'everything failed'.
reg [7:0] pt_x, pt_y;

function [17:0] pt_colour(input [7:0] x, input [7:0] y);
    if (y < 8'd8)
        pt_colour = dbg_done ? {6'h00, 6'h3f, 6'h00} : {6'h00, 6'h00, 6'h3f};
    else if (x < 8'd232)
        pt_colour = dbg_bits[x / 8'd15] ? {6'h00, 6'h3f, 6'h00} : {6'h3f, 6'h00, 6'h00};
    else
        pt_colour = {6'h20, 6'h20, 6'h20};
endfunction

always @(posedge clk) begin
    if (pt_x == 8'd239) begin
        pt_x <= 8'd0;
        pt_y <= (pt_y == 8'd159) ? 8'd0 : pt_y + 8'd1;
    end else begin
        pt_x <= pt_x + 8'd1;
    end
    mem_portA_we    <= 1'b1;
    mem_portA_addr  <= pt_y * 240 + pt_x;
    mem_portA_wdata <= pt_colour(pt_x, pt_y);
end
`elsif TINYGBA_CLKTEST
// TinyGBA: clock diagnostic readout, selected with -DTINYGBA_CLKTEST.  Same bar
// layout as the status readout (bar i is bit i, green = 1, red = 0), but `clk`
// is clk27 in this build, so the readout runs whether or not the GBA clocks do.
// Bit meanings are at the measurement block in gbatang_top.sv.
reg [7:0] ct_x, ct_y;

function [17:0] ct_colour(input [7:0] x, input [7:0] y);
    if (y < 8'd8)
        ct_colour = dbg_done ? {6'h00, 6'h3f, 6'h00} : {6'h00, 6'h00, 6'h3f};
    else if (x < 8'd232)
        ct_colour = dbg_bits[x / 8'd15] ? {6'h00, 6'h3f, 6'h00} : {6'h3f, 6'h00, 6'h00};
    else
        ct_colour = {6'h20, 6'h20, 6'h20};
endfunction

always @(posedge clk) begin
    if (ct_x == 8'd239) begin
        ct_x <= 8'd0;
        ct_y <= (ct_y == 8'd159) ? 8'd0 : ct_y + 8'd1;
    end else begin
        ct_x <= ct_x + 8'd1;
    end
    mem_portA_we    <= 1'b1;
    mem_portA_addr  <= ct_y * 240 + ct_x;
    mem_portA_wdata <= ct_colour(ct_x, ct_y);
end
`elsif TINYGBA_STATUS_TEST
// TinyGBA: sticky status readout, selected with -DTINYGBA_STATUS_TEST.  Sixteen
// bars, bit 0 on the left, green where the bit is set.  Bits 0..5 are sticky and
// never clear, so they answer "did this ever happen since reset"; bits 6..15 are
// rom_addr[27:18] live, so they say which region the CPU is fetching from now.
// The band across the top turns green once `gbaon` is high, which separates a
// machine still loading from one that is running and failing.  See the comment at
// the probe in gbatang_top.sv for the bit meanings.
reg [7:0] st_x, st_y;

function [17:0] st_colour(input [7:0] x, input [7:0] y);
    if (y < 8'd8)
        st_colour = dbg_done ? {6'h00, 6'h3f, 6'h00} : {6'h00, 6'h00, 6'h3f};
    // IDENTITY mapping: the leftmost bar is bit 0 and the rightmost is bit 15.
    // An earlier version reversed this so multi-bit values would read left to
    // right, and every decode taken through it was then read backwards -- a
    // real address came out bit-reversed and looked like a plausible wrong one.
    // Identity is duller and cannot be misread: bar i is bit i.
    else if (x < 8'd232)
        st_colour = dbg_bits[x / 8'd15] ? {6'h00, 6'h3f, 6'h00} : {6'h3f, 6'h00, 6'h00};
    else
        st_colour = {6'h20, 6'h20, 6'h20};
endfunction

always @(posedge clk) begin
    if (st_x == 8'd239) begin
        st_x <= 8'd0;
        st_y <= (st_y == 8'd159) ? 8'd0 : st_y + 8'd1;
    end else begin
        st_x <= st_x + 8'd1;
    end
    mem_portA_we    <= 1'b1;
    mem_portA_addr  <= st_y * 240 + st_x;
    mem_portA_wdata <= st_colour(st_x, st_y);
end
`elsif TINYGBA_PIXTEST
// TinyGBA: which GPU drawer holds the line, drawn as sixteen bands.
// Selected with TINYGBA_DEFINES=-DTINYGBA_PIXTEST.
//
// The raster is proven (BRD-017), and the bufg_pix_s3 load (core-log entry 23)
// found `drawstate` held in DRAWING, which only exits when every drawer's busy
// bit clears.  This frame names the drawer that does not finish.  It takes the
// framebuffer away from the GPU and sweeps its own raster over the whole
// 240x160 array, so the display path is proven by the field appearing at all and
// says nothing about the machine.  The band map is defined beside its registers
// in gbatang_top.sv; in short, bands 0..13 live, 14..15 sticky:
//
//   band  0..1   drawstate                 band 10  OBJ OAMFetch != IDLE
//   band  2..5   busy BG0..BG3 text        band 11  OBJ PIXELGen != WAITOAM
//   band  6..7   busy BG2/BG3 affine       band 12  DISPCNT OBJ enable
//   band  8      busy mode 3/4/5           band 13  CPU halt
//   band  9      busy OBJ                  band 14  CPU ever fetched the cart
//                                          band 15  gbaon ever high
//
// `pixel_data`, `pixel_x` and `pixel_y` are folded into the low bit of the blue
// channel rather than ignored.  Taking the framebuffer away from the GPU leaves
// them unconsumed, and the first build of this test did exactly that: synthesis
// pruned 2,509 flip-flops and 28 block RAMs out of the drawer's data path, so
// `pixel_we` would have been measured in a machine that no longer contained the
// logic which produces it.  A one-LSB tint is invisible on the picture and keeps
// every one of those bits live, which is what makes the answer mean anything.
wire px_tint = ^{pixel_data, pixel_x, pixel_y};

// Sixteen bands across the top, each 15 source pixels wide, showing dbg_bits[0..15]
// left to right.  White means set, black means clear, and the boundaries are at
// fixed x so a shifted or mirrored scan cannot be mistaken for a different read.
function [17:0] px_colour(input [7:0] x, input [7:0] y);
    if (y < 8'd16)
        px_colour = dbg_bits[x / 8'd15] ? {6'h3f, 6'h3f, 6'h3f} : {6'h00, 6'h00, 6'h00};
    else
        px_colour = {6'h20, 6'h20, {5'b10000, px_tint}};
endfunction

reg [7:0] px_x, px_y;
always @(posedge clk) begin
    if (px_x == 8'd239) begin
        px_x <= 8'd0;
        px_y <= (px_y == 8'd159) ? 8'd0 : px_y + 8'd1;
    end else begin
        px_x <= px_x + 8'd1;
    end
    mem_portA_we    <= 1'b1;
    mem_portA_addr  <= px_y * 240 + px_x;
    mem_portA_wdata <= px_colour(px_x, px_y);
end
`elsif TINYGBA_VIDEO_TEST
// TinyGBA: video-path proof, selected with TINYGBA_DEFINES=-DTINYGBA_VIDEO_TEST.
// Nothing in this port has produced a picture yet, and the SDRAM probe's answer
// is read off the screen, so the first hardware load has to establish the video
// chain on its own: the PLL and divider topology, the four clock placements in
// fpga/gba/tinygba.cst, the OSER10 serialiser path and the TMDS pair.  This
// writes eight vertical bars straight into the framebuffer, independent of the
// GPU, the CPU and the SDRAM, so a black screen means the video path is wrong
// and says nothing about the machine.
//
// The pattern is asymmetric on purpose, so a mirrored or rotated scan reads as
// such rather than as a different fault.  What it actually draws, left to
// right: red, green, blue, white, yellow, cyan, magenta, then grey from x=189
// to x=239 -- bar 7 and the 216..239 remainder both fall through to `default`,
// so the right-hand grey band is 51 px against a 27 px bar.  Over that sits a
// white 16x16 block at the top-left corner only.  A mirrored scan therefore
// shows the white marker at the top-RIGHT and the wide grey band on the LEFT;
// a rotated one shows the marker off the top edge.  (An earlier version of
// this comment claimed a red bar on the right edge; the code has never done
// that, and the expectation is now written from the code rather than beside
// it.)
reg [7:0] vt_x, vt_y;

function [17:0] vt_colour(input [7:0] x, input [7:0] y);
    reg [2:0] bar;
    if (x < 8'd16 && y < 8'd16) begin
        vt_colour = {6'h3f, 6'h3f, 6'h3f};      // top-left white marker
    end else begin
        bar = x / 8'd27;                        // 8 bars of 27 px = 216
        case (bar)
            3'd0: vt_colour = {6'h3f, 6'h00, 6'h00};   // red
            3'd1: vt_colour = {6'h00, 6'h3f, 6'h00};   // green
            3'd2: vt_colour = {6'h00, 6'h00, 6'h3f};   // blue
            3'd3: vt_colour = {6'h3f, 6'h3f, 6'h3f};   // white
            3'd4: vt_colour = {6'h3f, 6'h3f, 6'h00};   // yellow
            3'd5: vt_colour = {6'h00, 6'h3f, 6'h3f};   // cyan
            3'd6: vt_colour = {6'h3f, 6'h00, 6'h3f};   // magenta
            default: vt_colour = {6'h20, 6'h20, 6'h20}; // grey, and the 216-239 remainder
        endcase
    end
endfunction

always @(posedge clk) begin
    if (vt_x == 8'd239) begin
        vt_x <= 8'd0;
        vt_y <= (vt_y == 8'd159) ? 8'd0 : vt_y + 8'd1;
    end else begin
        vt_x <= vt_x + 8'd1;
    end
    mem_portA_we    <= 1'b1;
    mem_portA_addr  <= vt_y * 240 + vt_x;
    mem_portA_wdata <= vt_colour(vt_x, vt_y);
end
`else
always @(posedge clk) begin
    mem_portA_we <= pixel_we;
    mem_portA_addr <= pixel_y * 240 + pixel_x;
    mem_portA_wdata <= pixel_data;
end
`endif

// audio stuff
//    localparam AUDIO_RATE=32000;        // weird only 32K sampling rate works
//    localparam AUDIO_RATE=96000;
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    // TinyGBA: `audio_divider` is otherwise driven non-blockingly in this
    // always_ff, so the increment is written non-blockingly too; slang rejects
    // mixing the two forms and Gowin EDA tolerates it.  Behaviour is unchanged:
    // self-assignment reads the pre-edge value either way.
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider <= audio_divider + 1;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
always @(posedge clk_pixel) begin       // crossing clock domain
    audio_sample_word0[0] <= sound_left;
    audio_sample_word[0] <= audio_sample_word0[0];
    audio_sample_word0[1] <= sound_right;
    audio_sample_word[1] <= audio_sample_word0[1];
end

//
// Video
// Scale to 1080x720 for GBA video, 960x720 for overlay
//
reg [23:0] rgb;             // actual RGB output
reg active                  /* xsynthesis syn_keep=1 */;
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;
assign mem_portB_addr = yy * WIDTH + xx;
assign overlay_x = xx;
assign overlay_y = yy;
localparam XSTART = (1280 - 1080) / 2;   // 1080:720 = 3:2
localparam XSTOP = (1280 + 1080) / 2;
localparam XSTART_O = (1280 - 960) / 2;   // 960:720 = 4:3
localparam XSTOP_O = (1280 + 960) / 2;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
// xcnt and ycnt are fractional scaling counters.
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + (overlay ? 256 : width);
    ycnt_next = ycnt + (overlay ? 224 : height);

    active_t = 0;
    if (~overlay && cx == XSTART - 1 || overlay && cx == XSTART_O - 1) begin
        active_t = 1;
        active <= 1;
    end else if (~overlay && cx == XSTOP - 1 || overlay && cx == XSTOP_O - 1) begin
        active_t = 0;
        active <= 0;
    end

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (overlay) begin
            if (xcnt_next >= 960) begin
                xcnt <= xcnt_next - 960;
                xx <= xx + 1;
            end
        end else begin
            if (xcnt_next >= 1080) begin
                xcnt <= xcnt_next - 1080;
                xx <= xx + 1;
            end
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
            yy <= yy + 1;
        end
    end

    if (cx == 0) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

// calc rgb value to hdmi
always @(posedge clk_pixel) begin
    if (active) begin
        if (overlay)
            rgb <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            rgb <= {mem_portB_rdata[COLOR_BITS*2 +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
                    mem_portB_rdata[COLOR_BITS   +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
                    mem_portB_rdata[0            +: COLOR_BITS], {(8-COLOR_BITS){1'b0}}};    // RGB4 to RGB8
    end else
        rgb <= 24'h303030;
end

// HDMI output.
logic[2:0] tmds;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0) )

hdmi( .clk_pixel_x5(clk_pixel_x5), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .rgb(rgb), 
        .reset( 0 ),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( frameWidth ),
        .frame_height( frameHeight ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);


endmodule
