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

---
