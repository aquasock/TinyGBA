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
## 5 COMMIT Unreleased 2026-11-02T00:18:29-07:00

#### Coming From:

Unreleased 1bc4149

#### Purpose:

Put the rebuilt images on the board for the first time, and find out whether clean `clk67` routing repairs the SDRAM readback.

#### Outcome:

The video path works and the SDRAM was never broken. Both results are hardware readings from the Tang Console 138K, deployed one-wire with `openFPGALoader -b tangconsole` from the oss-cad-suite copy.

`01_video` draws eight vertical bars — red, green, blue, white, yellow, cyan, magenta, grey — with the 16x16 white orientation marker at the top LEFT and the wide grey band on the right, in the correct orientation and correctly letterboxed. That is the first picture this port has ever produced, and it proves the whole video chain on this board: the PLL and divider topology, the four clock placements in `tinygba.cst`, the OSER10 serialiser path and the TMDS pair. It also validates entry 4's `clk67` clock-plane fix in the only way that counts.

`02_sdram` then reported two green bars and six red on the low die, all red on the high die. Read against the probe's own pattern table, that fits one explanation: the low halfword of a 32-bit access reads back and the high halfword does not. It is not the memory. `gba_memory.sv` documents a 32-bit SDRAM read as `sdram |rd_lo| wait|rd_hi|ready| data` with `cpu_ready` in the cycle BEFORE the data, so at the ready cycle `cpu_rdata` holds the low halfword just captured beside the PREVIOUS high halfword, and `sdram_probe.v` took its comparison there. Assuming the stale high halfword is whatever the previous pattern wrote predicts all eight bars exactly, including that bars 0 and 1 pass and the other six fail — which is what hardware showed. The fix is two steps in `S_WAIT`: latch on `cpu_ready`, take the data on the following clock, and do not re-test `cpu_ready` in the second step because it is a registered pulse and is gone by then. `sdram_gba.v` is unchanged.

Three instrument faults were found and corrected on the way, and all three had already produced a confident wrong reading. A first lane-mode probe wrote `0xFFFFFFFF` and displayed `cpu_rdata[15:0]` — all sixteen bits green, and it could not have failed for any input, because 0xFF is the one byte a dead, floating or stuck-high lane all produce. The probe sampled one clock early, above. And the first attempt at the sample-point fix latched on `cpu_ready` and then waited for `cpu_ready` to still be high, which never happens.

The bench could not have caught any of this, and that is the finding worth carrying forward. `tools/run_diag_sim.sh` compiles `sdram_sim.v`, a logic-level stand-in that takes `cpu_be` and array-indexes memory, so `sdram_gba.v` — the controller — is never compiled by any testbench and no bug inside it can fail a run. Its PASS lines are true and say nothing about the controller. `fpga/gba/diag/sdram_model.v` and `tb_sdram_controller.sv` were started to close that gap: the model sits at the pins, decodes ACT/READ/WRITE/PRE/MRS/REF off `nCS`/`nRAS`/`nCAS`/`nWE`, honours DQM on write and on read, and holds read data until the next READ as a real part does. It reproduces the controller's own readback but its timing is not yet faithful enough to be an authority, and it is committed as work in progress rather than as a reference. Two things it needed before it could see anything: the controller samples at its own rotate slot rather than at the CL=2 point, so a part that drives for `cas_latency` clocks gives ZZZZ; and `sdram_gba` relies on the device powering its RV-port register to zero — it is only ever cleared, never initialised, and with no reset term iverilog leaves it X, which propagates into `nCS` and `nWE` until the controller issues no read or write at all. That is the same shape as the undriven `PAL` that cost TinySNES two days.

The corrected probe did not reach the board. Place and route ran 26 minutes and 241,000 iterations without converging, oscillating around 8,000 unrouted nets rather than trending down, and failed. The lane-probe build of nearly the same netlist completed the whole flow in 14 minutes, so this is the seed sensitivity the project already records rather than a property of the change. Nothing is lost: the fix is committed and the netlist is reproducible.

#### Next Steps:

Rebuild the corrected `TINYGBA_SDRAM_TEST` image with a different placement seed or through `tools/sweep_tinygba_seeds.sh`, which exists for exactly this, and read the sixteen bars. Sixteen green means the SDRAM is 32 MiB and sound and the two red-die questions are settled; eight green then eight red means the single-CS die select does not work and the module gives 32 MiB, which the GBA can live with for every cartridge that fits. Then `04_machine` with a real cartridge — `tools/load_gba_rom.py` streams one over the core's own UART and is validated against a retail image (Nintendo logo, header byte `$B2`, complement check), sending no header prefix because the GBA core has no 64-byte header handshake and the cartridge header is simply the first bytes of the stream. It has never been run against a live core. Bear in mind when reading the result that `TINYGBA_OVERLAY_OFF` exists because the OSD powers up asserted and its 960-pixel window hides the framebuffer behind an empty menu's black; a production build without that define will look black in one-wire mode and that is not a machine fault. `README.md` still documents neither the build nor the deploy.

#### Files Modified:

- fpga/gba/diag/sdram_probe.v
- fpga/gba/diag/sdram_model.v
- fpga/gba/diag/tb_sdram_controller.sv
- tools/load_gba_rom.py
- .ai/core-log.md

#### Status:

- Build: PASS for 01_video, 02_sdram, 03_prod, 04_machine; the corrected SDRAM probe FAILED place and route at seed 1 after 26 minutes
- Deployment: one-wire, 01_video 33c639b1, 02_sdram 960e2ae0
- User Test: PASS video chain, eight bars in correct orientation; SDRAM result requires the rebuild above

---

## 6 COMMIT Unreleased 2026-11-02T09:27:00-07:00

#### Coming From:

Unreleased ce62d6d

#### Purpose:

Give this port the two instruments the sibling SNES project only acquired after fifty cycles -- a clock-plane gate and a gate-level readout of the shipped netlist -- and make the first cartridge a discriminator rather than an experiment, without touching the Tang.

#### Outcome:

Three findings changed what this project can claim, and one of them contradicts a result already on record. The first is that every image this project has flashed had `clk67` crossing no clock-plane bridge pip at all, which is the condition core-log entry 4's fix was supposed to have removed: resolving `build/deploy/SHA256SUMS` to the routed netlists it was packed from, `build/vsweep_5`, `build/psweep_2`, `build/machine_s5` and `build/diag_sdram_s2` all show `clk16`, `clk50` and `hclk` on bridge pips and `clk67` on none, yet all four passed the hold check and the Fmax gate. So the SDRAM reading in entry 5 was taken on an image whose SDRAM clock was on general routing, and the eight-red-die result cannot be attributed to the probe fix until the corrected probe is flashed on an image whose `clk67` is on the plane. `tools/clock_plane_report.py` now reads this out of `netnames[<clock>].attributes.ROUTING` and `tools/build_tinygba.sh` runs it as a gate that fails on a dead pip or on a required clock crossing no pip; the pip table is inherited from TinyNES DEV-009 and DEV-017 through TinySNES and every entry names its origin, with this project's own hardware results separated into their own table and `clk67` at `TOP2` marked `partial` because the SDRAM probe clocked its own few hundred flip-flops on it and nothing has clocked 2381 sinks on it. The second is that the `syn_keep` marks on `gba_memory.sv`'s port list were inert. Measured on this exact flow with five identically shaped nets across four attribute spellings, only `(* keep *)` survives `read_slang` plus `synth_gowin` and the other three spellings are deleted, and the attribute must precede the declaration or elaboration fails outright. With the comment syntax, 0 of 13 fetch-path names survive in the netlist; with the attribute, 13 of 13 survive at honest widths, checked by `tools/gatelevel_report.py`, which reports per named net whether it exists and whether every bit has a driver. The conversion is a change of auditability and not of behaviour, and saying otherwise would have been the easy mistake: the netlist has the same 4734 flip-flops and the same set of 322 undriven wires before and after, and the cell count moves a few percent because ABC sees a different optimisation boundary. The remaining 99 comment attributes in 14 other files are still inert and are left as an open item rather than swept in the same cycle. The third is that `TINYGBA_OVERLAY_OFF` currently has no buildable machine image. Six seeds of that configuration all fail the `clk67` Fmax gate at 33.6 to 36.0 MHz against 67.0, on a 26-stage 29.77 ns path running from `cpu_mem_rdata` through `mem.rom_data`'s read muxes and `cpu.cmd` back into `sdram.SDRAM_BA`. That is not this cycle's doing and not a bad seed: the tree as it stood before any of these changes, synthesised fresh and routed at seed 5, fails the same gate at 38.76 MHz, while the same tree without the define passes at 171.26 MHz at the same seed with a 5.84 ns path, and the netlist from Oct 31 re-routed at seed 5 passes at 154.01 MHz. So the trigger is the machine configuration itself and it is open. What did build: `TINYGBA_SDRAM_TEST` at five clean seeds, all with zero hold violations, every clock passing, `clk67` on `SPINE27/TOP2` at 208 to 256 MHz and `clk16` at 19.4 to 20.0 against 16.75, seed 5 the best on both; the Oct 31 sweep's seeds 1, 2 and 7 were stopped part-way and are not reported as results. Seeds 1, 2 and 7 of that SDRAM sweep were terminated by a `pkill -f nextpnr-himbaechel` intended for them alone, which also killed a concurrent TinySNES build belonging to another agent; that build was restarted by its owner and lost one placement run, and the lesson -- cancel a job by its own task id or its own pid, never by a pattern that matches every build on the machine -- is recorded here because the same mistake would take out someone else's work again. `tools/make_gba_test_rom.py` assembles a 4 KiB ARM cartridge from source embedded in the script and verifies its own output: header, complement check, entry branch and the three read-back constants, all eight checks hand-disassembled. It forces blank, checks three constants at three cartridge offsets, writes and reads back IWRAM, EWRAM and VRAM with two individual byte lanes, draws mode 3 green for a pass or red with one yellow column per failed check, and blinks a square so a capture separates a running CPU from one that wedged; it enables no interrupt and writes no `WAITCNT`, so a pass says nothing about either, which is the distinction that cost the SNES project several cycles. The logo region is zero-filled because this core's BIOS is Cult-of-GBA built with `NO_LOGO` and branches straight to `0x08000000`. Nothing was deployed and the Tang was not connected to, at the user's instruction. Three records were added to `.ai/core-reference.md` -- TCL-007 on attribute syntax, TCL-008 on nextpnr printing its hold count only when it is non-zero, and BRD-004 on a clock passing both gates while crossing no bridge pip -- and `README.md` gained the two gates, the test cartridge and the machine-image blocker under Known gaps. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 5 were not rewritten and that the three new records carry unique ids and the canonical field order, and validated this entry as entry 6 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of six against the 100-entry limit.

#### Next Steps:

Settle the `clk67` failure in the `TINYGBA_OVERLAY_OFF` configuration before anything else, because it is the only thing between this tree and a cartridge on the board and it is demonstrably not a seed: the path is 26 logic stages from `cpu_mem_rdata` through `gba_memory`'s read muxes and `cpu.cmd` into `sdram.SDRAM_BA`, the same tree without the define is 5.84 ns, and the two independent syntheses that have it were built from trees differing only in `gba_memory.sv`'s attributes. The question to answer first is whether suppressing the OSD restructures the memory read mux into a deep chain or whether the machine configuration was always this close and the Oct 31 builds were lucky, and the instrument is a read of the two netlists rather than more placements: compare the logic feeding `sdram.SDRAM_BA` between the two configurations in `tools/gatelevel_report.py`'s terms, and if the depth is genuinely configuration-dependent, find which cone the overlay removal changed. Only then produce a machine image at a clean seed and stream the test cartridge at it, expecting the green screen and the blink, and reading a red screen's yellow columns as the check that failed. Separately, `02_sdram` must be rebuilt with `clk67` on the plane and flashed before entry 5's sample-point conclusion can be called a hardware result, since every image that conclusion rests on had `clk67` on general routing. Do not report an `clk16` hardware result without saying which pips it used: it lands on unmeasured `*/TOP3` at every seed, never on the `TOP2` pips that drew the verified video picture, and `TINYGBA_CLOCK_PLANE_STRICT=1` exists to make that a refusal when the project is ready to lose the builds it currently costs. Do not sweep more seeds for the machine configuration until the depth question is answered.

#### Files Modified:

- README.md
- fpga/gba/src/memory/gba_memory.sv
- fpga/gba/src/memory/sdram_gba.v
- tools/build_tinygba.sh
- tools/clock_plane_report.py
- tools/gatelevel_report.py
- tools/make_gba_test_rom.py
- .gitignore

#### Status:

- Build: FAIL
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 7 COMMIT Unreleased 2026-11-02T09:45:53-07:00

#### Coming From:

Unreleased 0363af6

#### Purpose:

Explain why the `TINYGBA_OVERLAY_OFF` machine configuration failed its `clk67` Fmax gate at every seed, which entry 6 left open and named as the only thing between this tree and a cartridge on the board.

#### Outcome:

The configuration was never broken and the gate was measuring the wrong thing. nextpnr-himbaechel's SDC parser implements exactly six commands -- `get_ports`, `get_cells`, `get_nets`, `get_pins`, `create_clock` and `set_false_path` -- refuses anything else with `Unsupported SDC command`, has no `set_multicycle_path` at all, and logs `does not do anything(yet)` and returns without effect for `set_false_path`. Every path is therefore timed as one cycle. Upstream GBATang's `gbatang.sdc`, which this port replaced with a file that drops every relaxation, heads one constraint with the comment `# sdram.cpu_dout through the CPU back to sdram: 4 cycles` and relaxes `clk16`-to-`clk67` and `clk67`-to-`clk16` by four and `clk16`-to-`clk50` by three. Those allowances are correct for the design rather than a workaround: one `clk16` period is exactly four `clk67` periods, so a path that leaves an SDRAM register, crosses logic clocked at `clk16` and returns to a `clk67` register has 59.70 ns of budget, not 14.92. The failing path is that one exactly -- `cpu_mem_rdata_DFFRE_Q_34` to `sdram.SDRAM_BA_DFFRE_Q`, 29.77 ns, which nextpnr reported as 33.59 MHz against 67.00 and refused. Six seeds failing at 33.6 to 36.0 was not seed sensitivity and not a change: the three controls that would have implicated one all passed, the tree before this cycle's edits giving 38.76 MHz at seed 5, the same tree without the define giving 171.26 MHz with a 5.84 ns same-domain path, and the Oct 31 netlist re-routed at seed 5 giving 154.01 MHz. The combinational depth into `sdram.SDRAM_BA_DFFRE_Q_D` is 57 in both configurations, so the logic was never restructured; what differs is only which path is worst. That matters more than the fix, because it means the six failing seeds and the passing ones were the same design measured two ways, and a single-cycle analysis is wrong in both directions at once: it also never reports the cross-clock paths, so `--timing-allow-fail` would have let a slow `clk16`-to-`clk67` path through with no measurement at all. `tools/timing_gate.py` now judges the build instead of nextpnr, and it is deliberately narrow: every path is held to a single cycle except the four documented pairs, the readback allowance requires both endpoints -- the path must start at `cpu_mem_rdata` and end in `sdram.` -- so an unrelated slow path cannot borrow it, the hold count is gated because nextpnr prints it only when it is non-zero, and every relaxation applied is printed with the upstream line it came from. Five checks stand behind it: the machine configuration passes with one printed relaxation, the same tree without the define passes with none, the SDRAM-probe build at seed 5 passes with none, `build/prod` with its one hold violation fails on hold, and two mutations of the machine build's `timing.json` -- moving the 29.77 ns path's source to an unrelated register, and lengthening the `clk16`-to-`clk67` path past 59.70 ns -- both fail as they must. nextpnr is now always run with `--timing-allow-fail` so that it writes `timing.json` and the routed netlist for the gate to read; it must not be the judge, and this cycle showed both ways it errs. Two records were added to `.ai/core-reference.md`, TCL-009 on the SDC command set and the multicycle contract and BRD-005 on the failure being an analysis artefact, and `README.md`'s known-gaps entry now says the machine image builds but its timing is judged rather than proven. The machine image was then built end to end at seed 5 with zero hold violations: `build/c6_machine_ok/tinygba.fs`, SHA-256 `2ebaaf33b338f39df0fbfdee0cf4dfe8b072a73a828713adcd05f9c476363ad7`, the only relaxation applied being the documented readback one, so a cartridge now has an image to run on for the first time. Nothing was deployed and the Tang was not connected to, at the user's instruction. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 6 were not rewritten and that the two new records carry unique ids and the canonical field order, and validated this entry as entry 7 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of seven against the 100-entry limit.

#### Next Steps:

Put a cartridge on the board, which is now finally possible and is the only thing that can confirm the lesson: load `build/c6_machine_ok/tinygba.fs` one-wire, stream `tools/make_gba_test_rom.py`'s cartridge with `tools/load_gba_rom.py`, and read the screen. A green field with a blinking white square means the CPU fetched through the ROM path, ran, and wrote VRAM and both work RAMs, and that the four-cycle readback allowance holds on silicon; red with yellow columns names the failing check by column; a frozen picture means the CPU wedged after the checks; a black 1080-pixel field means nothing ran or the framebuffer never reached the video window, which `01_video` separates. Do this before rebuilding `02_sdram`, because a booting machine answers the memory question more directly than sixteen bars, and entry 5's sample-point conclusion still needs a `clk67`-on-the-plane image before it is a hardware result. If the machine does not run, the readback allowance is the first suspect and the instrument is the same `timing_gate.py` with `--allow-hold` absent plus a narrowed allowance that requires the endpoints to be tighter, not a wider one. Two things remain over-constrained and should be settled before the next timing conclusion is drawn from this design: `build/prod` still fails on one hold violation and so production is not buildable at any seed tried, and the SDC still declares the four clocks flat with `create_clock` because the parser cannot name clocks, so the `clk16`-to-`clk50` three-cycle allowance upstream makes is not applied and those paths are held to one cycle of `clk16`, which is conservative rather than wrong. Do not treat a passing timing gate as evidence the machine runs, and do not sweep more seeds for a configuration that failed: check which path is worst and whether the contract relaxes it before concluding anything about a seed.

#### Files Modified:

- README.md
- tools/build_tinygba.sh
- tools/timing_gate.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 8 COMMIT Unreleased 2026-11-02T10:12:00-07:00

#### Coming From:

Unreleased 2ee5b8a

#### Purpose:

Put the machine image and the corrected SDRAM probe on the board for the first time since the timing gate was corrected, and find out whether the black machine picture is a memory fault.

#### Outcome:

The SDRAM is good and the machine still does not boot, which is the most useful pair of answers this project has had. The machine image `build/c6_machine_ok/tinygba.fs` drew a black field 1080 pixels wide flanked by the grey pillarbox bars, with HDMI synced: by the two widths recorded for this core that is the video window with an empty framebuffer, not the 960-pixel OSD window, and the OSD was independently ruled out rather than assumed absent -- the machine netlist has no `iosys.disp.menu_mem` and no overlay net at all, because `TINYGBA_OVERLAY_OFF` ties `overlay` to `1'b0` in logic and synthesis deletes the whole block, against 98 OSD and menu nets in the same tree built without that define. The cartridge was streamed with `tools/load_gba_rom.py` and the core accepted 4096 bytes in 0.6 s with no error, so the picture is a machine that is not running rather than a stream that failed. The first attempt at the SDRAM probe then showed the same black field, which cannot be that bitstream: the probe writes its sixteen bars from its own raster and takes no input from the GPU, the CPU or the cartridge, so an identical picture meant the load had not taken. That is the fourth recorded occurrence of the silent-load failure in BRD-003 and the second in this session, and it is now recorded in BRD-006 as the way to read that image: reload before concluding anything. Reloaded onto a rebooted console, the probe drew a green status band and sixteen green bars with only its own grey margin beyond x=232, which is its full pass: 64 MiB, both dies, all sixteen patterns read back. That settles the SDRAM, the two-die single-CS question and every memory hypothesis, and it supersedes both earlier readings -- entry 3's two green and fourteen red, and entry 5's eight-red high die -- because both were taken from images whose `clk67` crossed no clock-plane bridge pip (BRD-004) and neither had the corrected probe on the board. The working instrument for the remaining fault is now a sticky status probe, `TINYGBA_STATUS_TEST`, added this cycle and built at seed 5 as `build/c6_status/tinygba.fs`, SHA-256 `87fba5cff2863adfd94f20fc755bac5da0028e4becd6c3c0a4c9e939b87b390b`, zero hold violations and the same single documented relaxation. It latches six facts that never clear -- whether `gbaon` rose, whether `rom_en` ever asserted, whether `cpu_mem_ready` ever rose, whether `loader_do_valid` ever rose, whether the GPU ever wrote a pixel, and whether `halt` asserted -- and draws them as sixteen bars beside a live `rom_addr[27:18]`, with the band green once `gbaon` is high. Its bits are held low while `resetn` is low and only then allowed to set, which is the trap TinySNES hit when two of its history bits were unarmed and self-set at reset. It has not been on the board. Two things were checked offline and one hypothesis was withdrawn. The controller testbench `fpga/gba/diag/tb_sdram_controller.sv` still reports `xxxxffff` and then `zzzz`, and the trace shows `dq` as `Z` at the controller's sample slot, so it remains unable to see the controller as hardware sees it -- the same limitation entry 5 recorded, still open, and it is now explicitly not an authority. And an inspection of the status netlist initially read the sticky bits' data input as `joypad.reg_dout` and their enables as unrelated signals, which looked like a miscompiled probe; tracing the drivers showed bit 1515 is driven by a `VCC` cell, so it is constant 1 exactly as written, and the netname attached to it was a stale alias. That is the third time in two cycles that reading netnames rather than drivers produced a wrong conclusion, and it is why `tools/gatelevel_report.py` reads drivers. Nothing was deployed as the cycle closed and the Tang was handed back to the operator. BRD-006 was added to `.ai/core-reference.md`, `README.md`'s status now records the SDRAM as verified, and the diagnostic table gained `TINYGBA_STATUS_TEST`. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 7 were not rewritten and that BRD-006 carries a unique id and the canonical field order, and validated this entry as entry 8 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of eight against the 100-entry limit.

#### Next Steps:

Load `build/c6_status/tinygba.fs` and read the six sticky bits, because SDRAM is now exonerated and the remaining fault is a chain of four links that this build separates in one picture: a green band means `gbaon` rose and the loader released the machine, bit 1 means the CPU issued a cartridge fetch, bit 2 means the controller answered a request, bit 3 means cartridge bytes reached the loader at all, bit 4 means the GPU drew a pixel, and bit 5 means the CPU took a halt. Read the band first, then the low six bars left to right, and read the top ten as the region `rom_addr` is in rather than as a number. The most likely reading, and the one to look for, is a green band with bit 3 clear, which would mean the bytes never reached the loader even though the stream reported success -- that would put the fault in the `0x07` loader write path rather than in the CPU, and the next instrument is a counter of loader writes shown beside the same bits. If bit 3 is set and bit 1 is clear, the cartridge is in memory and the CPU is not fetching it, which points at `gbaon` and the reset sequencer rather than at memory. Do not re-test the SDRAM: it is verified and a fifth memory test would add nothing. Do not trust the controller testbench until its DQ drive window is aligned with the controller's own sample slot, and do not read any netlist by netname -- trace drivers, because a stale alias has now produced three wrong conclusions in two cycles. The production configuration still fails on hold and remains unbuildable, which should be settled by finding the path rather than by sweeping seeds.

#### Files Modified:

- README.md
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gba2hdmi.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 9 COMMIT Unreleased 2026-11-02T14:03:08-07:00

#### Coming From:

Unreleased a69a20a

#### Purpose:

Put the long-dormant machine on the board at last, find why it draws nothing, and replace the hand-built probe whose readings had already been mis-decoded three times with one generated from a single field list.

#### Outcome:

The machine runs the BIOS and stops on a halt it can never be woken from, and the answer was reached only after this session's instruments were made trustworthy. Three findings stand, each confirmed by more than one instrument. SDRAM is good: the corrected probe drew a green status band and sixteen green bars with only its own grey margin, which is 64 MiB with both dies and all sixteen patterns, and that supersedes both earlier probe readings because both came from images whose `clk67` crossed no clock-plane bridge pip. The GPU raster is alive: `DISPSTAT`'s V-Blank and H-Blank flags both arrive and the scanline counter advances, so the display timing is not the fault -- this refuted the cycle's own opening prediction and is why the probe moved from the IRQ outputs to the status flags, since `IRP_VBlank` and `IRP_HBlank` are gated by IRQ-enable bits the CPU must write and a CPU that never gets that far guarantees them low. And the CPU executes the official BIOS and stops at a real halt: the latched fetch address decoded to `0x344`, which disassembles in the official image to `strb r3, [ip, #769]` with `ip` = `0x04000000`, the write to `HALTCNT`, and the probe reads one halt entry, never cleared, with the V-Blank IRQ enable clear. That closes into a single missing write rather than a dead subsystem: `halt` clears when any `IRPFlags` bit sets, `IRPFlags[0]` needs `IRP_VBlank`, and `IRP_VBlank` needs the `DISPSTAT` enable that only the CPU can write. The machine is not broken in four places; it halts one instruction too early to ever be released. Two operational results matter for the next session. The official BIOS was wired in without entering the repository, through a `TINYGBA_BIOS_HEX` build define that takes a quoted absolute path, with the image converted to a hex file under the ignored `build/` directory; the in-tree default stays the open-source Cult-of-GBA image. And a logo-bearing test cartridge was generated with `--logo-from` splicing the 156-byte logo out of a local retail image, because the official BIOS validates the logo and hangs on a cartridge that lacks it, which would have looked exactly like a machine fault. The silent-load failure recurred three more times, once showing the previous bitstream's picture after a flash of a different one, and each time the correct response was a reload rather than an investigation; the probe image writes its bars from its own raster and cannot legitimately draw the machine's black field, which is what made it identifiable. The larger result of the session is instrument discipline. Five of this project's own readings were wrong in this session before being caught -- a reversed bar order that bit-reversed a displayed address, a halt latch that required `halt` and `rom_en` in the same cycle and so could never fire, IRQ-gated probe bits that were provably constant under synthesis, a live signal labelled as latched, and a multi-byte count read MSB-first from an LSB-first field -- and every one produced a plausible number rather than an error. The sibling SNES project's correction of its entry 62 showed the same class recurring there four times, so the fix applied here is structural: `tools/probe_map.py` holds one declarative field list and generates both the RTL packing, as `fpga/gba/src/probe_bits.vh`, and the host decoder, and `tools/build_tinygba.sh` refuses a build whose include does not match the list. The guard measures `$bits` of the packing expression rather than restating the generator's own arithmetic, and it was verified by deliberately mismatching the bus width and watching elaboration fail with `unknown module`, which is the only reliable elaboration-time failure on this flow since slang rejects `$error` and yosys drops a blackboxed module silently. An earlier version of that guard compared a constant against itself and could never have fired. The list also carries a short id, emitted as `PROBE_MAP_ID` and printed by the decoder, because a generated decoder cannot be trusted against a capture from a different layout: bar 3 changed meaning between two builds in this session. Two records were added, BRD-007 for the halt finding and TCL-010 for the generating rule, and `README.md` now says the machine runs the BIOS and halts rather than that it was never booted. Nothing was deployed after the readout was taken. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 8 were not rewritten and that the two new records carry unique ids and the canonical field order, and validated this entry as entry 9 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of nine against the 100-entry limit.

#### Next Steps:

Latch `gb_bus_adr` and `gb_bus_din` at the first write to `0x04000004` and read whether the BIOS writes `DISPSTAT`'s V-Blank IRQ enable at all, because that single question separates the two remaining explanations and everything else is measured: if no write to that address ever occurs, the BIOS halts before reaching the instruction that enables it, and the next step is to find which branch it took instead, with the halt-address latch already built and its trigger now known to work; if a write occurs with bit 3 clear, the BIOS is enabling a different source and the suspects become the interrupt master enable at `0x04000208` and the interrupt enable word at `0x04000200`; and if the write occurs with bit 3 set and `DISPSTAT[3]` is still clear, the write is not reaching `gba_gpu_timing` and the fault is in that decode path. Add the field to `tools/probe_map.py` and regenerate rather than hand-editing the packing, and check whether `REG_DISPSTAT_V_Blank_IRQ_Enable` is driven at all in the netlist first, because the sibling project's `PAL` and `GSU_TURBO` faults were both an undriven term folded to a constant by `synth_gowin` and that class has now cost two projects several cycles. Do not re-measure SDRAM, the raster, the clock plane or the timing contract; all four are settled and recorded. Do not decode a probe frame by hand, and do not trust a capture without checking that its map id matches the build it came from. Treat any flash that shows the previous bitstream's picture as a reload, not a result, and prefer `tools/probe_map.py --decode` over reading bars from a screenshot.

#### Files Modified:

- README.md
- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/memory/gba_memory.sv
- fpga/gba/src/probe_bits.vh
- tools/build_tinygba.sh
- tools/probe_map.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 10 COMMIT Unreleased 2026-11-02T15:04:12-07:00

#### Coming From:

Unreleased 2fbfef6

#### Purpose:

Build the core under Verilator so it can be asked whether it is correct rather than only what state it is in, after six hardware cycles produced one word per flash.

#### Outcome:

The core simulates for the first time in this port's history, and it boots and renders, which makes the hardware failure a divergence rather than a mystery. Upstream GBATang ships a complete Verilator harness at `verilator/sim_main.cpp` with an SDL window, FST tracing and audio capture, and this port had never carried it, so every result on record had come from a 16-pixel bar strip on a capture card with nothing to compare against. The harness needed three repairs before it built, and each is evidence it had never been run against this revision: `memory/gba_eeprom.sv` carries two `ifdef VERILATOR` `$display` statements that index `mem`, an array whose declaration is commented out in the same file at lines 83 to 98, so the vendor's own simulation build cannot elaborate; upstream's source list omits `gpu/linebuffer.v` and `memory/mem_eeprom.v`, both of which are instantiated unconditionally; and `mem_eeprom.v` still instantiates `MUX2`, `DFFRE` and `DPB` under `VERILATOR`, which only the vendor cell library defines, so `tools/sim/gowin_cells_sim.v` carries exactly those three with `specify` blocks removed. With those fixed, `tools/sim/build_gba_sim.sh` verilates, compiles and runs, and the simulation renders frames, writes audio and plays the Cult-of-GBA BIOS visibly. The decisive comparison is that the official BIOS, which halts on the board at the `HALTCNT` write and never wakes, **boots and renders eleven frames in simulation** with the same cartridge. So the RTL is not the fault: something the simulation does not model is. The simulation clocks `clk50:clk16` at exactly 3:1 from a single counter, which matches the board's 50.25:16.75 MHz, so it is a fair reference for logic and an unfair one for anything depending on how two clock domains relate -- and on the board `clk16` and `clk50` come from different PLLs, `pll16` and `pll33`, while in simulation they come from one counter. That difference is now the leading candidate and was not testable before this cycle. Two smaller findings came with it. `dispstat_dbg` was declared inside the probe `ifdef` and therefore used unconnected outside it, which this project's own synthesis builds silently tolerated as an implicit net and Verilator refused; it is now declared unconditionally. And a comment line beginning `// Verilator` is parsed as a pragma directive and fails elaboration, which is worth knowing before writing RTL comments. The user also reports that nand2mario's focus was the 60K board with the 138K secondary, and that a slow CPU could show up in audio before it shows up in display, since the GBA's CPU drives audio directly; that is recorded as a lead rather than acted on, because the simulation now gives a way to measure cycles per frame directly. Nothing was deployed. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 9 were not rewritten, and validated this entry as entry 10 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of ten against the 100-entry limit.

#### Next Steps:

Find what differs between the simulation and the board, because the simulation is now a reference and the question has changed shape: the official BIOS boots in simulation and halts on hardware, so the fault is in something the model does not reproduce. Work the difference list in order of how much each can affect the halt. First the clock relationship: in simulation `clk16` and `clk50` are one counter at an exact 3:1 ratio with fixed phase, while on the board they are `pll16` and `pll33` with no guaranteed phase, and `gba_gpu_timing` takes its register writes from `mclk` while running its state machine on `fclk` -- so instrument the register path across that boundary before assuming the DISPSTAT write that the probe saw on the bus actually lands in the register. Second the SDRAM: the simulation substitutes `sdram_sim.v`, a zero-latency array, for the real controller, so any behaviour that depends on `cpu_mem_ready` arriving late is invisible there. Third, memory waitstates: measure `clk16` cycles spent with `cpu_en` low as a fraction of total in simulation, then compare against what the hardware probe implies, because a CPU that stalls far more than real hardware would explain both a slow boot and the slow audio the user reports, and the GBA's CPU drives audio directly. Do not rebuild and reflash the same netlist hoping for a different result, and do not add more probe fields until the simulation has been used to answer one of those three questions -- the simulation costs minutes and exposes every signal, while a hardware probe costs a build and a flash for one word. Keep the harness's limits in view whenever using it to explain a board result: it has no SDRAM controller, no HDMI, no BL616 link and no PLL phase relationship, so it can prove logic wrong and cannot prove a board right.

#### Files Modified:

- README.md
- THIRD_PARTY.md
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/memory/gba_eeprom.sv
- tools/sim/build_gba_sim.sh
- tools/sim/gowin_cells_sim.v
- tools/sim/sim_main.cpp

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: N/A

---

## 11 COMMIT Unreleased 2026-11-02T16:13:36-07:00

#### Coming From:

Unreleased 565c8b5

#### Purpose:

Find why the board halts where the simulation does not, and build the gate that would have caught it without a session of hardware work.

#### Outcome:

The whole machine failure was one undriven wire, and the project now has a build gate that detects the class. `gb_bus_rst` is an output of `gba_memory` that every `eProcReg_gba` instance reads as `if (gb_bus_rst) Dout_buffer <= register.def;`, and it is assigned nowhere -- in this tree or in upstream GBATang at `77fd0714`, where the vendor flow must simply tie it low. Measured on this flow with a minimal reproducer: `synth_gowin` folds such a wire to constant 1, makes the reset branch unconditional, deletes the write branch, and leaves the register driven by a single GND cell. At scale that removed roughly 4,500 flip-flops from a 9,100-register design -- every MMIO register in the machine -- while the design went on to elaborate, place, route, pass Fmax, pass the hold check and pack a bitstream. The two counts are the measurement: 4,631 registers with the wire undriven, 9,100 with `assign gb_bus_rst = 1'b0;`, from otherwise identical sources, block RAM unchanged. That single fact explains every hardware reading in entries 8 to 10 without exception: the probe saw writes to `0x04000004` carrying `din[3]`, to `0x04000200` and to `0x04000208`, while the live `DISPSTAT` V-Blank IRQ enable stayed 0, because no register existed to hold it; `IRP_VBlank` could therefore never assert, `IRPFlags` could never set, and `halt` could never clear, which is why the CPU stayed stopped on the `HALTCNT` write at `0x344` that the address latch had already named. The GPU raster and the SDRAM were never implicated and remain verified. The reason the simulation disagreed is now precise rather than mysterious: Verilator treats an undriven wire as 0, so the model contained the registers the bitstream did not, and the fold is exactly the difference between them -- which means no simulation of this design could ever have found this fault. The gate is `tools/synth_parity.py`: it compares a netlist's flip-flop and block-RAM population against a recorded baseline for its configuration, fails on a loss beyond ten percent, and prints the `used but has no driver` wires synthesis reported, grouped by instance. It was tested against the two builds this cycle produced -- the pre-fix netlist fails at 49.1 percent loss and the fixed one passes at 0.0 -- and all three exit codes were exercised, including the `2` that reports a missing baseline rather than passing silently. Recording a baseline from a build whose correctness is known is deliberate: absolute comparison between RTL and netlist does not work on this design, because techmapping expands one RTL register into several cells and the netlist then legitimately carries more than the source implies, which was measured at 7,435 against 9,100 and would have made a direct comparison meaningless. The gate is wired into `tools/build_tinygba.sh` as stage 1b, keyed on the configuration's `TINYGBA_*` define names with `TINYGBA_BIOS_HEX` excluded, because that define selects which bytes are loaded into the BIOS block RAM and changes no logic. Three smaller things came with it. The harness exited its step budget by falling through into the SDL event loop and spinning at 100 percent of a core with the window frozen, which reads on screen as a hang or as someone having paused it; it now exits with a message and idles with `SDL_Delay` when paused. Frame dumping was added to the harness, `-p PREFIX -pe N`, writing PPMs straight from the framebuffer, because capturing the SDL window depends on the window being findable and unoccluded and the first attempt grabbed the entire desktop instead. And the simulation was confirmed to render a retail cartridge through the official BIOS, reaching the Game Boy Advance boot logo, with the CPU spending only 2.2 percent of cycles waiting on memory and 76.4 percent halted in the BIOS's own idle loop. The fixed image was built and gated but not deployed: `build/c6_fixed/tinygba.fs`, SHA-256 `5cfea671aa842c4169ceed0a5fa4b675b066744b64a215c80202185875b194d3`, seed 5, zero hold violations, one documented multicycle relaxation, clock plane clean. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 10 were not rewritten and that the two new records carry unique ids and the canonical field order, and validated this entry as entry 11 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of eleven against the 100-entry limit.

#### Next Steps:

Deploy `build/c6_fixed/tinygba.fs` with the status probe and the logo-bearing cartridge, and expect `vblank_irq_en` to assert and `halt_cleared` to set -- which would be the first time the BIOS has ever passed its boot halt on this port, and the first hardware evidence that the fix is real rather than merely synthesised. Read it with `tools/probe_map.py --decode` and check the map id matches, not by eye. If `halt_cleared` sets and `cart_fetched` goes high, the machine is running and the remaining work is retail-game compatibility in the simulator, which is where the effort belongs now: every question about correctness is minutes there against a build and a flash here, and the user's plan to perfect the simulator first and spot-check hardware periodically is the right shape for this project once the gate above closes the one gap the simulator structurally cannot. Re-take every register-dependent measurement from entries 8 to 10 on the fixed build before relying on it, because all of them describe a machine whose registers were absent; the measurements that do not involve MMIO writes -- SDRAM contents, raster flags, the halt address, fetch-region history -- stand as recorded. Record baselines for the production and SDRAM-test configurations once each has been boot-tested, since a baseline from an unverified build certifies nothing. Do not treat a passing parity gate as proof the design is correct: it catches a loss of registers, not a wrong one. Do not revert the `gb_bus_rst` assignment to match upstream, and if upstream is ever updated, check whether the vendor tool still ties the wire low before assuming it.

#### Files Modified:

- README.md
- fpga/gba/src/memory/gba_memory.sv
- tools/build_tinygba.sh
- tools/sim/sim_main.cpp
- tools/synth_parity.py
- tools/synth_baseline.json

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: N/A

---

## 12 COMMIT Unreleased 2026-11-02T16:25:27-07:00

#### Coming From:

Unreleased b0ce2cb

#### Purpose:

Put the `gb_bus_rst` fix on the board and find out whether the machine's boot halt finally clears.

#### Outcome:

The halt clears, and the machine executes its boot halt loop for the first time in this port's history. The deployed image, `build/c6_fixed/tinygba.fs` at SHA-256 `5cfea671aa842c4169ceed0a5fa4b675b066744b64a215c80202185875b194d3`, carries 9,100 registers against the 4,631 of the previous build, and the status probe reads `0xFFFE` under field map `1dce3f01`: the `DISPSTAT` V-Blank IRQ enable asserts, `halt` clears after having been seen, and the halt counter saturates at fifteen. The previous build entered exactly one halt and never left it, so the difference is the whole interrupt path working end to end -- the CPU writes `DISPSTAT` bit 3, `IRP_VBlank` asserts, `IRPFlags` sets, and `halt` clears -- which is precisely what BRD-008 predicted and what entries 8 to 10 could not have seen, because the registers those writes landed in did not exist. The rest of the reading is unchanged and self-consistent: the scanline advances, VBlank and HBlank arrive, writes to `0x04000004`, `0x04000200` and `0x04000208` all occurred, and `halt` is live at the sampled instant, which is expected since the BIOS spends most of a frame halted between VBlanks -- the simulator, which showed 76 percent of cycles halted, predicts exactly that. Two captures eight seconds apart are identical, so this is a steady state and not a transient. One thing did not change: the CPU has still never fetched from the cartridge, since `rom_addr[27:24]` non-zero has never been observed, and the machine has now run at least fifteen complete halt-and-wake cycles without reaching `0x08000000`. That is the next fault and it is a different one from this cycle's. The measurement method is worth recording because it is the first hardware reading in this project that was decoded by a tool rather than by eye: `tools/probe_map.py` generated the RTL packing and the decode from one field list, and the bar interpretation came from that rather than from reading a screenshot, which is the discipline TCL-010 calls for after four consecutive mis-decodes on the sibling project. The capture device was held by OBS for part of the cycle and one capture attempt failed with `Device or resource busy`; the fix is to take the reading when the device is free rather than to work around it. Nothing remains deployed beyond the tested image. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 11 were not rewritten and that BRD-009 carries a unique id and the canonical field order, and validated this entry as entry 12 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twelve against the 100-entry limit.

#### Next Steps:

Find why the CPU runs fifteen halt-and-wake cycles without ever fetching from `0x08000000`, and do it in the simulator rather than with another probe, because the board has now given the same six-bar answer twice while the simulator can show every fetch. The specific question is what the BIOS is waiting for after its halt loop: the official image boots to the logo and then reads the cartridge header at `0x08000004`, so a machine that never touches `0x08000000` is either still in pre-logo initialisation or has diverged before the header check. Instrument the simulator to log the first fetch from each region and compare that sequence against the board's fetch-region history, which is already recorded and sticky. If the simulator also never reaches the cartridge with this cartridge image, the difference from the earlier successful run is the image, since the earlier run that reached the logo used a retail cartridge and this reading streams `build/test/test_logo.gba`; re-run the simulator with the same test cartridge before concluding anything about the board. Do not re-measure the halt path, the raster, the SDRAM or the register writes -- all are now measured and working -- and do not build another probe until the simulator has answered. Record baselines for the production and SDRAM-test configurations once each is boot-tested, since a baseline from an unverified build certifies nothing.

#### Files Modified:

- README.md

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PASS

---

## 13 COMMIT Unreleased 2026-11-02T17:36:15-07:00

#### Coming From:

Unreleased 416cf14

#### Purpose:

Turn the newly working Verilator model into the project's primary instrument, and find out what the core can actually do with it.

#### Outcome:

The core runs retail and diagnostic cartridges correctly in simulation, and an independent hardware test suite says so. Upstream GBATang ships a complete Verilator harness with an SDL window, FST tracing and audio capture, and this port had never carried it, so every result on record had come from a sixteen-pixel bar strip on a capture card with nothing to compare against. The harness needed three repairs before it built at all, each evidence it had not been run against this revision: two `ifdef VERILATOR` `$display` statements in `gba_eeprom.sv` index an array whose declaration is commented out in that same file, upstream's source list omits `gpu/linebuffer.v` and `memory/mem_eeprom.v` which are instantiated unconditionally, and `mem_eeprom.v` still needs the `MUX2`, `DFFRE` and `DPB` primitives, carried in `tools/sim/gowin_cells_sim.v` with `specify` blocks removed. Three additions made it usable as an instrument rather than a demo: deterministic frame dumping to PPM straight from the framebuffer, since capturing the SDL window depends on it being findable and unoccluded and the first attempt grabbed the whole desktop; CPU stall accounting, which reports cycles with `cpu_en` low and the halt fraction; and fetch-region history, mirroring the hardware probe's sticky OR of `rom_addr[27:21]` so the two can be compared without translation, plus a data-region counter over `ram_addr`, because cartridge data reaches the controller on a different bus from instruction fetches and the hardware probe tracks only the latter. The results are stronger than expected. Super Mario Advance boots: the BIOS animation completes, the first instruction fetch from the cartridge occurs at sim_time 452,974,016, execution is later seen in `0x08000000`, `0x0C000000` and `0x06000000`, and the game reaches its own save-data check and reports 'The saved data is corrupt', which is correct behaviour because the harness fills cart RAM with `0xff` and models no save hardware. RetroRegen GBA Test v1.5 goes much further and is the result that matters: it reports `CPU: ARM7TDMI @ 16.78 MHz`, `SET: ARM v4T (ARM+THUMB)`, `BIOS SUM: 0xBAAE187F`, `AGB BIOS: GBA/SP/MICRO`, bus timing `IWRAM 1190`/`EWRAM 1702`/`ROM 1702` cyc per 256 reads all `OK`, `WAITCNT: 0x0000`, cart SRAM `OK (64K RANGE)`, and `MEMORY TEST -- RESULT: ALL REGIONS PASS` across IWRAM 32K, EWRAM 256K, VRAM 96K, PRAM 1K and OAM 1K; the LCD solid, LCD ramps and GPU scene checks also passed by eye and the GPU stress test ran, with audio and buttons skipped deliberately. That is the first independent third-party confirmation of the machine side of this port and it is far better evidence than any probe built during this session, because it is a suite judging the core rather than the core's own instrument reporting on itself. Its limit is stated in the same breath and must travel with it: the model substitutes `sdram_sim.v`, a behavioural array, for the real controller and does not compile `sdram_gba.v` at all, so `EWRAM` and `ROM` passing establishes that the CPU asked the right addresses and the decode is right and establishes nothing about the physical controller or its timing. Two methodological corrections came out of this cycle and both were mine. Frame dumps at fixed intervals can be byte-identical across several samples while the picture is merely static by design, and a static screen is not a hang; more seriously, I drew conclusions from runs I had cut short, reporting that the simulator never fetched from the cartridge when in fact the first cartridge fetch is around frame 500 and my samples stopped at 177 -- conclusions drawn from a run that has not finished are not measurements. Scripted controller input was added, `-press BIT@FRAME[:DURATION]`, so a boot test does not depend on a human and a window having focus, and it was confirmed working by a scripted START advancing the splash screen; manual driving was still faster for exploring the diagnostic menu, and the operator took over. The 177-frame and 605-frame samples also show the CPU doing real work rather than idling: the halt fraction falls from 80.9 percent in the BIOS loop to 37.2 percent running the diagnostic ROM, with 49.8 percent of cycles issuing cartridge fetches. Nothing was deployed this cycle. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 12 were not rewritten and that the two new records carry unique ids and the canonical field order, and validated this entry as entry 13 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of thirteen against the 100-entry limit.

#### Next Steps:

Run RetroRegen on the Tang, because it is now the sharpest instrument this project has and the one question the model cannot answer is the physical memory path: the same ROM on the board will report the same ten facts in one screen -- CPU identity, BIOS checksum, per-region bus timing, and the memory verdict -- and either match the simulation or name exactly where hardware diverges, which is worth more than any probe built this session. Build the production machine image with the `gb_bus_rst` fix at a clean seed, gate it, and stream the diagnostic cartridge at it; expect the BIOS logo, then the RetroRegen splash, and note that it needs START to leave it. Treat the memory test as the decisive line: `IWRAM` and the graphics regions are block RAM in both model and bitstream and should match, while `EWRAM` and `ROM` go through `sdram_gba.v` on the board and an array in the model, so a difference confined to those two regions is the SDRAM controller and a difference anywhere else is something new. Do not re-measure what the diagnostic suite has already settled in simulation, and do not build another bespoke probe before this ROM has run on hardware. Independently of the board, two gaps in the model are worth closing because they gate whole classes of retail testing: the save hardware is a `0xff` fill rather than a model, so every game that checks its save stops at a message, and `sdram_gba.v` is absent entirely, so nothing the model does can exercise the controller. Do not draw a conclusion from a simulation run that has not reached its step budget, and record the step budget and frame count with any result taken from it.

#### Files Modified:

- README.md
- tools/sim/build_gba_sim.sh
- tools/sim/gowin_cells_sim.v
- tools/sim/sim_main.cpp
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/memory/gba_eeprom.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: PASS

---

## 14 COMMIT Unreleased 2026-11-02T19:28:00-07:00

#### Coming From:

Unreleased 4f679cd

#### Purpose:

Compile the real SDRAM controller into the Verilator model, so that what the simulation says about memory stops describing an array and starts describing the 534 lines of `sdram_gba.v` that run on the board.

#### Outcome:

The controller now loads a cartridge byte-perfectly and services the CPU at the same stall rate as the behavioural array, and getting there required finding two acknowledgement losses in the memory FSM that had never been visible because no bench had ever run the controller. The infrastructure cost four repairs before a single line of controller logic executed: the model and the controller both drive a tristate from a `reg`, which this simulator refuses and which is fixed by copying to a wire first; a `z`-valued register initialiser is the same construct and becomes `16'h0000` behind a `dq_oen` that is already high; the harness clock could not express the 4:3:1 relationship at all, since its six-step counter yielded only `clk16` and `clk50` and the controller needs `clk67` at exactly four times `clk16`; and the loader began writing before the controller had finished its 200 microsecond initialisation, 13,424 `clk67` cycles, so the first writes went into a part that was still programming its mode register. With those fixed the controller accepted exactly one request and then stopped, which is what led to the real finding. `sdram_gba` acknowledges a CPU request at its `cycle[3]` slot, three `clk67` after the slot counter is re-seeded by a `clk16` edge, and holds `cpu_ready` for exactly one `clk16` period. Because the slot always falls inside the `clk16` period that issued the request, the acknowledgement is visible on the very next `clk16` edge and on no other -- measured, and invariant across all twelve relative phases of the two clocks, which was checked by sweeping them rather than argued. The ROM path reaches `REQ1_WAIT` on that edge and works. The loader's `REQ1_START` and the second request's `REQ2_START` each add one `clk16` hop, so their first `REQ1_WAIT`/`REQ2_WAIT` sample lands one edge after the window has closed and they wait forever; a counter in the consuming FSM confirmed `sdram_ready` was never sampled high in any wait state. Why this was never seen is the part worth carrying forward: `sdram_sim.v` runs on `clk16` and acknowledges a request two `clk16` after it, one cycle later than the controller does, so the FSM's extra hop was free against the array and is fatal against the real part. The array was not a weaker version of the controller; it was a different timing contract. Three edits restore it, each marked `TinyGBA:` -- the loader goes straight to `REQ1_WAIT` as the ROM path does, `REQ2_START` consumes the acknowledgement and falls back to `REQ2_WAIT` for the 32-bit case that acknowledges a cycle later, and `cpu_en`'s concurrent rom+ram term is widened to `REQ2_START` because it would otherwise read low through the acknowledgement it was just taught to accept; the first attempt at the second edit omitted that third and stalled the CPU instead, which is worth recording as the reason the three travel together. Measured after: the loader writes all 4,096 bytes of the test cartridge and a dump of the memory die matches the file halfword for halfword, `ldrWrites` wrapping to exactly zero being 16 times 256 and therefore itself evidence the load completed; the memory FSM stops stalling, and on RetroRegen the controller build reports 2.5 percent CPU stall against the array's 2.5 percent over the same run; boot reaches the built-in BIOS splash and animates through it. What is not established, and must not be read into the above: the cartridge's own code has not been seen to execute under the controller. The run reaches frame 500 with no instruction fetch from `0x08000000` while the controller's request counters freeze, the picture stops on the BIOS logo, and the array build on the same ROM has already drawn RetroRegen's own splash by frame 100. Two candidate causes remain and neither is excluded: the cartridge read path returning data the CPU does not accept, which is unverified in a way the write path is not, or the BIOS choosing not to hand off. Both are reachable with the instruments now in the tree. One earlier conclusion was withdrawn during this cycle: a screen that does not change is not evidence of a hang, and equal frame hashes across samples were twice explained by static-by-design content before the request counters showed which runs were actually idle. Nothing was deployed.

#### Next Steps:

Localise the divergence to the read path before touching anything else, because the write path is proven and the read path is not: dump the first cartridge reads the BIOS performs, address and sampled `dq_in` at the controller's collect point, and compare them against the same offsets in the ROM file, which distinguishes a wrong word from a right word at the wrong time. If the words are right, the fault is timing or handoff and not data, and the next instrument is the CPU's view: whether `cpu_en` and the read data are presented on the cycles the ARM7TDMI samples them, which the array model's one-cycle-later acknowledgement hides. Do not conclude anything about cartridge execution from a run that has not reached at least frame 500, and treat the request counters rather than the picture as the evidence for whether the machine is idle. Once the read path is settled, re-run RetroRegen on the controller and require the same ten facts entry 13 obtained from the array -- CPU identity, BIOS checksum, per-region bus timing and `ALL REGIONS PASS` -- because a memory test that passes through a real controller is the first result in this project that speaks about the board's memory rather than a model of it. The `sdram_model.v` used here is the sibling project's part and models no refresh, no timing violations and not the second die's physical timing, so even a perfect run bounds logic and sequencing only. One known latent defect is deliberately left alone: the DMA path still enters `REQ1_START` and will lose its acknowledgement the same way the loader did, and nothing has exercised DMA yet.

#### Files Modified:

- fpga/gba/diag/gba_sdram_rtl.v
- fpga/gba/diag/sdram_model.v
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/memory/gba_memory.sv
- fpga/gba/src/memory/sdram_gba.v
- tools/sim/build_gba_sim.sh
- tools/sim/sim_main.cpp

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: PENDING

---

## 15 COMMIT Unreleased 2026-11-02T21:20:00-07:00

#### Coming From:

Unreleased b3f55fc

#### Purpose:

Put the sticky status probe on the board and get a hardware answer to a question a black screen cannot answer: how far does the machine actually get?

#### Outcome:

The machine gets further than any record in this project has ever claimed, and stops at one specific place: it never fetches from the cartridge. `TINYGBA_STATUS_TEST` was built at seed 5, packed clean (`clk67` 131.2 MHz against 67.0, zero hold violations, no relaxation needed) and loaded, and three states were read off the board with the generated decoder. With no cartridge: every bit zero and the status band blue, which is the correct "still loading" baseline and also proof the probe is not self-setting. With the 4 KiB test cartridge: scanline, VBlank and HBlank all arrive, the CPU writes DISPSTAT, DISPSTAT-with-IRQ-enable, IE and IME, it halts and wakes seven times, and `cart_fetched` stays low. With RetroRegen: the same alive signals and the same four register writes, but the CPU halts exactly once and never wakes, and `cart_fetched` is still low. So on hardware the video timing runs, the CPU executes, and the interrupt registers the BIOS needs are all written -- and no cartridge instruction is ever fetched in any configuration. That is the first time the boot path has been narrowed to a single stage on the board rather than inferred from a black picture. Two corrections belong with the result and are not incidental to it. The first is that a decode of these same captures was initially read against a hand-written bit list in the RTL comment, which a later edit to the map had left behind, and that stale list put `cpu_mem_ready`, `rom_en`, `pixel_out_we` and `loader_do_valid` at bits that are actually `vblank_arrived`, `scanline_run`, `vblank_irq_en` and `halt_live`. A "the SDRAM controller answered on hardware" claim was stated to the operator from that decode and is withdrawn here: the generated map has no such field, and the board has not been shown to answer a memory request. The comment has been replaced with a pointer to `tools/probe_map.py --list` so the prose copy cannot drift again. The second is that two earlier cycles concluded from a black screen that cartridge bytes were not reaching the core; the actual cause was the capture card returning black at 1280x720 whatever the board drew, recorded as BRD-012, and the loader was working the whole time. The picture is still black with a real cartridge loaded, and that is now the open question rather than the finding, with the probe having ruled out the stages before the fetch. Nothing was deployed beyond this diagnostic image, and the machine image was flashed and reloaded several times during the readings.

#### Next Steps:

The gap is between the loader accepting bytes on the host side and the CPU fetching from `0x08000000`, and it has two candidate halves that the current probe cannot separate: whether the cartridge bytes land in SDRAM at all, and whether the CPU's fetch path reaches the controller once they do. Add a probe bit or two rather than reasoning: a sticky `loader_do_valid` (the byte actually entered the loader, not the host's belief that it sent it) and a sticky `cpu_mem_ready`, both of which exist as wires in `gbatang_memory`'s interface and neither of which is in the current map, then read them under the same three conditions. If `loader_do_valid` never sets, the fault is in the loader-to-memory path and `tools/load_gba_rom.py`'s baud and framing are the instruments. If it sets and `cpu_mem_ready` does not, the fault is the acknowledged-request loss already fixed in simulation and the fix has not reached the board. Also worth one cycle: with the test cartridge the CPU halts and wakes seven times, which is the boot halt loop the simulation shows, while RetroRegen halts once and never wakes -- that difference is not explained and may be the larger cartridge or the save-data check rather than a fault. Do not read a black picture as evidence about the machine: pin the capture format and quote the histogram, as BRD-012 requires.

#### Files Modified:

- .ai/core-log.md
- .ai/core-reference.md
- fpga/gba/src/gbatang_top.sv

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: PENDING

---

## 16 COMMIT Unreleased 2026-11-02T21:40:00-07:00

#### Coming From:

Unreleased e46fe86

#### Purpose:

Put the two signals that separate "the bytes never arrived" from "the controller never acknowledged" onto the probe wire, and close a hole in the decoder that made reading a capture depend on luck.

#### Outcome:

The probe now carries `loader_valid` (`loader_do_valid` rose) at bit 14 and `mem_ready` (`cpu_mem_ready` rose) at bit 15, which are the two facts BRD-013 left unresolved: `cart_fetched = 0` is consistent with the cartridge bytes never entering the loader and with them entering a controller that never acknowledges, and nothing on the wire could tell those apart. Both signals already existed as sticky latches in `st_bits[2]` and `st_bits[3]`; they had simply never been exposed, so this is a map change rather than new capture logic. Two bits had to come off to keep the sixteen-bar geometry that the renderer and the decoder both assume, and `scanline_run` and `hblank_arrived` were the ones removed: both are already recorded as VERIFIED in BRD-013, and `vblank_arrived` still proves the video timing runs, so nothing that has been relied on is lost. The map id moves from `1dce3f01` to `b7850627`, which is the mechanism working: every field above bit 1 moved, so an old capture is not readable under the new map. Building this exposed a defect in the decoder that was worse than the thing being built. `--decode` printed the *current* map id and then decoded regardless, so a capture taken under one map was silently rendered with another map's field names -- demonstrated by decoding the BRD-013 RetroRegen capture under the new map, which reported `vblank_arrived = 1` where the bit was actually `scanline_run`. The docstring claimed "a capture decodes only under the map that built it" and that claim was false in the code, which is the same class of defect as the stale comment in entry 15: a plausible output with no enforcement behind it. It mattered more here, because the tool exists specifically to stop this, and a session that trusted it would have gotten a confident wrong answer. The fix is mechanical rather than advisory: `tools/build_tinygba.sh` now records the map id in `$out/probe-map.id` at build time, `tools/cap_tang.sh` copies that into a `<capture>.png.map` sidecar when it flashes and captures, and `--decode` exits 3 with both ids shown when the sidecar disagrees while marking a capture with no sidecar UNVERIFIED rather than decoding it quietly. The ids are derived from the build that produced the bitstream, not from whatever the tree contains at decode time, so a capture cannot be re-labelled after the fact. `tools/cap_tang.sh` is new and also pins the capture format, because the 1280x720-black trap in BRD-012 was previously avoided only by remembering to type the format by hand. The image built clean: seed 5, `clk67` 153.5 MHz against 67.0, cross-domain 21.4 and 41.5 ns against 59.7, zero hold violations, no relaxation, SHA-256 `23903d61b10f97f12d191d1cdac5fc8d930a7b117dbf1a1175dc85070db62a57`. Nothing was deployed, at the operator's instruction.

#### Next Steps:

Flash `build/tang_status2` and read the same three conditions BRD-013 used -- no cartridge, the 4 KiB test cartridge, RetroRegen -- because the two new bits make that comparison decisive: `loader_valid = 1` with `mem_ready = 0` means the bytes reach the memory path and the controller never acknowledges, so the simulation-verified fix has not reached the board; `loader_valid = 0` means the fault is upstream of memory and `tools/load_gba_rom.py`'s framing and baud are the instruments; both set with `cart_fetched = 0` would move the question to the CPU's fetch path rather than the loader or the controller. Capture with `tools/cap_tang.sh` rather than by hand, so the format is pinned and the sidecar is written. Keep the remaining unexplained difference in view: with the 4 KiB cartridge the CPU halts and wakes seven times, and with RetroRegen it halts once and never wakes, which nothing in this cycle accounts for and which may be the image size or the save-data check rather than a fault. Do not decode any capture without checking the map id, and do not treat the absence of a sidecar as agreement.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/probe_bits.vh
- tools/build_tinygba.sh
- tools/probe_map.py
- tools/cap_tang.sh

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: PENDING

---

## 17 COMMIT Unreleased 2026-11-02T23:05:00-07:00

#### Coming From:

Unreleased eadc31a

#### Purpose:

Find out what actually stalls the machine, after two decoder defects had made the previous hardware conclusions unreliable.

#### Outcome:

The memory controller is exonerated and the fault is the GPU not producing a VBlank, but reaching that answer required finding two independent bugs in the tool that was supposed to make decoding trustworthy. The first was geometry: `--decode` divided the measured field into sixteen equal bands, while the renderer computes `dbg_bits[x / 15]` for `x < 232`, so bar 15 spans 15 source pixels except the last, which is truncated to 7, and the field is not a multiple of sixteen. Every bar centre was therefore slightly wrong and the last bar was sampled roughly one bar to the left, reporting one field's value under another field's name -- the precise failure `tools/probe_map.py` exists to prevent, committed by the tool itself. The second was classification: `is_field` excluded the grey margin by exact match against a short list of greys, and the capture card's MJPEG encoder renders the 135-grey margin as `(134,134,134)` at some columns, so a strip of margin counted as field, the field edge was inflated by about forty display pixels, every centre shifted again, and the last bar was sampled inside the margin and read as zero. Both are now fixed by replicating the renderer's arithmetic and by classifying near-neutral pixels by tolerance rather than by membership in a list. The second bug was caught only because its output was impossible: a clk16-domain latch of `cpu_mem_ready` read 1 while a clk67-domain latch of the same signal read 0, and clk67 is four times faster, so that cannot happen. That contradiction was the most useful measurement of the cycle, and the lesson is to check decode output for internal consistency before believing any of it. With both fixed, the corrected picture is flatly different from the previous report and that report is withdrawn. On a fixed bitstream the board is bimodal across power cycles -- six runs alternating `0xFFFF, 0xF1F4, 0xFFFF, 0xFFFF, 0xF1F4, 0xFFFF`, identically for a 4 KiB and a 284 KiB cartridge. The good state has VBlank, fifteen or more halt entries, and a cartridge fetch. The bad state has `mem_ready = 1`, `mem_ready_clk67 = 1`, `clk67_alive = 1`, DISPSTAT written including the V-Blank IRQ enable, IE and IME written, `halt_entries = 1`, `halt_cleared = 0`, `vblank_arrived = 0` and `cart_fetched = 0`. So in the bad state the CPU configures the V-Blank interrupt, halts once, and waits forever for a VBlank that never arrives; the memory path, the clk67 clock distribution and the CPU are all demonstrably working. The black picture is a consequence, not the fault. The claim in the previous entry that the controller never acknowledges was a decoder artefact and is withdrawn here. A lead was found by reading the timing generator while the build ran and is recorded as a lead and not a result: `cycles` advances only on `if (mclk & ~mclk_r)`, and `mclk_r` is one of two registers in `gba_gpu_timing.v` that the reset branch does not assign (the other is `pixelpos`); if that edge detector never fires, `cycles` never reaches its per-state thresholds, `linecounter` never advances, no VBlank is raised and the CPU stays halted -- which is the observed state exactly. Why this was missed for several cycles is worth carrying: the status probe draws its bars from `gba2hdmi`'s own raster, not from the GBA's GPU, so a perfect picture proves the display path and says nothing whatever about the GBA timing generator, and treating the picture as evidence about the GPU is what hid a frozen GPU behind a working screen. The discriminator build itself (`build/tang_scan`, seed 5, `clk67` 130.5 MHz, zero hold violations, no relaxation, SHA-256 `e6731802d0fe9093f747798a0de601499882368548e46209e7a13b58c8e06500`, map `8c589e34`) puts `scanline_run` on bit 14, replacing `clk67_alive` which had read 1 in every run, so the raw VCOUNT separates "GPU not running" from "GPU running and the flag path broken". Nothing was deployed, at the operator's instruction.

#### Next Steps:

Flash `build/tang_scan` and read the bimodal pair, because `scanline_run` decides between the two remaining causes in one capture: if it is 1 in the failing state the timing generator is advancing and the fault is the DISPSTAT flag or probe path, and if it is 0 the generator is frozen and the unreset `mclk_r`/`pixelpos` lead becomes the primary suspect. Run each condition until both states have been observed rather than reading a single capture, since six runs were needed to see both and a one-shot read has a coin-flip chance of naming the wrong state. Then fix with mechanism rather than prose: assign `mclk_r` and `pixelpos` in the reset branch so the timing generator has no power-up-dependent state, and re-run the same alternating sequence to show the bimodality is gone. Every capture from here should come from `tools/cap_tang.sh` so the format is pinned and the map sidecar is written, and decode output should be checked for internal contradictions before it is quoted.

#### Files Modified:

- tools/probe_map.py
- tools/build_tinygba.sh

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: PENDING

---

## 18 COMMIT Unreleased 2026-11-03T00:55:00-07:00

#### Coming From:

Unreleased 332840e

#### Purpose:

Localise the frozen GPU inside the timing generator, and leave a clean, reproducible state for a handoff after the interruptible build was stopped at the operator's request.

#### Outcome:

The GPU's stall is now located one level deeper than before, and the cycle produced a third decoder defect that matters more than the findings it would otherwise have supported. Taps added behind `TINYGBA_STATUS_TEST` in `gba_gpu_timing.v`, plumbed through `gba_gpu.v` to the top, latched on `clk50` and synchronised into `clk16`, expose four rungs of the generator: reset released, state machine left VISIBLE, cycle counter reached 100, cycle counter reached 1008. The non-diagnostic build is unaffected, checked by building the Verilator model, which does not define the tap. The first capture with these taps decoded as `gpu_released=1`, `[1]=0`, `[2]=1`, and the field map labelled `[1]` as `cycles_100` and `[2]` as `cycles_1008`. That was one rung low: `DBG_gt` packs `{cycles>=1008, cycles>=100, left_visible, released}`, so `[1]` is `left_visible` and `[2]` is `cycles>=100`, and `[3]` — the top rung — was not on the wire at all. Relabelled and widened, the reading is that the cycle counter reaches 100 and the state machine never leaves VISIBLE, which is a specific fault rather than "frozen" and points at a reset that keeps returning: the counter restarts from zero often enough to pass 100 and never often enough to complete a 1008-cycle line. `gbaon` drives that reset, so a `gbaon` that falls again after rising would produce exactly this signature, and a `gbaon_fell` bit was added to test it directly. This is the third decode defect found in one session and the pattern is the important part: the first was bar geometry, where `--decode` divided the field into sixteen equal bands while the renderer draws 15-pixel bars with the last truncated to 7 pixels; the second was grey classification, where exact membership in a short list of greys failed against the capture card's MJPEG rendering the margin as `(134,134,134)`, inflating the field edge by about forty display pixels; the third was hand-written bit indices in the new map, one rung off the RTL packing. All three produced plausible output rather than an error, all three were caught by evidence rather than inspection — the first two by an impossible combination (`mem_ready=1` from clk16 while `mem_ready_clk67=0`, impossible because clk67 is four times faster), the third by the ladder's own internal ordering — and none would have been caught by a width check. Two conclusions from earlier in the session are withdrawn and must not be revived: that the SDRAM controller never acknowledges (it does; `mem_ready` and `mem_ready_clk67` are both 1 in the failing state), and that the fault is a memory-path problem at all. The memory path, the clk67 clock distribution and the CPU are all demonstrably working in the failing state; what fails is the GPU's raster. Every capture taken through the unpinned ffmpeg path is void per BRD-012, and every capture decoded before the geometry and grey fixes is suspect for bit 15 at minimum. The bitstream `build/tang_gb` was stopped during routing at the operator's instruction and is not complete: synthesis finished at 79,460,697 bytes, the register-parity gate passed, and nextpnr was killed at iteration 207,000 with 30,875 nets still unrouted. Nothing was deployed after `build/tang_scan`, whose map `8c589e34` is what produced the discriminating `scanline_run=0`.

#### Next Steps:

Rebuild `build/tang_gb` from the current tree (synthesis is cached and the netlist is intact; `TINYGBA_STAGE=pnr` then `pack`), flash it, and cycle loads until the bad state is caught, because the board is bimodal across loads and a single capture has a coin-flip chance of naming the wrong state — six cycles were needed earlier. Read `gbaon_fell` in the failing state: if it is 1 the loader's release is not stable and the fix is to make `gbaon` latching rather than a level, which would explain the bimodality, the single halt entry and the missing fetch from one cause; if it is 0 the reset theory is wrong and the next instrument is the `mclk` edge detector inside the generator, since `if (mclk & ~mclk_r) cycles = cycles + 1` is the only path that advances the counter and `mclk_r` is one of two registers in `gba_gpu_timing.v` that the reset branch does not assign, the other being `pixelpos`. Fix with mechanism, then demonstrate the bimodality is gone by cycling loads under the same conditions rather than by observing one good run. Capture with `tools/cap_tang.sh` so the format is pinned and the map sidecar is written, decode with `tools/probe_map.py --decode`, and check every decode for internal contradictions before quoting it — that check is what caught two of the three decoder defects. The Verilator model cannot reproduce this class of fault because it never fails to boot, so a fix must be validated on the board or by deliberately perturbing the model's reset timing; do not claim a fix is verified from simulation alone.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_gpu.v
- fpga/gba/src/gpu/gba_gpu_timing.v
- tools/probe_map.py
- fpga/gba/src/probe_bits.vh

#### Status:

- Build: NOT RUN (build/tang_gb stopped during routing)
- Deployment: PASS (build/tang_scan, map 8c589e34)
- User Test: FAIL (black screen, grey pillarbox, HDMI synced)

---

## 19 COMMIT Unreleased 2026-11-03T13:00:32-07:00

#### Coming From:

Unreleased 67e60ad

#### Purpose:

Settle whether the board's frozen GPU raster comes from a metastable loader release or from a defect inside the timing generator, by simulating the generator directly and then putting the best-supported configuration on the board.

#### Outcome:

The generator's reset was genuinely broken, fixing it produced the best timing this port has ever recorded, and the board still draws nothing -- and the cycle's durable results are that defect, a negative result about clock phase, and the first simulation of a BIOS screen in this project's history. The defect is in `gba_gpu_timing.v`: the reset branch sets `cycles_reg <= 0`, but the same always block ends with an unconditional `cycles_reg <= cycles;` where `cycles` was loaded from the pre-edge value, and in Verilog the last non-blocking assignment in a time step wins, so the zero was destroyed and the counter survived reset. Measured in a standalone Verilator model of the module: assert reset at `cycles_reg` 206 and it stays 206. Moving that assignment inside the non-reset branch makes reset do what it says (206 to 0) and leaves frame generation untouched (2 VBlanks in 40 ms, linecounter sweeping 0 to 227, 405 lines). The consequence is larger than the bug: all five seeds of the corrected design now pass `clk67` at 154.012 to 163.747 MHz against a 67.002 MHz constraint with no multicycle relaxation at all, where every earlier build needed the documented four-cycle readback allowance to scrape past at 31 to 36 MHz, so the dead assignment had been masking the real critical path from `cpu_mem_rdata` into `sdram.*`. Two things were established with the Verilator harness rather than the board. Built with the operator's official BIOS and the logo-bearing test cartridge, the model renders the BIOS boot screen -- 240x160, 22 colours, a white `(252,252,252)` field with the logo lettering -- which is the first time this project has reproduced that picture anywhere; and because the harness draws its screenbuffer straight from `pixel_out_we`, `pixel_out_x/y` and `pixel_out_data`, and because `video.mem_portA_we` traces through `mem_portA_we_DFF_Q` to `gpu.igba_gpu_colorshade.pixel_out_we` in the routed netlist, both the GPU's pixel stream and its handoff into the framebuffer are sound. A phase sweep then refuted entry 10's leading candidate outright: with `clk50` and `clk16` at 3:1 and the `clk16` edge moved across twelve offsets from 0 to 55 ns, the raster completed two frames at every one, so the difference between the model's single counter and the board's two PLLs does not matter. Three mechanisms were proposed and withdrawn in the course of this. The first was that `gbaon` was toggling, which the probe had already refuted by reading `gpu_released=1` in the failing state; the sticky release built on it was reverted rather than carried. The second was `TINYGBA_GBAON_ALWAYS`, which ties the release high and failed on hardware because it starts the machine before the loader has written the cartridge, an ordering the model does not have. The third was re-examining the OSD, which is absent from the netlist by construction: zero nets matching overlay, menu, textdisp or cursor. The deployed image was `build/rf_4/tinygba.fs`, SHA-256 `752d933ee7bfa62410f954f5c0e19143650fe7e8a805f2d1051f9aaf3ff9ad19`, built at seed 4 and flashed one-wire, and the operator reports the same picture as every previous attempt: black centre with the grey pillarbox, HDMI synced. One operational fact cost time and is recorded so it does not again: three separate USB disappearances this session, twice taking the FT2232 and both serial ports and once producing a `TinyTang CDC` device instead, were all the console sitting in two-wire mode rather than a cable or driver fault, and the board flashes normally once it is returned to one-wire. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 18 were not rewritten, and validated this entry as entry 19 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of nineteen against the 100-entry limit.

#### Next Steps:

Add `gba2hdmi` to the Verilator build, because the model and the board now agree about everything the model contains and disagree only on the picture, and the one block the model does not compile is the framebuffer, the scaler and the TMDS path -- compiling it turns the last untested link into something a simulation can fail. The question to answer first is whether the GPU still produces a pixel stream once the model carries the framebuffer, and the second is what `x/y` coordinates those pixels land on, since a stream writing outside `pixel_y * 240 + pixel_x` would leave the frame empty while looking perfect upstream. Do not re-derive what this cycle settled: the reset assignment defect, the phase-independence result, the BIOS render in the model, and the absence of the OSD from the netlist are all measured and recorded. Treat the two-way split honestly -- the board has still never been shown to write the framebuffer, so a build that holds the GPU in reset while driving `mem_portA` from a known pattern would separate "no pixels are generated" from "pixels are generated and not displayed" in one flash, and that is the cheaper experiment if the simulation path stalls. Keep `TINYGBA_GBAON_ALWAYS` in the tree as a documented diagnostic even though it failed here, because it isolates the loader from the machine and will be wanted again once the picture works; do not enable it expecting a picture.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_gpu_timing.v

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 20 COMMIT Unreleased 2026-11-03T21:56:28-07:00

#### Coming From:

Unreleased 071e49f

#### Purpose:

Prove on the board whether the GPU's raster actually runs after the counter-reset fix, and if it does, follow the fault down to the stage that stops producing pixels, while building instruments that cannot report a plausible wrong answer.

#### Outcome:

The raster is proven running on the board and the fault is now localised to the drawer, and reaching that took four instrument defects, each of which produced a confident wrong reading first. The raster result is the session's durable one. A diagnostic build carrying the timing generator's ladder across the framebuffer read `white white white black white white white black` under `TINYGBA_PIXTEST`: reset released, state machine left VISIBLE, counter passed 100, unreachable 1008 rung black as designed, `mclk` edge detector fired, counter passed 400 and 700, and `gbaon` never fell. Every rung that a healthy raster sets was set, and the rung that cannot light by construction stayed dark, which is also a check on the instrument. That supersedes BRD-014's `left_visible=0`/`scanline_run=0`, which came from `build/tang_gpu` built before commit `071e49f`, so the dead `cycles_reg <= 0` in `gba_gpu_timing.v` was the raster fault and fixing it closed that record. The next build moved one stage down and read `white white black white white white black white`: `drawline` fires, `hblank_trigger` fires, and `pixel_out_we` never does, so the timing generator hands lines to the drawer and the drawer never emits a pixel. That chain is now the whole open question. Bimodality was also confirmed rather than assumed: two loads of the same bitstream `build/drw2_6/tinygba.fs` gave an all-black strip and then the good reading, which is BRD-014's warning arriving on schedule and which invalidates every single-sample conclusion taken earlier in the session. Four instrument defects are recorded because each one would have supported a wrong finding. First, the initial eight-band build wired `DBG_gt` live rather than latched; because the counter sweeps 0 to 1007 continuously, a live sample reads "below 100, in VISIBLE" about nine times in ten even on a healthy raster, so six of its eight bands were a coin flip, and the build was replaced with a sticky-OR latch. Second, tap registers placed inside `gba_gpu_drawer.v` were removed entirely by synthesis, because `pix_drawer` was their only consumer and sat on no path to a displayed output; the fix is to export raw signals and latch at the top level, where they reach `dbg_bits`. Third, an `assign` referencing `drawstate` before its declaration silently created an implicit wire, and the comparison folded to a constant. Fourth, a band computed as `busy_allmod == 8'h00` folded to the constant-zero net and would have read black for ever; it was replaced with individual busy bits. A fifth defect ended the session without an answer: the latest build's read `white black black black black white white white` is internally contradictory, because band 0 says the machine reached WAITHBLANK and band 3 says `drawline` never fired, and reaching WAITHBLANK requires `drawline`. The cause is that `drawstate` has no reset anywhere in `gba_gpu_drawer.v`, so it powers up in an arbitrary state, and sticky latches cleared by `~resetn` immediately begin sampling uninitialised values the moment reset releases. For a machine that is stuck rather than transient, a live level is the correct instrument and the latch is what introduced the ambiguity. One timing observation belongs with the handoff and is not explained: the drawer-ladder builds pass `clk67` at 32 to 38 MHz where the preceding family passed at 144 to 164, always inside the 59.70 ns multicycle budget and never a gate failure, with 1,683 fewer LUTs and 24 more flip-flops, which fits ABC choosing a different optimisation boundary as core-log entry 6 recorded rather than a design regression. Nothing is committed from the two seeds that were still routing; both were stopped by pid. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 19 were not rewritten, and validated this entry as entry 20 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty against the 100-entry limit.

#### Next Steps:

Rebuild `TINYGBA_PIXTEST` with live levels instead of sticky latches, because the machine is stuck and its steady state is the answer while the latch is what produced the contradictory reading: bands 0 and 1 should show `drawstate` in binary directly, bands for `drawline`, `hblank_trigger` and `pixel_out_we` should be live levels, and two bands should show `busy_allmod[7]` and `busy_allmod[6]` individually along with an OR of the whole vector, so a stuck-DRAWING state names the busy module by bit position. Take every reading across at least three loads before believing it, since two loads of one bitstream have already disagreed, and treat a strip whose bands contradict each other -- reaching WAITHBLANK without `drawline` is impossible -- as a bad sample rather than a finding. Do not re-derive what this cycle settled: the raster runs, `drawline` and `hblank_trigger` fire, and `pixel_out_we` never asserts. Do not widen the search back to memory, clocks or the OSD. If the drawer turns out to be stuck in DRAWING with a busy drawer named, the memory path that the drawers read through `gba_memory`'s GPU ports is the next suspect, because those ports have never been exercised on this board while the simulator substitutes plain arrays, and that is the same model-versus-hardware gap that hid the `gb_bus_rst` fold. `TINYGBA_GPU_TAPS` now gates every GPU tap and is set by both `TINYGBA_STATUS_TEST` and `TINYGBA_PIXTEST`; a new diagnostic that needs the taps must set it explicitly and must declare it before the first `ifdef` that reads it, since preprocessor order silently swallowed an earlier attempt. The console's FT2232 disappears whenever it is in two-wire mode (BRD-015) and this recurred three times; check `lsusb | grep 0403:6010` before concluding anything about a load failure.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_gpu.v
- fpga/gba/src/gpu/gba_gpu_drawer.v
- fpga/gba/src/gpu/gba_gpu_timing.v

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 21 COMMIT Unreleased 2026-11-04T09:58:58-07:00

#### Coming From:

Unreleased 105543b

#### Purpose:

Build the instrument that can say where inside the GPU drawer a line stops, after entry 20 left a self-contradictory strip because it latched a stuck machine, and inherit the one build gate the sibling SNES project wrote in the same cycle that turned its coprocessor on.

#### Outcome:

The instrument is rebuilt as sixteen bands that separate steady state from history, the gate is ported and proven, and nothing has been deployed. The instrument change answers the defect that ended entry 20 without an answer. That build latched every band, and because `drawstate` has no reset anywhere in `gba_gpu_drawer.v` the latches began sampling arbitrary power-up values the instant reset released, which produced a strip reporting WAITHBLANK reached while `drawline` was clear -- an impossible pair. The correction is to stop latching at all for the questions the machine's steady state answers, and to keep latching only for the controls a healthy machine must have produced. Bands 0 to 4 are now live levels re-sampled every `clk50`: `drawstate[1:0]` (0 IDLE 1 WAITHBLANK 2 DRAWING 3 MERGING), `busy_mode345`, and `vramfetch[1:0]` (0 IDLE 1 STARTREAD 2 WAITREAD 3 FETCHDONE). Bands 5 to 10 are sticky ever-true history, cleared on reset: a VRAM fetch reached FETCHDONE, `pixel_out_we` asserted, `drawline` fired, the OBJ drawer reported busy, some drawer reported busy, and `gbaon` rose. Bands 11 to 15 carry live `gbaon` and four unused zeroes. The timing generator's ladder is deliberately dropped from this frame: its answer is already recorded in BRD-017 and carrying it would cost half the bands the drawer needs. The renderer moved from eight bands of 30 source pixels to sixteen of 15, which is 67 display pixels each at the 4.5 scale this mode uses. One hypothesis died on the way and is recorded so it is not re-run: the VRAM read latency is not a model-versus-hardware asymmetry, because `gpu/vram_lo.v` instantiates `DPB` with `READ_MODE0 = 1'b0` (one clock) and `common/sim_dpram_be.sv` does `doutb <= mem[addrb]`, also one clock. What survives as a candidate, and is not promoted past a candidate, is narrower and inside `gba_drawer_mode345.v`'s `tFetchState_WAITREAD`: that branch spends a two-cycle `vram_readwait` countdown BEFORE it examines `VRAM_Drawer_valid_Lo`/`_Hi`, so a one-cycle strobe arriving inside the window is discarded and the poll then waits for a pulse that has already gone. `busy` only clears when a fetch reaches FETCHDONE, so such a stall parks the drawer in DRAWING for ever and no pixel is merged out, which is the observed symptom. The new bands are what would name it: `busy_mode345` high with `vramfetch` in WAITREAD. The second result is the gate. `tools/clock_edge_check.py` is ported from TinySNES, where it is build step `1b` and where its absence cost a whole cycle. On GW5A `synth_gowin` keeps only a plain negedge flop as a true `DFFN` and legalises every negedge flop with an enable or reset into a posedge `DFFRE` behind a LUT1 inverter of the clock, so the two halves clock a few ns apart with no hold check between them; that deadlocked the SuperFX on the board while an ideal-clock bench ran it. The port is wired as build step `1c`, immediately after the register-parity gate, and it was proven rather than assumed. A minimal module carrying the construct -- one plain negedge flop plus negedge flops with an enable and with a reset -- synthesises under `synth_gowin -family gw5a` and the gate exits 1 naming the clock, the true negedge flop and the inverter; today's tree exits 0; a missing file and a missing argument both exit 2. TinyGBA had no gate for this class and its netlists had never been checked for it. Measured here on 2026-11-04: zero `DFFN` cells in a routed netlist, and no flop or block RAM clock pin driven by LUT, MUX or inverter fabric, so the tree is clean and the gate is insurance rather than a fix -- which is exactly the kind of property that rots when it is only ever a one-off grep. The third result is a firm negative about the clock plan, and it is the one that constrains how any future hardware reading may be worded. `tools/clock_plane_report.py --strict` refuses both `build/drw3_1` and the new `build/pix16_s1`: no placement this tree produces puts all four clocks on pips measured good on this board. `clk16` sits on six `*/TOP3` pips with no record at any seed, `clk50` on three unmeasured ones, `clk67` on `SPINE19/TOP2` unmeasured plus `SPINE27/TOP2` only `partial`, and `hclk` on two unmeasured. Only six clock-plane paths are measured-good here, all `clkdiv` or `pll` on `BOTTOM2`/`TOP0`/`TOP1`, and none of them carries `clk16`. That makes the TinySNES BRD-005 variable live on this port: there, the identical netlist booted or left the cartridge depending only on which spine the master clock took, with every build passing Fmax and none reporting a hold violation. The build itself is clean and reproducible. `TINYGBA_PIXTEST` at seed 1 completed in 14 minutes 48 seconds with zero hold violations, every clock passing (`clk16` 19.732 against 16.750, `clk50` 89.071 against 50.251, `clk67` 117.633 against 67.002, `hclk` 98.707 against 74.250), cross-domain paths 19.44 and 39.78 ns against a 59.70 ns budget, and no multicycle relaxation needed, which is the first PIXTEST configuration to reach a bitstream without one. `tinygba.fs` is SHA-256 `454a5dde2ac200fd8a5768e82bd772b84b67cf2138a9a5e6fb9119e3242cdab2` and `tinygba.bin` is `1f6aec923dfcf74af87481d2082d4689a4ef17413b37268eb33667bff6e0c568`, 11,535 flip-flops and 148 block RAM. The taps were verified to have survived synthesis rather than assumed: `tools/gatelevel_report.py` reports `pix_live` 7 bits and `pix_hist` 6 bits all present and all driven, and a backward trace from `video.mem_portA_wdata_DFFRE_Q` reaches both, which is the TCL-013 requirement that a diagnostic register sit on a path to a displayed output. A default-configuration synthesis was run as a regression control and elaborates at 11,574 flip-flops and 149 block RAM with the clock-edge gate clean, so the non-diagnostic build is unaffected; `DBG_vf` is inside `TINYGBA_GPU_TAPS` at both the drawer and the GPU level. No parity baseline was recorded for either configuration, because `.ai/core-log.md` entry 11's rule is that a baseline from a build whose correctness is unknown certifies nothing, and neither build has been booted. Nothing was deployed and the Tang was not connected to, at the operator's instruction, so there is no hardware reading from this cycle and the drawer bands remain unread. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 20 were not rewritten, and validated this entry as entry 21 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-one against the 100-entry limit.

#### Next Steps:

Deploy `build/pix16_s1/tinygba.fs` when the operator releases the board, take at least three loads because BRD-014 measured the machine bimodal across loads of one fixed bitstream, and capture with `tools/cap_tang.sh` so the format is pinned per BRD-012 and the map sidecar is written. Read bands 0 to 4 as "where is it now" and bands 5 to 10 as "did the machinery ever work". The discriminating pair is band 2 against bands 3 and 4: `busy_mode345` white with `vramfetch` reading WAITREAD names a VRAM fetch that accepted an address and never collected the data, which makes the `vram_readwait` countdown in `tFetchState_WAITREAD` the first thing to examine and the fix a re-timed poll that cannot discard a strobe -- either dropping the countdown or latching `VRAM_Drawer_valid_Lo`/`_Hi` across it. `busy_mode345` black with `drawstate` reading IDLE means the drawer never started and the search goes back up one level to the `drawline`-to-`WAITHBLANK` transition and its `linesDrawn < 160` term. Stuck in DRAWING with `vramfetch` IDLE names a drawer other than mode345, and band 8's OBJ history says whether that one ever ran. Treat a strip whose controls are black -- `drawline` never fired, `gbaon` never high -- as a bad sample rather than a finding, exactly as entry 20's contradictory strip was. Do not re-derive what is recorded: the raster runs (BRD-017), the line reaches the drawer (BRD-018), and the VRAM read latency matches the model, so the model-versus-hardware gap is not there. Separately, and before any hardware result from this tree is worded as a statement about the design, settle the clock plan: `--strict` refuses every placement, `clk16` has never been on a measured-good pip on this board, and the only pips that drew the verified picture are the `TOP2` ones. The route to closing it is not another build but a measurement -- a diagnostic that exercises a wide `clk16` domain and is read on the board, so the pip acquires a record -- because the tool can only gate on facts the reference library already holds. Do not switch `TINYGBA_CLOCK_PLANE_STRICT=1` on permanently until that measurement exists, or every build is refused for a reason no one can act on. Record parity baselines for `TINYGBA_PIXTEST` and the default configuration once each has been boot-tested, not before.

#### Files Modified:

- README.md
- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_drawer_mode345.v
- fpga/gba/src/gpu/gba_gpu.v
- fpga/gba/src/gpu/gba_gpu_drawer.v
- tools/build_tinygba.sh
- tools/clock_edge_check.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 22 COMMIT Unreleased 2026-11-04T15:38:23-07:00

#### Coming From:

Unreleased bfd0b31

#### Purpose:

Replace the PIXTEST bands that the 2026-11-04 hardware reading could not be trusted to answer, after establishing that a live sample of the per-line fetch state cannot distinguish a frozen machine from a capture landing at the same line phase.

#### Outcome:

The instrument is corrected and rebuilt at a clean seed, and the correction withdraws the standing of last cycle's live-band reading rather than adding to it. Entry 21's bands 3 and 4 were live samples of `vramfetch`, a register that cycles every line, and 48 identical frames across eight seconds were read as a freeze. That inference was unsafe: `clk50` and the pixel clock are locked, so the capture can land at the same line phase every frame and a live sample of a cycling register cannot separate the two cases. This is the aliasing class BRD-014 and TCL-010 already record, and it was my error to sign off on the reading without ruling it out; the sticky bands 5 to 11 of that build are unaffected because a sticky bit cannot alias. The fix asks the fetch questions as sticky facts. Bands 7 to 10 now record whether `vramfetch` ever reached STARTREAD, WAITREAD, FETCHDONE, and returned to IDLE after a line started, and those four are armed on the first `drawline`, because before a line is drawn the machine legitimately sits in IDLE and an unarmed latch would record the reset value -- the arming trap TCL-013 records. The discriminator is band 10 against band 9: a fetch machine that cycles normally sets both, while one frozen at FETCHDONE sets band 9 and never band 10, and neither bit can clear so no capture artefact can fake it. The live bands narrowed to registers that either never move or answer a mode question: `drawstate`, `busy_mode345`, `DrawState`, and all three bits of `BG_Mode` read from the drawer's own register rather than from `DISPCNT`. That last one is aimed at the contradiction the previous cycle left open, because `tFetchState`'s `WAITREAD` is only reachable when the drawer decodes mode 4 while the test cartridge writes `DISPCNT` `0x0403`, which is mode 3, and band 6 alone separates those. `DrawState` is two bits wide but takes only 0 and 1, so synthesis folds its high bit to GND; rather than ship a band that is black by construction the bit was spent on `BG_Mode[0]`, and that fold is recorded because it is exactly the kind of always-black band TCL-013 warns will read as a finding. The memory path the cycle was authorised to investigate was traced instead to a conclusion that removes it as a suspect. The VRAM is not shared with the CPU: `vram_lo` and `vram_hi` are instantiated inside `gba_gpu_drawer.v` at line 838, port A is the CPU on `mclk` and port B the drawer on `fclk`, both `CE` and `OCE` tied high, `READ_MODE0` `1'b0`, and the Verilator build substitutes `sim_dpram_be` with the same one-clock ports. There is no arbitration, no acknowledge and therefore no model-versus-hardware gap in that path, and `vram_blocked` is a non-signal for it. What the measured facts do form is a closed loop: `busy_mode345` clears only when `vramfetch` is IDLE and `DrawState` is NEXTPIXEL, and `vramfetch` leaves FETCHDONE only when `DrawState` is NEXTPIXEL, so every band observed is consistent with `DrawState` being stuck away from NEXTPIXEL. The build cost more routability than its flip-flop count suggests and that is recorded as a toolchain fact rather than a complaint. Synthesis went from 11,535 to 11,538 flip-flops, three registers, but LUTs rose 40,778 to 41,294 and routing arcs from 220,272 to 228,317, about 8,000 arcs, because the added logic includes a wide vector reduction in `gpu_ds[9:2] != 8'h00`. Seed 1 failed place and route after 32 minutes and 368,000 iterations, plateauing near 20,000 unrouted nets, so the netlist was placed at four further seeds in parallel: seeds 3, 4 and 5 were still oscillating at 42 minutes and were stopped by exact pid, and seed 2 completed with zero hold violations, every clock passing (`clk16` 18.990 against 16.750, `clk50` 88.676 against 50.251, `clk67` 118.259 against 67.002, `hclk` 86.333 against 74.250), cross-domain paths 18.23 and 37.26 ns against a 59.70 ns budget, and no multicycle relaxation. That is one clean seed of five attempted, which is on the poor side of the range this project records and is attributed to the arc increase rather than to a broken change. `build/pix17_s2/tinygba.fs` is SHA-256 `226cfe64a6dc56892168ab46a1d39f5ee22ff6de2d2ff11c898fed0e68ffe3e1` and `tinygba.bin` is `d637c1fd2b0b6ff4839e402c470af138a70b9e515a0c2f507ad7520f0a62ad89`. The taps were verified rather than assumed on the routed netlist: `pix_live` 7 bits, `pix_hist` 9 bits and `pix_armed` 1 bit are all present and all driven by their own `DFFRE`, `dbg_bits` carries sixteen bits with no GND padding at all, and a bounded backward trace from `video.mem_portA_wdata_DFFRE_Q` reaches the band word, which is the TCL-013 requirement. One process error is worth recording because it cost a cycle: the first correction was re-synthesised into the same build directory, the build reused the cached netlist, and the resulting GND on a tap bit was misread as the fix having failed. Nothing was deployed and the Tang was not connected to, at the operator's instruction, so this cycle produced no hardware reading and the corrected bands are unread. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 21 were not rewritten, and validated this entry as entry 22 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-two against the 100-entry limit.

#### Next Steps:

Deploy `build/pix17_s2/tinygba.fs` when the operator releases the board, and read bands 9 and 10 first, because they decide whether entry 21's freeze was real or an aliasing artefact and neither can be faked: both white means the fetch machine cycles normally every line and the live reading of last cycle was an artefact; band 9 white with band 10 black means a genuine freeze at FETCHDONE, which bands 3 and 4 then have to explain. Band 6 settles the mode contradiction in the same picture, because white means the drawer decodes mode 4 or 5 and black means mode 3, and `tFetchState`'s WAITREAD is only reachable from mode 4. Take at least three loads, since BRD-014 measured the machine bimodal and the previous cycle observed two states in three cycles, and treat a strip whose controls are black -- band 12 `drawline` ever, band 15 `gbaon` ever -- as a bad sample rather than a finding. Do not re-derive the memory path: the drawer's VRAM is a private dual-port block RAM clocked by the drawer's own `fclk`, not `gba_memory`'s arbiter, so contention and backpressure cannot be the fault and `vram_blocked` is not a signal to chase. If band 6 reads mode 3 and band 9 reads white with band 10 black, the contradiction is in `tFetchState`'s entry condition rather than in the mode register and the next instrument is `DrawState` plus the `drawline` and `vramfetch == FETCHDONE` terms that gate its transition. Separately, this instrument costs about 500 LUTs and 8,000 routing arcs more than entry 21's, which dropped the clean-seed yield from one of one to one of five; if the diagnostic frame is ever to be grown again, prefer individual bit terms over a wide vector reduction, since that reduction is what moved the arc count. Do not re-synthesise into an existing build directory when testing a logic change: the cached netlist is reused and the result is a stale reading of the previous design.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_drawer_mode345.v
- fpga/gba/src/gpu/gba_gpu.v
- fpga/gba/src/gpu/gba_gpu_drawer.v

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 23 COMMIT Unreleased 2026-11-06T18:34:12-07:00

#### Coming From:

Unreleased c81eef1

#### Purpose:

Remove the board-only faults that kept the machine from drawing a picture, from the two-PLL clock split through to the GPU drawer hang that the PIXTEST bands exposed.

#### Outcome:

The GPU now draws on the board, and the fault that blocked it for entries 18 to 22 was synthesis, not logic. The cycle began on the clocks. `clk16` and `clk50` came from two PLLs with no phase relationship while the GPU samples `clk16` state in `clk50` and the SDRAM samples `mclk` raw in `clk67`, so all GBA clocks were moved onto one PLL, `pll16` at `PLL_L[0]`, from a 1809 MHz VCO: `CLKOUT0` divide 36 for `clk50`, `CLKOUT1` divide 27 for `clk67`, `CLKOUT2` divide 108 for `clk16`, and `CLKOUT3` divide 27 for the SDRAM pin clock. A `TINYGBA_CLKTEST` build proved every clock alive and on frequency on the board, but the boot test `pll1ov_s3` stayed black, and a PIXTEST seed sweep then showed the one-PLL move had pushed `clk67` onto general routing, because apicula carries no plane pip for `CLKOUT1`, with hold misses on `sdram.rst_cnt`. Vendor probe builds showed the vendor reaches the plane from `CLKOUT1` and `CLKOUT3` through centre-bridge muxes apicula does not model, so instead `CLOCK_LOC "clk67" BUFG;` was added to `fpga/gba/tinygba.cst`, which makes the nextpnr fork route `clk67` through a `BUFG` and a logic-to-clock gate onto `SPINE16/TOP0` and `SPINE25/TOP1`, both measured good; `clk67` went back into `tools/clock_plane_report.py`'s `REQUIRED_PLANE`, and the finding is TCL-018. `build/bufg_pix_s3` (`.fs` SHA-256 `8566e3e1585f90df75f3b46a2d1822a2cb657dc8fbbdb7bf8d188a508681fc5b`) passed with zero hold violations and on the board held `drawstate` at DRAWING in every capture with `pixel_out_we` never asserting. A new instrument, `build/obj_pix_s3` (`19dde6b5f69d945eec7856c301bcb4ed745d80b31435b4b63bdf539d0927f71d`), added an always-present `DBG_ob` tap of the OBJ drawer's `OAMFetch` and `PIXELGen` states and remapped the sixteen bands to `drawstate`, each drawer's `busy`, the OBJ states, `DISPCNT` OBJ enable, CPU `halt`, a sticky cartridge-fetch bit and `gbaon`. It read every drawer busy, including both affine drawers and mode 3-5 while in BG mode 0, and every drawer busy before the CPU had even been released, which no `drawline` could have caused. The netlist explained it: the upstream RTL leaves `busy`, `vramfetch` and `palettefetch` without reset or initialiser and relies on the vendor flow's power-up at 0, while yosys treats them as undefined, folded `busy_mode2_2 | busy_mode2_2_hd0 | busy_mode2_2_hd1` to a `VCC` cell so that `busy_allmod` could never reach 0, and mapped the other `busy` flops to `DFFSE`, which powers up at 1. `tools/build_tinygba.sh` now runs `setundef -zero -init` before `synth_gowin`, recorded as TCL-017 with the earlier `gb_bus_rst` fold of TCL-011 as the same class. `build/fix_pix_s3` (`.fs` `9c4fe8900f3be710b9be31671d52f9c37203e2ab6fc7dcc4d0c3466492effc81`, `.bin` `e3a648ae55b397b3e7a7b4e082c52faf4c047d4bdafe293af6b2f1b52b7b50bc`) passed with no relaxation and zero hold violations (`clk16` 19.725, `clk50` 80.769, `clk67` 103.210, `hclk` 98.678 MHz) at 48,247 LUTs, 12,038 flip-flops and 226,079 routing arcs, every drawer `busy` is now `DFFRE`, and the 86 remaining `DFFSE` all come from explicit initialisers or reset values of 1. On the board it reads all-zero bands before release, and after the cartridge loads `drawstate` cycles, the bands flicker as the operator saw, and the GBA field is a uniform grey instead of black, which also explains BRD-018. The machine still does not boot: across 48 frames over 12 seconds from reset the field never changes, `halt` toggles so the BIOS is taking V-Blank interrupts, and the cartridge-fetch bit never sets, which is BRD-020. The overlay-off reseeds behaved as TCL-009 predicts and exposed one limit of the `BUFG` route: `build/fix_ov_s1` (`.fs` `ed96667551e0a512a5c99a5d1cc29484b05c19164c0b8a85d1561a66b3f5a9bb`) and `fix_ov_s3` both built with zero hold violations but pass `clk67` only through the documented GBATang four-cycle readback path, at 36.8 and 37.7 MHz, while `fix_ov_s2` routed but was refused by the clock-plane gate because `clk67` fell back to general routing at that seed, so the `BUFG` route is a per-placement result rather than a guarantee and the gate is what catches it. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 22 and the existing reference records were not rewritten, and validated this entry as entry 23 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-three against the 100-entry limit.

#### Next Steps:

Find why the BIOS executes and takes interrupts but neither draws its logo nor jumps to the cartridge. The next instrument should replace the GPU-internal bands, which have answered their question, with what the BIOS is doing to the display: live `DISPCNT` BG mode, forced blank and the four BG enables, the `BLDCNT` effect bits, and `halt`, plus sticky bits for the CPU having written palette RAM, VRAM and OAM and for the cartridge fetch. Those decide between a BIOS that never loads its graphics and one that loads them but is stuck in its fade or blend state. Build from a fresh build directory, take at least three loads, and check every tap against the netlist for constant or undefined drivers before reading the board, since TCL-017 shows a band can be folded without the source looking wrong. When `fix_ov_s1` is wanted as an uninstrumented boot image it is the clean one of the three overlay-off seeds; `fix_ov_s2` must not be deployed. Do not remove `setundef -zero -init` from the build: every register this tree leaves unreset depends on it.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_drawer_obj.sv
- fpga/gba/src/gpu/gba_gpu.v
- fpga/gba/src/gpu/gba_gpu_drawer.v
- fpga/gba/src/pll/pll_16.v
- fpga/gba/tinygba.cst
- fpga/gba/tinygba.sdc
- tools/build_tinygba.sh
- tools/clock_plane_report.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 24 COMMIT Unreleased 2026-11-06T19:18:37-07:00

#### Coming From:

Unreleased 1e4e3a8

#### Purpose:

Find out what the BIOS does to the display after the `setundef` fix, and whether it reaches the cartridge.

#### Outcome:

The machine boots the official BIOS on the board for the first time, and the fault has moved to the cartridge. The PIXTEST band map in `fpga/gba/src/gbatang_top.sv` was replaced with live `DISPCNT` BG mode, forced blank and BG0 to BG3 enables, the `BLDCNT` special-effect bits and CPU `halt`, plus sticky bits for palette RAM, VRAM and OAM writes and for a cartridge instruction fetch, which clear while `gbaon` is low so they describe only the current load, and `gbaon`; a new always-present `DBG_dc` tap carries the `DISPCNT` and `BLDCNT` fields out of `gba_gpu_drawer.v` through `gba_gpu.v`, and the `gba2hdmi.sv` legend was rewritten. `build/dbg2_pix_s3` (`.fs` SHA-256 `af620647481fe950ce7322f885b3d17aaeeba5b1aeac87a0539c12ed64a39021`) passed with no relaxation and zero hold violations (`clk16` 19.502, `clk50` 79.580, `clk67` 145.285, `hclk` 97.069 MHz), and every one of the sixteen band flops traced in `build/dbg2_pix_s3/tinygba.json` to a `DFFRE` with a non-constant driver. While reviewing the legend it became clear that the PIXTEST frame writes its own grey below the bands, so entry 23's uniform grey field and BRD-020's reading that the BIOS never completed its intro were measurements of the instrument, not the machine. `build/fix_ov_s1` was therefore deployed as the first overlay-off image since the fix, and with `test_logo.gba` it played the complete BIOS intro, the GAME BOY and Nintendo marks, between about 1.5 and 5.5 s after release and then held solid white. `build/dbg2_pix_s3` then read the intro from the registers and showed the sticky cartridge-fetch band set from about 6.5 s, so the BIOS accepts the header and jumps, but the cartridge's first store, `DISPCNT` 0, never lands: the register holds BG mode 0, forced blank and all four BG enables, a value the cartridge never writes, with `halt` at 0. The operator then asked for a retail cartridge from the MiSTer image, and Super Mario Advance (USA, Europe), 4 MiB loaded at 2 Mbaud in 21.7 s, failed the same way, holding the BIOS handover value of forced blank with nothing enabled, and on `build/fix_ov_s1` the operator watched the intro end on white, so the test cartridge is not the cause. These are recorded as BRD-021, which supersedes BRD-020's intro reading, and BRD-022. One discrepancy is unexplained: `build/fix_pix_s3` read its cartridge-fetch band as 0 throughout while the identical latch reads 1 here. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 23 and the existing reference records were not rewritten, and validated this entry as entry 24 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-four against the 100-entry limit.

#### Next Steps:

Measure what the CPU fetches after the BIOS hands over. The next instrument should latch the first cartridge instruction fetches after `gbaon` rises, recording each `rom_addr` and the `rom_data` word the memory path returns for it, and draw them so they can be compared against the bytes of `test_logo.gba` at the same offsets; a wrong word at `0x080000C0` or a fetch that never completes names the instruction-fetch path from the cartridge SDRAM, while correct words would move the search to execution and the IO write path. Running the same cartridge in the Verilator model gives the reference fetch sequence to compare against. Build from a fresh build directory and check the taps against the netlist before reading the board. Keep `build/fix_ov_s1` as the uninstrumented boot image and do not remove `setundef -zero -init` from the build.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gpu/gba_gpu.v
- fpga/gba/src/gpu/gba_gpu_drawer.v

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---
## 25 COMMIT Unreleased 2026-11-06T20:01:48-07:00

#### Coming From:

Unreleased c1fa94d

#### Purpose:

Build an instrument that records what the CPU fetches and accesses after the BIOS hands over to the cartridge, so the BRD-022 failure can be placed in the instruction-fetch path or beyond it.

#### Outcome:

A new diagnostic configuration, `TINYGBA_FETCHTRACE`, was added and built but not deployed, because the operator stopped the cycle after the build for an agent handoff. In `fpga/gba/src/gbatang_top.sv` a clk16 recorder starts at the first completed CPU memory cycle whose fetch address is `0x08000000` or above, a completed cycle being `(rom_en | ram_cen) & cpu_en & ~halt`, and stores sixteen consecutive completed cycles as four 32-bit words each in `tr_flat`: word 0 is `{rom_en, thumb, 2'b00, rom_addr[27:0]}`, word 1 is `rom_data` sampled on the following clk16 edge where gba_memory presents it, word 2 is `{ram_cen, ram_wen, ram_be, ram_addr[27:24], ram_addr[21:0]}` and word 3 is `ram_wdata` for a write or `ram_rdata` sampled on the following edge for a read, with a per-entry valid bit; the record clears while `gbaon` is low so each cart load records afresh, and the configuration also turns the OSD overlay off. In `fpga/gba/src/gba2hdmi.sv` the new `tr_sel`, `tr_word` and `tr_valid` ports feed a framebuffer writer that draws each word as one row of 32 bit cells, bit 31 on the left, 7 by 5 source pixels per cell, white for 1 and dark grey or black for 0 in address words and dark blue for 0 in data words, alternating shade per nibble, four rows per entry and eight entries per page, with an entry-valid strip at x 224 to 231 and a page strip at x 232 to 239 that is black for entries 0 to 7 and white for 8 to 15, flipping every 2^26 clk50 cycles, about 1.34 s; outside the configuration `tr_sel` is tied to zero and `tr_word` and `tr_valid` to zero. `build/ftr_s3`, seed 3 from a fresh directory with `TINYGBA_DEFINES` set to `-DTINYGBA_FETCHTRACE` and `-DTINYGBA_BIOS_HEX` given the quoted absolute path of `build/test/official_bios.hex` (an unquoted path fails elaboration in `gba_memory.sv`), passed synthesis with no new warnings in the edited files, the clock-edge gate, the clock-plane gate with every clock on dedicated lanes and `clk67` on measured-good spines, and timing with no relaxation and zero hold violations (`clk16` 20.215, `clk50` 65.334, `clk67` 115.768, `hclk` 100.695 MHz); its `.fs` SHA-256 is `341c31ab1bc12c458213e2471b1e95f7b2979dc2d47d8a715eaeccbb1edca73c`, and the register-parity gate had no baseline for this configuration. In `build/ftr_s3/tinygba.json` all 2,048 `tr_flat` bits, the 16 `tr_vld` bits and the five `tr_n` bits are `DFFRE` cells, and every `tr_flat` flop in all four word positions has a non-constant D and clock enable. The board was left running `build/fix_ov_s1` with Super Mario Advance loaded, in one-wire mode.

#### Next Steps:

On the operator's explicit deploy, flash `build/ftr_s3/tinygba.fs` with `openFPGALoader -b tangconsole`, load `build/test/test_logo.gba` over `/dev/ttyUSB1` with `tools/load_gba_rom.py`, and capture both pages from `/dev/video0`, then decode the rows against the cartridge bytes. The expected start is a fetch of `0x08000000` returning `ea00002e`, probably followed by pipeline fetches of `0x08000004` and `0x08000008` before the branch takes effect, then `0x080000C0` returning `e3a0b301`, `0x080000C4` returning `e3a00000` and `0x080000C8` returning `e1cb00b0`, and the `strh` to `DISPCNT` at `0x04000000` with data 0 arriving in the same memory cycle as a later cartridge fetch, which is the first use of gba_memory's concurrent SDRAM-fetch-plus-data path through `rom_rdata_new`, since the BIOS executes from block RAM. A wrong instruction word, a missing or misaddressed `DISPCNT` write, or a stall names the fault; a correct trace moves the search to the IO write path into the GPU. Write a decoder for the capture before reading it by eye, keep `build/fix_ov_s1` as the uninstrumented boot image, and do not remove `setundef -zero -init` from the build.

#### Files Modified:

- fpga/gba/src/gba2hdmi.sv
- fpga/gba/src/gbatang_top.sv

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---
## 26 COMMIT Unreleased 2026-11-06T21:09:12-07:00

#### Coming From:

Unreleased b362039

#### Purpose:

Deploy the cartridge fetch trace that entry 25 built but never flashed, and answer whether the BRD-022 failure lies in the instruction-fetch path from cartridge SDRAM or past it.

#### Outcome:

The fetch path is exonerated and the fault has moved to the last store the cartridge executes. `build/ftr_s3/tinygba.fs`, whose `.fs` SHA-256 was re-verified as `341c31ab1bc12c458213e2471b1e95f7b2979dc2d47d8a715eaeccbb1edca73c` before flashing, was deployed one-wire with `test_logo.gba` streamed over `/dev/ttyUSB1`, and all sixteen recorded cycles decoded: every cartridge instruction fetch returns exactly the word in the ROM file, fifteen of fifteen, running `0x08000000` to `0xEA00002E` and `0x08000004` to `0x51AEFF24` before the branch, then `0x080000C0` through `0x080000F0` returning `E3A0B301`, `E3A00000`, `E1CB00B0`, `E3A0A000`, `E59F61D8`, `E59F51D8`, `E5964000`, `E1540005`, `138AA001`, `E59F61CC`, `E59F51CC`, `E5964000` and `E1540005`. The single apparent mismatch was entry 10, which is a data-access cycle with `rom_en` clear whose word 1 holds the previous entry's data, so it is not a fetch and not an error. Data reads are correct for the same reason: the literals at `0x080002B0` through `0x080002BC` return `0x08000400`, `0xA5A50001`, `0x08000800` and `0xA5A50002`, and the first `ROMCHK` read at `0x08000400` returns `0xA5A50001`, so that check passes on the board. The `DISPCNT` write is issued too, which is the part BRD-022 got wrong: the fetch of `0x080000C8` is followed two cycles later by a completed cycle carrying `ram_cen=1`, `ram_wen=1`, `be=0011`, `ram_addr=0x04000000` and `ram_wdata=0`, concurrent with the fetch of `0x080000D0`, which is the SDRAM-fetch-plus-IO-write path through `rom_rdata_new` that had never been exercised. Because that instrument could not say whether execution reached the end of the cartridge, the cycle was extended rather than stopped, and the extension is the four-page version of the same readout: `build/io_s3` at seed 3, `.fs` SHA-256 `58a911881cdb88974e7d574c3b511b9e86e488a503cc2c9e3353a7ce39536c5b`, `.bin` `0a7d41c459619fc43aa4ef139886be5cec4823c1eab70a87a91e1e49ab860599`, zero hold violations with no relaxation, `clk16` 20.094, `clk50` 83.689, `clk67` 119.303 and `hclk` 85.778 MHz, 14,200 flip-flops against the previous 13,673 and block RAM unchanged at 148, every tap verified in the netlist as a distinct `DFFRE` with no undriven bits before the load. On pages 0 and 1 it reproduced the same fifteen correct fetches. Page 2, an eight-entry ring of completed CPU writes into `0x04000000` to `0x04FFFFFF` with VRAM, palette and OAM excluded so the fill loops cannot bury the answer, shows the `DISPCNT<=0x0000` store arriving as `0x04000000 <= 0x00000000 be=0011`. Page 3 carries the GPU drawer's own `DISPCNT` registers beside sticky bits, and reads `forced_blank=1`, `BG0` to `BG3` all set and `BLDCNT` none, stable across every settled frame, which reproduces BRD-022's register reading independently and shows that reading was not an instrument artefact. What page 3 does not show is the second write: the sticky `DISPCNT<=0x0403` bit never sets in any frame of three spanning about four seconds, so the cartridge's final `strh` is never reached or never executes, while forced blank remains set and the picture stays solid white. One entry of the ring carries `0x04000000` with `ram_wdata=0xFFE0FFE0` and `be=0011`, a halfword store replicated across both bus halves as the ARM7TDMI does; `0xFFE0` is the colour the cartridge writes to VRAM for its failure columns and `0xFFE0` in `DISPCNT` sets exactly the forced-blank and BG0-BG3 bits observed in the register, so a VRAM store reaching IO space would explain both symptoms from one cause. That is recorded as a lead and not a finding, because it rests on one ring entry with no established provenance and the DMA and sound writes appearing beside it are not accounted for. The new decoder `tools/decode_fetchtrace.py` was written before any capture was read, as entry 25 required, and it immediately earned that discipline by producing a wrong answer of its own: it reassembled `ram_addr[27:24]` at bit 22 instead of bit 24 and turned the `DISPCNT` write into a plausible `0x01000000`, which was caught because the address is impossible for the instruction being fetched and because a synthetic frame rendered from known words then disagreed with the decode. Two further instrument limits are recorded rather than rounded off: the ring's `io_n` counter is three bits, so the entry count reads modulo eight and this build reports `7 entries written, wrapped` rather than a total, and the status page's counters are `clk16` registers read combinationally into the `clk50` renderer with no synchroniser, so the first frame after a page change tears and showed `trace 0 of 16` beside a settled `ring 3`; every later frame agreed and the torn one was discarded. The clock-plane gate again refuses to certify `clk16`, which sits on six `*/TOP3` pips this board has never measured (BRD-019), so this result is attributable to the design only with that caveat stated. Two records were added, BRD-023 for the fetch result and TCL-019 for the page-classification and tearing rules, and the machine was left running `build/io_s3` with `test_logo.gba` loaded, white and stable, for the handoff. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 25 and the existing reference records were not rewritten, confirmed the two new records carry unique ids and the canonical field order, and validated this entry as entry 26 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-six against the 100-entry limit.

#### Next Steps:

Confirm or kill the misrouting lead, because it is the only mechanism on the table that explains both the stuck `DISPCNT` and the white screen from one cause, and the current ring cannot see it: the ring keeps the latest eight IO writes and a stray VRAM store appears in it only if it is one of the last eight things the CPU did, which is why one entry carries `0xFFE0FFE0` and nothing establishes when or why. The next build should replace the three-bit `io_n` with a full wrap counter so the write total is known rather than modulo eight, add a sticky bit for a VRAM-region store seen carrying `0xFFE0` or a `0x0400xxxx` address, and add a small ring of the low address bits of the last VRAM stores, so the question becomes whether the cartridge's fill loop ever addresses outside `0x06000000` rather than whether one ring entry looks odd. If a VRAM store is shown carrying an IO address, the fault is in the address path between the CPU and `gba_memory` and the suspect is the `strh` address decode rather than anything in the GPU; if no VRAM store ever misaddresses, the misrouting lead dies and the alternative is that the CPU wedges before the final `strh`, in which case the next instrument is the tail of the cartridge's own execution rather than its head, and the cheapest form is a sticky counter of completed cartridge fetches drawn beside the existing page, since the head trace already proves the first sixteen and the question would become whether the count keeps rising after them. Note that the fill loop writes 38,400 halfwords and the blink loop never terminates, so the ring's exclusion of VRAM is what keeps the two IO writes visible and any new instrument must preserve that property. Do not re-test the fetch path, the BIOS handover, the SDRAM, the raster or the clocks; all five are measured. Do not draw a conclusion from the first frame after a page change, and classify every capture by its page strips before reading a row (TCL-019). One gap is left open on purpose: only the `TINYGBA_FETCHTRACE` configuration was built this cycle, so the default and production configurations have not been re-elaborated since `tr_sel` widened from six bits to seven, and a default-configuration synthesis is the control to run before the next instrument is trusted. Keep `build/fix_ov_s1` as the uninstrumented boot image and do not remove `setundef -zero -init` from the build. The `clk16` clock-plane question is still open and still bounds how any hardware result here may be worded.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gba2hdmi.sv
- tools/decode_fetchtrace.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: NOT RUN

---
## 27 COMMIT Unreleased 2026-11-07T14:44:20-07:00

#### Coming From:

Unreleased c24b10b

#### Purpose:

Find what the corrected MMIO ring says the cartridge actually does with its stores, after entry 26 read a ring whose word packing was wrong, and settle whether the fault lies in the memory path or past it.

#### Outcome:

The memory and IO paths are exonerated and the fault is past everything the instrument can see, but reaching that required finding three more defects in the instrument itself and one in my own reasoning. The first defect was in the packing: the ring concatenated 108 bits into a `+:` 128-bit slice, so Verilog zero-extended it, every field shifted down by 20 bits, and every word decoded as a slice across two fields. Entry 26's claim that the cartridge wrote `0xFFE0` into `DISPCNT` came from that garbage and is withdrawn. The first repair was 144 bits into the same 128-bit slice, which truncates instead, and was caught by recomputing the widths before the build finished rather than by a tool. The second defect was the entry stride: the write side indexed `{mm_n, 6'd0}`, which is `mm_n * 64`, while the read side used `{tr_ent, 7'd0}`, which is `ent * 128`, so every odd entry was half-overwritten by its successor and the ring decoded as a blend of two writes. The marker caught that one, which is what it was added for. The third was a decode error of mine: a concatenation packs its leftmost term into the most significant bits, so word 0 of the entry is the rightmost source term, and I had read the words in source order, inverting every field. Three of these are now enforced by mechanism rather than by care. `tools/check_ring_width.py` counts every concatenation against its `+:` slice width and every `{name, K'd0}` index against its slice size as build step `0b`, refuses to pass on a symbol it cannot resolve rather than guessing, exits 2 when it matched no packings so a gate that checks nothing cannot report success, and was mutation-tested both ways -- four stray bits gives `concatenation is 132 bits, slice is 128 bits` and a one-bit stride slip gives `index {mm_n, 6'd0} strides by 64 but the slice is 128 bits`. The RTL carries a `0xA5C3` marker in the spare 16 bits of word 0 so a misaligned packing is detectable in the data, and the decoder raises on a missing marker or on a ring entry whose CPU address is outside IO space, which the latch condition guarantees cannot happen. The build was also trimmed: the 2,048-bit boot trace moved behind its own `TINYGBA_BOOTTRACE` define because it answered its question in BRD-023 and cost 2,064 registers, taking the configuration from 14,851 flip-flops to 12,744. That paid off immediately in place and route -- synthesis fell from 17 minutes to 11, and `build/gx_s4` passed every gate with no multicycle relaxation at all for the first time in this project, `clk16` 19.145, `clk50` 85.056, `clk67` 133.476 and `hclk` 93.694 MHz with zero hold violations and `clk67` on both measured-good spines. Of four seeds, two passed both gates and two were refused, one by the clock-plane gate for `clk67` on general routing and one by a hard `hclk5` to OSER10 `FCLK` route abort, which is recorded as BRD-024. On the board, `build/gx_s4` (`.fs` SHA-256 `ad3bc68d8635f54a6743b9f87b21eb17fa6655b8b07da691a00305e6dc9c227f`) and `build/gx_s2` (`9c1655b45662d7725b1f0871f827d4bbc51e2b916dbecd1fa2709bf401c760bf`) were both deployable, and `gx_s4` was flashed. With the ring correct, all eight slots carry the marker and every entry reads `same cycle`, and the cartridge's IO writes are all correct -- DISPSTAT at `IO+0x084`, the window registers at `0xA0` to `0xAC`, and `DISPCNT <= 0` at slot 3. Super Mario Advance was then run and reaches 84 cartridge instruction fetches before issuing `WAITCNT <= 0x40144014` and a DMA3 transfer from `0x080000FC` to `0x03001190` with `DMA3CNT <= 0x85001F00`, which is the game copying itself into IWRAM and executing from there; an earlier reading in this cycle that called that a freeze was wrong, because a counter of cartridge fetches cannot see IWRAM execution and a frozen counter is not a hang. Four purpose-built cartridges then measured the paths in isolation without a single FPGA rebuild, which was the point of building them: `litprobe` loaded three literals in a known pool order and wrote them to four registers, all correct, which refuted the hypothesis that the CPU computes a PC-relative literal address one word early; `threecase` confirmed literals load correctly with nothing preceding them, after a cartridge read and after an IO read; `shiftpool` loaded three adjacent pool words with no shift; and `repread` read one cartridge address eight times consecutively, all eight correct. Against all that, two cartridges reported the opposite -- `readf8` read `0x080000F8` correctly as data and returned zero for a literal load targeting the same address, reproduced across frames and reloads -- and no variable was found that separates those two from the three that pass. That contradiction is recorded as BRD-026 with lead status and is explicitly not a finding, because the likeliest explanation is a defect in those two test cartridges: both place a literal where the code tail also sits, and every attempt to force the pool to a chosen address was relocated by the assembler. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 26 and the existing reference records were not rewritten, confirmed the four new records carry unique ids and the canonical field order, and validated this entry as entry 27 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-seven against the 100-entry limit.

#### Next Steps:

Resolve the `0x080000F8` contradiction before drawing any further conclusion about the machine, because it is the only measurement this cycle that disagrees with the others and it is recorded as a lead rather than a finding: build one more cartridge that places a literal at exactly `0x080000F8` with no code within several words of it, verify the assembled address by disassembly before loading rather than trusting the source, and read it through the ring. If it returns the constant, the two failing cartridges were defective and BRD-026 should be withdrawn; if it returns zero, the machine has an address-dependent read fault that every other test in this cycle missed, and the instrument to find it is the Verilator model with a watchpoint on `rom_addr`, not another ring. Then take up the display question with the paths the ring has now cleared: cartridge fetches, data reads, literal loads, IO decode, DMA and WAITCNT are all measured correct, so the fault is in whatever the cartridge does immediately before enabling the display, and the instrument that can see it does not exist yet -- the ring only records writes to `0x04000000` to `0x04FFFFFF` and the counter only counts cartridge fetches, which goes blind the moment a game like Super Mario Advance copies itself to IWRAM. Add a sticky record of the last few IWRAM instruction fetches alongside the existing counter, since `0x03000000` execution is where the retail cartridge actually goes, and check whether a thumb-mode immediate-offset store computes a different address from the same store reached by a different route. Do not re-test the memory path, the fetch path, the literal path, the IO decode, the clock plan or the SDRAM; all six are measured and recorded. Do not decode a capture without the marker present in all eight slots, and do not trust a ring reading from any build before `build/gx_s4`, because every one of them carries at least one of the three packing defects above. Keep the packing-width gate in the build: it found nothing on the corrected tree but it is the only thing standing between a silent width slip and another confident wrong reading, and it now checks strides as well as widths. One instrument limit remains from entry 26 and is still open: the status page's `clk16` counters are read combinationally into the `clk50` renderer, so the first frame after a page change tears and must be discarded.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- fpga/gba/src/gba2hdmi.sv
- tools/build_tinygba.sh
- tools/check_ring_width.py
- tools/decode_fetchtrace.py
- tools/make_literal_probe_rom.py
- tools/make_mask_report_rom.py
- tools/make_repeat_read_rom.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---
## 28 COMMIT Unreleased 2026-11-07T14:53:40-07:00

#### Coming From:

Unreleased 8524905

#### Purpose:

Settle the one measurement from entry 27 that disagreed with the others, so the cycle can close with a consistent evidence base instead of an open contradiction.

#### Outcome:

The contradiction was in the instrument and is withdrawn: the literal-load path is correct at `0x080000F8`, and BRD-026's lead does not describe the machine. Entry 27 left two cartridges returning zero for a literal load targeting that address while a data read of it returned the correct constant, and named the isolation test that would settle it. That test is `tools/make_addr_probe_rom.py`, and it avoids the failure mode which spoiled the earlier pair: it uses explicit `ldr Rd,[pc,#imm]` offsets rather than `ldr Rd,=value`, so no literal pool is emitted and the assembler cannot relocate the target, and it puts three words of distance between the last instruction at `0x080000EC` and the first target at `0x080000F8`. The build script decodes each instruction back out of the finished image and refuses to write a cartridge unless every load targets the address and constant it claims, which matters because the earlier failures were exactly a case of an instrument not doing what its source said; the result was then confirmed independently with `objdump`, which showed the three loads at `0x080000CC`, `0x080000D0` and `0x080000D4` reaching `0x080000F8`, `0x08000104` and `0x08000110`. On the board all three returned their constants, `0x11112222`, `0x33334444` and `0x55556666`, each to its own ring slot, and a ten-second capture across all four pages showed no variation in any of them. So BRD-026 is superseded by BRD-027 and must not be cited as evidence of an address-dependent read fault. With that closed, every path this cycle can measure now agrees: cartridge instruction fetches are byte-exact, cartridge data reads are correct including repeat and adjacent reads, literal loads are correct at every address tested, IO register decode separates DISPCNT, DISPSTAT, VCOUNT and BLDCNT, and DMA and WAITCNT are observed working on Super Mario Advance. No cartridge completes its display-enable, so the fault lies past everything the MMIO ring can observe. Two operational faults in my own procedure cost time this cycle and are recorded as TCL-021. The first is that a power cycle clears the bitstream: after the console was switched off for a mode change and back on, a cartridge was loaded without a reflash and three capture cycles were spent examining a design that was not running, with an empty ring and all sixteen frames on page 0 -- which is impossible in a running design, because the page advances every 0.67 s, and that inconsistency was the only thing that revealed it. `tools/cap_tang.sh` flashes and captures together for exactly this reason, and calling the loader directly on a board of unknown configuration state is the mistake. The second is smaller and was caught by reading the ring rather than the screen: an early attempt to read the `addrprobe` results filtered on the three expected IO offsets and found nothing, because the ring holds the newest eight IO writes and the BIOS had already pushed the probe's writes out of it; the fix was to dump every slot rather than the ones the test expected, which is the same mistake as assuming a page rather than reading the page strip. Nothing was deployed as an artifact of this cycle: `build/gx_s4` was already the deployed image from entry 27 and was reflashed unchanged, `.fs` SHA-256 `ad3bc68d8635f54a6743b9f87b21eb17fa6655b8b07da691a00305e6dc9c227f`. The board was left running it with `build/test/addrprobe.gba` loaded and was then returned to two-wire mode by the operator. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 27 and the existing reference records were not rewritten, confirmed the two new records carry unique ids and the canonical field order, and validated this entry as entry 28 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-eight against the 100-entry limit.

#### Next Steps:

Build the instrument that can see past the ring, because the ring has now been checked against every path it can observe and all of them are correct. The specific gap is IWRAM execution: the ring records only writes into `0x04000000` to `0x04FFFFFF` and the counter counts only cartridge instruction fetches, so both go blind the moment a cartridge copies itself to `0x03000000` and runs from there, which is what Super Mario Advance does after its DMA3 transfer and is where a retail game spends most of its time. The next readout should latch the first few completed instruction fetches with `ram_addr[27:24] == 3` alongside the existing cartridge counter, and a sticky record of whether `0x03000000` execution was ever seen at all, so the question becomes whether a cartridge reaches its own IWRAM code and what it fetches there. Before spending a build, run the same cartridges in the Verilator model with a watchpoint on `ram_addr` and on `DISPCNT`, because the model can single-step and the board cannot; its known limit must travel with any result, since it substitutes an array for the SDRAM controller and, with this cartridge, does not boot it at all. Do not re-test the memory path, the fetch path, the literal path, the IO decode, the clock plan or the SDRAM, all six of which are measured and recorded. Do not cite BRD-026. Do not decode a capture without the marker present in every slot, and do not read a capture from a board whose configuration state is unknown -- reflash first, and prefer `tools/cap_tang.sh`, which does both. One item remains open from earlier cycles and is unaffected by this one: `clk16` still reaches its sinks on pips this board has never measured (BRD-019), so every hardware result remains contingent on that caveat until a build lands on a measured-good spine.

#### Files Modified:

- tools/make_addr_probe_rom.py

#### Status:

- Build: N/A
- Deployment: PASS
- User Test: FAIL

---
## 29 COMMIT Unreleased 2026-11-07T21:16:05-07:00

#### Coming From:

Unreleased fffc072

#### Purpose:

Make the real SDRAM controller usable in the simulation, so the memory path that runs on the board can be debugged in a model that can be single-stepped instead of only through a bitstream and a capture card.

#### Outcome:

The real-controller model now boots the cartridge, and reaching that required finding a defect in the model itself rather than in the design. The starting point was the previous cycle's conclusion that the real controller reproduced the board's failure; that conclusion was wrong and is withdrawn. What the model was actually doing was returning zero for every cartridge read. The cause is in `fpga/gba/diag/sdram_model.v`: the read path has a shift register `rd_pipe` with a companion `rd_valid_pipe`, and the tri-state enable was computed from `rd_valid_pipe[cas_latency-1]` while the data register `dq_out` was loaded from `rd_pipe[cas_latency-1]` in a later `if` that tested the same index. The two are written a clock apart relative to the shift, so the bus was enabled one cycle before its data arrived and presented the previous word. The controller samples DQ in its own DAT slot, so it captured a stale or high-impedance bus and `cpu_rdata` came out as a clean zero rather than as an error. The write path was never in doubt: the die dump showed `cart[0..3] = 002e ea00 ff24 51ae`, exactly the image's first eight bytes, so the loader, the part and the controller's write sequencing were all correct and only the read capture was wrong. Both the enable and the data now use stage 0, and the result is categorical: all 112 cartridge data reads in a run match the ROM file under byte, halfword and word interpretation, and the model boots the cartridge with 18,375,892 cartridge fetch cycles and `fetch regions` `0x00000040`. The investigation also cost two of my own errors worth recording. I first claimed the real-controller build reproduced the board's stall, which it did not -- the frames I read were a machine holding an unreadable cartridge; and before that I read a run of 900 million steps as evidence of a stall when the same ROM under this controller needs about 3000 million to reach the cartridge, which is the third time this project has drawn a conclusion from a simulation that had not run long enough and the reason BRD-028 records the budget with the result. On the board the fault is unchanged and now reproduced in the model: the BIOS intro plays, the screen goes black, `DISPCNT` receives the cartridge's first `0x0000` store and then only the BIOS's own `0x1002`, and no cartridge read ever reaches the self-checks at `0x08000400`, `0x08000800` or `0x08000C00`, while the same ROM under `sdram_sim` boots to green. Nothing was deployed and the board was not touched: every change in this cycle is simulation-only, and a bitstream built from this tree would be identical to `build/gx_s4` from entry 27, because `sdram_model.v` is never compiled by `tools/build_tinygba.sh` and the harness is not part of the design. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 28 and the existing reference records were not rewritten, confirmed the two new records carry unique ids and the canonical field order, and validated this entry as entry 29 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of twenty-nine against the 100-entry limit.

#### Next Steps:

Single-step the model from the cartridge's literal load to its first self-check read, because that is now the whole remaining distance and it is the only place the two models differ. The specific comparison is the array build, which boots green, against the real-controller build, which stalls: the cartridge loads `0x08000C00` from the pool at `0x080002C4`, and the next thing it should do is read `0x08000400`, and that read never appears in the trace. Run both under the same step budget with a breakpoint on `ram_addr == 0x08000400` and record what the CPU is fetching and what `cpu_en` and `ram_cen` do in the cycles around it, since the difference between the two builds is the controller's acknowledgement timing and not the data. Do not re-test the write path, the die contents or the literal pool: all three are measured correct and recorded in TCL-022 and BRD-028. Do not conclude anything from a run shorter than 3000 million steps with this ROM under the real controller; that limit has now cost three separate wrong readings in this project and is the reason the budget is recorded beside every result. One limit of the model must travel with anything found in it: `sdram_model.v` is a model of a part and not the part, so a fault found here is evidence about the controller's logic and sequencing and not about this board's signal integrity or clock skew, and the board remains the only instrument for those. The board itself is in two-wire mode with `build/gx_s4` and `build/test/addrprobe.gba` loaded from entry 27, and no change in this cycle warrants flashing it.

#### Files Modified:

- fpga/gba/diag/sdram_model.v
- tools/sim/sim_main.cpp

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---
## 30 COMMIT Unreleased 2026-11-08T00:02:15-07:00

#### Coming From:

Unreleased f6574f3

#### Purpose:

Build the readout that can see a cartridge executing from IWRAM, because every instrument this project has used so far goes blind at the point a retail game leaves the cartridge, and find out whether Super Mario Advance reaches its own code at all.

#### Outcome:

The board answers that a retail cartridge writes and reads IWRAM in volume and never executes a single instruction there, which is a narrower and more useful result than anything the display-side instruments had produced. The readout is `build/iw_s5` (`.fs` SHA-256 `b4f5a0800dd1520ae2576e5a1b9edfd2c8c5a7543c67201832a0f6c9096da695`), built at seed 5 with the real controller taps and the official BIOS, passing both gates at `clk16` 18.980, `clk50` 85.727, `clk67` 32.864 under the documented GBATang four-cycle allowance with a 30.43 ns worst path against a 59.70 ns budget, and `hclk` 79.327 MHz, zero hold violations, `clk67` on both measured-good spines. Page 1 gained entry 4: a sticky IWRAM-execution bit with the last IWRAM fetch address, plus full-width counters of IWRAM instruction fetches, IWRAM data writes and IWRAM data reads, all gated on `rom_addr[27:24] == 4'h3` and `ram_addr[27:24] == 4'h3` respectively. The page-1 validity mask moved from `0x0F00` to `0x1F00` because it had been setting bits 8 to 11 only, which would have left entry 4's validity strip dark and made a live entry look absent -- caught before the build by reading the mask arithmetic rather than the picture. All five new registers were confirmed live in the synthesised netlist before flashing: `iw_fetch` 32 bits, `iw_wr` and `iw_rd` 24 each, `s_iw` 1, and `last_iw_addr` 27 with bit 0 folded, which is correct because ARM instruction addresses are word-aligned. On the board, with Super Mario Advance loaded, every page-1 frame over a 16-second capture agrees: IWRAM execution seen 0, IWRAM instruction fetches 0, IWRAM data writes 513204, IWRAM data reads 669827, cartridge fetches 84, halt 1. So the DMA transfers land, IWRAM is written and read heavily, and the CPU never fetches from `0x03000000` even once. This supersedes entry 27's statement that Super Mario Advance copies itself into IWRAM and executes from there: that was inferred from a frozen cartridge-fetch counter and was wrong, though the count of 84 it reported is reproduced exactly. The earlier reading treated the frozen counter as consistent with a game running elsewhere; the direct measurement shows the game never gets anywhere. Of four seeds staged for place and route, seed 5 finished first and cleanly, and seeds 2, 3 and 4 were still routing when this cycle closed at the operator's request for a handoff. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 29 and the existing reference records were not rewritten, confirmed the new record carries a unique id and the canonical field order, and validated this entry as entry 30 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of thirty against the 100-entry limit.

#### Next Steps:

Find why control never transfers into IWRAM, because that is now the single question and it is upstream of everything the display-side instruments were chasing. The data path is proved: 513,204 writes and 669,827 reads mean the DMA lands and the region works, so the fault is in the handover -- the DMA's completion signalling, the branch, or an exception taken at the transfer. Take it to the model, which is the right instrument now: `build/sim_v` or `build/sim_fix2` with `-DTINYGBA_SDRAM_RTL` boots the cartridge and can be single-stepped, and the comparison that matters is Super Mario Advance under the array build, which is the known-good reference, against the same ROM under the real controller. Watch `ram_addr`, `rom_addr`, `cpu_en` and `halt` across the DMA3 completion and record the first instruction the CPU fetches after `cart_fetch` stops rising. The `DISPCNTWRITE` trace already in `tools/sim/sim_main.cpp` is the wrong instrument for this and should be replaced rather than extended. Two measurement traps cost this project real time and must not be repeated: a run shorter than 3000 million steps with this ROM under the real controller reports no cartridge fetches and means nothing, and a frozen counter of cartridge fetches says nothing about IWRAM execution, which is the whole reason this entry exists. Do not re-test the memory path, the fetch path, the literal path, the IO decode, the DMA transfer itself, the clock plan or the SDRAM; all are measured. Do not attempt a fix on the board before the model explains the handover; the board is the only instrument for signal integrity and clock skew, and neither is implicated yet. One standing caveat is unaffected: `clk16` still reaches its sinks on pips this board has never measured (BRD-019), so hardware results remain attributable to the design only with that stated.

#### Files Modified:

- fpga/gba/src/gbatang_top.sv
- tools/decode_fetchtrace.py

#### Status:

- Build: PASS
- Deployment: PASS
- User Test: FAIL

---

## 31 COMMIT Unreleased 2026-11-08T09:29:57-07:00

#### Coming From:

Unreleased 2b0e20d

#### Purpose:

Reproduce the board's blank display on demand under the real SDRAM controller and localise the cartridge read-path fault that the array model does not share.

#### Outcome:

The failure now reproduces on demand in the model and is bounded to a single cycle, but its mechanism is not established and no fix was shipped. Two builds of the same tree, same ROM and same 3000-million-step budget differ categorically: with the behavioural array, `build/test/test_logo.gba` renders its pass screen as two colours at a mean of 85, and RetroRegen reaches its menu at 3,420 colours; with `-DTINYGBA_SDRAM_RTL`, both cartridges render one colour for all 889 frames, `test_logo` white at a mean of 252, and RetroRegen white at a mean of 252 against 139,636,806 cartridge fetch cycles in the array build. The controller build reports 18,375,892 cartridge fetch cycles, the identical figure BRD-028 records from the deployed board image, so the model and the board are the same fault. A cycle-level contract trace at the read of the literal-pool word `0x080002B0` records the only difference found: at the cycle the acknowledgement is visible, the array presents `sdram_rdata` `08000400` while the controller presents `e1540400`, and one cycle later both builds present `08000400` in `sdram_rdata` and `ram_rdata` with the same next address, so the divergence is confined to the ack cycle and does not survive its own trace. That convergence is why the mechanism is recorded as a lead rather than a finding, and why the patch the evidence first suggested was reverted rather than shipped: delaying the controller's 32-bit read acknowledgement until the high halfword is collected does make `sdram_rdata` correct at the ack, but `ram_rdata` remained stale because `gba_memory` only sources `sdram_rdata` when the FSM is in `MAIN`, so the frames changed from white to black and the cartridge fetch count rose from 18,375,892 to 26,185,631, which is a different broken behaviour and not progress. Reading the source also confirmed that entry 14's deliberately deferred DMA defect is still present, since the DMA path still enters `REQ1_START` and `dma_done` is gated on the single-cycle `sdram_ready` pulse, but `test_logo` issues no DMA, so it cannot be this blocker. One instrument defect was found and fixed: `tools/sim/sim_main.cpp` capped the `CARTREAD` log at 200 entries, so a truncated log read as a request stream that stopped, and the cap is now 4000. Three of this session's own analytical failures are worth carrying forward because all three were confident conclusions drawn from an instrument that had not been validated: a stale-read claim was withdrawn on the strength of a 1500-million-step run that never reached the literal pool and then reinstated when the 3000-million-step run did, a capped log was read as a stall, and a contract trace stalled because this build's redirected stdout is block-buffered, which was fixed by writing to a file with `$fflush`. Nothing was deployed and the Tang was not connected to; it is in two-wire mode and enumerates as `ffff:5454 TinyTang CDC`. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 30 and the existing reference records were not rewritten, confirmed the three new records carry unique ids and the canonical field order, and validated this entry as entry 31 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of thirty-one against the 100-entry limit.

#### Next Steps:

Trace the assembly path rather than the controller handoff, because the contract trace shows the two builds converge one cycle after the acknowledgement and therefore cannot explain a permanent difference from the ack cycle alone: instrument `double_req`, `rom_rdata_new` and the `rom_data`/`ram_data` output mux across a concurrent rom-and-ram access in both builds, since that is the logic that differs between them and the only place a wrong word could be latched into the CPU without appearing at the raw controller interface. Do not re-run the array-versus-controller A/B or re-derive the reproduction; it is measured and recorded. Do not patch `sdram_gba` or `gba_memory` again until a trace survives its own test, because the one attempted patch produced a different failure (white frames becoming black and fetch cycles rising to 26,185,631) while its own probe showed only a partial correction, and it was reverted for that reason. Every simulation in this cycle that carried weight ran to 3000 million steps; a shorter run does not reach the cartridge handover for this ROM under this controller and has already produced two wrong conclusions in this project. When the assembly path is settled, require the array-equivalent result before anything else: two colours at a mean of 85 for `test_logo` and 3,420 colours for the RetroRegen menu. Only then build a bitstream, and note that the board is in two-wire mode and must be returned to one-wire before it can be flashed. The DMA `REQ1_START` defect remains open as its own change and is not on this path, and every hardware result remains attributable to the design only under BRD-019's unmeasured-`clk16`-pip caveat.

#### Files Modified:

- tools/sim/sim_main.cpp

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 32 COMMIT Unreleased 2026-11-08T11:59:55-07:00

#### Coming From:

Unreleased 654017e

#### Purpose:

Replace the cartridge-read instrument that produced three contradictory conclusions with one calibrated against the ROM, and settle whether the controller really returns the wrong word.

#### Outcome:

The controller really does return the wrong word, and the instrument that now says so is validated against the ROM rather than against an assumption about where the CPU samples. The previous harness printed `ram_rdata` on the `cpu_en` edge and asserted in a comment that this was the value the CPU received, which was never checked; that single unexamined assumption is what let a stale-read lead be stated, withdrawn and reinstated across three cycles. `tools/sim/sim_main.cpp` now logs the address with both candidate words, the one visible on the `cpu_en` edge and the one visible on the previous edge, and `tools/check_cartread.py` reads the ROM image, translates the GBA address to an image offset by subtracting `0x08000000`, masks each word by the byte enables and scores both columns. On the array build, which produces a working machine, `data_now` reproduces 184 of 184 captured reads exactly and `data_prev` reproduces 11, so the pairing is established by evidence and the same column can be applied to the controller with confidence. On the controller build, 112 of 4,000 captured reads match the ROM and 3,888 do not, and the mismatches are a consistent one-word lag: `0x080002B0` returns `e154e154` where the image holds `08000400`, `0x080002B4` returns `08000400`, `0x080002B8` returns `a5a50001` and so on through the literal pool. The runs were 3000 million steps each and the frames say the same thing: the array draws two colours at a mean of 83 to 85, which is its pass screen, and the controller draws one colour at a mean of 0 for all 889 frames, with 18,375,892 cartridge fetch cycles against the board's identical figure. The root cause is not established and no fix ships. Two attempts were made and both were reverted unshipped: delaying the controller's 32-bit read acknowledgement until the high halfword is collected made `sdram_rdata` correct at the acknowledgement while `ram_rdata` stayed stale because the output mux only sources the bus in `MAIN`, and adding that mux change as well still left the frames black and the reads one word stale, so neither moved the symptom and neither is retained. An assembly-path trace of `double_req`, `rom_rdata_new`, both raw SDRAM ports and both output ports showed the two builds delivering the identical correct word for the self-check read of `0x08000400` within their own windows, which is why the remaining divergence is now recorded as being in the latch or ordering of the double-request path rather than in the controller's data, and why no third patch was attempted on inference. One further instrument defect was fixed: `tools/check_cartread.py` recognises that a capture read while a run is still writing can end mid-line and skips the incomplete tail rather than aborting, which is the hazard TCL-023 records. Nothing was deployed and the Tang was not connected to; it remains in two-wire mode. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 31 and the existing reference records were not rewritten, confirmed the two new records carry unique ids and the canonical field order, and validated this entry as entry 32 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of thirty-two against the 100-entry limit.

#### Next Steps:

Find where the cartridge word is latched rather than whether it is wrong, because that question is now answered and quantified: instrument the double-request path's latch and ordering in both builds on the same address, tracing when `rom_rdata_new` is written relative to the acknowledgement and which cycle the output mux is sampled by the consumer, since the assembly trace showed both builds holding the right word at the self-check read and yet only one of them executes correctly. Do not re-derive the staleness itself and do not re-run the array-versus-controller A/B; both are measured, calibrated and recorded. Do not patch `sdram_gba` or `gba_memory` again until a trace explains why the two reverted attempts left the symptom unchanged, because both were motivated by a correct observation of the lag and both failed to move it, which means the lag is being absorbed somewhere not yet instrumented. Keep using `tools/check_cartread.py` for every cartridge-read claim from now on: it calibrates the sampling column against a build whose machine works and then judges the failing build with the same column, and a claim that has not been through it is the class of claim that cost this project three cycles. Every simulation that carries weight must run to 3000 million steps, since shorter runs do not reach the cartridge handover for this ROM under this controller. When the latch is settled, require the array-equivalent result before anything else: two colours at a mean of 85 for `test_logo` and the RetroRegen menu, and only then build a bitstream. The board is in two-wire mode and must be returned to one-wire before it can be flashed, the DMA `REQ1_START` defect remains open as its own change and is not on this path, and every hardware result remains attributable to the design only under BRD-019's unmeasured-`clk16`-pip caveat.

#### Files Modified:

- tools/sim/sim_main.cpp
- tools/check_cartread.py

#### Status:

- Build: PASS
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 33 COMMIT Unreleased 2026-11-08T12:27:26-07:00

#### Coming From:

Unreleased 295b769

#### Purpose:

Compare this port against the upstream GBATang checkout to find how upstream crosses the memory boundary this project is stuck at, and correct the record where that comparison showed a recorded claim to be wrong.

#### Outcome:

The comparison withdraws a claim this project has been resting on, and it is a claim I made rather than one the log already contained: the model does not reproduce the board's fault. Entries 31 and 32 and records BRD-030 and BRD-032 assert that the controller build's 18,375,892 cartridge fetch cycles are the same figure as the deployed board image, and they are not. BRD-028 is a simulation record; the board record is BRD-029, which measures 84 cartridge fetches on Super Mario Advance. The model therefore gets far further than the board, executing eighteen million cartridge fetches where the board executes eighty-four, so the Verilator reproduction is an instrument for the controller's logic and not a reproduction of the board's failure, and every conclusion that leaned on that equivalence has to be re-read accordingly. The upstream checkout at `/run/media/vash/GIT/tangcore/gbatang` is confirmed at the pinned `77fd0714a426ada76aee612f1192c704e89762e4`. Three structural differences were found in it. First, upstream never compiles `sdram_gba.v` under Verilator at all: `gbatang_top.sv` instantiates the real controller behind `ifndef VERILATOR` and the behavioural array behind `else`, so nand2mario's simulation has never crossed this boundary and the real controller has only ever run on vendor-built Gowin hardware; entry 14's changes exist because this port chose to compile the controller in simulation, which upstream deliberately does not. Second, `sdram_gba.v` is upstream's apart from slang-required cosmetic changes and the documented `[31:15]` to `[31:16]` repair, so its acknowledgement timing is upstream's and the port did not diverge there. Third, upstream generates all four GBA clocks from one `pll_33` at 27 MHz with `clk50` on `CLKOUT0`, `clk16` on `CLKOUT1`, `clk67` on `CLKOUT2` and `clk67_p` on `CLKOUT3`, while this port moved `clk67` to `CLKOUT1` and `clk16` to `CLKOUT2` on `pll16` and added `CLOCK_LOC "clk67" BUFG`, a reordering forced by apicula modelling plane pips only for `CLKOUT0` and `CLKOUT2` and not measured against upstream's assignment on hardware. One suspect was tested and eliminated rather than left as a theory: reverting the two entry-14 changes in `gba_memory.sv` to upstream's exact semantics, `REQ2_START: state <= REQ2_WAIT` and `cpu_en = state == REQ2_BRAM | state == REQ2_WAIT & sdram_ready`, made the design worse rather than better, giving a white field for all 889 frames with zero cartridge reads, so that change is load-bearing in this port and is not the cause. A fourth difference is recorded for the next cycle rather than acted on: upstream's `build.tcl` sets `GW5AST-LV138PG484AC1/I0` with `-device_version B` on every 138K board, while this port targets device revision C. Nothing was deployed and the Tang was not connected to, at the operator's instruction. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 32 and the existing reference records were not rewritten, confirmed the two new records carry unique ids and the canonical field order, and validated this entry as entry 33 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of thirty-three against the 100-entry limit.

#### Next Steps:

Test upstream's exact clock assignment rather than continuing to reason about it, because it is the one structural difference from upstream that sits on this boundary and that upstream validated on hardware: move `clk16` back to `CLKOUT1` and `clk67` back to `CLKOUT2` on the PLL, drop `CLOCK_LOC "clk67" BUFG`, and see whether the cartridge reads come back correct, noting that the vendor flow reaches the plane from `CLKOUT1` through the centre-bridge muxes TCL-018 describes and that this will therefore build only if the clock-plane gate is satisfied by those pips or the gate is run non-strict. Treat a simulation-only run as insufficient for this question, because the harness generates all clocks from one counter and so cannot show a phase relationship that the real PLL output assignment decides; if the simulation result is unchanged, that is evidence the difference is not phase and the test must move to a bitstream and the board. Correct the record first in any later cycle that cites the reproduction: BRD-030 and BRD-032 both overstate it, and BRD-028's 18,375,892 is a model figure with no board counterpart, the board's being BRD-029's 84. Do not re-test the entry-14 revert, which is measured and eliminated. Do not patch `sdram_gba` or `gba_memory` again without a trace that explains why the three reverted attempts left the symptom unchanged. Keep every cartridge-read claim going through `tools/check_cartread.py`, keep simulations that carry weight at 3000 million steps, and note that the board is in two-wire mode and must be returned to one-wire before it can be flashed.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: NOT RUN
- User Test: NOT RUN

---

## 34 COMMIT Unreleased 2026-11-08T13:37:54-07:00

#### Coming From:

Unreleased b984fd8

#### Purpose:

Narrow the cartridge read fault to a single stage by measuring the SDRAM bus itself, after the failure was localised to byte reads of one address.

#### Outcome:

The part, the bus and the model are exonerated, and the corruption is confined to a byte read's collection inside `sdram_gba`. Analysis of the existing 3000-million-step captures by access width showed the defect is narrow: on the array build every width is correct, and on the controller build word, low-halfword and high-halfword reads are all correct while byte reads fail, with 3,881 of 3,888 wrong reads landing on the single address `0x0800009c`. That address is the last word of the Nintendo logo, which the BIOS validates, so the machine is failing its logo check and retrying in a loop rather than executing the cartridge. The first divergence in the read stream is a dropped access rather than a wrong one: the array services `0x0800009d` once and the controller never services it at all. A bus-level trace was then built in `fpga/gba/diag/gba_sdram_rtl.v` with one counter in one clock domain, because two independently started counters in the controller and the model reported a spurious 16-cycle offset. It arms on a READ command to the word holding `0x0800009c` and prints every cycle afterwards. The result is textbook: the READ command appears with `dq=0000`, and exactly two clocks later `dq=d421`, which is the correct halfword for bytes `21 d4`, and it is then held stable for as long as the trace runs. So the part returns the right word at the cycle a CL=2 part should, the controller's collect point falls inside that window, the DQM handling is correct because the controller issues `dqm=00` on reads as the model's own comment claims, and the bus is clean. The corruption therefore happens between the bus and `cpu_rdata`, inside the collection stage, and only for the byte arms: `casez (ds_latch[0])` maps `4'b0001` to `{4{dq_in[7:0]}}`, and the trace earlier this cycle showed the collected byte as `0x75` where the bus was carrying `0x21`, a value that appears nowhere in the cartridge image. Three instrument traps were hit and cost time: a comment beginning with the word the simulator treats as a directive fails elaboration, which entry 10 already records; a tristate operand may not be compared outside the propagation graph, so DQ is now read through a wire and printed rather than compared; and a counter placed in a block that does not tick on every clock produces an offset that looks like a real timing defect. Nothing was deployed and the Tang was not connected to. The core-syntax audit re-read `.ai/core.md` and `.ai/core-syntax.md`, inspected the complete `.ai/` diff, confirmed `.ai/core.md` was not changed, checked that entries 1 to 33 and the existing reference records were not rewritten, confirmed the one new record carries a unique id and the canonical field order, and validated this entry as entry 34 with six canonical sections, a one-sentence Purpose, prose in Outcome and Next Steps, an allowed Status set and a count of thirty-four against the 100-entry limit.

#### Next Steps:

Instrument the byte arm's input rather than the bus, because every other candidate is now excluded by measurement and the remaining question is exactly what `dq_in` holds on the cycle the `4'b0001` arm samples it during a byte read at `0x0800009c`: print `dq_in`, `ds_latch[0]`, `addr_latch[0]` and `cpu_rdata[port[0]]` on the collect edge for that access, on the same bus-level counter, and do it for a byte read in the retry loop rather than the first logo read, since the failure count of 3,881 implies the loop is where the corruption is reproducible. If `dq_in` is correct at the collect edge the fault is in the arm or in what happens to `cpu_rdata` afterwards, and if it is wrong the fault is that the collect edge falls outside the part's driven window for back-to-back reads, which the model withdraws the bus for one cycle when a new READ arrives. Do not re-test the bus, the part, the DQM handling or the word and halfword paths; all are measured and recorded. Do not place counters in blocks that may not tick every clock, and do not compare tristate signals. Keep every cartridge-read claim going through `tools/check_cartread.py`, keep weight-bearing runs at 3000 million steps, and note the board remains in two-wire mode.

#### Files Modified:

None.

#### Status:

- Build: N/A
- Deployment: NOT RUN
- User Test: NOT RUN

---
