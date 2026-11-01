# TinyGBA clocks on the Tang Console 138K.
# SPDX-License-Identifier: GPL-3.0-only
#
# Adapted from GBATang's src/gbatang.sdc (nand2mario).  That file declares the
# main clocks with create_generated_clock and then relaxes four clock-domain
# crossings with set_multicycle_path, which nextpnr-himbaechel's SDC parser
# cannot express: it rejects create_generated_clock, get_clocks, -waveform and
# /// comments outright, and set_multicycle_path is unusable because it cannot
# name its clocks (TinySNES TCL-002, inherited here as TCL-004).  Every clock is
# therefore declared flat with create_clock and its own period, derived from the
# PLL divider values in fpga/gba/src/pll/, and the crossings stay at the
# conservative single-cycle assumption.  That over-constrains rather than
# under-constrains; if the SDRAM paths fail timing this is where to look.
#
#   pll_27   50 MHz    -> 50 * 27 / 50  = 27.000 MHz   (clk27, HDMI reference)
#   pll_33   27 MHz    -> 27 * 67 / 36  = 50.250 MHz   (clk50, GPU)
#                       27 * 67 / 108 = 16.750 MHz     (clk16, GBA CPU / mclk)
#                       27 * 67 / 27  = 67.000 MHz     (clk67, SDRAM)
#   pll_12   50 MHz    -> 50 * 18 / 75  = 12.000 MHz   (clk12, USB HID)
#   pll_hdmi 27 MHz    -> 27 * 55 / 4   = 371.250 MHz  (hclk5, serialiser)
#   div5     371.25    -> / 5           = 74.250 MHz   (hclk, 720p pixel clock)

create_clock -name sysclk -period 20.000 [get_ports {sysclk}]

# 27 MHz reference for the HDMI PLL.
create_clock -name clk27 -period 37.037 [get_pins {pll27.PLL_inst/CLKOUT0}]

# GBA main clock, 16.75 MHz.  The GPU samples this clock's phase, and the SDRAM
# controller needs exactly four of these per SDRAM clock.
create_clock -name clk16 -period 59.701 [get_pins {pll16.PLL_inst/CLKOUT0}]

# GPU clock, one clk16 in three.
create_clock -name clk50 -period 19.900 [get_pins {pll33.PLL_inst/CLKOUT0}]

# SDRAM clock, one clk16 in four.  O_sdram_clk is this clock's phase-shifted
# sibling (CLKOUT3), which is not constrained separately: it leaves the FPGA.
create_clock -name clk67 -period 14.925 [get_pins {pll16.PLL_inst/CLKOUT2}]

# USB HID host clock.
create_clock -name clk12 -period 83.333 [get_pins {pll12.PLL_inst/CLKOUT0}]

# HDMI: 371.25 MHz serialiser bit clock and the 74.25 MHz 720p pixel clock.
create_clock -name hclk5 -period 2.694 [get_nets {hclk5}]
create_clock -name hclk -period 13.468 [get_nets {hclk}]

# GBATang's own file also cuts one path outright, from the VRAM instance to the
# SDRAM: "no paths from VRAM to SDRAM".  nextpnr accepts set_false_path, but the
# cut is only sound while code is never executed from VRAM, so it is left out
# here for the first build.  If the VRAM<->SDRAM paths fail timing, restoring it
# is a decision to make with evidence, not a default.
