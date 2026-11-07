// SPDX-License-Identifier: GPL-3.0-only
//
// The GBA clock family: clk50, clk67 and clk16 from one VCO, as upstream
// GBATang's pll_33 made them.  27 * 67 = 1809 MHz, and 1809 = 36 x 50.25 =
// 27 x 67 = 108 x 16.75, so every output divides the same loop.
//
// Why one PLL.  GBATang crosses between these clocks with no synchronisers:
// the GPU samples clk16 as data on clk50 (`mclk & ~mclk_r` in gba_gpu.v and
// gba_gpu_timing.v) and times its IRQ and DMA pulses into clk16 from that
// sample, the CPU reads VCOUNT and DISPSTAT that the GPU writes on clk50, and
// the SDRAM controller finds the clk16 edge on clk67 the same way.  All of it
// assumes a fixed phase between the clocks.  Two PLLs fed by one reference
// are frequency-locked but not phase-locked: each output divider starts on
// its own, so the clk16/clk50 phase was different on every configuration
// load while this port had them on pll16 and pll33 (core-log entry 23).
//
// Output assignment.  A PLL output reaches the global clock spine only
// through a clock-plane wire (`T[LR]PLL<n>CLK<lane>`), and this device's
// database has one for CLKOUT0 and CLKOUT2 only (core-reference TCL-001).
// The two clocks with thousands of sinks take those: clk50 on CLKOUT0
// (`TLPLL0CLK0`) and clk16 on CLKOUT2 (`TLPLL0CLK2`).  clk67, with about 255
// sinks in the SDRAM controller, takes CLKOUT1 and reaches them on general
// routing, which every image flashed before 2026-11-02 also did and which
// the hold gate checks.  CLKOUT3 is the off-chip SDRAM clock and keeps the
// 16/7 phase shift pll_33 gave it.  The site, PLL_L[0], is pinned in
// fpga/gba/tinygba.cst.
//
// Do not split these outputs across two PLLs again to win a plane wire.
module pll_16 (clkout0, clkout1, clkout2, clkout3, clkin, lock);
output clkout0;
output clkout1;
output clkout2;
output clkout3;
input  clkin;
output lock;          // read only by the TINYGBA_CLKTEST diagnostic
wire c2,c3,c4,c5,c6,c7, clkfbout;
wire gw_vcc, gw_gnd;
assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;
PLL #(
    .FCLKIN("27"), .IDIV_SEL(1), .FBDIV_SEL(1),
    .MDIV_SEL(67), .MDIV_FRAC_SEL(0),
    .ODIV0_SEL(36), .ODIV0_FRAC_SEL(0),
    .ODIV1_SEL(27), .ODIV2_SEL(108), .ODIV3_SEL(27),
    .ODIV4_SEL(8), .ODIV5_SEL(8), .ODIV6_SEL(8),
    .CLKOUT0_EN("TRUE"), .CLKOUT1_EN("TRUE"), .CLKOUT2_EN("TRUE"), .CLKOUT3_EN("TRUE"),
    .CLKOUT4_EN("FALSE"), .CLKOUT5_EN("FALSE"), .CLKOUT6_EN("FALSE"),
    .CLKFB_SEL("INTERNAL"),
    .CLKOUT0_DT_DIR(1'b0), .CLKOUT0_DT_STEP(0),
    .CLKOUT0_PE_COARSE(0), .CLKOUT0_PE_FINE(0),
    .CLKOUT1_PE_COARSE(0), .CLKOUT1_PE_FINE(0),
    .CLKOUT2_PE_COARSE(0), .CLKOUT2_PE_FINE(0),
    .CLKOUT3_PE_COARSE(16), .CLKOUT3_PE_FINE(7)
) PLL_inst (
    .LOCK(lock), .CLKOUT0(clkout0), .CLKOUT1(clkout1), .CLKOUT2(clkout2), .CLKOUT3(clkout3),
    .CLKOUT4(c4), .CLKOUT5(c5), .CLKOUT6(c6), .CLKFBOUT(clkfbout),
    .CLKIN(clkin), .CLKFB(gw_gnd), .RESET(gw_gnd), .PLLPWD(gw_gnd),
    .RESET_I(gw_gnd), .RESET_O(gw_gnd),
    .FBDSEL(6'b0), .IDSEL(6'b0), .MDSEL(7'b0), .MDSEL_FRAC(3'b0),
    .ODSEL0(7'b0), .ODSEL0_FRAC(3'b0), .ODSEL1(7'b0), .ODSEL2(7'b0), .ODSEL3(7'b0),
    .ODSEL4(7'b0), .ODSEL5(7'b0), .ODSEL6(7'b0),
    .DT0(4'b0), .DT1(4'b0), .DT2(4'b0), .DT3(4'b0),
    .ICPSEL(6'b0), .LPFRES(3'b0), .LPFCAP(2'b0), .PSSEL(3'b0),
    .PSDIR(gw_gnd), .PSPULSE(gw_gnd),
    .ENCLK0(gw_vcc), .ENCLK1(gw_vcc), .ENCLK2(gw_vcc), .ENCLK3(gw_vcc),
    .ENCLK4(gw_vcc), .ENCLK5(gw_vcc), .ENCLK6(gw_vcc),
    .SSCPOL(gw_gnd), .SSCON(gw_gnd), .SSCMDSEL(7'b0), .SSCMDSEL_FRAC(3'b0)
);
endmodule
