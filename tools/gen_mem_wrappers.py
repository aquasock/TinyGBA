#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Extract a Gowin primitive's parameter block from an IP-generator wrapper.

Why this exists.  Six memories in this tree were Gowin IP-generator output
carrying Gowin's all-rights-reserved header rather than this project's licence
(TCL-065).  Each is a port list plus a few primitive instantiations with fixed
parameters, so the fix is to express the same memory in this project's own RTL.
The part that must not be retyped by hand is the parameters: `BIT_WIDTH_*`,
`BLK_SEL_*` and above all the 64 `INIT_RAM_*` words, which for the OSD text page
hold an 8x8 font plus a logo and are the difference between a working text page
and a blank one.

This tool emits one `#(...)` parameter block per instantiation, ready to paste
into a hand-written wrapper.  The wiring is written by a person because it needs
judgement; the hex is copied by a machine because it does not.

    tools/gen_mem_wrappers.py <gowin-wrapper.v> [--inst N] [--indent 8]

Exits non-zero if it finds no primitive instantiation.
"""
import argparse
import re
import sys

PRIMS = ("DPB", "SP", "DPX9B")


def instances(src):
    """[(primitive, instance_name, [param names in declaration order])]."""
    out = []
    for m in re.finditer(r"^\s*(DPB|SP|DPX9B)\s+(\w+)\s*\(", src, re.M):
        out.append([m.group(1), m.group(2)])
    return out


def params_for(src, inst):
    """[(PARAM, value)] for one instance, in the order the defparams appear."""
    seen, out = set(), []
    pat = re.compile(r"defparam\s+" + re.escape(inst) + r"\.(\w+)\s*=\s*([^;]+);")
    for m in pat.finditer(src):
        if m.group(1) in seen:
            continue
        seen.add(m.group(1))
        out.append((m.group(1), m.group(2).strip()))
    return out


def block(prim, inst, pairs, indent):
    pad = " " * indent
    lines = [f"{prim} #("]
    body = []
    for name, val in pairs:
        body.append(f".{name}({val})")
    body[-1] = body[-1]  # trailing comma handled below
    for i, item in enumerate(body):
        comma = "," if i < len(body) - 1 else ""
        lines.append(f"{pad}    {item}{comma}")
    lines.append(f"{pad})")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("--inst", default=None, help="only this instance (default: all)")
    ap.add_argument("--indent", type=int, default=4)
    ap.add_argument("--summary", action="store_true",
                    help="report geometry instead of emitting Verilog")
    args = ap.parse_args(argv)

    src = open(args.source).read()
    found = instances(src)
    if not found:
        sys.exit(f"{args.source}: no {PRIMS} instantiation found")

    if args.summary:
        for prim, inst in found:
            pairs = params_for(src, inst)
            d = dict(pairs)
            dims = " ".join(f"{k}={v}" for k, v in pairs
                            if k.startswith(("BIT_WIDTH", "BLK_SEL")))
            nz = sum(1 for k, v in pairs
                     if k.startswith("INIT_RAM") and int(v.split("'h")[-1], 16) != 0)
            print(f"{prim} {inst}: {len(pairs)} params, {nz} non-zero INIT_RAM, {dims}")
        return 0

    for prim, inst in found:
        if args.inst and inst != args.inst:
            continue
        pairs = params_for(src, inst)
        if not pairs:
            print(f"// {inst}: no defparams found", file=sys.stderr)
            continue
        print(block(prim, inst, pairs, args.indent))
    return 0


if __name__ == "__main__":
    sys.exit(main())
