#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Assemble any probe cartridge kept in `tools/roms/` into a loadable GBA image.

Why this exists.  Several probes were written this session as bare assembly and
assembled by hand into `/tmp`, which is a practice `core.md` does not allow: a
diagnostic the operator is meant to run has to be produced by a committed,
deterministic script.  So the sources live in `tools/roms/` and this tool does the
assembly, patches the complement byte, and pads the image.

Each probe is a flat ARM image: a branch to `_start`, the Nintendo logo at 0x04,
the header fields at 0xA0..0xBB, and code from 0xC0.  The complement check at
0xBD is computed here rather than in the assembly, because it depends on bytes the
assembler cannot see.

    tools/make_probe_rom.py --list
    tools/make_probe_rom.py byteprobe            -> build/test/byteprobe.gba
    tools/make_probe_rom.py all --out-dir build/test

Every probe in this directory is a discriminator: it paints green where the
machine behaved and red where it did not, so a result can be read from a screen
rather than inferred.  TCL-041 applies to all of them -- run the image under mGBA
and require it to pass there before reading its board result, because a probe that
fails in the emulator is telling you about itself.
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRCDIR = os.path.join(ROOT, "tools", "roms")
IMAGE_SIZE = 0x1000
COMPLEMENT_FIXED = 0x19


def find_toolchain(explicit):
    cand = explicit or os.path.expanduser(
        "~/tools/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin")
    if not os.path.isdir(cand):
        as_path = shutil.which("arm-none-eabi-as")
        cand = os.path.dirname(as_path) if as_path else ""
    as_bin = os.path.join(cand, "arm-none-eabi-as") if cand else ""
    oc_bin = os.path.join(cand, "arm-none-eabi-objcopy") if cand else ""
    if not (os.path.isfile(as_bin) and os.access(as_bin, os.X_OK)):
        raise SystemExit("arm-none-eabi-as not found; set ARM_TOOLCHAIN to its bin dir")
    if not (os.path.isfile(oc_bin) and os.access(oc_bin, os.X_OK)):
        raise SystemExit(f"arm-none-eabi-objcopy not found beside {as_bin}")
    return as_bin, oc_bin


def build(name, as_bin, oc_bin, out_dir):
    src = os.path.join(SRCDIR, name + ".s")
    if not os.path.isfile(src):
        raise SystemExit(f"no such probe: {src}")
    out = os.path.join(out_dir, name + ".gba")
    os.makedirs(out_dir, exist_ok=True)
    obj = os.path.join(out_dir, name + ".o")
    binf = os.path.join(out_dir, name + ".bin")

    subprocess.run([as_bin, "-mcpu=arm7tdmi", "-EL", "-o", obj, src], check=True)
    subprocess.run([oc_bin, "-O", "binary", "--only-section=.text", obj, binf],
                   check=True)
    with open(binf, "rb") as f:
        img = bytearray(f.read())

    if len(img) > IMAGE_SIZE:
        raise SystemExit(f"{name}: image is {len(img)} bytes, over the {IMAGE_SIZE}"
                         " budget; raise IMAGE_SIZE deliberately rather than letting"
                         " the header fields shift")
    img.extend(b"\0" * (IMAGE_SIZE - len(img)))

    # The header fields have to sit at fixed offsets, so check them rather than
    # trusting the source layout: a one-byte slip in a title string moves every
    # field after it, and the BIOS then refuses the cartridge.
    if img[0xB2] != 0x96:
        raise SystemExit(f"{name}: header byte 0xB2 is {img[0xB2]:#04x}, expected 0x96"
                         " -- the title or game-code padding has shifted the header")
    chk = (-(sum(img[0xA0:0xBD]) + COMPLEMENT_FIXED)) & 0xFF
    img[0xBD] = chk
    with open(out, "wb") as f:
        f.write(img)

    for p in (obj, binf):
        try:
            os.unlink(p)
        except OSError:
            pass
    return out, chk


def main(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("probe", nargs="?", help="probe name, 'all', or --list")
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "build", "test"))
    ap.add_argument("--toolchain", default=None)
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args(argv[1:])

    probes = sorted(f[:-2] for f in os.listdir(SRCDIR) if f.endswith(".s"))
    if args.list or not args.probe:
        print("probes in tools/roms/:")
        for p in probes:
            print("  " + p)
        return 0

    as_bin, oc_bin = find_toolchain(args.toolchain)
    names = probes if args.probe == "all" else [args.probe]
    for name in names:
        out, chk = build(name, as_bin, oc_bin, args.out_dir)
        print(f"{out}: complement ${chk:02X}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
