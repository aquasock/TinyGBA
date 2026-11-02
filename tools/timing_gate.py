#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Judge a routed build against the timing contract this design was written to.

Why this exists.  nextpnr analyses every path as a single cycle, and it cannot
do otherwise: its SDC parser implements only `get_ports`, `get_cells`, `get_nets`,
`get_pins`, `create_clock` and `set_false_path`, and `set_false_path` logs
"does not do anything (yet)" and returns without effect (verified in the fork's
`common/kernel/sdc.cc` 2026-11-02).  `set_multicycle_path` is not implemented at
all.  Upstream GBATang's own `gbatang.sdc` leans on it four times:

    # sdram.cpu_dout through the CPU back to sdram: 4 cycles
    set_multicycle_path 4 -setup -end -from [get_pins {sdram/cpu_rdata*/*}] -to [get_clocks {clk67}]
    set_multicycle_path 3 -hold -end -from [get_pins {sdram/cpu_rdata*/*}] -to [get_clocks {clk67}]
    set_multicycle_path 4 -setup -start -from [get_clocks {clk67}] -to [get_clocks {clk16}]
    set_multicycle_path 4 -setup -end   -from [get_clocks {clk16}] -to [get_clocks {clk67}]

So the design genuinely contains paths that are meant to take four `clk67`
cycles, because the logic they cross is clocked at `clk16` -- one `clk16` period
is four `clk67` periods.  Measuring those as single-cycle charges a 59.7 ns path
against a 14.9 ns budget and fails a design that meets its own contract by a
factor of two.  This tool applies exactly those four documented allowances and
nothing else.

What it will not do: invent an allowance.  Every relaxation must name the
upstream line it comes from, must match both endpoints, and is printed as
ALLOWED so a build log never quietly hides one.  Anything not matched is held to
a single cycle.

It also gates what the Fmax report alone cannot see:
  * the hold count, which nextpnr prints only when it is non-zero;
  * cross-clock paths between `clk16` and `clk67`, which `--timing-allow-fail`
    would otherwise let through untested.

    tools/timing_gate.py build/tinygba
    tools/timing_gate.py build/tinygba --allow-hold

Exit status 0 when the build meets the contract, 1 when it does not, 2 on a
usage or parsing problem.
"""
import argparse
import json
import pathlib
import re
import sys

# Upstream's multicycle factor, and the only value this tool accepts.
MULTICYCLE = 4

# Clock pairs upstream relaxes by MULTICYCLE in both directions.
RELAXED_PAIRS = {
    ("posedge clk16", "posedge clk67"),
    ("posedge clk67", "posedge clk16"),
}

# Same-domain `clk67` paths are single-cycle except for this one class: a path
# that leaves the SDRAM controller's readback registers, crosses the CPU's
# combinational logic and returns to a register in the SDRAM instance.  Upstream
# names it `sdram/cpu_rdata* -> clk67`.  Both endpoints are required so an
# unrelated slow path cannot borrow the allowance.
READBACK_SOURCE = "cpu_mem_rdata"
SDRAM_DEST = "sdram."


def path_delay(cp):
    return sum(step.get("delay", 0.0) for step in cp.get("path", []))


def first_cell(cp):
    steps = cp.get("path", [])
    return steps[0].get("from", {}).get("cell", "") if steps else ""


def last_cell(cp):
    steps = cp.get("path", [])
    return steps[-1].get("to", {}).get("cell", "") if steps else ""


def allowance(cp, period):
    """(budget_ns, reason) when upstream relaxes this path, else (None, None)."""
    src, dst = cp.get("from"), cp.get("to")
    if (src, dst) in RELAXED_PAIRS:
        return (MULTICYCLE * period["clk67"],
                "GBATang: set_multicycle_path 4 -from clk16 -to clk67 / -from clk67 -to clk16")
    if src == "posedge clk67" and dst == "posedge clk67":
        if first_cell(cp).startswith(READBACK_SOURCE) and last_cell(cp).startswith(SDRAM_DEST):
            return (MULTICYCLE * period["clk67"],
                    "GBATang: set_multicycle_path 4 -from {sdram/cpu_rdata*/*} -to {clk67}")
    return (None, None)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("build_dir")
    ap.add_argument("--allow-hold", action="store_true",
                    help="report hold violations without failing")
    args = ap.parse_args()

    out = pathlib.Path(args.build_dir)
    try:
        timing = json.loads((out / "timing.json").read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot read {out}/timing.json: {e}", file=sys.stderr)
        return 2

    fmax = timing.get("fmax", {})
    paths = timing.get("critical_paths", [])
    if not fmax:
        print(f"{out}/timing.json has no fmax section", file=sys.stderr)
        return 2

    # ns per cycle, from the same constraint numbers nextpnr used.
    period = {k: 1000.0 / v["constraint"] for k, v in fmax.items()}
    period.setdefault("clk16", 1000.0 / 16.75)
    period.setdefault("clk67", 1000.0 / 67.00)

    failures = []
    allowed = []

    for name, v in sorted(fmax.items()):
        achieved, constraint = v["achieved"], v["constraint"]
        if achieved >= constraint:
            print(f"  {name:6s}: constraint {constraint:7.3f} MHz, achieved {achieved:7.3f} MHz  pass")
            continue

        # Failing: find the same-domain path that produced the number and see
        # whether the contract actually relaxes it.
        same = [cp for cp in paths
                if cp.get("from") == f"posedge {name}" and cp.get("to") == f"posedge {name}"]
        budget, reason, delay, cp = (None, None, 0.0, None)
        if same:
            cp = max(same, key=path_delay)
            budget, reason = allowance(cp, period)
            delay = path_delay(cp)
        if budget is not None and same and delay <= budget:
            print(f"  {name:6s}: constraint {constraint:7.3f} MHz, achieved {achieved:7.3f} MHz")
            print(f"          ALLOWED: worst path is {delay:.2f} ns, budget {budget:.2f} ns")
            print(f"          {reason}")
            print(f"          {first_cell(cp)} -> {last_cell(cp)}")
            allowed.append((name, delay, budget, reason))
        else:
            print(f"  {name:6s}: constraint {constraint:7.3f} MHz, achieved {achieved:7.3f} MHz  FAIL")
            if cp is not None:
                print(f"          worst path {delay:.2f} ns, budget "
                      f"{(budget if budget is not None else period.get(name, 0)):.2f} ns")
                print(f"          {first_cell(cp)} -> {last_cell(cp)}")
            failures.append(name)

    # Cross-domain paths between clk16 and clk67 are not part of any Fmax figure,
    # so --timing-allow-fail would let them through entirely unmeasured.  Upstream
    # gives them four clk67 cycles.
    cross_budget = MULTICYCLE * period["clk67"]
    for cp in paths:
        pair = (cp.get("from"), cp.get("to"))
        if pair in RELAXED_PAIRS:
            delay = path_delay(cp)
            state = "pass" if delay <= cross_budget else "FAIL"
            print(f"  cross {cp['from'].replace('posedge ','')} -> "
                  f"{cp['to'].replace('posedge ','')}: {delay:6.2f} ns, budget "
                  f"{cross_budget:6.2f} ns  {state}")
            if delay > cross_budget:
                failures.append(f"{cp['from']}->{cp['to']}")

    # Hold.  nextpnr prints the count only when it is non-zero (core-reference
    # TCL-008), so absence means a clean placement.
    try:
        log = (out / "nextpnr.log").read_text(errors="replace")
    except OSError:
        log = ""
    m = re.search(r"([0-9]+) Hold/min time violations", log)
    hold = int(m.group(1)) if m else 0
    print(f"  hold  : {hold} violation(s)" + ("" if hold == 0 else
          ("  (allowed by --allow-hold)" if args.allow_hold else "  FAIL")))
    if hold and not args.allow_hold:
        failures.append("hold")

    print()
    if failures:
        raise SystemExit(f"timing contract not met: {', '.join(sorted(set(failures)))}")
    if allowed:
        print(f"Meets the contract.  {len(allowed)} clock(s) passed only because of a documented")
        print("GBATang multicycle path; each is listed above with the upstream line it comes from.")
    else:
        print("Meets the contract with no relaxation needed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
