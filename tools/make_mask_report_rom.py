#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the self-checking test cartridge, but report through IO, not the screen.

Why this exists.  `tools/make_gba_test_rom.py` draws its result on the
framebuffer: green if every check passed, red plus one yellow column per failed
check.  That works until the display register itself is the thing under
suspicion, and then the report is unreadable -- which is exactly where this
project is.  The machine leaves DISPCNT holding forced blank, so every capture is
white and the yellow columns are invisible.

This cartridge runs the same eight checks and then reports the failure mask as
halfword stores into unused IO addresses, where the MMIO write ring can read them
with no dependency on the display path at all:

    0x04000090 <= mask        the eight check results, bit 0 first
    0x04000094 <= ~mask       the same value inverted, so a store that does not
                              land is distinguishable from a mask of zero
    0x04000098 <= 0xBEEF      always, so a run that never reaches the report is
                              distinguishable from one that reports all-clear

Those three addresses are unused in the GBA IO map (0x90 to 0x9F), so the writes
have no side effect.  Nothing is written to VRAM and the display is never enabled,
so the picture stays blank and cannot confuse the reading.

The checks are the same eight, in the same order, as the on-screen version:

    bit 0..2   ROM reads at 0x08000400, 0x08000800, 0x08000C00
    bit 3..6   IWRAM bottom/top, EWRAM bottom/top word-and-byte-lane checks
    bit 7      VRAM halfword at 0x0600FF00

A zero mask with the marker present and the inverted word present means every
check passed and the fault is downstream of memory entirely -- in the display
handover.  A non-zero mask names the failing check by bit position.

Usage:
    tools/make_mask_report_rom.py -o build/test/maskprobe.gba \
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

    .ascii  "MASKPROBE001"
    .ascii  "TGBT"
    .ascii  "01"
    .byte   0x96
    .byte   0x00
    .byte   0x00
    .space  7
    .byte   0x00
    .byte   0x00
    .space  2

    @ ------------------------------------------------------------------- entry
_start:                             @ 0x0C0
    ldr     r11, =0x04000000        @ IO base
    mov     r0, #0
    strh    r0, [r11]               @ DISPCNT = 0, force blank as before
    mov     r10, #0                 @ failure mask, one bit per check

    @ ---------------------------------------------- bits 0..2: cartridge reads
    mov     r6, #0x08000000
    add     r6, r6, #0x400
    ldr     r4, [r6]
    ldr     r5, =0xA5A50001
    cmp     r4, r5
    orrne   r10, r10, #1

    mov     r6, #0x08000000
    add     r6, r6, #0x800
    ldr     r4, [r6]
    ldr     r5, =0xA5A50002
    cmp     r4, r5
    orrne   r10, r10, #2

    mov     r6, #0x08000000
    add     r6, r6, #0xC00
    ldr     r4, [r6]
    ldr     r5, =0xA5A50003
    cmp     r4, r5
    orrne   r10, r10, #4

    @ ---------------------------------------- bits 3..6: work RAM, word + lanes
    ldr     r6, =0x03000000
    bl      memchk3
    ldr     r6, =0x03007E00
    bl      memchk4
    ldr     r6, =0x02000000
    bl      memchk5
    ldr     r6, =0x0203FE00
    bl      memchk6

    @ ------------------------------------------------- bit 7: VRAM halfword
    ldr     r6, =0x0600FF00
    ldr     r5, =0x7BDE
    strh    r5, [r6]
    ldrh    r4, [r6]
    cmp     r4, r5
    orrne   r10, r10, #128

    @ ------------------------------------- exact words read back, for detail
    @ Three more unused IO addresses carry what the ROM checks actually got, so a
    @ failing bit can be attributed to data rather than inferred from pass/fail.
    mov     r6, #0x08000000
    add     r6, r6, #0x400
    ldr     r4, [r6]
    add     r7, r11, #0xA0
    str     r4, [r7]                @ what 0x08000400 returned

    mov     r6, #0x08000000
    add     r6, r6, #0x800
    ldr     r4, [r6]
    add     r8, r11, #0xA4
    str     r4, [r8]                @ what 0x08000800 returned

    mov     r6, #0x08000000
    add     r6, r6, #0xC00
    ldr     r4, [r6]
    add     r9, r11, #0xA8
    str     r4, [r9]                @ what 0x08000C00 returned

    @ ----------------------------------------------------------- report via IO
    @ Unused IO addresses, so these stores have no side effect; the MMIO ring
    @ records them and the display path is never involved.
    add     r7, r11, #0x90
    strh    r10, [r7]               @ mask

    mvn     r1, r10
    add     r8, r11, #0x94
    strh    r1, [r8]                @ ~mask

    ldr     r2, =0xBEEF
    add     r9, r11, #0x98
    strh    r2, [r9]                @ marker: this run reached the report

    @ Stay put; the captured state is the steady state.
    mov     r3, #0
spin:
    add     r3, r3, #1
    b       spin

    @ A word compare plus two byte lanes, so a swapped lane fails.
    @ Entry: r6 = address to test, r10 = mask, bit in r12.
memchk3: mov    r12, #8
         b      memchk
memchk4: mov    r12, #16
         b      memchk
memchk5: mov    r12, #32
         b      memchk
memchk6: mov    r12, #64
memchk:
    ldr     r5, =0x12345678
    str     r5, [r6]
    ldr     r4, [r6]
    cmp     r4, r5
    orrne   r10, r10, r12
    ldrb    r4, [r6]
    cmp     r4, #0x78
    orrne   r10, r10, r12
    ldrb    r4, [r6, #3]
    cmp     r4, #0x12
    orrne   r10, r10, r12
    bx      lr

    .ltorg

    .org    0x400
    .word   0xA5A50001
    .org    0x800
    .word   0xA5A50002
    .org    0xC00
    .word   0xA5A50003
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
    src = os.path.join(workdir, "maskprobe.s")
    obj = os.path.join(workdir, "maskprobe.o")
    binpath = os.path.join(workdir, "maskprobe.bin")
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
    if image[0xA0:0xAC] != b"MASKPROBE001":
        bad.append("title bytes are wrong")
    if image[0xB2] != 0x96:
        bad.append("header fixed value is wrong")
    if image[0xBD] != complement_check(image):
        bad.append("complement check is wrong")
    for off, val in ((0x400, 0xA5A50001), (0x800, 0xA5A50002), (0xC00, 0xA5A50003)):
        got = int.from_bytes(image[off:off + 4], "little")
        if got != val:
            bad.append(f"constant at 0x{off:03X} is 0x{got:08X}, expected 0x{val:08X}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="build/test/maskprobe.gba")
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
    print(f"wrote {args.output} ({len(image)} bytes), all header and constant "
          f"checks pass")
    print("  IO+0x090 <= mask     bit0..2 = ROM reads, bit3..6 = IWRAM/EWRAM, "
          "bit7 = VRAM")
    print("  IO+0x094 <= ~mask    must be the complement; catches a store that "
          "did not land")
    print("  IO+0x098 <= 0xBEEF   marker: this run reached the report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
