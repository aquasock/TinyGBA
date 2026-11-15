#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Assemble a bare-metal GBA probe ROM from one .s file.

Why this exists.  `tools/roms/*.s` are committed as source, and
`build/test/saveprobe.gba` was committed as a binary with no recipe beside it,
so the only way to change a probe was to reconstruct the build by hand.  That
is exactly what happened during the save investigation: reproducing the
committed 4096-byte image from its own source took three guesses (the pad
length, the header complement, and whether the assembler target mattered), and
the first two produced a file that differed from the committed one at the
complement byte.  A probe whose binary cannot be rebuilt from its source is not
reproducible evidence, so the recipe is recorded here.

The image layout is the one `tools/roms/saveprobe.s` already carries: a branch
at 0, the 156-byte Nintendo logo, the title at 0xA0, the fixed 0x96 at 0xB2,
and code from 0xC0.  Two bytes are computed rather than assembled, which is why
this cannot be a bare `as` followed by `objcopy`:

  * 0xB2 is the fixed value 0x96 every cartridge header carries.  It is in the
    source already, and is asserted here so a future source that drops it fails
    rather than producing an image the BIOS would reject.
  * 0xBD is the header complement: `-(sum of bytes 0xA0..0xBC) - 0x19`.  The
    BIOS and the core both check it, and a wrong value is a silent refusal.

    tools/make_probe_bin.py tools/roms/saveprobe.s build/test/saveprobe.gba
    tools/make_probe_bin.py a.s out.gba --size 8192
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

TOOLCHAIN = "~/tools/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin"
HEADER_FIXED_OFF = 0xB2
HEADER_FIXED_VAL = 0x96
COMPLEMENT_OFF = 0xBD
COMPLEMENT_BASE = 0x19


def find_tool(name):
    found = shutil.which(name)
    if found:
        return found
    candidate = os.path.expanduser(os.path.join(TOOLCHAIN, name))
    if os.path.exists(candidate):
        return candidate
    raise SystemExit(f"{name} not found; set ARM_TOOLCHAIN to its bin directory")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("output")
    ap.add_argument("--size", type=int, default=4096,
                    help="pad the image to this many bytes (default 4096)")
    args = ap.parse_args()

    as_bin = find_tool("arm-none-eabi-as")
    oc_bin = find_tool("arm-none-eabi-objcopy")

    with tempfile.TemporaryDirectory() as work:
        obj = os.path.join(work, "probe.o")
        raw = os.path.join(work, "probe.bin")
        # --fatal-warnings is load-bearing, not tidiness.  `as` accepts a
        # handful of instructions it warns about and still encodes them, and on
        # ARM7TDMI those encodings are UNPREDICTABLE at run time: `mul r8, r9,
        # r8` (Rd == Rm) is the one that bit this project, and the resulting
        # probe drew plausible-looking squares in the wrong places rather than
        # failing.  A build that cannot fail is not a check, so a warning here
        # is a build error.
        subprocess.run([as_bin, "-mcpu=arm7tdmi", "--fatal-warnings",
                        "-o", obj, args.source], check=True)
        subprocess.run([oc_bin, "-O", "binary", obj, raw], check=True)
        image = bytearray(open(raw, "rb").read())

    if len(image) > args.size:
        raise SystemExit(f"{args.source}: {len(image)} bytes exceeds --size {args.size}")
    image.extend(b"\x00" * (args.size - len(image)))

    if len(image) <= COMPLEMENT_OFF:
        raise SystemExit(f"{args.source}: image too short to carry a header")
    if image[HEADER_FIXED_OFF] != HEADER_FIXED_VAL:
        raise SystemExit(
            f"{args.source}: byte 0x{HEADER_FIXED_OFF:02X} is "
            f"0x{image[HEADER_FIXED_OFF]:02X}, must be 0x{HEADER_FIXED_VAL:02X}")
    image[COMPLEMENT_OFF] = (
        -sum(image[0xA0:COMPLEMENT_OFF]) - COMPLEMENT_BASE) & 0xFF

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "wb") as fh:
        fh.write(image)
    print(f"{args.output}: {len(image)} bytes, complement 0x{image[COMPLEMENT_OFF]:02X}")


if __name__ == "__main__":
    sys.exit(main())
