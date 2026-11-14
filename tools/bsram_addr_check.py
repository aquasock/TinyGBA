#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Report dual-port BSRAM address ports that are driven through logic, not flops.

Why this exists.  nextpnr's Gowin timing model does not check the setup path into
a true dual-port BSRAM's B-port address (`ADB`): the pin is registered under a
different cell class in `gowin_arch_gen.py`.  A path can therefore meet timing in
the report and still fail on the board, and whether it does depends on the
placement.  The sibling `fpt/tang-tiny-gpu` project found this, reproduces it in
`tools/repro/nextpnr_gowin_timing`, and checks it with `scripts/bsram_check.py`,
which requires every `ADA`/`ADB` bit to come from a flip-flop `Q` or a constant.
TCL-035 records the finding and this project's census under it.

Why this version reports depth rather than a pass/fail on "any logic at all".
Their design drives `ADB` from flops throughout, so a binary check is right for
them.  On this design 994 address bits are logic-driven, the overwhelming
majority on the *modelled* `ADA` port, and a binary check would fail every build
and be turned off.  What matters on the unmodelled port is whether a cone is deep
enough to be at risk, so this reports the depth distribution and flags only cones
deeper than a bound.  The depth is in LUT/MUX levels between the port and the
nearest flip-flop, which is a proxy for delay and not a timing number: the gate
cannot know the routed delay, because that is the very quantity nextpnr omits.

Usage:

    tools/bsram_addr_check.py build/x/tinygba.json                # report
    tools/bsram_addr_check.py build/x/tinygba.json --max-depth 8  # fail deeper
    tools/bsram_addr_check.py build/x/tinygba.json --port ADB     # B port only

Exit status: 0 within the bound, 1 when a cone exceeds it, 2 on bad input.
"""
import argparse
import collections
import json
import sys

DP_TYPES = {"DPX9B", "DPB", "DPX9", "DP"}
FF_PREFIX = "DFF"
CONST_TYPES = {"GND", "VCC"}

# Depth is always measured against this fixed generous cap and the bound is only
# compared afterwards.  Tying the cap to `--max-depth` clipped every report to
# `bound + 4`, so a 42-level cone was reported as "12" and a "deepest 44" that was
# really the cap read like a measurement.  A reported depth has to be the depth.
MEASURE_CAP = 96

# Cells the traversal may walk *through*.  Anything else is a boundary: a flop,
# a constant, a memory whose output is registered, an I/O buffer, or a primitive
# this tool does not model.  The first version of this only stopped at `DFF*`,
# constants and unknown nets, which meant it walked into BSRAMs -- whose outputs
# are registered -- and so never reached a flop.  Every `ADB` cone then ran to the
# cap and the tool reported a 40-level path that does not exist.  Naming the
# combinational set explicitly, rather than blacklisting flops, is what makes the
# depth mean "logic levels between the port and the nearest register".
def is_comb(cell_type):
    if cell_type.startswith("LUT") or cell_type.startswith("MUX2"):
        return True
    return cell_type in {"ALU", "INV", "AND2", "OR2", "XOR2", "XNOR2", "NOT",
                         "MUX2_LUT5", "MUX2_LUT6", "MUX2_LUT7", "MUX2_LUT8"}


def top_module(design):
    """The flattened top, found by the `top` attribute.

    Looking it up by name fails on a design whose top is wrapped (`top_v2`), and
    then a primitive's own definition is inspected and nothing is checked.  That
    trap is the sibling project's, recorded in its `scripts/bsram_check.py`.
    """
    modules = design.get("modules", {})
    if not modules:
        raise ValueError("no modules in the netlist")
    tops = [m for m in modules.values() if m.get("attributes", {}).get("top")]
    if len(tops) == 1:
        return tops[0]
    return next(iter(modules.values()))


def build_driver_map(top):
    """bit index -> (cell_type, cell_name, output_port) for every driven bit."""
    driver = {}
    for name, cell in top.get("cells", {}).items():
        dirs = cell.get("port_directions", {})
        for port, bits in cell.get("connections", {}).items():
            if dirs.get(port) != "output":
                continue
            for b in bits:
                if isinstance(b, int):
                    driver[b] = (cell["type"], name, port)
    return driver


def cone_depth(start, top, driver, cap):
    """Longest chain of logic cells between `start` and a flip-flop or constant.

    Breadth-first with a visited set and an iteration cap.  A first version of
    this recursed over every input of every cell with no visited set and returned
    the cap for every bit on a design this size, which is why the visited set and
    the cap are here rather than left implicit.
    """
    frontier = [(start, 0)]
    seen = set()
    best = 0
    iterations = 0
    while frontier and iterations < 50000:
        bit, depth = frontier.pop()
        iterations += 1
        if bit in seen:
            continue
        seen.add(bit)
        t, name, port = driver.get(bit, ("?", "?", "?"))
        if t.startswith(FF_PREFIX) or t in CONST_TYPES or t == "?":
            best = max(best, depth)
            continue
        cell = top["cells"].get(name)
        if cell is None or not is_comb(t):
            best = max(best, depth)
            continue
        if depth >= cap:
            return cap
        dirs = cell.get("port_directions", {})
        for iport, bits in cell.get("connections", {}).items():
            if dirs.get(iport) == "input":
                for b in bits:
                    if isinstance(b, int):
                        frontier.append((b, depth + 1))
    return best


def array_of(cell_name):
    parts = cell_name.split(".")
    while len(parts) > 1 and parts[-1].isdigit():
        parts.pop()
    return ".".join(parts)


def main(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("netlist")
    ap.add_argument("--max-depth", type=int, default=8,
                    help="fail when a cone is deeper than this many logic levels "
                         "(default 8; use a large value to report only)")
    ap.add_argument("--port", choices=("ADB", "ADA", "both"), default="ADB",
                    help="which address port to judge (default ADB, the port "
                         "nextpnr does not time)")
    ap.add_argument("--top", type=int, default=10,
                    help="how many offending arrays to list (default 10)")
    ap.add_argument("--known", default="mem.mem_bios",
                    help="comma-separated arrays already recorded as deep (TCL-035);"
                         " they are reported but do not fail the check, so the gate"
                         " catches a NEW deep cone rather than failing every build"
                         " on the one the project already knows about")
    args = ap.parse_args(argv[1:])

    try:
        with open(args.netlist) as f:
            design = json.load(f)
        top = top_module(design)
    except (OSError, json.JSONDecodeError, ValueError) as e:
        print(f"cannot read {args.netlist}: {e}", file=sys.stderr)
        return 2

    driver = build_driver_map(top)
    ports = ("ADA", "ADB") if args.port == "both" else (args.port,)

    depth_hist = collections.Counter()
    per_array = collections.defaultdict(lambda: collections.Counter())
    cells = 0
    logic_bits = 0
    for name, cell in top.get("cells", {}).items():
        if cell.get("type") not in DP_TYPES:
            continue
        cells += 1
        for port in ports:
            for b in cell.get("connections", {}).get(port, []):
                if not isinstance(b, int):
                    continue
                t, _, _ = driver.get(b, ("?", "?", "?"))
                if t.startswith(FF_PREFIX) or t in CONST_TYPES:
                    continue
                logic_bits += 1
                d = cone_depth(b, top, driver, MEASURE_CAP)
                depth_hist[d] += 1
                per_array[array_of(name)][d] += 1

    print(f"netlist: {args.netlist}")
    print(f"  dual-port BSRAM cells:            {cells}")
    print(f"  address bits behind logic on {args.port}: {logic_bits}")
    if logic_bits:
        print("  depth distribution (logic levels between port and a flop):")
        for d in sorted(depth_hist):
            label = f"{d}" if d < MEASURE_CAP else f">={MEASURE_CAP}"
            flag = "  <-- exceeds bound" if d > args.max_depth else ""
            print(f"    {label:>4} levels: {depth_hist[d]:5} bits{flag}")

    known = {k.strip() for k in args.known.split(",") if k.strip()}
    offenders, known_hits = [], []
    for arr, hist in per_array.items():
        deep = sum(n for d, n in hist.items() if d > args.max_depth)
        if deep:
            worst = max(hist)
            (known_hits if arr in known else offenders).append(
                (deep, worst, arr, sum(hist.values())))
    offenders.sort(reverse=True)
    known_hits.sort(reverse=True)
    if known_hits:
        print(f"  recorded deep in TCL-035, reported but not failing:")
        for deep, worst, arr, total in known_hits[:args.top]:
            print(f"    {arr:44} {deep:5} of {total:5} bits, deepest {worst}")
    if offenders:
        print(f"  arrays with a cone deeper than {args.max_depth}:")
        for deep, worst, arr, total in offenders[:args.top]:
            print(f"    {arr:44} {deep:5} of {total:5} bits, deepest {worst}")
        if len(offenders) > args.top:
            print(f"    ... and {len(offenders) - args.top} more")
        print("  nextpnr's Gowin model does not time this port, so no timing gate"
              " in this build covers it (TCL-035).  A deep cone may still be"
              " inside its budget -- this reports a path nobody has checked rather"
              " than a defect -- but an array that was not in TCL-035's known list"
              " is new and should be looked at.")
        return 1
    if known_hits:
        print(f"  no NEW {args.port} cone deeper than {args.max_depth} levels"
              f" ({len(known_hits)} known arr{'ay' if len(known_hits)==1 else 'ays'}"
              f" recorded in TCL-035)")
    else:
        print(f"  no {args.port} cone deeper than {args.max_depth} levels")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
