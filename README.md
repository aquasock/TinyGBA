# TinyGBA

GBATang, ported to the Tang Console 138K with the open flow — yosys with the
slang front end, `nextpnr-himbaechel` against the GW5AST-138C database, and the
apicula fork's `gowin_pack`. No Gowin EDA is involved.

The video path is proven on hardware. The machine has not been booted yet: no
cartridge has run on the board, so no game has produced a picture.

## Status

- **Video chain: works.** `01_video` draws eight colour bars with a 16×16 white
  orientation marker at the top left and the wide grey band on the right. That
  exercises the PLL and divider topology, the clock placements in `tinygba.cst`,
  the OSER10 serialiser path and the TMDS pair.
- **SDRAM: sound, as far as it has been tested.** The first probe reported the
  high halfword of a 32-bit access failing; that was the probe sampling one clock
  before the data arrives, not the memory. The corrected probe has not yet run on
  the board — its place and route failed at seed 1.
- **The machine: never booted.** `04_machine` exists and has not been loaded with
  a cartridge.

## Build

```
tools/build_tinygba.sh                        # build/tinygba
TINYGBA_SEED=5 tools/build_tinygba.sh
TINYGBA_BUILD_DIR=build/diag \
  TINYGBA_DEFINES=-DTINYGBA_VIDEO_TEST tools/build_tinygba.sh
```

| variable | meaning |
|---|---|
| `TINYGBA_STAGE` | `synth`, `pnr`, `pack` or `all` |
| `TINYGBA_BUILD_DIR` | output directory |
| `TINYGBA_SEED` | placement seed; the router is seed-sensitive and will fail to converge on some |
| `TINYGBA_DEFINES` | preprocessor defines for a diagnostic build |
| `TINYGBA_ALLOW_HOLD` | `1` lets an unclean placement through; the Fmax gate still runs |

A build that fails in place and route with a few thousand nets unrouted is the
known seed sensitivity, not a broken change — retry with another seed, or use
`tools/sweep_tinygba_seeds.sh`.

### Diagnostic builds

| define | what it draws |
|---|---|
| `TINYGBA_VIDEO_TEST` | eight colour bars + orientation marker; proves the video chain alone |
| `TINYGBA_SDRAM_TEST` | sixteen bars, one per probe pattern; green = read back correctly |
| `TINYGBA_SDRAM_TEST` + `TINYGBA_SDRAM_LANES` | the low halfword's sixteen data bits, green = that lane returned 1 |
| `TINYGBA_OVERLAY_OFF` | production machine with the OSD suppressed — use this in one-wire mode |

The OSD powers up asserted and its 960-pixel window hides the framebuffer behind
an empty menu's black. In two-wire mode the BL616 menu closes it; in one-wire
mode nothing does, so a production build **without** `TINYGBA_OVERLAY_OFF` will
look black and that is not a machine fault.

## Deploy (one-wire)

One-wire puts the bitstream in the FPGA over the FT2232 and streams the cartridge
straight at the core's UART. Use the oss-cad-suite copy of `openFPGALoader`; the
system copy at v0.13.1 has no `tangconsole` board.

```
~/oss-cad-suite/bin/openFPGALoader -b tangconsole build/diag_video/tinygba.fs
```

Diagnostic builds need no cartridge. For the machine:

```
tools/load_gba_rom.py game.gba                 # /dev/ttyUSB1, 2 Mbaud
tools/load_gba_rom.py game.gba --dry-run       # header check only, sends nothing
```

Two operational facts that cost time when forgotten. A flash that reports `Done`
can still leave the board silent, and the fix is to load the same file again — so
a single flash is not a test of a bitstream. And flashing clears the core's
`loaded` state, so a cartridge has to be streamed again after every flash.

## Layout

```
fpga/gba/src/      vendored GBATang, deviations marked `TinyGBA:` in place
fpga/gba/diag/     diagnostic probes, the pin-level SDRAM model and its testbench
fpga/gba/*.cst     pin and clock placement for the Console 138K
tools/             build, ROM loading, seed sweep, diagnostic simulation
build/deploy/      a numbered image set: 01_video, 02_sdram, 03_prod, 04_machine
```

`fpga/gba/src/` is upstream's, kept unbuilt so it can be diffed against
[GBATang](https://github.com/nand2mario/gbatang). Every deviation is a forced
toolchain accommodation — slang rejecting `$error`, undeclared parameters,
block-scoped registers — rather than a design change. See `THIRD_PARTY.md`.

## Known gaps

- No cartridge has been run on the board.
- `tools/run_diag_sim.sh` cannot see faults in `sdram_gba.v`: it compiles
  `sdram_sim.v`, a logic-level stand-in, so the controller is never simulated.
  `fpga/gba/diag/sdram_model.v` and `tb_sdram_controller.sv` are the start of
  closing that gap and are not yet a reliable authority.
- Controller input arrives over the BL616 link and has not been exercised.
- `sdram_gba.v` relies on the device powering one register to zero; it has no
  reset term, so it is X in simulation.
