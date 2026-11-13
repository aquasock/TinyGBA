// GBA for Tang FPGA
// nand2mario, 2024.7

// uncomment this to use test rom instead of iosys menu system
//`define TEST_LOADER

`ifndef CONFIG_H
// TinyGBA: slang rejects the `error directive ("unknown macro or compiler
// directive"), which Gowin EDA tolerates.  The guard is kept as a comment.
// `error("config.v has to be processed before gbatang_top.sv")
`endif

module gbatang_top (

`ifndef VERILATOR
    input sysclk,                   // 50Mhz

    // MicroSD
    // output sd_clk,
    // inout  sd_cmd,                  // MOSI
    // input  sd_dat0,                 // MISO
    // output sd_dat1,
    // output sd_dat2,
    // output sd_dat3,

    // SPI flash
    // output flash_spi_cs_n,          // chip select
    // input flash_spi_miso,           // master in slave out
    // output flash_spi_mosi,          // mster out slave in
    // output flash_spi_clk,           // spi clock
    // output flash_spi_wp_n,          // write protect
    // output flash_spi_hold_n,        // hold operations

    // dualshock controller on pmod0
    output ds_clk,
    input ds_miso,
    output ds_mosi,
    output ds_cs,

    // USB1 and USB2
    inout usb1_dp,
    inout usb1_dn,
    inout usb2_dp,
    inout usb2_dn,

    // SDRAM
    output O_sdram_clk,
    output O_sdram_cs_n,            // chip select
    output O_sdram_cas_n,           // columns address select
    output O_sdram_ras_n,           // row address select
    output O_sdram_wen_n,           // write enable
    inout [15:0] IO_sdram_dq,       // 16 bit bidirectional data bus
    output [12:0] O_sdram_addr,     // 13 bit multiplexed address bus
    output [1:0] O_sdram_dqm,       // 
    output [1:0] O_sdram_ba,        // 4 banks

`ifdef DDR3_FRAMEBUFFER
    // DDR3 interface
    output [14:0] ddr_addr,
    output [2:0] ddr_bank,
    output ddr_cs,
    output ddr_ras,
    output ddr_cas,
    output ddr_we,
    output ddr_ck,
    output ddr_ck_n,
    output ddr_cke,
    output ddr_odt,
    output ddr_reset_n,
    output [1:0] ddr_dm,
    inout [15:0] ddr_dq,
    inout [1:0] ddr_dqs,
    inout [1:0] ddr_dqs_n,
`endif

    // UART
    input UART_RXD,
    output UART_TXD,    
`else           // Ports for Verilator
    input clk16,
    input clk50,
    input clk67,        // 4x clk16, used only when TINYGBA_SDRAM_RTL simulates
                        // the real controller; sdram_sim needs no such clock
    input [11:0] joy_btns,
    output gba_on,

    input [2:0] loading,            // 0: gba on, 1: loading rom, 2: loading cartram, 3: set up flash backup
    input [7:0] loader_do,
    input loader_do_valid,
`endif

    output reg [7:0] led,           // debug leds on pmod1
    input s0,
    input s1,

    // HDMI output
    output       tmds_clk_n,
    output       tmds_clk_p,
    output [2:0] tmds_d_n,
    output [2:0] tmds_d_p    
);

`include "pproc_bus_gba.sv"

// ------------------------------------------------------------------ diagnostics
// The GPU timing generator's internal taps are compiled only when asked for, and
// the switch has to be resolved here rather than beside the overlay logic far
// below, because `ifdef is read in order: the tap declarations come first and a
// define written after them has no effect.  Two diagnostic builds need them.
// TINYGBA_STATUS_TEST draws the sixteen-bit probe word; TINYGBA_PIXTEST draws
// the drawer's sixteen bands.
`ifdef TINYGBA_STATUS_TEST
  `define TINYGBA_GPU_TAPS
`endif
`ifdef TINYGBA_PIXTEST
  `define TINYGBA_GPU_TAPS
`endif
// TINYGBA_FETCHTRACE draws the GPU's live DISPCNT fields on its status page, so
// that a bus write is compared against the register rather than assumed to land.
`ifdef TINYGBA_FETCHTRACE
  `define TINYGBA_GPU_TAPS
`endif

// Clocking
`ifndef VERILATOR
wire clk27;         // intermediate 27Mhz clock for HDMI
wire clk12;         // for usb
// wire clk105;
// OSC #(.FREQ_DIV(2)) osc (.OSCOUT(clk105));
// pll_27 pll27(.clkin(clk105), .clkout0(clk27));
pll_27 pll27(.clkin(sysclk), .clkout0(clk27));

wire clk16;         // main clock: 16.7Mhz GBA CPU clock
wire clk50;         // ppu clock:  3 x 16.7Mhz
wire clk67, clk67_p;// ram clock:  67.2Mhz
wire hclk;          // 74.25Mhz hdmi 720p pixel clock
// TinyGBA: clk50, clk67 and clk16 all come from pll16 on PLL_L[0], one VCO,
// as upstream's pll_33 made them.  GBATang crosses between these clocks with
// no synchronisers and depends on their fixed phase; two PLLs on one
// reference are frequency-locked but come up at a different relative phase on
// every configuration load (core-log entry 23).  A PLL output reaches the
// global clock spine only through a clock-plane wire, and only CLKOUT0 and
// CLKOUT2 have one, so the two big clocks take those -- clk50 on CLKOUT0,
// clk16 on CLKOUT2 -- and clk67 takes CLKOUT1 on general routing.  See
// fpga/gba/src/pll/pll_16.v and .ai/core-reference.md TCL-001.
wire pll16_lock;
pll_16 pll16(.clkin(clk27), .clkout0(clk50), .clkout1(clk67), .clkout2(clk16),
             .clkout3(clk67_p), .lock(pll16_lock));
assign O_sdram_clk = clk67_p;

// TinyGBA: HDMI clocks.  One output on the PLL and a CLKDIV for the pixel
// clock, both pinned in fpga/gba/tinygba.cst, replacing the removed `pll_74`
// two-output wrapper (see src/gba2hdmi.sv for why).
wire hclk5;         // 371.25Mhz hdmi serialiser bit clock
gowin_pll_hdmi pll_hdmi (.clkout(hclk5), .clkin(clk27));

wire [2:0]  loading;
wire        loader_do_valid;
wire [7:0]  loader_do;
`endif

reg resetn = 0;

`ifndef VERILATOR
`ifdef TINYGBA_CLKTEST
// TinyGBA clock diagnostic: release the pixel-clock divider from clk27, so the
// HDMI output comes up even when clk16, and with it `resetn`, never runs.
reg [7:0] hdmi_rst_cnt = 8'd0;
reg       hdmi_resetn  = 1'b0;
always @(posedge clk27)
    if (&hdmi_rst_cnt) hdmi_resetn  <= 1'b1;
    else               hdmi_rst_cnt <= hdmi_rst_cnt + 1'b1;
`endif
// TinyGBA: the pixel clock, divided from the 5x serialiser clock.  `div5` is
// pinned to RIGHTSIDE[4] in fpga/gba/tinygba.cst; left to the placer it lands in
// block 0, from where the pixel clock does not route to the OSER10s.
CLKDIV #(.DIV_MODE("5")) div5 (
    .CLKOUT(hclk),              // 74.25Mhz
    .HCLKIN(hclk5),
`ifdef TINYGBA_CLKTEST
    .RESETN(hdmi_resetn),
`else
    .RESETN(resetn),
`endif
    .CALIB(1'b0)
);
`endif
wire gbaon_mem;     // what the loader actually drove (see the override below)
// `gbaon` itself is declared by the override below:
// this is resetn signal for everything gba except memory (needed by iosys)

// TinyGBA diagnostic override.  `gbaon` is the reset for the CPU and for the GPU
// timing generator, and on the board the generator reports `gpu_released=1`,
// `left_visible=0`, `cycles_100=1` -- a counter that got past 100 and a state
// machine that never left VISIBLE.  That pair is what a generator held in reset
// looks like once you know `cycles_reg` is not cleared by reset (fixed in
// gba_gpu_timing.v this cycle), so the leading hypothesis is that the loader's
// release is not being sustained rather than that the raster cannot count.
//
// Defining TINYGBA_GBAON_ALWAYS removes the hypothesis by removing its subject:
// the machine is released unconditionally, so any picture or absence of one is
// about the machine and not about the loader.  The cartridge still loads through
// the normal path; the BIOS boot animation runs while it streams, which is long
// enough for a 4 KiB image at 0.6 s.  This is a diagnostic configuration only --
// a shipping build leaves it undefined and keeps the loader-gated release.
`ifdef TINYGBA_GBAON_ALWAYS
wire gbaon = 1'b1;
`else
wire gbaon = gbaon_mem;
`endif

wire cartram_dirty_clear;
wire cartram_dirty;

wire [31:0] core_config;

/* verilator public_on */

// CPU bus signals
wire [27:0] ram_addr, rom_addr;
wire [31:0] ram_wdata;
wire thumb;         // whether next rom load is 16-bit
wire ram_cen, ram_wen, rom_en;
wire [3:0] ram_be;  // byte enable
wire [31:0] ram_rdata, rom_data;
wire cpu_en;        // Memory access done and there's no DMA
wire halt;          // HALTCNT write halts CPU until interrupts

// DMA bus signals
wire [27:0] dma_addr;
wire [31:0] dma_wdata, dma_rdata;
wire dma_rnw;
wire dma_on, dma_bus_ena; //dma_bus_unread;
wire dma_bus_done;
wire [1:0] dma_bus_acc;

/* verilator public_off */

// GPU to DMA signals
wire hblank_trigger, vblank_trigger, videodma_start, videodma_stop;

// sound
wire [15:0] sound_out_left /* verilator public */, sound_out_right /* verilator public */;
wire [1:0] sound_dma_req;

// timers
wire timer0_tick, timer1_tick;

// interrupts
wire cpu_IRP;
wire IRP_VBlank, IRP_HBlank, IRP_LCDStat, IRP_Serial, IRP_Joypad;
wire [3:0] IRP_Timer, IRP_DMA;


////////////////////////////
// CPU
////////////////////////////

gba_cpu cpu (
    .clk(clk16), .rst(~gbaon), .cpu_en(cpu_en & ~halt), .cpu_restart(~gbaon), .fiq(1'b0), 
    .irq(cpu_IRP), .thumb(thumb),
    .ram_abort(1'b0), .ram_rdata(ram_rdata), .rom_abort(1'b0), .rom_data(rom_data),
    .ram_addr(ram_addr), .ram_cen(ram_cen), .ram_flag(ram_be), .ram_wdata(ram_wdata),
    .ram_wen(ram_wen),  .rom_addr(rom_addr), .rom_en(rom_en) ); 

`ifndef VERILATOR
reg [15:0] rstCnt = 16'hffff;
`else
reg [1:0] rstCnt = 2'b11;
`endif

always @(posedge clk16) begin           // reset logic
    if (rstCnt != 0) begin
        rstCnt <= rstCnt - 1;
    end else begin
    // end else if (~s0) begin
        if (~resetn)
            $display("gbatang_top: reset done");
        resetn = 1;
    end
end

wire [7:0] pixel_out_x /* verilator public */, pixel_out_y /* verilator public */;
wire [17:0] pixel_out_data /* verilator public */;
wire pixel_out_we /* verilator public */;

// Declared unconditionally: the GPU's DISPSTAT_debug output is connected in both
// the simulation build and the synthesis build, and an earlier version declared
// this inside the probe `ifdef`, which left the port connection referring to an
// implicitly-created net in every build without that define.
// (Note: a line beginning `// Verilator` is parsed as a pragma directive, so
// that word is kept out of the start of a comment.)
`ifdef TINYGBA_GPU_TAPS
wire [7:0]  gpu_dbg;        // GPU timing generator internals, see gba_gpu_timing.v
wire [1:0]  gpu_ev;         // GPU drawer line-start events, see gba_gpu.v
wire [9:0]  gpu_ds;         // GPU drawer state machine + busy vector, see gba_gpu.v
wire [6:0]  gpu_vf;         // GPU mode 3/4/5 fetch state, draw state, BG_Mode
wire [2:0]  gpu_ob;         // GPU OBJ drawer machines + DISPCNT OBJ enable
wire [6:0]  gpu_dc;         // DISPCNT forced blank + BG enables, BLDCNT effect
`endif
wire [31:0] dispstat_dbg;   // {REG_VCOUNT[23:16], V_Count_Setting, 2'b0,
                            //  IRQ enables, flags}: [0] VBlank flag, [1] HBlank
                            //  flag, both set unconditionally on arrival.

`ifdef TINYGBA_SDRAM_TEST
// TinyGBA: the occupancy probe owns the SDRAM CPU port.  The memory controller
// keeps running but its requests go nowhere, which is harmless here: the probe
// writes nothing the loader needs, and the readout is drawn by gba2hdmi's own
// raster rather than by the machine.  See fpga/gba/diag/sdram_probe.v for why
// this is a diagnostic-only arrangement.
wire [25:2] probe_addr;
wire [31:0] probe_wdata;
wire [1:0]  probe_port;
wire        probe_rd, probe_wr;
wire [3:0]  probe_be;

sdram_probe probe (
    .clk(clk16), .resetn(resetn),
    .cpu_addr(probe_addr), .cpu_wdata(probe_wdata), .cpu_port(probe_port),
    .cpu_rd(probe_rd), .cpu_wr(probe_wr), .cpu_be(probe_be),
    .cpu_ready(cpu_mem_ready_raw), .cpu_rdata(cpu_mem_rdata),
    .result(dbg_bits), .done(dbg_done)
);

assign cpu_mem_addr  = probe_addr;
assign cpu_mem_wdata = probe_wdata;
assign cpu_mem_rd    = probe_rd;
assign cpu_mem_wr    = probe_wr;
assign cpu_mem_be    = probe_be;
assign cpu_mem_port  = probe_port;
`else
assign cpu_mem_addr  = mem_addr;
assign cpu_mem_wdata = mem_wdata;
assign cpu_mem_rd    = mem_rd;
assign cpu_mem_wr    = mem_wr;
assign cpu_mem_be    = mem_be;
assign cpu_mem_port  = mem_port;

`ifdef TINYGBA_STATUS_TEST
// TinyGBA: sticky status readout.  The machine has never drawn anything, and a
// black picture cannot say which of four quite different things failed, so this
// build latches whether each one has EVER happened since reset and draws the
// answer where the video path -- already proven -- can show it.  Every bit is
// latched on the first occurrence and never cleared, because a snapshot cannot
// tell "never happened" from "happened and finished"; TinySNES paid for that
// lesson twice, and one of its probes reported all-set because the bits were
// never armed against their own reset value.  Each bit is therefore held low
// while `resetn` is low, and only then allowed to set.
//
// The bit assignment is NOT written here.  It lives in one place,
// `fpga/gba/src/probe_bits.vh`, which `tools/probe_map.py` generates and which
// also generates the host decoder, so the RTL packing and the decoder cannot
// disagree.  Before a capture is decoded, run `tools/probe_map.py --list`.
//
// This comment used to restate the map by hand, and a later edit to the map left
// it behind.  A decode taken from the stale comment read bit 2 as "the SDRAM
// controller answered" when on the board it is `vblank_arrived`, and bit 4 as
// "the GPU drew a pixel" when it is the DISPSTAT V-Blank IRQ enable.  Both were
// reported as hardware results before the generated map was checked.  A prose
// copy of a generated table is a second source of truth and will drift; read the
// generator, not a comment.
//
// The status band turns green once `gbaon` is high, which separates "still
// loading" from "running and failing".
(* keep *) reg [5:0]  st_bits;
(* keep *) reg [2:0]  st_gpu;
(* keep *) reg [9:0]  st_region;
// Interrupt-path history.  The CPU halts on a HALTCNT write and `halt` only
// clears when some bit of IRPFlags is set, so a permanent halt means the
// interrupt never arrived.  These separate the possible reasons:
//   st_irq[0]  IRP_VBlank ever asserted
//   st_irq[1]  the GPU's VBlank IRQ enable was ever set (the CPU must write it)
//   st_irq[2]  cpu_IRP ever asserted
//   st_irq[3]  halt ever went low again after being seen high
(* keep *) reg [3:0]  st_irq;
(* keep *) reg [3:0]  st_halt_edges;
// Did the CPU ever WRITE the registers that could release the halt?
//
// The machine halts at the HALTCNT write and never wakes, and `halt` only clears
// when an IRPFlags bit sets, which needs a source the CPU has enabled.  These
// four say whether the writes that would do it ever happened at all, which
// separates "the BIOS halts before reaching them" from "it writes them and they
// do not take".  Addresses are offsets from 0x04000000, the same numbering
// HALTCNT.Adr uses (`28'h300`), so DISPSTAT is `28'h004`.
//   st_reg[0]  a write to 0x04000004 (DISPSTAT) occurred
//   st_reg[1]  ...and one of them carried din[3], the V-Blank IRQ enable
//   st_reg[2]  a write to 0x04000200 (IE) occurred
//   st_reg[3]  a write to 0x04000208 (IME) occurred
(* keep *) reg [3:0]  st_reg;
wire st_wr = gb_bus_ena & ~gb_bus_rnw;
wire st_wr_dispstat = st_wr & (gb_bus_adr == 28'h004);
(* keep *) reg [15:0] st_dbg;
wire       st_armed = resetn;

// Where the CPU stopped.  The sticky status bits say the CPU never reached the
// cartridge, but not where it went instead, and "halted in low memory" covers
// every address from the reset vector to the sound driver.  This latches the
// last address the CPU fetched before `halt` rose, which names the instruction
// that stalled the machine: a BIOS wait loop and a mis-executing reset path look
// identical on every other instrument built so far.
//
// The address is latched from `last_fetch`, not from `rom_addr` directly,
// because the store that writes HALTCNT reaches the interrupt module a cycle or
// two after the fetch that decoded it, and `rom_addr` has moved on by then.
(* keep *) reg [27:0] last_fetch;
(* keep *) reg [11:0] st_halt_word;      // rom_addr[13:2] at the last fetch before halt
(* keep *) reg        st_halt_valid;
(* keep *) reg        st_halt_r;
wire       st_halt_rise = halt & ~st_halt_r;

always @(posedge clk16) begin
    st_halt_r <= halt;
    if (~st_armed) begin
        last_fetch     <= 28'd0;
        st_halt_word   <= 12'd0;
        st_halt_valid  <= 1'b0;
    end else begin
        if (rom_en)
            last_fetch <= rom_addr;
        // Latch on the halt alone.  Requiring `rom_en` on the same cycle was
        // wrong: `halt` is a registered output of gba_interrupts and `rom_en` is
        // a per-cycle strobe, so the two practically never coincide and the
        // latch could never fire -- measured 2026-11-02, `st_halt_valid` stayed
        // low on hardware.  Instead capture the most recent fetch at the moment
        // halt rises, and keep refreshing it for as long as halt stays high so a
        // halt that persists ends up holding the last address the CPU asked for.
        if (st_halt_rise | halt) begin
            st_halt_word  <= last_fetch[13:2];
            st_halt_valid <= 1'b1;
        end
    end
end

always @(posedge clk16) begin
    if (~st_armed) begin
        st_bits       <= 6'b000000;
        st_gpu        <= 3'b000;
        st_region     <= 10'b0000000000;
        st_irq        <= 4'b0000;
        st_halt_edges <= 4'd0;
        st_reg        <= 4'b0000;
    end else begin
        if (st_wr_dispstat)                 st_reg[0] <= 1'b1;
        if (st_wr_dispstat & gb_bus_din[3]) st_reg[1] <= 1'b1;
        if (st_wr & (gb_bus_adr == 28'h200)) st_reg[2] <= 1'b1;
        if (st_wr & (gb_bus_adr == 28'h208)) st_reg[3] <= 1'b1;
        if (IRP_VBlank)          st_irq[0] <= 1'b1;
        if (dispstat_dbg[3])     st_irq[1] <= 1'b1;
        if (cpu_IRP)             st_irq[2] <= 1'b1;
        if (st_halt_valid & ~halt) st_irq[3] <= 1'b1;
        if (st_halt_rise) begin
            if (st_halt_edges != 4'hF) st_halt_edges <= st_halt_edges + 4'd1;
        end
        // Which 256 KB region the CPU has EVER fetched from, as a sticky OR.
        // A live view of these bits cannot answer the question: every BIOS
        // address is below 0x40000, so rom_addr[27:18] reads zero throughout a
        // correctly running BIOS and a stalled one alike, and the display only
        // samples one instant per pixel.  Sticky OR makes "did the CPU ever
        // reach the cartridge at 0x08000000" a fact that survives the frame.
        // Cartridge fetches set bit 25.  `st_region` is no longer on the probe
        // wire, so no bar number is named here: see `tools/probe_map.py --list`.
        st_region <= st_region | rom_addr[27:18];
        if (gbaon)                    st_bits[0] <= 1'b1;
        if (rom_en)                   st_bits[1] <= 1'b1;
        if (cpu_mem_ready)            st_bits[2] <= 1'b1;
        if (loader_do_valid)          st_bits[3] <= 1'b1;
        if (pixel_out_we)             st_bits[4] <= 1'b1;
        if (halt)                     st_bits[5] <= 1'b1;
        // GPU timing history, taken from DISPSTAT rather than from the interrupt
        // outputs.  `IRP_VBlank` and `IRP_HBlank` are gated by their IRQ-enable
        // bits, which only the CPU can set, so a CPU that never gets that far
        // guarantees they stay low and says nothing about the GPU.  The status
        // flags beside them are set unconditionally, so these three answer the
        // question the IRQ lines cannot: is the raster running at all?
        //   st_gpu[0]  a VBlank period has arrived
        //   st_gpu[1]  an HBlank period has arrived
        //   st_gpu[2]  the scanline counter has advanced past line 1
        if (dispstat_dbg[0])          st_gpu[0] <= 1'b1;
        if (dispstat_dbg[1])          st_gpu[1] <= 1'b1;
        if (|dispstat_dbg[23:16])     st_gpu[2] <= 1'b1;
    end
end

// clk67-domain observations.  On the board the machine reports `mem_ready = 0`
// -- the SDRAM controller never acknowledged a request -- while the loader
// accepted cartridge bytes and the CPU fetched.  That reading is real (both bits
// are driven flops in the netlist) but it has three quite different causes and
// the clk16-domain sticky bit cannot tell them apart:
//
//   a) `clk67` never reaches the controller's flip-flops at all, so nothing in
//      the controller runs.  This design has never clocked thousands of sinks on
//      this pip -- `clk67` sits on SPINE27/TOP2, recorded `partial` precisely
//      because only a probe's few hundred flops have ever been measured on it.
//   b) the controller runs but never acknowledges, e.g. it is stuck in its
//      200 microsecond initialisation.
//   c) the controller acknowledges correctly and nothing in the clk16 domain
//      ever samples it, because `cpu_ready` is high for one clk16 period and the
//      window can fall between two clk16 edges.
//
// `st_clk67_alive` separates (a) from the rest: it can only set if a flop
// clocked by clk67 ran at least twice.  `st_mem_ready_fast` separates (c) from
// (b): it is the same `cpu_mem_ready` signal latched in the domain that produces
// it, so a controller that acknowledges will set it regardless of whether the
// clk16 side ever sees the pulse.
//
// Both are latched by clk67 and read by the clk16 packer, so they pass through a
// two-flop synchroniser.  Sticky bits only ever rise, so a synchroniser is
// sufficient; there is no ordering to preserve between them.
(* keep *) reg st_clk67_alive;
(* keep *) reg st_mem_ready_fast;
reg [1:0] st_clk67_tog;
always @(posedge clk67) begin
    if (~resetn) begin
        st_clk67_tog      <= 2'b00;
        st_clk67_alive    <= 1'b0;
        st_mem_ready_fast <= 1'b0;
    end else begin
        st_clk67_tog <= st_clk67_tog + 2'd1;
        if (st_clk67_tog[1])     st_clk67_alive    <= 1'b1;
        // Samples the RAW net deliberately: this flop is clocked by clk67, the
        // domain that produces the strobe, so it must not take the clk16
        // synchroniser's output or it would introduce the very crossing it exists
        // to observe across.
        if (cpu_mem_ready_raw)   st_mem_ready_fast <= 1'b1;
    end
end

// GPU timing generator internals, latched.  `gpu_dbg` is produced on clk50 (the
// GPU's fclk) and is a level, not a pulse, but it is sampled here on every clk50
// edge so the ladder survives however briefly a rung is true.
// Did the loader's release stay released?  `gbaon` drives the GPU's reset, so a
// `gbaon` that falls again after rising would restart the GPU's cycle counter
// often enough that it passes 100 and never finishes a 1008-cycle line -- which
// is precisely the ladder the board shows.  One flop remembers that it was high,
// another latches the first time it goes back low.
(* keep *) reg st_gbaon_high, st_gbaon_fell;
always @(posedge clk16) begin
    if (~resetn) begin
        st_gbaon_high <= 1'b0;
        st_gbaon_fell <= 1'b0;
    end else begin
        if (gbaon)              st_gbaon_high <= 1'b1;
        else if (st_gbaon_high) st_gbaon_fell <= 1'b1;
    end
end

(* keep *) reg [3:0] st_gpu_step;
reg [3:0] st_gpu_step_sync;
always @(posedge clk50) begin
    if (~resetn) st_gpu_step <= 4'b0000;
    else         st_gpu_step <= st_gpu_step | gpu_dbg[3:0];
end
always @(posedge clk16) begin
    if (~resetn) st_gpu_step_sync <= 4'b0000;
    else         st_gpu_step_sync <= st_gpu_step;
end

(* keep *) reg [1:0] st_alive_sync, st_mrfast_sync;
always @(posedge clk16) begin
    if (~resetn) begin
        st_alive_sync  <= 2'b00;
        st_mrfast_sync <= 2'b00;
    end else begin
        st_alive_sync  <= {st_alive_sync[0],  st_clk67_alive};
        st_mrfast_sync <= {st_mrfast_sync[0], st_mem_ready_fast};
    end
end

// The display layout is NOT written here.  It is generated from one declarative
// field list by tools/probe_map.py, into probe_bits.vh beside this file, and the
// host-side decoder is generated from that same list.  Four consecutive cycles
// on the sibling SNES project mis-stated a field position and each produced a
// plausible number rather than an error; this project then made the same class
// of mistake three times in one session.  Generating both halves from one list
// makes a wrong ORDER impossible rather than merely unlikely, which a width
// check alone cannot do.
//
//   bar i is bit i, leftmost bar is bit 0
//   tools/probe_map.py --list       prints every field and its bit range
//   tools/probe_map.py --decode f   decodes a capture using the same list
//
// `TINYGBA_PROBE_ASSIGN` also carries an elaboration-time guard that measures
// `$bits` of the packing expression, so a field whose width changes stops the
// build here.
wire st_cart_seen = (st_region[9:6] != 4'b0000);   // rom_addr[27:24] non-zero
`include "probe_bits.vh"
always @(posedge clk16) begin
    `TINYGBA_PROBE_ASSIGN
end

assign dbg_bits = st_dbg;
assign dbg_done = gbaon;
`else
`ifdef TINYGBA_PIXTEST
// TinyGBA: what the BIOS has asked the display to show, drawn as sixteen bands
// across the top of the test field in gba2hdmi, white = 1.
//
// With unreset registers initialised to 0 (core-log entry 23, TCL-017) the drawer
// cycles IDLE/WAITHBLANK/MERGING, the CPU halts and wakes on vblank, and the
// field is a constant grey with no logo and no cart fetch (BRD-020).  This map
// asks whether the BIOS ever loaded palette, VRAM and OAM and what DISPCNT and
// BLDCNT hold, so a grey that is a blend or brightness setting can be told apart
// from a grey that is an empty palette or a display that was never enabled.
//
// Bands 0 to 10 are LIVE levels.  Each band is 15x16 source pixels written over
// about one GBA line, so a cycling signal shows as stripes and a solid band is a
// held level, not a frame-phase alias.
//
//   band  0  DISPCNT BG_Mode[0]        \
//   band  1  DISPCNT BG_Mode[1]         > the register the drawer decodes
//   band  2  DISPCNT BG_Mode[2]        /
//   band  3  DISPCNT Forced_Blank
//   band  4  DISPCNT Screen_Display_BG0
//   band  5  DISPCNT Screen_Display_BG1
//   band  6  DISPCNT Screen_Display_BG2
//   band  7  DISPCNT Screen_Display_BG3
//   band  8  BLDCNT Color_Special_Effect[0]  \  0 none 1 alpha
//   band  9  BLDCNT Color_Special_Effect[1]  /  2 brighten 3 darken
//   band 10  CPU `halt`
//
// Bands 11 to 15 are STICKY ever-true.  Bands 11 to 14 clear while the machine
// is held (`~gbaon`), so they report only the current cart load; band 15 clears
// only on board reset.
//
//   band 11  palette RAM written (BG or OBJ palette, CPU or DMA)
//   band 12  VRAM written        (either half)
//   band 13  OAM written
//   band 14  the CPU fetched from 0x08000000 or above (it reached the cart)
//   band 15  gbaon ever high              (control: the machine was released)
(* keep *) reg [10:0] pix_live;   // bands 0..10
(* keep *) reg        pix_on;     // band 15
(* keep *) reg [3:0]  pix_wr;     // clk16 side of bands 11..14, set further down
(* keep *) reg [3:0]  pix_wr50;   // bands 11..14
always @(posedge clk50) begin
    if (~resetn) begin
        pix_live <= 11'b0;
        pix_on   <= 1'b0;
        pix_wr50 <= 4'b0;
    end else begin
        pix_live[2:0]  <= gpu_vf[6:4];   // BG_Mode
        pix_live[9:3]  <= gpu_dc;        // Forced_Blank, BG0..3, BLDCNT effect
        pix_live[10]   <= halt;
        pix_wr50       <= pix_wr;
        if (gbaon)                     pix_on <= 1'b1;
    end
end
// Bit 15 is the leftmost, so band 0 lands in bit 0 and the order below reads left
// to right on screen.
assign dbg_bits = {pix_on, pix_wr50, pix_live};
assign dbg_done = 1'b0;
`else
`ifdef TINYGBA_CLKTEST
// TinyGBA clock diagnostic (core-log entry 23).  With clk50, clk67 and clk16
// moved onto one PLL, the board drew no HDMI sync at all, which is what a
// `resetn` that never rises looks like: its counter runs on clk16.  This
// measures every GBA clock from clk27, which feeds the HDMI PLL and is known
// good, and draws the result through a framebuffer writer that also runs on
// clk27, so nothing in the readout depends on a clock under test.
//
// Each clock drives a free-running /16 counter.  Its top bit is synchronised
// into clk27 and its rising edges counted over 2^20 clk27 cycles (38.836 ms).
// Expected counts: clk16 40,656; clk50 121,971; clk67 162,626.  "ok" is +/-2%.
//   bar 0  pll16 LOCK ever high          bar 1  pll16 LOCK now
//   bar 2  `resetn` now (the clk16 reset counter released)
//   bar 3  clk16 ever toggled            bar 4  clk16 frequency ok
//   bar 5  clk50 ever toggled            bar 6  clk50 frequency ok
//   bar 7  clk67 ever toggled            bar 8  clk67 frequency ok
//   bars 9..15  clk16 count[17:11], LSB at bar 9; 40,656 reads 19 (0010011)
// The top band is always green: it proves the readout itself is running.
reg [3:0] ck16_div = 4'd0, ck50_div = 4'd0, ck67_div = 4'd0;
always @(posedge clk16) ck16_div <= ck16_div + 1'b1;
always @(posedge clk50) ck50_div <= ck50_div + 1'b1;
always @(posedge clk67) ck67_div <= ck67_div + 1'b1;

reg [2:0]  ck_s16 = 3'd0, ck_s50 = 3'd0, ck_s67 = 3'd0;
reg [1:0]  ck_slock = 2'd0, ck_srst = 2'd0;
reg [19:0] ck_win = 20'd0;
reg [17:0] ck_n16 = 18'd0, ck_n50 = 18'd0, ck_n67 = 18'd0;
reg [17:0] ck_m16 = 18'd0, ck_m50 = 18'd0, ck_m67 = 18'd0;
reg        ck_alive16 = 1'b0, ck_alive50 = 1'b0, ck_alive67 = 1'b0, ck_lock_ever = 1'b0;
wire ck_e16 = ck_s16[1] & ~ck_s16[2];
wire ck_e50 = ck_s50[1] & ~ck_s50[2];
wire ck_e67 = ck_s67[1] & ~ck_s67[2];
always @(posedge clk27) begin
    ck_s16   <= {ck_s16[1:0], ck16_div[3]};
    ck_s50   <= {ck_s50[1:0], ck50_div[3]};
    ck_s67   <= {ck_s67[1:0], ck67_div[3]};
    ck_slock <= {ck_slock[0], pll16_lock};
    ck_srst  <= {ck_srst[0], resetn};
    ck_win   <= ck_win + 1'b1;
    if (&ck_win) begin
        ck_m16 <= ck_n16 + ck_e16;  ck_n16 <= 18'd0;
        ck_m50 <= ck_n50 + ck_e50;  ck_n50 <= 18'd0;
        ck_m67 <= ck_n67 + ck_e67;  ck_n67 <= 18'd0;
    end else begin
        ck_n16 <= ck_n16 + ck_e16;
        ck_n50 <= ck_n50 + ck_e50;
        ck_n67 <= ck_n67 + ck_e67;
    end
    if (ck_e16)      ck_alive16   <= 1'b1;
    if (ck_e50)      ck_alive50   <= 1'b1;
    if (ck_e67)      ck_alive67   <= 1'b1;
    if (ck_slock[1]) ck_lock_ever <= 1'b1;
end
wire ck_ok16 = (ck_m16 >= 18'd39843)  & (ck_m16 <= 18'd41469);
wire ck_ok50 = (ck_m50 >= 18'd119532) & (ck_m50 <= 18'd124410);
wire ck_ok67 = (ck_m67 >= 18'd159373) & (ck_m67 <= 18'd165879);
assign dbg_bits = {ck_m16[17:11], ck_ok67, ck_alive67, ck_ok50, ck_alive50,
                   ck_ok16, ck_alive16, ck_srst[1], ck_slock[1], ck_lock_ever};
assign dbg_done = 1'b1;
`else
assign dbg_bits      = 16'h0000;
assign dbg_done      = 1'b0;
`endif
`endif
`endif
`endif

// Fetch-trace readout port of gba2hdmi.  gba2hdmi drives `tr_sel` as
// {page[1:0], entry[2:0], word[1:0]} and draws `tr_word`; it is tied off
// outside TINYGBA_FETCHTRACE.  Pages 0 and 1 are the completed-cycle trace,
// page 2 the MMIO write ring, page 3 the status pages.  The pages above 1 are
// generated further down, after the `gb_bus_*` declarations.
wire [6:0]  tr_sel;
wire [31:0] tr_word;
wire [15:0] tr_valid;
`ifdef TINYGBA_STALLTRACE
// Stall-trace readout (layout v5), generated after the DMA block further down.
wire [31:0] stl_word;
wire [15:0] stl_valid;
wire [7:0]  stl_mem_state;                // gba_memory {dma_on_r, double_req, dma_sdram, 2'b00, state}
wire [31:0] stl_debug_dma;                // gba_dma debug_dma
`endif
`ifdef TINYGBA_FETCHTRACE
// TinyGBA: the first sixteen CPU memory cycles from the cartridge, drawn as
// words by gba2hdmi (BRD-022).  The official BIOS completes its intro and
// jumps to 0x08000000, but neither the test cart nor a retail cart reaches its
// first DISPCNT write.  The BIOS executes from block RAM, so the concurrent
// "instruction fetch from SDRAM plus data access" path of gba_memory, which
// returns the instruction through `rom_rdata_new`, is first used here.
//
// A memory cycle completes on the clk16 edge where the CPU has a request out
// (`rom_en` or `ram_cen`) and `cpu_en & ~halt` is high, which is the CPU's own
// enable; gba_memory presents `rom_data` and `ram_rdata` on the FOLLOWING
// cycle, and that is where they are sampled here, as the CPU sees them.
// Recording starts at the first completed cycle whose fetch address is 0x08000000
// or above and takes sixteen consecutive completed cycles.  It clears while the
// machine is held (`~gbaon`), so each cart load records afresh.
//
// Four words per entry:
//   word 0  {rom_en, thumb, 2'b00, rom_addr[27:0]}
//   word 1  rom_data as the CPU receives it
//   word 2  {ram_cen, ram_wen, ram_be[3:0], ram_addr[27:24], ram_addr[21:0]}
//   word 3  ram_wen ? ram_wdata : ram_rdata
//
// This recorder is compiled only under `TINYGBA_BOOTTRACE`, which is separate
// from `TINYGBA_FETCHTRACE` on purpose.  It answered its question in BRD-023 --
// fifteen of fifteen cartridge fetches returned byte-exact words -- and it costs
// 2,064 registers, more than every other tap in this readout combined.  Carrying
// it into a build that is asking a different question made place and route slow
// and fragile: six seeds of the resulting netlist produced two hard `hclk5`
// routing aborts, one clock-plane refusal and one long grind.  The MMIO ring
// below is what the misrouting question needs, and it fits without this.
`ifdef TINYGBA_BOOTTRACE
wire tr_cyc = (rom_en | ram_cen) & cpu_en & ~halt;
(* keep *) reg [2047:0] tr_flat;          // entry e word w at bits (4e+w)*32
(* keep *) reg [15:0]   tr_vld;
reg  [4:0]  tr_n;                         // entries recorded, 16 = full
reg         tr_pend;                      // an entry's read data arrives this cycle
reg  [3:0]  tr_pidx;
reg         tr_pwen;
reg  [31:0] tr_pwdata;
wire        tr_go = tr_cyc & ~tr_n[4] & ((tr_n != 5'd0) | (rom_en & rom_addr[27]));
always @(posedge clk16) begin
    if (~gbaon) begin
        tr_n    <= 5'd0;
        tr_pend <= 1'b0;
        tr_vld  <= 16'd0;
    end else begin
        tr_pend <= tr_go;
        if (tr_go) begin
            tr_n      <= tr_n + 5'd1;
            tr_pidx   <= tr_n[3:0];
            tr_pwen   <= ram_wen;
            tr_pwdata <= ram_wdata;
            tr_flat[{tr_n[3:0], 2'd0}*32 +: 32] <= {rom_en, thumb, 2'b00, rom_addr};
            tr_flat[{tr_n[3:0], 2'd2}*32 +: 32] <= {ram_cen, ram_wen, ram_be,
                                                    ram_addr[27:24], ram_addr[21:0]};
        end
        if (tr_pend) begin
            tr_flat[{tr_pidx, 2'd1}*32 +: 32] <= rom_data;
            tr_flat[{tr_pidx, 2'd3}*32 +: 32] <= tr_pwen ? tr_pwdata : ram_rdata;
            tr_vld[tr_pidx] <= 1'b1;
        end
    end
end
`endif
`else
assign tr_word  = 32'd0;
assign tr_valid = 16'd0;
`endif

`ifdef VERILATOR
assign gba_on = gbaon;
`endif

////////////////////////////
// GPU
////////////////////////////

// The GPU's pixel-stream declarations live above the CPU/memory mux, because the
// status probe reads `pixel_out_we` and a use before its declaration is a
// hazard the build only tolerates by flag.

wire [proc_buswidth-1:0] gb_bus_din;        // CPU bus
wire [proc_buswidth-1:0] gb_bus_dout;
wire [proc_busadr-1:0] gb_bus_adr;
wire gb_bus_rnw;
wire gb_bus_ena;
wire gb_bus_done;
wire [1:0] gb_bus_acc;
wire [3:0] gb_bus_be;
wire gb_bus_rst;

// ---------------------------------------------------------------- pages 2, 3
// The MMIO write ring and the status pages.  This block sits after the
// `gb_bus_*` declarations on purpose: naming those wires above their
// declaration makes Verilog create implicit 1-bit wires that fold to constants,
// which is TCL-014 and has already produced two wrong readings in this project.
//
// The ring records what the MMIO register file ACTUALLY received, on
// `gb_bus_ena & ~gb_bus_rnw`, beside what the CPU asked for.  The alignment
// between those two is NOT assumed here, because `gb_memory` has two paths to
// the register file and they are one cycle apart.  `bram_addr` is assigned in an
// `always @*` block, so in `state == MAIN` it IS `ram_addr` in the same cycle and
// `gb_bus_adr = {bram_addr[11:2], 2'b0}` is combinational from it.  In every
// other state `bram_addr` takes the registered `bram_addr_buf`, which was loaded
// from `ram_addr` one cycle earlier.  So a write can reach the register file with
// either the current address or the previous one, and a ring that recorded only
// one of them would call the buffered case a mismatch.
//
// Both are therefore stored, and the decoder reports which one the register file's
// address agrees with.  That is a measurement of the alignment as well as of the
// address, which is what BRD-023 needed and did not have.
//
// Four words per entry, eight entries:
//   word 0  {4'h0, gb_bus_adr}    address the register file saw
//   word 1  gb_bus_din            data the register file saw
//   word 2  ram_addr[27:0]        address the CPU has out this cycle
//   word 3  ram_addr_d1[27:0]     the previous cycle's, i.e. bram_addr_buf

// ---------------------------------------------------------------- page 3
// Four entries:
//   entry 0  live GPU DISPCNT and sticky DISPCNT writes, ring position, halt
//   entry 1  counters: CPU-side IO writes, VRAM writes, MMIO writes the register
//            file received, cartridge fetches
//   entry 2  the last completed cartridge fetch, so an offending store can be
//            located in `build/test/test.s` by disassembly rather than inferred
//            from its data, and the VRAM phase bits
//   entry 3  the last VRAM store, address and data as the CPU issued them
`ifdef TINYGBA_FETCHTRACE
wire tr_iowr   = ram_cen & ram_wen & cpu_en & ~halt & (ram_addr[27:24] == 4'h4);
wire tr_vramwr = ram_cen & ram_wen & cpu_en & ~halt & (ram_addr[27:24] == 4'h6);
wire tr_cart   = rom_en & cpu_en & ~halt & rom_addr[27];
wire tr_mmio   = gb_bus_ena & ~gb_bus_rnw;
// IWRAM execution.  A retail cartridge copies itself to 0x03000000 and runs from
// there, at which point a counter of CARTRIDGE fetches stops moving although the
// CPU is working, so that counter cannot tell a running game from a wedged one.
// Entry 27 made exactly that mistake.  These watch the region the cartridge
// actually moves to.
wire tr_iwfetch = rom_en & cpu_en & ~halt & (rom_addr[27:24] == 4'h3);
wire tr_iwwr    = ram_cen & ram_wen & cpu_en & ~halt & (ram_addr[27:24] == 4'h3);
wire tr_iwrd    = ram_cen & ~ram_wen & cpu_en & ~halt & (ram_addr[27:24] == 4'h3);

reg  [27:0] ram_addr_d1;
always @(posedge clk16) ram_addr_d1 <= ram_addr[27:0];

`ifndef TINYGBA_STALLTRACE
// The MMIO ring is compiled out under TINYGBA_STALLTRACE: the stall tail ring
// takes its pages and its 1,024 registers, and both together would bring back
// the routing fragility the boot trace caused (BRD-024).
(* keep *) reg [1023:0] mm_flat;          // entry e word w at bits (4e+w)*32
(* keep *) reg [7:0]    mm_vld;
`endif
(* keep *) reg [4:0]    s_vram;           // VRAM store ever carried
                                          // {7FFF, 0000, FFE0, 001F, 03E0}
(* keep *) reg [2:0]    s_dc;             // DISPCNT written with {FFE0, 0403, 0000}
(* keep *) reg [15:0]   last_dc_data;     // data carried by the last write to 0x04000000
reg  [7:0]  dc403_n;                      // writes of 0x0403 to DISPCNT, saturating
(* keep *) reg [27:0]   last_cart_addr;
(* keep *) reg          last_cart_thumb;
(* keep *) reg [27:0]   last_vram_addr;
(* keep *) reg [31:0]   last_vram_data;
reg  [2:0]  mm_n;
reg         mm_wrapped;
reg  [15:0] io_total;                     // stores the CPU decoded as IO space
reg  [15:0] mmio_wr;                      // writes the register file received
reg  [23:0] vram_wr;
reg  [15:0] dc_wr;
reg  [31:0] cart_fetch;
(* keep *) reg [27:0] last_iw_addr;        // last IWRAM instruction fetch
reg  [31:0] iw_fetch;                     // IWRAM instruction fetches
reg  [23:0] iw_wr;                        // IWRAM data writes
reg  [23:0] iw_rd;                        // IWRAM data reads
(* keep *) reg s_iw;                      // IWRAM execution ever seen
always @(posedge clk16) begin
    if (~gbaon) begin
        mm_n            <= 3'd0;
        mm_wrapped      <= 1'b0;
`ifndef TINYGBA_STALLTRACE
        mm_vld          <= 8'd0;
`endif
        io_total        <= 16'd0;
        mmio_wr         <= 16'd0;
        vram_wr         <= 24'd0;
        dc_wr           <= 16'd0;
        cart_fetch      <= 32'd0;
        last_iw_addr    <= 28'd0;
        iw_fetch        <= 32'd0;
        iw_wr           <= 24'd0;
        iw_rd           <= 24'd0;
        s_iw            <= 1'b0;
        s_vram          <= 5'd0;
        s_dc            <= 3'd0;
        last_dc_data    <= 16'd0;
        dc403_n         <= 8'd0;
        last_cart_addr  <= 28'd0;
        last_cart_thumb <= 1'b0;
        last_vram_addr  <= 28'd0;
        last_vram_data  <= 32'd0;
    end else begin
        if (tr_iwfetch) begin
            iw_fetch     <= iw_fetch + 32'd1;
            last_iw_addr <= rom_addr[27:0];
            s_iw         <= 1'b1;
        end
        if (tr_iwwr) iw_wr <= iw_wr + 24'd1;
        if (tr_iwrd) iw_rd <= iw_rd + 24'd1;
        if (tr_cart) begin
            cart_fetch      <= cart_fetch + 32'd1;
            last_cart_addr  <= rom_addr[27:0];
            last_cart_thumb <= thumb;
        end
        if (tr_vramwr) begin
            vram_wr        <= vram_wr + 24'd1;
            last_vram_addr <= ram_addr[27:0];
            last_vram_data <= ram_wdata;
            case (ram_wdata[15:0])
                16'h03E0: s_vram[0] <= 1'b1;   // fill: every check passed
                16'h001F: s_vram[1] <= 1'b1;   // fill: a check failed
                16'hFFE0: s_vram[2] <= 1'b1;   // failure column
                16'h7FFF: s_vram[3] <= 1'b1;   // blink square, white phase
                16'h0000: s_vram[4] <= 1'b1;   // blink square, black phase
                default:  ;
            endcase
        end
        if (tr_iowr) begin
            io_total <= io_total + 16'd1;
            if (ram_addr[27:0] == 28'h0400_0000) begin
                dc_wr <= dc_wr + 16'd1;
                case (ram_wdata[15:0])
                    16'h0000: s_dc[0] <= 1'b1;
                    16'h0403: s_dc[1] <= 1'b1;
                    16'hFFE0: s_dc[2] <= 1'b1;
                    default:  ;
                endcase
                last_dc_data <= ram_wdata[15:0];
                if (ram_wdata[15:0] == 16'h0403 && ~&dc403_n)
                    dc403_n <= dc403_n + 8'd1;
            end
        end
        if (tr_mmio) begin
            // Four words, 32 bits each, totalling exactly 128, which is what the
            // `+:` slice takes.  This is worth spelling out because the first two
            // attempts got it wrong in ways Verilog does not complain about: the
            // first was 108 bits into 128 and was silently zero-extended, shifting
            // every field by 20 bits; the second was 144 bits and was silently
            // truncated.  Both produced plausible-looking words and both were
            // caught only by checking the width by hand.  Each word is padded to
            // its own 32-bit boundary, and `gb_bus_adr` is cut to the 12 bits that
            // carry the IO-window offset -- the rest of it is a constant zero by
            // construction (`{bram_addr[11:2], 2'b0}`).
            //   4 + 16 + 12 = 32    marker and register-side address
            //       32              register-side data
            //   4 + 28      = 32    CPU address
            //   4 + 28      = 32    CPU address one cycle earlier
            // Entry stride.  `{mm_n, 7'd0}` is `mm_n * 128`, which is the entry
            // size; the first version of this line used `{mm_n, 6'd0}`, which is
            // `mm_n * 64`, so every entry overwrote the upper half of its
            // predecessor and half the ring decoded as a blend of two writes.
            // The marker constant caught it: entries 1 and 4 carried `0xA5C3` and
            // the rest did not, which is only possible if the layout is wrong.
            // The read side always used `{tr_ent, 7'd0}`, so only this line was
            // wrong -- the symptom looked like a decoder fault and was not.
`ifndef TINYGBA_STALLTRACE
            mm_flat[{mm_n, 7'd0} +: 128] <= {4'h0,  16'hA5C3, gb_bus_adr[11:0],
                                             gb_bus_din,
                                             4'h0,  ram_addr[27:0],
                                             4'h0,  ram_addr_d1[27:0]};
            mm_vld[mm_n] <= 1'b1;
`endif
            mm_n         <= mm_n + 3'd1;
            if (mm_n == 3'd7) mm_wrapped <= 1'b1;
            mmio_wr <= mmio_wr + 16'd1;
        end
    end
end

wire [2:0]   tr_page = tr_sel[6:5];
wire [2:0]   tr_ent  = tr_sel[4:2];
wire [1:0]   tr_wd   = tr_sel[1:0];
`ifndef TINYGBA_STALLTRACE
wire [6:0]   mm_off  = {tr_wd, 5'd0};     // 0, 32, 64, 96
wire [127:0] mm_pick = mm_flat[{tr_ent, 7'd0} +: 128];
`endif

reg [31:0] tr_word_mux;
always @(*) begin
    tr_word_mux = 32'd0;
    case (tr_page)
`ifdef TINYGBA_STALLTRACE
        // Layout v5: pages 0 and 2 are the stall tail ring, page 3 the live
        // stall counters; all generated in the stall-trace block below.
        2'd0, 2'd2, 2'd3: tr_word_mux = stl_word;
`else
        // Page 0: the MMIO write ring, eight entries of four words.
        2'd0: tr_word_mux = mm_pick[mm_off +: 32];
`endif
        // Page 1: the status pages, four entries.
        2'd1: case (tr_ent)
                  3'd0: case (tr_wd)
                            2'd0: tr_word_mux = {25'h0, gpu_dc};      // live DISPCNT
                            // 25 bits, not 26: the padding was one bit too wide, so
                            // the 33-bit concatenation was silently truncated into
                            // this 32-bit register and the low 32 bits were what the
                            // decoder already read.  Written out as the width it has
                            // instead of the width it claimed, so
                            // tools/check_ring_width.py can check it.
                            2'd1: tr_word_mux = {25'h0, s_dc, mm_wrapped, mm_n};
                            2'd2: tr_word_mux = {16'h0, dc_wr};
                            default: tr_word_mux = {30'h0, halt, gbaon};
                        endcase
                  3'd1: case (tr_wd)
                            2'd0: tr_word_mux = {16'h0, io_total};
                            2'd1: tr_word_mux = {8'h0,  vram_wr};
                            2'd2: tr_word_mux = {16'h0, mmio_wr};
                            default: tr_word_mux = cart_fetch;
                        endcase
                  3'd2: case (tr_wd)
                            2'd0: tr_word_mux = {3'h0, last_cart_thumb, last_cart_addr};
                            default: tr_word_mux = {27'h0, s_vram};
                        endcase
                  // Entry 3 keeps the last VRAM store.
                  3'd3: case (tr_wd)
                            2'd0: tr_word_mux = {4'h0, last_vram_addr};
                            default: tr_word_mux = last_vram_data;
                        endcase
                  // Entry 4 carries IWRAM execution.  A retail cartridge copies
                  // itself to 0x03000000 and runs from there, so these are the
                  // only fields that can tell a working game from a wedged one;
                  // the cartridge-fetch counter goes blind at that point.
                  3'd4: case (tr_wd)
                            2'd0: tr_word_mux = {3'h0, s_iw, last_iw_addr};
                            2'd1: tr_word_mux = iw_fetch;
                            2'd2: tr_word_mux = {8'h0, iw_wr};
                            default: tr_word_mux = {8'h0, iw_rd};
                        endcase
`ifdef TINYGBA_STALLTRACE
                  // Entries 5..7: the freeze snapshot of the stall trace.
                  default: tr_word_mux = stl_word;
`else
                  default: tr_word_mux = 32'd0;
`endif
                 endcase
    endcase
end

assign tr_word  = tr_word_mux;
`ifdef TINYGBA_STALLTRACE
assign tr_valid = (tr_page == 2'd1) ? {stl_valid[15:13], 5'h1F, 8'h00} : stl_valid;
`else
assign tr_valid = (tr_page == 2'd0) ? {8'h00, mm_vld}
                : (tr_page == 2'd1) ? 16'h1F00
                :                     16'h0000;
`endif
`endif

wire [13:0] vram_lo_addr;
wire [31:0] vram_lo_din, vram_lo_dout;
wire vram_lo_we;
wire [3:0] vram_lo_be;
wire [12:0] vram_hi_addr;
wire [31:0] vram_hi_din, vram_hi_dout;
wire vram_hi_we;
wire [3:0] vram_hi_be;
wire [7:0] oamram_addr;
wire [31:0] oamram_din, oamram_dout;
wire [3:0] oamram_we;
wire [6:0] palette_bg_addr;
wire [31:0] palette_bg_din, palette_bg_dout;
wire [3:0] palette_bg_we;
wire [6:0] palette_oam_addr;
wire [31:0] palette_oam_din, palette_oam_dout;
wire [3:0] palette_oam_we;

wire phase = ~clk16;    // 0: internal GPU work, 1: get data from CPU

`ifdef TINYGBA_PIXTEST
// TinyGBA: clk16 side of PIXTEST bands 11..14 (see the map above).  It sits here
// because the memory-mux strobes are declared just above.
always @(posedge clk16) begin
    if (~gbaon) pix_wr <= 4'b0;
    else begin
        if (|palette_bg_we | |palette_oam_we)        pix_wr[0] <= 1'b1;
        if (vram_lo_we | vram_hi_we)                 pix_wr[1] <= 1'b1;
        if (|oamram_we)                              pix_wr[2] <= 1'b1;
        if (rom_en & (rom_addr[27:24] != 4'h0))      pix_wr[3] <= 1'b1;
    end
end
`endif

gba_gpu #(.FCLK_SPEED(3)) gpu (
    .fclk(clk50), .mclk(clk16), .phase(phase), .reset(~gbaon),
    `GB_BUS_PORTS_INST,

    // config
    .lockspeed(1'b0), .interframe_blend(2'b0), .maxpixels(1'b0), .shade_mode(3'b0), 
    .hdmode2x_bg(1'b0), .hdmode2x_obj(1'b0), 
    .bitmapdrawmode(), 
    
    // output
    .pixel_out_x(pixel_out_x), .pixel_out_2x(), .pixel_out_y(pixel_out_y), .pixel_out_addr(), 
    .pixel_out_data(pixel_out_data), .pixel_out_we(pixel_out_we), .pixel2_out_x(), 
    .pixel2_out_data(), .pixel2_out_we(), 
    
    // one cycle a time on phase 0
    // .new_cycles(8'd1), .new_cycles_valid(1'b1),
    
    .IRP_HBlank(IRP_HBlank), .IRP_VBlank(IRP_VBlank), .IRP_LCDStat(IRP_LCDStat), 
    .hblank_trigger_dma(hblank_trigger), .vblank_trigger_dma(vblank_trigger), 
    .videodma_start_dma(videodma_start), .videodma_stop_dma(videodma_stop), 
    
    // VRAM access from CPU
    .VRAM_Lo_addr(vram_lo_addr), .VRAM_Lo_datain(vram_lo_din), .VRAM_Lo_dataout(vram_lo_dout), 
    .VRAM_Lo_we(vram_lo_we), .VRAM_Lo_be(vram_lo_be), 
    .VRAM_Hi_addr(vram_hi_addr), .VRAM_Hi_datain(vram_hi_din), .VRAM_Hi_dataout(vram_hi_dout), 
    .VRAM_Hi_we(vram_hi_we), .VRAM_Hi_be(vram_hi_be), 
    .vram_blocked(), .OAMRAM_PROC_addr(oamram_addr), .OAMRAM_PROC_datain(oamram_din), 
    .OAMRAM_PROC_dataout(oamram_dout), .OAMRAM_PROC_we(oamram_we), 
    
    // Palette access from CPU
    .PALETTE_BG_addr(palette_bg_addr), .PALETTE_BG_datain(palette_bg_din), .PALETTE_BG_dataout(palette_bg_dout), 
    .PALETTE_BG_we(palette_bg_we), 
    .PALETTE_OAM_addr(palette_oam_addr), .PALETTE_OAM_datain(palette_oam_din), .PALETTE_OAM_dataout(palette_oam_dout), 
    .PALETTE_OAM_we(palette_oam_we), 

    .DISPSTAT_debug(dispstat_dbg)
`ifdef TINYGBA_GPU_TAPS
    , .DBG_gt(gpu_dbg)
    , .DBG_ev(gpu_ev)
    , .DBG_ds(gpu_ds)
    , .DBG_vf(gpu_vf)
    , .DBG_ob(gpu_ob)
    , .DBG_dc(gpu_dc)
`endif
);


////////////////////////////
// Sound
////////////////////////////

gba_sound sound (
    .clk(clk16), .reset(~gbaon), .gb_on(1'b1),
    `GB_BUS_PORTS_INST,
    .timer0_tick(timer0_tick), .timer1_tick(timer1_tick), .sound_dma_req(sound_dma_req),
    .sound_out_left(sound_out_left), .sound_out_right(sound_out_right),
    .debug_fifocount()
);

////////////////////////////
// Memory
////////////////////////////

// cpu sdram memory interface
`ifdef TINYGBA_SDRAM_DEBUG
wire [2:0] mem_dbg_state;
wire [7:0] mem_dbg_lw;
wire       mem_dbg_lwr;
`endif
wire [25:2] cpu_mem_addr;
wire [31:0] cpu_mem_wdata;
wire [31:0] cpu_mem_rdata [1:3];
wire        cpu_mem_rd, cpu_mem_wr;
wire [3:0]  cpu_mem_be;
wire        cpu_mem_ready_raw;
// TinyGBA (BRD-049): `cpu_ready` is registered in the controller's `clk67` domain
// and left this block as a bare net, sampled as a level by `gba_memory` in
// `clk16` with no synchroniser.  It is a full `clk16` period wide -- four `clk67`
// cycles, measured as 556,000 `clk16` samples of it against 345,000 `clk67`
// rises -- so it is wide enough for a two-flop synchroniser to capture reliably;
// what it was missing is the two flops.  Without them the receiving flop sees a
// signal that changes asynchronously to its own clock, which is a metastability
// hazard on the exact boundary that carries BRD-044's one-word read lag.
//
// The cost is real and is the reason this is a separate change from any read-path
// fix: every memory access now completes two `clk16` cycles later than it did, so
// a reach figure taken at a fixed step budget will fall for reasons that are
// speed and not correctness.  Any before/after comparison must say so, and the
// property that matters is whether the program still reaches the same address.
reg  [1:0]  cpu_mem_ready_s;
always @(posedge clk16)
    if (~resetn) cpu_mem_ready_s <= 2'b00;
    else         cpu_mem_ready_s <= {cpu_mem_ready_s[0], cpu_mem_ready_raw};
wire        cpu_mem_ready = cpu_mem_ready_s[1];
wire [1:0]  cpu_mem_port;

// TinyGBA: the memory controller's view of the SDRAM port.  Normally these are
// wired straight onto the cpu_mem_* signals above; under TINYGBA_SDRAM_TEST the
// occupancy probe takes the port over instead (see fpga/gba/diag/sdram_probe.v).
wire [25:2] mem_addr;
wire [31:0] mem_wdata;
wire        mem_rd, mem_wr;
wire [3:0]  mem_be;
wire [1:0]  mem_port;

// Diagnostic readout, drawn by gba2hdmi under TINYGBA_SDRAM_TEST and tied to
// zero in every production build.
wire [15:0] dbg_bits;
wire        dbg_done;

// iosys RV memory interface
wire        rv_valid        /* xsynthesis syn_keep=1 */;
wire        rv_ready        /* xsynthesis syn_keep=1 */;
wire [22:0] rv_addr         /* xsynthesis syn_keep=1 */;
wire [31:0] rv_wdata        /* xsynthesis syn_keep=1 */;
wire [3:0]  rv_wstrb        /* xsynthesis syn_keep=1 */;
wire [31:0] rv_rdata        /* xsynthesis syn_keep=1 */;

// sdram-side interface
wire [22:1] rv_mem_addr     /* xsynthesis syn_keep=1 */;
wire [15:0] rv_mem_din      /* xsynthesis syn_keep=1 */;
wire [1:0]  rv_mem_ds       /* xsynthesis syn_keep=1 */;
wire [15:0] rv_mem_dout     /* xsynthesis syn_keep=1 */;
wire        rv_mem_req      /* xsynthesis syn_keep=1 */;
wire        rv_mem_req_ack  /* xsynthesis syn_keep=1 */;
wire        rv_mem_we       /* xsynthesis syn_keep=1 */;

// EEPROM accesses
wire        eeprom_rd, eeprom_wr;
wire [12:0] eeprom_addr;
wire  [7:0] eeprom_rdata, eeprom_wdata;

wire        sdram_busy;
wire  [2:0] config_backup_type;
wire        backup_written;

wire [16:0] dma_eepromcount;

gba_memory mem (
    .clk(clk16), .resetn(resetn), .ce(1'b1),
    // CPU memory interface
    .rom_en(rom_en), .rom_addr(rom_addr), .rom_data(rom_data), .thumb(thumb), .cpu_en(cpu_en), 

    .ram_cen(ram_cen), .ram_wen(ram_wen), .ram_addr(ram_addr), .ram_rdata(ram_rdata),
    .ram_wdata(ram_wdata), .ram_be(ram_be), 

    .dma_on(dma_on), .dma_addr(dma_addr), .dma_wdata(dma_wdata), .dma_ena(dma_bus_ena), 
    .dma_wr(~dma_rnw), .dma_be(calc_byte_ena(dma_bus_acc, dma_addr[1:0])), 
    .dma_rdata(dma_rdata), .dma_done(dma_bus_done), .dma_eepromcount(dma_eepromcount),

    // SDRAM interface
	.sdram_addr(mem_addr), .sdram_wdata(mem_wdata), .sdram_rdata(cpu_mem_rdata), 
    .sdram_rd(mem_rd), .sdram_wr(mem_wr), .sdram_be(mem_be),
    .sdram_port(mem_port), .sdram_ready(cpu_mem_ready), .backup_written(backup_written),

    // EEPROM access from RV
    .eeprom_rd(eeprom_rd), .eeprom_wr(eeprom_wr), .eeprom_addr(eeprom_addr),
    .eeprom_rdata(eeprom_rdata), .eeprom_wdata(eeprom_wdata),

    // Loader interface
    .loading(loading), .loader_data(loader_do), .loader_valid(loader_do_valid),
    .gbaon(gbaon_mem), .config_backup_type(config_backup_type),
    .cartram_dirty(cartram_dirty), .cartram_dirty_clear(cartram_dirty_clear),

    // Interface to GPU to access special memory like VRAM, OAMRAM, PALETTE
    .vram_lo_addr(vram_lo_addr), .vram_lo_din(vram_lo_din), .vram_lo_dout(vram_lo_dout), 
    .vram_lo_we(vram_lo_we), .vram_lo_be(vram_lo_be), 
    .vram_hi_addr(vram_hi_addr), .vram_hi_din(vram_hi_din), .vram_hi_dout(vram_hi_dout), 
    .vram_hi_we(vram_hi_we), .vram_hi_be(vram_hi_be), 
`ifdef TINYGBA_SDRAM_DEBUG
	.dbg_state(mem_dbg_state), .dbg_loader_writes(mem_dbg_lw), .dbg_loader_writing(mem_dbg_lwr),
`endif
`ifdef TINYGBA_STALLTRACE
    .stl_mem_state(stl_mem_state),
`endif
    .gb_bus_din(gb_bus_din), .gb_bus_dout(gb_bus_dout), .gb_bus_adr(gb_bus_adr),
    .gb_bus_rnw(gb_bus_rnw), .gb_bus_ena(gb_bus_ena), .gb_bus_done(gb_bus_done),
    .gb_bus_acc(gb_bus_acc), .gb_bus_be(gb_bus_be), .gb_bus_rst(gb_bus_rst), 
    .oamram_addr(oamram_addr), .oamram_din(oamram_din), .oamram_dout(oamram_dout), .oamram_we(oamram_we), 
    .palette_bg_addr(palette_bg_addr), .palette_bg_din(palette_bg_din), 
    .palette_bg_dout(palette_bg_dout), .palette_bg_we(palette_bg_we), 
    .palette_oam_addr(palette_oam_addr), .palette_oam_din(palette_oam_din), 
    .palette_oam_dout(palette_oam_dout), .palette_oam_we(palette_oam_we)
);

`ifndef VERILATOR
sdram_gba sdram (
    .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr),
	.SDRAM_BA(O_sdram_ba), .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n),
	.SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n), 
    .SDRAM_DQM(O_sdram_dqm),

	// cpu/chipset interface
	.clk(clk67), .mclk(clk16), .resetn(resetn),

	.cpu_addr(cpu_mem_addr), .cpu_wdata(cpu_mem_wdata), .cpu_rdata(cpu_mem_rdata), 
    .cpu_rd(cpu_mem_rd), .cpu_wr(cpu_mem_wr), .cpu_be(cpu_mem_be),
    .cpu_ready(cpu_mem_ready_raw), .cpu_port(cpu_mem_port),
    .config_backup_type(config_backup_type), .backup_written(backup_written),
	
    .rv_addr(rv_mem_addr), .rv_din(rv_mem_din), .rv_ds(rv_mem_ds), 
    .rv_dout(rv_mem_dout), .rv_req(rv_mem_req), .rv_req_ack(rv_mem_req_ack), 
    .rv_we(rv_mem_we),

    .busy(sdram_busy)
);

`else

// TinyGBA: under TINYGBA_SDRAM_RTL, simulate the REAL controller against a
// pin-level part instead of the behavioural array.  `sdram_sim` answers
// correctly and instantly, so it can never reproduce a controller fault -- the
// same blind spot the sibling SNES project records when its GSU's memory reads
// only worked while the other master happened to be reading.  The define exists
// only in the simulation build; synthesis always takes the `ifndef VERILATOR`
// branch above and is unaffected.
`ifdef TINYGBA_SDRAM_RTL
gba_sdram_rtl sdram (
	.SDRAM_DQ(), .SDRAM_A(), .SDRAM_DQM(), .SDRAM_BA(),
	.SDRAM_nCS(), .SDRAM_nWE(), .SDRAM_nRAS(), .SDRAM_nCAS(),
	.clk(clk67), .mclk(clk16), .resetn(resetn),
	.cpu_addr(cpu_mem_addr), .cpu_wdata(cpu_mem_wdata), .cpu_rdata(cpu_mem_rdata),
	.cpu_rd(cpu_mem_rd), .cpu_wr(cpu_mem_wr), .cpu_be(cpu_mem_be),
	.cpu_ready(cpu_mem_ready_raw), .cpu_port(cpu_mem_port),
	.config_backup_type(config_backup_type), .backup_written(backup_written),
	.rv_dout(), .rv_req_ack(), .total_refresh(), .busy(),
`ifdef TINYGBA_SDRAM_DEBUG
	.dbg_mem_state(mem_dbg_state), .dbg_loader_writes(mem_dbg_lw),
	.dbg_loader_writing(mem_dbg_lwr),
`endif
	.clk67_unused()
);
`else
// model for cpu to work under verilator
sdram_sim sdram (
	.clk(clk16),
	.cpu_addr(cpu_mem_addr), .cpu_wdata(cpu_mem_wdata), .cpu_rdata(cpu_mem_rdata), 
    .cpu_rd(cpu_mem_rd), .cpu_wr(cpu_mem_wr), .cpu_be(cpu_mem_be),
    .cpu_ready(cpu_mem_ready_raw), .cpu_port(cpu_mem_port), 
    .config_backup_type(config_backup_type)
);
`endif   // TINYGBA_SDRAM_RTL

`endif

////////////////////////////
// Interrupts
////////////////////////////
gba_interrupts intr (.clk(clk16), .resetn(gbaon),
    `GB_BUS_PORTS_INST,
    .IRP_VBlank(IRP_VBlank), .IRP_HBlank(IRP_HBlank), .IRP_LCDStat(IRP_LCDStat), 
    .IRP_Timer(IRP_Timer), .IRP_Serial(IRP_Serial), .IRP_DMA(IRP_DMA), 
    .IRP_Joypad(IRP_Joypad), 
    .cpu_IRP(cpu_IRP), .halt(halt)
);

////////////////////////////
// DMA
////////////////////////////

gba_dma dma (
    .clk100(clk16), .reset(~gbaon), .ce(1'b1 /*~halt*/), `GB_BUS_PORTS_INST, 
    .new_cycles(1), .new_cycles_valid(1'b1), .irp_dma(IRP_DMA), .lastread_dma(), 
    .dma_on(dma_on), .do_step(1'b1), .cpu_preemptable(cpu_en),      // always start DMA after a ready cycle
    .sound_dma_req(sound_dma_req), .hblank_trigger(hblank_trigger), .vblank_trigger(vblank_trigger), 
    .videodma_start(videodma_start), .videodma_stop(videodma_stop), .dma_new_cycles(), 
    .dma_first_cycles(), .dma_dword_cycles(), .dma_toROM(), 
    .dma_init_cycles(), .dma_cycles_adrup(), .dma_eepromcount(dma_eepromcount), 
    .dma_bus_Adr(dma_addr), .dma_bus_rnw(dma_rnw), .dma_bus_ena(dma_bus_ena), 
    .dma_bus_acc(dma_bus_acc), .dma_bus_dout(dma_wdata), .dma_bus_din(dma_rdata), 
    .dma_bus_done(dma_bus_done), .dma_bus_unread(),
`ifdef TINYGBA_STALLTRACE
    .debug_dma(stl_debug_dma)
`else
    .debug_dma()
`endif
);

`ifdef TINYGBA_STALLTRACE
// ---------------------------------------------------------------- stall tail
// TinyGBA: the board stall-trace instrument, layout v5 (core-log entry 41).
// Compiled under TINYGBA_STALLTRACE, which needs TINYGBA_FETCHTRACE for the
// readout path; give both on TINYGBA_DEFINES.
//
// Two board facts were never measured: where test_logo stops between
// `DISPCNT<=0` and `DISPCNT<=0x0403` with halt=0 (BRD-023/025), and what the
// memory controller and DMA are doing when Super Mario Advance freezes after
// its DMA3 copy with halt=1 (BRD-025/029).  The boot trace answered only "what
// were the first sixteen cycles"; this answers "what were the LAST sixteen".
//
// Ring.  Every completed CPU memory cycle -- the clk16 edge where the CPU has a
// request out (`rom_en` or `ram_cen`) and `cpu_en & ~halt`, the CPU's own
// enable -- is written into a sixteen-slot circular ring, with the read data
// sampled on the following clk16 edge as the CPU receives it.  The words are
// the boot trace's:
//   word 0  {rom_en, thumb, 2'b00, rom_addr[27:0]}
//   word 1  rom_data as the CPU receives it
//   word 2  {ram_cen, ram_wen, ram_be[3:0], ram_addr[27:24], ram_addr[21:0]}
//   word 3  ram_wen ? ram_wdata : ram_rdata
//
// Freeze.  The ring stops taking entries, and a snapshot of the memory
// controller is latched, on whichever comes first:
//   stall  no completed CPU cycle for 2^22 clk16 cycles (4,194,304, ~0.25 s
//          at 16.78 MHz, ~15 frames).  The longest legitimate waits in this
//          machine are a HALT until the next V-Blank (one frame, 280,896
//          clk16) and an immediate DMA holding the CPU (a full 0x1F00-word
//          copy at a few clk16 per beat is well under 10^5), so this is
//          an order of magnitude clear of both.  The longest gap that DID end
//          in a completed cycle before the freeze is kept as `stl_maxgap`, so
//          the margin is measured rather than assumed.
//   time   2^27 clk16 (~8.0 s) after gbaon, so a CPU that is looping rather
//          than stalled still yields a coherent sixteen-cycle window of the loop.
// The cause is recorded.  Everything clears while `~gbaon`, so each load
// records afresh.  Counters that keep running after the freeze are on page 3
// and are read combinationally in clk50: discard the first frame after a page
// change and read pages by the page strip (TCL-019).
//
// Readout (gba2hdmi FETCHTRACE geometry, unchanged):
//   page 0  ring slots 0..7          page 2  ring slots 8..15
//   page 1  status entries 0..4 as in v4, freeze snapshot in entries 5..7
//   page 3  live counters, entries 0..2
// Oldest ring slot is `stl_wp` once `stl_full`, else slot 0; the decoder orders
// them.  Page 1 entry 5 word 0 carries the marker 0x57A1 in bits 31:16 so a
// packing or decoder error shows as a wrong marker, not as plausible data.
wire        stl_cyc = (rom_en | ram_cen) & cpu_en & ~halt;
wire [15:0] stl_flags = {dma_on, dma_bus_ena, rom_en, ram_cen, cpu_en, halt,
                         mem_rd, mem_wr, mem_port[1:0], cpu_mem_ready, thumb,
                         ram_wen, dma_rnw, dma_bus_done, gbaon};

(* keep *) reg [2047:0] stl_flat;         // slot s word w at bits (4s+w)*32
(* keep *) reg [15:0]   stl_vld;
(* keep *) reg [3:0]    stl_wp;           // next slot to write
(* keep *) reg          stl_full;         // the ring has wrapped
reg         stl_pend;                     // a slot's read data arrives this cycle
reg  [3:0]  stl_pidx;
reg         stl_pwen;
reg  [31:0] stl_pwdata;
(* keep *) reg          stl_frz;
(* keep *) reg [3:0]    stl_cause;        // bit 0 stall, bit 1 time, bit 2 cart->BIOS, bit 3 pool read
(* keep *) reg [31:0]   stl_gap;          // clk16 since the last completed cycle, live
(* keep *) reg [23:0]   stl_maxgap;       // longest gap ended by a completed cycle, pre-freeze
reg  [27:0] stl_age;                      // clk16 since gbaon, stops at bit 27
(* keep *) reg [31:0]   stl_ncyc;         // completed cycles before the freeze
(* keep *) reg [31:0]   stl_post;         // completed cycles after the freeze
(* keep *) reg [15:0]   stl_rdy_cyc;      // sdram_ready pulses since the last completed cycle
(* keep *) reg [15:0]   stl_rdy_st;       // sdram_ready pulses since the FSM changed state
(* keep *) reg [15:0]   stl_st_age;       // clk16 in the current FSM state
(* keep *) reg [15:0]   stl_st_chg;       // FSM state changes since the last completed cycle
reg  [2:0]  stl_st_prev;
(* keep *) reg [31:0]   stl_dma_rd;       // DMA read beats completed (dma_bus_done)
(* keep *) reg [31:0]   stl_dma_wr;       // DMA write beats completed
(* keep *) reg [27:0]   stl_dma_rd_addr;  // address of the last completed DMA read
(* keep *) reg [27:0]   stl_dma_wr_addr;  // address of the last completed DMA write
// Freeze snapshot.
(* keep *) reg [7:0]    f_mem;
(* keep *) reg [15:0]   f_flags;
(* keep *) reg [27:0]   f_dma_addr;
(* keep *) reg [27:0]   f_rom_addr;
(* keep *) reg [31:0]   f_ram;            // {ram_be, ram_addr[27:0]}
(* keep *) reg [23:0]   f_sdaddr;         // mem_addr[25:2]
(* keep *) reg [15:0]   f_rdy_cyc, f_rdy_st, f_st_age, f_st_chg;
(* keep *) reg [15:0]   f_dbgdma;
(* keep *) reg [31:0]   f_dma_rd, f_dma_wr;

// ---------------------------------------------------------------- layout v6
// Control-flow records (core-log entry 42's Next Steps).  Entry 41 answered "is
// the CPU alive" with the stall tail and entry 42 showed the picture is still a
// white field on an overlay-free image, so the open question is no longer whether
// the CPU runs but where it goes and what it does to the display on the way.
//
// Two things are watched here.  The first is the handover: on test_logo.gba the
// CPU is measured inside the cartridge's own blink loop, while Super Mario
// Advance is measured alive in BIOS code after exactly 84 cartridge fetches, and
// the difference between those two is a control-flow transition neither
// instrument could see.  A transition is a completed BIOS-region fetch that
// follows a cartridge fetch, which covers both an ordinary return to the BIOS and
// an exception taken through the 0x00000018 vector -- the case BRD-042 is a lead
// about.  The second is DISPCNT, because the cartridge's `strh 0x0403` is issued
// on the bus (BRD-023, BRD-025) while the register keeps its BIOS value (BRD-022,
// BRD-024), and nothing has yet measured both ends of that chain in one image.
//
// Every record here is sticky: it says "this happened at least once since gbaon",
// never "this is happening now".  That is deliberate.  A live sample of a cycling
// register aliases across frames when the capture and the raster are locked, which
// is BRD-014's and TCL-010's failure mode, and it is what made entry 21's freeze
// reading unsafe (entry 22).  A sticky bit cannot alias.
(* keep *) reg        s_cart_seen;   // a cartridge fetch since the last BIOS fetch
(* keep *) reg        s_xfer;        // a cartridge -> BIOS transition ever happened
(* keep *) reg [7:0]  xfer_n;        // how many, saturating
(* keep *) reg        s_vec8;        // fetched the 0x00000008 vector (SWI)
(* keep *) reg        s_vec18;       // fetched the 0x00000018 vector (IRQ)
(* keep *) reg        s_vec1c;       // fetched the 0x0000001C vector (FIQ)
(* keep *) reg        s_hnd;         // read 0x03FFFFFC, where the IRQ pointer lives
(* keep *) reg [31:0] hnd_val;       // the word found there
(* keep *) reg [7:0]  hnd_n;         // how many such reads, saturating
(* keep *) reg        s_cfc;         // fetched 0x080000FC, the ARM IRQ handler
(* keep *) reg [31:0] bios_fetch;    // BIOS-region instruction fetches
reg         stl_hnd_pend;            // the handler-pointer read's data arrives now

// Register side of the DISPCNT question, latched in clk50 where `gpu_dc` lives so
// this adds no clock-domain crossing.  `gpu_dc` is
// {BLDCNT effect[1:0], BG3, BG2, BG1, BG0, Forced_Blank}, bit 0 first, so the three
// values this cartridge can put DISPCNT in are exact constants:
//   0x0000  forced blank set, every BG off, no effect  -> 7'b0000001
//   0x0403  forced blank clear, BG2 on                -> 7'b0001000
//   0x1F80  forced blank set, BG0..3 on (BIOS handover) -> 7'b0011111
// The first one is the trap: forced blank is active HIGH in bit 7 of DISPCNT, so
// 0x0000 is not the all-clear value and an all-zero compare would have measured
// nothing at all.
(* keep *) reg        s_gpu0;        // drawer saw DISPCNT 0x0000: forced blank, no BGs
(* keep *) reg        s_gpu403;      // drawer saw forced blank clear with BG2 on
(* keep *) reg        s_gpu_bios;    // drawer saw forced blank set with BG0..3 on

always @(posedge clk50) begin
    if (~resetn) begin
        s_gpu0    <= 1'b0;
        s_gpu403  <= 1'b0;
        s_gpu_bios <= 1'b0;
    end else if (~gbaon) begin
        s_gpu0    <= 1'b0;
        s_gpu403  <= 1'b0;
        s_gpu_bios <= 1'b0;
    end else begin
        if (gpu_dc == 7'b0000001) s_gpu0    <= 1'b1;
        if (gpu_dc == 7'b0001000) s_gpu403  <= 1'b1;
        if (gpu_dc == 7'b0011111) s_gpu_bios <= 1'b1;
    end
end

wire stl_fetch  = rom_en & cpu_en & ~halt;                   // a completed fetch
wire stl_fcart  = stl_fetch & (rom_addr[27:24] == 4'h8);     // from the cartridge
wire stl_fbios  = stl_fetch & (rom_addr[27:24] == 4'h0);     // from the BIOS
wire stl_fxfer  = stl_fbios & s_cart_seen;                   // the handover itself
wire stl_fvec8  = stl_fbios & (rom_addr[27:0] == 28'h0000_0008);
wire stl_fvec18 = stl_fbios & (rom_addr[27:0] == 28'h0000_0018);
wire stl_fvec1c = stl_fbios & (rom_addr[27:0] == 28'h0000_001C);
wire stl_fcfc   = stl_fetch & (rom_addr[27:0] == 28'h0800_00FC);
wire stl_hndrd  = ram_cen & ~ram_wen & cpu_en & ~halt &
                  (ram_addr[27:0] == 28'h03FF_FFFC);

// ---------------------------------------------------------------- layout v7
// The literal-pool read (core-log entry 43's Next Steps, BRD-044).  v6 measured
// that the cartridge's second store to DISPCNT carries 0xFFE0 where its source
// says 0x0403, and that the word immediately before 0x0403 in this cartridge's
// literal pool is 0x0000FFE0.  The instruction is `ldr r0, =0x0403` followed by
// `strh r0, [r11]`, so the stored value is whatever that load returned.  One
// measurement decides it, and this block takes it.
//
// The ring also freezes on the read itself, so the capture holds the cycles
// leading into the pool load as well as the value it produced.  The address arm
// checks the region nibble AND an offset inside the 4 KiB image, which is the
// bound TCL-029 requires: the CPU does make out-of-range accesses, and a
// condition testing only the low bits will eventually fire on one.
//
// Three adjacent pool words are recorded rather than one, because the lag this
// tests for is a one-transaction offset: if 0x2E0 returns the word that belongs
// to 0x2DC and 0x2E4 returns the word that belongs to 0x2E0, that is a lag and
// its direction is known.  All three are recorded raw and compared against the
// cartridge image by the host decoder rather than against a constant compiled
// here, because a comparison inside the instrument would have to be trusted to
// be right about the very value it is checking (TCL-024).
wire stl_frd32   = ram_cen & ~ram_wen & cpu_en & ~halt & (ram_be == 4'b1111);
wire stl_fcart32 = stl_frd32 & (ram_addr[27:24] == 4'h8) & ~ram_addr[12];
wire stl_f2dc    = stl_fcart32 & (ram_addr[11:0] == 12'h2DC);
wire stl_f2e0    = stl_fcart32 & (ram_addr[11:0] == 12'h2E0);
wire stl_f2e4    = stl_fcart32 & (ram_addr[11:0] == 12'h2E4);

(* keep *) reg        s_f2dc, s_f2e0, s_f2e4;   // each pool word was read
(* keep *) reg [31:0] v_f2dc, v_f2e0, v_f2e4;   // the word each read returned
(* keep *) reg [7:0]  f2e0_n;                   // reads of 0x080002E0, saturating
(* keep *) reg [3:0]  f2e0_be;                  // byte enables seen on that access
(* keep *) reg [27:0] last_rd32_addr;           // last 32-bit cartridge data read
(* keep *) reg [31:0] last_rd32_data;           // and the word it returned
(* keep *) reg [31:0] prev_rd32_data;           // the word the one before that returned
reg         rd_p_dc, rd_p_e0, rd_p_e4;          // that read's data arrives this cycle
reg         rd_p_c32;                           // a 32-bit cartridge read's data arrives now

wire stl_go   = stl_cyc & ~stl_frz;
// v6 adds the handover to the two time-based triggers rather than replacing them.
// The stall trigger is cheap and entry 41 measured it never fire, and the 8-second
// trigger is what still yields a coherent window for a cartridge that never returns
// to the BIOS at all -- which is exactly what test_logo.gba does.
wire stl_trig = ~stl_frz & (stl_gap[22] | stl_age[27] | stl_fxfer | stl_f2e0);
wire stl_stch = stl_mem_state[2:0] != stl_st_prev;

always @(posedge clk16) begin
    if (~gbaon) begin
        stl_vld     <= 16'd0;
        stl_wp      <= 4'd0;
        stl_full    <= 1'b0;
        stl_pend    <= 1'b0;
        stl_frz     <= 1'b0;
        stl_cause   <= 4'd0;
        stl_gap     <= 32'd0;
        stl_maxgap  <= 24'd0;
        stl_age     <= 28'd0;
        stl_ncyc    <= 32'd0;
        stl_post    <= 32'd0;
        stl_rdy_cyc <= 16'd0;
        stl_rdy_st  <= 16'd0;
        stl_st_age  <= 16'd0;
        stl_st_chg  <= 16'd0;
        stl_st_prev <= 3'd0;
        stl_dma_rd  <= 32'd0;
        stl_dma_wr  <= 32'd0;
        stl_dma_rd_addr <= 28'd0;
        stl_dma_wr_addr <= 28'd0;
        f_mem       <= 8'd0;
        f_flags     <= 16'd0;
        f_dma_addr  <= 28'd0;
        f_rom_addr  <= 28'd0;
        f_ram       <= 32'd0;
        f_sdaddr    <= 24'd0;
        f_rdy_cyc   <= 16'd0;
        f_rdy_st    <= 16'd0;
        f_st_age    <= 16'd0;
        f_st_chg    <= 16'd0;
        f_dbgdma    <= 16'd0;
        f_dma_rd    <= 32'd0;
        f_dma_wr    <= 32'd0;
        s_cart_seen <= 1'b0;
        s_xfer      <= 1'b0;
        xfer_n      <= 8'd0;
        s_vec8      <= 1'b0;
        s_vec18     <= 1'b0;
        s_vec1c     <= 1'b0;
        s_hnd       <= 1'b0;
        hnd_val     <= 32'd0;
        hnd_n       <= 8'd0;
        s_cfc       <= 1'b0;
        bios_fetch  <= 32'd0;
        stl_hnd_pend <= 1'b0;
        s_f2dc      <= 1'b0;
        s_f2e0      <= 1'b0;
        s_f2e4      <= 1'b0;
        v_f2dc      <= 32'd0;
        v_f2e0      <= 32'd0;
        v_f2e4      <= 32'd0;
        f2e0_n      <= 8'd0;
        f2e0_be     <= 4'd0;
        last_rd32_addr <= 28'd0;
        last_rd32_data <= 32'd0;
        prev_rd32_data <= 32'd0;
        rd_p_dc     <= 1'b0;
        rd_p_e0     <= 1'b0;
        rd_p_e4     <= 1'b0;
        rd_p_c32    <= 1'b0;
    end else begin
        // Ring.
        stl_pend <= stl_go;
        if (stl_go) begin
            stl_wp    <= stl_wp + 4'd1;
            if (stl_wp == 4'd15) stl_full <= 1'b1;
            stl_pidx  <= stl_wp;
            stl_pwen  <= ram_wen;
            stl_pwdata <= ram_wdata;
            stl_flat[{stl_wp, 2'd0}*32 +: 32] <= {rom_en, thumb, 2'b00, rom_addr[27:0]};
            stl_flat[{stl_wp, 2'd2}*32 +: 32] <= {ram_cen, ram_wen, ram_be,
                                                  ram_addr[27:24], ram_addr[21:0]};
        end
        if (stl_pend) begin
            stl_flat[{stl_pidx, 2'd1}*32 +: 32] <= rom_data;
            stl_flat[{stl_pidx, 2'd3}*32 +: 32] <= stl_pwen ? stl_pwdata : ram_rdata;
            stl_vld[stl_pidx] <= 1'b1;
        end

        // Gap, age and cycle counts.
        if (~stl_age[27]) stl_age <= stl_age + 28'd1;
        if (stl_cyc) begin
            stl_gap <= 32'd0;
            if (~stl_frz & (stl_gap[23:0] > stl_maxgap)) stl_maxgap <= stl_gap[23:0];
            if (stl_frz) stl_post <= stl_post + 32'd1;
            else         stl_ncyc <= stl_ncyc + 32'd1;
        end else if (~&stl_gap)
            stl_gap <= stl_gap + 32'd1;

        // Memory-controller wait counters.
        stl_st_prev <= stl_mem_state[2:0];
        if (stl_cyc) begin
            stl_rdy_cyc <= 16'd0;
            stl_st_chg  <= 16'd0;
        end else begin
            if (cpu_mem_ready & ~&stl_rdy_cyc) stl_rdy_cyc <= stl_rdy_cyc + 16'd1;
            if (stl_stch & ~&stl_st_chg)      stl_st_chg  <= stl_st_chg + 16'd1;
        end
        if (stl_stch) begin
            stl_st_age <= 16'd0;
            stl_rdy_st <= 16'd0;
        end else begin
            if (~&stl_st_age)                  stl_st_age <= stl_st_age + 16'd1;
            if (cpu_mem_ready & ~&stl_rdy_st)  stl_rdy_st <= stl_rdy_st + 16'd1;
        end

        // DMA beats.
        if (dma_bus_done & dma_rnw) begin
            stl_dma_rd      <= stl_dma_rd + 32'd1;
            stl_dma_rd_addr <= dma_addr;
        end
        if (dma_bus_done & ~dma_rnw) begin
            stl_dma_wr      <= stl_dma_wr + 32'd1;
            stl_dma_wr_addr <= dma_addr;
        end

        // Layout v6: control-flow records.  `s_cart_seen` is set by a cartridge
        // fetch and cleared by a BIOS fetch, so it means "the last instruction the
        // CPU fetched came from the cartridge"; a BIOS fetch while it is set is the
        // handover.  The BIOS runs before any cartridge fetch, so this cannot fire
        // on the boot sequence.
        if (stl_fcart) s_cart_seen <= 1'b1;
        if (stl_fbios) s_cart_seen <= 1'b0;
        if (stl_fxfer) begin
            s_xfer <= 1'b1;
            if (~&xfer_n) xfer_n <= xfer_n + 8'd1;
        end
        if (stl_fvec8)  s_vec8  <= 1'b1;
        if (stl_fvec18) s_vec18 <= 1'b1;
        if (stl_fvec1c) s_vec1c <= 1'b1;
        if (stl_fcfc)   s_cfc   <= 1'b1;
        if (stl_fbios & ~&bios_fetch) bios_fetch <= bios_fetch + 32'd1;
        // The handler pointer's data arrives on the cycle after the completed access,
        // for the same reason the ring samples rom_data a cycle late.
        stl_hnd_pend <= stl_hndrd;
        if (stl_hndrd) begin
            s_hnd <= 1'b1;
            if (~&hnd_n) hnd_n <= hnd_n + 8'd1;
        end
        if (stl_hnd_pend) hnd_val <= ram_rdata;

        // Layout v7: the literal-pool read.  Every value is recorded raw and
        // scored against the cartridge image by the host decoder, never compared
        // against a constant compiled here: a comparison inside the instrument
        // would have to be trusted to be right about the very value it checks,
        // which is TCL-024's lesson.  The three adjacent words plus the two-deep
        // read history give the decoder enough to name a lag and its direction.
        rd_p_dc <= stl_f2dc;
        rd_p_e0 <= stl_f2e0;
        rd_p_e4 <= stl_f2e4;
        if (stl_f2dc) begin s_f2dc <= 1'b1; end
        if (stl_f2e4) begin s_f2e4 <= 1'b1; end
        if (stl_f2e0) begin
            s_f2e0  <= 1'b1;
            f2e0_be <= ram_be;
            if (~&f2e0_n) f2e0_n <= f2e0_n + 8'd1;
        end
        if (rd_p_dc) v_f2dc <= ram_rdata;
        if (rd_p_e4) v_f2e4 <= ram_rdata;
        if (rd_p_e0) v_f2e0 <= ram_rdata;
        // Two-deep history of completed 32-bit cartridge data reads, so the host
        // decoder can see whether the pool read's value came from the transaction
        // before it.  The data is sampled on the cycle after the access, like every
        // other data capture here, so the shift happens on arrival and not on the
        // access cycle.
        rd_p_c32 <= stl_fcart32;
        if (stl_fcart32) last_rd32_addr <= ram_addr[27:0];
        if (rd_p_c32) begin
            prev_rd32_data <= last_rd32_data;
            last_rd32_data <= ram_rdata;
        end

        // Freeze.
        if (stl_trig) begin
            stl_frz    <= 1'b1;
            stl_cause  <= {stl_f2e0, stl_fxfer, stl_age[27], stl_gap[22]};
            f_mem      <= stl_mem_state;
            f_flags    <= stl_flags;
            f_dma_addr <= dma_addr;
            f_rom_addr <= rom_addr[27:0];
            f_ram      <= {ram_be, ram_addr[27:0]};
            f_sdaddr   <= mem_addr;
            f_rdy_cyc  <= stl_rdy_cyc;
            f_rdy_st   <= stl_rdy_st;
            f_st_age   <= stl_st_age;
            f_st_chg   <= stl_st_chg;
            f_dbgdma   <= stl_debug_dma[15:0];
            f_dma_rd   <= stl_dma_rd;
            f_dma_wr   <= stl_dma_wr;
        end
    end
end

// Readout.  `tr_sel` is {page[1:0], entry[2:0], word[1:0]}; page bit 1 picks
// ring slots 8..15.  Combinational from `tr_sel`, as gba2hdmi requires.
wire [3:0]  stl_rslot = {tr_sel[6], tr_sel[4:2]};
wire [31:0] stl_ring_word = stl_flat[{stl_rslot, tr_sel[1:0]}*32 +: 32];
reg  [31:0] stl_word_mux;
always @(*) begin
    stl_word_mux = 32'd0;
    case (tr_sel[6:5])
        2'd0, 2'd2: stl_word_mux = stl_ring_word;
        // Page 1 entries 5..7: the freeze snapshot.  Fixed once frozen.
        2'd1: case (tr_sel[4:0])
                  5'd20: stl_word_mux = {16'h57A3, 2'b00, stl_frz, 1'b0, stl_cause,
                                         3'b000, stl_full, stl_wp};
                  5'd21: stl_word_mux = {f_mem, 8'h00, f_flags};
                  5'd22: stl_word_mux = {4'h0, f_dma_addr};
                  5'd23: stl_word_mux = {4'h0, f_rom_addr};
                  5'd24: stl_word_mux = f_ram;
                  5'd25: stl_word_mux = {6'h00, f_sdaddr, 2'b00};
                  5'd26: stl_word_mux = {f_rdy_cyc, f_rdy_st};
                  5'd27: stl_word_mux = {f_st_age, f_st_chg};
                  5'd28: stl_word_mux = {16'h0000, f_dbgdma};
                  5'd29: stl_word_mux = f_dma_rd;
                  5'd30: stl_word_mux = f_dma_wr;
                  5'd31: stl_word_mux = {8'h00, stl_maxgap};
                  default: stl_word_mux = 32'd0;
              endcase
        // Page 3: live counters.  These move after the freeze; read the second
        // frame after the page changes (TCL-019).
        default: case (tr_sel[4:0])
                  5'd0:  stl_word_mux = stl_ncyc;
                  5'd1:  stl_word_mux = stl_gap;
                  5'd2:  stl_word_mux = stl_post;
                  5'd3:  stl_word_mux = {stl_mem_state, 8'h00, stl_flags};
                  5'd4:  stl_word_mux = {4'h0, stl_dma_rd_addr};
                  5'd5:  stl_word_mux = {4'h0, stl_dma_wr_addr};
                  5'd6:  stl_word_mux = stl_dma_rd;
                  5'd7:  stl_word_mux = stl_dma_wr;
                  5'd8:  stl_word_mux = {stl_rdy_cyc, stl_rdy_st};
                  5'd9:  stl_word_mux = {stl_st_age, stl_st_chg};
                  5'd10: stl_word_mux = {16'h0000, stl_debug_dma[15:0]};
                  5'd11: stl_word_mux = {15'h0000, dma_eepromcount};
                  // Layout v6: the handover and the exception records.
                  5'd12: stl_word_mux = {5'h00, 8'h00, s_cfc, s_hnd, s_vec1c,
                                         s_vec18, s_vec8, 3'b000, s_xfer,
                                         s_cart_seen, 1'b0, hnd_n};
                  5'd13: stl_word_mux = {16'h0000, 8'h00, xfer_n};
                  5'd14: stl_word_mux = bios_fetch;
                  5'd15: stl_word_mux = hnd_val;
                  // Layout v6: the DISPCNT landing chain, register side.
                  5'd16: stl_word_mux = {18'h00000, s_gpu_bios, s_gpu403, s_gpu0,
                                         s_dc, dc403_n};
                  5'd17: stl_word_mux = {24'h0, gpu_dc, 1'b0};
                  5'd18: stl_word_mux = {16'h0000, last_dc_data};
                  5'd19: stl_word_mux = {16'h0000, dc_wr};
                  // Layout v7: the literal-pool read.  Entry 5 is the three words
                  // themselves; entry 6 is the two-deep read history that says
                  // whether the value came from the transaction before it.
                  // Entry 5: the three pool words as the CPU received them.
                  5'd20: stl_word_mux = v_f2e0;
                  5'd21: stl_word_mux = v_f2dc;
                  5'd22: stl_word_mux = v_f2e4;
                  5'd23: stl_word_mux = {4'h0, last_rd32_addr};
                  // Entry 6: the two-deep read history and the flags.
                  5'd24: stl_word_mux = last_rd32_data;
                  5'd25: stl_word_mux = prev_rd32_data;
                  5'd26: stl_word_mux = {17'h0, s_f2dc, s_f2e0, s_f2e4, f2e0_be,
                                         f2e0_n};
                  5'd27: stl_word_mux = {24'h0, v_f2e0[15:8]};
                  default: stl_word_mux = 32'd0;
              endcase
    endcase
end
assign stl_word  = stl_word_mux;
// Valid strip: x 224..231 shows tr_valid[{page[0], entry}].  Pages 0 and 2 show
// which ring slots hold a complete entry; page 1's entries 5..7 show the freeze
// (white once frozen); page 3 marks its three entries.
assign stl_valid = (tr_sel[6:5] == 2'd0) ? {8'h00, stl_vld[7:0]}
                 : (tr_sel[6:5] == 2'd2) ? {8'h00, stl_vld[15:8]}
                 : (tr_sel[6:5] == 2'd1) ? {{3{stl_frz}}, 13'h0000}
                 :                         16'h1F00;
`endif

////////////////////////////
// Timer
////////////////////////////
gba_timer timer (
    .clk(clk16), .gb_on(1'b1), .reset(~gbaon), 
    `GB_BUS_PORTS_INST,
    .IRP_Timer(IRP_Timer),  .timer0_tick(timer0_tick), .timer1_tick(timer1_tick), 
    .debugout0(), .debugout1(), .debugout2(), .debugout3() );


////////////////////////////
// Joypad
////////////////////////////

`ifndef VERILATOR
wire [11:0] joy_btns_gba, joy_btns_iosys, joy_usb1, joy_usb2;
wire [1:0] usb_type;
wire usb_conerr;
wire [11:0] joy_btns;       // (R L X A RT LT DN UP START SELECT Y B)
controller_ds2 ds2 (
    .clk(clk16), .snes_buttons(joy_btns),
    .ds_clk(ds_clk), .ds_miso(ds_miso), .ds_mosi(ds_mosi), .ds_cs(ds_cs) 
);

`ifdef USB1
pll_12 pll12(.clkin(sysclk), .clkout0(clk12), .lock(pll_lock_12));
usb_hid_host usb_hid_host (
    .usbclk(clk12), .usbrst_n(pll_lock_12),
    .usb_dm(usb1_dn), .usb_dp(usb1_dp),
    .typ(usb_type), .conerr(usb_conerr),
    .game_snes(joy_usb1)
);
`else
assign joy_usb1 = 12'b0;
`endif

`ifdef USB2
usb_hid_host usb_hid_host2 (
    .usbclk(clk12), .usbrst_n(pll_lock_12),
    .usb_dm(usb2_dn), .usb_dp(usb2_dp),
    .game_snes(joy_usb2)
);
`else
assign joy_usb2 = 12'b0;
`endif

`else          // VERILATOR
wire [11:0] joy_btns_gba = joy_btns;
`endif

wire [11:0] hid1, hid2;

gba_joypad joypad (
    .mclk(clk16), /*.fclk(clk33),*/ `GB_BUS_PORTS_INST, .IRP_Joypad(IRP_Joypad),
    .KeyA(joy_btns_gba[8]), .KeyB(joy_btns_gba[0]), .KeySelect(joy_btns_gba[2]), .KeyStart(joy_btns_gba[3]), 
    .KeyRight(joy_btns_gba[7]), .KeyLeft(joy_btns_gba[6]), .KeyUp(joy_btns_gba[4]), .KeyDown(joy_btns_gba[5]), 
    .KeyR(joy_btns_gba[11]), .KeyL(joy_btns_gba[10]),
    .cpu_done()
);


////////////////////////////
// Video output
////////////////////////////

`ifndef VERILATOR
// wire overlay = ~s1;      // for debug
//
// TinyGBA: the OSD overlay powers up asserted.  `iosys_bl616`'s overlay_reg is
// initialised to 1 and is only cleared by command 0x08 with x[0]=0, which the
// BL616 menu sends.  With nothing driving that command the overlay stays on
// for ever, and because it owns a 960-pixel-wide window (XSTART_O..XSTOP_O)
// drawn from overlay_color, it hides whatever is in the framebuffer behind an
// empty menu's black.  That is what the first video-proof load showed: a
// locked 720p picture, correctly letterboxed, with the active area exactly
// 960 px wide and uniformly black.
//
// The diagnostic builds exist to read their answer off the screen, so they tie
// the overlay low.  Production keeps the OSD, because the menu is a real
// feature there and the BL616 closes it in normal use.  Two nested `ifdef`s
// rather than one `||` expression: TinySNES found that slang does not evaluate
// `elsif A || B` as written.
`ifdef TINYGBA_VIDEO_TEST
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
`ifdef TINYGBA_SDRAM_TEST
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
// A production build with the overlay suppressed, for bench work: in one-wire
// mode nothing drives the BL616 menu, so the OSD never closes and its 960-wide
// window hides the machine behind an empty menu's black.  Keep the OSD in the
// shipping configuration and take it out only when the machine itself is what
// is being looked at.
`ifdef TINYGBA_OVERLAY_OFF
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
`ifdef TINYGBA_STATUS_TEST
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
`ifdef TINYGBA_PIXTEST
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
`ifdef TINYGBA_FETCHTRACE
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
`ifdef TINYGBA_CLKTEST
  `define TINYGBA_DIAG_OVERLAY_OFF
`endif
wire overlay_iosys;
`ifdef TINYGBA_DIAG_OVERLAY_OFF
wire overlay = 1'b0;
`else
wire overlay = overlay_iosys;
`endif
wire [7:0] overlay_x, overlay_y;
wire [14:0] overlay_color;
reg [5:0] ddr_prefetch_delay;
assign joy_btns_gba = overlay ? 0 : joy_btns | joy_usb1 | joy_usb2 | hid1 | hid2;

`ifdef DDR3_FRAMEBUFFER
gba2hdmi_ddr3 video (       // DDR3-based framebuffer
	.clk27(clk27), .resetn(resetn), .clk_pixel(hclk), 
    .clk(clk50), .pixel_data(pixel_out_data), .pixel_x(pixel_out_x), .pixel_y(pixel_out_y),
    .pixel_we(pixel_out_we),
    .sound_left(sound_out_left), .sound_right(sound_out_right),
    .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
    .freeze(core_config[6]),

    .ddr_addr(ddr_addr), .ddr_bank(ddr_bank), .ddr_cs(ddr_cs), .ddr_ras(ddr_ras), .ddr_cas(ddr_cas),
    .ddr_we(ddr_we), .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n), .ddr_cke(ddr_cke), .ddr_odt(ddr_odt),
    .ddr_reset_n(ddr_reset_n), .ddr_dm(ddr_dm), .ddr_dq(ddr_dq), .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n),

	.tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n),
	.tmds_d_p(tmds_d_p),

    .ddr_prefetch_delay(core_config[5:0]),         // allow adjusting DDR3 prefetch delay
    .init_calib_complete(init_calib_complete)      // 1: ddr3 is ready
);
assign led = ~{joy_usb1[2:0], init_calib_complete, overlay, usb_conerr, usb_type};
`else
gba2hdmi video (            // BRAM-based framebuffer
`ifdef TINYGBA_CLKTEST
	.clk(clk27), .clk27(clk27), .resetn(resetn), .clk_pixel(hclk), .clk_pixel_x5(hclk5),
`else
	.clk(clk50), .clk27(clk27), .resetn(resetn), .clk_pixel(hclk), .clk_pixel_x5(hclk5),
`endif
    .pixel_data(pixel_out_data), .pixel_x(pixel_out_x), .pixel_y(pixel_out_y),
    .pixel_we(pixel_out_we),
    .sound_left(sound_out_left), .sound_right(sound_out_right),
    .dbg_bits(dbg_bits), .dbg_done(dbg_done),
    .tr_sel(tr_sel), .tr_word(tr_word), .tr_valid(tr_valid),
`ifdef TEST_LOADER
    .overlay(0),
`else
    .overlay(overlay), 
`endif
    .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
	.tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n),
	.tmds_d_p(tmds_d_p)
);
`endif

////////////////////////////
// iosys for menu, rom loading and other functions
////////////////////////////

iosys_bl616 #(.CORE_ID(3), .COLOR_LOGO(15'b01111_01100_10101), .FREQ(16_650_000)) iosys (
    .clk(clk16), .hclk(clk50),      // hclk=clk50: goes to framebuffer_ddr3 for overlay
    .resetn(resetn),

    .overlay(overlay_iosys), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
    .core_config(core_config),
    .joy1(joy_btns | joy_usb1 | joy_usb2), .joy2(12'b0),
    .hid1(hid1), .hid2(hid2),

`ifdef TEST_LOADER
    .rom_loading(), .rom_do(), .rom_do_valid(), 
`else
    .rom_loading(loading), .rom_do(loader_do), .rom_do_valid(loader_do_valid), 
`endif

    .uart_tx(UART_TXD), .uart_rx(UART_RXD)
);

`ifdef TEST_LOADER
// test rom, start loading once sdram is ready
test_loader loader (
    .clk(clk16), .resetn(resetn & ~sdram_busy), .loading(loading), .dout(loader_do), 
    .dout_valid(loader_do_valid)
);
`endif

`endif 

// assign led = ~{init_calib_complete, overlay, cartram_dirty_clear, cartram_dirty, config_backup_type, gbaon};

function [3:0] calc_byte_ena (input [1:0] size, input [1:0] addr);
    casez ({size, addr})
    // byte access
    4'b00_??: calc_byte_ena = 1 << addr;
    // half-word
    4'b01_0?: calc_byte_ena = 4'b0011;
    4'b01_1?: calc_byte_ena = 4'b1100;
    // word
    4'b10_??: calc_byte_ena = 4'b1111;
    default: calc_byte_ena = 4'b0;
    endcase
endfunction


endmodule

`undef pproc_bus_gba