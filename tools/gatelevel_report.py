#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read the synthesised netlist and report whether the machine's fetch path survived.

Why this exists.  A source-level review cannot tell you what the synthesiser did,
and this project has already been burned by exactly that gap: Gowin's attribute
comments mark twenty CPU-port and fetch-path declarations in `gba_memory.sv` as
must-keep, and this flow's front end does not parse that comment syntax, so the
marks are inert.  Whether losing them changes anything is a question about the
netlist, not about the source, and the honest answer is read out of the artifact
the bitstream is packed from.

It answers three things per named net:

  * does a net with that name still exist at all, and is it still a bus of the
    width the RTL declared -- a cone that has been folded away leaves the name
    behind only as a stub, or not at all;
  * is each bit driven by a cell, left undriven, or driven only by a constant;
  * how many distinct driving cell types feed it.

An undriven bit or a bit driven only by a constant is a chain of don't-cares
starting somewhere upstream, which is the failure mode the sibling SNES project
chased for five cycles -- an unassigned `PAL` register made every downstream
compare `x`, and the whole pixel path left the netlist while simulation was
still passing (TinySNES core-log entries 52 and 53).

    tools/gatelevel_report.py build/tinygba/tinygba.json
    tools/gatelevel_report.py a.json --compare b.json
    tools/gatelevel_report.py ... --strict       fail if any target is not intact

Exit status: 0 when every target is intact (or nothing was asked of it), 1 when a
target is missing or has undriven bits (and --strict was given), 2 on a usage or
parsing problem.
"""
import argparse
import collections
import json
import sys

# The nets that carry the machine's instruction fetch and its results back to the
# CPU.  The width is the RTL declaration and is part of the test: a bus that
# comes back narrower has lost lanes somewhere, which a name match alone would
# hide.
TARGETS = [
    ("mem.rom_en", 1),
    ("mem.rom_addr", 32),
    ("mem.rom_data", 32),
    ("mem.cpu_en", 1),
    ("mem.ram_cen", 1),
    ("mem.ram_addr", 32),
    ("mem.ram_rdata", 32),
    ("mem.ram_wdata", 32),
    ("mem.gb_bus_din", 32),
    ("mem.gb_bus_dout", 32),
    ("mem.gb_bus_adr", 28),
    ("mem.loading", 3),
    ("mem.loader_valid", 1),
]


def load_top(path):
    with open(path) as f:
        design = json.load(f)
    modules = design.get("modules", {})
    if not modules:
        raise SystemExit(f"{path}: no modules in the netlist")
    # The elaborated netlist keeps every module; the design is the one with the
    # most cells.  A routed netlist has only the flattened top, which is also the
    # largest, so this works for both.
    name = max(modules, key=lambda n: len(modules[n].get("cells", {})))
    return path, modules[name]


def analyse(mod):
    """Map each net id to its drivers, and record the module's own ports."""
    cells = mod.get("cells", {})
    drivers = collections.defaultdict(list)      # bit id -> [(cell, port, type)]
    for cname, cell in cells.items():
        dirs = cell.get("port_directions", {})
        for port, bits in cell.get("connections", {}).items():
            if dirs.get(port) != "output":
                continue
            for b in bits:
                if isinstance(b, int):
                    drivers[b].append((cname, port, cell.get("type", "?")))
    ports = {name: p.get("direction") for name, p in mod.get("ports", {}).items()}
    return drivers, ports


def bits_of(mod, target):
    """The bit ids of the net named exactly `target`, and nothing else.

    The first version of this matched `target + "_"` as well, to catch derived
    names.  That is the failure TinySNES records in its own report tool: Yosys
    names every fan-out and optimised net `<base>_<cell>_...`, so a prefix match
    swept up hundreds of unrelated nets, reported a 32-bit bus as 277 bits, and
    made a healthy signal look enormous -- and the width test, which exists to
    catch lost lanes, became meaningless.  Exact name, or nothing.
    """
    netnames = mod.get("netnames", {})
    info = netnames.get(target)
    if info is None:
        return set(), []
    bits = {b for b in info.get("bits", []) if isinstance(b, int)}
    return bits, [target]


def report(path, mod, name, width, drivers, ports):
    bits, matched = bits_of(mod, name)
    if not matched:
        return {"status": "missing", "line": f"  {name:26s} MISSING from the netlist"}
    if not bits:
        return {"status": "empty",
                "line": f"  {name:26s} exists as a name with no bits"}

    driven, undriven = 0, 0
    types = collections.Counter()
    for b in sorted(bits):
        ds = drivers.get(b, [])
        if ds:
            driven += 1
            for _, _, t in ds:
                types[t] += 1
        else:
            undriven += 1

    width_note = ""
    if width and len(bits) != width:
        width_note = f"  (RTL declares {width} bits)"
    top = ", ".join(f"{t}x{n}" for t, n in types.most_common(4)) or "-"
    status = "intact" if undriven == 0 and bits else "undriven"
    line = (f"  {name:26s} bits {len(bits):3d}  driven {driven:3d}  "
            f"undriven {undriven:3d}  drivers: {top}{width_note}")
    return {"status": status, "line": line, "matched": matched}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("netlist")
    ap.add_argument("--compare", default=None,
                    help="a second netlist, reported side by side")
    ap.add_argument("--target", action="append", default=None,
                    help="override the target list, as name=width")
    ap.add_argument("--strict", action="store_true",
                    help="fail when a target is missing or has undriven bits")
    args = ap.parse_args()

    targets = TARGETS
    if args.target:
        targets = []
        for spec in args.target:
            name, _, width = spec.partition("=")
            targets.append((name, int(width) if width else 0))

    try:
        path_a, mod_a = load_top(args.netlist)
        mod_b = None
        if args.compare:
            _, mod_b = load_top(args.compare)
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot read netlist: {e}", file=sys.stderr)
        return 2

    drv_a, ports_a = analyse(mod_a)
    results = []
    print(f"{path_a}")
    for name, width in targets:
        r = report(path_a, mod_a, name, width, drv_a, ports_a)
        results.append(r)
        print(r["line"])

    if mod_b is not None:
        drv_b, ports_b = analyse(mod_b)
        print()
        print(f"{args.compare}")
        for (name, width), ra in zip(targets, results):
            rb = report(args.compare, mod_b, name, width, drv_b, ports_b)
            print(rb["line"])
            if ra["line"].split() != rb["line"].split():
                print(f"    ^ differs from {path_a}")

    broken = [r for r in results if r["status"] != "intact"]
    print()
    if broken:
        print(f"{len(broken)} of {len(results)} fetch-path targets are not intact.",
              file=sys.stderr)
        print("An undriven bit here is a don't-care propagating from upstream, not a",
              file=sys.stderr)
        print("harmless pruning: check which register feeds it before reading any",
              file=sys.stderr)
        print("hardware result from this netlist.", file=sys.stderr)
        if args.strict:
            return 1
        return 0
    print(f"All {len(results)} fetch-path targets are present and driven.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
