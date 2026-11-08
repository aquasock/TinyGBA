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
- record_id: TCL-007
  kind: TOOLCHAIN
  topic_id: TCL
  title: "This flow honours `(* keep *)` and ignores all three Gowin comment-attribute spellings"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "Gowin EDA marks a net or port as must-keep with an attribute written inside a comment: `/* synthesis syn_keep=1 */`, `/* synthesis keep */`, or the variant `/* xxsynthesis syn_keep=1 */` that GBATang uses on `gba_memory.sv`'s CPU port list. `read_slang --std 1800-2017` does not parse any of the three, so they arrive at the netlist as ordinary comments. Measured on this flow 2026-11-02 with five identically shaped nets in one module, four carrying an attribute and one plain: after `read_slang` then `synth_gowin -family gw5a`, only the `(* keep *)` net and its whole adder cone survived; the three comment-attribute nets and the plain net were all deleted. The attribute also has to precede the declaration -- `input a (* keep *)` is a syntax error under slang and fails elaboration with `port 'a' does not exist`, so the form is `(* keep *) input a`. A keep on a port whose value no one consumes restores that port's entire driving cone: measured on a two-output module where only one output reached the top level, the kept port kept twelve named nets and the unkept one kept none."
  consequence: "Every Gowin comment attribute in the vendored tree is inert, so the synthesiser was free to restructure the signals they were written to protect. Counted 2026-11-02: 113 `synthesis syn_keep=1`, 2 `syn_preserve` and 2 `xxsynthesis` occurrences across 14 files, of which the ones on `gba_memory.sv`'s port list sit on the machine's instruction-fetch path. Converting them to `(* keep *)` is a change of auditability, not of behaviour: the netlist has the same 4734 flip-flops and the same 322 undriven wires before and after, and the cell count moves a few percent because ABC sees a different optimisation boundary. Do not describe the conversion as a fix for a fault. The remaining 99 comment attributes outside `gba_memory.sv` are still inert and are recorded as an open item rather than converted in the same cycle."
  sources:
    - "This repository, `fpga/gba/src/memory/gba_memory.sv` before and after the conversion, and its comment recording the measurement"
    - "`tools/gatelevel_report.py`, added this cycle, which reports per named net whether it exists and whether every bit has a driver"
    - "Test modules at /tmp/keeptest and /tmp/keepport, 2026-11-02, run through `read_slang --std 1800-2017 --single-unit` plus `synth_gowin -family gw5a`"
  verification: "Measured 2026-11-02 on this flow. Two full syntheses of the design, one from the tree as committed and one from a copy with only `gba_memory.sv` changed: `tools/gatelevel_report.py` reports 0 of 13 fetch-path names present in the first and 13 of 13 present and fully driven in the second, at honest widths. The logic is unchanged between them, by the flip-flop count, the undriven-wire set and the warning output."

- record_id: TCL-008
  kind: TOOLCHAIN
  topic_id: TCL
  title: "nextpnr prints its hold-violation count only when it is non-zero, so a clean build has no such line"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "nextpnr-himbaechel prints `Info: N Hold/min time violations (showing 10 worst paths):` followed by `ERROR: Hold/min time violation for clock '<name>':` only when N is greater than zero. A build with no hold violation contains no line matching `[0-9]+ Hold/min time violations` anywhere in its log. Measured across the logs in this repository 2026-11-02: `build/prod/nextpnr.log` carries `Info: 1 Hold/min time violations`, and `build/p67s2`, `build/p67s3`, `build/n_machine` and all five seeds of the 2026-11-02 sweep carry no match at all. The sweep helper `tools/sweep_tinygba_seeds.sh` records `hold=$(grep -oE '[0-9]+ Hold/min time violations' ...)` and then prints `${hold:-0}`, which is correct, but a reader taking the absence of the line as a missing measurement would be wrong."
  consequence: "A clean placement has no hold line, so a build gate that greps for the line and refuses on a match is sound, and one that requires the line to be present would refuse every clean seed. State the convention in any new tool rather than leaving it to be rediscovered: absence of the line means zero violations, and the Fmax report is the only timing output guaranteed to be present."
  sources:
    - "This repository, `build/prod/nextpnr.log` (one violation) against `build/n_machine`, `build/p67s2`, `build/p67s3` and `build/c6_sweep/s3` through `s8` (none)"
    - "`tools/sweep_tinygba_seeds.sh`: the `hold=$(grep ...)` expression and its `${hold:-0}` default"
  verification: "Read from the logs in this repository 2026-11-02, by grepping every nextpnr log present for `Hold/min time violations` and confirming the only match belongs to a log that also carries the matching `ERROR: Hold/min time violation` line."

- record_id: BRD-004
  kind: BOARD
  topic_id: BRD
  title: "A clock can pass the hold check and the Fmax gate while crossing no clock-plane bridge pip at all"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "A routed netlist records each clock net's route in `netnames[<clock>].attributes.ROUTING`, and a clock that reaches the global network carries pips of the form `SPINE<n>/CBRIDGEOUT_<half><k>` in that string. A clock routed point to point to its sinks carries none. Measured 2026-11-02 on the routed netlists of the four images staged in `build/deploy`: `clk16`, `clk50` and `hclk` cross bridge pips in all four, and `clk67` crosses none in any of them -- the exact condition that `clk67`'s fix in core-log entry 4 removed, still present in every image this project has flashed. Both the hold check and the Fmax gate passed on all four. The mechanism is that a clock on general routing is still checked for hold against its own skew and still reports an Fmax, so neither gate can see that the clock never entered the global network. On the post-fix tree built 2026-11-02, all five clean seeds place `clk67` on `SPINE27/TOP2` and `clk67` reports 208 to 256 MHz against a 67 MHz constraint; `clk16` lands on `SPINE{1,2,18,20,26,28}/TOP3`, which this board has never measured, with 15 failed dedicated routes at every seed, and the log reads `'clk16' net was routed using global resources partially` rather than `only`."
  consequence: "A hold-clean build that passes Fmax is not evidence that its clocks reached the global network, so a deploy decision taken on those two gates alone can ship an image whose clock is on general routing. `tools/clock_plane_report.py` now reads this out of the routed netlist and `tools/build_tinygba.sh` fails on a dead pip or on a required clock crossing no pip. The gate cannot yet require a measured-good path, because `clk16` sits on unmeasured pips at every seed tried; that is recorded rather than rounded off, and `TINYGBA_CLOCK_PLANE_STRICT=1` makes it refuse. The `TOP2` pips that drew the verified video picture (core-log entry 5) are the only ones this project has measured for `clk16`, and no build since has used them."
  sources:
    - "`tools/clock_plane_report.py`, added this cycle, and `build/deploy/SHA256SUMS` matched to `build/*/tinygba.fs` by digest to find each deployed image's routed netlist"
    - "This repository, `build/vsweep_5/`, `build/psweep_2/`, `build/machine_s5/` and `build/diag_sdram_s2/` routed netlists, all four matching a deployed digest"
    - "This repository, `build/c6_sweep/s3` through `s8` clock-plane logs and nextpnr logs, 2026-11-02"
  verification: "Measured 2026-11-02 from the routed netlists themselves rather than from build timestamps: the four deployed digests were resolved to their build directories, and each netlist's clock routes were parsed for bridge pips. The `clk67` fix of core-log entry 4 was confirmed present in the post-fix builds (`clk67` Fmax 125 to 141 MHz then, 208 to 256 MHz now) and absent from every deployed image."

---
- record_id: TCL-009
  kind: TOOLCHAIN
  topic_id: TCL
  title: "nextpnr cannot express GBATang's multicycle paths, so its timing verdict is wrong in both directions"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "nextpnr-himbaechel's SDC parser implements exactly six commands -- `get_ports`, `get_cells`, `get_nets`, `get_pins`, `create_clock` and `set_false_path` -- and rejects anything else with `Unsupported SDC command`. `set_multicycle_path` is not implemented at all, and `set_false_path` logs `set_false_path from: X, to: Y does not do anything(yet)` and returns without changing the analysis. Every path is therefore timed as a single cycle. Upstream GBATang's `gbatang.sdc` depends on the opposite: its comment `# sdram.cpu_dout through the CPU back to sdram: 4 cycles` heads `set_multicycle_path 4 -setup -end -from [get_pins {sdram/cpu_rdata*/*}] -to [get_clocks {clk67}]`, and it relaxes `clk16`-to-`clk67` and `clk67`-to-`clk16` by four and `clk16`-to-`clk50` by three. Those allowances are correct for the design and not a hack: one `clk16` period is exactly four `clk67` periods, so a path that leaves an SDRAM register, crosses logic clocked at `clk16` and returns to a `clk67` register has four `clk67` cycles of budget, 59.70 ns, not 14.92 ns."
  consequence: "A single-cycle analysis can fail a design that meets its own contract, and it can also pass one that does not: cross-clock paths never appear in the Fmax report, so `--timing-allow-fail` lets a slow `clk16`-to-`clk67` path through with no measurement at all. Measured on this design 2026-11-02: the worst `clk67`-to-`clk67` path in the `TINYGBA_OVERLAY_OFF` machine configuration is 29.77 ns from `cpu_mem_rdata_DFFRE_Q_34` to `sdram.SDRAM_BA_DFFRE_Q`, which is exactly upstream's documented readback case and clears 59.70 ns by a factor of two, while the same build's cross-domain paths are 40.13 and 39.84 ns, also inside 59.70. nextpnr reported 33.59 MHz against 67.00 and refused the build. `tools/timing_gate.py` now judges the build instead: it holds every path to a single cycle except the four documented pairs, requires both endpoints of the readback allowance so an unrelated slow path cannot borrow it, gates the hold count, and prints every relaxation it applies with the upstream line it came from."
  sources:
    - "nextpnr fork `common/kernel/sdc.cc`: the `evaluate` command dispatch and `cmd_set_false_path`'s no-op warning, read 2026-11-02"
    - "tangcore `gbatang/src/gbatang.sdc` at commit `77fd0714`, the constraint file this port replaced"
    - "This repository, `tools/timing_gate.py` and `build/c6_machine_ok/timing-gate.log`"
  verification: "Measured 2026-11-02. The gate was checked against five builds: the machine configuration it was written for passes with one printed relaxation; the same tree without the define passes with none; the SDRAM-probe build at seed 5 passes with none; `build/prod`, which has one hold violation, fails on hold; and two mutation tests on a copy of the machine build's `timing.json` -- moving the 29.77 ns path's source to an unrelated register, and lengthening the `clk16`-to-`clk67` path past 59.70 ns -- both fail as they must. Not yet confirmed on hardware: no image has been loaded."

- record_id: BRD-005
  kind: BOARD
  topic_id: BRD
  title: "The machine configuration's timing failure was the analysis, not the design"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "The `TINYGBA_OVERLAY_OFF` machine configuration failed nextpnr's Fmax gate on `clk67` at all six seeds tried, 33.6 to 36.0 MHz against 67.00, and the failure survived every control that would have implicated a change: the tree as it stood before the cycle's edits, synthesised fresh and routed at seed 5, gave 38.76 MHz; the same tree without the define gave 171.26 MHz at the same seed with a 5.84 ns `clk67`-to-`clk67` path; and the Oct 31 netlist re-routed at seed 5 gave 154.01 MHz. The logic was not restructured either -- the combinational depth into `sdram.SDRAM_BA_DFFRE_Q_D` is 57 in both configurations, and `mem.rom_data` is depth 11 against 12. What differs is only which same-domain path is worst: without the define, `clk67`-to-`clk67` is 5.84 ns and the 39.66 ns worst path is `clk67`-to-`clk16`, which never enters the Fmax figure; with the define, the readback path `cpu_mem_rdata` -> `sdram.SDRAM_BA` becomes the worst at 29.77 ns and does enter it. That path is the one upstream GBATang's `gbatang.sdc` documents as a four-cycle path (TCL-009)."
  consequence: "The configuration was never broken and the six failing seeds were not bad seeds. The design meets its own contract, and the gate that refused it was measuring every path as a single cycle because nextpnr cannot express multicycle paths. The concrete consequence for the next cycle is that a machine image now exists to put a cartridge on: `build/c6_machine_ok/tinygba.fs`, SHA-256 `2ebaaf33b338f39df0fbfdee0cf4dfe8b072a73a828713adcd05f9c476363ad7`, seed 5, zero hold violations, and the only relaxation applied is the documented readback one. This does not make the design fast enough on silicon -- it makes the measurement correct. A hardware reading from it is the only thing that can confirm the allowance is sound in practise."
  sources:
    - "This repository, `build/c6_machine_ok/timing-gate.log` and `build/c6_machine_ok/nextpnr.log`"
    - "This repository, `build/c6_msweep/s1` through `s6` and the controls at `/tmp/keepab/ab_machine_s5`, `/tmp/ab2/ndef_s5` and `/tmp/ab2/nml_s5`"
    - "tangcore `gbatang/src/gbatang.sdc` at `77fd0714`"
  verification: "Measured 2026-11-02 by full builds: six seeds of the failing configuration, one unmodified-tree control, one without-the-define control and one re-routed Oct 31 netlist, plus a full end-to-end build of the machine image with the corrected gate that reached a bitstream. Not yet confirmed on hardware: the image has not been loaded."

- record_id: BRD-006
  kind: BOARD
  topic_id: BRD
  title: "The board's SDRAM is fully good: 64 MiB, both dies, all sixteen probe patterns"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "The `TINYGBA_SDRAM_TEST` image built at seed 5, SHA-256 `aa3455c066a75bada619fbd380151f624a94057cb288877ff0b9b642161e591f`, draws a green status band and sixteen green bars, with the probe's own grey margin beyond x=232 as the only non-green area. That is the probe's full pass: `done` has been reached and every one of the sixteen patterns read back correctly, eight on the low die and eight on the high. The grey block at the right edge is the display's `x >= 232` margin, not a failed bar. Two earlier readings are superseded. Core-log entry 3 read two green and fourteen red, and entry 5 read eight red on the high die and attributed it to the probe sampling a cycle before the data arrived; both were taken from images whose `clk67` crossed no clock-plane bridge pip at all (BRD-004), and neither had the corrected probe on the board. An attempted flash of this same image earlier in the session produced a screen identical to the machine image, which was the silent-load failure of BRD-003 rather than a result: the probe writes its bars from its own raster and cannot be influenced by the GPU, the CPU or the cartridge, so it cannot legitimately show the machine's black field."
  consequence: "SDRAM is out of the machine's failure path entirely. Work RAM, cartridge space and the two-die single-CS question are all settled: the module gives the full 64 MiB and the die select works, so no cartridge size is excluded and no memory fault can explain a machine that does not run. Any future diagnosis of the black framebuffer must look at the boot path instead -- whether the loader released the CPU, whether the CPU fetched, and whether the GPU ever wrote a pixel -- and must not re-test the memory. It also means a `TINYGBA_SDRAM_TEST` flash that shows the previous image's picture is a failed load, not a probe failure, and the correct response is to reload before drawing any conclusion."
  sources:
    - "This repository, `build/c6_sweep/s5/tinygba.fs` and its `build.log`, `clock-plane.log` and `timing-gate.log`"
    - "Board capture reported by the operator 2026-11-02: green band, sixteen green bars, grey margin"
    - "This repository, `fpga/gba/src/gba2hdmi.sv`: the `TINYGBA_SDRAM_TEST` colour function and its `x < 8'd232` bar region"
  verification: "Observed on the board 2026-11-02 after a fresh load onto a rebooted console, with the image rebuilt from the current tree so that `clk67` sits on `SPINE27/TOP2` and both gates pass. The first flash attempt in the same session did not take and showed the machine's picture; the reload showed the probe's own."

- record_id: BRD-007
  kind: BOARD
  topic_id: BRD
  title: "The machine runs the official BIOS, halts once, and never enables the interrupt that would release it"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "Measured on the board with `TINYGBA_STATUS_TEST` and the official GBA BIOS supplied by the operator (`boot.rom`, SHA-256 `fd2547724b505f487e6dcb29ec2ecff3af35a841a77ab2e85fd87350abd36570`, kept out of this repository), with a logo-bearing test cartridge streamed at the core's UART. The probe word reads `0x016E` under field map `a089dde1`: the GPU scanline counter advances, a VBlank period arrives, an HBlank period arrives, the CPU is halted, a halt has been seen exactly once since reset, halt has never gone low again, the CPU has never fetched any address at or above 2 MB, and the DISPSTAT V-Blank IRQ enable is clear. The halt address was latched separately and read `rom_addr[13:2]` index `0x0D1`, byte address `0x344`, which disassembles in the official BIOS to `e5cc3301 strb r3, [ip, #769]` with `ip` = `0x04000000`, i.e. the write to `HALTCNT` at `0x04000301`. Three of these are independent instruments agreeing: a live DISPSTAT status flag, a sticky fetch-region OR, and a latched halt address."
  consequence: "The display path, the SDRAM, the clock plan and the GPU raster are all excluded from the machine's failure, and the fault is one register write that never happens: `halt` clears on any `IRPFlags` bit, `IRPFlags[0]` is set by `IRP_VBlank`, and `IRP_VBlank` is gated by `DISPSTAT`'s V-Blank IRQ enable, which only the CPU can write. A CPU that halts before writing it can never be released, which is a closed loop rather than a hang. The next instrument is to latch `gb_bus_adr` and `gb_bus_din` at the first write to `0x04000004`, which separates 'the write never executes' from 'the write executes and does not reach the GPU'. Do not re-test memory, raster or clocks; all three are measured. Note the sample-versus-latch caveat: the IRQ-enable bit is read live at one instant per frame, so a transient enable would be missed, though a permanently halted CPU makes that unlikely."
  sources:
    - "This repository, `build/c6_final/tinygba.fs` (SHA-256 `e615e69e8cb6da27a0120992297cb00f5fb9b3e5c256f47602667e3bdad9cde0`) and `build/c6_final/clock-plane.log`, `timing-gate.log`"
    - "`tools/probe_map.py` field map `a089dde1`, which generated both the RTL packing and the decode"
    - "Official GBA BIOS at `/run/media/vash/MiSTer_Data/games/GBA/boot.rom`, disassembled with the ARM GNU toolchain's `objdump -b binary -m armv4t`"
  verification: "Measured on the board 2026-11-02 across three separate builds of the probe, with `halt_entries` and the halt address stable between them. The halt address was cross-checked by disassembly rather than assumed. Not yet measured: whether the BIOS writes `0x04000004` at all."

- record_id: TCL-010
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A diagnostic probe's field order must be generated from one list, because a width check cannot catch a wrong order"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "A probe that packs several fields into one bus and a host script that decodes them are two independent statements of the same layout, and they drifted repeatedly in this family of projects: the sibling SNES port mis-stated a field position in four consecutive cycles (its core-log entries 60 to 63), and this project made the same class of error three times in one session -- a reversed bar order that bit-reversed a displayed address, a field read from the wrong bit index, and a multi-byte count read MSB-first from an LSB-first field. Every one produced a plausible number rather than an error, and each was caught only because some other field had a known expected value. An elaboration-time width assertion catches a wrong total but cannot catch a wrong order. The fix is one declarative field list that generates both halves: `tools/probe_map.py` emits `fpga/gba/src/probe_bits.vh` (bit offsets, widths and the packing macro) and decodes captures from the same list, and `tools/build_tinygba.sh` refuses a build whose include does not match the list. The width guard measures `$bits` of the packing expression rather than restating the generator's arithmetic, and it was verified by comparing against a deliberately wrong constant and watching elaboration fail with `unknown module` -- slang rejects `$error` and yosys drops a blackboxed module silently, so an unknown module is the only reliable elaboration-time failure on this flow."
  consequence: "Any diagnostic that shows more than one field must generate its packing and its decoder from one list before a reading is taken. A generated decoder still cannot be trusted against a capture from a different layout, because two layouts may use the same bar for different fields -- which happened here when bar 3 changed from the VBlank IRQ enable to the HBlank flag between builds -- so the list also carries a short id, emitted into the RTL as `PROBE_MAP_ID` and printed by the decoder. Decode by tool, never by hand, and record the map id with any hardware result."
  sources:
    - "This repository, `tools/probe_map.py` and the generated `fpga/gba/src/probe_bits.vh`"
    - "TinySNES `.ai/core-log.md` entries 60 to 63, which record four consecutive field-position errors and the correction that inverted entry 62's conclusion"
    - "Elaboration behaviour measured 2026-11-02 in `/tmp/memtest`: `$bits` resolves under `read_slang`, and an instantiated unknown module is a hard error"
  verification: "Measured 2026-11-02. The generated decoder reproduced a hand decode on the same capture; the width guard was verified to fail a build by deliberately mismatching the bus width; and the first hardware reading taken through the generated path (`word 0x016E`) agreed with three independent instruments."

- record_id: TCL-011
  kind: TOOLCHAIN
  topic_id: TCL
  title: "`synth_gowin` folds an undriven wire used in a condition to constant 1, and deletes the logic behind it"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "A wire that is read but never assigned does not become 0 under this flow's `synth_gowin`.  Measured 2026-11-02 with a minimal reproducer: `wire gb_bus_rst;` used as `if (gb_bus_rst) q <= 0; else if (en) q <= din;` folds the wire to constant 1, makes the reset branch unconditional, and the synthesiser deletes the write branch, leaving `q` driven by a single GND cell.  The full design behaved the same way at scale: `gba_memory`'s `gb_bus_rst` output is read by every `eProcReg_gba` instance as `if (gb_bus_rst) Dout_buffer <= register.def;` and is assigned nowhere, in this tree or in upstream GBATang at `77fd0714`, so the vendor flow must tie it low.  With it undriven this flow produced 4,631 flip-flops; with `assign gb_bus_rst = 1'b0;` the same source produced 9,100.  Roughly 4,500 registers -- every MMIO register in the machine -- had been deleted, and the design still elaborated, placed, routed, passed Fmax, passed the hold check and packed a bitstream.  `yosys` does warn `Wire ... is used but has no driver`, and those warnings are the only signal the flow gives."
  consequence: "A design ported from Gowin EDA cannot assume an undriven wire is 0.  Any wire that appears in a condition must be driven explicitly before the open flow will reproduce vendor behaviour, and the way to find them is the `has no driver` warning set rather than reading the RTL.  This is the third instance of the class in this project family: TinySNES lost two cycles to the same fold on an undriven `PAL` register and again on `GSU_TURBO`.  Crucially, no simulation can detect this: Verilator treats an undriven wire as 0, so the model behaves correctly while the bitstream does not, and the fold *is* the difference between them.  Use `tools/synth_parity.py` to compare a netlist's register population against a recorded baseline, and treat a large loss as this fault until proved otherwise."
  sources:
    - "Minimal reproducer at `/tmp/memtest/rst.v`, 2026-11-02: `read_slang` then `synth_gowin -family gw5a`, output `q` driven by GND"
    - "This repository, `fpga/gba/src/memory/gba_memory.sv` and `fpga/gba/src/common/eprocreg_gba.sv:41`"
    - "tangcore `gbatang/src/` at `77fd0714`: `grep -rnE 'gb_bus_rst *[<=]'` finds no assignment"
  verification: "Measured 2026-11-02.  Full syntheses of the same source, differing only in the added `assign gb_bus_rst = 1'b0;`: 4,631 flip-flops before, 9,100 after, with block RAM unchanged at 66 DPB instances in both.  The Verilator model boots a retail cartridge both before and after the fix, since it already treated the wire as 0."

- record_id: BRD-008
  kind: BOARD
  topic_id: BRD
  title: "The machine's halt was every MMIO register being deleted by synthesis, not an interrupt fault"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "The reason the board halted in the BIOS and never woke is that `gb_bus_rst` (TCL-011) folded high, so no MMIO register could hold a value the CPU wrote.  This explains every hardware reading in core-log entries 8 to 10 without exception: the probe saw writes to `0x04000004` carrying `din[3]`, to `0x04000200` and to `0x04000208`, while the live `DISPSTAT` V-Blank IRQ enable stayed 0, because the register that would hold it did not exist in the netlist.  `IRP_VBlank` therefore could never assert, `IRPFlags` could never set, `halt` could never clear, and the CPU stayed halted on the `HALTCNT` write at `0x344` that the halt-address latch identified.  The GPU raster was never at fault: VBlank and HBlank status flags and the scanline counter are set unconditionally by `mclk`-domain and `fclk`-domain logic and were measured working.  The SDRAM was never at fault: sixteen green bars.  The distinguishing evidence is that the same RTL boots a retail cartridge in Verilator, where an undriven wire is 0 and the registers therefore work."
  consequence: "Every hardware measurement taken before this fix describes a machine whose registers were all absent, and conclusions drawn from register-dependent observations -- the DISPSTAT enable, IE, IME, and anything read back from an MMIO address -- must be re-taken on a build that contains them.  Conversely the measurements that do not involve MMIO writes stand: SDRAM contents, the raster flags, the halt address, and the fetch-region history.  The immediate next step is to build and run the fixed design on the board with the status probe, expecting `vblank_irq_en` to assert and `halt_cleared` to set, which would be the first time the BIOS has ever proceeded past its boot halt on this port."
  sources:
    - "This repository, core-log entries 8, 9 and 10: the probe readings, the halt address `0x344`, and the simulation comparison"
    - "This repository, `build/c6_fixed/tinygba.fs`, SHA-256 `5cfea671aa842c4169ceed0a5fa4b675b066744b64a215c80202185875b194d3`, the first machine build containing all 9,100 registers"
    - "`tools/synth_parity.py` and `tools/synth_baseline.json`, which make the register population a build gate"
  verification: "Measured 2026-11-02 by synthesis: 4,631 registers without the fix and 9,100 with it, both from identical sources otherwise, and the defect reproduced in isolation.  Not yet confirmed on hardware: the fixed image has been built and gated but not deployed."

- record_id: BRD-009
  kind: BOARD
  topic_id: BRD
  title: "The halt clears: the board executes its boot halt loop for the first time"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "The image built with `gb_bus_rst` driven low (`build/c6_fixed/tinygba.fs`, SHA-256 `5cfea671aa842c4169ceed0a5fa4b675b066744b64a215c80202185875b194d3`, 9,100 registers against the previous 4,631) reads `0xFFFE` on the status probe under field map `1dce3f01`: `DISPSTAT`'s V-Blank IRQ enable asserts, `halt` clears after being seen, and the halt counter saturates at 15, where the previous build entered exactly one halt and never left it.  The rest of the reading is unchanged and consistent -- the scanline advances, VBlank and HBlank arrive, writes to `0x04000004`, `0x04000200` and `0x04000208` all occurred, and `halt` is live at the sampled instant, which is expected because the BIOS spends most of a frame between VBlanks halted.  The CPU has still not fetched from the cartridge (`rom_addr[27:24]` non-zero has never been seen), and two readings eight seconds apart are identical."
  consequence: "The MMIO register path works on hardware, and the BIOS's boot halt loop runs and is released -- the first time this port has executed past that halt.  Entries 8 to 10 measured a machine with no writable registers and their register-dependent conclusions are superseded; their non-MMIO findings (SDRAM contents, raster flags, halt address, fetch-region history) stand.  The remaining fault is now past the halt, in the path from the BIOS to the cartridge: the machine has run at least fifteen complete halt-and-wake cycles and still never reached `0x08000000`, which is the next thing to isolate.  That question belongs in the simulator, where every fetch is visible, rather than in another probe: the board has now given the same six-bar answer twice."
  sources:
    - "This repository, `build/c6_fixed/tinygba.fs` and its `parity.log`, `clock-plane.log`, `timing-gate.log`"
    - "Board capture of the `TINYGBA_STATUS_TEST` probe, decoded with `tools/probe_map.py --decode`, map id `1dce3f01`"
    - "This repository, `fpga/gba/src/memory/gba_memory.sv`: the `assign gb_bus_rst = 1'b0;` that produced the difference"
  verification: "Observed on the board 2026-11-02 across two captures eight seconds apart, both identical.  The probe's own field map generated both the RTL packing and the decode, so the bar interpretation is not hand-read."

- record_id: BRD-010
  kind: BOARD
  topic_id: BRD
  title: "The RetroRegen GBA diagnostic ROM boots to its main menu in the Verilator model"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "With the official GBA BIOS (`boot.rom`, SHA-256 `fd2547724b505f487e6dcb29ec2ecff3af35a841a77ab2e85fd87350abd36570`) and `RetroRegen-GBA-Test-v1.5.gba` (284,384 bytes, detected as SRAM backup type 3), the simulated core renders the ROM's GBA-family boot logo, its RetroRegen splash screen at 3,000 distinct colours, and its main menu listing QUICK TEST, SYSTEM STATUS, MEMORY TEST, SCREEN TEST, GPU STRESS TEST, BUTTON TEST, AUDIO TEST, BURN-IN TEST and ABOUT/HELP with a working cursor and the footer `MODEL: GBA FAMILY (AGB BIOS)`. A scripted START press at frame 300 advanced the splash to the menu, so controller input through `joy_btns` into `KEYINPUT` is confirmed working in the model. The same core also boots Super Mario Advance to that game's own save-check message, and the first instruction fetch from the cartridge occurs at sim_time 452,974,016 with execution later seen in `0x08000000`, `0x0C000000` and `0x06000000`."
  consequence: "The GBA core executes retail and diagnostic cartridges correctly in simulation, with working graphics, palette, sprite and tilemap rendering and working controller input.  This makes the model a usable reference for hardware work: the RetroRegen suite already reports `GBA FAMILY (AGB BIOS)` and can run nineteen independent PASS/FAIL checks, which is a far sharper instrument than the sixteen-bar status probe.  It also establishes what the simulator cannot settle: the model substitutes `sdram_sim.v` for the real controller and stubs the save hardware as `0xff`, so a retail game stopping at 'The saved data is corrupt' is expected there and says nothing about the board.  Note that frame dumps taken at fixed intervals can be byte-identical across several dumps and that a static screen is not by itself a hang -- the splash and menu are both static by design, and only a comparison across frames that span an input can show progress."
  sources:
    - "`/home/vash/Desktop/RetroRegen-GBA-Test-v1.5/RetroRegen-GBA-Test-v1.5.gba` and its `README.txt`"
    - "This repository, `tools/sim/build_gba_sim.sh` and `tools/sim/sim_main.cpp`: the harness, the frame dump and the scripted-press support added this cycle"
    - "Frames `rr_frame0240.ppm` (BIOS logo), `rr_frame0300.ppm` (RetroRegen splash, 3000 colours) and `rr_frame0420.ppm` (main menu)"
  verification: "Observed 2026-11-02 in the Verilator model with `-s 1200000000 -pe 60 -pf 240 -press 3@300:10,3@420:10,8@540:10,8@660:10`.  The splash-to-menu transition followed the scripted START press, which is what establishes that the input path works rather than merely being connected."

- record_id: BRD-011
  kind: BOARD
  topic_id: BRD
  title: "RetroRegen's diagnostic suite passes the core's CPU, system ID, graphics and every internal memory region in simulation"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "`RetroRegen-GBA-Test-v1.5.gba` driven by hand through the Verilator model, with the official GBA BIOS, reports: SYSTEM STATUS -- `CPU: ARM7TDMI @ 16.78 MHz`, `SET: ARM v4T (ARM+THUMB)`, `BIOS SUM: 0xBAAE187F`, `AGB BIOS: GBA/SP/MICRO`, and bus timing `IWRAM 1190`, `EWRAM 1702`, `ROM 1702` cyc/256 reads all `OK`, `WAITCNT: 0x0000`, `CART SAVE (SRAM PROBE): OK (64K RANGE)`.  MEMORY TEST -- `IWRAM 32K PASS`, `EWRAM 256K PASS`, `VRAM 96K PASS`, `PRAM 1K PASS`, `OAM 1K PASS`, `RESULT: ALL REGIONS PASS`, cart SRAM `OK (64K RANGE)`.  The guided checks also passed by eye: system ID, CPU, memory, LCD solid, LCD ramps and the GPU scene.  Audio and the button test were skipped deliberately, because the model's audio goes nowhere observable and the input was being driven by hand.  The GPU stress test ran."
  consequence: "The core's CPU executes ARM and Thumb correctly, its BIOS is byte-identical to the official image by checksum, its memory decode and byte-lane handling are correct across every internal region at every width, its palette and framebuffer carry the full colour range, and its drawer renders a real scene.  This is the first independent third-party confirmation of the machine side of this port, and it is much stronger evidence than any probe built during this session, because it is a test suite judging the core rather than the core's own instrument reporting on itself.  The limit must be stated wherever this result is quoted: the model substitutes `sdram_sim.v`, a behavioural array, for the real SDRAM controller and does not compile `sdram_gba.v` at all, so `EWRAM` and `ROM` passing says the CPU asked the right addresses and the decode is right, and says nothing about the physical controller or its timing.  The same ROM on the board is therefore the correct next instrument, and it will report the same ten facts in one screen -- either matching this result or naming where hardware diverges, which is exactly the spot-check the current plan calls for."
  sources:
    - "`/home/vash/Desktop/RetroRegen-GBA-Test-v1.5/` and its `README.txt`"
    - "Superseded screenshot of the SYSTEM STATUS and MEMORY TEST screens, 2026-11-02"
    - "This repository, `tools/sim/build_gba_sim.sh`: the simulated source list, which carries `sdram_sim.v` and not `sdram_gba.v`"
  verification: "Observed 2026-11-02 in the Verilator model, driven interactively by the operator through the SDL window, with frames dumped to `qd_frame*.ppm` and the two verdict screens read directly."

- record_id: BRD-012
  kind: BOARD
  topic_id: BRD
  title: "The capture card returns solid black at 1280x720 whatever the board is doing"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "Opening the Guermok/MACROSILICON USB3 capture device with ffmpeg and no format pinned makes it negotiate a 1280x720 mode that delivers a frame of uniform `(0,0,0)` regardless of what the Tang is driving. Loaded with `build/c6_machine_ok/tinygba.fs`, an image core-log entry 8 records as drawing a black field flanked by grey pillarbox bars, such a grab reported exactly one colour across all 921,600 pixels and one run on its middle row. The same board, captured as MJPEG at 1920x1080, reported 14 colours with grey `(43,43,43)` at x=0..148 and x=1770..1919 and a 1,616-pixel black window between them -- the picture entry 8 describes. The device advertises yuyv422, mjpeg, bgr24 and nv12 at ten resolutions including both of these, so the wrong mode is reachable by default rather than being a malformed request."
  consequence: "A black frame from this card is not evidence about the board unless the format is pinned, and the failure is silent: it produces a plausible-looking all-black image rather than an error, so it reads exactly like a machine that draws nothing. Every conclusion drawn from an unpinned single-frame grab is void. `TINYGBA_OVERLAY_OFF` images must be captured as `-f v4l2 -input_format mjpeg -video_size 1920x1080`, and a reading must state the negotiated size and the colour histogram beside the picture, because `1920x1080` and black-at-1080p versus black-at-720p is the difference between a measurement and an artefact. Two of this cycle's own readings were taken through the unpinned path before the control was run; both are discarded."
  sources:
    - "This repository, `build/c6_machine_ok/tinygba.fs` and the picture core-log entry 8 records for it"
    - "`ffmpeg -f v4l2 -list_formats all -i /dev/video0`: the mode list the device advertises"
    - "Board capture 2026-11-02, 1920x1080 MJPEG, grey=321840 black=1749600, identical for `build/c6_machine_ok` and `build/tang_ctrl`"
  verification: "Measured 2026-11-02 by loading the recorded-good `build/c6_machine_ok` image, capturing it both ways, and comparing colour histograms and middle-row run boundaries. The 1280x720 grab was uniformly black; the 1920x1080 MJPEG grab showed the grey pillarbox the project's own records predict."

- record_id: BRD-013
  kind: BOARD
  topic_id: BRD
  title: "On the board the CPU writes every interrupt register the BIOS needs and never fetches from the cartridge"
  status: VERIFIED
  verified_date: 2026-11-02
  statement: "`TINYGBA_STATUS_TEST` built at seed 5 (`7770b88a158c817f9b01972936497718bbdd9c97e858a8690f1d7fc86e153fb1`) and read on the board through `tools/probe_map.py --decode`, in three states.  No cartridge: word `0x0000`, status band blue -- every bit clear, which is the correct still-loading baseline and shows the sticky bits are armed and do not self-set.  With the 4 KiB test cartridge streamed on `/dev/ttyUSB1`: word `0x7FFE`, band green, `scanline_run=1`, `vblank_arrived=1`, `hblank_arrived=1`, `vblank_irq_en=1`, `dispstat_written=1`, `dispstat_en_written=1`, `ie_written=1`, `ime_written=1`, `halt_seen=1`, `halt_cleared=1`, `halt_entries=7`, and `cart_fetched=0`.  With RetroRegen-GBA-Test-v1.5 streamed the same way: word `0x1F7E`, band green, the same alive signals and the same four register writes, but `halt_cleared=0`, `halt_entries=1`, and `cart_fetched=0`.  `cart_fetched` is `rom_addr[27:24]` non-zero accumulated over reset, so it is clear in every configuration: no cartridge instruction is ever fetched."
  consequence: "The board's boot path is narrowed to one stage. Video timing runs (scanline, VBlank and HBlank all arrive), the CPU executes, and it writes all four of the registers that govern the V-Blank interrupt -- DISPSTAT, a DISPSTAT write carrying din[3], IE and IME -- so the failure is not 'the CPU never gets that far'. It is that the fetch from `0x08000000` never happens, with the test cartridge leaving the CPU cycling through a halt that wakes (seven entries) and RetroRegen leaving it halted once and never woken. Two things must travel with this record. First, an earlier decode of these same captures was read against a stale hand-written bit list in a code comment and produced a withdrawn claim that the SDRAM controller answered on hardware; the generated map has no such field, and the board has not been shown to answer a memory request. Any decode must come from `tools/probe_map.py --list`, never from prose. Second, the picture is still black with a real cartridge loaded, so a black screen remains consistent with a machine that is alive up to the fetch and this record must not be quoted as evidence that the picture is right."
  sources:
    - "This repository, `build/tang_status/tinygba.fs` and its `timing-gate.log`, `clock-plane.log`"
    - "Captures `/tmp/status1.png`, `/tmp/st_usb1.png`, `/tmp/st_rr.png`, decoded with `tools/probe_map.py --decode`, field map `1dce3f01`"
    - "This repository, `fpga/gba/src/probe_bits.vh` and `tools/probe_map.py`"
  verification: "Observed on the board 2026-11-02 after flashing with `openFPGALoader -b tangconsole` and streaming each image with `tools/load_gba_rom.py --uart /dev/ttyUSB1`, captured as MJPEG at 1920x1080 per BRD-012."

- record_id: BRD-014
  kind: BOARD
  topic_id: BRD
  title: "The GPU's raster never completes a scanline, which is why the machine halts forever"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "On the board the machine is bimodal across loads of one fixed bitstream. The good state (`0xFFFF`) has VBlank, fifteen or more halt entries and a cartridge fetch. The bad state (`0xB638` under map `169aa481`, and `0x7FF3` under map `b7850627` before the ladder was added) has `mem_ready=1`, `mem_ready_clk67=1`, `gpu_released=1`, the CPU writing DISPSTAT, IE and IME, `halt_entries=1`, `halt_cleared=0`, `cart_fetched=0`, `vblank_arrived=0` and `scanline_run=0`. With the GPU timing generator tapped (`build/tang_gpu`, map `169aa481`), the failing ladder reads `gpu_released=1`, `left_visible=0`, `cycles_100=1`: the cycle counter advances past 100 and the state machine never leaves VISIBLE, so no line of 1008 cycles is ever completed and no VBlank is ever raised. The memory controller, the clk67 clock distribution and the CPU all work in the failing state. The picture in the failing state is a black field with grey pillarbox bars at 1920x1080, which is a locked, synced video path displaying an empty framebuffer, confirmed by the operator on a monitor."
  consequence: "The fault is the GPU's raster, not memory. Two claims made earlier in the same session are superseded and must not be revived: that the SDRAM controller never acknowledges, and that the black picture implies a memory-path fault. The signature -- a counter that passes 100 and never finishes a 1008-cycle line -- is what a reset that keeps returning looks like, so `gbaon` (which drives the GPU's reset) falling again after rising is the leading candidate, with the generator's unreset `mclk_r`/`pixelpos` as the alternative. Because the badge is bimodal across loads, any hardware reading taken from a single capture has a coin-flip chance of naming the wrong state; six load cycles were needed to observe both. The status probe's bars are drawn by `gba2hdmi`'s own raster, not by the GBA GPU, so a correct probe picture proves the display path and says nothing about the GPU timing generator -- conflating the two hid this fault for several cycles."
  sources:
    - "This repository, `build/tang_gpu` (map `169aa481`) and `build/tang_scan` (map `8c589e34`)"
    - "Captures decoded with `tools/probe_map.py --decode` after the bar-geometry and grey-tolerance fixes"
    - "This repository, `fpga/gba/src/gpu/gba_gpu_timing.v`: the `DBG_gt` packing and the `if (mclk & ~mclk_r) cycles = cycles + 1` increment"
  verification: "Observed on the board 2026-11-03 by flashing with `openFPGALoader -b tangconsole`, streaming `build/test/test.gba` with `tools/load_gba_rom.py --uart /dev/ttyUSB1`, and decoding MJPEG captures pinned at 1920x1080. The bad state was caught in two independent builds with different maps."

---

- record_id: TCL-012
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A non-blocking assignment after an if/else silently destroys the branch's value, and no tool reports it"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "`gba_gpu_timing.v` cleared its cycle counter with `if (reset) begin ... cycles_reg <= 0; ... end else begin ... end` followed, outside the branch, by an unconditional `cycles_reg <= cycles;` where `cycles` had been loaded from the pre-edge value of `cycles_reg` at the top of the same always block. In Verilog the last non-blocking assignment scheduled in a time step wins, so the reset branch's zero was overwritten and the counter kept its old value. Measured in a standalone Verilator model of the module: with the raster running at `cycles_reg` 206, asserting reset and holding it for 2.5 us left `cycles_reg` at 206. Moving the assignment inside the non-reset branch makes reset clear the counter (206 to 0) with no change to frame generation, which still produced 2 VBlanks in 40 ms, 405 lines and a linecounter sweep of 0 to 227. Neither slang nor yosys nor nextpnr reports this construct; it elaborates, synthesises, passes every gate this project has, and behaves differently from what the source appears to say."
  consequence: "A reset that appears to clear a register may not, and the only reliable way to know is to assert reset in a model and read the register back rather than to read the branch. On this design the surviving counter is what made the GPU read `gpu_released=1`, `left_visible=0`, `cycles_100=1`: a state machine pinned to VISIBLE with a counter above 100 that never advances. The second-order effect was timing -- removing the dead assignment moved `clk67`'s worst path away from the SDRAM cone and all five seeds then passed at 154 to 164 MHz against 67.002 with no multicycle relaxation, where every earlier build had needed the four-cycle readback allowance to pass at 31 to 36 MHz. Treat a large unexplained timing improvement as evidence that dead logic was removed, not as a sign that the change was neutral."
  sources:
    - "This repository, `fpga/gba/src/gpu/gba_gpu_timing.v` before and after, and the `if (reset)` branch against the unconditional assignment at the end of the same always block"
    - "Standalone benches at /tmp/gt_cycle, 2026-11-03: `tb_gt_resetclear.sv` (assert reset at a known counter value and read it back) and `tb_gt_frames.sv` (frame completion under a static release)"
    - "This repository, `build/rf_1` through `build/rf_6/timing-gate.log`: five seeds, `clk67` 154.012 to 163.747 MHz, no relaxation"
  verification: "Measured 2026-11-03 in Verilator 5.032: the pre-fix module left `cycles_reg` at 206 through a held reset, the post-fix module returned it to 0, and the frame bench reported identical frame counts before and after. Confirmed at scale in five separate place-and-route runs."

- record_id: BRD-015
  kind: BOARD
  topic_id: BRD
  title: "The Tang in two-wire mode has no FT2232 and cannot be flashed; it enumerates as a TinyTang CDC device"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "When the Tang Console is switched to two-wire mode its FT2232 is not present on USB. `lsusb` shows no `0403:6010`, `/dev/ttyUSB0` and `/dev/ttyUSB1` do not exist, and `openFPGALoader -b tangconsole` fails with `unable to open ftdi device: -3 (device not found)` because that board definition selects the ft2232 cable. In one instance the console instead enumerated as `ffff:5454 TinyTang CDC` and presented a single `/dev/ttyACM0`. Three separate disappearances during one session were all this mode switch and none was a cable, driver, hub or kernel fault; each cleared as soon as the console was returned to one-wire, at which point `0403:6010` reappeared and the same image flashed normally."
  consequence: "A board that vanishes from USB mid-session is a mode switch until proven otherwise, and the check is `lsusb | grep 0403:6010` rather than any driver investigation. The symptom is worth recognising because it arrives as a plain load failure after earlier loads in the same session succeeded, which reads like a hardware or cable fault. Nothing in this project needs the two-wire path: every image on record was deployed one-wire with `openFPGALoader -b tangconsole`."
  sources:
    - "This repository, session transcript 2026-11-03: `lsusb`, `/dev/ttyUSB*` and `openFPGALoader` output before and after the operator returned the console to one-wire mode"
    - "`openFPGALoader --list-boards`: `tangconsole` is bound to the `ft2232` cable"
  verification: "Observed 2026-11-03 three times in one session: FT2232 absent and the load refused each time, FT2232 present and `Done`/`DONE` each time after the operator switched back."

- record_id: BRD-016
  kind: BOARD
  topic_id: BRD
  title: "The model renders the BIOS screen and the board does not, and the block the model omits is the framebuffer and scaler"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "Built with the operator's official GBA BIOS (`TINYGBA_BIOS_HEX`) and driven with the logo-bearing test cartridge, the Verilator model renders the BIOS boot screen: a 240x160 frame of 22 distinct colours, dominated by a `(252,252,252)` white field with the logo lettering. It also reports the boot path in numbers -- 33,333,333 `clk16` cycles after `gba_on`, 2.0 percent of cycles stalled with `cpu_en` low, 75.5 percent halted, `rom_en` asserted 18.0 percent, data regions 0x00000000 through 0x0C000000 all touched -- and it never fetches from the cartridge, which on this 4 KiB image is the same behaviour the board shows. The harness builds its screenbuffer directly from `pixel_out_we`, `pixel_out_x`, `pixel_out_y` and `pixel_out_data`, so the GPU's pixel stream is real; and in the routed netlist `video.mem_portA_we` traces through `mem_portA_we_DFF_Q` to `gpu.igba_gpu_colorshade.pixel_out_we`, so the handoff into the framebuffer is wired. What the model does not compile at all is `gba2hdmi`: the framebuffer array, the 4.5x scaler and the TMDS serialiser path are absent from `tools/sim/build_gba_sim.sh`'s source list. The board, running the same BIOS and cartridge, draws a black centre with the grey pillarbox and a synced HDMI signal. A phase sweep also cleared the two-PLL-versus-one-counter difference that entry 10 named as the leading candidate: with `clk50` and `clk16` at 3:1 and the `clk16` edge swept across twelve offsets from 0 to 55 ns, the raster completed two frames at every one."
  consequence: "The model and the board now agree on the rasters, the CPU, the memory decode and the pixel stream, and disagree only on the picture, so the remaining candidate is the one block the model does not contain: what happens between the pixel stream and the TMDS pair. The next instrument is to compile `gba2hdmi` into the model rather than to flash another hypothesis, and the specific question to answer is where `pixel_out_x/y` writes land relative to `pixel_y * 240 + pixel_x`. Do not re-test clock phase, the reset assignment, or the presence of the OSD: all three are measured and closed. Note also that the board has never been shown to write the framebuffer at all, so a build holding the GPU in reset while driving `mem_portA` from a known pattern remains the cheapest way to separate generated-but-undisplayed from never-generated."
  sources:
    - "This repository, `tools/sim/build_gba_sim.sh` source list (no `gba2hdmi.sv`) and `tools/sim/sim_main.cpp`, which draws from `gba->pixel_out_*`"
    - "This repository, `build/sim_prod/obj_dir`, built 2026-11-03 with `TINYGBA_SIM_DEFINES='-DTINYGBA_BIOS_HEX=...'`; frame `/tmp/simf_frame0060.ppm`, 22 colours"
    - "This repository, `build/rf_4/tinygba.json`: `video.mem_portA_we` driven by `video.mem_portA_we_DFF_Q`, whose `D` is `gpu.igba_gpu_colorshade.pixel_out_we`"
    - "Standalone bench at /tmp/gt_cycle/tb_gt_phase.sv, 2026-11-03: twelve `clk16` phase offsets, 2 VBlanks at each"
  verification: "Measured 2026-11-03. The model render and its counters are from a completed 400,000,000-step run; the netlist trace is from the routed netlist of the deployed image `build/rf_4/tinygba.fs` (SHA-256 `752d933ee7bfa62410f954f5c0e19143650fe7e8a805f2d1051f9aaf3ff9ad19`); the phase result is a twelve-point sweep. The board's black picture is the operator's report across every image deployed this session."

- record_id: BRD-017
  kind: BOARD
  topic_id: BRD
  title: "The GPU raster runs on the board once the cycle counter's dead reset is fixed"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "A `TINYGBA_PIXTEST` build carrying the timing generator's ladder across the framebuffer read `white white white black white white white black` on the board, under commit `071e49f`'s fix to `gba_gpu_timing.v`. Decoded against the ladder in `gba_gpu_timing.v`: reset released, the state machine left VISIBLE, `cycles_reg` passed 100, the 1008 rung stayed black, the `mclk` rising-edge detector fired, and `cycles_reg` passed 400 and 700. The 1008 rung is black by construction -- the state machine subtracts 1008 in the same cycle it tests for it, so the register never holds that value -- and its darkness is therefore a check that the tap is reading the register and not a copy that could reach the threshold. The rungs were sticky, latched on `clk50` in `gbatang_top.sv`, so each means 'ever true since reset' rather than an instantaneous sample. This supersedes BRD-014's `left_visible=0` and `scanline_run=0`, which were taken from `build/tang_gpu`, built before `071e49f`. The next build in the same session read `drawline` and `hblank_trigger` both firing and `pixel_out_we` never asserting, so the generator completes lines and hands them to the drawer."
  consequence: "The timing generator is no longer a suspect in the black picture and BRD-014's title, 'the GPU raster never completes a scanline', is settled by the fix it pointed at. The remaining fault is the drawer: lines arrive and no pixel comes out. Do not re-probe the generator's counters, its reset, or the `mclk` edge detector; all three are measured working. Note the instrument requirement that made the reading possible: the threshold comparisons in `DBG_gt` are live signals, and the counter sweeps 0 to 1007 continuously, so an unlatched sample reads 'below 100, in VISIBLE' roughly nine times in ten even on a healthy raster. A live tap of this ladder is uninformative and one build produced six coin-flip bands because of it."
  sources:
    - "This repository, `fpga/gba/src/gpu/gba_gpu_timing.v`: the `DBG_gt` ladder and its sticky latch, and the reset-branch fix from commit `071e49f`"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: `pix_ladder`, the sticky-OR latch on `clk50` that carries the ladder to `dbg_bits`"
    - "Standalone bench at /tmp/gt_cycle/tb_taps.sv, 2026-11-03, which shows a healthy run setting every rung except 1008"
  verification: "Observed on the board 2026-11-03 by flashing with `openFPGALoader -b tangconsole` and streaming `build/test/test_logo.gba`, reading the eight bands as colours. The same stimulus in Verilator sets the identical rungs, so the pattern the board produced is the healthy one and not an artefact of the decode."

- record_id: BRD-018
  kind: BOARD
  topic_id: BRD
  title: "The drawer receives lines and never emits a pixel"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "On a `TINYGBA_PIXTEST` build whose eight bands carried `drawline`, `hblank_trigger`, `pixel_out_we` and four controls, the board read `white white black white white white black white`: `drawline` fires, `hblank_trigger` fires, `pixel_out_we` never asserts, the generator left VISIBLE, the counter passed 100 and 700, `gbaon` never fell and `gbaon` is high. So the timing generator hands a line to `gba_gpu_drawer` and the drawer never produces a pixel. That narrows the fault to the drawer's own state machine, whose only route to a pixel is IDLE -> WAITHBLANK on `drawline` and `linesDrawn < 160`, then DRAWING on `hblank_trigger`, then MERGING when `busy_allmod == 0`, with `pixel_we` assigned in the merge stage. Two of those three transitions are now measured to happen. A later build attempting to read the state machine directly produced a self-contradictory strip instead, reporting WAITHBLANK reached while `drawline` was clear, which cannot both be true."
  consequence: "The next instrument must read the drawer's live state and its busy vector, not a latched history. `drawstate` in `gba_gpu_drawer.v` has no reset term anywhere -- it is declared as `reg [1:0] drawstate` and only ever assigned in the state machine -- so it powers up in an arbitrary state, and a sticky latch cleared by `~resetn` starts sampling that value the instant reset releases. For a machine that is stuck rather than transient the steady state is the answer and a live level is the correct instrument. If the state proves to be DRAWING with a busy bit set, the suspect becomes the memory path the drawers read through `gba_memory`'s GPU ports, which no build on this board has ever exercised and which the Verilator model replaces with plain arrays."
  sources:
    - "This repository, `fpga/gba/src/gba2hdmi.sv`: the `TINYGBA_PIXTEST` band definition and the eight-band renderer"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: `pix_drawer`, the latch that carries the bands to `dbg_bits`"
    - "This repository, `fpga/gba/src/gpu/gba_gpu_drawer.v`: the `tdrawstate_*` machine at lines 2005 to 2041, and the absence of any reset on `drawstate`"
  verification: "Observed on the board 2026-11-03 on `build/drw2_1/tinygba.fs` (SHA-256 `b9fa26e945570f77d6db01c9938d769e0ee9ae207c74bc6562af4ec673f14d63`), read as eight band colours. The matching all-black strip from a different load of `build/drw2_6/tinygba.fs` is the bad state of the bimodality BRD-014 records, not a contradiction."

- record_id: TCL-013
  kind: TOOLCHAIN
  topic_id: TCL
  title: "Synthesis deletes diagnostic registers that sit on no path to a displayed output"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "A set of eight sticky diagnostic registers placed inside `gba_gpu_drawer.v` and driven from `drawline`, `hblank_trigger`, `drawstate`, `busy_allmod` and `pixel_out_we` produced zero cells in the final netlist: `dr_taps` appeared in the synthesis log's process listing and was then removed, and the top-level consumer was left latched to a hard `VCC`. The registers were their own only consumer, because the module output they drove was itself consumed only by a net that later folded. Exporting the same raw signals as module outputs and latching them at the top level, where they reach `dbg_bits` and therefore the framebuffer, kept all eight. A second instance of the same hazard appeared as a band computed from `busy_allmod == 8'h00`, which folded to the constant-zero net and would have read black for ever regardless of the machine."
  consequence: "A diagnostic register must reach a displayed output or it will be removed, and a green build says nothing about whether it survived. Verify by counting flip-flops against a known configuration and by confirming each tap bit is a distinct live net rather than a constant, and prefer individual bits over a whole-vector comparison against a constant when the value has to survive. Do not conclude a tap is wired to `VCC` from its `D` pin alone: `D=VCC` with a separate clock enable is how yosys implements `q <= q | signal`, so the enable carries the logic."
  sources:
    - "This repository, `fpga/gba/src/gpu/gba_gpu_drawer.v` and `gba_gpu.v`, before and after exporting `DBG_ev` and `DBG_ds` as outputs"
    - "This repository, `build/drw/tinygba.json` (zero tap cells) against `build/drw2/tinygba.json` (taps present, +13 flip-flops)"
    - "This repository, `build/drw3/synth.log`: the `$dr_taps[7]` to `$dr_taps[3]` process listing, with no matching cells in the written netlist"
  verification: "Measured 2026-11-03 by comparing flip-flop and LUT counts between consecutive syntheses of the same configuration, and by checking every tap bit's driving cell in the written netlist. Corrected twice after the first check wrongly read `D=VCC` as a constant."

- record_id: TCL-014
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A reference before its declaration silently becomes an implicit wire, and preprocessor order swallows defines"
  status: VERIFIED
  verified_date: 2026-11-03
  statement: "Two declaration-order faults produced confident wrong readings in one session. An `assign DBG_ds = {busy_allmod, drawstate};` placed beside the port declaration referenced `drawstate`, which is declared some ninety lines further down in `gba_gpu_drawer.v`; Verilog creates an implicit 1-bit wire instead of reading the register, so the concatenation folded and every consumer saw a constant. Separately, a `mclk_r` reference written above its declaration inside `gba_gpu_timing.v` would have tapped a different implicit wire than the register the edge detector uses. The preprocessor has the same hazard in the other direction: a `` `define TINYGBA_GPU_TAPS `` written below the `` `ifdef `` that tests it has no effect, which is what happened when the define was first added beside the overlay logic near the bottom of `gbatang_top.sv` and elaboration failed with 'use of undeclared identifier'."
  consequence: "Put any continuous assignment after the declarations it reads, and put a conditionally-compiled define above the first `ifdef` that consumes it. Neither fault produces a warning on this flow: the implicit wire elaborates, synthesises, and folds to a constant, so the symptom is a tap that reads a fixed value rather than an error. The tell is the same in both cases -- a tap bit driven by `VCC` or `GND`, or an elaboration error naming an identifier that is defined further down the file."
  sources:
    - "This repository, `fpga/gba/src/gpu/gba_gpu_drawer.v`: the `DBG_ds` assign moved from beside the port to the end of the module"
    - "This repository, `fpga/gba/src/gpu/gba_gpu_timing.v`: `reg mclk_r;` hoisted above the tap block that reads it"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: `TINYGBA_GPU_TAPS` moved from line 948 to line 108, above the `gpu_dbg` declaration at line 282"
  verification: "Measured 2026-11-03. The misplaced define failed elaboration outright with 'use of undeclared identifier gpu_dbg' and elaborated once moved. The misplaced assign produced a netlist whose tap bits were reported as `VCC`-driven until the assign was moved, after which the bits traced to the intended sources."

- record_id: TCL-015
  kind: TOOLCHAIN
  topic_id: TCL
  title: "This tree contains no DFFN and no fabric clock, and a build gate now keeps it that way"
  status: VERIFIED
  verified_date: 2026-11-04
  statement: "The sibling TinySNES project lost a cycle to a synthesis behaviour recorded there as TCL-020: for GW5A, `synth_gowin` keeps only a plain negedge flop as a true `DFFN` and legalises every negedge flop carrying an enable or a synchronous reset into a posedge `DFFRE` behind a `LUT1` inverter of the clock. When both kinds sit on one clock the two halves clock a few ns apart on fabric routing and nextpnr times the inverted net as an unrelated clock, so the path between them is never hold-checked; that deadlocked the SuperFX on the board while a bench with ideal clocks ran it. Measured on this port 2026-11-04: the routed netlist `build/drw3_1/tinygba-routed.json` carries 3,077 `DFF`, 8,251 `DFFRE` and zero `DFFN`, and no flop or block RAM clock pin is driven by a `LUT1`/`LUT2`/`MUX2`/`INV` cell. The construct is therefore absent from TinyGBA rather than fixed in it, and twelve `negedge` occurrences in the RTL are all asynchronous reset terms or the HDMI serialiser's intended `clk_pixel_x5` negedge. `tools/clock_edge_check.py` is now ported from TinySNES and runs as build step `1c`, immediately after the register-parity gate, reading the synthesised netlist before place and route because that is where the legalisation has already happened and the inverted net is still named."
  consequence: "`DFFN` count is the cheap invariant to watch. A non-zero count on this design means someone added a plain negedge flop and the gate will refuse the build until that flop is given a synchronous reset or enable, which is the repair TinySNES records. Do not describe the gate as a fix for a present fault: it changed no logic, and the netlist it judges was already clean. Its value is that the property was previously unchecked and this project's netlists had never been examined for the class."
  sources:
    - "This repository, `build/drw3_1/tinygba-routed.json`: flop primitive census and the clock-pin driver scan"
    - "This repository, `tools/clock_edge_check.py` and `tools/build_tinygba.sh` build step `1c`"
    - "TinySNES `.ai/core-reference.md` TCL-020 and `tools/clock_edge_check.py`, the port's origin"
  verification: "Measured 2026-11-04. The gate was proven to fire rather than assumed to: a minimal module carrying one plain negedge flop plus negedge flops with an enable and with a reset, synthesised with `synth_gowin -family gw5a`, makes the gate exit 1 and name the clock, the true negedge flop and the inverter; this tree's netlists exit 0; a missing file and a missing argument exit 2. The gate ran inside the real flow on `build/pix16_s1` and reported `clock edges: OK`."

- record_id: BRD-019
  kind: BOARD
  topic_id: BRD
  title: "No placement this tree produces puts all four clocks on pips measured good on this board"
  status: VERIFIED
  verified_date: 2026-11-04
  statement: "`tools/clock_plane_report.py --strict` refuses every placement tried, exiting 1 on both `build/drw3_1/tinygba-routed.json` and `build/pix16_s1/tinygba-routed.json`. `clk16` reaches its sinks on six `*/TOP3` pips -- `SPINE1`, `SPINE2`/`SPINE19`, `SPINE20`, `SPINE26`, `SPINE27`, `SPINE28` -- none of which this board has a record for; `clk50` uses `SPINE0/TOP0`, `SPINE18/TOP1` and `SPINE26/TOP0` unmeasured alongside two measured-good; `clk67` uses `SPINE19/TOP2` unmeasured and `SPINE27/TOP2` only `partial`; `hclk` uses `SPINE16/BOTTOM2` and `SPINE24/BOTTOM2` unmeasured alongside one measured-good. The six clock-plane paths this project has measured good are all `clkdiv` or `pll` sites on `BOTTOM2`, `TOP0` and `TOP1`, and none of them carries `clk16`. The gate's own wording is that a clock on an unmeasured pip may be fine and may be silent, because nothing has shown it either way."
  consequence: "A hardware reading from this tree cannot yet be attributed to the design rather than to the pip, which is precisely the ambiguity TinySNES records as its BRD-005: there, the identical netlist booted on a placement taking one spine for the master clock and left the cartridge on placements taking two others, with every build passing Fmax and none reporting a hold violation. The consequence here is a wording rule as much as an engineering one -- a result from an unmeasured `clk16` pip must say so. It does not make the builds wrong. Every image this project has flashed came from this class of placement, including the ones that drew a verified picture and read sixteen green SDRAM bars, so an unmeasured pip is demonstrably not fatal in itself; what is unproven is which pip each individual result came from."
  sources:
    - "This repository, `build/drw3_1/clock-plane.log` and `build/pix16_s1/clock-plane.log`, and the same two netlists' `netnames[<clock>].attributes.ROUTING`"
    - "This repository, `tools/clock_plane_report.py`: the measured-good table and the `--strict` refusal path"
    - "TinySNES `.ai/core-reference.md` BRD-005, the sibling project's placement-decides-it result"
  verification: "Measured 2026-11-04 from the routed netlists rather than from build timestamps: the strict gate exits 1 on both, the default gate exits 0 on both, and the bridge-pip strings were read directly (`clk16` 7 bridge pips / 149 spine references, `clk50` 6/140, `clk67` 2/19, `hclk` 4/47). Not measured on hardware: no build has been loaded since this record was written."

- record_id: TCL-016
  kind: TOOLCHAIN
  topic_id: TCL
  title: "Diagnostic compare logic costs routing arcs far out of proportion to its flip-flop count, and the arc count is the number to watch"
  status: VERIFIED
  verified_date: 2026-11-04
  statement: "Adding three diagnostic flip-flops to this design took LUTs from 40,778 to 41,294 and nextpnr's routing arc count from 220,272 to 228,317, an increase of about 8,000 arcs or 3.8 percent, for a 0.03 percent increase in registers. The flip-flop count is therefore a misleading measure of what a diagnostic change costs the placer, and the arc count printed once at the top of every nextpnr log is the honest one. The growth is attributed to the added combinational logic rather than to the registers: the new bands include a wide vector reduction written as `gpu_ds[9:2] != 8'h00`, and a comparison of a multi-bit vector against a constant is precisely the construct this project already records as folding-prone and expensive (TCL-013). Measured across five seeds on the changed netlist the arc count varies with placement as well as with netlist -- 228,317, 228,580, 228,680, 228,892 and 228,912 -- so it is a netlist-plus-seed quantity and not a pure function of the source."
  consequence: "A diagnostic change that looks free by its register count can cost a clean-seed yield an order of magnitude of placement time. Measured here: the instrument before the change placed at one seed of one attempted, and the instrument after placed at one seed of five, with seed 1 plateauing near 20,000 unrouted nets for 32 minutes and 368,000 iterations before being stopped. The consequence for future diagnostic work is to prefer individual bit terms over whole-vector comparisons when spending spare bits, and to read `Routing N arcs` at the top of the nextpnr log before and after a diagnostic change rather than trusting `flip-flops` from the parity gate to say whether the change was cheap."
  sources:
    - "This repository, `build/pix16_s1/nextpnr.log` (`Routing 220272 arcs`) against `build/pix17_s1` through `build/pix17_s5` (`Routing 228317` to `228912 arcs`)"
    - "This repository, the two netlists' `gbatang_top` cell censuses: LUTs 40,778 against 41,294, flip-flops 11,535 against 11,538"
    - "This repository, `tools/gatelevel_report.py` output for `pix_live`, `pix_hist` and `pix_armed`, which shows the added registers are only three"
  verification: "Measured 2026-11-04 from the build logs of six placements and the cell census of two synthesised netlists. Not a hypothesis: the arc, LUT and flip-flop counts are read out of the artifacts, and the clean-seed yield is the outcome of five attempted placements, three of them stopped by pid while still oscillating at 42 minutes. The `build/pix17_s2` placement completed with zero hold violations and every clock passing, so the changed netlist is placeable, just less often."

- record_id: TCL-017
  kind: TOOLCHAIN
  topic_id: TCL
  title: "yosys treats a register with neither reset nor initialiser as undefined and folds it, where the vendor flow powers it up at 0"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "The upstream GBATang RTL leaves many registers with no reset and no initialiser, among them every GPU drawer's `busy`, `vramfetch` and `palettefetch`, and relies on the Gowin vendor flow powering every flop up at 0. yosys gives such a flop an undefined initial value and uses that freedom in two ways that both break the machine. First, it folds logic through the undefined value: `busy_allmod[4]` is `busy_mode2_2 | busy_mode2_2_hd0 | busy_mode2_2_hd1`, the two HD instances never receive `drawline` in this configuration so their `busy` can never leave its initial value, and yosys resolved the OR of an undefined term to constant 1, deleted `busy_mode2_2` and drove `gpu.DBG_ds[6]` and `[7]` from a `VCC` cell (`build/obj_pix_s3/tinygba.json`, net 931). `busy_allmod` could therefore never reach 0 and `gba_gpu_drawer.v`'s `tdrawstate_DRAWING` could never exit. Second, it maps flops whose next-state logic contains a synchronous one onto `DFFSE`, which powers up at 1: in the same netlist all eight drawer `busy` flops and `vramfetch[0]` were `DFFSE`, and the board showed every drawer busy before the CPU had been released. Running `setundef -zero -init` between `read_slang` and `synth_gowin` gives every such flop init 0; in `build/fix_pix_s3/tinygba.json` the `VCC` driver is gone, all eight drawer `busy` flops are `DFFRE`, and the 86 remaining `DFFSE` all trace to an explicit `= 1` initialiser (`rstCnt`, the UART idle-high pair, `dma_idle`), a reset value of 1 (`DISPCNT` forced blank, the BG2/BG3 affine `DX`/`DMY`), or the HDMI serialiser."
  consequence: "Any register in this tree without a reset is a hardware-only fault waiting to happen under the open flow, while Verilator, which zeroes uninitialised state, runs the same RTL correctly. `tools/build_tinygba.sh` now runs `setundef -zero -init` before `synth_gowin`, which reproduces the vendor power-up convention for the whole design rather than patching registers one at a time. TCL-011's `gb_bus_rst` fold is the same class seen earlier. Do not remove the `setundef` step, and when a netlist shows a constant where a register should be, check for an undefined initial value before suspecting the logic."
  sources:
    - "This repository, `build/obj_pix_s3/tinygba.json`: `pix_live` bits 6 and 7 driven from cell `gpu.DBG_ds_VCC_V`; drawer `busy` flops of type `DFFSE`"
    - "This repository, `build/fix_pix_s3/tinygba.json`: the same nets driven by `gpu.drawer.igba_drawer_mode2_2.busy_DFFRE_Q` and siblings; `DFFSE` census 86"
    - "This repository, `fpga/gba/src/gpu/gba_drawer_mode2.v` and `gba_drawer_mode0.v`: `busy` declared `reg` with no reset or initialiser"
  verification: "Measured 2026-11-06 on both netlists and on the board: `build/obj_pix_s3` held `drawstate` at DRAWING with every busy band at 1 in twelve samples across four captures, and `build/fix_pix_s3`, differing only by the `setundef` step, reads all-zero bands before release and cycles `drawstate` through IDLE, WAITHBLANK and MERGING after it, with the GBA field rendered as a solid colour instead of black."

- record_id: TCL-018
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A PLL output without a clock-plane pip reaches the spine through a BUFG and a logic-to-clock gate"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "TCL-001 holds: apicula carries plane pips only for `CLKOUT0` of the PLLs at `PLL_L[0]` and `PLL_R[0]` and for `CLKOUT2` at `PLL_L[0]`, so with all GBA clocks on one PLL at `PLL_L[0]` `clk67` on `CLKOUT1` fell to general routing and hold failed on `sdram.rst_cnt` with 1.2 to 1.84 ns of skew. The vendor flow does reach the plane from `CLKOUT1` and `CLKOUT3`, but through centre-bridge muxes at (27,87) and (27,94) sourced from `CBRIDGEOUT_BOTTOM4..7`, a path apicula does not model and whose decode depends on an unconfirmed fuse polarity; modelling it is reverse-engineering work. The nextpnr-himbaechel fork already supports the alternative: a net carrying the `CLOCK` attribute gets a `BUFG` from the packer, and the global router takes the `BUFG` output through fabric into a logic-to-clock gate and onto the plane. The CST line `CLOCK_LOC \"clk67\" BUFG;` sets that attribute. With it, `clk67` routes in the global phase with no general-routing fallback on `SPINE16/TOP0` and `SPINE25/TOP1`, both measured good, at a cost of one `BUFG`."
  consequence: "Use `CLOCK_LOC \"<net>\" BUFG;` for any PLL output that apicula cannot put on the plane directly, and keep the net in `tools/clock_plane_report.py`'s `REQUIRED_PLANE` so the gate catches a fall back to general routing. The route is per placement, not guaranteed: `build/fix_ov_s2` routed with `clk67` on general routing despite the `BUFG` and was refused by the gate."
  sources:
    - "This repository, `fpga/gba/tinygba.cst`: `CLOCK_LOC \"clk67\" BUFG;`"
    - "nextpnr-himbaechel fork `himbaechel/uarch/gowin/pack.cc` (BUFG insertion on `CLOCK` nets), `cst.cc` (`CLOCK_LOC ... BUFG`), `globals.cc` (logic-to-clock gate routing)"
    - "Vendor probe builds of `CLKOUT1` alone and `CLKOUT3` alone at `PLL_L[0]`, decoded from the vendor bitstreams on this machine 2026-11-05"
  verification: "Measured 2026-11-06 on `build/bufg_pix_s3`, `build/obj_pix_s3`, `build/bufg_ov_s1`, `build/bufg_ov_s2`, `build/fix_pix_s3` and `build/fix_ov_s3`: zero hold violations in every one and `clk67` on measured-good spine pips in every plane report; `build/bufg_pix_s3` and `build/fix_pix_s3` ran on the board."

- record_id: BRD-020
  kind: BOARD
  topic_id: BRD
  title: "With undefined-init folding removed the GPU draws, but the BIOS never completes its intro or fetches the cartridge"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "`build/fix_pix_s3` (SHA-256 `9c4fe8900f3be710b9be31671d52f9c37203e2ab6fc7dcc4d0c3466492effc81`) running the official BIOS with `test_logo.gba` loaded renders the GBA field as a uniform grey, luminance 136 plus or minus 0.5 with no structure, constant across 48 frames sampled at 4 Hz over 12 seconds from reset. The drawer cycles through IDLE, WAITHBLANK and MERGING, the OBJ drawer and occasionally the BG3 affine drawer report busy, `DISPCNT` OBJ enable is set, CPU `halt` toggles throughout, and the sticky cart-fetch band never sets. This explains BRD-018: `pixel_out_we` never asserted because the drawer could never leave DRAWING (TCL-017), not because of any fault in the pixel path. The overlay-off build made before the fix, `build/bufg_ov_s1`, showed a black field."
  consequence: "The picture path now works end to end and the fault has moved to the CPU side: the BIOS is executing and taking V-Blank interrupts, but it neither draws its logo nor jumps to `0x08000000` within 12 seconds, where real hardware does so in about 2.5. The grey is consistent with the BIOS's white backdrop held partway through its brightness fade, which is a hypothesis and not a finding."
  sources:
    - "This repository, the PIXTEST band legend in `fpga/gba/src/gba2hdmi.sv` and the band sources in `fpga/gba/src/gbatang_top.sv`"
    - "HDMI captures through the USB capture device on this machine, 2026-11-06"
  verification: "Read 2026-11-06 from four captures four seconds apart and a 12-second capture from reset decoded at 4 Hz; every frame's field statistics and band strings were consistent with one another."

- record_id: BRD-021
  kind: BOARD
  topic_id: BRD
  title: "With undefined-init folding removed the official BIOS completes its intro and jumps to the cartridge"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "`build/fix_ov_s1` (overlay off, official BIOS, `.fs` SHA-256 `ed96667551e0a512a5c99a5d1cc29484b05c19164c0b8a85d1561a66b3f5a9bb`) is the first image since the `setundef` fix of TCL-017 to show the GPU's own picture on the board, and it plays the complete BIOS intro: the GAME BOY wordmark sweeps in with its colour cycle above the Nintendo mark from about 1.5 s to 5.5 s after the cartridge load releases the machine, then the screen fades to solid white. The operator watched the same sequence live with `test_logo.gba` and with Super Mario Advance (USA, Europe). The PIXTEST build `build/dbg2_pix_s3` read the same intro from the registers: `DISPCNT` BG mode 2 with `BLDCNT` alpha blending, then BG3 enabled, then `BLDCNT` brighten, with palette RAM, VRAM and OAM all written. From about 6.5 s the sticky cartridge-fetch band, which is driven by the CPU's instruction-fetch port (`rom_en` with `rom_addr[27:24]` non-zero), is set, so the BIOS accepted the header and jumped to `0x08000000`. This supersedes BRD-020's reading that the BIOS never completes its intro: BRD-020's uniform grey field was the PIXTEST frame's own background, which `gba2hdmi.sv` writes in place of the GPU's picture, and it said nothing about what the machine drew. BRD-020's other band readings stand, except its cartridge-fetch band, which read 0 throughout in `build/fix_pix_s3` while the identical latch reads 1 in `build/dbg2_pix_s3`; the cause of that difference is not established."
  consequence: "The CPU, the BIOS, interrupts, the GPU, palette, VRAM and OAM writes and the picture path all work end to end on the open flow. The fault has moved past the BIOS to the first instructions of the cartridge (BRD-022). A PIXTEST field is never evidence about the machine's picture; only an overlay-off image shows that."
  sources:
    - "This repository, `fpga/gba/src/gba2hdmi.sv`: the PIXTEST branch writes `{6'h20, 6'h20, ...}` below the bands from its own raster"
    - "This repository, the PIXTEST band map and its sources in `fpga/gba/src/gbatang_top.sv`, build `build/dbg2_pix_s3` (`.fs` `af620647481fe950ce7322f885b3d17aaeeba5b1aeac87a0539c12ed64a39021`)"
    - "HDMI captures through the USB capture device on this machine, 2026-11-06, and the operator's live observation of the same board"
  verification: "Observed 2026-11-06 in a 16-second capture of `build/fix_ov_s1` decoded at 2 Hz, and in two 16-second captures of `build/dbg2_pix_s3`, one per cartridge, whose band strings agree frame for frame with the intro seen on the picture."

- record_id: BRD-022
  kind: BOARD
  topic_id: BRD
  title: "After the BIOS hands over, cartridge code does not run correctly: the first DISPCNT write never lands"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "Once the cartridge-fetch band sets, `build/dbg2_pix_s3` holds a fixed state for the remaining ten seconds of every capture with CPU `halt` at 0, so the CPU is executing and not waiting for an interrupt. With `test_logo.gba`, whose entry point at `0x080000C0` writes `DISPCNT` 0 as its first store and then fills the framebuffer green or red within a frame, `DISPCNT` reads BG mode 0, forced blank set and BG0 to BG3 all enabled, which the cartridge never writes. With Super Mario Advance it reads BG mode 0 and forced blank with nothing enabled, the value the BIOS leaves at handover, and the game never enables its display, where real hardware shows the first screen within about a second. On `build/fix_ov_s1` both cartridges stay on solid white, which is forced blank. The BIOS read the cartridge header through the data port and accepted it, so data reads from the cartridge area return correct words at least for the header."
  consequence: "The leading hypothesis, not yet a finding, is that instruction fetches from the cartridge SDRAM through the CPU's `rom_data` port return wrong words, so the CPU executes something other than the cartridge and either never reaches the first store or writes garbage. Both cartridges fail the same way, so the cartridge image is not the cause. The next measurement is the addresses and words of the first instruction fetches after handover, compared with the ROM file."
  sources:
    - "This repository, `build/test/test.s`: `_start` stores 0 to `DISPCNT` before any other IO write"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: the `gba_cpu` instance, whose `rom_addr`/`rom_en`/`rom_data` port is the instruction-fetch path"
    - "HDMI captures through the USB capture device on this machine, 2026-11-06"
  verification: "Read 2026-11-06 from two 16-second captures of `build/dbg2_pix_s3` decoded at 2 Hz, 24 consecutive identical frames each after handover, and from the operator's live observation of `build/fix_ov_s1` with Super Mario Advance."

- record_id: BRD-023
  kind: BOARD
  topic_id: BRD
  title: "Cartridge fetches return byte-exact words and the first DISPCNT write is issued; the second is never reached"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "`TINYGBA_FETCHTRACE` records the first sixteen completed CPU memory cycles after the machine jumps to `0x08000000` and draws them as bit cells, one row per 32-bit word. Read on the board with `test_logo.gba`, every cartridge instruction fetch returns exactly the word in the ROM file: fifteen of fifteen fetched words match, running `0x08000000` -> `0xEA00002E`, `0x08000004` -> `0x51AEFF24`, then after the branch `0x080000C0` -> `0xE3A0B301`, `0xC4` -> `0xE3A00000`, `0xC8` -> `0xE1CB00B0`, `0xCC` -> `0xE3A0A000`, `0xD0` -> `0xE59F61D8`, `0xD4` -> `0xE59F51D8`, `0xD8` -> `0xE5964000`, `0xDC` -> `0xE1540005`, `0xE0` -> `0x138AA001`, `0xE4` -> `0xE59F61CC`, `0xE8` -> `0xE59F51CC`, `0xEC` -> `0xE5964000`, `0xF0` -> `0xE1540005`. Data reads are correct too: the literals at `0x080002B0`/`B4`/`B8`/`BC` return `0x08000400`, `0xA5A50001`, `0x08000800`, `0xA5A50002`, and the first `ROMCHK` read at `0x08000400` returns `0xA5A50001`, so that check passes on the board. The first `DISPCNT` write is also issued correctly: the fetch of `0x080000C8` (`E1CB00B0`) is followed by a completed cycle carrying `ram_cen=1`, `ram_wen=1`, `be=0011`, `ram_addr=0x04000000`, `ram_wdata=0`, concurrent with the fetch of `0x080000D0`, which is the SDRAM-fetch-plus-IO-write path through `rom_rdata_new` that had never been exercised. What does not happen is the second write: the sticky `DISPCNT<=0x0403` bit never sets, in any frame of three spanning about four seconds, so the cartridge's final `strh` is never reached or never executes. The GPU drawer's own `DISPCNT` registers read `forced_blank=1`, `BG0` to `BG3` all set, `BLDCNT` none, stable across every settled frame, which reproduces BRD-022's register reading independently and shows it was not an instrument artefact. One entry of the IO write ring carries `ram_addr=0x04000000` with `ram_wdata=0xFFE0FFE0` and `be=0011`, a halfword store replicated across both halves as the ARM7TDMI does; `0xFFE0` is the colour the cartridge writes to VRAM for its failure columns, and `0xFFE0` in `DISPCNT` sets exactly the forced-blank and BG0-BG3 bits observed in the register."
  consequence: "BRD-022's leading hypothesis is refuted: the instruction-fetch path from cartridge SDRAM returns correct words, so the CPU is not executing the wrong cartridge. Its title claim that the first `DISPCNT` write never lands is also wrong at the bus level, because the write is issued with the correct address, width and data. The fault is now after that point, and the two candidates the instruments can still separate are a CPU that wedges before the final store and a write that is issued to `0x04000000` but mis-decoded on the way to the register. The `0xFFE0FFE0` ring entry at `0x04000000` is a lead and not a finding: it is one ring entry with no established provenance, and if it is real it would mean a VRAM data store reaching IO space, which would explain both the stuck `DISPCNT` and the white screen from one cause. Do not re-test the fetch path, the BIOS handover or the SDRAM; all three are measured. Wording rule: this result was taken on an image whose `clk16` sits on six `*/TOP3` pips this board has never measured (BRD-019), so it is attributable to the design only with that caveat."
  sources:
    - "This repository, `build/io_s3/tinygba.fs` (`.fs` SHA-256 `58a911881cdb88974e7d574c3b511b9e86e488a503cc2c9e3353a7ce39536c5b`), seed 3, zero hold violations, no relaxation"
    - "This repository, `tools/decode_fetchtrace.py`, which decodes the four pages from the capture geometry in `gba2hdmi.sv`"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: the `tr_flat` recorder and the `io_flat` IO write ring"
    - "This repository, `build/test/test.s`: the two `strh` writes to `DISPCNT` at the entry point and at the end of the run"
    - "Captures `/tmp/io/f001.png` through `/tmp/io/f018.png`, 2026-11-06, MJPEG pinned at 1920x1080 per BRD-012"
  verification: "Observed on the board 2026-11-06 after flashing `build/io_s3` one-wire, streaming `build/test/test_logo.gba` over `/dev/ttyUSB1`, and capturing nine seconds at 2 Hz, which spans all four pages of the readout. Every fetched word was compared against the ROM file by tool rather than by eye, and every tap was confirmed in the netlist as a distinct `DFFRE` with no undriven bits before the load."

- record_id: TCL-019
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A cycling multi-page readout must be classified by its page strip before any row is read, and its cross-clock counters tear their first frame"
  status: VERIFIED
  verified_date: 2026-11-06
  statement: "When a diagnostic frame cycles through several pages, a capture has no page of its own: `TINYGBA_FETCHTRACE` advances its page every 2^25 `clk50` cycles, 0.67 s, for a 2.7 s cycle across four pages, and a frame grabbed at an arbitrary moment shows whichever page it landed on. Decoding such a frame under an assumed page produces plausible rows under the wrong field names, which is the failure mode TCL-010 exists to prevent, one level up. Measured 2026-11-06 on an 18-frame capture: the pages appeared in the order 3, 0, 1, 2, 3, 0, 1, 1, 2 and onwards, so an assumed page 0 would have mis-read more than half the frames. The readout therefore carries its page number as a pair of strips at source x 232..235 (bit 0) and x 236..239 (bit 1), which the host reads before any row. The second fault is tearing: the status page's counters live in `clk16` and are read combinationally into a `clk50` renderer with no synchroniser, so the frame in flight when they change mixes old and new values. Measured in the same capture, the first frame after the page changed read `completed-cycle trace: 0 of 16` while the same frame's `IO ring: 3 entries` was already the new value, a combination that cannot occur once settled; every later frame of that page agreed on `16 of 16`."
  consequence: "Classify a cycling diagnostic frame by its own page marker before reading a single row, and treat the first frame after a page change as a bad sample rather than a reading. A decoder that assumes a page has no way to notice it is wrong, because the bit cells decode to plausible words whatever page they came from. Where a readout mixes clock domains, either synchronise the crossing or discard the frame that straddles it; the counters here are read as a whole word, so a tear is visible as an internally impossible combination and that check is worth writing into any decoder that reads them."
  sources:
    - "This repository, `fpga/gba/src/gba2hdmi.sv`: the `ft_sel` page select, the `ft_tick[26:25]` page counter and the two page strips in `ft_colour`"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: `tr_page`, and the status words read from `clk16` registers into the `clk50` renderer"
    - "Captures `/tmp/io/f001.png` through `/tmp/io/f018.png`, 2026-11-06, decoded with `tools/decode_fetchtrace.py`"
  verification: "Measured 2026-11-06 across an 18-frame capture: page classification was read for every frame and all four pages appeared, and the torn frame's `trace 0 of 16` against `ring 3` was the only internally inconsistent frame in the set, with three later frames of the same page agreeing."

- record_id: TCL-020
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A concatenation assigned to a `+:` part-select is silently extended or truncated, and decodes to plausible values either way"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "A Verilog concatenation on the right of a part-select assignment does not have to match the slice width. Too few bits and the value is zero-extended; too many and it is truncated at the top. Neither is an error and neither produced a warning at this flow's verbosity. Measured 2026-11-07 on `gbatang_top.sv`'s MMIO ring, which packs four words of diagnostic data: the first version concatenated 108 bits into a `+:` 128-bit slice, so every field shifted down by 20 bits, and the second version concatenated 144 bits, so the top 16 bits were discarded. Both round-tripped through synthesis, place and route and a bitstream, and both decoded to words a reader would accept. The 108-bit version was caught only because two decoded fields contradicted an invariant of the instrument itself -- the ring latches only when `ram_addr[27:24] == 4`, yet several decoded CPU addresses had a high nibble of zero -- and the 144-bit version was caught only by recomputing the widths by hand before the build finished."
  consequence: "Every diagnostic packing must have its width checked mechanically, because the failure is silent and the symptoms are wrong answers rather than errors. `tools/check_ring_width.py` does this as build step `0b`, counting each term of each concatenation assigned to a `+:` slice and failing when the total differs. It refuses to pass on a symbol it cannot resolve rather than guessing, exits 2 when it matched no packings at all so a gate that checks nothing cannot report success, and was mutation-tested by appending four stray bits to a passing packing to confirm it fails. The RTL side also carries two runtime guards: a fixed marker constant in a spare field, so a shifted packing is detectable in the data itself, and a decoder assertion on the instrument's own latch invariant. Do not describe this as a coding-style matter: it produced two confident wrong hardware readings in one cycle, one of which was reported to the operator before it was caught."
  sources:
    - "This repository, `fpga/gba/src/gbatang_top.sv`: the `mm_flat` packing before and after, at the `mm_n` part-select assignment"
    - "This repository, `tools/check_ring_width.py` and `tools/build_tinygba.sh` build step `0b`"
    - "This repository, `tools/decode_fetchtrace.py`: the `0xA5C3` marker check and the `ram_addr[27:24] == 4` invariant assertion"
  verification: "Measured 2026-11-07. The gate reports `packings: 3 checked, all widths match` on the corrected tree, fails with `concatenation is 132 bits, slice is 128 bits` on a mutation, and exits 2 naming an unresolved symbol on a packing it cannot parse. The decoder raises on the pre-fix capture that produced the wrong reading."

- record_id: BRD-024
  kind: BOARD
  topic_id: BRD
  title: "The HDMI serialiser's 5x pixel clock fails to route at some placement seeds, aborting the run"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "`hclk5`, the 371.25 MHz bit clock from `pll_hdmi` that drives `clk_pixel_x5`, fails to reach the `FCLK` pin of the OSER10 serialisers at some placement seeds. The failure is a hard error rather than a convergence problem: `ERROR: Net hclk5 has no route to the FCLK of video.hdmi.serializer.gwSer0 (sink wire X181Y102/FCLKA): the router left this arc unrouted`, followed by `place and route failed`, and the run stops in roughly ten minutes instead of the fifty a full route takes. Measured 2026-11-07 across three netlists and seven placements: it occurred on `build/mm2_s3` (seed 3), `build/mm2_s4` (seed 4) and `build/fx_s5` (seed 5), so 3 of 7 attempts, and did not occur on seeds 2 or 3 of `build/fx` or on `build/mm2_s2`. The same sink wire and the same arc are named every time, which makes it a placement-dependent contention for that specific pin rather than a wiring defect in the tree: core-log entry 2 records the fix that connected `clk_pixel_x5` to `hclk5` after `pll_74` was removed, and that fix is present in every build above, since a build without it fails earlier at the pack stage with `KeyError: 'IOLOGIC_FCLK'`."
  consequence: "A route that dies early is this fault until proven otherwise, and the response is another seed rather than a design change. It is worth recognising because the error names an internal wire and a grid coordinate, which reads like a fault in the design or the constraints, and because the tree that produces it also produces clean images at other seeds -- `build/fx_s2` and `build/fx_s4` pass every gate with no relaxation. Do not diagnose it from one occurrence and do not attempt a fix before checking whether the failing seed was simply unlucky."
  sources:
    - "This repository, `build/mm2_s3/nextpnr.log`, `build/mm2_s4/nextpnr.log` and `build/fx_s5/nextpnr.log`: the `X181Y102/FCLKA` error"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: `pll_hdmi` driving `hclk5` into `clk_pixel_x5`"
    - "This repository, core-log entry 2, which records the `clk_pixel_x5` connection and the `IOLOGIC_FCLK` pack failure that preceded it"
  verification: "Measured 2026-11-07 by attempting place and route at seven seeds across three netlists and recording which reached a bitstream. Seeds `fx_s2` and `fx_s4` reached bitstreams and passed both gates; the three failures all named the same sink wire. Nothing was measured on hardware for this record: it is a toolchain observation, not a board one."

- record_id: BRD-025
  kind: BOARD
  topic_id: BRD
  title: "Cartridge IO writes reach the right registers and literal loads work; the display is simply never enabled"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "With the MMIO write ring corrected -- four explicit 32-bit words totalling exactly 128 bits, a `0xA5C3` marker in the spare 16 bits of word 0, and an entry stride of `{mm_n, 7'd0}` matching the 128-bit entry -- all eight slots carry the marker and decode consistently. On `build/gx_s4` with `test_logo.gba`, every entry reads `same cycle`: the register file's address equals the word-aligned CPU address for each write. Three purpose-built cartridges then measured the paths in isolation, each loading no FPGA rebuild. `litprobe` loaded three literals in a known pool order and wrote them to DISPCNT, DISPSTAT, VCOUNT and BLDCNT: all four values arrived correct, which refutes the hypothesis that the CPU computes a PC-relative literal address one word early. `threecase` confirmed literals load correctly with nothing preceding them, after a cartridge read, and after an IO read. `shiftpool` loaded three adjacent pool words and showed no shift. `repread` read `0x08000400` eight times consecutively and all eight returned `0xA5A50001`. Super Mario Advance reaches 84 cartridge instruction fetches, then issues `WAITCNT <= 0x40144014` and a DMA3 transfer from `0x080000FC` to `0x03001190` with `DMA3CNT <= 0x85001F00`, which is the game copying itself into IWRAM and running from there. Neither `test_logo.gba` nor Super Mario Advance leaves `DISPCNT` enabled: it stays at forced blank with no background enabled, which is why every capture is white."
  consequence: "The memory and IO paths are not the fault. Cartridge instruction fetches are byte-exact (BRD-023), data reads are correct, literal loads are correct, IO register decode separates DISPCNT, DISPSTAT, VCOUNT and BLDCNT correctly, DMA runs and WAITCNT is written. What remains is that no cartridge completes its display-enable, so the fault is past everything the ring can see. One earlier reading in this cycle was wrong and is corrected here: a counter of cartridge instruction fetches appearing to freeze after 84 was read as a hang, but Super Mario Advance copies its code to IWRAM and executes from there, so cartridge fetches stop by design -- a frozen fetch counter is not a hang and that instrument cannot see IWRAM execution at all."
  sources:
    - "This repository, `build/gx_s4/tinygba.fs` (`.fs` SHA-256 `ad3bc68d8635f54a6743b9f87b21eb17fa6655b8b07da691a00305e6dc9c227f`), seed 4, no timing relaxation"
    - "This repository, `tools/make_literal_probe_rom.py`, `tools/make_mask_report_rom.py` and `tools/make_repeat_read_rom.py`: purpose-built cartridges, each verified by disassembly against the image"
    - "This repository, `tools/decode_fetchtrace.py` with the `0xA5C3` marker guard"
    - "`/run/media/vash/MiSTer_Data/games/GBA/Super Mario Advance (USA, Europe).zip`, extracted to `build/test/roms/sma.gba`, SHA-256 `d29dec02caacbf449e2a93c6042258b0669542e102eb0e6fd0eb92a5411e0244`"
  verification: "Observed on the board 2026-11-07 across nine cartridge loads on two bitstreams. Each cartridge result was stable across every captured frame: the mask and marker reproduced identically in four separate page captures, and `litprobe` produced the same four values in the second run as the first. The ring was read through `tools/decode_fetchtrace.py`, never by eye."

- record_id: BRD-026
  kind: BOARD
  topic_id: BRD
  title: "LEAD: one literal load targeting 0x080000F8 returns zero while a data read of the same address does not"
  status: LEAD
  verified_date: 2026-11-07
  statement: "Two cartridges built to isolate the literal-load path produced results that contradict the rest of this cycle's measurements. In `build/test/readf8.gba`, a data read of `0x080000F8` returned `0x77778888`, which is the correct pool constant, while an `ldr r5, =0x77778888` at instruction `0x080000E0` -- which assembles to `ldr r5, [pc, #16]` with a target of exactly `0x080000F8` -- returned `0x00000000`. The same shape reproduced in `build/test/pairread.gba`: a cartridge data read returned `0xA5A50001` and the following literal load returned zero. Both reproduced identically across every captured frame and across repeated loads. Against this, three other cartridges loading literals through the same mechanism all returned correct values: `litprobe` returned `0x0403`, `0x0403`, `0xAAAA` and `0xBBBB`; `threecase` returned `0x11112222`, `0x33334444` and `0x55556666`; `shiftpool` returned `0xAAAA1111`, `0xBBBB2222` and `0xCCCC3333` from three adjacent pool words with no shift. No isolated variable distinguishes the failing pair from the passing three: not the preceding instruction, not the pool layout, not the target offset within the pool. All three failing and passing outcomes were read from the MMIO ring, which is verified."
  consequence: "This is recorded as a lead and not a finding, and it must not be used to explain the display fault until it is isolated. The likeliest explanation is a defect in the test cartridges themselves rather than a property of the machine: the three ROMs that show the anomaly all place a literal at `0x080000F8` in images where that address also sits at the tail of the code, and the assembler relocated the pool every time an attempt was made to force it to a chosen address. The next attempt must construct a fourth cartridge that places a literal at `0x080000F8` with no code within several words of it, and must verify the assembled address by disassembly before loading, as every cartridge this cycle was. If that cartridge also returns zero, the machine has an address-dependent read fault that every other test in this cycle missed. If it returns the correct value, the anomaly belongs to the instruments and should be withdrawn rather than carried forward."
  sources:
    - "This repository, `build/test/readf8.gba` and `build/test/pairread.gba`, disassembled with `arm-linux-gnueabihf-objdump -b binary -m armv5te` before loading; the `ldr` target and the pool word were both confirmed against the image"
    - "This repository, `build/test/litprobe.gba`, `build/test/threecase.gba` and `build/test/shiftpool.gba`: the three cartridges that pass"
    - "Captures `/tmp/f8_*.png`, `/tmp/pa_*.png`, `/tmp/lp_*.png`, `/tmp/tc_*.png` and `/tmp/sp_*.png`, 2026-11-07, MJPEG pinned at 1920x1080"
  verification: "Not verified. The contradiction was reproduced but not resolved, and no configuration was found that separates the failing cartridges from the passing ones. Recorded so the next cycle starts from the contradiction instead of rediscovering it."

- record_id: BRD-027
  kind: BOARD
  topic_id: BRD
  title: "The 0x080000F8 literal-load anomaly was a defect in the test cartridges and is withdrawn"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "`tools/make_addr_probe_rom.py` builds a cartridge that loads three cartridge words by explicit `ldr Rd,[pc,#imm]` offset -- no literal pool is emitted, so the assembler cannot relocate anything -- from `0x080000F8`, `0x08000104` and `0x08000110`, with the code ending at `0x080000EC` so the first target is separated from the last instruction by three words. The build script decodes each instruction back out of the finished image and refuses to write it unless every load targets the address and constant it claims, and the result was confirmed independently with `arm-linux-gnueabihf-objdump`. On the board all three loads returned their constants: `0x11112222` from `0x080000F8`, `0x33334444` from `0x08000104`, `0x55556666` from `0x08000110`, each reported to its own ring slot and each single-valued across every page-0 frame of a ten-second capture that also showed all four pages cycling. This supersedes BRD-026, which recorded the same address returning zero in two earlier cartridges and named the isolation test that would settle it. The literal-load path is correct at `0x080000F8`; the earlier results were artefacts of those two cartridges, both of which placed the target word where the code tail also sat."
  consequence: "BRD-026 is withdrawn and must not be cited as evidence of an address-dependent read fault. With it closed, every path this cycle can measure agrees: cartridge instruction fetches are byte-exact, cartridge data reads are correct including repeat and adjacent reads, literal loads are correct at every address tested, IO register decode separates DISPCNT, DISPSTAT, VCOUNT and BLDCNT, and DMA and WAITCNT are observed working. No cartridge completes its display-enable, and the fault therefore lies past everything the MMIO ring can observe. The lesson worth carrying is about test construction as much as about the machine: three hypotheses this project has now formed from cartridge behaviour were wrong, and each was wrong in a way its own instrument could have caught, so a cartridge built to test the machine must first be shown to test what it claims -- which is why this one verifies its own loads from the assembled image rather than from its source."
  sources:
    - "This repository, `tools/make_addr_probe_rom.py`: the cartridge, its `verify()` that decodes the image back, and its refusal to write an image whose loads do not match"
    - "This repository, `build/test/addrprobe.gba`, disassembled with `arm-linux-gnueabihf-objdump -b binary -m armv5te`: `80000cc` loads from `0x80000f8`, `80000d0` from `0x8000104`, `80000d4` from `0x8000110`"
    - "This repository, BRD-026, the lead this resolves, and `build/test/readf8.gba` and `build/test/pairread.gba`, the cartridges it withdrew"
    - "Captures `/tmp/ap3_001.png` and `/tmp/ap4_*.png`, 2026-11-07, MJPEG pinned at 1920x1080"
  verification: "Observed on the board 2026-11-07: all three ring slots matched their constants, and a ten-second capture across all four pages showed no variation in any of them. Read through `tools/decode_fetchtrace.py` with the marker present in every slot."

- record_id: TCL-021
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A power cycle clears the bitstream, and a capture from an unconfigured board looks like a stalled design"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "The Tang Console holds its configuration in volatile memory, so switching it off for a mode change and back on leaves the FPGA unconfigured until a bitstream is loaded again. The symptom is not an error: the capture device still receives a picture, the probe frame still draws, and the board looks like a design that has stopped. Measured 2026-11-07: after the console was power-cycled for a mode switch, a cartridge was loaded without a reflash and three consecutive capture cycles showed the ring empty and every one of sixteen frames on page 0. The page advances every 2^25 `clk50` cycles, about 0.67 s, so sixteen frames covering eight seconds cannot all be page 0 in a running design -- that inconsistency was the tell. After `openFPGALoader -b tangconsole build/gx_s4/tinygba.fs`, the same cartridge loaded and the same capture showed all four pages cycling in the order 0, 1, 2, 3."
  consequence: "Reflash after every power cycle, including one taken to switch the console between one-wire and two-wire mode. `tools/cap_tang.sh` exists for this and does both in one step; calling `tools/load_gba_rom.py` directly on a board whose configuration state is unknown is the mistake, and it cost three capture cycles here. The general rule this joins is the one BRD-003 already records: the board's silent failures produce plausible pictures rather than errors, so the cheapest defence is a readout whose own internal consistency can be checked -- a page that never advances, a ring whose marker is absent, or a counter that contradicts its own latch is evidence about the instrument before it is evidence about the machine."
  sources:
    - "This repository, session 2026-11-07: three capture cycles with the ring empty and all sixteen frames on page 0 after a power cycle and before a reflash"
    - "`tools/cap_tang.sh`, which flashes and captures together for exactly this reason"
    - "This repository, `fpga/gba/src/gbatang_top.sv`: the ring's clear while `~gbaon`, which is why an unconfigured or unreleased board reads all-zero rather than stale"
  verification: "Measured 2026-11-07 by the same cartridge producing an empty ring before the reflash and correct values after it, with the page distribution changing from sixteen page-0 frames to a four-page cycle."

- record_id: TCL-022
  kind: TOOLCHAIN
  topic_id: TCL
  title: "The pin-level SDRAM model drove DQ from one pipeline stage and its data from another, so every cartridge read returned zero"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "In `fpga/gba/diag/sdram_model.v` the read path has a shift register `rd_pipe` and a companion `rd_valid_pipe`, and the tri-state enable was computed from `rd_valid_pipe[cas_latency-1]` while the data register `dq_out` was loaded from `rd_pipe[cas_latency-1]` in a separate later `if` that tested the same index. The two are written on different cycles relative to the shift, so the bus was enabled one clock before its data arrived and presented the previous word. The controller samples DQ in its own DAT slot rather than at the standard CAS point, so what it captured was a stale or high-impedance bus, and `cpu_rdata` came out as a clean `0x00000000` rather than as an error. Measured on the model built with `TINYGBA_SDRAM_RTL`: every cartridge data read returned zero while the loader wrote the die byte-perfectly, `cart[0..3] = 002e ea00 ff24 51ae` matching the image's first eight bytes -- so the write path and the part were both correct and only the read capture was wrong."
  consequence: "A model that returns zero looks exactly like a dead bus or a controller that never captures, and this project spent several cycles reading it as evidence about the controller: the earlier conclusion that the real-controller build reproduced the board's failure was drawn from it and is wrong. The repair is to use one pipeline stage for both the enable and the data, which is now the case. After it, all 112 cartridge data reads match the ROM file under byte, halfword and word interpretation, and the model boots the cartridge: 18,375,892 cartridge fetch cycles and `fetch regions` `0x00000040`. Anyone debugging a read path against this model should check that enable and data agree on a stage before believing a zero, because a zero here is the failure's shape rather than its cause."
  sources:
    - "This repository, `fpga/gba/diag/sdram_model.v`: the read enable and the `dq_out` load, before and after"
    - "This repository, `fpga/gba/src/memory/sdram_gba.v`: the DAT-slot capture at `cycle[3]`, `port[0]` and `oe_latch[0]`"
    - "This repository, `tools/sim/sim_main.cpp`: the `CARTREAD` trace, sampled on the cycle `cpu_en_r` is asserted"
  verification: "Measured 2026-11-07. Before the fix, twelve cartridge reads logged `data=00000000` including reads of addresses whose contents the die dump showed to be correct. After it, 112 of 112 matched, and a 3000M-step run reported 18,375,892 cartridge fetch cycles where the same run before reported none. The result was reproduced on a clean rebuild from the committed tree."

- record_id: BRD-028
  kind: BOARD
  topic_id: BRD
  title: "With the real SDRAM controller the model boots the cartridge, executes 18M cartridge fetches, and still never enables the display"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "`build/sim_v`, built with `-DTINYGBA_SDRAM_RTL` and the official BIOS, runs `test_logo.gba` to 3000M steps: 889 frames, `cartridge fetch cycles: 18375892`, `fetch regions 0x00000040`, so the CPU executes from the cartridge through the real controller. The cartridge's literal pool loads correctly -- `0x080002B0` returns `0x08000400`, `0x080002B4` returns `0xA5A50001`, and the same for the other two check constants -- and its first store lands, `DISPCNT <= 0x0000`, which is why the screen goes black after the BIOS intro fades. What never happens is the final `0x0403` store: the only `DISPCNT` writes after the cartridge's are `0x1002`, alternating, which is the BIOS's own value. Cartridge data reads stop at `0x080002CC` and never reach the self-check reads at `0x08000400`, `0x08000800` or `0x08000C00`. The same ROM under `sdram_sim` instead boots to green, completing every check. This is the board's symptom reproduced in a simulation: BIOS intro plays, screen goes black, display never re-enabled, cartridge code running but never reaching its own checks."
  consequence: "The fault is now reproducible on demand in a simulation that can be single-stepped, which is the instrument this project has needed since BRD-011. It is not the SDRAM part or the write path -- both are proved correct -- and it is not the literal load, the IO decode or the fetch path, all measured working. It lies between the cartridge loading its literal at `0x080002C4` and the read of `0x08000400`, and the difference between the two models is the memory controller's timing. The next step is model work, not hardware: single-step the transition from the entry code to the first self-check read and compare against the array model doing the same. Run lengths matter and have misled this project twice: at 2000M steps the same build reports zero cartridge fetches, so 3000M is the budget for this ROM under the real controller."
  sources:
    - "This repository, `build/sim_v/obj_dir/Vgbatang_top` built from the committed tree with `-DTINYGBA_SDRAM_RTL` and `-DTINYGBA_BIOS_HEX` pointing at `build/test/official_bios.hex`"
    - "This repository, `tools/sim/sim_main.cpp`: the `CARTREAD`, `DISPCNTWRITE` and `cartridge fetch cycles` traces"
    - "`build/test/test_logo.gba` and `build/test/test.s`: the entry code, the literal pool at `0x2B0` to `0x2E8`, and the three self-checks"
  verification: "Measured 2026-11-07 and reproduced on a clean rebuild: 18,375,892 cartridge fetch cycles at 3000M steps, the `DISPCNT <= 0` store observed, `0x1002` thereafter, and no cartridge read reaching `0x08000400`. Frames dumped at 200-frame intervals from 200 to 800 were uniformly black from 300 onwards."

- record_id: BRD-029
  kind: BOARD
  topic_id: BRD
  title: "A retail cartridge writes and reads IWRAM but never executes a single instruction from it"
  status: VERIFIED
  verified_date: 2026-11-07
  statement: "`build/iw_s5` (`.fs` SHA-256 `b4f5a0800dd1520ae2576e5a1b9edfd2c8c5a7543c67201832a0f6c9096da695`) carries an IWRAM-execution readout on page 1 entry 4: a sticky 'IWRAM execution ever seen' bit with the last IWRAM fetch address, and separate full-width counters for IWRAM instruction fetches, IWRAM data writes and IWRAM data reads. `tr_iwfetch` is `rom_en & cpu_en & ~halt & rom_addr[27:24] == 4'h3`; the write and read counters use the same region test on `ram_addr`. With Super Mario Advance loaded, all four fields are frozen across 16 seconds: **IWRAM execution seen 0, IWRAM instruction fetches 0, IWRAM data writes 513204, IWRAM data reads 669827**, alongside `cart_fetch` 84 and `halt` 1. So the cartridge's DMA transfers land and IWRAM is being written and read in volume, but the CPU never fetches a single instruction from `0x03000000`. This supersedes core-log entry 27's reading that Super Mario Advance copies itself into IWRAM and executes from there; that was an inference from a frozen cartridge-fetch counter, and it was wrong. The cart-fetch count of 84 reproduces exactly, so the number was right and the interpretation was not."
  consequence: "The failure is no longer 'the display never turns on' but something much narrower and upstream of it: control never transfers into IWRAM. The data path there works -- 513,204 writes and 669,827 reads prove it -- so the fault is in the handover, meaning the DMA completion signalling, the branch, or an exception taken at the moment of transfer. Everything the project has measured as working remains working: BIOS handover, cartridge fetches, data reads, literal loads, IO decode, DMA transfers, clock plan, SDRAM. What has never been observed on this board is a CPU executing outside the BIOS or the cartridge's first 84 fetches. Do not cite entry 27's IWRAM claim; do not treat a frozen cartridge-fetch counter as evidence of a hang or of progress."
  sources:
    - "This repository, `fpga/gba/src/gbatang_top.sv`: the `tr_iwfetch`/`tr_iwwr`/`tr_iwrd` taps, the counters, and page 1 entry 4 in the readout mux"
    - "This repository, `tools/decode_fetchtrace.py`: `decode_iwram`, and the page-1 valid mask raised from `0x0F00` to `0x1F00` so entry 4's validity strip is not dark"
    - "This repository, `build/iw_s5/timing-gate.log` and `clock-plane.log`: `clk67` on measured-good spines, zero hold violations"
    - "`build/test/roms/sma.gba`, SHA-256 `d29dec02caacbf449e2a93c6042258b0669542e102eb0e6fd0eb92a5411e0244`"
  verification: "Observed on the board 2026-11-07 across 32 captured frames over 16 seconds, decoded with `tools/decode_fetchtrace.py`; every page-1 frame agreed on all four IWRAM fields, the cartridge-fetch count and the halt bit."

- record_id: BRD-030
  kind: BOARD
  topic_id: BRD
  title: "The real SDRAM controller reproduces the board's blank display on demand in the model"
  status: VERIFIED
  verified_date: 2026-11-08
  statement: "Two Verilator builds of the same tree, run on the same ROM with the same 3000-million-step budget, differ categorically by which SDRAM model they carry. With the behavioural array (`sdram_sim.v`), `build/test/test_logo.gba` renders its pass screen as two colours at a mean of 85 -- a green field with the white marker -- and `RetroRegen-GBA-Test-v1.5.gba` reaches its menu at 3,420 colours after 139,636,806 cartridge fetch cycles. With `-DTINYGBA_SDRAM_RTL`, which compiles `sdram_gba.v` against the pin-level `sdram_model.v`, both cartridges render exactly one colour for all 889 frames: `test_logo` white at a mean of 252 and RetroRegen white at a mean of 252, with 13,434,403 cartridge fetch cycles, roughly a tenth of the array's. The controller build's `test_logo` figure of 18,375,892 cartridge fetch cycles is identical to the number BRD-028 records from the deployed board image. The CPU is not halted and the memory FSM is not stuck: a debug build sampled the FSM across a full run and found only `MAIN`, `REQ1_WAIT`, `REQ2_BRAM` and `REQ2_WAIT`, with `sdram_ready` sampled high in the wait states as expected, and the cartridge's first `DISPCNT <= 0x0000` store lands while the final `0x0403` store never does."
  consequence: "The board's failure is now reproducible on demand without the board, which is the instrument this project needed since BRD-011 and did not have while entries 15 to 30 were working a 16-pixel bar strip. Any hypothesis about the machine's memory path can be tested here in minutes rather than in a build-and-flash cycle. The reproduction says nothing about the physical part, the board's signal integrity or its clock skew, and the pin-level model is a model of a part rather than the part, so a fault found here is evidence about the controller's logic and sequencing only. Two run-length rules travel with it: this ROM under this controller does not reach the cartridge handover before roughly 3000 million steps, and a shorter run reports no cartridge fetches and means nothing."
  sources:
    - "This repository, `tools/sim/build_gba_sim.sh` with `TINYGBA_SIM_DEFINES=-DTINYGBA_SDRAM_RTL` and `-DTINYGBA_BIOS_HEX` pointing at `build/test/official_bios.hex`"
    - "This repository, frame dumps `build/run_arr_tl/a_frame*.ppm`, `build/run_ct_arr/ca_frame*.ppm`, `build/run_tl/tl_frame*.ppm` and `build/run_ct_ctl/cc_frame*.ppm`, measured with ImageMagick `-format %k` and mean"
    - "`build/test/test_logo.gba`, generated by `tools/make_gba_test_rom.py`, and `/home/vash/Desktop/RetroRegen-GBA-Test-v1.5/RetroRegen-GBA-Test-v1.5.gba`"
  verification: "Measured 2026-11-08 at 3000 million steps per run, 889 frames each, with SDL's offscreen driver: array `test_logo` two colours mean 85; controller `test_logo` one colour mean 252 and 18,375,892 cartridge fetch cycles; array RetroRegen 3,420 colours and 139,636,806 fetch cycles; controller RetroRegen one colour and 13,434,403 fetch cycles. The controller `test_logo` fetch count matches BRD-028's board figure exactly."

- record_id: BRD-031
  kind: BOARD
  topic_id: BRD
  title: "LEAD: the array and the controller differ only on the acknowledgement cycle, and converge one cycle later"
  status: LEAD
  verified_date: 2026-11-08
  statement: "A contract trace recorded the cycles around the cartridge data read of the literal-pool word `0x080002B0` in both builds, printing the memory FSM state, `sdram_ready`, `cpu_en` and the values on `sdram_rdata`, `ram_rdata` and `rom_data`. At the cycle the acknowledgement is visible both builds report `state=5` (`REQ2_WAIT`), `ready=1` and `cpu_en=1`, and they differ: the array presents `sdram_rdata` `08000400`, which is the file's word for that address, with `ram_rdata` `00000000`; the controller presents `sdram_rdata` `e1540400`, the upper halfword of the previous instruction, with `ram_rdata` `e154e154`. One cycle later both builds are identical -- `state=0`, `cpu_en=0`, `sdram_rdata` `08000400`, `ram_rdata` `08000400` -- and both already carry the next request's address `080002b4`. The same shape repeats at `0x080002B4`, where the array acks with `a5a50001` and the controller with `08000001`. A third build with the controller's 32-bit read acknowledgement delayed until the high halfword is collected moved `sdram_rdata` at the ack to the correct `08000400` but left `ram_rdata` at `e154e154`, because `gba_memory`'s output mux only sources `sdram_rdata` while the FSM is in `MAIN` and the ack happens in `REQ2_WAIT`."
  consequence: "This is recorded as a lead and not a finding, and it must not be used to justify another patch until a trace survives its own test. The reason is that the two builds converge to byte-identical values one cycle after the acknowledgement, which cannot by itself explain a permanent difference in what the CPU executes: either the effective divergence lies outside this probe point, most likely in the double-request assembly path (`double_req`, `rom_rdata_new`, and the `rom_data`/`ram_data` mux), or the probe is misaligned relative to the consumer in a way not yet established. The attempted patch is the evidence for the caution: it made one term correct, produced a different failure in which white frames became black and the cartridge fetch count rose from 18,375,892 to 26,185,631, and was reverted unshipped. Both builds presenting a wrong `ram_rdata` at the ack, including the array one that boots correctly, is the specific observation that stops this from being a finding."
  sources:
    - "This repository, `fpga/gba/src/memory/gba_memory.sv`: the `TINYGBA_CONTRACT_TRACE` block that wrote the windows to `/tmp/ct_arr.txt`, `/tmp/ct_ctl.txt` and `/tmp/ct_fix.txt`, and the output mux at the `state == MAIN & ~dma_on_r` guard"
    - "This repository, `fpga/gba/src/memory/sdram_gba.v`: the low-halfword continuation at the `cycle[3]` slot that acked a 32-bit read one cycle early, and the `port[0]` clear at `mark done after both halfwords`"
    - "This repository, `fpga/gba/src/memory/sdram_sim.v`: the array's `cycle 1` data write followed by `cpu_ready <= 1`"
  verification: "Not verified. The cycle windows were captured from three builds at 3000 million steps, and the numbers are reproducible, but the inference from them does not hold: the convergence one cycle after the ack means the trace has not localised the mechanism, and the one patch it motivated failed on its own terms. Recorded so the next cycle starts from the trace instead of repeating it."

- record_id: TCL-023
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A capped diagnostic log makes an instrument limit look like a machine that stopped"
  status: VERIFIED
  verified_date: 2026-11-08
  statement: "`tools/sim/sim_main.cpp` printed cartridge data reads only while `n_cartread < 200`, and the counter was never reported. A 3000-million-step run of `test_logo` under the real SDRAM controller therefore stopped printing `CARTREAD` lines at exactly 200 entries, and that truncation was read as a request stream that terminated after the literal pool -- consistent with the machine wedging. Raising the cap to 4000 showed the run issues 112 reads in total at that point in the cartridge, so the cap was masking a genuine question rather than causing the appearance, but it could not have been distinguished from a real stop from the log alone. The same run also demonstrated a second, unrelated reporting hazard: with stdout redirected to a file, this build's output is block-buffered, so a terminated run loses whatever had not flushed and produces a truncated window in the middle of a line."
  consequence: "A diagnostic that truncates must say so, because a missing record and a negative result are indistinguishable in a log that has no terminator. Report the counter and a sentinel when the cap is reached, or make the cap unreachable for the run lengths in use. For the second hazard, write diagnostic windows to a file with an explicit `$fflush`, which is what the contract trace in this cycle does, and never conclude from a run that was killed before its summary line printed."
  sources:
    - "This repository, `tools/sim/sim_main.cpp`: the `n_cartread < 200` guard, now 4000"
    - "This repository, the `TINYGBA_CONTRACT_TRACE` block in `fpga/gba/src/memory/gba_memory.sv`, which writes with `$fwrite` and flushes with `$fflush`"
    - "This repository, `build/run_cap/cap.log` and `build/run_tl/tl.log`, both 3000 million steps"
  verification: "Measured 2026-11-08: the capped log ended at 200 entries and the 4000-entry log reported 112, and a killed trace run ended mid-line while the file-based trace of the same build produced a complete window."

- record_id: BRD-032
  kind: BOARD
  topic_id: BRD
  title: "Under the real controller every cartridge data read returns the previous word, and BRD-031's lead is withdrawn"
  status: VERIFIED
  verified_date: 2026-11-08
  statement: "With the sampling column calibrated against the ROM on a build whose machine works, the real-controller build returns the wrong word for almost every cartridge data read. `tools/sim/sim_main.cpp` now logs each read as the address plus both candidate words, the one visible on the `cpu_en` edge and the one visible on the previous edge, and `tools/check_cartread.py` translates the GBA address to an image offset by subtracting `0x08000000`, masks by the byte enables and scores both columns against the file. On the array build `data_now` reproduces 184 of 184 reads and `data_prev` reproduces 11, which fixes the pairing by evidence. Applying that same column, the controller reproduces 112 of 4,000 reads and fails 3,888, and the failures are a consistent one-word lag: `0x080002B0` returns `e154e154` where the image holds `08000400`, `0x080002B4` returns `08000400`, `0x080002B8` returns `a5a50001`, `0x080002BC` returns `08000800` and the shift continues through the literal pool. The frames agree: at 3000 million steps the array draws two colours at a mean of 83 to 85 and the controller draws one colour at a mean of 0 for all 889 frames, with 18,375,892 cartridge fetch cycles matching the deployed board image. This supersedes BRD-031, whose conclusion that the two builds converge one cycle after the acknowledgement was drawn from the same uncalibrated pairing that this record replaces: the builds do converge in the raw bus signals, but the word the CPU is told to consume is still one transaction behind, so convergence at the ack did not describe what the consumer received."
  consequence: "The stale-read finding stands and is now measured with an instrument that can be checked, so it should not be withdrawn again on the strength of an uncalibrated log. The root cause is still not established and no fix ships: delaying the controller's 32-bit read acknowledgement made only `sdram_rdata` correct at the ack while `ram_rdata` stayed stale, and adding a mux change to source the bus on the ack cycle as well still left the frames black and the reads one word stale, so both attempts were reverted. The remaining question is where the word is latched rather than whether it is wrong, and an assembly-path trace showed both builds holding the correct word for the self-check read of `0x08000400`, which puts the divergence in the double-request latch or its ordering. Any future cartridge-read claim must go through `tools/check_cartread.py`, because an uncalibrated claim of this kind is what cost three cycles."
  sources:
    - "This repository, `tools/sim/sim_main.cpp`: the `data_now`/`data_prev` logging and the `prev_ram_rdata` register"
    - "This repository, `tools/check_cartread.py`: the ROM offset, byte-enable masking and two-column scoring"
    - "This repository, `build/run_cal_a/ca.log` and `build/run_cal_c/cc.log`, both 3000 million steps, plus `build/run_cal_a/ca_frame*.ppm` and `build/run_cal_c/cc_frame*.ppm`"
  verification: "Measured 2026-11-08 at 3000 million steps per run. Calibration on the array build: 184 of 184 reads match with `data_now`, 11 with `data_prev`. Controller, same column: 112 of 4,000 match. Frames measured with ImageMagick colour count and mean: array 2 colours at 83 to 85, controller 1 colour at 0 across all 889 frames. The controller's cartridge fetch count equals BRD-028's board figure."

- record_id: TCL-024
  kind: TOOLCHAIN
  topic_id: TCL
  title: "A diagnostic sampling point must be calibrated against a known-good build, not asserted in a comment"
  status: VERIFIED
  verified_date: 2026-11-08
  statement: "`tools/sim/sim_main.cpp` printed `ram_rdata` on the cycle `cpu_en` was high and carried a comment asserting that this was the value the CPU received, so that a trace sampled anywhere else would report the previous transaction's data. The assertion was never tested, and the opposite was true: the column that reproduces the ROM is the one visible on the edge after `cpu_en`, which reproduces 184 of 184 captured reads on the array build while the original column reproduces 11. Three separate conclusions were drawn from the untested column and all three were wrong in turn -- a stale-read finding, its withdrawal on the strength of a run too short to reach the literal pool, and its reinstatement -- and each reversal cost a build and a run. The repair is structural: log both candidate values in one line, and let a checker score each column against the file the data is supposed to have come from, on a build whose machine is known to work, before applying that column to a failing build. The same checker also distinguishes an incomplete final line, which a capture read from a live run will contain, from a malformed record, and skips the former rather than aborting."
  consequence: "A diagnostic that asserts which cycle a value belongs to is making a claim about the design that must be validated the same way any other claim is, and the cheapest validation is to record the candidates and score them against ground truth. The concrete rule for this project is that cartridge-read claims go through `tools/check_cartread.py`, which prints the calibration and then judges the build under test with the column the calibration chose. The wider lesson is that an instrument's own documentation is not evidence about the instrument: a comment stating the sampling point was correct carried the same weight as a measurement for three cycles and was wrong."
  sources:
    - "This repository, `tools/sim/sim_main.cpp`: the `cpu_en_r`-gated print and its replaced comment, now `data_now` and `data_prev`"
    - "This repository, `tools/check_cartread.py`: `score()` and the calibration step in `main()`"
    - "This repository, `fpga/gba/src/memory/gba_memory.sv`: the port comment stating that `rom_data` and `ram_rdata` are available the cycle after `cpu_en`"
  verification: "Measured 2026-11-08: the calibration scores 184 against 11 on the array build, and the tool reports 112 of 4,000 for the controller build using the calibrated column. Cross-checked against the independent RTL-level traces in `build/run_aa` and `build/run_ac`, which showed the array delivering `08000400` on the edge after the `cpu_en` for `0x080002B0`."

- record_id: BRD-033
  kind: BOARD
  topic_id: BRD
  title: "The Verilator reproduction is not the board's failure: the model runs 18M cartridge fetches where the board runs 84"
  status: VERIFIED
  verified_date: 2026-11-08
  statement: "BRD-028's figure of 18,375,892 cartridge fetch cycles from `build/sim_v` under `-DTINYGBA_SDRAM_RTL` is a simulation result and has no board counterpart. The board record is BRD-029, which measures 84 cartridge instruction fetches from Super Mario Advance on `build/iw_s5` and additionally 513,204 IWRAM data writes and 669,827 IWRAM data reads with zero IWRAM instruction fetches. Core-log entries 31 and 32, and records BRD-030 and BRD-032, asserted that the controller build's fetch count matched the deployed board image; that assertion is wrong and is withdrawn here. The model, taken to 3000 million steps, executes some eighteen million cartridge fetches and reaches the cartridge's literal pool and its first self-check read at `0x08000400`; the board executes eighty-four fetches and never executes an instruction from IWRAM."
  consequence: "The Verilator build with the real controller is an instrument for the controller's logic and sequencing, and it is not a reproduction of the board's failure. Any conclusion that leaned on the two being the same fault must be re-read: the model demonstrably gets much further than the board, so a fault the model shows and a fault the board shows may be different faults, and a fix validated only in the model is not thereby validated for the board. The useful asymmetry is the other way round from how it was being used: the model can be single-stepped and is worth using for questions about the controller's logic, while the board is the only instrument for the questions the model cannot reach, which are signal integrity, clock phase and anything depending on the physical part. Wording rule: do not describe the model as reproducing the board's blank display; describe it as reproducing a blank display under the real controller."
  sources:
    - "This repository, `.ai/core-reference.md` BRD-028 (simulation, 18,375,892 fetch cycles) and BRD-029 (board, 84 fetches on Super Mario Advance)"
    - "This repository, `build/run_cal_c/cc.log`: 18,375,892 cartridge fetch cycles at 3000 million steps, 889 frames"
    - "This repository, `build/run_cal_a/ca.log` and frame dumps, the array control at the same budget"
  verification: "Read 2026-11-08 by comparing the two records directly rather than by recollection: BRD-028's title states the run is `build/sim_v` built with `-DTINYGBA_SDRAM_RTL`, and BRD-029 states the 84-fetch figure was observed on the board across 32 captured frames over 16 seconds. The model's 18,375,892 was independently re-confirmed this cycle in `build/run_cal_c/cc.log`."

- record_id: TCL-025
  kind: TOOLCHAIN
  topic_id: TCL
  title: "Upstream never compiles the real SDRAM controller under Verilator, so this port crossed that boundary alone"
  status: VERIFIED
  verified_date: 2026-11-08
  statement: "Upstream GBATang at `77fd0714a426ada76aee612f1192c704e89762e4` instantiates the memory system behind a preprocessor gate in `src/gbatang_top.sv`: `ifndef VERILATOR` selects `sdram_gba`, the 534-line controller that runs on hardware, and the `else` branch selects `sdram_sim`, the behavioural array. nand2mario's simulation has therefore never executed the controller, and the controller has only ever run on vendor-built Gowin hardware. This port removed that gate so `-DTINYGBA_SDRAM_RTL` can compile the controller against a pin-level part model, which is the reason core-log entry 14 had to change `gba_memory.sv` at all: the loader's and the second request's acknowledgement losses are only reachable when a real acknowledgement timing is present, and upstream's own simulation cannot see them." 
  consequence: "A divergence between this port and upstream in the memory path is expected rather than suspicious, because this port asks the controller questions upstream never asks. Conversely, upstream's hardware behaviour is not evidence that this port's simulation is right, and this port's simulation result is not evidence about upstream's hardware: the two projects are measuring different things with different instruments. When a memory-path difference appears against upstream, classify it first as 'this port's simulation-only concern' or 'a change to hardware behaviour', because entry 14's changes are the former and were shown this cycle to be load-bearing in simulation and not the cause of the present fault."
  sources:
    - "`/run/media/vash/GIT/tangcore/gbatang/src/gbatang_top.sv` at `77fd0714`: the `ifndef VERILATOR` gate around the `sdram_gba` instance and its `else` array branch"
    - "`/run/media/vash/GIT/tangcore/gbatang/src/memory/sdram_gba.v`, diffed against this repository's copy: cosmetic slang changes plus the documented `[31:15]` to `[31:16]` repair, with the acknowledgement timing unchanged"
    - "This repository, core-log entry 14, which records why the `gba_memory.sv` changes were needed once the controller was compiled"
  verification: "Read from the upstream checkout 2026-11-08 after confirming its HEAD is the pinned `77fd0714a426ada76aee612f1192c704e89762e4`, and the `gba_memory.sv` divergence was confirmed by diffing against the same checkout."
