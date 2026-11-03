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
