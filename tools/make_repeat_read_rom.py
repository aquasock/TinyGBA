#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read one cartridge address eight times and report every result.

Why.  `tools/make_mask_report_rom.py` produced a mask saying the ROM reads at
`0x08000400` and `0x08000800` failed, while the same program's later detail reads
of those exact addresses returned the correct words.  Same program, same
addresses, different results -- so either the first read of a location differs
from a later read of it, or the probe is wrong.  This cartridge decides that
without an FPGA rebuild.

It reads `0x08000400` eight times in a row, back to back, and stores each result
to its own unused IO address so the MMIO ring captures all eight as distinct
entries:

    IO+0x090 .. IO+0x0AC   result 0 .. result 7, one 32-bit store each

The expected word at `0x08000400` is `0xA5A50001`.  Entries that read that value
passed; anything else is what the read actually returned.  If the first entry
differs and the rest match, the first access to a cartridge location returns
stale data and later accesses are fine.  If all eight match, the mask report's
bits 0 and 1 were a defect in that probe, not a property of the machine.

Usage:
    tools/make_repeat_read_rom.py -o build/test/repread.gba \
        --logo-from build/test/test_logo.gba
"""

import argparse
import os
import subprocess
import sys

IMAGE_SIZE = 4096
COMPLEMENT_FIXED = 0x19
TARGET_ADDR = 0x08000400
TARGET_WORD = 0xA5A50001
READS = 8

ASM = r"""
    .arm
    .section .text

    b       _start

    .space  156

    .ascii  "REPREAD00001"
    .ascii  "TGBT"
    .ascii  "01"
    .byte   0x96
    .byte   0x00
    .byte   0x00
    .space  7
    .byte   0x00
    .byte   0x00
    .space  2

_start:                             @ 0x0C0
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]               @ DISPCNT = 0, same context as the real probe

    @ Read the same cartridge word eight times, storing each result to its own
    @ IO address so the ring shows all eight rather than only the last.
    mov     r6, #0x08000000
    add     r6, r6, #0x400
    mov     r12, #0

read_loop:
    ldr     r4, [r6]
    add     r7, r11, r12, lsl #2
    add     r7, r7, #0x90
    str     r4, [r7]
    add     r12, r12, #1
    cmp     r12, #8
    bne     read_loop

    mov     r3, #0
spin:
    add     r3, r3, #1
    b       spin

    .ltorg

    .org    0x400
    .word   0xA5A50001
"""

PREAMBLE = ".syntax unified\n.arch armv4t\n"


def find_toolchain(explicit):
    cand = explicit or os.path.expanduser(
        "~/tools/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin")
    as_bin = os.path.join(cand, "arm-none-eabi-as")
    oc_bin = os.path.join(cand, "arm-none-eabi-objcopy")
    if not (os.path.isfile(as_bin) and os.access(as_bin, os.X_OK)):
        raise SystemExit(f"arm-none-eabi-as not found at {as_bin}")
    if not (os.path.isfile(oc_bin) and os.access(oc_bin, os.X_OK)):
        raise SystemExit(f"arm-none-eabi-objcopy not found at {oc_bin}")
    return as_bin, oc_bin


def complement_check(image):
    return (-(COMPLEMENT_FIXED + sum(image[0xA0:0xBD]))) & 0xFF


def build(as_bin, oc_bin, workdir, logo_from):
    src = os.path.join(workdir, "repread.s")
    obj = os.path.join(workdir, "repread.o")
    binpath = os.path.join(workdir, "repread.bin")
    with open(src, "w") as f:
        f.write(PREAMBLE + ASM)
    subprocess.run([as_bin, "-mcpu=arm7tdmi", "-EL", "-o", obj, src], check=True)
    subprocess.run([oc_bin, "-O", "binary", "--only-section=.text", obj, binpath],
                   check=True)
    with open(binpath, "rb") as f:
        raw = f.read()
    if len(raw) > IMAGE_SIZE:
        raise SystemExit(f"image is {len(raw)} bytes, over {IMAGE_SIZE}")
    image = bytearray(raw) + bytearray(IMAGE_SIZE - len(raw))
    if logo_from:
        with open(logo_from, "rb") as f:
            retail = f.read()
        logo = retail[0x04:0xA0]
        if len(logo) != 156:
            raise SystemExit(f"{logo_from} is too short to hold a header")
        image[0x04:0xA0] = logo
    image[0xBD] = complement_check(image)
    return bytes(image), obj


def verify(image):
    bad = []
    if len(image) != IMAGE_SIZE:
        bad.append(f"size is {len(image)}")
    if int.from_bytes(image[0:4], "little") != 0xEA00002E:
        bad.append("entry branch is not b 0x0C0")
    if image[0xA0:0xAC] != b"REPREAD00001":
        bad.append("title bytes are wrong")
    if image[0xB2] != 0x96:
        bad.append("header fixed value is wrong")
    if image[0xBD] != complement_check(image):
        bad.append("complement check is wrong")
    got = int.from_bytes(image[TARGET_ADDR - 0x08000000:
                              TARGET_ADDR - 0x08000000 + 4], "little")
    if got != TARGET_WORD:
        bad.append(f"target constant is 0x{got:08X}, expected 0x{TARGET_WORD:08X}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="build/test/repread.gba")
    ap.add_argument("--logo-from", default=None)
    ap.add_argument("--toolchain", default=None)
    ap.add_argument("--keep-asm", action="store_true")
    args = ap.parse_args()

    as_bin, oc_bin = find_toolchain(args.toolchain)
    outdir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(outdir, exist_ok=True)
    image, obj = build(as_bin, oc_bin, outdir, args.logo_from)
    bad = verify(image)
    if bad:
        for b in bad:
            print(f"  FAIL {b}", file=sys.stderr)
        return 1
    with open(args.output, "wb") as f:
        f.write(image)
    if not args.keep_asm:
        for p in (obj, obj[:-1] + "s"):
            if os.path.exists(p):
                os.remove(p)
    print(f"wrote {args.output} ({len(image)} bytes)")
    print(f"  reads 0x{TARGET_ADDR:08X} {READS} times, expecting "
          f"0x{TARGET_WORD:08X} each time")
    print(f"  results land at IO+0x090 .. IO+0x0AC, one ring entry each")
    return 0


if __name__ == "__main__":
    sys.exit(main())
