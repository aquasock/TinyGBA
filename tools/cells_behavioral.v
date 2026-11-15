// SPDX-License-Identifier: GPL-3.0-only
//
// Behavioural replacements for Gowin primitives that GBATang's generated IP
// instantiates in bulk and that nextpnr-himbaechel can neither place nor need.
// tools/build_tinygba.sh strips both modules from the cell-library shim, so
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
//   LUT5   formerly needed for 38 instances, all in fb.v, which used it to
//          decode its nineteen bank selects.  fb.v has since been replaced by
//          fb_ram, which writes that decode as ordinary Verilog, so nothing in
//          the tree instantiates LUT5 any more and the definition below was
//          removed.  It is recorded here because the reason it existed is easy
//          to rediscover the hard way: oss-cad-suite's cells_xtra_gw5a.v
//          declares `module LUT5` with no body at all, so a bare LUT5 survives
//          synthesis with no logic and the placer fails with "no BELs remaining
//          to implement cell type 'LUT5'" -- which is what happened on the
//          first place-and-route run of this port.  If a future change
//          reintroduces a LUT5 instantiation, this definition has to come back.
//
// Neither primitive was special.  MUX2 in cells_sim.v is exactly
// `assign O = S0 ? I1 : I0;`, and LUT5 was a 5-input lookup against a 32-bit
// INIT, which is the standard Gowin semantic.  Written this way yosys infers
// ordinary LUT4s plus the device's own MUX2_LUT5 packing, and the placer never
// sees a bare LUT5.  The transformation is semantic, not a workaround: 2307
// two-input muxes and 38 five-input functions were well inside the device's
// 138,240 LUT4.
//
// Only MUX2 remains supplied here.  Removing `fb.v` in TCL-073 removed the last
// LUT5 instantiation in the tree, and the definition had to go with it: the
// strip in build_tinygba.sh and this definition were a pair, and with nothing
// instantiating the cell, leaving both in place made yosys pull in the real
// library copy and collide with this one.
//
// This is a toolchain shim, not vendored IP: it is this project's own file and it
// is listed in THIRD_PARTY.md as such.

module MUX2 (O, I0, I1, S0);

  input  I0, I1;
  input  S0;
  output O;

  assign O = S0 ? I1 : I0;

endmodule

// (LUT5 definition removed with fb.v -- see the note above.)

