// SPDX-License-Identifier: GPL-3.0-only
//
// 16.75 MHz GBA main clock: 27 * 67 / 108, the same point pll_33's CLKOUT1
// used to carry, moved to a PLL whose *first* output drives it.
//
// Why a second PLL.  A PLL output reaches the global clock spine only through
// a clock-plane wire (`T[LR]PLL<n>CLK<lane>`), and this device's database gives
// only CLKOUT0 such a pip: CLKOUT1..CLKOUT6 connect no further than the
// tile-local `F1..F6`/`CLK1`/`CLK2` lanes.  On pll33's CLKOUT1, clk16 reached
// none of its 2381 sinks on global resources; nextpnr routed it as 2381
// point-to-point arcs whose skew (-5.38 ns at worst, into `mem_bios`'s BSRAM
// CLKA) failed hold on all 24 placements tried.  pll33's own CLKOUT0 plane
// wire already carries clk50, so clk16 gets its own site: PLL_L[0], whose
// CLKOUT0 owns the plane wire `TLPLL0CLK0`, pinned in fpga/gba/tinygba.cst.
//
// clk67 rides the same PLL on CLKOUT2, because the two clocks share a VCO:
// 1809 = 108 x 16.75 = 27 x 67.  CLKOUT2 reaches the plane on lane 2
// (`TLPLL0CLK2`) exactly as CLKOUT0 does on lane 0, which was measured against
// the vendor flow; CLKOUT3 is the off-chip SDRAM clock and keeps the 16/7
// phase shift pll_33 gave it.
//
// Do not move these outputs back to pll33, and do not connect CLKOUT1: it has
// no plane wire and no amount of placement will give it one.
module pll_16 (clkout0, clkout2, clkout3, clkin);
output clkout0;
output clkout2;
output clkout3;
input  clkin;
wire lock, c1,c2,c3,c4,c5,c6,c7, clkfbout;
wire gw_vcc, gw_gnd;
assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;
PLL #(
    .FCLKIN("27"), .IDIV_SEL(1), .FBDIV_SEL(1),
    .MDIV_SEL(67), .MDIV_FRAC_SEL(0),
    .ODIV0_SEL(108), .ODIV0_FRAC_SEL(0),
    .ODIV1_SEL(8), .ODIV2_SEL(27), .ODIV3_SEL(27),
    .ODIV4_SEL(8), .ODIV5_SEL(8), .ODIV6_SEL(8),
    .CLKOUT0_EN("TRUE"), .CLKOUT1_EN("FALSE"), .CLKOUT2_EN("TRUE"), .CLKOUT3_EN("TRUE"),
    .CLKOUT4_EN("FALSE"), .CLKOUT5_EN("FALSE"), .CLKOUT6_EN("FALSE"),
    .CLKFB_SEL("INTERNAL"),
    .CLKOUT0_DT_DIR(1'b0), .CLKOUT0_DT_STEP(0),
    .CLKOUT0_PE_COARSE(0), .CLKOUT0_PE_FINE(0),
    .CLKOUT2_PE_COARSE(0), .CLKOUT2_PE_FINE(0),
    .CLKOUT3_PE_COARSE(16), .CLKOUT3_PE_FINE(7)
) PLL_inst (
    .LOCK(lock), .CLKOUT0(clkout0), .CLKOUT1(c1), .CLKOUT2(clkout2), .CLKOUT3(clkout3),
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
