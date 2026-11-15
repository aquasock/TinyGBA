# Third-party code carried in this repository

TinyGBA vendors the upstream sources it builds rather than patching an upstream
checkout, following the same rule TinySNES records: every source the core needs
is in this tree, and no external checkout is involved in a build.

- **GBATang** — `fpga/gba/src/` and the file list in `tools/build_tinygba.sh`
  come from nand2mario's GBATang at commit `77fd0714a426ada76aee612f1192c704e89762e4`
  (https://github.com/nand2mario/gbatang), pinned as a submodule of
  https://github.com/nand2mario/tangcore, GPL-3.0. That project is itself a port
  of the MiSTer GBA core, with the CPU replaced by risclite's ARM9-compatible
  soft core and the memory system rewritten. The vendored tree is upstream's
  `src/` with every deviation marked in place by a `TinyGBA:` comment. That
  marker is the authoritative list and `grep -rn 'TinyGBA:' fpga/gba/src/`
  enumerates it; seventeen files carry one at the time of writing. They fall
  into three groups: forced toolchain accommodations (slang rejecting `$error`,
  undeclared parameters, block-scoped registers), `ifdef`-guarded diagnostics
  that never reach a synthesised build, and fixes for real defects, each with a
  `BRD-` or `TCL-` record behind it. The last group includes the sound channels
  (`gba_sound.v`, `gba_sound_ch1.v`, `ch3`, `ch4`), `gba_memory.sv`,
  `gba_dma_module.sv` and `gbatang_top.sv`.

  **A subset of that tree is not nand2mario's work and is not GPL-3.0.** Sixteen
  files under `fpga/gba/src/` are output of Gowin's IP generator and carry
  `Copyright (C)2014-2024 Gowin Semiconductor Corporation. All rights reserved.`
  in their header, stating no grant of any kind. Nine of them are in the shipped
  build: the six memory wrappers `memory/mem_eeprom.v`, `memory/mem_iwram.v`,
  `gpu/vram_lo.v`, `gpu/vram_hi.v`, `iosys/gowin_dpb_menu.v` and `fb.v`, and the
  three PLL wrappers `pll/pll_12.v`, `pll/pll_27.v`, `pll/pll_33.v`. The other
  seven are not built: six are duplicates held in an unused `plla/` directory and
  `pll/pll_74.v` is superseded by the hand-written `pll/gowin_pll_hdmi.v`. They
  all arrived inside GBATang's GPL-3.0 tree, but a licensor can only license what
  it owns, so GBATang's licence does not reach them and neither does this
  project's. They are carried as build inputs, not as licensed source. Whether
  Gowin's EULA permits redistributing generated output has not been established:
  no Gowin EDA is installed here, no EULA text is in the tree, and this project
  will not assert a permission it has not read. See TCL-065. The `.ipc` and
  `.mod` files beside them are Gowin project descriptors and are never read by the
  build.

  The six memory wrappers are pure primitive instantiations with no logic in
  them -- `mem_eeprom` is four `DPB` cells and a port list -- so they are
  replaceable by this project's own RTL, which is the intended direction. Three
  of the six already carry a generic behavioural counterpart at the same
  instantiation site under `ifdef VERILATOR`: `mem_iwram`, `vram_lo` and
  `vram_hi`. `mem_eeprom`'s equivalent exists only as a commented-out
  `dpram_block` instantiation, and `gowin_dpb_menu` and `fb.v` have none. The PLL
  wrappers are not yet in scope.

- **GBATang's Verilator harness** — `tools/sim/sim_main.cpp` is upstream's
  `verilator/sim_main.cpp` at the same commit, GPL-3.0, carried unmodified. It
  gives the core an SDL window, an FST trace and a WAV-quality audio capture,
  which is the only way this project can ask a question about correctness rather
  than about state. `tools/sim/gowin_cells_sim.v` extracts just `MUX2`, `DFFRE`
  and `DPB` from oss-cad-suite's Gowin cell library with `specify` blocks removed,
  because `memory/mem_eeprom.v` still instantiates those three under `VERILATOR`.
  Both are wired up by `tools/sim/build_gba_sim.sh`, which is this project's own.

- **hdl-util/hdmi** — `fpga/gba/src/hdmi/`, the HDMI transmitter, by Sameer Puri,
  MIT, carried as `fpga/gba/src/hdmi/LICENSE-MIT`. These ten files are **not**
  GBATang's copies: they are TinyTang's (`fpga/desktop/hdmi/`), because
  GBATang's own copies fail to elaborate in slang with the same errors SNESTang's
  did, while TinyTang's carry the open-flow fixes (one assignment in `hdmi.sv`,
  the `frame_counter` increment in `packet_picker.sv`) with their own explanatory
  comments, and have run on this board. This mirrors the swap TinySNES made.

- **TinySNES** — the shape of `tools/build_tinygba.sh`, the clock-placement
  idiom in `fpga/gba/tinygba.cst` and the `create_clock`-only rewrite in
  `fpga/gba/tinygba.sdc` come from TinySNES's `tools/build_tinysnes.sh`,
  `fpga/snes/tinysnes.cst` and `fpga/snes/tinysnes.sdc`. The four `INS_LOC`
  clock sites trace back through TinySNES to TinyNES's `fpga/ae350_soc/ae350_soc.cst`
  and TinyTang's `fpga/desktop/desktop.cst`. `tools/fs_to_bin.py` is TinyNES's
  file, unmodified, via TinySNES.

- **TinyNES, Wii Classic Controller master** —
  `fpga/gba/src/peripherals/wii_pad_master.sv` is the module `wii_pad_master`
  from TinyNES `fpga/ae350_soc/wii_pads.sv` at commit `7013393`
  (https://github.com/aquasock/TinyNES), GPL-3.0-only, which matches this
  project's licence. The module body is carried byte-identical to upstream and
  only a provenance header is added, so `diff` against the source still works;
  everything below that header is upstream's. Only this module is taken:
  upstream's second module, `wii_pads`, is an AHB slave with a four-bus register
  file for the AE350 SoC, and TinyGBA has no AHB bus and needs one controller's
  buttons folded into its keypad, so the wiring lives in `gbatang_top.sv` instead
  and the GBA memory map is untouched. The bus timing, wake-up sequence,
  format-3 selection, identity check and format-1 repacking are upstream's and
  unmodified, as are the button bit positions that TinyNES's `pad_test`
  validated on this board against a genuine Classic Controller and an 8BitDo
  Retro Receiver.

- **Build tools** — yosys 0.69 with the slang front end, `nextpnr-himbaechel` and
  `apicula` from the aquasock forks. They are build inputs, not vendored code.

- **This project's own files** — `tools/cells_behavioral.v` defines `MUX2` and
  `LUT5` behaviorally so that 2345 vendor-IP primitive instances synthesise to
  LUTs instead of demanding dedicated BELs this device does not have; the
  implementations match the semantics in oss-cad-suite's Gowin cell libraries.
  `fpga/gba/src/pll/gowin_pll_hdmi.v` is a hand-written PLL instantiation
  replacing the Gowin IP-generator wrapper `pll_74.v`, which remains in the tree,
  unbuilt, so that upstream can be diffed against it.

The licensing of this repository's own additions is not yet decided; the
vendored GPL-3.0 sources mean a GPL-3.0-compatible licence is the practical
choice, and that decision is the user's.
