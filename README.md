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
- **SDRAM: verified good on the board.** The corrected probe reads sixteen green
  bars and a green status band: 64 MiB, both dies, all sixteen patterns. Two
  earlier readings of that probe were taken on images whose `clk67` crossed no
  clock-plane pip at all and are superseded. See `core-reference.md` BRD-006.
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
| `TINYGBA_CLOCK_PLANE_STRICT` | `1` makes the clock-plane gate refuse a clock on a pip this board has never measured |

A build that fails in place and route with a few thousand nets unrouted is the
known seed sensitivity, not a broken change — retry with another seed, or use
`tools/sweep_tinygba_seeds.sh`.

Two gates run between routing and packing, because neither is visible in the
timing report and both have shipped an image that was wrong:

- **`tools/clock_plane_report.py`** reads the routed netlist and reports which
  clock-plane bridge pip each clock takes. A clock on a pip measured as clocking
  nothing, or on no pip at all (general routing), fails the build. It writes
  `$out/clock-plane.log`. What it cannot yet do is require a measured-good path:
  `clk16` lands on `*/TOP3` pips at every seed tried, and this board has never
  measured those. `TINYGBA_CLOCK_PLANE_STRICT=1` turns that into a refusal.
- **`tools/gatelevel_report.py`** reads the synthesised netlist and reports, per
  named net, whether it exists and whether every bit has a driver. Use it before
  trusting any hardware reading from a build, and `--compare` two netlists to see
  what a change did to the fetch path.

### Diagnostic builds

| define | what it draws |
|---|---|
| `TINYGBA_VIDEO_TEST` | eight colour bars + orientation marker; proves the video chain alone |
| `TINYGBA_SDRAM_TEST` | sixteen bars, one per probe pattern; green = read back correctly |
| `TINYGBA_SDRAM_TEST` + `TINYGBA_SDRAM_LANES` | the low halfword's sixteen data bits, green = that lane returned 1 |
| `TINYGBA_OVERLAY_OFF` | production machine with the OSD suppressed — use this in one-wire mode |
| `TINYGBA_STATUS_TEST` | sixteen sticky status bits — did the loader release the CPU, did the CPU fetch, did the controller answer, did the GPU draw |

The OSD powers up asserted and its 960-pixel window hides the framebuffer behind
an empty menu's black. In two-wire mode the BL616 menu closes it; in one-wire
mode nothing does, so a production build **without** `TINYGBA_OVERLAY_OFF` will
look black and that is not a machine fault.

### Test cartridge

`tools/make_gba_test_rom.py` writes a self-checking cartridge, so the first
cartridge put on the board is a discriminator rather than an experiment:

```
tools/make_gba_test_rom.py -o build/test/test.gba
```

It forces blank, checks three constants at three cartridge offsets, writes and
reads back IWRAM, EWRAM and VRAM including two individual byte lanes, then draws
mode 3 — **green** if every check passed, **red** with one yellow full-height
column per failed check if any did not — and blinks a white square so a capture
can tell a running CPU from one that wedged. It enables no interrupt and writes
no `WAITCNT`, so a pass says nothing about either. Needs `arm-none-eabi-as`; set
`ARM_TOOLCHAIN` to its bin directory if it is not on `PATH`. The logo region is
zero-filled because this core's BIOS is Cult-of-GBA built with `NO_LOGO`, which
branches straight to `0x08000000` without validating it.

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
- **The machine image builds, but its timing is judged rather than proven.**
  Its `clk67` path from the SDRAM readback through the CPU and back measures
  29.77 ns, which exceeds one 67 MHz cycle and sits inside the four cycles
  upstream GBATang's `gbatang.sdc` allows for exactly that path. nextpnr cannot
  express a multicycle path — it implements no `set_multicycle_path` and its
  `set_false_path` is a no-op — so it refused the build. `tools/timing_gate.py`
  now applies the four documented allowances, prints each one with the upstream
  line it comes from, and gates the hold count and the cross-clock paths that
  the Fmax report never sees. The image is correct against the design's own
  contract and unproven on silicon: only a cartridge on the board can confirm
  the allowance. `build/prod` still has hold violations and is not buildable.
- `tools/run_diag_sim.sh` cannot see faults in `sdram_gba.v`: it compiles
  `sdram_sim.v`, a logic-level stand-in, so the controller is never simulated.
  `fpga/gba/diag/sdram_model.v` and `tb_sdram_controller.sv` are the start of
  closing that gap and are not yet a reliable authority.
- Controller input arrives over the BL616 link and has not been exercised.
- `sdram_gba.v` relies on the device powering one register to zero; it has no
  reset term, so it is X in simulation.
