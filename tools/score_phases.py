#!/usr/bin/env python3
"""Score each clk16 phase's cartridge reads against the ROM.

Used to test whether a read defect is a property of the design or of the
clk16/clk67 phase relationship the simulator happens to impose.  Each phase's
log is the same binary run with TINYGBA_CLK16_SHIFT set to a different offset, so
any difference between them is phase and nothing else.

    tools/score_phases.py ROM.gba build/phase/p*/r.log

Prints, per phase, the number of reads, how many match the ROM, and the highest
cartridge address reached.  Reach matters as much as accuracy: a phase that is
correct only because the machine stopped earlier is not a fix (TCL-027).
"""

import re
import sys

LINE = re.compile(r"CARTREAD: addr=([0-9a-f]{8}) be=([0-9a-f]) data_now=([0-9a-f]{8})")


def mask(be):
    m = 0
    for lane in range(4):
        if be & (1 << lane):
            m |= 0xFF << (8 * lane)
    return m


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[6], file=sys.stderr)
        return 2
    rom = open(argv[1], "rb").read()

    rows_out = []
    for path in argv[2:]:
        ok = bad = 0
        top = 0
        try:
            with open(path) as f:
                for line in f:
                    m = LINE.search(line)
                    if not m:
                        continue
                    addr, be, got = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
                    top = max(top, addr)
                    off = (addr - 0x08000000) & ~3
                    if off < 0 or off + 4 > len(rom):
                        continue
                    want = int.from_bytes(rom[off:off + 4], "little") & mask(be)
                    if want == (got & mask(be)):
                        ok += 1
                    else:
                        bad += 1
        except OSError as e:
            print(f"{path}: {e}", file=sys.stderr)
            continue
        rows_out.append((path, ok, bad, top))

    print(f"{'phase':>8}  {'ok':>5} {'bad':>5}  {'reach':>10}")
    for path, ok, bad, top in rows_out:
        phase = "?"
        m = re.search(r"/p(\d+)/", path)
        if m:
            phase = m.group(1)
        print(f"{phase:>8}  {ok:5d} {bad:5d}  {top:08x}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
