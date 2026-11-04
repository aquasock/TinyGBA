#!/usr/bin/env python3
"""Refuse a netlist that clocks one edge of a clock two different ways.

Why this exists.  For GW5A, yosys' synth_gowin keeps only a plain negedge flop
(no enable, no reset) as a true DFFN.  Every other negedge flop is legalised to
a posedge DFFRE whose clock is a LUT1 inverter of the real clock, and that
inverted clock reaches its flops on fabric routing, several ns after the
global clock.  nextpnr treats the inverter output as an unrelated clock and
does not time paths between it and the true negedge flops.

When both kinds sit on the same clock, logic meant to change on one negedge is
split across two edges a few ns apart, with no hold check between them.  That
stopped the SuperFX on the board in the sibling TinySNES project (its
core-log entry 88, recorded there as TCL-020): the GSU's EN was the one true
DFFN while its PEND/WAIT handshake flops sat on the inverted clock, so they
sampled EN after it had already changed and the coprocessor deadlocked on its
first ROM load.  The symptom on hardware looked like a logic deadlock, not a
timing failure, and a bench with ideal clocks could not see it.

TinyGBA had no equivalent gate, so its netlists were never checked for the
class.  Measured 2026-11-04 on build/drw3_1: zero DFFN cells and no flop or
BRAM clock pin driven by fabric logic, so this tree is currently clean.  The
gate exists to keep it that way rather than to fix a present fault, which is
exactly the kind of thing that rots if it is only ever a one-off grep.

    tools/clock_edge_check.py build/x/tinygba.json

Reads the synthesised netlist, before place and route: that is where the
legalisation has already happened and where the inverted clock net is still
visible by name.

Exit status is 0 when no clock net drives both a true negedge primitive and a
LUT clock inverter, 1 when one does, and 2 on a usage or parsing problem.
"""
import json
import re
import sys

# Gowin's primitives spell the clock input CLK on fabric flops and CLKA/CLKB on
# the block RAMs, so the inverter has to be followed into both.
CLOCK_PIN = re.compile(r"^CLK[AB]?$")


def _bits(value):
    """Yield the integer bit ids in a yosys connection value, skipping constants."""
    if isinstance(value, int):
        yield value
    elif isinstance(value, list):
        for v in value:
            if isinstance(v, int):
                yield v


def _param(cell, name):
    v = cell.get("parameters", {}).get(name, "")
    return v


def is_inverter(cell):
    if cell.get("type") != "LUT1":
        return False
    # yosys writes INIT as a binary string, MSB first: F = INIT[I0], so an
    # inverter is "01".  Accept the integer spelling as well.
    init = _param(cell, "INIT")
    return str(init) in ("01", "1")


def check(path, stream=sys.stderr):
    """Return a list of (clock name, module, negedge count, inverter count)."""
    with open(path) as f:
        modules = json.load(f)["modules"]

    failures = []
    for mname, mod in modules.items():
        cells = mod.get("cells", {})
        if not cells:
            continue

        # Bit ids are per module in the yosys JSON, so resolve names inside the
        # module rather than across it.
        names = {}
        for n, v in mod.get("netnames", {}).items():
            for b in v.get("bits", []):
                if not isinstance(b, int):
                    continue
                key = (n.startswith("$"), n.count("."), len(n))
                if b not in names or key < names[b][0]:
                    names[b] = (key, n)
        names = {b: n for b, (_, n) in names.items()}

        clock_bits = set()
        negedge = {}
        for cn, c in cells.items():
            for p, bits in c.get("connections", {}).items():
                if not CLOCK_PIN.match(p):
                    continue
                for b in _bits(bits):
                    clock_bits.add(b)
                    if c.get("type", "").startswith("DFFN") and p == "CLK":
                        negedge.setdefault(b, []).append(cn)

        inverted = {}
        for cn, c in cells.items():
            if not is_inverter(c):
                continue
            srcs = list(_bits(c.get("connections", {}).get("I0")))
            outs = list(_bits(c.get("connections", {}).get("F")))
            for out in outs:
                if out in clock_bits:
                    for src in srcs:
                        inverted.setdefault(src, []).append(cn)

        for b in sorted(set(negedge) & set(inverted), key=str):
            failures.append((names.get(b, str(b)), mname,
                             len(negedge[b]), len(inverted[b])))
            name = names.get(b, str(b))
            print(f"clock_edge_check: '{name}' in {mname} clocks "
                  f"{len(negedge[b])} true negedge flop(s) and also feeds "
                  f"{len(inverted[b])} LUT clock inverter(s)", file=stream)
            for cn in negedge[b][:8]:
                print(f"    true negedge: {cn}", file=stream)
            for cn in inverted[b][:8]:
                outs = list(_bits(cells[cn].get("connections", {}).get("F")))
                label = names.get(outs[0], "?") if outs else "?"
                print(f"    inverter:     {cn} -> '{label}'", file=stream)

    return failures


def main():
    if len(sys.argv) != 2:
        print("usage: clock_edge_check.py <synthesised netlist .json>",
              file=sys.stderr)
        return 2
    try:
        failures = check(sys.argv[1])
    except (OSError, ValueError, KeyError) as e:
        print(f"clock_edge_check: cannot read {sys.argv[1]}: {e}", file=sys.stderr)
        return 2

    if failures:
        print("clock_edge_check: FAILED -- give the true negedge flop(s) a "
              "synchronous reset or enable so they join the inverted clock",
              file=sys.stderr)
        return 1

    print("    clock edges: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
