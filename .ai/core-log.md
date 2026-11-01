## 1 COMMIT Unreleased 2026-10-31T10:31:45-07:00

#### Coming From:

Unreleased cc1ce48

#### Purpose:

Open TinyGBA by vendoring nand2mario's GBATang GBA core into the open flow for the Tang Console 138K, get it through synthesis and place-and-route, and build the instruments the first hardware session will need.

#### Outcome:

The repository now carries GBATang at commit `77fd0714a426ada76aee612f1192c704e89762e4`, fetched as the `gbatang` submodule of nand2mario's `tangcore` and vendored verbatim into `fpga/gba/src/` except for the files marked `TinyGBA:` in place; `fpga/gba/tinygba.cst` is GBATang's `src/boards/console138k.cst` with the four clock placements added, and `fpga/gba/tinygba.sdc` re-derives the clock plan for a parser with no `create_generated_clock`. `tools/build_tinygba.sh` is the flow: yosys 0.69+260 with `read_slang --std 1800-2017 --single-unit`, the cell libraries passed both as `-v` and as `--blackboxed-module`, `synth_gowin -family gw5a`, `nextpnr-himbaechel` for `GW5AST-LV138PG484AC1/I0`, an Fmax gate and `gowin_pack`. Getting the design through slang took nine documented changes: the two vendor-style `` `error `` directives became comments; the uninitialised parameters in `gba_dma_module.sv` and `gba_sound_ch1.v` were given inert defaults, every instantiation overriding them; `kbd_data` in `iosys_bl616.v` became a local reg because it was declared `input reg` and assigned procedurally; three mixed blocking and non-blocking assignments and one block-scoped register initialiser were made consistent in `gba2hdmi.sv`, `hdmi.sv`, `packet_picker.sv` and `sdram_gba.v`. `fpga/gba/src/hdmi/` was replaced with TinyTang's copy of hdl-util's transmitter, which already carries those same open-flow fixes and has run on this board, exactly as TinySNES did. `pll_74` was replaced by a hand-written single-output 371.25 MHz `gowin_pll_hdmi.v` with a `CLKDIV` divider making the pixel clock, and both cells are pinned, because the two-output wrapper is the arrangement that produced no picture at all on three TinySNES images. Two findings were worth the cycle on their own. `read_slang` compiles each file as its own unit unless `--single-unit` is passed, so the board defines in `console138k.v` never reached the design and the build silently dropped both USB HID hosts, the 12 MHz PLL and `linebuffer.v`'s M138K block-RAM path. And GBATang's generated IP instantiates 2307 `MUX2` cells and 38 bare `LUT5` cells, which this device cannot place: `tools/cells_behavioral.v` defines both behaviourally and the build shim strips the library copies, so they synthesise to LUT4s. USB HID was then disabled in `console138k.v`, matching TinySNES's own board configuration, which removed a clock domain and two `usb_hid_host` instances and dropped hold violations at seed 1 from 54 to 7. Synthesis passes at 27,888 LUT4 of 138,240, 121 BSRAM, 3 PLL. Place and route does not: hold violations on `clk16` persist at every seed tried. On the initial netlist seeds 1 to 16 gave 54, 15, 17, 43, 25, 19, 14, 11 and 18 among them, and on the USB-less netlist seeds 1 to 8 gave 7, 16, 22, 31, 21, 34, 5 and 22, so no placement is clean and seed 7 at 5 is the best. Post-route Fmax passes everywhere it was read, `clk16` at 18.10 to 18.68 MHz against 16.75, `hclk` at 74.79 to 82.67 against 74.25, `clk50` at 76.15 and `clk67` at 119.80, so the failure is hold and not setup. Every violation has the same shape: about -5 to -6 ns of `clk16` clock skew arriving at a `mem.mem_bios` BSRAM `CLKA` pin, with 2381 `clk16` sinks falling back from dedicated clock routing to general routing, and only two nets in the design routed on global resources. `NPNR_GOWIN_CLK_FIRST=clk16`, the arch's own clock-first knob that TinyNES uses for `bus_clk`, was tried on three seeds and changed neither the skew nor the count, which matches TinySNES's note that it does not take. There is no `BUFG` primitive in the GW5A cell library, so global promotion cannot be forced from RTL. No bitstream exists and nothing was deployed. Separately the SDRAM question was scoped: the module advertises 64 MiB with two W9825G6KH-6 dies while the 40-pin header brings out 38 conductors, which is one die's worth, and GBATang's controller selects between two dies by driving that single CS wire from address bit 25 on every activate, read and write and refreshing each die in turn. `fpga/gba/diag/sdram_probe.v` tests that by writing patterns to the low die, their complements to the high die, and re-reading the low die, so an absent second die cannot pass. `fpga/gba/diag/tb_sdram_probe.sv` drives it against two models under `tools/run_diag_sim.sh` and both directions pass, all sixteen patterns correct against GBATang's 64 MiB `sdram_sim` and eight green followed by eight red against a model whose die select does nothing. Two defects in the probe were found by that testbench rather than by inspection: the transfer counter was conflated with the word index, so the high die was never addressed at all, and the model checked `cpu_addr[23]` where the controller uses `cpu_addr[25]`. `gba2hdmi.sv` and `gbatang_top.sv` carry the diagnostic readout, a colour-bar video proof under `TINYGBA_VIDEO_TEST` and sixteen probe bars under `TINYGBA_SDRAM_TEST`, and all three configurations synthesise, 65 MB production, 61 MB video and 58 MB SDRAM. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed and that `.ai/core-reference.md` remains empty rather than being filled with unverified records, and validated this entry as entry 1 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of one against the 100-entry limit.

#### Next Steps:

Clear the hold violations on `clk16`, which is the single blocker between this tree and a bitstream, and do it by understanding the clock distribution rather than by sweeping more seeds, since twenty-four placements have now failed and the best is five violations; the shape to investigate is that 2381 `clk16` sinks take general routing while only two nets in the design get global resources, so the question is which nets nextpnr promotes and whether the four `INS_LOC` PLL sites inherited from TinyNES and TinyTang suit a design whose main clock fans out across the whole die, and the alternative if promotion cannot be influenced is to reduce `clk16`'s fanout by moving the BIOS block RAM or splitting the domain. Then produce two bitstreams and put them on the Tang in this order: `TINYGBA_VIDEO_TEST`, which draws colour bars from `gba2hdmi`'s own raster on `clk50` and therefore tests the PLL and divider topology, the four clock placements, the OSER10 path and the TMDS pair without depending on `clk16` at all, and then `TINYGBA_SDRAM_TEST`, whose sixteen bars answer whether the second 32 MiB die is reachable. A black screen on the first means the video path is wrong and says nothing about the machine. Only after both does the machine itself matter, and RAM, timer and save behaviour are all unverified. Do not reintroduce USB HID without measuring its effect on the clock domains, and do not carry the GPU's `MUX2` and `LUT5` instances back into the build expecting them to place.

#### Files Modified:

- .gitignore
- THIRD_PARTY.md
- fpga/gba/LICENSE-GBATANG-GPL-3.0
- fpga/gba/tinygba.cst
- fpga/gba/tinygba.sdc
- fpga/gba/src/
- fpga/gba/diag/sdram_probe.v
- fpga/gba/diag/tb_sdram_probe.sv
- tools/build_tinygba.sh
- tools/cells_behavioral.v
- tools/fs_to_bin.py
- tools/run_diag_sim.sh
- tools/sweep_tinygba_seeds.sh

#### Status:

- Build: FAIL
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 2 COMMIT Unreleased 2026-10-31T13:00:16-07:00

#### Coming From:

Unreleased 2478ca3

#### Purpose:

Clear the clk16 hold violations that stood between this tree and a bitstream, and produce the production, video-proof and SDRAM-probe images for a first hardware session without deploying any of them.

#### Outcome:

The `clk16` blocker is understood and gone. A PLL output reaches the global clock spine only through a clock-plane wire, `T[LR]PLL<n>CLK<lane>`, and the GW5AST-138C database carries 24 of those wires but only two pips that drive one, both from `CLKOUT0`: `MPLLCLKOUT0 -> TLPLL0CLK0` on the left-edge PLL sites and `MPLLCLKOUT0 -> TRPLL0CLK0` on the right-edge ones. `CLKOUT1` through `CLKOUT6` connect no further than the tile-local `F1..F6` and `CLK1`/`CLK2` lanes, so a clock on a secondary PLL output is a dead end whatever the placer is told to do. `clk16` sat on `pll33`'s `CLKOUT1`, reached none of its 2381 sinks on global resources, and nextpnr fell back to 2381 point-to-point arcs whose skew, -5.38 ns at worst into `mem_bios`'s BSRAM `CLKA`, failed hold on all 24 placements tried. That also explains why `NPNR_GOWIN_CLK_FIRST` changed nothing: priority was never the constraint. Three fixes were tried in a scratch copy before any of this was written to the tree. Dividing by one in a `CLKDIV` to move the net onto an HCLK lane failed, because `CLKDIV_O10` has no path to a spine either. A real `BUFG`, declared as a blackbox so synthesis would keep it, placed but the global router answered "no clock gate reaches both its source and its loads". A spare PLL on `PLL_R[2]` with `CLKOUT0` also failed, because that site's only plane wire is `TRPLL0CLK0` and `clk50` already holds it. What works is giving `clk16` its own PLL, `pll16`, on `PLL_L[0]`, the site whose `CLKOUT0` owns the free `TLPLL0CLK0` wire; `pll33`'s `CLKOUT1` is left unused. A six-seed sweep of the fixed netlist gave zero `clk16` hold violations at every seed, against a previous best of five at seed 7 out of twenty-four placements. Seeds 2 and 6 failed on `clk67` instead, at -1.18 ns of skew from `CLKOUT2`'s 255 failed dedicated routes, which is the same class of defect as `clk16` had but milder; it is recorded as an open limitation because it does not block a bitstream at a clean seed. Two further defects were found on the way. `pll_74` had been removed without reconnecting its 371.25 MHz output, leaving `clk_5x_pixel` undeclared in `gba2hdmi.sv`, so the three `OSER10` serialisers had both `FCLK` and `Q` unconnected and the video-proof image would have drawn a black screen; TinySNES's TCL-006 records this exact failure and the same `X181Y102/FCLKA` route error, and the fix is the shape it documents, a `clk_pixel_x5` input fed from `hclk5`. Separately, `pll_27.v` and `pll_33.v` set their parameters with `defparam`, and because `PLL` is a blackbox every string parameter arrived at the packer as raw ASCII, `FCLKIN` `"27"` showing up as `0x3237` and `CLKOUT0_EN` `"TRUE"` as its four bytes, so both files were converted to `#(...)` parameter style. Producing a bitstream then needed an oracle run, because `pll_33` runs at `FVCO` 1809 MHz (27 x 67) and apicula's charge-pump model covers only 650 to 1300 MHz and refuses to extrapolate. Gowin EDA 1.9.11.03 was made to run headless here, overriding a bundled `libfreetype` that clashes with system `libfontconfig`, and a minimal project reproducing `pll_33`'s operating point was built; the vendor warns `PA1019` and builds anyway, exactly as it did for TinyNES's three above-band points. Its bitstream gives `FLDCOUNT` 16, `A_ICP_SEL` 240, `A_LPF_RES_SEL` R4 and `KVCO` 7, where the ladder would have answered R5 with 137, which continues the above-band pattern already documented for the other three points. A search had already shown the plan admits no in-band alternative: `clk16`, `clk50` and `clk67` all carry the prime 67, so a common `FVCO` must be a multiple of 201, and the only `Fpfd` values inside the measured band are 27, 25 and 50, all coprime to 67, so no configuration is simultaneously in band for `Fpfd` and `FVCO`. The measured point was added to the apicula fork and the packed bitstream was then verified by unpacking it and reading every PLL's derived attributes back: `pll16` and `pll33` both give 16/240/R4, matching the vendor exactly, and `pll27` and `pll_hdmi` still give 190/R4 with `FLDCOUNT` 32 and 16, so the parameter conversion did not disturb the two points that were already measured. Three images were built from the committed tree at seed 1, all with zero hold violations, `clk16` on global resources and every clock passing the timing gate: production `tinygba.bin` SHA-256 `4c88b84cbc4f146be7ede6f50ec2a04d9547345fcb96ee84ed79d13fec23b1f3` with `clk16` 19.57 against 16.75, `clk50` 118.65 against 50.25, `clk67` 111.47 against 67.00 and `hclk` 96.02 against 74.25; `TINYGBA_VIDEO_TEST` SHA-256 `03123f45432358f23e9edc0ca8cff4f0cad9f5a1422349f7dc323427382883f5`; and `TINYGBA_SDRAM_TEST` SHA-256 `c278fa212f32fe3600c934b14cbd1c7fbfcf376e8e3d982f1b30cac3bd09c36a`. Nothing was deployed and the Tang was not connected to, at the user's instruction, and no hardware result exists. The syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, and validated this entry as entry 2 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of two against the 100-entry limit.

#### Next Steps:

Load the three images in the order the diagnostics were designed for and keep the Tang connection behind the user's permission: `TINYGBA_VIDEO_TEST` first, which should draw eight vertical bars with a white top-left marker and a red right edge and tests the PLL and divider topology, the clock placements, the OSER10 path and the TMDS pair without depending on `clk16` or the machine, so a black screen means the video path is wrong and says nothing about the GBA; then `TINYGBA_SDRAM_TEST`, whose sixteen bars answer whether the second 32 MiB die is reachable, eight green followed by eight red meaning it is not; and only then production `tinygba.bin`, where RAM, timer and save behaviour are all unverified and the BIOS block RAM, SDRAM capture and the GPU have never run on hardware in this port. `clk67`'s -1.18 ns of skew on seeds 2 and 6 is the next routing defect of the same kind `clk16` had and should be settled by understanding `CLKOUT2`'s missing plane pip rather than by sweeping seeds, since seed 1 is clean only by placement luck; the fix is likely to move `clk67` onto a `CLKOUT0` of its own once the two free right-edge sites are understood. Do not reintroduce USB HID without measuring its effect on the clock domains, and do not carry the GPU's `MUX2` and `LUT5` instances back into the build expecting them to place.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/pll/pll_16.v
- fpga/gba/src/pll/pll_27.v
- fpga/gba/src/pll/pll_33.v
- fpga/gba/tinygba.cst
- fpga/gba/tinygba.sdc
- tools/build_tinygba.sh

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 3 COMMIT Unreleased 2026-10-31T16:07:43-07:00

#### Coming From:

Unreleased 5b67502

#### Purpose:

Put the first TinyGBA images on the Tang in one-wire mode and read what the hardware actually does, so the video path, the SDRAM and the machine are each answered from the board rather than from the build.

#### Outcome:

The video path works and the machine does not run. The first load was the `TINYGBA_VIDEO_TEST` image, and it produced a locked 720p picture on the bench's capture card with a correct letterbox, which by itself proves the PLL and divider topology, the four `INS_LOC` placements, the `OSER10` serialiser path and both TMDS pairs -- none of which had ever run on this board in this port. What it did not show was the test bars: the active area came back uniformly black at exactly 960 pixels wide, from x=160 to x=1119. That width is `XSTART_O`..`XSTOP_O`, gba2hdmi's overlay window rather than its 1080-wide video window, and the cause is `iosys_bl616.v`'s `reg overlay_reg = 1;`: the OSD overlay powers up asserted and is only cleared by command 0x08 with x[0]=0, which the BL616 menu sends and nothing sends in one-wire mode. The overlay was covering the framebuffer with an empty menu's black, so the test pattern had almost certainly been written correctly the whole time and was simply underneath it. The diagnostic builds now tie `overlay` low through two nested `ifdef`s rather than one `||`, because TinySNES records that slang does not evaluate `elsif A || B` as written, and a third define `TINYGBA_OVERLAY_OFF` suppresses it in an otherwise production build for bench work; production keeps the OSD, since the menu is real functionality on the console and the BL616 closes it in normal use. Reloaded with the overlay off, the bars appeared in the right order with the correct colours -- red, green, blue, white, yellow, cyan, magenta, then grey -- over a 1080-pixel active area centred in the letterbox, full height, with the white 16x16 marker measuring 72 by 72 pixels at the top-left corner, exactly 16 source pixels at the 4.5 scale this mode uses. One anomaly in that picture is the instrument's own: a 104-pixel red band at the right edge where grey should continue, which is `reg [2:0] bar; bar = x / 8'd27;` truncating bar 8 to bar 0 for source x 216 to 239, and 23 source pixels is 104 display pixels to the pixel. That defect is in the diagnostic pattern and not in the core, and it is left recorded rather than quietly fixed so the next reader does not mistake it for a video fault. The `TINYGBA_SDRAM_TEST` image answered worse: the status band read green, so the probe reached `done`, but only patterns 0 and 1 of sixteen read back correctly, bars 0 and 1 green and bars 2 through 15 red, with the low die failing five of its own eight patterns and the high die failing all eight. The probe drives `cpu_be` as 4'b1111 and writes full 32-bit words, so a narrow write is not the explanation, and the pattern set -- walking ones in the low byte, then 0x00010000, 0x10000000, and four multi-bit patterns -- cannot localise which bits fail: the honest statement is that bits 0 and 4 read back and every other pattern tested does not, so the data path is badly broken and a bit-level test is needed before the fault can be named. The production image showed a 960-pixel black window, which is the overlay again and is expected in the shipping configuration on a bench with no menu driving it; a build of the same tree with only `TINYGBA_OVERLAY_OFF` added ran to a 1080-pixel active area that was uniformly black, so the machine itself draws nothing and cannot be said to boot. That is consistent with the SDRAM result, since the GBA's work RAM and cartridge space live there and only the BIOS is in block RAM. `clk67` is the likely connective tissue and the reason this cycle could not get further: the SDRAM clock still misses dedicated routing on all 255 of its sinks, and unlike `clk16` it cannot be moved onto its own clock-plane wire, because the GW5AST-138C database carries exactly two such wires, `TLPLL0CLK0` and `TRPLL0CLK0`, and `clk16` and `clk50` now hold both. Every one of this cycle's placement failures was that same `clk67` hold defect at -1.2 to -1.9 ns and none was `clk16`; the netlist change from the overlay fix moved the clean seeds, so the video image was built at seed 5 with seven of eight seeds clean, and production and the SDRAM probe at seed 2. A stale `build/prod/tinygba.bin` survived the failed seed-1 rebuild and would have deployed the pre-fix image had it been loaded by directory name, so the deploy set was staged under `build/deploy` from explicitly named clean-seed directories with a `SHA256SUMS` file, and the PLL fuses were read back out of the exact production image before loading to confirm 16/240/R4 at 1809 MHz. All three images loaded with `openFPGALoader -b tangconsole` from oss-cad-suite, which is the one-wire path, and the results were read from the capture card as sequences of frames rather than single grabs, because the first frame after a load is usually black while the card has not yet locked. No user test was run: the machine never produced a picture, so there was nothing for the user to accept. The syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, and validated this entry as entry 3 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of three against the 100-entry limit.

#### Next Steps:

The next cycle should settle `clk67` before anything else, because it is the common cause of both remaining faults: the SDRAM reads back almost nothing and the machine never draws, and the SDRAM clock is the one clock in the design that still reaches its 255 sinks on general routing with 1.2 to 1.9 ns of skew. The two clock-plane wires are spent, so the options are to measure whether `CLKOUT2` can reach a spine at all by the oracle method this cycle used for the FVCO point, or to stop giving `clk67` a PLL output and derive the SDRAM clock in the fabric where its skew is at least visible, or to reduce its fanout so general routing carries it with less skew; an oracle bitstream with the SDRAM clock on `CLKOUT0` of a spare site would answer the first in one step. Only after that does the SDRAM itself mean anything: rerun the probe with a pattern set that walks every data bit individually and every address bit, so a failure names a lane instead of a bar, and check `cpu_be` and DQM handling against the 38-conductor header finding already recorded, since this module advertises two 32 MiB dies on a bus that brings out one die's worth. The GBA machine, the BIOS block RAM, timers, saves and the GPU are all still unverified and cannot be judged until SDRAM works. Two smaller items: fix the `reg [2:0] bar` truncation in the video pattern so the right-hand band is grey as documented, and decide whether the shipping configuration should clear the OSD itself rather than depend on the BL616, since a core that shows a black 960-pixel window until a menu command arrives looks broken to anyone who loads it standalone.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: NOT RUN

---

## 4 COMMIT Unreleased 2026-10-31T17:18:15-07:00

#### Coming From:

Unreleased e4e9859

#### Purpose:

Settle `clk67`, the one clock still reaching its sinks on general routing and the likeliest cause of both the failed SDRAM readback and the absent machine picture, by measuring what a PLL's second output can reach rather than by sweeping more seeds.

#### Outcome:

`clk67` is fixed, and the fix was a missing database entry rather than a design compromise. The question was whether a PLL's `CLKOUT2` can reach the clock plane at all, since apicula's database carried only two pips into the 24-wire plane and both came from `CLKOUT0`. Two vendor builds answered it. The first enabled `CLKOUT0` and `CLKOUT2` on a `PLL` at `PLL_L[0]`, each clocking a fourteen-bit register bank so both had to be clock-routed, and the unpacked bitstream showed `(54,93) SPINE8 <= TLPLL0CLK0` and `(54,93) SPINE10 <= TLPLL0CLK2` in the same build. The second was the control: `CLKOUT0` disabled and only `CLKOUT2` enabled, which still produced `SPINE8 <= TLPLL0CLK2` driving 48 `GB00` sinks. So `CLKOUT2` does reach the plane, on lane 2, and the lane number follows the output number. apicula simply had no pip to say so, which is why `clk67` fell back to general routing on all 255 of its sinks with 1.2 to 1.9 ns of skew and cost several clean seeds on every netlist change. The pip was added to `_gw5a_pll_clk_wires` as `(0, 'CLKOUT2') -> 'TLPLL0CLK2'`, the fork's chipdb was regenerated with `python3 -m apicula.chipdb_builder GW5AST-138C` under `GOWINHOME`, and nextpnr-himbaechel was rebuilt with `~/tools/rebuild-nextpnr.sh`, which exists because the architecture is generated at make time and the option spelling is easy to get wrong. The regenerated database was diffed against the previous one before use: exactly one pip added, none removed, no other tile field changed, and the only node change is that `TLPLL0CLK2` now merges the PLL tile wire at `(27,1)` with the bridge wire at `(54,93)`, which is precisely what the code's own comment says the mapping is for. On the design, `clk67` and its phase-shifted off-chip sibling `clk67_p` moved from `pll33`'s `CLKOUT2` and `CLKOUT3` to the same outputs of `pll16` at `PLL_L[0]`, which is possible because `clk16` and `clk67` share a VCO: 1809 MHz is 108 times 16.75 and 27 times 67, so one loop divides to both. `clk67_p` keeps the 16/7 fine-phase shift `pll_33` gave it, and `pll33` now drives only `clk50`, its other outputs left unconnected on purpose. The result is categorical where the old behaviour was seed-dependent: across seeds 1 to 8 every placement now routes `clk67` on global resources with zero failed dedicated routes and zero hold violations, against three clean seeds of six before, and `clk67`'s Fmax rose to 125 to 141 MHz against a 67 MHz constraint. The production, video-proof, SDRAM-probe and overlay-free machine images were all rebuilt at seed 1 with zero hold violations and every clock passing, and all four now report both `clk16` and `clk67` on global resources. The apicula fork was committed as `495661a`, which also carries the previously uncommitted FVCO 1809 MHz measurement from entry 3's work. Nothing was deployed: the Tang was not connected to, at the user's instruction, so whether the `clk67` fix repairs the SDRAM readback and the absent picture is not known and must not be assumed. The syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, and validated this entry as entry 4 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of four against the 100-entry limit.

#### Next Steps:

Load the rebuilt images in the order the diagnostics were designed for, once the user releases the board: the video proof first, whose result should be unchanged from entry 3 and is only a control for the rebuild; then the SDRAM probe, which is the real question, because the readback failure of entry 3 was measured while `clk67` was on general routing with more than a nanosecond of skew across the SDRAM controller's own registers, and if the data path now reads back correctly the SDRAM fault was the clock all along; and then the overlay-free machine image, where any picture at all would be the first evidence this port has produced of the GBA itself running. If the SDRAM still fails with `clk67` clean, the next step is the bit-level probe entry 3's Next Steps specified, since the current pattern set cannot name which data lane fails and bits 0 and 4 are the only two known to read back. The `reg [2:0] bar` truncation in the video pattern is still unfixed and still makes the right-hand band red instead of grey; it is harmless but should be corrected before the pattern is used as a reference again. `README.md` remains a single heading and documents neither the build nor the deploy, which is a real gap for anyone picking this up cold.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/pll/pll_16.v
- fpga/gba/tinygba.sdc

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---
