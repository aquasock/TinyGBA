#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Check that every diagnostic packing concatenation totals its declared width.

Why this exists as a gate rather than a habit.  A Verilog concatenation assigned
to a `+:` part-select does not have to be the size of the slice.  Too few bits and
it is silently zero-extended; too many and it is silently truncated.  Neither is
an error, neither produces a warning at this flow's verbosity, and both yield
words that decode to plausible values.

That happened twice in one cycle on `gbatang_top.sv`'s MMIO ring: a 108-bit
concatenation into a 128-bit slice, which shifted every field by 20 bits, and
then a 144-bit one, which truncated.  Each was caught by a person recomputing the
limits by hand, and each produced a confident wrong reading first.

So the widths are counted here, from the source, on every build.  The parser is
deliberately narrow: it understands the form these packings are actually written
in -- `{...}` on the right of a `+:` part-select assignment -- and it exits 2
rather than guessing if it meets something it does not understand, because a
gate that silently checks nothing is worse than no gate.
"""

import re
import sys

UNKNOWN = object()


def width_of(term, widths):
    """Width of one concatenation term, or UNKNOWN."""
    term = term.strip()
    if not term:
        return 0
    # sized literal: 4'h0, 16'hA5C3, 28'd0, 8'b0
    m = re.fullmatch(r"(\d+)'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_]+", term)
    if m:
        return int(m.group(1))
    # part select: name[hi:lo]
    m = re.fullmatch(r"(\w+)\[(\d+):(\d+)\]", term)
    if m:
        hi, lo = int(m.group(2)), int(m.group(3))
        return hi - lo + 1
    # bare identifier: look up
    m = re.fullmatch(r"[A-Za-z_]\w*", term)
    if m and m.group(0) in widths:
        return widths[m.group(0)]
    return UNKNOWN


def collect_widths(src, params=None):
    """Best-effort widths for signals, from wire/reg/port declarations.

    Handles the three forms this tree uses: `wire x;` (1 bit), `wire [7:0] x;`,
    several names in one declaration (`wire a, b, c;`), and ANSI ports
    (`output [31:0] rom_addr,`).  A name it cannot find stays absent, and
    main() then refuses rather than guessing.
    """
    if params is None:
        params = {}
    for m in re.finditer(r"\b(?:localparam|parameter)\b[^=]*?\b([A-Za-z_]\w*)\s*=\s*(\d+)",
                         src):
        params[m.group(1)] = int(m.group(2))

    widths = {}
    decl = re.compile(
        r"\b(?:wire|reg|input|output|inout)\b\s*(?:\[([^\]:]+):([^\]]+)\])?\s*"
        r"([^;\n)]*?)(?=;|$|\))", re.M)
    for m in decl.finditer(src):
        hi, lo, names = m.group(1), m.group(2), m.group(3)
        if hi is None:
            w = 1
        else:
            try:
                w = int(hi) - int(lo) + 1
            except (ValueError, AttributeError):
                # [PARAM-1:0] form
                pm = re.fullmatch(r"\s*([A-Za-z_]\w*)\s*-\s*1\s*", hi)
                if pm and pm.group(1) in params and lo.strip() == "0":
                    w = params[pm.group(1)]
                else:
                    continue
        for name in names.split(","):
            name = re.sub(r"//.*", "", name).strip()
            name = re.sub(r"=.*", "", name).strip()
            if re.fullmatch(r"[A-Za-z_]\w*", name or ""):
                widths.setdefault(name, w)
    return widths


def split_terms(expr):
    """Split a concatenation body on top-level commas."""
    depth, term, out = 0, "", []
    for ch in expr:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(term)
            term = ""
        else:
            term += ch
    if term.strip():
        out.append(term)
    return out


def balanced_brace(src, start):
    """Return (body, end_index) for the {...} beginning at src[start]."""
    depth = 0
    for i in range(start, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start + 1:i], i + 1
    return None, None


# `something[expr +: N] <= { ... }` -- the part-select is on the left and the
# concatenation on the right, which is the form these packings are written in.
ASSIGN = re.compile(r"\+\:\s*(\d+)\s*\]\s*<=\s*\{")

# `name = { ... }` -- a plain assignment of a concatenation to a declared register
# or net, optionally after a `case` label (`5'd20: stl_word_mux = {...}`).  The
# declared width is the size the right-hand side must total.  This form is the one
# every readout word in the stall-trace mux uses, and it truncates just as silently
# as the `+:` form: a 33-bit concatenation assigned to a 32-bit reg drops its top
# bit with no warning.  It found one on its first run -- the status word packed
# `{26'h0, s_dc, mm_wrapped, mm_n}`, 33 bits into 32 -- which was harmless only
# because the bit it dropped was padding, and which is exactly why it is worth
# checking rather than recomputing by hand.
PLAIN = re.compile(r"(?:^|:)\s*([A-Za-z_]\w*)\s*=\s*\{", re.M)

# `name = other;` -- a plain whole-identifier assignment.  Widths have to agree or
# the right-hand side is truncated or zero-extended, exactly as for a
# concatenation, and a readout word assigned straight from a narrower register
# would read as a plausible smaller number rather than as an error.  The v6
# readout assigns four words this way, so the form is checked rather than left
# to inspection.
PLAIN_IDENT = re.compile(r"(?:^|:)\s*([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*;", re.M)

# `[ {name, K'd0} +: N ]` -- an entry index built by shifting a counter into
# place.  K must equal log2(N), or consecutive entries overlap (K too small) or
# leave gaps (K too large).  Both are silent: the array is simply indexed wrongly
# and every other entry decodes as a blend of two writes.  This cost a full build
# cycle on the MMIO ring, where the write side used `{mm_n, 6'd0}` for a 128-bit
# entry while the read side used `{tr_ent, 7'd0}`.
STRIDE = re.compile(
    r"\[\s*\{\s*([A-Za-z_]\w*)\s*,\s*(\d+)'d0\s*\}\s*\+\:\s*(\d+)\s*\]")


def check_strides(src, path):
    """Every `{name, K'd0}` index into an N-bit slice must have 2**K == N."""
    bad = 0
    seen = 0
    for m in STRIDE.finditer(src):
        name, zeros, width = m.group(1), int(m.group(2)), int(m.group(3))
        seen += 1
        if (1 << zeros) != width:
            line = src[: m.start()].count("\n") + 1
            print(f"{path}:{line}: index {{{name}, {zeros}'d0}} strides by "
                  f"{1 << zeros} but the slice is {width} bits", file=sys.stderr)
            bad += 1
    return seen, bad


def check_plain(src, path, widths):
    """Every `name = { ... }` must total the declared width of `name`.

    Returns (checked, failed, unresolved) so main() can decide whether the gate
    actually saw anything, and whether it understood what it saw.  A `case` label
    prefix is allowed; the expression is only ever measured, never interpreted.
    """
    checked = failed = unresolved = 0
    for m in PLAIN.finditer(src):
        name = m.group(1)
        declared = widths.get(name)
        body, _ = balanced_brace(src, m.end() - 1)
        if body is None:
            print(f"{path}: unterminated concatenation near offset {m.start()}",
                  file=sys.stderr)
            return checked, failed + 1, unresolved
        if declared is None:
            # A name whose declaration this parser cannot size.  Refuse rather
            # than guess, for the same reason width_of() refuses.
            unresolved += 1
            continue
        total = 0
        bad_terms = []
        for t in split_terms(body):
            t = re.sub(r"//.*", "", t).strip()
            if not t:
                continue
            w = width_of(t, widths)
            if w is UNKNOWN:
                bad_terms.append(t)
            else:
                total += w
        line = src[: m.start()].count("\n") + 1
        if bad_terms:
            print(f"{path}:{line}: cannot resolve {bad_terms} in the packing for "
                  f"`{name}` -- it is NOT being checked; teach width_of() about it",
                  file=sys.stderr)
            return checked, failed, unresolved + 1
        checked += 1
        if total != declared:
            failed += 1
            print(f"{path}:{line}: concatenation for `{name}` is {total} bits, "
                  f"declared {declared} bits", file=sys.stderr)
    for m in PLAIN_IDENT.finditer(src):
        dst, srcexpr = m.group(1), m.group(2)
        dw, sw = widths.get(dst), widths.get(srcexpr)
        if dw is None or sw is None:
            unresolved += 1
            continue
        checked += 1
        if dw != sw:
            failed += 1
            line = src[: m.start()].count("\n") + 1
            print(f"{path}:{line}: `{dst}` is {dw} bits but is assigned "
                  f"`{srcexpr}`, which is {sw} bits", file=sys.stderr)
    return checked, failed, unresolved


def main(path, context=()):
    src = open(path).read()
    # Symbols come from the file itself plus any include files whose parameters
    # and macros it relies on.  The packings checked are always from `path`.
    # Parameters first, from every file in play, so `[PARAM-1:0]` ranges resolve
    # before any declaration is measured.
    params = {}
    for f in (path,) + tuple(context):
        for m in re.finditer(
                r"\b(?:localparam|parameter)\b[^=;]*?\b([A-Za-z_]\w*)\s*=\s*(\d+)",
                open(f).read()):
            params.setdefault(m.group(1), int(m.group(2)))
    widths = {}
    for f in (path,) + tuple(context):
        for k, v in collect_widths(open(f).read(), params).items():
            widths.setdefault(k, v)
    stride_seen, stride_bad = check_strides(src, path)
    checked = failed = 0
    for m in ASSIGN.finditer(src):
        slice_w = int(m.group(1))
        body, _ = balanced_brace(src, m.end() - 1)
        if body is None:
            print(f"{path}: unterminated concatenation near offset {m.start()}",
                  file=sys.stderr)
            return 2
        terms = split_terms(body)
        total = 0
        unresolved = []
        for t in terms:
            t = re.sub(r"//.*", "", t).strip()
            if not t:
                continue
            w = width_of(t, widths)
            if w is UNKNOWN:
                unresolved.append(t)
            else:
                total += w
        line = src[: m.start()].count("\n") + 1
        if unresolved:
            print(f"{path}:{line}: cannot resolve {unresolved} -- this packing is "
                  f"NOT being checked; teach width_of() about it", file=sys.stderr)
            return 2
        checked += 1
        if total != slice_w:
            failed += 1
            print(f"{path}:{line}: concatenation is {total} bits, slice is "
                  f"{slice_w} bits", file=sys.stderr)
    if checked == 0:
        print(f"{path}: no packings matched -- the gate checked nothing, which is "
              f"a failure, not a pass", file=sys.stderr)
        return 2
    plain_checked, plain_failed, plain_unresolved = check_plain(src, path, widths)
    if plain_unresolved:
        return 2
    if failed or stride_bad or plain_failed:
        return 1
    print(f"  packings: {checked} checked, all widths match; "
          f"strides: {stride_seen} checked, all match their slice size; "
          f"plain assignments: {plain_checked} checked, all match")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: check_ring_width.py [-c CONTEXT.sv] FILE.sv ...", file=sys.stderr)
        sys.exit(2)
    context, files = [], []
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "-c":
            context.append(args.pop(0))
        else:
            files.append(a)
    rc = 0
    for p in files:
        rc = max(rc, main(p, context))
    sys.exit(rc)
