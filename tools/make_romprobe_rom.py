#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a cartridge that reads a known word from every 64 KiB of its own image.

Why this exists.  `test_logo` is 4 KiB and works.  `test_logo`'s checks read at
`0x08000400`, `0x08000800` and `0x08000C00` -- inside the first 4 KiB.  Every
cartridge that fails on this machine is large: the RetroRegen diagnostic cart is
284 KiB and Super Mario Advance is 4 MiB.  The RetroRegen cart fails in a
particular way worth naming: its text draws at the correct position, height,
scale and colour, with wrong glyph *patterns*.  Position comes from the drawer's
scan counters, content comes from memory, so that signature is what a cartridge
looks like when its code runs and its data comes back wrong.

Nothing so far has tested a cartridge read above 4 KiB on the board.  The v7
trace's pool records sit at `0x080002xx`.  So this cartridge asks the smallest
question that could explain the symptom: does a word stored at offset N read back
as itself, for N across the whole image?

It stores `N` itself at offset `N`, for N = 1 MiB down to 64 KiB, so no expected
value needs a table: the datum is its own address.  Then it reads each one and
paints a 15x15 square per checkpoint across the top of the screen:

    green  0x03E0   the word read back matched
    red    0x001F   it did not

Checkpoints run left to right for N = 0x10000, 0x20000, ... 0xF0000, which is
15 squares of 15 pixels = 225 of the 240 the screen has.  The image is 1 MiB, so
the last checkpoint sits at 0xF0000, inside the image.  A screen that is green
across answers the question for the first megabyte; a red square names the first
offset that fails, and its position gives the value.

    tools/make_romprobe_rom.py -o build/test/romprobe.gba
"""
import argparse
import os
import shutil
import subprocess
import sys

PREAMBLE = """\
    .arm
    .section .text
    b       _start
    @ 0x04: Nintendo logo.  It must start here: the BIOS validates the 156 bytes
    @ at 0x04..0x9F and refuses the cartridge otherwise.
    .byte   0x24,0xff,0xae,0x51,0x69,0x9a,0xa2,0x21
    .byte   0x3d,0x84,0x82,0x0a,0x84,0xe4,0x09,0xad
    .byte   0x11,0x24,0x8b,0x98,0xc0,0x81,0x7f,0x21
    .byte   0xa3,0x52,0xbe,0x19,0x93,0x09,0xce,0x20
    .byte   0x10,0x46,0x4a,0x4a,0xf8,0x27,0x31,0xec
    .byte   0x58,0xc7,0xe8,0x33,0x82,0xe3,0xce,0xbf
    .byte   0x85,0xf4,0xdf,0x94,0xce,0x4b,0x09,0xc1
    .byte   0x94,0x56,0x8a,0xc0,0x13,0x72,0xa7,0xfc
    .byte   0x9f,0x84,0x4d,0x73,0xa3,0xca,0x9a,0x61
    .byte   0x58,0x97,0xa3,0x27,0xfc,0x03,0x98,0x76
    .byte   0x23,0x1d,0xc7,0x61,0x03,0x04,0xae,0x56
    .byte   0xbf,0x38,0x84,0x00,0x40,0xa7,0x0e,0xfd
    .byte   0xff,0x52,0xfe,0x03,0x6f,0x95,0x30,0xf1
    .byte   0x97,0xfb,0xc0,0x85,0x60,0xd6,0x80,0x25
    .byte   0xa9,0x63,0xbe,0x03,0x01,0x4e,0x38,0xe2
    .byte   0xf9,0xa2,0x34,0xff,0xbb,0x3e,0x03,0x44
    .byte   0x78,0x00,0x90,0xcb,0x88,0x11,0x3a,0x94
    .byte   0x65,0xc0,0x7c,0x63,0x87,0xf0,0x3c,0xaf
    .byte   0xd6,0x25,0xe4,0x8b,0x38,0x0a,0xac,0x72
    .byte   0x21,0xd4,0xf8,0x07
    .ascii  "ROMPROBE\\0\\0\\0\\0"
    .ascii  "RMPB"
    .ascii  "01"
    .byte   0x96
    .space  9
    .space  4
"""

# The checkpoints, as the program sees them: index i (1..15) means offset i<<16.
CHECKPOINTS = 15

ASM = """\
_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]               @ forced blank while frame memory is written
    ldr     r0, =0x0403
    strh    r0, [r11]               @ mode 3, BG2 on

    @ Clear the whole screen to black first, so a square that is never painted
    @ is visibly absent rather than inheriting whatever was there.
    ldr     r9, =0x06000000
    mov     r4, #0
clr:
    mov     r0, #0
    add     r3, r9, r4, lsl #1
    strh    r0, [r3]
    add     r4, r4, #1
    ldr     r1, =38400
    cmp     r4, r1
    bne     clr

    ldr     r8, =0x08000000         @ cartridge base
    mov     r6, #1                  @ i = 1 .. 15
cp_loop:
    mov     r10, r6, lsl #16        @ offset = i << 16
    add     r3, r8, r10
    ldr     r2, [r3]                @ read the word stored there
    cmp     r2, r10
    ldreq   r5, =0x03E0             @ green: read back matched
    ldrne   r5, =0x001F             @ red: it did not

    @ Paint a 15x15 square at x = (i-1)*15, y = 0.
    sub     r0, r6, #1
    mov     r1, #15
    mul     r0, r1, r0              @ x0 = (i-1)*15
    mov     r4, #0                  @ y
sq_y:
    mov     r3, #0                  @ x within square
sq_x:
    @ addr = (y*240 + x0 + r3) * 2
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r0
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #15
    bne     sq_x
    add     r4, r4, #1
    cmp     r4, #15
    bne     sq_y

    add     r6, r6, #1
    cmp     r6, #16
    bne     cp_loop

    ldr     r11, =0x04000000
    ldr     r0, =0x0403
    strh    r0, [r11]               @ display on
hang:
    b       hang
    .ltorg
"""

IMAGE_SIZE = 0x100000          # 1 MiB, so the 0xF0000 checkpoint is in range
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


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="build/test/romprobe.gba")
    ap.add_argument("--toolchain", default=None)
    args = ap.parse_args(argv[1:])

    as_bin, oc_bin = find_toolchain(args.toolchain)
    work = os.path.dirname(os.path.abspath(args.out)) or "."
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "romprobe.s")
    obj = os.path.join(work, "romprobe.o")
    binf = os.path.join(work, "romprobe.bin")

    with open(src, "w") as f:
        f.write(PREAMBLE + ASM)
    subprocess.run([as_bin, "-mcpu=arm7tdmi", "-EL", "-o", obj, src], check=True)
    subprocess.run([oc_bin, "-O", "binary", "--only-section=.text", obj, binf],
                   check=True)
    with open(binf, "rb") as f:
        img = bytearray(f.read())

    img.extend(b"\0" * (IMAGE_SIZE - len(img)))

    # Each checkpoint stores its own offset, so the datum is its own address and
    # the test needs no table: at offset i<<16 the word is i<<16.
    for i in range(1, CHECKPOINTS + 1):
        off = i << 16
        img[off:off + 4] = (off & 0xFFFFFFFF).to_bytes(4, "little")

    chk = (-(sum(img[0xA0:0xBD]) + COMPLEMENT_FIXED)) & 0xFF
    img[0xBD] = chk
    with open(args.out, "wb") as f:
        f.write(img)

    for p in (src, obj, binf):
        try:
            os.unlink(p)
        except OSError:
            pass

    print(f"{args.out}: {len(img)} bytes, complement ${chk:02X}")
    print(f"  checkpoints at offsets " +
          ", ".join(f"0x{i << 16:05X}" for i in range(1, CHECKPOINTS + 1)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
