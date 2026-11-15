# TinyGBA

GBATang, ported to the Tang Console 138K with the open flow — yosys with the
slang front end, `nextpnr-himbaechel` against the GW5AST-138C database, and the
apicula fork's `gowin_pack`. No Gowin EDA is involved.

**A retail GBA cartridge runs on the board.** Castlevania: Aria of Sorrow, an
8 MiB image, boots to its title screen, plays its intro and continues into
gameplay, producing 75 distinct frames in 75 seconds with correct picture,
correct audio and a correct frame rate. Six consecutive loads of that same image
all booted correctly. The diagnostic suite reports `RESULT: ALL REGIONS PASS` on
hardware across IWRAM, EWRAM, VRAM, PRAM and OAM, and its button test counts
10/10 controls pressed.

The operator's assessment is that this is the first open-flow GBA core — yosys,
nextpnr, no vendor EDA — to run retail software on hardware, following the same
project's TinySNES core. That is a claim about the wider field rather than
something measured here, and is stated as the operator's assessment, not as a
verified fact.

---

## Status

### The machine: runs retail titles

- **Picture.** A twelve-title sweep found eleven running correctly. Metroid Fusion,
  The Minish Cap, Golden Sun, Metroid Zero Mission, Advance Wars, Fire Emblem,
  Final Fantasy Tactics Advance, Castlevania: Aria of Sorrow, Mario Kart: Super
  Circuit, Doom II and Asterix & Obelix XXL all pass on audio and video, the last
  two being software-rendered 3D titles chosen to push the machine hardest. One
  cartridge fails: Pokemon Emerald stops at the BIOS handover's white screen. See
  BRD-080 through BRD-087.
- **Speed.** The core runs at 99.8378% of a real GBA's frame rate — 59.6306 Hz
  against 59.7275 — because the PLL cannot reach 16.777216 MHz from a 27 MHz
  reference. That deficit is a clock-plan compromise, not a speed limit: Doom II
  drops frames in the same places, by the same magnitude, as mGBA. See TCL-058
  and BRD-086.
- **Audio.** Stereo separation is correct on HDMI and both pitch and level are
  now correct. Measured through the capture card's own audio input: CH1 SQUARE
  plays 439.4 Hz at 3331 RMS for a stated 440 Hz, CH3 WAVE plays 440.1 Hz with a
  textbook triangle spectrum, and the PCM path — which was never at fault —
  sweeps cleanly from 40 to 7960 Hz against a claimed 100–8000. See BRD-071,
  BRD-072 and BRD-074.
- **Memory.** The diagnostic suite passes every internal region at full size:
  IWRAM 32K, EWRAM 256K, VRAM 96K, PRAM 1K, OAM 1K, cells and decoder both, in
  1377 ms. See BRD-069.
- **Input.** Two independent paths work. Host-side joystick injection over the
  core's UART drives the diagnostic cartridge's menu, and the cartridge's own
  button test confirms all ten controls — see BRD-068. And the board's own
  controller works: a Wii Classic Controller on USB-A port 2 drives the GBA
  keypad directly, with A and X both pressing GBA **A**, B and Y both pressing
  GBA **B**, and every other button mapping one-to-one — see BRD-079.
- **Multi-load behaviour.** The bimodality recorded in BRD-014 and BRD-045 — one
  load halting, another running — did not reproduce across six consecutive loads
  of one 8 MiB image on one bitstream. See BRD-077.

### The two defects that blocked it, both now fixed

Both were synthesis and memory-arbitration faults rather than anything in the
CPU, the GPU or a cartridge.

- **The netlist was mis-synthesised.** Three helper functions in
  `gba_memory.sv` were declared without `automatic`, so every call site drove one
  shared argument variable. Yosys reported 72 `multiple conflicting drivers`
  warnings against `issingle`, `isreadonly` and `tosdram` — the memory and DMA
  arbitration — and resolved them arbitrarily. A minimal reproduction
  synthesised the input bus shorted to ground and the output tied to VCC.
  Verilator inlines functions per call site and never saw it, which is why every
  simulation passed while the bitstream did not. **BRD-064, TCL-049.**
- **An undriven wire in the DMA data path.** `dma_bus_unread` was connected to
  nothing, and it sits in the one condition that decides whether a DMA transmits
  the word it just read or a stale buffer. In simulation an undriven wire is 0, so
  real data moved; under `synth_gowin` it is `x`, `opt` folded the condition to
  constant false, and every DMA transmitted `last_dma_in` — zero on a first
  transfer. **BRD-065, TCL-050.**
- A third fix restored two lines of `gba_memory.sv` to upstream, undoing a port
  change from 2026-11-02 that became both unnecessary and harmful once the ready
  strobe was synchronised. **Commit `f38cebe`, BRD-066.** The fix is confirmed;
  the proposed mechanism for it is not, and `DISSENT-req2-start-mechanism-2026-11-14.md`
  records the contradiction rather than smoothing it over.

### Earlier milestones, still true

- **Video chain.** `01_video` draws eight colour bars with a 16×16 white
  orientation marker and the wide grey band; that exercises the PLL and divider
  topology, the clock placements in `tinygba.cst`, the OSER10 serialiser path
  and the TMDS pair.
- **SDRAM.** Verified good on the board: 64 MiB, both dies, all sixteen
  patterns. See `core-reference.md` BRD-006.

### Open

- **The clock plan is not fully settled.** `clk16` reaches its sinks on `*/TOP3`
  pips this board has never measured, and `tools/clock_plane_report.py --strict`
  refuses every placement this tree produces. Only four clock-plane paths are
  measured-good here, and the sibling TinySNES project's BRD-005 records the same
  netlist booting or not depending only on which spine the master clock takes.
  A hardware reading from this tree is still attributable to the design only with
  that caveat.
- **Timing margin is a property of the netlist, not of the seed.** Some images
  need the documented GBATang multicycle relaxation for `clk67` and some do not:
  `build/rev_prod` reached 181 MHz with none while every build carrying the
  audio fix lands at 48–57 MHz and needs the allowance. A 24-seed sweep with a
  matched control shows no seed recovers it, and a build with only the four
  sound files reverted reproduces the fast netlist and 184 MHz exactly, so the
  cost is the audio change moving the synthesiser's optimisation boundary rather
  than the placement. See TCL-056. The relaxation is the one upstream
  `gbatang.sdc` exists to express, so these images are correct, not marginal —
  but any timing figure from one must say it needed the allowance.
- **The save path has never worked.** `tools/load_gba_rom.py` sends only commands
  `0x06`, `0x07` and `0x08`, and `config_backup_type` is assigned from the loader
  stream only in a fourth loading stage this loader never enters, so it stays
  `BACKUP_NONE`, regions `0x0E000000` and `0x0F000000` are treated as read-only,
  and every save write is discarded. No cartridge with a battery-backed save has
  ever had one on this board. See BRD-070.
- **The Classic Controller's analogue inputs are unused.** The sticks and the
  two analogue triggers are read by the pad master and thrown away; only the
  fifteen buttons reach the keypad, because the GBA has no analogue input. The
  one consequence worth knowing is that LEFT and RIGHT come from the D-pad
  rather than from a stick.
- **Link port, RTC and solar sensor** are unexercised; no cartridge here uses
  them.

---

## Build

```
tools/build_tinygba.sh                        # build/tinygba
TINYGBA_SEED=5 tools/build_tinygba.sh
TINYGBA_BUILD_DIR=build/diag \
  TINYGBA_DEFINES=-DTINYGBA_VIDEO_TEST tools/build_tinygba.sh
```

The production image, as built and tested (this produced `build/snd_prod`, the
current best image — a retail title runs on it; see Status):

```
TINYGBA_BUILD_DIR=build/snd_prod TINYGBA_SEED=14 \
TINYGBA_DEFINES='-DTINYGBA_OVERLAY_OFF -DTINYGBA_BIOS_HEX="/abs/path/official_bios.hex"' \
tools/build_tinygba.sh
```

`-nowidelut` is passed to `synth_gowin` by default, because it is smaller,
faster to place, better timed and identical in flip-flop count: without it wide
muxes map to fixed-position `MUX2_LUT5..8` primitives, cell count rises from
58,501 to 81,124, and placement takes roughly three times as long. `TINYGBA_WIDELUT=1`
restores the old mapping for comparison; every image this project has deployed
since 2026-11-13 was built with the default. See TCL-036.

| variable | meaning |
|---|---|
| `TINYGBA_STAGE` | `synth`, `pnr`, `pack` or `all` |
| `TINYGBA_BUILD_DIR` | output directory |
| `TINYGBA_SEED` | placement seed; the router is seed-sensitive and will fail to converge on some |
| `TINYGBA_DEFINES` | preprocessor defines, including `-DTINYGBA_BIOS_HEX="/abs/path.hex"` to substitute a BIOS |
| `TINYGBA_WIDELUT` | `1` disables the default `-nowidelut`, mapping wide muxes onto `MUX2_LUT` primitives |
| `TINYGBA_SYNTH_EXTRA` | extra arguments for `synth_gowin`, appended after the default; for experiments |
| `TINYGBA_FORCE_SYNTH` | `1` re-synthesises even when a cached netlist exists |
| `TINYGBA_ALLOW_HOLD` | `1` lets an unclean placement through; the Fmax gate still runs |
| `TINYGBA_CLOCK_PLANE_STRICT` | `1` makes the clock-plane gate refuse a clock on a pip this board has never measured |

Each build gets its own directory under `build/` and they accumulate — several
hundred exist in a working tree, because a seed sweep or a before/after
comparison creates one per attempt. `build/test/` holds probe cartridges.

A build that fails in place and route with a few thousand nets unrouted is the
known seed sensitivity, not a broken change — retry with another seed, or use
`tools/sweep_tinygba_seeds.sh`. Placement and routing dominates the wall clock;
re-running with `TINYGBA_STAGE=pnr` reuses the cached netlist.

### Gates

Each of these exists because something shipped that was wrong and neither the
timing report nor any simulation could see it.

- **1a. Synthesis-conflict** — fails the build on any `multiple conflicting
  drivers` warning. Read from both `synth.err` and `synth.log`, because those two
  files have held different counts of the same warning on one design. **This is
  the gate that would have caught the defect that blocked the machine for a
  week**; see BRD-064.
- **1b. Register parity** (`tools/synth_parity.py`) — compares a netlist's
  register population against a recorded baseline for its configuration and
  fails on a large loss. A netlist can lose most of its registers and still
  build, pass timing and pack; on 2026-11-02 an undriven `gb_bus_rst` folded high
  and deleted about 4,500 of 9,100 flip-flops. Record a baseline with
  `--update-baseline`.
- **1c. Clock edge** (`tools/clock_edge_check.py`) — refuses a netlist where one
  clock drives both a true negedge flop and a LUT clock inverter. On GW5A
  `synth_gowin` legalises negedge flops into posedge `DFFRE` behind a LUT1
  inverter, so the two halves clock a few ns apart with no hold check between
  them. That deadlocked the SuperFX in the sibling TinySNES project.
- **1d. Memory placement** (`tools/memory_census.py`) — records which arrays the
  synthesiser put in distributed (LUT) RAM and fails when one appears,
  disappears or changes resource against a baseline for the configuration. The
  choice is invisible in the RTL: `synth_gowin` decides it, and on this design it
  already disagrees with the source — the one 4-bit line buffer asks for block
  RAM in comment syntax `read_slang` does not parse and lands in LUT RAM. The
  gate does not force a mapping, because `-nolutram` wholesale would also move
  four sound arrays and the loader buffer; it makes a deliberate change visible
  as a baseline diff. Record one with `--update-baseline`. See TCL-033.
- **1e. BSRAM address port** (`tools/bsram_addr_check.py`) — fails when a
  dual-port BSRAM `ADB` address bit is driven through more than 8 logic levels
  and the array is not one already on record. nextpnr's Gowin model does not time
  that port at all, so no other gate in this build covers it, and whether such a
  path fails depends on the placement — this project's recurring failure mode.
  `mem.mem_bios` is recorded as known at 44 levels; the gate catches a *new* deep
  cone. See TCL-035.
- **3. Clock plane** (`tools/clock_plane_report.py`) — reports which clock-plane
  bridge pip each clock takes, and fails on a pip measured as clocking nothing or
  on no pip at all (general routing). `TINYGBA_CLOCK_PLANE_STRICT=1` additionally
  refuses a pip this board has never measured.
- **4. Timing** (`tools/timing_gate.py`) — applies the documented GBATang
  multicycle allowances, prints each with the upstream line it comes from, and
  gates the hold count and the cross-clock paths that the Fmax report never sees.
  nextpnr implements no `set_multicycle_path` and its `set_false_path` is a
  no-op, which is why this gate exists rather than a constraint file.

The build also refuses a stale `fpga/gba/src/probe_bits.vh` and a diagnostic
packing width that does not match its field map.

### Diagnostic builds

| define | what it draws |
|---|---|
| `TINYGBA_VIDEO_TEST` | eight colour bars + orientation marker; proves the video chain alone |
| `TINYGBA_SDRAM_TEST` | sixteen bars, one per probe pattern; green = read back correctly |
| `TINYGBA_SDRAM_TEST` + `TINYGBA_SDRAM_LANES` | the low halfword's sixteen data bits, green = that lane returned 1 |
| `TINYGBA_OVERLAY_OFF` | production machine with the OSD suppressed — use this in one-wire mode |
| `TINYGBA_STATUS_TEST` | sixteen probe bits: fetch region, raster, halt state and interrupt enables |
| `TINYGBA_PIXTEST` | sixteen drawer bands: live `drawstate`, `busy_mode345` and the VRAM fetch state |
| `TINYGBA_FETCHTRACE` | the first sixteen completed CPU memory cycles after the jump to `0x08000000`, as bit cells; decoded by `tools/decode_fetchtrace.py` |
| `TINYGBA_STALLTRACE` | an MMIO write ring and FSM snapshots around a detected stall |

The `TINYGBA_STATUS_TEST` bar layout is **generated**, not hand-written. One field
list in `tools/probe_map.py` produces both the RTL packing
(`fpga/gba/src/probe_bits.vh`) and the host decoder, and the build refuses a
stale include. Four consecutive cycles on the sibling SNES project mis-stated a
field position and each produced a plausible number rather than an error; this
project then repeated that class three times in one session. Decode a capture
with `tools/probe_map.py --decode frame.png` and never by hand — the tool prints
the map id, and a capture only decodes under the map that built it.

The OSD powers up asserted and its 960-pixel window hides the framebuffer behind
an empty menu's black. In two-wire mode the BL616 menu closes it; in one-wire
mode nothing does, so a production build **without** `TINYGBA_OVERLAY_OFF` will
look black and that is not a machine fault.

### Simulation

The core runs under Verilator with SDL video, FST tracing and audio capture:

```
tools/sim/build_gba_sim.sh build          # verilate and compile
tools/sim/build_gba_sim.sh run game.gba   # SDL window; -s N limits steps
TINYGBA_SIM_DEFINES=-DTINYGBA_SDRAM_RTL \
  tools/sim/build_gba_sim.sh build        # real controller + pin-level model
```

`-DTINYGBA_SDRAM_RTL` swaps the behavioural `sdram_sim.v` array for the real
`sdram_gba.v` controller driving `fpga/gba/diag/sdram_model.v`. It is slower and
it is the only way to exercise the controller at all; several real faults only
appeared in that configuration.

Two things the harness cannot tell you, learned the hard way:

- **It cannot see a synthesis defect.** Verilator and `synth_gowin` differ on
  undriven wires and on static function storage, and both differences produced
  faults that ran correctly in the model and failed on the board. When hardware
  and simulation disagree, read the synthesis log before doubting the RTL.
- **It is unfair about cross-clock questions.** The harness clocks `clk50:clk16`
  at exactly 3:1 from one counter, which matches the board's 50.25:16.75 MHz, but
  on the board the two come from different PLLs with an arbitrary phase.

A unit testbench that instantiates one production module and drives its register
bus is often the better instrument: minutes instead of forty, and it can be run
against the pre-change module from git to give a matched before/after. That is
how the two audio fixes were verified before any bitstream was built — see
BRD-073 and TCL-053.

### Test cartridges

`tools/make_probe_rom.py` assembles every probe in `tools/roms/` into a loadable
cartridge. Each one paints green where the machine behaved and red where it did
not, so a result reads off a screen rather than being inferred.

```
tools/make_probe_rom.py --list
tools/make_probe_rom.py irq3                  # -> build/test/irq3.gba
tools/make_probe_rom.py all --out-dir build/test
```

`tools/make_gba_test_rom.py` writes the original self-checking cartridge, which
forces blank, checks three constants at three cartridge offsets, writes and reads
back IWRAM, EWRAM and VRAM including two byte lanes, then draws mode 3 — green if
every check passed, red with one yellow column per failure. It enables no
interrupt and writes no `WAITCNT`, so a pass says nothing about either.

**Every probe must pass in mGBA before its board result is read.** A probe that
fails in the emulator is telling you about itself. This rule (TCL-041) has caught
at least eight separate instrument defects here — a PC-relative `adr` with the
cartridge base added twice (TCL-042), an interrupt acknowledged through `IE`
instead of `IF` (TCL-043), breakpoints taken from an older build (TCL-044), an
SWI number in the wrong bits (TCL-045), a probe whose expected value was `0x0000`
— exactly what a broken transfer writes, so its green certified a fault for three
days (TCL-047), probes that never verified their own preconditions (TCL-048), and
a frame magic one byte off the working loader's (TCL-051).

---

## Deploy (two-wire, from the SD card)

This is the normal way to run a game, and the same way every other core on the
card works: the FPGA core lives on the SD, the cartridge lives on the SD, and the
board loads both itself. Nothing is transferred from a PC.

```
# put the core pair on the card (tools/ship_core.py builds it from a build dir)
python3 tools/ship_core.py build/snd_prod
python3 ../TinyTang/tools/tinytang_put.py --port /dev/ttyACM1 \
    build/snd_prod/ship/tinygba.bin /root/cores/console138k/tinygba.bin

# put a cartridge under /root/media/gba/
python3 ../TinyTang/tools/tinytang_put.py --port /dev/ttyACM1 \
    "game.gba" "/root/media/gba/game.gba"

# on the board's shell (tangload programs the FPGA; gbaload streams the cart)
tangload /root/cores/console138k/tinygba.bin
gbaload "/root/media/gba/game.gba"
```

`gbaload` is `nesload`'s counterpart for this core and lives in TinyTang's
firmware, not here: the frame protocol is nand2mario's and identical between the
cores, so it sends `0x06` to hold the core in reset, `0x07` for cartridge bytes in
1024-byte chunks with a `taskYIELD` between them, then clears the OSD and sends
`0x06` again to start the game. It refuses a file that is not a cartridge (no
`0x96` at `0xB2`) or one larger than the 32 MiB a GBA cartridge can be.

**A controller only works on this path.** An image flashed over JTAG runs the core
but configures no socket fabric, so nothing on the pad responds (TCL-054).
Two-wire is mandatory for play; one-wire is for bench work only.

Operational facts that cost time when forgotten:

- **A power cycle erases the FPGA.** After rebooting the board, `tangload` the
  core again before `gbaload` means anything.
- Reloading a cartridge restarts it from the beginning; there is no resume.
- The console and the machine are independent. The BL616's USB console has
  wedged mid-transfer while the game kept running perfectly on screen; a reboot
  clears it and the core was never at fault.
- `tools/board_mode.py` reports which mode the board is in by asking it, rather
  than inferring it from `lsusb` — the two have disagreed.

### Deploy (one-wire, bench only)

One-wire puts the bitstream in the FPGA over the FT2232 and streams the cartridge
straight at the core's UART. Use the oss-cad-suite copy of `openFPGALoader`; the
system copy at v0.13.1 has no `tangconsole` board.

```
~/oss-cad-suite/bin/openFPGALoader -b tangconsole build/snd_prod/tinygba.fs
tools/load_gba_rom.py game.gba                 # /dev/ttyUSB1, 2 Mbaud
tools/load_gba_rom.py game.gba --dry-run       # header check only, sends nothing
```

`fpgapipe` cannot carry a large cartridge: it aborts when UART1's FIFO stays full
for 100 ms, which a sustained 192 KB/s stream against a 200 KB/s core will do on
any hiccup. An 8 MB image failed at about 5.7 MB every time this way, and each
failure took the BL616 down with it. Use the card path above instead.

Operational facts that cost time when forgotten:

- A flash that reports `Done` can still leave the board silent, and the fix is to
  load the same file again — so a single flash is not a test of a bitstream.
- Flashing clears the core's `loaded` state, so a cartridge must be streamed
  again after every flash, and after any power cycle.
- **A power cycle erases the FPGA.** After rebooting the board the core must be
  flashed before a cartridge means anything.

### Driving input

The core's own command table carries a joystick command, so a menu or a game that
waits for a button can be driven from the host:

```
tools/gba_input.py press START                 # press and release, 120 ms
tools/gba_input.py hold DOWN --seconds 0.6     # hold, then release
tools/gba_input.py set UP|RIGHT                # hold until changed
tools/gba_input.py release                     # all buttons up
```

GBA keypad bits, and the states the diagnostic cartridge reports, are in
`tools/roms/keylive.s` — a probe that polls `KEYINPUT` and paints one square per
button, so a capture taken during a hold reports the keypad at that moment.

### The controller on the board

A Wii Classic Controller (or an 8BitDo Retro Receiver with its own controller)
plugs into **USB-A port 2** and drives the GBA keypad with no host involved. The
port's data pair is an open-drain I2C bus — D+ is SDA, D- is SCL — polled by
`fpga/gba/src/peripherals/wii_pad_master.sv`, which is TinyNES's master vendored
byte-identical; the adapter's pull-ups divide against the dock's host pull-downs,
so no level shifting is needed.

This only works in **two-wire mode, loaded with `tangload`**. A bitstream flashed
over JTAG runs the core but configures no socket fabric, so no controller can
respond to it (TCL-054):

```
python3 ../TinyTang/tools/tinytang_put.py --port /dev/ttyACM1 \
    build/<dir>/ship/tinygba.bin /root/cores/console138k/tinygba.bin
tangload /root/cores/console138k/tinygba.bin        # on the board's shell
```

The mapping, from TinyNES's `pad_test` table as validated on this board: the
D-pad, A, B, START, SELECT, L and R map one-to-one; **X also presses A** and **Y
also presses B**, preserving the Classic Controller's physical face-button
arrangement; **ZL and ZR also press L and R**; HOME is unmapped. The analogue
sticks and triggers are read and discarded, because the GBA has no analogue
input.

`tools/pad/run_pad_tb.sh` checks the wiring and the mapping in simulation against
a byte-level controller model, for both a genuine Classic Controller and the
receiver, before any bitstream is spent on it.

### Capturing

`tools/cap_tang.sh <build-dir> <prefix> [--no-flash]` flashes and captures
`/dev/video0` at 1920×1080 MJPEG. Measured on this board the active area is x 149–1770
with the frame full height, so the scale is about 6.76. The capture card also exposes its audio
input as ALSA `hw:1,0`; `arecord -D hw:1,0 -f S16_LE -r 48000 -c 2` records what
the HDMI link is carrying, which is how the audio measurements were taken.

---

## Layout

```
fpga/gba/src/      vendored GBATang, deviations marked `TinyGBA:` in place
fpga/gba/diag/     diagnostic probes, the pin-level SDRAM model and its testbench
fpga/gba/*.cst     pin and clock placement for the Console 138K
tools/             build, ROM loading, probes, gates, simulation, input
tools/roms/        probe cartridge sources, one discriminator each
.ai/               core.md, core-log.md, core-reference.md, core-syntax.md
```

`fpga/gba/src/` is upstream's, kept close enough to diff against
[GBATang](https://github.com/nand2mario/gbatang). Deviations are marked `TinyGBA:`
in place and fall into three groups: forced toolchain accommodations (slang
rejecting `$error`, undeclared parameters, block-scoped registers), `ifdef`-guarded
diagnostics that never reach a synthesised build, and fixes for real defects with
a record behind each. See `THIRD_PARTY.md`.

### Project memory

`.ai/` is the authoritative record and it is worth reading before changing
anything:

- **`core.md`** — directives. Restricted; changed only on request.
- **`core-log.md`** — one entry per cycle: what was attempted, what was measured,
  what was got wrong. A ring buffer of 100 entries.
- **`core-reference.md`** — the record library. `BRD-` for board findings,
  `TCL-` for toolchain and instrument findings. Every hardware claim in this
  README has a record id.
- **`core-syntax.md`** — format rules for the above.

Records are not append-only decoration. Many carry a `SUPERSEDED` or `WITHDRAWN`
title after later evidence contradicted them, and that is deliberate: the useful
part is often *which* conclusion turned out wrong and what the measurement was
that killed it.

---

## Known gaps

- **Save hardware is not configured by the loader.** See Status above; no
  cartridge with a battery-backed save has run here.
- **`clk67` timing margins are seed-dependent.** Some placements need the
  documented multicycle allowance, some do not.
- **The clock-plane question is open.** Four paths are measured-good; `clk16`'s
  `*/TOP3` pips are not, and `--strict` refuses every placement this tree makes.
- **Long-run stability is unmeasured.** The longest continuous run recorded is 75
  seconds of one retail title. That is a smoke test, not a soak, and nothing here
  says anything about an hour of play.
- **Attribution of the `REQ2_START` fix is unresolved.** The revert works; the
  Thumb stale-acknowledgement mechanism proposed for it does not reproduce under
  the probe written to test it. See the dissent document.
- `tools/run_diag_sim.sh` compiles `sdram_sim.v` and so cannot see faults in
  `sdram_gba.v`; use `-DTINYGBA_SDRAM_RTL` instead.
- `sdram_gba.v` relies on the device powering one register to zero; it has no
  reset term, so it is X in a plain simulation.
