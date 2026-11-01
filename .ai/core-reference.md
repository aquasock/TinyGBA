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

- record_id: BRD-002
  kind: BOARD
  topic_id: BRD
  title: "The OSD overlay powers up asserted and hides the framebuffer until the BL616 clears it"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "`iosys_bl616.v` declares `reg overlay_reg = 1;` and drives `overlay` straight from it, so gba2hdmi's overlay input is asserted from configuration onwards and is only cleared by command 0x08 with x[0]=0, which the BL616 menu sends. Nothing in a one-wire bench session sends that command. While asserted, gba2hdmi draws its overlay window -- `XSTART_O` to `XSTOP_O`, which is 960 of the 1280 pixels, centred -- and fills it from `overlay_color`, which is zero until the menu writes it. The result is a locked, correctly letterboxed 720p picture whose active area is exactly 960 pixels of black, whatever the framebuffer contains."
  consequence: "A black screen at 960 pixels wide is the overlay and says nothing about the video path or the machine; a black screen at 1080 pixels is the video window with an empty framebuffer. The two are distinguishable by width alone, which is the quickest read on the capture card. Diagnostic builds must suppress the overlay to show their own answer, and both `TINYGBA_VIDEO_TEST` and `TINYGBA_SDRAM_TEST` now do through nested ifdefs; `TINYGBA_OVERLAY_OFF` suppresses it in an otherwise production build for bench work. Keeping the OSD in the shipping configuration means a standalone load of the core shows that black window until a menu command arrives."
  sources:
    - "This repository, fpga/gba/src/iosys/iosys_bl616.v: `reg overlay_reg = 1;`, `assign overlay = overlay_reg;`, and the 0x08 command handler"
    - "This repository, fpga/gba/src/gba2hdmi.sv: the `XSTART_O`/`XSTOP_O` window and the `overlay_color` mux"
    - "Bench captures at /tmp/v2 and /tmp/v3, 2026-10-31, measured by pixel run-length along y=360"
  verification: "Observed on the board 2026-10-31: the video-proof image before the fix showed black from x=160 to x=1119, exactly 960 pixels, and the same image after the fix showed bars across 1080 pixels from x=100 to x=1179. The production image showed the 960-pixel black window as expected."

- record_id: BRD-003
  kind: BOARD
  topic_id: BRD
  title: "The video path is proven on the board; the SDRAM data path is not, and the machine therefore does not run"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "With the overlay suppressed, `TINYGBA_VIDEO_TEST` draws eight full-height bars in the order and colours its code specifies across a 1080-pixel active area centred in the letterbox, with the 16x16 top-left marker measuring 72 by 72 pixels at the 4.5 scale. That establishes the PLL and divider topology, all four `INS_LOC` placements, the OSER10 serialiser path and both TMDS pairs on hardware for the first time in this port. `TINYGBA_SDRAM_TEST` reaches `done` -- its status band is green -- but only two of sixteen patterns read back correctly: bars 0 and 1 green, bars 2 to 15 red, the low die failing five of its own eight and the high die failing all eight. The probe writes full 32-bit words with `cpu_be` 4'b1111, so the failure is in the read path and not the write width. The pattern set is walking ones in the low byte followed by multi-bit patterns, which cannot say which bits fail: bits 0 and 4 are known to read back and the rest is unlocalised. A production build with the overlay suppressed draws a uniformly black 1080-pixel active area, so the GBA GPU produces no output, consistent with work RAM and cartridge space living in the SDRAM while only the BIOS is in block RAM."
  consequence: "The video chain is no longer a suspect in any later failure and the diagnostic images can be trusted to show what they claim. The SDRAM is now the blocking fault for the machine, and it must be re-probed with a pattern set that walks every data bit and every address bit individually so a failure names a lane rather than a bar. Any claim that the machine boots, or that the BIOS, timers, saves or GPU work, is unsupported until the SDRAM reads back correctly."
  sources:
    - "Bench captures /tmp/v1, /tmp/v2 and /tmp/v4, 2026-10-31, decoded by pixel run-length and per-bar colour sampling"
    - "This repository, fpga/gba/diag/sdram_probe.v: the eight-pattern list, `cpu_be <= 4'b1111`, and the 32-bit readback compare"
  verification: "Observed on the board 2026-10-31 across three separate loads: the video pattern decoded bar by bar, the SDRAM probe decoded bar by bar over nine consecutive frames with no variation between them, and the machine build captured over twelve frames with no non-black pixel in the active area."

- record_id: TCL-005
  kind: TOOLCHAIN
  topic_id: TCL
  title: "Three PLL clock-plane sources are reachable, one per CLKOUT0 on the right and CLKOUT0/CLKOUT2 on the left"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "The GW5AST-138C database carries 24 clock-plane wires named `T[LR]PLL<n>CLK<lane>`, four lanes on each of six left- and right-edge PLL sites, and the DCS tiles consume all 24 as sources. The vendor routes a PLL output onto the plane through the wire whose lane number matches the output number: `CLKOUT0` to lane 0 and `CLKOUT2` to lane 2. Measured with two vendor builds on a `PLL` at `PLL_L[0]`: with `CLKOUT0` and `CLKOUT2` both enabled and each clocking a fourteen-bit register bank, the bitstream drives `(54,93) SPINE8 <= TLPLL0CLK0` and `(54,93) SPINE10 <= TLPLL0CLK2` at once; with `CLKOUT0` disabled and only `CLKOUT2` enabled it still drives `SPINE8 <= TLPLL0CLK2`, clocking 48 `GB00` sinks. apicula carried only the two lane-0 pips until 2026-10-31, when `(0, 'CLKOUT2') -> 'TLPLL0CLK2'` was added to `_gw5a_pll_clk_wires`; the right-edge sites still have only their lane-0 pip modelled. `CLKOUT1` has no plane wire in the database at all and no vendor build has been made to test it."
  consequence: "This design uses exactly three global clocks and they now occupy the three modelled sources: `clk50` on `pll33`'s `CLKOUT0` at `PLL_R[0]` (`TRPLL0CLK0`), and `clk16` and `clk67` sharing `pll16` at `PLL_L[0]` on `CLKOUT0` and `CLKOUT2` (`TLPLL0CLK0`, `TLPLL0CLK2`). That is possible because the two clocks share a VCO: 1809 MHz is 108 x 16.75 and 27 x 67. A fourth global clock would need either the unmodelled right-edge lane 2 or a measured answer on `CLKOUT1`, and calling a clock unfixable without checking which lane its output owns is the mistake that cost this project three cycles."
  sources:
    - "apicula `GW5AST-138C.msgpack.xz`: `tiles[*].pips`, and after the change the single added entry under tile type 74"
    - "Vendor builds 2026-10-31: `/tmp/oracle_clk67` (CLKOUT0+CLKOUT2) and `/tmp/oracle_c2only` (CLKOUT2 only), both unpacked with `apycula.gowin_unpack`"
    - "apicula fork commit `495661a`, `apycula/chipdb.py`"
  verification: "Measured 2026-10-31. On the design, `clk67` went from 255 failed dedicated routes and 1.2 to 1.9 ns of skew on general routing, with three clean seeds of six, to zero failed routes and zero hold violations on all eight seeds tried, `clk67` Fmax 125 to 141 MHz against 67.0. The regenerated chipdb was diffed against its predecessor: one pip added, none removed, no other tile field changed, and only the `TLPLL0CLK2` node changed, to merge the PLL tile wire at (27,1) with the bridge wire at (54,93). Not yet confirmed that this repairs the SDRAM readback; no image has been loaded since."

- record_id: TCL-006
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A three-bit bar index truncates the eighth video-test bar back to the first"
  status: VERIFIED
  verified_date: 2026-10-31
  statement: "`TINYGBA_VIDEO_TEST`'s colour function declares `reg [2:0] bar;` and computes `bar = x / 8'd27;` for a 240-pixel-wide framebuffer. Source x 216 to 239 divides to 8, which does not fit three bits and truncates to 0, so the last 23 source pixels take the `3'd0` case and draw red. The bars otherwise run red, green, blue, white, yellow, cyan, magenta, grey. At the 4.5 horizontal scale of the 1080-pixel video window, 23 source pixels is 104 display pixels, and the capture shows a 104-pixel red band at the right edge where the grey should continue."
  consequence: "The picture is otherwise correct and the band is an instrument defect, not a video fault; it should not be read as a colour or addressing error in the core. Widen the index to four bits, or size the bars so the last one never overflows, before drawing any conclusion from the right-hand edge of that pattern."
  sources:
    - "This repository, fpga/gba/src/gba2hdmi.sv: the `TINYGBA_VIDEO_TEST` colour function"
    - "Bench capture /tmp/v1/f05.png, 2026-10-31: run-length along y=400 shows grey 954-1069 then red 1074-1177"
  verification: "Measured on the board 2026-10-31: the arithmetic predicts a 104-pixel band and the capture measures 104 pixels, and the other seven bars land where the scale predicts."

---
