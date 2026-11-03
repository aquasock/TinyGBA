#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""One declarative field map per diagnostic probe, generating both sides of it.

Why this exists.  On the sibling SNES project, four consecutive cycles read a
probe frame and mis-stated a field position, and every one of them produced a
plausible number rather than an error: a bit-reversed address looked like a real
address, a field read one bit low looked like a real flag.  All four were caught
by luck -- some other field happened to have a known expected value.  This
project then made three more of the same class in a single session.  A width
check catches a wrong total; it cannot catch a wrong ORDER, and a throwaway
decoder written per cycle is not a source of truth.

So the field map is declared once, here, and both sides are generated from it:

  * `--emit-verilog` writes `fpga/gba/src/probe_bits.vh`, which `gbatang_top.sv`
    includes.  It contains the concatenation, the per-field bit offsets, and an
    elaboration-time assertion that the widths sum to the probe bus width.  A
    wrong total becomes a build error instead of a readout to be decoded around.
  * `--decode` takes a captured frame and decodes it using the same list, so the
    RTL and the decoder cannot disagree.

The list is ordered from bit 0 upward.  `value` is the Verilog expression the
field is packed from.  Nothing else in the tree should restate these widths.

    tools/probe_map.py --list
    tools/probe_map.py --emit-verilog            # regenerate the include
    tools/probe_map.py --check                   # fail if the include is stale
    tools/probe_map.py --decode frame.png        # decode a capture
    tools/probe_map.py --decode --barbits 1010..  # decode a bare bit string
"""
import argparse
import json
import re
import sys

PROBE_WIDTH = 16
INCLUDE_PATH = "fpga/gba/src/probe_bits.vh"

# Ordered from bit 0 upward.  `value` must be a Verilog expression whose width
# equals `width` -- the generated assertion checks the total, and `--list`
# prints the individual widths so a mismatch is visible before a build.
FIELDS = [
    dict(name="cart_fetched", width=1, value="st_cart_seen",
         doc="CPU has fetched from the cartridge (rom_addr[27:24] non-zero)"),
    dict(name="vblank_arrived", width=1, value="st_gpu[0]",
         doc="a VBlank period has arrived (DISPSTAT flag, needs no CPU help)"),
    dict(name="dispstat_written", width=1, value="st_reg[0]",
         doc="the CPU ever wrote 0x04000004 (DISPSTAT) at all"),
    dict(name="halt_entries", width=4, value="st_halt_edges",
         doc="how many times the CPU has entered a halt, saturating at 15"),
    # The loader-to-memory path.  BRD-013 left one question open: whether the
    # cartridge bytes the host sends ever enter the loader, and whether the SDRAM
    # controller ever answers, because "the CPU never fetched from 0x08000000" is
    # consistent with the bytes never arriving AND with them arriving into a
    # controller that never acknowledges.  `halts_entries` and the video bits
    # cannot separate those.  Both signals already existed as sticky latches in
    # `st_bits[2]`/`st_bits[3]`; they were simply never put on the wire.
    dict(name="loader_valid", width=1, value="st_bits[3]",
         doc="a cartridge byte reached the loader (loader_do_valid rose)"),
    dict(name="mem_ready", width=1, value="st_bits[2]",
         doc="the SDRAM controller acknowledged a request, as seen from clk16 "
             "(cpu_mem_ready rose while a clk16 edge sampled it)"),
    # Separate the three ways `mem_ready = 0` can happen.  Read together with the
    # bit above, these form a 2x2 that names the fault instead of guessing:
    #   alive=0                                    -> clk67 never clocks the
    #                                                 controller at all
    #   alive=1, mem_ready_clk67=0, mem_ready=0    -> controller runs but never
    #                                                 acknowledges
    #   alive=1, mem_ready_clk67=1, mem_ready=0    -> it acknowledges and the
    #                                                 clk16 domain never samples it
    # `clk67_alive` was on bit 14 and read 1 in every run on every build, so it
    # has done its job and gives the bit back.  What is needed now is the same
    # question one layer down: in the failing state `vblank_arrived` is 0, which
    # is the DISPSTAT V-Blank FLAG.  That flag is produced by the GPU's timing
    # generator, so a zero could mean the raster is not running at all, or that
    # it runs and only the flag path is broken.  `st_gpu[2]` latches
    # `|dispstat_dbg[23:16]`, the raw VCOUNT, which advances on every scanline
    # regardless of any flag -- so it separates "GPU dead" from "flag not set".
    dict(name="scanline_run", width=1, value="st_gpu[2]",
         doc="the GPU's raw scanline counter (VCOUNT) has advanced at all"),
    dict(name="mem_ready_clk67", width=1, value="st_mrfast_sync[1]",
         doc="the SDRAM controller acknowledged, latched in its own clk67 domain"),
    # Ladder inside the GPU timing generator, so a frozen VCOUNT can be located
    # rather than guessed at.  Read in order: the first rung that is still 0 names
    # the stage that did not happen.
    #   cycles_100     the cycle counter reached 100   -- it is counting at all
    #   cycles_1008    it reached 1008                -- the VISIBLE->HBLANK threshold
    #   left_visible   the state machine left VISIBLE  -- transitions fire
    # `DBG_gt` is {cycles>=1008, cycles>=100, gpustate!=VISIBLE, reset_released},
    # so index 0 is the release, 1 is "left VISIBLE", 2 is 100 and 3 is 1008.  An
    # earlier revision of this list read index 1 as `cycles_100` and index 2 as
    # `cycles_1008` -- one rung low, and it silently relabelled two hardware
    # readings before the ladder's own ordering exposed it.  The indices here are
    # the packing in `gba_gpu_timing.v`; if that packing changes, this list is
    # wrong and the map id changes with it, which is the only reason the mistake
    # was catchable at all.
    dict(name="gpu_released", width=1, value="st_gpu_step_sync[0]",
         doc="the GPU timing generator saw its reset released at all"),
    dict(name="left_visible", width=1, value="st_gpu_step_sync[1]",
         doc="the GPU's state machine left VISIBLE at any point"),
    dict(name="cycles_100", width=1, value="st_gpu_step_sync[2]",
         doc="the GPU timing generator's cycle counter reached 100"),
    dict(name="cycles_1008", width=1, value="st_gpu_step_sync[3]",
         doc="the GPU timing generator's cycle counter reached 1008, the line length"),
    # The counter reaching 100 but never 1008 is what a RESET that keeps coming
    # back looks like: the counter restarts from zero often enough to pass 100 and
    # never to finish a line.  `gbaon` is the loader's release, and it is what
    # drives the GPU's reset, so a `gbaon` that falls again after rising would
    # produce exactly the observed state.
    dict(name="gbaon_fell", width=1, value="st_gbaon_fell",
         doc="gbaon went low again after having gone high -- the release is not stable"),
]

def map_id():
    """Short stable id for this field list, so a capture can be tied to its layout.

    A decoder generated from one list cannot mislabel a capture built from that
    same list.  It CAN mislabel an older capture, because two layouts may use the
    same bar for different fields -- which happened in this project on 2026-11-02,
    when bar 3 changed from the VBlank IRQ enable to the HBlank flag between
    builds, and again when the loader and SDRAM-acknowledge fields were added to
    the map and every bar above bit 1 moved.

    The id is emitted into the RTL as `PROBE_MAP_ID`.  A capture carries it in a
    sidecar `<capture>.map` written at capture time by the script that flashed the
    build (see `tools/cap_tang.sh`), and `--decode` REFUSES a capture whose
    sidecar names a different map.  A capture with no sidecar decodes with a loud
    UNVERIFIED warning rather than silently, because "no evidence" and "matching
    evidence" are not the same thing.  An earlier version of this docstring
    claimed a capture "decodes only under the map that built it" while the code
    merely printed the current id and decoded regardless; that claim was false,
    and an old capture was misdecoded through it.
    """
    import hashlib
    desc = "|".join(f"{f['name']}:{f['width']}:{f['value']}" for f in FIELDS)
    return hashlib.sha256(desc.encode()).hexdigest()[:8]


def widths_ok():
    """True when the declared widths fill the probe word exactly."""
    return sum(f["width"] for f in FIELDS) == PROBE_WIDTH


def offsets():
    """[(field, lsb)] in declaration order, bit 0 first."""
    out, lsb = [], 0
    for f in FIELDS:
        out.append((f, lsb))
        lsb += f["width"]
    return out


def emit_verilog():
    """The include: offsets, widths, a measured width guard, and the assign macro."""
    L = []
    L.append("// GENERATED by tools/probe_map.py --emit-verilog -- do not edit.")
    L.append("//")
    L.append("// RTL half of the probe field map.  The host decoder is generated from")
    L.append("// the same list by tools/probe_map.py --decode, so the packing order")
    L.append("// here and the order the decoder reads cannot disagree.  Bar i is bit i.")
    L.append("")
    total = 0
    for f in FIELDS:
        lsb = total
        hi = lsb + f["width"] - 1
        total += f["width"]
        rng = f"{lsb}" if f["width"] == 1 else f"{hi}:{lsb}"
        L.append(f"localparam PROBE_{f['name'].upper()}_LSB = {lsb};")
        L.append(f"localparam PROBE_{f['name'].upper()}_WIDTH = {f['width']};"
                 f"   // bits {rng}: {f['doc']}")
    args = ", ".join(f["value"] for f, _ in reversed(offsets()))
    L.append("")
    L.append(f"localparam PROBE_BUS_WIDTH = {PROBE_WIDTH};")
    L.append(f'localparam PROBE_MAP_ID = 32\'h{map_id()};'
             f'   // decode captures with the map that built them')
    L.append("// The guard MEASURES the packing expression rather than restating the")
    L.append("// generator's own arithmetic.  `$bits` of the concatenation is compared")
    L.append("// against the bus width, so if any source expression ever changes width")
    L.append("// -- or the packing is hand-edited to drop a field -- the build stops")
    L.append("// here instead of shipping a readout that has to be decoded around.")
    L.append("// Verified 2026-11-02 by comparing against a deliberately wrong constant")
    L.append("// and watching elaboration fail with `unknown module`.")
    L.append(f"localparam PROBE_PACK_WIDTH = $bits({{ {args} }});")
    L.append("generate")
    L.append("  if (PROBE_PACK_WIDTH != PROBE_BUS_WIDTH) begin : probe_width_error")
    L.append("    // Deliberately undefined module: slang rejects $error, yosys drops a")
    L.append("    // blackboxed module silently, but an unknown module is a hard error.")
    L.append("    probe_pack_width_does_not_match_the_probe_bus_width u_width_err();")
    L.append("  end")
    L.append("endgenerate")
    L.append("")
    L.append("`define TINYGBA_PROBE_ASSIGN \\")
    L.append(f"    st_dbg <= {{ {args} }};")
    return "\n".join(L) + "\n"


# ------------------------------------------------------------------ decoding
def bar_bits_from_frame(path):
    """Measure the sixteen bars from a capture and return the bit string.

    Geometry is measured from the frame rather than assumed: the picture window
    sits between the letterbox and/or pillarbox bars, and a decoder that assumes
    the bars span the full capture width returns garbage whenever a pillarbox is
    present -- the failure the SNES project records twice.
    """
    from PIL import Image
    im = Image.open(path).convert("RGB")
    W, H = im.size
    y = H // 2
    row = [im.getpixel((x, y)) for x in range(W)]
    runs, cur, st = [], row[0], 0
    for x in range(1, W):
        if row[x] != cur:
            runs.append((st, x - 1, cur)); cur, st = row[x], x
    runs.append((st, W - 1, cur))
    segs = [r for r in runs if r[1] - r[0] > 3]
    if len(segs) < 3:
        raise SystemExit(f"{path}: only {len(segs)} colour runs; not a probe frame")
    # Exclude the letterbox (very dark) and the probe's own grey margin.
    #
    # By TOLERANCE, not by membership in a short list of exact greys.  An earlier
    # version tested `c[0] == c[1] == c[2] and c[0] in (0, 34, 43, 127, 135)`,
    # and the capture card's MJPEG encoder renders the 135-grey margin as
    # `(134,134,134)` at some columns.  134 is not in that list, so a strip of
    # margin counted as field and inflated the measured field edge by about 40
    # display pixels.  Every bar centre was then shifted right, the last bar was
    # sampled inside the margin, and it read as a zero.  That produced a
    # contradictory hardware decode -- a clk67-domain latch reporting 0 where the
    # clk16-domain latch of the SAME signal reported 1, which is impossible and is
    # what exposed the bug.  A near-neutral pixel is either margin or letterbox;
    # neither is a probe field, and compression noise must not change the answer.
    def is_field(c):
        r, g, b = c[0], c[1], c[2]
        if abs(r - g) <= 10 and abs(g - b) <= 10 and abs(r - b) <= 10:
            return False        # any near-neutral grey: margin or letterbox
        return True
    body = [s for s in segs if is_field(s[2])]
    if not body:
        raise SystemExit(f"{path}: no field pixels found")
    left, right = min(s[0] for s in body), max(s[1] for s in body)
    # Sample each bar at the centre of the span the RENDERER actually draws, not
    # by dividing the field into sixteen equal bands.  The renderer
    # (`gba2hdmi.sv`, `st_colour`) computes `dbg_bits[x / 15]` for `x < 232`, so
    # bar i covers source pixels [15i, 15i+15) and the LAST bar is truncated to
    # 7 pixels at [225, 232).  The field is therefore 232 source pixels, not a
    # multiple of 16, and an even 16-way split samples the last band roughly one
    # bar to the left: bit 15 was decoded from bar 14's colour.  That is not a
    # cosmetic error -- it silently reports one field's value under another
    # field's name, which is exactly the failure this tool exists to prevent, and
    # it produced a wrong hardware conclusion on 2026-11-02 (a `mem_ready` of 0
    # that was really a mis-sampled bar) before being caught by sampling the raw
    # pixels by hand.
    FIELD_SRC = 232          # x < 232 in gba2hdmi.sv
    BAR_W     = 15           # dbg_bits[x / 15]
    scale = (right - left + 1) / FIELD_SRC
    bits = []
    for i in range(PROBE_WIDTH):
        sx0 = i * BAR_W
        sx1 = min(sx0 + BAR_W, FIELD_SRC)
        if sx0 >= FIELD_SRC:
            raise SystemExit(f"{path}: field runs out before bar {i}")
        centre = (sx0 + sx1) / 2.0
        # Two samples per bar, a quarter and three quarters across, so a bar that
        # is only half drawn (or a capture that is mid-resync) is caught rather
        # than averaged into a plausible bit.
        votes = []
        for frac in (0.25, 0.5, 0.75):
            sxc = sx0 + (sx1 - sx0) * frac
            x = int(left + sxc * scale)
            c = im.getpixel((x, y))
            votes.append(1 if (c[1] > 200 and c[0] < 60) else 0)
        if len(set(votes)) > 1:
            c = im.getpixel((int(left + centre * scale), y))
            sys.stderr.write(
                f"probe_map: WARNING {path}: bar {i} (bit {i}) disagrees across "
                f"its span {votes}, colour {c}; using the majority\n")
        bits.append(1 if sum(votes) * 2 >= len(votes) else 0)
    return bits


def read_capture_map(path):
    """Return the map id recorded beside a capture, or None if it has none."""
    try:
        with open(path + ".map") as f:
            return f.read().strip().split()[0]
    except (OSError, IndexError):
        return None


def decode_bits(bits):
    """Turn a 16-entry list of bar bits (index = bit number) into fields."""
    word = 0
    for i, b in enumerate(bits):
        if b:
            word |= 1 << i
    out = []
    for f, lsb in offsets():
        hi = lsb + f["width"] - 1
        v = (word >> lsb) & ((1 << f["width"]) - 1)
        out.append((f, lsb, hi, v))
    return word, out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--emit-verilog", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--map-id", action="store_true",
                    help="print this tree's map id, for a build to record")
    ap.add_argument("--decode", metavar="FRAME")
    ap.add_argument("--barbits", metavar="BITS",
                    help="decode a literal bit string, leftmost char = bar 0")
    ap.add_argument("--json", action="store_true", help="machine-readable decode")
    args = ap.parse_args()

    if args.list:
        total = 0
        print(f"probe word is {PROBE_WIDTH} bits; bar i shows bit i")
        print(f"field map id {map_id()}")
        print("  --decode refuses a capture whose .map sidecar names another "
              "map, and warns when it has none\n")
        print(f"  {'field':20s} {'bits':>8s}  source")
        for f in FIELDS:
            lsb = total; hi = lsb + f["width"] - 1
            total += f["width"]
            rng = f"{lsb}" if f["width"] == 1 else f"{hi}:{lsb}"
            print(f"  {f['name']:20s} {rng:>8s}  {f['value']}")
        print(f"\n  {'TOTAL':20s} {total:>8d}   (must equal {PROBE_WIDTH})")
        return 0

    if args.emit_verilog:
        import pathlib
        p = pathlib.Path(__file__).resolve().parent.parent / INCLUDE_PATH
        p.write_text(emit_verilog())
        print(f"wrote {p.relative_to(p.parents[3])}")
        return 0

    if args.check:
        import pathlib
        p = pathlib.Path(__file__).resolve().parent.parent / INCLUDE_PATH
        want = emit_verilog()
        have = p.read_text() if p.exists() else ""
        if have != want:
            print(f"{INCLUDE_PATH} is stale; run --emit-verilog", file=sys.stderr)
            return 1
        print(f"{INCLUDE_PATH} matches the field map")
        return 0

    bits = None
    if args.barbits:
        s = args.barbits.replace(",", "").replace(" ", "")
        if len(s) != PROBE_WIDTH or set(s) - set("01"):
            raise SystemExit(f"expected {PROBE_WIDTH} characters of 0/1, got {s!r}")
        bits = [int(c) for c in s]
    elif args.map_id:
        print(map_id())
        return 0

    if args.decode:
        bits = bar_bits_from_frame(args.decode)
    if bits is None:
        ap.print_help()
        return 2

    # Refuse to decode a capture that names a different map, and say so loudly when
    # a capture names no map at all.  Printing the current id is not a check: it
    # labels the capture with whatever map is loaded now, which is precisely the
    # mistake this guard exists to stop.
    want = map_id()
    got = read_capture_map(args.decode)
    if got is not None and got != want:
        sys.stderr.write(
            f"probe_map: REFUSING to decode {args.decode}\n"
            f"  capture was built with map {got}\n"
            f"  this tree's map is       {want}\n"
            f"  re-capture from a build made with the current map, or decode\n"
            f"  with the tree that built that capture.\n")
        return 3
    if got is None:
        sys.stderr.write(
            f"probe_map: UNVERIFIED -- {args.decode} has no .map sidecar, so it\n"
            f"  cannot be shown to match this tree's map {want}.  Treat the\n"
            f"  field names below as unconfirmed.\n")

    word, fields = decode_bits(bits)
    if args.json:
        print(json.dumps({"word": word, "bits": bits,
                          "fields": {f["name"]: v for f, _, _, v in fields}},
                         indent=2))
        return 0
    print(f"field map id {map_id()}")
    print(f"bars (bar 0 leftmost): {''.join(str(b) for b in bits)}")
    print(f"word: 0x{word:04X}\n")
    for f, lsb, hi, v in fields:
        rng = f"bit {lsb}" if lsb == hi else f"bits {hi}:{lsb}"
        shown = (f"{v}") if f["width"] == 1 else (f"{v} (0x{v:0{(f['width']+3)//4}X})")
        print(f"  {f['name']:20s} {rng:>10s}  = {shown:12s} {f['doc']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
