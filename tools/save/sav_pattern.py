#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Make and check a pattern `.sav` for the save-persistence path.

Why this exists.  The most direct question about save persistence is whether
what the core writes into the cartridge's save window is what comes back out of
it, and whether a stored save lands where the cartridge will look.  Proving that
by playing a game and saving in it depends on the game, on the operator being
present, and on the save being reachable in a few minutes of play; worse, it
proves the round trip only for the bytes the game happened to write, which for a
fresh cartridge are zeros.

A pattern file answers the same question without a game: it is a `.sav` whose
every byte depends on its offset, so an off-by-one chunk, a dropped byte, a
swapped byte lane, a missing bank or an address that aliases at 64 KB all show
up as a mismatch on a named offset.  Load a cartridge with it in place, dump the
save back with `gbasave`, and check the result with this script.

The pattern is the one `tools/save/tb_save.sv` uses, deliberately: the RTL test
and the board test then fail on the same byte for the same reason.

This is a test vector, not a save.  A cartridge will treat it as a corrupt save
and usually offers to erase it, which is the expected outcome of the procedure.

    tools/save/sav_pattern.py make  <file> --size 32k
    tools/save/sav_pattern.py check <file> --size 32k

`--size` accepts the whole save sizes the core knows: 8k (EEPROM), 32k (SRAM),
64k (flash512K) and 128k (flash1M).  Exits 0 on a match.
"""

import argparse
import sys

SIZES = {
    "8k": 8 * 1024,
    "32k": 32 * 1024,
    "64k": 64 * 1024,
    "128k": 128 * 1024,
}


def pattern(size):
    return bytes(((i * 31) + 7) & 0xFF for i in range(size))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=("make", "check"))
    ap.add_argument("path")
    ap.add_argument("--size", required=True, choices=sorted(SIZES))
    args = ap.parse_args(argv)

    want = pattern(SIZES[args.size])

    if args.mode == "make":
        with open(args.path, "wb") as f:
            f.write(want)
        print(f"wrote {len(want)} bytes of pattern to {args.path}")
        return 0

    try:
        with open(args.path, "rb") as f:
            got = f.read()
    except OSError as exc:
        print(f"cannot read {args.path}: {exc}", file=sys.stderr)
        return 2

    if len(got) != len(want):
        print(f"FAIL: {args.path} is {len(got)} bytes, expected {len(want)}")
        return 1

    bad = [i for i in range(len(want)) if got[i] != want[i]]
    if not bad:
        print(f"PASS: {args.path} matches the pattern byte for byte "
              f"({len(want)} bytes, offsets 0x000000-0x{len(want)-1:06x})")
        return 0

    print(f"FAIL: {len(bad)} of {len(want)} bytes differ; first 12:")
    for i in bad[:12]:
        print(f"  offset 0x{i:06x}: got {got[i]:02x} want {want[i]:02x}")
    # A whole-file summary helps tell a shift from noise: a shift by one byte
    # makes every offset differ, a bank that did not switch makes the second
    # half differ while the first matches, and a lost chunk shows as a run.
    first = bad[0]
    last = bad[-1]
    print(f"  differing range: 0x{first:06x} to 0x{last:06x}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
