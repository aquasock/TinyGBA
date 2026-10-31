// SPDX-License-Identifier: GPL-3.0-only
//
// Behavioural replacements for Gowin primitives that GBATang's generated IP
// instantiates in bulk and that nextpnr-himbaechel can neither place nor need.  tools/build_tinygba.sh strips both modules from the cell-library shim, so
// these definitions are the ones that bind.
//
// Why this exists.  GBATang's Gowin-generated IP instantiates primitives that
// Gowin EDA maps to dedicated BELs:
//
//   MUX2   2307 instances: 960 in gpu/vram_lo.v, 648 in fb.v, 448 in
//          gpu/vram_hi.v, 224 in memory/mem_iwram.v, 27 in memory/mem_eeprom.v.
//          nextpnr-himbaechel has almost no MUX2 BELs on this device: TinySNES
//          (TCL-005) hit "no BELs remaining to implement cell type MUX2" on
//          GW5AST-138C with *eight* of them in one module, and expressed those
//          as ternary selects instead.
//
//   LUT5   38 instances, all in fb.v.  oss-cad-suite's cells_xtra_gw5a.v
//          declares `module LUT5` with no body at all, so the cell survives
//          synthesis with no logic and the placer fails with "no BELs remaining
//          to implement cell type 'LUT5'" -- which is what happened on the
//          first place-and-route run of this port.
//
// Neither primitive is special.  MUX2 in cells_sim.v is exactly
// `assign O = S0 ? I1 : I0;`, and LUT5 is a 5-input lookup against a 32-bit INIT,
// which is the standard Gowin semantic.  Written this way yosys infers ordinary
// LUT4s plus the device's own MUX2_LUT5 packing, and the placer never sees a bare
// LUT5.  The transformation is semantic, not a workaround: 2307 two-input muxes
// and 38 five-input functions are well inside the device's 138,240 LUT4.
//
// This is a toolchain shim, not vendored IP: it is this project's own file and it
// is listed in THIRD_PARTY.md as such.

module MUX2 (O, I0, I1, S0);

  input  I0, I1;
  input  S0;
  output O;

  assign O = S0 ? I1 : I0;

endmodule

module LUT5 (I0, I1, I2, I3, I4, F);

  parameter [31:0] INIT = 32'h0000_0000;

  input  I0, I1, I2, I3, I4;
  output F;

  wire [4:0] I = {I4, I3, I2, I1, I0};

  assign F = INIT[I];

endmodule
