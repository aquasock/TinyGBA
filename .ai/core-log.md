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
