#!/usr/bin/env python3
"""Check captured cartridge reads against the ROM, and calibrate the sampling.

The harness logs each cartridge data read as the address plus BOTH candidate data
words -- the one visible on the `cpu_en` edge and the one visible on the previous
edge -- because it is not obvious which of them the CPU actually receives:

    CARTREAD: addr=%08x be=%x data_now=%08x data_prev=%08x

This tool decides the pairing empirically instead of assuming it.  It reads the
ROM file, then scores each column by how many captured reads match the bytes the
ROM holds at that address.  The column that scores higher is the one that
describes what the CPU receives; if neither scores well the capture is describing
something else and no conclusion should be drawn from it.

    tools/check_cartread.py ROM.gba LOG [LOG...]

The build carrying the behavioural array is the calibration reference, because it
is the build that produces a working machine: if a column reproduces the ROM
there, that column is the correct reading of the hardware.  The controller build
is then judged with the same column.

Exit status: 0 when the calibrated column matches every checked read, 1 when
reads disagree with the ROM, 2 on bad input.  A read whose byte-enables select a
partial word is compared only on the lanes the enable marks.
"""

import re
import sys

LINE = re.compile(
    r"^CARTREAD: addr=([0-9a-fA-F]{8}) be=([0-9a-fA-F]) "
    r"data_now=([0-9a-fA-F]{8}) data_prev=([0-9a-fA-F]{8})$"
)


def load_rom(path):
    with open(path, "rb") as f:
        return f.read()


def rom_word(rom, addr, be):
    """The word the ROM holds at a GBA cartridge address, lanes masked by `be`.

    `addr` is a GBA address in the cartridge region, so the image offset is
    `addr - 0x08000000`: the ROM file starts at cartridge offset zero, not at the
    address the CPU uses.  `be` is the byte-enable mask for the 32-bit word, bit 0
    being the least significant lane; a masked lane is not compared, so it is
    zeroed on both sides.
    """
    off = (addr - 0x08000000) & ~3
    if off < 0 or off + 4 > len(rom):
        return None
    word = int.from_bytes(rom[off:off + 4], "little")
    keep = 0
    for lane in range(4):
        if be & (1 << lane):
            keep |= 0xFF << (8 * lane)
    return word & keep


def load_capture(path):
    rows = []
    truncated = 0
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f]
    for n, line in enumerate(lines, 1):
        if not line.startswith("CARTREAD:"):
            continue
        m = LINE.match(line)
        if not m:
            # A capture read while the run was still writing can end mid-line.
            # That is an artefact of reading a live file, not a machine result,
            # so the incomplete tail is counted and skipped rather than aborting
            # the whole analysis (TCL-023).
            truncated += 1
            continue
        addr, be, now, prev = m.groups()
        rows.append((int(addr, 16), int(be, 16), int(now, 16), int(prev, 16)))
    if truncated:
        print(f"{path}: skipped {truncated} incomplete line(s) at the end of the capture")
    return rows


def score(rows, rom, column):
    """How many captured reads the given column reproduces exactly."""
    ok = bad = 0
    for addr, be, now, prev in rows:
        want = rom_word(rom, addr, be)
        if want is None:
            continue
        got = now if column == "now" else prev
        if want == (got & mask_for(be)):
            ok += 1
        else:
            bad += 1
    return ok, bad


def mask_for(be):
    m = 0
    for lane in range(4):
        if be & (1 << lane):
            m |= 0xFF << (8 * lane)
    return m
def report(path, rows, rom, column):
    ok, bad = score(rows, rom, column)
    total = ok + bad
    print(f"{path}: {total} reads checked, {ok} match the ROM, {bad} do not"
          f"  (column data_{column})")
    if bad:
        shown = 0
        for addr, be, now, prev in rows:
            want = rom_word(rom, addr, be)
            if want is None:
                continue
            got = (now if column == "now" else prev) & mask_for(be)
            if got != want:
                if shown < 10:
                    print(f"  addr={addr:08x} be={be:x} rom={want:08x} got={got:08x}")
                    shown += 1
        if bad > shown:
            print(f"  ... and {bad - shown} more")
    return bad


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[10], file=sys.stderr)
        return 2
    rom = load_rom(argv[1])

    caps = []
    for p in argv[2:]:
        rows = load_capture(p)
        if rows is None:
            return 2
        caps.append((p, rows))

    # Calibrate on the first capture supplied, which by convention is the build
    # whose machine is known to work.
    name, rows = caps[0]
    ok_now, _ = score(rows, rom, "now")
    ok_prev, _ = score(rows, rom, "prev")
    column = "now" if ok_now >= ok_prev else "prev"
    print(f"calibrating on {name}: data_now matches {ok_now}, "
          f"data_prev matches {ok_prev} -> using data_{column}\n")

    failures = 0
    for p, r in caps:
        failures += report(p, r, rom, column)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
