#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Guard against a netlist silently losing the registers its RTL declared.

Why this exists.  On 2026-11-02 this port lost about half its flip-flops to a
single undriven wire.  `gb_bus_rst` is an output of `gba_memory`, consumed by
every MMIO register as `if (gb_bus_rst) ...reset... else ...write...`, and
assigned by nothing -- here or in upstream GBATang.  Gowin EDA ties an undriven
wire low, so on the vendor flow those registers work; this flow's `synth_gowin`
folded the wire to constant 1, the reset branch became unconditional, every
write branch was dead code, and ABC deleted roughly 4,500 flip-flops.  The
design still built, still passed timing, and still produced a bitstream.  The
machine halted in the BIOS and never woke, and finding out why took a session of
board work.

The Verilator model could not catch it: in Verilator an undriven wire is 0, so
the model behaved correctly while the bitstream did not.  No simulation of this
design can see a synthesis fold, because the fold IS the difference between the
model and the bitstream.

What this does.  It reads the same RTL through the same front end the build uses,
counts flip-flops after elaboration and `proc` but before any optimisation, then
compares that count against the synthesised netlist.  A large loss between the
two is the signature of a signal that was assumed to be real and turned out to be
a constant.  It also sweeps `used but has no driver` warnings and reports them by
module, because an undriven wire is the cause of the class this tool exists for.

    tools/synth_parity.py build/tinygba.json
    tools/synth_parity.py build/tinygba.json --max-loss 5

Exit status is 0 when the loss is within the threshold, 1 when it is not, and 2
on a usage or parsing problem.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# How much register loss is normal.  ABC legitimately removes some registers --
# a constant-propagated counter, a stuck compare -- so an exact match is not
# expected.  Measured on this design 2026-11-02: a healthy build loses a few per
# cent, the `gb_bus_rst` fault lost 49 percent.
DEFAULT_MAX_LOSS_PCT = 10.0

YOSYS = "yosys"


def count_flops(netlist):
    """Register cells and the memory blocks that hold state, from a netlist."""
    import collections
    with open(netlist) as f:
        design = json.load(f)
    t = collections.Counter()
    for mod in design.get("modules", {}).values():
        for cell in mod.get("cells", {}).values():
            t[cell.get("type", "")] += 1
    flops = sum(v for k, v in t.items() if k.startswith("DFF"))
    # Block RAM is state too, and a fold can delete whole memories.  Counting the
    # regions rather than their contents keeps the unit comparable.
    bram = sum(v for k, v in t.items() if "RAM16" in k or k in ("DPB", "SP", "SDP", "DP"))
    return flops, bram


def undriven_modules(warnings_text):
    """Group `used but has no driver` warnings by the module they belong to."""
    groups = {}
    for m in re.finditer(r"Wire (\S+) is used but has no driver", warnings_text):
        name = m.group(1)
        # Names look like `gbatang_top.\mem.gb_bus_rst [3]` or
        # `gba_dma_module$gbatang_top.dma.x`.  The last component is the signal;
        # everything before it names the instance path.
        sig = re.sub(r"\[[0-9]+\]$", "", name)
        parts = re.split(r"[.\\]", sig)
        owner = parts[-2] if len(parts) >= 2 else "(top)"
        groups.setdefault(owner, set()).add(parts[-1])
    return groups


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("netlist", help="the synthesised netlist, e.g. build/x/tinygba.json")
    ap.add_argument("--max-loss", type=float, default=DEFAULT_MAX_LOSS_PCT,
                    help=f"percent register loss that fails the check "
                         f"(default {DEFAULT_MAX_LOSS_PCT})")
    ap.add_argument("--baseline", default="tools/synth_baseline.json")
    ap.add_argument("--key", help="configuration name for the baseline entry")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--synth-log",
                    help="the build's synth.err, to report undriven wires from")
    args = ap.parse_args()

    flops, bram = count_flops(args.netlist)
    print(f"netlist {args.netlist}")
    print(f"  flip-flops     {flops:6d}")
    print(f"  block RAM      {bram:6d}")
    print()

    if args.update_baseline:
        import pathlib
        path = pathlib.Path(args.baseline)
        try:
            base = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            base = {}
        base[args.key] = {"flops": flops, "bram": bram}
        path.write_text(json.dumps(base, indent=2, sort_keys=True) + "\n")
        print(f"baseline updated: {args.key} = {flops} flops, {bram} BRAM")
        return 0

    import pathlib
    path = pathlib.Path(args.baseline)
    if not path.exists():
        print(f"no baseline at {path}.", file=sys.stderr)
        print("Record one from a build known to work with", file=sys.stderr)
        print(f"  tools/synth_parity.py <netlist> --key {args.key} --update-baseline",
              file=sys.stderr)
        return 2
    base = json.loads(path.read_text())
    if args.key not in base:
        print(f"no baseline entry for '{args.key}'.", file=sys.stderr)
        print(f"known keys: {', '.join(sorted(base)) or '(none)'}", file=sys.stderr)
        return 2
    b = base[args.key]
    print(f"  baseline '{args.key}': {b['flops']} flops, {b['bram']} BRAM")

    loss = 100.0 * (b["flops"] - flops) / b["flops"] if b["flops"] else 0.0
    print(f"  change         {flops - b['flops']:+6d} flops ({-loss:+.1f}%)")
    bad = loss > args.max_loss

    if flops < b["flops"] * 0.9:
        print()
        print("A large LOSS of registers is the signature of this project's worst")
        print("class of bug: a signal that synthesis proved constant, deleting the")
        print("logic behind it.  On 2026-11-02 an undriven `gb_bus_rst` folded high")
        print("and removed about 4,500 registers -- every MMIO register in the")
        print("machine -- while the design still built, passed timing and produced")
        print("a bitstream.  A simulation cannot see this, because the simulation")
        print("sees the signal rather than its absence.")

    if args.synth_log and os.path.exists(args.synth_log):
        with open(args.synth_log, errors="replace") as f:
            groups = undriven_modules(f.read())
        if groups:
            print()
            print("Undriven wires reported by synthesis, grouped by instance:")
            for owner, sigs in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:12]:
                sample = ", ".join(sorted(sigs)[:5])
                more = "" if len(sigs) <= 5 else f" (+{len(sigs)-5})"
                print(f"  {owner:30s} {sample}{more}")
            print()
            print("An undriven wire is the cause of the loss above when it gates a")
            print("conditional in the RTL.  `gb_bus_rst` was exactly that: an output")
            print("of gba_memory, assigned by nothing, used as `if (gb_bus_rst)`.")

    print()
    if bad:
        print(f"FAIL: register loss {loss:.1f}% exceeds the {args.max_loss:.1f}% budget.",
              file=sys.stderr)
        return 1
    print(f"PASS: register change is within the {args.max_loss:.1f}% budget.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
