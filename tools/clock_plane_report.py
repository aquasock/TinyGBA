#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Report which clock-plane bridge pip each clock takes, and flag the ones that cannot clock.

Why this exists.  A clock reaches the GW5AST-138C's global network by leaving a
spine mux through a bridge pip, and the pips are not interchangeable: some clock
every flip-flop on the branches they feed, some clock none of them, and which one
a clock gets is decided by nextpnr at placement time and is invisible in the
timing report and in the hold check.  TinySNES learned this the expensive way --
two builds of identical source, both hold-clean, both passing Fmax, one booting
deterministically over ten boots and the other leaving the cartridge on every
boot, differing only in which spine the master clock took (its BRD-005).  This
project has no such gate, and its deploy criterion has been hold-clean plus Fmax,
which that result shows is not sufficient.

The pip table below is inherited, not measured here, and the provenance is
carried with every entry:

  * TinyNES measured the PLL-source half and the HCLK CLKDIV-source half
    separately on this board and recorded them as DEV-009 and DEV-017; TinySNES
    carries the same table in its core-reference and gates its own builds on it.
  * The `own` rows are this project's hardware results, read from the routed
    netlist of the image that produced them, so a later build can be compared
    against a placement that is known to have worked.

Nothing in the table is a claim about the silicon beyond what a capture card
showed.  Anything absent is UNMEASURED, which is not the same as broken.

    tools/clock_plane_report.py build/x/tinygba-routed.json
    tools/clock_plane_report.py ... --strict      fail on unmeasured and partial

Exit status: 0 when every clock is on a pip fully measured good, 1 when a clock
is on a pip measured dead or (under --strict) on one that is not fully measured,
2 on a usage or parsing problem.
"""
import argparse
import json
import re
import sys

# Verdicts, strongest first.  `partial` exists because a small self-test clocking
# its own handful of flip-flops is real evidence that a pip reaches the fabric,
# and is not evidence that it reaches 2381 sinks spread across the die.  Collapsing
# the two is exactly how an instrument reports a false pass.
GOOD = "good"
PARTIAL = "partial"
DEAD = "dead"
UNMEASURED = "unmeasured"

RANK = {GOOD: 0, PARTIAL: 1, UNMEASURED: 2, DEAD: 3}

# The rule is SOURCE-DEPENDENT, and conflating the two sources is the mistake
# TinySNES's first version of this tool made.  A clock out of a PLL and a clock
# out of an HCLK CLKDIV block enter the plane through different pips with
# different verdicts.
#
# Inherited from TinyNES DEV-009 (PLL source), DEV-017 (CLKDIV source), read out
# of TinySNES's core-reference 2026-11-02.  Not measured on this project's board.
INHERITED = {
    # PLL-sourced clock.
    ("pll", "SPINE8",  "CBRIDGEOUT_TOP0"): GOOD,      # DEV-009: ran
    ("pll", "SPINE10", "CBRIDGEOUT_TOP2"): GOOD,      # DEV-009: ran
    ("pll", "SPINE16", "CBRIDGEOUT_BOTTOM0"): DEAD,   # DEV-009: silent
    ("pll", "SPINE25", "CBRIDGEOUT_BOTTOM0"): DEAD,   # DEV-009: silent
    ("pll", "SPINE1",  "CBRIDGEOUT_BOTTOM0"): DEAD,   # DEV-009: silent
    # HCLK CLKDIV-sourced clock.
    ("clkdiv", "SPINE18", "CBRIDGEOUT_BOTTOM2"): GOOD,  # DEV-017: clocks every flop
    ("clkdiv", "SPINE26", "CBRIDGEOUT_BOTTOM2"): GOOD,  # DEV-017: clocks every flop
    ("clkdiv", "SPINE16", "CBRIDGEOUT_BOTTOM0"): DEAD,  # DEV-017: clocks nothing
    ("clkdiv", "SPINE17", "CBRIDGEOUT_BOTTOM0"): DEAD,  # DEV-017: clocks nothing
    ("clkdiv", "SPINE18", "CBRIDGEOUT_TOP1"): DEAD,     # DEV-017: dead 8 of 8 seeds
}

# Measured on THIS board by THIS project, with the image that produced the result
# named, because that is the only way a later build can be compared against it.
#
# core-log entry 5: `01_video` (build/vsweep_5) drew eight bars in the correct
# order with the orientation marker and the right-hand band, on a locked 720p
# picture.  That clock plan is recorded here as the reference placement.
OWN = {
    # clk50 draws the test pattern's raster, so its pips clocked real work.
    # build/vsweep_5: SPINE16/TOP0, SPINE24/TOP0, SPINE25/TOP1.
    ("pll", "SPINE16", "CBRIDGEOUT_TOP0"): GOOD,
    ("pll", "SPINE24", "CBRIDGEOUT_TOP0"): GOOD,
    ("pll", "SPINE25", "CBRIDGEOUT_TOP1"): GOOD,
    # hclk is the 74.25 MHz pixel clock, made by div5 from the HDMI PLL's 5x
    # output, so it is a CLKDIV source.  build/vsweep_5 used these three.
    ("clkdiv", "SPINE19", "CBRIDGEOUT_BOTTOM2"): GOOD,
    ("clkdiv", "SPINE25", "CBRIDGEOUT_BOTTOM2"): GOOD,
    ("clkdiv", "SPINE26", "CBRIDGEOUT_BOTTOM2"): GOOD,
    # clk16 at TOP2 is PARTIAL on purpose.  `02_sdram` (build/diag_sdram_s2)
    # clocked `sdram_probe`'s state machine with it and the probe reached `done`
    # and drew a green status band (core-log entry 5), so the pip reaches the
    # fabric.  The probe is a few hundred flip-flops in one place; the machine is
    # 2381 `clk16` sinks spread across the die, and no build has shown this pip
    # clocking those.  Do not promote this to GOOD without a running machine.
    ("pll", "SPINE1",  "CBRIDGEOUT_TOP2"): PARTIAL,
    ("pll", "SPINE2",  "CBRIDGEOUT_TOP2"): PARTIAL,
    ("pll", "SPINE18", "CBRIDGEOUT_TOP2"): PARTIAL,
    ("pll", "SPINE26", "CBRIDGEOUT_TOP2"): PARTIAL,
    ("pll", "SPINE27", "CBRIDGEOUT_TOP2"): PARTIAL,
    ("pll", "SPINE28", "CBRIDGEOUT_TOP2"): PARTIAL,
}

# Which source a clock is.  `hclk` is the only clock in this design made by an
# HCLK CLKDIV block; everything else on the plane comes straight out of a PLL.
# A clock this tool cannot classify is reported as unclassified rather than
# guessed at.
CLKDIV_SOURCES = {"hclk"}

# Clocks that never reach the plane, and are not supposed to need it.  `sysclk` is
# the input oscillator; `clk27` feeds a PLL and the PLL's output is the clock;
# `clk67_p` leaves the FPGA as O_sdram_clk; `hclk5` takes the FCLKA dedicated
# high-speed lane from the HDMI PLL to the three OSER10 serialisers, which is the
# correct path for it rather than a fallback.
NO_PLANE_EXPECTED = {"sysclk", "clk27", "clk67_p", "hclk5"}

# The clocks fpga/gba/tinygba.sdc constrains and that must reach the plane.  A net
# here with no bridge pip is on general routing, which is the fault the clk67 work
# of core-log entry 4 removed and which no timing report shows.
REQUIRED_PLANE = ("clk16", "clk50", "clk67", "hclk")


def classify(name):
    if name in CLKDIV_SOURCES:
        return "clkdiv"
    return "pll"


def verdict(src, pip):
    if (src,) + pip in OWN:
        return OWN[(src,) + pip], "this project"
    if (src,) + pip in INHERITED:
        return INHERITED[(src,) + pip], "TinyNES via TinySNES"
    return UNMEASURED, "no record"


def clock_routes(top):
    """Yield (net_name, [(spine, bridge_pin)]) for every clock net crossing a bridge."""
    for name, info in top.get("netnames", {}).items():
        route = info.get("attributes", {}).get("ROUTING", "")
        if not route or "CBRIDGE" not in route:
            continue
        pips = []
        # A bridge pip appears as "<x>Y<y>/SPINE<n>/CBRIDGEOUT_<half><k>".
        for m in re.finditer(r"/SPINE(\d+)/(CBRIDGEOUT_(?:TOP|BOTTOM)\d)", route):
            pip = (f"SPINE{m.group(1)}", m.group(2))
            if pip not in pips:
                pips.append(pip)
        yield name, sorted(pips)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("routed_json")
    ap.add_argument("--strict", action="store_true",
                    help="also fail when a clock is on a pip only partially "
                         "measured or never measured")
    ap.add_argument("--quiet", action="store_true",
                    help="print only the summary and the failures")
    args = ap.parse_args()

    try:
        with open(args.routed_json) as f:
            design = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot read {args.routed_json}: {e}", file=sys.stderr)
        return 2

    modules = design.get("modules", {})
    if not modules:
        print(f"{args.routed_json}: no modules in the netlist", file=sys.stderr)
        return 2
    # A routed netlist carries one module: the top, flattened by nextpnr.
    top = next(iter(modules.values()))

    worst = {}
    dead, partial, unmeasured = [], [], []
    routed_any = False

    for name, pips in sorted(clock_routes(top)):
        src = classify(name)
        routed_any = True
        cells = []
        worst_state = GOOD
        for pip in pips:
            state, origin = verdict(src, pip)
            if RANK[state] > RANK[worst_state]:
                worst_state = state
            cells.append(f"{pip[0]}/{pip[1].replace('CBRIDGEOUT_', '')}"
                         f"={state}[{origin}]")
        # A net feeding a PLL's reference input is not a design clock: it reaches
        # the plane, the PLL's own output is what clocks logic, and that output is
        # checked under its own name.  Reported, never gated.
        if name.endswith(".clkin"):
            if not args.quiet:
                print(f"  {name:11s} [(feed)] " + ", ".join(cells) + "  -- not gated")
            continue
        if not args.quiet:
            print(f"  {name:11s} [{src:6s}] " + ", ".join(cells))
        worst[name] = worst_state
        if worst_state == DEAD:
            dead.append((name, cells))
        elif worst_state == PARTIAL:
            partial.append((name, cells))
        elif worst_state == UNMEASURED:
            unmeasured.append((name, cells))

    if not routed_any:
        print("no clock net crosses a clock-plane bridge pip; nothing to check")
        return 0

    # A clock that reaches the plane on no pip at all is on general routing, which
    # is the fault the `clk67` work of core-log entry 4 removed: 255 sinks, 1.2 to
    # 1.9 ns of skew, and a seed-dependent hold failure.  It is worse than an
    # unmeasured pip and must never pass silently.
    general = [n for n in REQUIRED_PLANE
               if n not in worst and n not in NO_PLANE_EXPECTED
               and n in top.get("netnames", {})]

    print()
    if general:
        for name in general:
            print(f"NO PLANE PIP: '{name}' crosses no bridge pip, so it is on general "
                  f"routing", file=sys.stderr)

    for name, cells in dead:
        print(f"DEAD PIP: '{name}' is on a bridge pip measured as clocking nothing: "
              + ", ".join(cells), file=sys.stderr)

    if dead:
        print("On that pip the flip-flops behind it hold power-up 0 "
              "(TinyNES DEV-009, DEV-017).", file=sys.stderr)
    if general:
        print("A clock on general routing reaches its sinks point to point, with no "
              "skew guarantee: 255 sinks and 1.2 to 1.9 ns of skew is what this "
              "design measured before core-log entry 4 (TCL-004, TCL-005).",
              file=sys.stderr)
    if dead or general:
        return 1

    if partial or unmeasured:
        n = len(partial) + len(unmeasured)
        print(f"{n} clock(s) are not on a fully measured-good path.")
        if partial:
            print("  partially measured -- a small domain clocked on this pip, a wide "
                  "one never has:")
            for name, cells in partial:
                print(f"    {name}: " + ", ".join(cells))
        if unmeasured:
            print("  never measured on this board:")
            for name, cells in unmeasured:
                print(f"    {name}: " + ", ".join(cells))
        print("Measured-good paths on this board, for comparison:")
        for (src, sp, br), state in sorted(OWN.items()):
            if state == GOOD:
                print(f"    {src:6s} {sp}/{br.replace('CBRIDGEOUT_', '')}  (this project)")
        print("A clock on an unmeasured pip may be fine and may be silent; nothing has "
              "shown it either way.")
        if args.strict:
            print("Refusing under --strict.  A hardware result read from this placement "
                  "cannot be attributed to the design rather than to the pip.",
                  file=sys.stderr)
            return 1
        print("(not failing: this gate fails on dead pips and on general routing; "
              "pass --strict to fail on these too)")
        return 0

    print("Every clock is on a fully measured-good bridge pip.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
