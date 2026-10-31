# TINYGBA TECHNICAL REFERENCE

Authoritative record store for hardware and toolchain facts this project has
measured. `.ai/core.md` directs that anything that could be considered a
standard, a conformance rule or a specification be looked up here before it is
looked up online, and that a fact added here be a record rather than a belief.

Every record below was derived from this repository, from a tool run in this
workspace, or from a vendor build made on this machine. A record is not written
from recollection or from another project's prose without saying so.

Field meanings:

- `record_id` — `TCL-nnn` toolchain, `DEV-nnn` device, `BRD-nnn` board.
- `status` — `VERIFIED` (observed end to end), `MEASURED` (a number read out of
  a tool or a bitstream, but the consequence not yet seen on hardware),
  `LEAD` (a hypothesis with evidence, explicitly not a finding).
- `sources` — where the statement comes from, precise enough to re-derive.

---

- record_id: TCL-001
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A PLL output reaches the clock spine only from CLKOUT0 on the GW5AST-138C"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "A PLL output enters the global clock network through a clock-plane wire named `T[LR]PLL<n>CLK<lane>`. The GW5AST-138C database carries 24 such wires, four lanes on each of the six left- and right-edge PLL sites, and the DCS tiles at P26A/B/C/D, P27A/D, P16A/D, P17A/D, P36/37 and P46/47 plus the LWT and LWB sites consume all 24 as sources. Only two pips in the whole database drive one, and both are from the first output: `MPLLCLKOUT0 -> TLPLL0CLK0` on tile type 74 (left-edge sites, X1Y27 and X1Y81) and `MPLLCLKOUT0 -> TRPLL0CLK0` on tile type 77 (right-edge sites, X177Y27, X178Y45, X178Y63 and X177Y81). `CLKOUT1` through `CLKOUT6` have pips only to the tile-local `F1`..`F6` lane wires, which reach nothing above the `CLK1`/`CLK2` hops. A secondary PLL output therefore cannot clock a wide domain on this device, by database construction and not by placer choice."
  consequence: "Put a clock that must reach many sinks on a PLL's `CLKOUT0`, and pin that PLL to a site whose plane wire is unused. On this board `pll33` at `PLL_R[0]` owns `TRPLL0CLK0` for `clk50`; `pll16` at `PLL_L[0]` owns `TLPLL0CLK0` for `clk16`; `PLL_R[2]`'s only wire is the one `clk50` holds, so it is not a spare for a second global clock. `NPNR_GOWIN_CLK_FIRST` cannot help a clock with no plane pip, because priority was never the constraint."
  sources:
    - "apicula `GW5AST-138C.msgpack.xz`, `tiles[*].pips`: the only two entries naming a `PLL0CLK` wire as a destination"
    - "apicula `GW5AST-138C.msgpack.xz`, `tiles[*].clock_pips`: 3258 PLL-plane entries, all PLL plane wire -> bridge/spine"
    - "nextpnr-himbaechel fork `himbaechel/uarch/gowin/globals.cc`: `is_pll_plane_wire` and `global_pip_filter`, which admit a PLL output to a spine only through such a wire"
  verification: "Measured on this netlist 2026-10-31: on `pll33.CLKOUT1` `clk16` reached 0 of 2381 sinks on global resources and nextpnr reported 2381 failed dedicated routes from `MPLLCLKOUT1`; on `pll16.CLKOUT0` at `PLL_L[0]` the log reads `'clk16' net was routed using global resources partially` and there are no `clk16` hold violations at any of six seeds."

- record_id: TCL-002
  kind: TOOLCHAIN
  topic_id: TCL
  title: "apicula refuses to pack an unmeasured PLL operating point, and FVCO 1809 MHz is now measured"
  status: MEASURED
  verified_date: 2026-10-31
  statement: "The vendor derives four PLL attributes from the operating point rather than reading them off the cell: `FLDCOUNT`, `KVCO`, `A_ICP_SEL` and `A_LPF_RES_SEL`. apicula's model in `gw5ast138c_pll_pump.py` is a fit over 45 vendor bitstreams spanning `Fpfd` 19 to 50 MHz and `FVCO` 650 to 1300 MHz, and outside that wedge it raises `PllPumpUnmeasured` instead of extrapolating, with the three already-known above-band points in `MEASURED_ABOVE_BAND`. GBATang's plan has no in-band option at all: `clk16` 16.75, `clk50` 50.25 and `clk67` 67.00 MHz all carry the prime 67, so a common `FVCO` is a multiple of 201, and the only `Fpfd` values inside the measured band are 27, 25 and 50 MHz, which are coprime to 67, so no configuration is simultaneously in band for `Fpfd` and `FVCO`. A vendor build of `pll_33`'s point (`Fpfd` 27, `MDIV` 67, `ODIV0/1/2` 36/108/27, `FVCO` 1809) warns `PA1019` that the VCO is outside 650 to 1300 MHz and produces a bitstream anyway, and that bitstream encodes `FLDCOUNT` 16, `A_ICP_SEL` 240, `A_LPF_RES_SEL` R4 and `KVCO` 7. The ladder would have answered R5 with 137. This continues the pattern the other three above-band points show: above the fitted band the vendor stays on R4 and lets the current rise with `FVCO` rather than stepping the resistor."
  consequence: "`MEASURED_ABOVE_BAND` in the apicula fork carries `(27.0, 1809.0): (16, 240, 4)`. The gate is a measurement table, not a policy: a new GBA clock plan on a different `Fpfd`/`FVCO` needs its own oracle run before it will pack. The vendor flow accepts these points, so `PA1019` is a warning to read and not a refusal to obey."
  sources:
    - "apicula fork `apycula/gw5ast138c_pll_pump.py`: `MEASURED_ABOVE_BAND`, `pump()`, and the module docstring recording the 45-run fit"
    - "Gowin EDA 1.9.11.03 `gw_sh`, built 2026-10-31 against `GW5AST-LV138PG484AC1/I0` device version C: `PA1019` warning and completed bitstream"
    - "That bitstream unpacked with `apycula.gowin_unpack.parse_attrvals` at grid (27,1), tile type 74"
  verification: "Read back out of the vendor bitstream 2026-10-31. The apicula-packed bitstream was then unpacked the same way and gives 16/240/R4 for both `pll16` and `pll33`, and 32/190/R4 and 16/190/R4 for `pll27` and `pll_hdmi`, so the new point agrees with the oracle and the two pre-existing measured points survive unchanged. Not yet confirmed on hardware: no image has been loaded."

- record_id: TCL-003
  kind: TOOLCHAIN
  topic_id: TCL
  title: "`defparam` on a blackboxed Gowin primitive delivers string parameters as raw ASCII"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "The vendored Gowin IP wrappers `pll_27.v` and `pll_33.v` set their parameters with `defparam PLL_inst.FCLKIN = \"27\";`. Because `PLL` is passed to the build as a blackboxed module, the elaboration leaves those string parameters in the netlist as the bytes of the string rather than as a string: `FCLKIN` `\"27\"` reaches the packer as `'0011001000110111'` (0x3237) and `CLKOUT0_EN` `\"TRUE\"` as `'01010100010100100101010101000101'` (0x54525545). The packer then fails with either `The 11001000110111.0MHz frequency is outside the permissible range` or `KeyError: '01010100010100100101010101000101'`. Writing the same values as `PLL #(.FCLKIN(\"27\"), ...)` parameters avoids it, which is what the hand-written `gowin_pll_hdmi.v` already did."
  consequence: "Any vendor-generated IP wrapper carried into this build must be converted from `defparam` to parameter style, or every string parameter it sets is mangled. The symptom names the packer or a nonsense frequency, not the netlist, so the cause is easy to misattribute."
  sources:
    - "This repository, `fpga/gba/src/pll/pll_27.v` and `pll_33.v` before and after the conversion"
    - "`build/diag_video/tinygba-routed.json` before the fix: `FCLKIN` values `'0011001000110111'` and `'0011010100110000'`"
    - "apicula `gowin_pack.py`, `get_pll_attrvals` and `get_pll_attr_val`"
  verification: "Observed 2026-10-31: the pack failed on the ASCII values, and succeeded unchanged once both files used `#(...)` parameters. The unpacked result confirms the values arrived as `A_MDIV_SEL` 27 and 67, `A_ODIV0_SEL` 50 and 36, i.e. the intended dividers."

- record_id: TCL-004
  kind: TOOLCHAIN
  topic_id: TCL
  title: "Placement seeds are not interchangeable for this netlist: clk67 hold failures are seed-dependent"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "On the fixed netlist, seeds 1, 3, 4 and 5 place and route with zero hold violations, while seed 2 gives two and seed 6 gives four, all on `posedge clk67` with about -1.18 ns of clock skew into `sdram.*` registers and `clk67` still missing dedicated routing on all 255 of its sinks from `MPLLCLKOUT2`. The same six seeds all route `clk16` on global resources with no `clk16` violations, so the seed sensitivity is in the `clk67` domain and not in the one this cycle fixed. TinySNES records the same behaviour for its main domain, seed 1 with 53 hold violations and seed 9 the first clean placement, and TinyNES records it for its fabric-routed bus clock."
  consequence: "A clean build must name its seed, and a seed that is clean for one netlist is not clean for the next, so a sweep is normal and must be repeated when the netlist changes. Seed 1 is the seed the three images in this cycle were built with."
  sources:
    - "This repository, six-seed sweep at `TINYGBA_STAGE=pnr`, 2026-10-31"
    - "TinySNES `.ai/core-log.md` entry 1: seed 1 gave 53 hold violations and seed 9 was the first clean placement"
  verification: "Measured 2026-10-31 over seeds 1 to 6: `clk16` global at every seed with zero `clk16` violations; `clk67` violations 0, 2, 0, 0, 0, 4."

- record_id: BRD-001
  kind: BOARD
  topic_id: BRD
  title: "The HDMI serialiser bit clock must be wired to the OSER10 FCLK, and pll_74's removal left it dangling"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "When `pll_74` was replaced by the single-output `gowin_pll_hdmi` wrapper plus `CLKDIV` `div5`, the 371.25 MHz serialiser clock was never reconnected: `gba2hdmi.sv` kept `hdmi(.clk_pixel_x5(clk_5x_pixel))` while the declaration of `clk_5x_pixel` was commented out with the removed instantiation. Synthesis then produced three `OSER10` serialisers with both `FCLK` and `Q` unconnected, and the pack failed with `KeyError: 'IOLOGIC_FCLK'` because nextpnr only sets that attribute on a user reached from an FCLK net. The repair is the shape TinySNES records in TCL-006: carry `clk_pixel_x5` in as an input and drive it from `hclk5`, the PLL's 371.25 MHz output, exactly as `snes2hdmi.v` takes `input clk_5x_pixel` and `snestang_top.v` binds `.clk_5x_pixel(hclk5)`."
  consequence: "A `TINYGBA_VIDEO_TEST` image built from the tree before this fix would have drawn a black screen for a reason unrelated to the FPGA video path, which is the one failure the proof image exists to rule out. Keep `clk_pixel_x5` connected to `hclk5`; the serialisers have no other clock source."
  sources:
    - "This repository, `fpga/gba/src/gba2hdmi.sv` and `fpga/gba/src/gbatang_top.sv` before and after the fix"
    - "`build/diag_sdram/tinygba-routed.json` before the fix: three `IOLOGIC_DUMMY` aux cells with `MAIN_CELL` pointing at `OSER10` cells whose `FCLK` and `Q` connections were empty"
    - "TinySNES `.ai/core-reference.md` TCL-006 and its `fpga/snes/src/snes2hdmi.v`, `fpga/snes/src/snestang_top.v`"
  verification: "Observed 2026-10-31: the pack stopped at `IOLOGIC_FCLK` before the fix and completed after it, and the final netlist's serialiser cells are connected. Not yet confirmed on hardware: no image has been loaded."

---
