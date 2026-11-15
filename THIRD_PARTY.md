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

  **Twelve files in that tree are not nand2mario's work.** They are output of
  Gowin's IP generator and carry `Copyright (C)2014-2024 Gowin Semiconductor
  Corporation. All rights reserved.` in their header. Five of them are in the
  shipped build: two memory wrappers `gpu/vram_lo.v` and `gpu/vram_hi.v`, and the
  three PLL wrappers `pll/pll_12.v`, `pll/pll_27.v` and `pll/pll_33.v`. The other
  seven are not built: six are duplicates in an unused `plla/` directory and
  `pll/pll_74.v` is superseded by the hand-written `pll/gowin_pll_hdmi.v`. Four
  of the six memory wrappers have been replaced by this project's own RTL:
  `iosys/gowin_dpb_menu.v` by `iosys/menu_ram.v` (TCL-067),
  `memory/mem_eeprom.v` by `memory/eeprom_ram.v` (TCL-069),
  `memory/mem_iwram.v` by `memory/iwram_ram.v` (TCL-072) and `fb.v` by `fb_ram.v`
  (TCL-073), with the superseded files and their Gowin project descriptors
  removed. They are used as build
  inputs and are not covered by this repository's licence, which cannot extend to
  material its author did not write. The `.ipc` and `.mod` files beside them are
  Gowin project descriptors, read only by Gowin's own tooling and never by the
  build. See TCL-065 for what these files are and where they sit in the netlist.

  The remaining two memory wrappers -- `vram_lo` and `vram_hi` -- are primitive
  instantiations plus generated logic around them: bank decoders, registered
  output selects and multiplexer trees. Replacing them means restating that logic
  in ordinary RTL rather than copying a port list. Both already carry a generic
  behavioural counterpart at the same instantiation site under
  `ifdef VERILATOR`.
  `fpga/gba/src/common/dpram_block.v` is the model for that work, and the
  substitution is checked by simulation rather than by counting cells:
  `tools/sim/run_mem_equiv_tb.sh` drives each old and new wrapper side by side
  under `tools/sim/gowin_bram_sim.v` and requires deliberately broken variants
  to fail (TCL-068, TCL-069, TCL-072).

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

## This repository's own licence

TinyGBA is **GPL-3.0-only**. The text is in `LICENSE`, and every source file
this repository wrote carries an `SPDX-License-Identifier: GPL-3.0-only` header.
The one exception is `tools/fs_to_bin.py`, carried in from TinyTang, which keeps
its own MIT licence -- GPL-3.0 permits that, and the header says so.

The licence is not a preference here. `fpga/gba/src/` is GBATang, which is
GPL-3.0, vendored in-tree rather than fetched, and this project's RTL is
compiled into the same bitstream as it, so the result is a single work and
GPL-3.0 is the only licence that work can carry. `GPL-3.0-only` rather than
`GPL-3.0-or-later` names what is actually granted: the GBATang sources are
version 3 as published, with no "or later" in their notices.

The decision was taken on 2026-11-15, replacing the earlier "not yet decided"
state in which this file recorded that a GPL-3.0-compatible licence was the
practical choice. Vendored components keep their own terms and are listed above:
hdl-util's HDMI transmitter stays MIT (`fpga/gba/src/hdmi/LICENSE-MIT`), and the
Gowin IP-generator output is not covered by this repository's licence at all.

No licence here is legal advice, and one question is deliberately left open:
whether Gowin's own terms permit redistributing IP-generator output, which no one
working on this repository has read. See TCL-065. Anyone distributing a bitstream
built from this tree commercially should satisfy themselves on that point.
