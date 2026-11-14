#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Report which memories the synthesiser put in distributed RAM, and refuse a regression.

Why this exists.  `synth_gowin` decides a small array's resource on its own, and the
decision is invisible in the RTL: it appears only as a `mapping memory ... via
$__GOWIN_LUTRAM_` line in the synthesis log and as `RAM16SDP4` cells in the netlist.
On this design it already disagrees with the source.  `gpu/linebuffer.v` asks for
block RAM by writing `/* synthesis syn_ramstyle = "block_ram" */` under `` `ifdef
M138K ``, and `M138K` is defined for this board, yet
`gpu.drawer.linebuf_obj_settings` -- the one line buffer that is 4 bits wide -- is
mapped to LUT RAM with its read register absorbed (`Extracted data FF from read
port 0`).  See TCL-033.  Comment-form attributes are not parsed by this flow's
`read_slang` front end, which is the same failure the port hit when thirteen
`(* keep *)` marks in `gba_memory.sv` turned out to be inert.

Why the rule is "any distributed RAM is a finding" rather than "no distributed
RAM".  The sibling `fpt/tang-tiny-gpu` project records that distributed RAM built
by these open tools misbehaved on real hardware while passing Verilator, and its
answer is `synth_gowin -nolutram` so that small arrays become flip-flops and large
ones block RAM.  That is a heavier change than this project should adopt
unexamined, because it also moves four sound arrays and the loader buffer.  So this
gate does not force the mapping: it prints the census, and fails only when an array
appears or disappears relative to a recorded baseline.  A deliberate change to the
mapping is then a baseline update, which is a visible act with a diff.

Usage:

    tools/memory_census.py build/x/tinygba.json                 # report
    tools/memory_census.py build/x/tinygba.json --check         # fail on drift
    tools/memory_census.py build/x/tinygba.json --update-baseline

Exit status: 0 when the census matches the baseline or no baseline exists, 1 on
drift under --check, 2 on bad input.
"""
import argparse
import collections
import json
import os
import sys

BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory_baseline.json")

# Cells that indicate a memory was placed in distributed (LUT) RAM rather than
# block RAM.  RAM16SDP4 is the GW5A single-port LUT RAM the open flow emits.
LUTRAM_CELLS = ("RAM16SDP4", "RAM16SDP", "RAM32X4", "RAM64X2")
BSRAM_CELLS = ("DPB", "SDPB", "DPX9B", "SDPX9B", "SP", "DP16KD")


def array_of(cell_name):
    """The array path from a flattened netlist cell name.

    A placed memory keeps its hierarchy in the cell name and appends a slice
    index, e.g. `gpu.drawer.linebuf_obj_settings.ram.0.10`, so dropping trailing
    all-numeric components groups the 64 LUT-RAM slices of that one array back
    into the array.  Without this the census is 66 indistinguishable cells in a
    flattened top and says nothing about which array moved.
    """
    parts = cell_name.split(".")
    while len(parts) > 1 and parts[-1].isdigit():
        parts.pop()
    return ".".join(parts)


def census(path):
    """Return {array_path: {cell_type: count}} for the whole netlist."""
    with open(path) as f:
        design = json.load(f)
    modules = design.get("modules", {})
    if not modules:
        raise ValueError("no modules in the netlist")
    arrays = collections.defaultdict(collections.Counter)
    for mod in modules.values():
        for name, cell in mod.get("cells", {}).items():
            t = cell.get("type")
            if t in LUTRAM_CELLS or t in BSRAM_CELLS:
                arrays[array_of(name)][t] += 1
    return dict(arrays)


def summarise(arrays):
    """({cell_type: count}, [(array, n_cells, {type: count})] for LUT-RAM arrays)."""
    total = collections.Counter()
    lut = []
    for path, cells in arrays.items():
        total.update(cells)
        if any(t in LUTRAM_CELLS for t in cells):
            lut.append((path, sum(cells.values()), dict(cells)))
    return total, sorted(lut, key=lambda r: (-r[1], r[0]))


def main(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("netlist")
    ap.add_argument("--check", action="store_true",
                    help="exit 1 when the census differs from the baseline")
    ap.add_argument("--update-baseline", action="store_true",
                    help="record this census as the baseline")
    ap.add_argument("--key", default=None,
                    help="baseline key; defaults to the netlist's own name")
    args = ap.parse_args(argv[1:])

    try:
        arrays = census(args.netlist)
        total, lut_arrays = summarise(arrays)
    except (OSError, json.JSONDecodeError, ValueError) as e:
        print(f"cannot read {args.netlist}: {e}", file=sys.stderr)
        return 2

    key = args.key or os.path.basename(os.path.dirname(os.path.abspath(args.netlist)))

    lut_total = sum(v for t, v in total.items() if t in LUTRAM_CELLS)
    bsram_total = sum(v for t, v in total.items() if t in BSRAM_CELLS)
    print(f"netlist: {args.netlist}")
    print(f"  distributed RAM cells: {lut_total}")
    print(f"  block RAM cells:       {bsram_total}")
    if lut_total:
        print("  arrays in distributed RAM:")
        for path, n, cells in lut_arrays:
            print(f"    {path:52} {n:4} {cells}")
        print("  Distributed RAM is a finding on this project (TCL-033):"
              " the RTL may have asked for block RAM and not been heard, and the"
              " sibling project records this resource misbehaving on hardware.")

    base = {}
    if os.path.exists(BASELINE):
        with open(BASELINE) as f:
            base = json.load(f).get("census", {})
    current = {path: dict(sorted(c.items())) for path, c in sorted(arrays.items())}

    if args.update_baseline:
        base[key] = current
        with open(BASELINE, "w") as f:
            json.dump({"note": "recorded by tools/memory_census.py; a change here is"
                               " a deliberate change of memory placement",
                       "census": base}, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"baseline updated for {key!r} in {BASELINE}")
        return 0

    if key not in base:
        print(f"no baseline for {key!r}; recording one is a deliberate act:")
        print(f"  tools/memory_census.py {args.netlist} --key {key} --update-baseline")
        return 0

    was, now = base[key], current
    if was == now:
        print(f"census matches the baseline for {key!r}")
        return 0

    # Compare per array and per cell type, so a diff names the array that moved
    # rather than only the total.  A total can stay constant while two arrays
    # swap resources, and that is exactly the kind of change this gate is for.
    def flat(c):
        return {(path, cell): n for path, cells in c.items() for cell, n in cells.items()}

    was_f, now_f = flat(was), flat(now)
    print(f"census DIFFERS from the baseline for {key!r}")
    for k in sorted(set(now_f) | set(was_f)):
        a, b = now_f.get(k, 0), was_f.get(k, 0)
        if a != b:
            path, cell = k
            print(f"  {path:52} {cell:10} {b} -> {a}")
    if args.check:
        print("refusing: memory placement changed; update the baseline if intended",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
