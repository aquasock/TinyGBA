#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a cartridge that tests the PC-relative literal load, and nothing else.

Why.  On the board the machine runs a test cartridge whose self-checks fail and
which then leaves DISPCNT holding `0xFFE0` -- forced blank, which is why every
capture is white.  `0xFFE0` is the value of the LAST literal in that cartridge's
pool before the one it means to load, and the intended value, `0x0403`, sits four
bytes after it at `0x080002DC` and `0x080002E0` respectively.  A CPU that computed
a PC-relative literal address four bytes too low would read the yellow and write
it to the display register, and would also mis-read the check constants, which
explains the failed checks from the same single mechanism.

That is a hypothesis, not a finding -- three earlier hypotheses on this machine
were wrong -- so this cartridge is built to distinguish the cases in one picture
rather than to support it.  It uses no literal for the IO base and none for the
display value, so a broken literal path cannot garble the test's own setup, and
it then loads three literals in a known pool order and writes each to a distinct
IO register.  Read the MMIO ring with `tools/decode_fetchtrace.py`:

    DISPCNT  0x00  written from mov/add only        -> must read 0x0403
    DISPSTAT 0x04  written from the middle literal  -> the measurement
    VCOUNT   0x06  written from the first literal   -> control
    BLDCNT   0x08  written from the last literal    -> control

The pool is laid out as [0x1111AAAA, 0x00000403, 0x2222BBBB].  A store of
`0xAAAA` to DISPSTAT means the literal address came out one word early, `0xBBBB`
means one word late, and `0x0403` means the literal path is correct and the fault
is somewhere else entirely.

Usage:
    tools/make_literal_probe_rom.py -o build/test/litprobe.gba \
        --logo-from build/test/test_logo.gba
"""

import argparse
import os
import subprocess
import sys

IMAGE_SIZE = 4096
COMPLEMENT_FIXED = 0x19

ASM = r"""
    .arm
    .section .text

    @ ---------------------------------------------------------- cartridge header
    b       _start

    @ 0x004: Nintendo logo, spliced in by the builder when --logo-from is given.
    .space  156

    @ 0x0A0: title, game code, maker code.
    .ascii  "LITPROBE0001"
    .ascii  "TGBT"
    .ascii  "01"
    .byte   0x96                    @ fixed value
    .byte   0x00                    @ unit code
    .byte   0x00                    @ device type: 0 = ROM
    .space  7                       @ reserved
    .byte   0x00                    @ software version
    .byte   0x00                    @ complement check, patched by the builder
    .space  2                       @ reserved

    @ ------------------------------------------------------------------- entry
_start:                             @ 0x0C0
    @ The IO base is built with a rotated immediate, not a literal, so a broken
    @ literal path cannot make the test point somewhere else.
    mov     r11, #0x4000000         @ 0x04000000

    @ Control 1: DISPCNT from mov/add only.  Whatever else is wrong, this must
    @ read back 0x0403; if it does not, the fault is not in the literal loader.
    mov     r0, #0x400
    add     r0, r0, #3              @ 0x403
    strh    r0, [r11]               @ DISPCNT

    @ The three literals, referenced in the order they must be laid out in the
    @ pool.  `ldr Rd, =value` puts the word in the nearest pool; `.ltorg` below
    @ fixes where that is, and the reference order fixes the order inside it.
    ldr     r4, =0x1111AAAA         @ pool[0]
    ldr     r5, =0x0403             @ pool[1] -- the one under test
    ldr     r6, =0x2222BBBB         @ pool[2]

    @ Report each one to its own register so the ring separates them.
    add     r7,  r11, #4
    strh    r5, [r7]                @ DISPSTAT <= the tested literal
    add     r8,  r11, #6
    strh    r4, [r8]                @ VCOUNT   <= pool[0], the control
    add     r9,  r11, #8
    strh    r6, [r9]                @ BLDCNT   <= pool[2], the control

    @ Stay put, so the captured state is the steady state.
    mov     r2, #0
spin:
    add     r2, r2, #1
    b       spin

    .ltorg
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
    src = os.path.join(workdir, "litprobe.s")
    obj = os.path.join(workdir, "litprobe.o")
    binpath = os.path.join(workdir, "litprobe.bin")
    with open(src, "w") as f:
        f.write(PREAMBLE + ASM)
    subprocess.run([as_bin, "-mcpu=arm7tdmi", "-EL", "-o", obj, src], check=True)
    subprocess.run([oc_bin, "-O", "binary", "--only-section=.text", obj, binpath],
                   check=True)
    with open(binpath, "rb") as f:
        raw = f.read()
    if len(raw) > IMAGE_SIZE:
        raise SystemExit(f"image is {len(raw)} bytes, over the {IMAGE_SIZE} limit")
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="build/test/litprobe.gba")
    ap.add_argument("--logo-from", default=None)
    ap.add_argument("--toolchain", default=None)
    ap.add_argument("--keep-asm", action="store_true")
    args = ap.parse_args()

    as_bin, oc_bin = find_toolchain(args.toolchain)
    outdir = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(outdir, exist_ok=True)
    image, obj = build(as_bin, oc_bin, outdir, args.logo_from)
    with open(args.output, "wb") as f:
        f.write(image)
    if not args.keep_asm:
        for p in (obj, obj[:-1] + "s"):
            if os.path.exists(p):
                os.remove(p)

    # Print what the image is supposed to do, so the expectation is on record
    # beside the artefact rather than recomputed later from a decoder that could
    # itself be wrong.
    print(f"wrote {args.output} ({len(image)} bytes)")
    print("  entry   0x080000C0, DISPCNT <= 0x0403 built from mov/add only")
    print("  DISPSTAT <= pool[1]: 0x0403 correct | 0xAAAA one word early | "
          "0xBBBB one word late")
    print("  VCOUNT   <= pool[0]: 0xAAAA    BLDCNT <= pool[2]: 0xBBBB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
