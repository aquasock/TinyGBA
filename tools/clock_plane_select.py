#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compare the clock-plane placement of routed netlists against a reference.

BRD-047 left the project with a test condition expressed in prose: rebuild
layout v7 and keep a placement whose `clk67` is confined to the two spines this
board has measured good.  That condition has to be applied to every candidate
seed, and it has two properties a hand-read of `clock-plane.log` does not have:
it is exact, and it covers every clock at once rather than the one that was
named.

Why compare against a reference netlist instead of only against the good/bad
table.  On this design three of the four clocks sit on pips the board has never
measured (BRD-019), so "all clocks measured good" is unavailable and will be for
some time.  The question that is answerable is the relative one: a candidate
that reproduces the *control* placement's pip set differs from it in no clock
plane at all, and a board result from it can therefore be attributed to the
design change rather than to the placement.  A candidate that matches on `clk67`
but moves `clk16` has two variables, not one.

This tool reads the routed netlist, which is the same source
`tools/clock_plane_report.py` uses, and reuses that module's pip parser and
measured-good table so the two cannot drift apart.

    tools/clock_plane_select.py build/v6_s9/tinygba-routed.json build/v7_s1[0-9]/
    tools/clock_plane_select.py --reference build/v6_s9/tinygba-routed.json build/v7_s*/
    tools/clock_plane_select.py --require clk67=SPINE16/TOP0,SPINE25/TOP1 build/x/

With no `--reference` the first positional argument is the reference.  A
directory argument is read as `<dir>/tinygba-routed.json`, so a seed sweep can
be passed as a glob.

Exit status: 0 if at least one candidate matches the reference on every clock,
1 if none does, 2 on a read error.  A match is reported per clock, because a
candidate that differs only on a clock nobody has measured is a weaker result
than one that differs on a measured-good spine, and the summary says which.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clock_plane_report import (  # noqa: E402
    GOOD, RANK, REQUIRED_PLANE, classify, clock_routes, verdict,
)

MATCH, DIFFER, ABSENT = "match", "differs", "absent"


def resolve(path):
    if os.path.isdir(path):
        return os.path.join(path, "tinygba-routed.json")
    return path


def top_of(path):
    """Read a routed netlist and return its (single, flattened) top module."""
    with open(path) as f:
        design = json.load(f)
    modules = design.get("modules", {})
    if not modules:
        raise ValueError("no modules in the netlist")
    return next(iter(modules.values()))


def planes(top):
    """Return {clock: [(spine, bridge_pin)]} plus {clock: worst measured state}.

    Only the four clocks the design is timed against are returned: a net that
    reaches a bridge is not necessarily a design clock (a PLL reference input
    does), and `clock_plane_report.py` already draws that line by name.
    """
    pips, worst = {}, {}
    for name, these in clock_routes(top):
        if name not in REQUIRED_PLANE:
            continue
        pips[name] = sorted(these)
        state = GOOD
        for pip in these:
            got, _ = verdict(classify(name), pip)
            if RANK[got] > RANK[state]:
                state = got
        worst[name] = state
    return pips, worst


def fmt(pips):
    return ", ".join(f"{s}/{p.replace('CBRIDGEOUT_', '')}" for s, p in pips) or "none"


def plane_has_good(pips, clock):
    """True when at least one of the clock's pips is measured good on this board.

    Deliberately `any` and not `all`: three of the four clocks cross pips this
    board has never measured (BRD-019), so requiring every pip to be good would
    reject every placement the tree produces.  Requiring one is the rule BRD-048
    records -- every image that has ever displayed crossed at least one measured
    good `hclk` pip, and the one that did not showed nothing at all.
    """
    return any(verdict(classify(clock), pip)[0] == GOOD for pip in pips.get(clock, []))


def parse_requirements(spec):
    """`clk67=SPINE16/TOP0,SPINE25/TOP1;clk16=SPINE1/TOP3` -> {clock: set}."""
    req = {}
    for part in filter(None, (p.strip() for p in spec.split(";"))):
        clock, _, rest = part.partition("=")
        if not rest:
            raise ValueError(f"need <clock>=<spine>/<pin>: {part!r}")
        want = set()
        for pip in filter(None, (x.strip() for x in rest.split(","))):
            spine, _, pin = pip.partition("/")
            if not spine or not pin:
                raise ValueError(f"need <spine>/<pin>: {pip!r}")
            want.add((spine, "CBRIDGEOUT_" + pin))
        req[clock.strip()] = want
    return req


def target_for(clock, ref, require):
    """The pip set a clock must have: the requirement if given, else the reference."""
    if require and clock in require:
        return require[clock]
    return ref.get(clock)


def compare(ref, cand, require=None):
    """Return (per-clock verdicts, differing, absent, failed).

    Every clock is compared and reported, but only the clocks the target speaks
    to can fail: with `--require clk67=...` the question asked is about `clk67`,
    and the other three clocks are context.  Their verdict is still printed so a
    reader can see whether the narrow match came at the cost of moving
    everything else.
    """
    out, differing, missing, failed = {}, [], [], []
    for clock in REQUIRED_PLANE:
        want = target_for(clock, ref, require)
        if want is None:
            continue
        got = cand.get(clock)
        verdict_ = MATCH
        if got is None:
            verdict_ = ABSENT
            missing.append(clock)
        elif got != sorted(want):
            verdict_ = DIFFER
            differing.append(clock)
        out[clock] = verdict_
        if verdict_ != MATCH and (not require or clock in require):
            failed.append(clock)
    return out, differing, missing, failed


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("netlists", nargs="+",
                    help="reference first unless --reference is given; a directory "
                         "is read as <dir>/tinygba-routed.json")
    ap.add_argument("--reference", metavar="ROUTED_JSON",
                    help="routed netlist whose clock planes are the target")
    ap.add_argument("--require", metavar="SPEC",
                    help="override the target per clock, e.g. "
                         "clk67=SPINE16/TOP0,SPINE25/TOP1")
    ap.add_argument("--list", action="store_true",
                    help="print every candidate, not only those that match")
    ap.add_argument("--require-good", metavar="CLOCKS",
                    help="comma-separated clocks that must each cross at least one "
                         "measured-good pip, e.g. hclk,clk67.  This is the rule "
                         "BRD-048 records: a placement can be hold-clean, meet every "
                         "gate, and still show nothing because the clock that matters "
                         "has no measured-good spine.  Set-exact matching against a "
                         "reference does not express it, because a candidate can "
                         "reproduce an unmeasured reference placement exactly.")
    args = ap.parse_args()

    paths = [resolve(p) for p in args.netlists]
    if args.reference:
        ref_path, cand_paths = resolve(args.reference), paths
    elif len(paths) >= 2:
        ref_path, cand_paths = paths[0], paths[1:]
    else:
        ap.error("need a reference and at least one candidate, or --reference")

    try:
        require = parse_requirements(args.require) if args.require else None
        must_be_good = [c.strip() for c in (args.require_good or "").split(",") if c.strip()]
        for clock in must_be_good:
            if clock not in REQUIRED_PLANE:
                raise ValueError(f"--require-good: unknown clock {clock!r}; "
                                 f"known: {', '.join(REQUIRED_PLANE)}")
        ref_pips, ref_worst = planes(top_of(ref_path))
    except (OSError, json.JSONDecodeError, ValueError) as e:
        print(f"reference {ref_path}: {e}", file=sys.stderr)
        return 2

    print(f"reference: {ref_path}")
    for clock in REQUIRED_PLANE:
        if clock not in ref_pips:
            continue
        if require and clock in require:
            print(f"  {clock:6} {fmt(sorted(require[clock]))}  (target, --require)")
        elif require:
            print(f"  {clock:6} {fmt(ref_pips[clock])}  ({ref_worst[clock]}; "
                  f"reference only, not required)")
        else:
            print(f"  {clock:6} {fmt(ref_pips[clock])}  ({ref_worst[clock]})")
    for clock, want in (require or {}).items():
        if clock not in ref_pips:
            print(f"  {clock:6} {fmt(sorted(want))}  (target, --require)")
    print()

    rows, winners = [], []
    for path in cand_paths:
        try:
            pips, _ = planes(top_of(path))
        except (OSError, json.JSONDecodeError, ValueError) as e:
            print(f"{path}: {e}", file=sys.stderr)
            rows.append((path, None, None, None, None, [clock for clock in REQUIRED_PLANE]))
            continue
        out, differing, missing, failed = compare(ref_pips, pips, require)
        # BRD-048: a clock with no measured-good pip reaches no sink on a path
        # this board has shown to work.  Checked per candidate rather than
        # against the reference, because the reference may itself be an
        # unmeasured placement, and set-exact matching cannot express it.
        ungrounded = [c for c in must_be_good if not plane_has_good(pips, c)]
        if ungrounded:
            failed = failed + [c for c in ungrounded if c not in failed]
        rows.append((path, out, differing, missing, ungrounded, failed))
        if not failed:
            winners.append(path)

    for path, out, differing, missing, ungrounded, failed in rows:
        if out is None:
            continue
        label = "MATCH" if not failed else "  -  "
        detail = ", ".join(f"{c}={out[c]}" for c in REQUIRED_PLANE if c in out)
        print(f"{label} {os.path.dirname(path) or path:32} {detail}")
        if failed:
            got_pips = planes(top_of(path))[0]
            for clock in differing:
                target = target_for(clock, ref_pips, require)
                note = "" if not require or clock in require else "  (context, not required)"
                print(f"        {clock} target {fmt(sorted(target))} "
                      f"got {fmt(got_pips.get(clock, []))}{note}")
            for clock in missing:
                print(f"        {clock} absent from this placement")
            for clock in ungrounded:
                print(f"        {clock} crosses no measured-good pip: "
                      f"{fmt(got_pips.get(clock, []))}")

    print()
    scope = "required " if (require or must_be_good) else ""
    if not winners:
        print(f"no candidate reproduces the target clock plane on every {scope}clock")
        return 1
    print(f"{len(winners)} candidate(s) match on every {scope}clock: "
          + ", ".join(os.path.dirname(w) or w for w in winners))
    return 0


if __name__ == "__main__":
    sys.exit(main())
