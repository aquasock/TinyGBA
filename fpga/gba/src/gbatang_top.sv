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
// TinyGBA: clk16 and clk67 share pll16 on PLL_L[0].  A PLL output reaches the
// global clock spine only through a clock-plane wire (`T[LR]PLL<n>CLK<lane>`),
// and the lane number follows the output number: CLKOUT0 uses lane 0, CLKOUT2
// uses lane 2.  clk16 was on pll33's CLKOUT1, which has no plane wire at all,
// so it reached none of its 2381 sinks globally and nextpnr fell back to 2381
// point-to-point arcs whose -5.38 ns of skew failed hold on all 24 placements
// tried; clk67 on CLKOUT2 had the same defect at 255 sinks and 1.2 to 1.9 ns,
// and cost several clean seeds on every netlist change.
//
// Both now sit on one PLL because they share a VCO: 1809 = 108 x 16.75 =
// 27 x 67, so CLKOUT0 divides to 16.75 MHz and CLKOUT2 to 67.00 MHz from the
// same loop.  clk50 keeps pll33, which owns the other plane wire, and pll33's
// second and third outputs are left unconnected on purpose.  See
// fpga/gba/src/pll/pll_16.v and .ai/core-reference.md TCL-001.
wire clk16_unused, clk67_unused, clk67p_unused;
pll_33 pll33(.clkin(clk27), .clkout0(clk50), .clkout1(clk16_unused),
             .clkout2(clk67_unused), .clkout3(clk67p_unused));
pll_16 pll16(.clkin(clk27), .clkout0(clk16), .clkout2(clk67), .clkout3(clk67_p));
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
// TinyGBA: the pixel clock, divided from the 5x serialiser clock.  `div5` is
// pinned to RIGHTSIDE[4] in fpga/gba/tinygba.cst; left to the placer it lands in
// block 0, from where the pixel clock does not route to the OSER10s.
CLKDIV #(.DIV_MODE("5")) div5 (
    .CLKOUT(hclk),              // 74.25Mhz
    .HCLKIN(hclk5),
    .RESETN(resetn),
    .CALIB(1'b0)
);
`endif
wire gbaon;         // this is resetn signal for everything gba except memory (needed by iosys)

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
`ifdef TINYGBA_STATUS_TEST
wire [3:0]  gpu_dbg;        // GPU timing generator internals, see gba_gpu_timing.v
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
    .cpu_ready(cpu_mem_ready), .cpu_rdata(cpu_mem_rdata),
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
        if (cpu_mem_ready)       st_mem_ready_fast <= 1'b1;
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
    else         st_gpu_step <= st_gpu_step | gpu_dbg;
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
assign dbg_bits      = 16'h0000;
assign dbg_done      = 1'b0;
`endif
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
`ifdef TINYGBA_STATUS_TEST
    , .DBG_gt(gpu_dbg)
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
wire        cpu_mem_ready;
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
    .gbaon(gbaon), .config_backup_type(config_backup_type),
    .cartram_dirty(cartram_dirty), .cartram_dirty_clear(cartram_dirty_clear),

    // Interface to GPU to access special memory like VRAM, OAMRAM, PALETTE
    .vram_lo_addr(vram_lo_addr), .vram_lo_din(vram_lo_din), .vram_lo_dout(vram_lo_dout), 
    .vram_lo_we(vram_lo_we), .vram_lo_be(vram_lo_be), 
    .vram_hi_addr(vram_hi_addr), .vram_hi_din(vram_hi_din), .vram_hi_dout(vram_hi_dout), 
    .vram_hi_we(vram_hi_we), .vram_hi_be(vram_hi_be), 
`ifdef TINYGBA_SDRAM_DEBUG
	.dbg_state(mem_dbg_state), .dbg_loader_writes(mem_dbg_lw), .dbg_loader_writing(mem_dbg_lwr),
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
    .cpu_ready(cpu_mem_ready), .cpu_port(cpu_mem_port),
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
	.cpu_ready(cpu_mem_ready), .cpu_port(cpu_mem_port),
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
    .cpu_ready(cpu_mem_ready), .cpu_port(cpu_mem_port), 
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
    .dma_bus_done(dma_bus_done), .dma_bus_unread(), .debug_dma()
);

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
	.clk(clk50), .clk27(clk27), .resetn(resetn), .clk_pixel(hclk), .clk_pixel_x5(hclk5),
    .pixel_data(pixel_out_data), .pixel_x(pixel_out_x), .pixel_y(pixel_out_y),
    .pixel_we(pixel_out_we),
    .sound_left(sound_out_left), .sound_right(sound_out_right),
    .dbg_bits(dbg_bits), .dbg_done(dbg_done),
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