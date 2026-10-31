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
  `src/` verbatim except for the files listed below, each change marked in place
  with a `TinyGBA:` comment.

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
