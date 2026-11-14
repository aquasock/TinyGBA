#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a cartridge that tests the VRAM address path, which nothing else has.

Why this exists.  `test_logo` writes the same colour to every halfword of VRAM, so
it cannot see an address fault: fetch the wrong address and it still reads green.
That is exactly why a green field is not evidence that the display path is
correct, and why the RetroRegen diagnostic cartridge -- the first thing here to
write *varied* data into frame memory -- is the first thing to show corruption.
Its text draws at the correct position, height and scale, with wrong glyph
patterns, which is the signature of reading or writing the wrong address rather
than of a broken layout.

What this builds.  Mode 3 (bitmap, BG2), full screen.  For each halfword at
index n from 0, it writes a value that encodes n itself:

    colour(n) = 0x7FFF - (n & 0x3FF)          ... low 10 bits of n, inverted

Written as four vertical bands so a human can read the screen without a decoder:

    band 0  x   0.. 59   colour = 0x001F | ((y*2) << 5)      blue ramp, 160 steps
    band 1  x  60..119   colour = 0x03E0 | (x_band << 0)     green + x offset
    band 2  x 120..179   colour = 0x7C00 | (y_band << 0)     red + y offset
    band 3  x 180..239   colour = (x_band*2) | (y_band << 5)  two-axis pattern

The point of the fourth band is that its value depends on BOTH coordinates, so a
row or column address fault shows as a visible scramble rather than as a uniform
shift.  Then the cartridge reads each halfword back and compares it with what it
wrote, and paints the border white on any mismatch, so a wrong *store* is
distinguished from a wrong *fetch*: if every halfword reads back correctly and the
screen still looks wrong, the fault is in the drawer's read side.

    tools/make_vram_probe_rom.py -o build/test/vramprobe.gba
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys

# The ARM branch at offset 0 jumps to 0xC0, where the code starts.
PREAMBLE = """\
    .arm
    .section .text
    b       _start
    @ 0x04: Nintendo logo, checked by the BIOS before it will hand over.
    @ It must start here, not at 0x40: the BIOS validates the 156 bytes at 0x04..0x9F
    @ and refuses the cartridge otherwise.  A first version of this file put the
    @ logo after a .space and produced an image the loader rejected.
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
    @ 0xA0: title, then the fixed header bytes the BIOS checks.
    .ascii  "VRAMPROBE\\0\\0\\0"
    .ascii  "VAPR"                  @ game code
    .ascii  "01"                    @ maker
    .byte   0x96                    @ 0xB2: fixed
    .byte   0x00                    @ 0xB3: main unit code
    .byte   0x00                    @ 0xB4
    .byte   0x00                    @ 0xB5
    .byte   0x00                    @ 0xB6
    .byte   0x00                    @ 0xB7
    .byte   0x00                    @ 0xB8: software version
    .byte   0x00                    @ 0xB9: complement (patched below)
    .byte   0x00,0x00               @ 0xBA,0xBB
    @ 0xBC..0xBF: region and reserved
    .space  4
"""

ASM = """\
_start:
    ldr     r11, =0x04000000

    @ Force blank while frame memory is written, mode 3, BG2 on.
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]

    @ ---------------------------------------------------------- write the bands
    @ n counts halfwords from 0; r9 walks VRAM and r10 walks y.
    ldr     r9, =0x06000000
    mov     r10, #0                 @ y
wy_loop:
    mov     r8, #0                  @ x
wx_loop:
    @ band = x / 60, xin = x - band*60
    mov     r0, r8
    mov     r1, #0                  @ band
find_band:
    cmp     r0, #60
    subhs   r0, r0, #60
    addhs   r1, r1, #1
    bhs     find_band
    @ now r0 = xin (0..59), r1 = band (0..3)

    cmp     r1, #0
    beq     band0
    cmp     r1, #1
    beq     band1
    cmp     r1, #2
    beq     band2
    b       band3

band0:                              @ blue ramp in y: 0x001F | ((y*2 & 31) << 5)
    mov     r2, r10, lsl #1
    and     r2, r2, #31
    mov     r2, r2, lsl #5
    orr     r2, r2, #0x1F
    b       store_px
band1:                              @ green + x offset: 0x03E0 | (xin & 31)
    and     r3, r0, #31
    orr     r2, r3, #0x03E0
    b       store_px
band2:                              @ red + y offset: 0x7C00 | (y & 31)
    and     r3, r10, #31
    orr     r2, r3, #0x7C00
    b       store_px
band3:                              @ two-axis: (x&31) | ((y&31) << 5), both coords
    and     r3, r0, #31
    and     r4, r10, #31
    orr     r2, r3, r4, lsl #5
store_px:
    strh    r2, [r9], #2

    add     r8, r8, #1
    cmp     r8, #240
    bne     wx_loop
    add     r10, r10, #1
    cmp     r10, #160
    bne     wy_loop

    @ ------------------------------------------- read every halfword back
    @ If a read differs from what was written, remember it in r7.
    ldr     r9, =0x06000000
    mov     r7, #0                  @ mismatch count
    mov     r10, #0
ry_loop:
    mov     r8, #0
rx_loop:
    mov     r0, r8
    mov     r1, #0
rb_band:
    cmp     r0, #60
    subhs   r0, r0, #60
    addhs   r1, r1, #1
    bhs     rb_band
    cmp     r1, #0
    beq     rb0
    cmp     r1, #1
    beq     rb1
    cmp     r1, #2
    beq     rb2
    b       rb3
rb0:    mov     r2, r10, lsl #1
        and     r2, r2, #31
        mov     r2, r2, lsl #5
        orr     r2, r2, #0x1F
        b       cmp_px
rb1:    and     r3, r0, #31
        orr     r2, r3, #0x03E0
        b       cmp_px
rb2:    and     r3, r10, #31
        orr     r2, r3, #0x7C00
        b       cmp_px
rb3:    and     r3, r0, #31
        and     r4, r10, #31
        orr     r2, r3, r4, lsl #5
cmp_px:
    ldrh    r3, [r9], #2
    cmp     r3, r2
    addne   r7, r7, #1
    add     r8, r8, #1
    cmp     r8, #240
    bne     rx_loop
    add     r10, r10, #1
    cmp     r10, #160
    bne     ry_loop

    @ ---- report: a white bar along the top whose width is the mismatch count,
    @ capped at 240 halfwords, so "all reads fail" and "a few fail" look different.
    @ r7 holds the count.  Also a 4-pixel border: white for zero, red otherwise.
    ldr     r9, =0x06000000
    mov     r6, r7
    cmp     r6, #240
    movhi   r6, #240
    mov     r10, #0
bar_row:
    mov     r8, #0
bar_x:
    cmp     r8, r6
    bhs     bar_next
    mov     r0, r10
    mov     r1, #240
    mul     r0, r1, r0
    add     r0, r0, r8
    add     r3, r9, r0, lsl #1
    ldr     r5, =0x7FFF             @ white: distinct from every band colour
    strh    r5, [r3]
bar_next:
    add     r8, r8, #1
    cmp     r8, #240
    bne     bar_x
    add     r10, r10, #1
    cmp     r10, #10
    bne     bar_row

    @ Border
    mov     r5, #0
    cmp     r7, #0
    ldreq   r5, =0x7FFF             @ white when every readback matched
    ldrne   r5, =0x001F             @ red on any mismatch
    mov     r10, #0
br_loop:
    mov     r8, #0
br_x:
    cmp     r10, #4
    blo     br_write
    cmp     r10, #156
    bhs     br_write
    cmp     r8, #4
    blo     br_write
    cmp     r8, #236
    blo     br_skip
br_write:
    mov     r0, r10
    mov     r1, #240
    mul     r0, r1, r0
    add     r0, r0, r8
    add     r3, r9, r0, lsl #1
    strh    r5, [r3]
br_skip:
    add     r8, r8, #1
    cmp     r8, #240
    bne     br_x
    add     r10, r10, #1
    cmp     r10, #160
    bne     br_loop

    @ Leave forced blank; the picture is already in frame memory.
    ldr     r11, =0x04000000
    ldr     r0, =0x0403
    strh    r0, [r11]

hang:
    b       hang

    .ltorg
"""

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


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", default="build/test/vramprobe.gba")
    ap.add_argument("--toolchain", default=None)
    ap.add_argument("--keep-source", action="store_true")
    args = ap.parse_args(argv[1:])

    as_bin, oc_bin = find_toolchain(args.toolchain)
    work = os.path.dirname(os.path.abspath(args.out)) or "."
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "vramprobe.s")
    obj = os.path.join(work, "vramprobe.o")
    binf = os.path.join(work, "vramprobe.bin")

    with open(src, "w") as f:
        f.write(PREAMBLE + ASM)
    subprocess.run([as_bin, "-mcpu=arm7tdmi", "-EL", "-o", obj, src], check=True)
    subprocess.run([oc_bin, "-O", "binary", "--only-section=.text", obj, binf],
                   check=True)
    with open(binf, "rb") as f:
        img = bytearray(f.read())

    if len(img) > IMAGE_SIZE:
        raise SystemExit(f"image is {len(img)} bytes, over the {IMAGE_SIZE} budget")

    img.extend(b"\0" * (IMAGE_SIZE - len(img)))
    chk = (-(sum(img[0xA0:0xBD]) + COMPLEMENT_FIXED)) & 0xFF
    img[0xBD] = chk
    with open(args.out, "wb") as f:
        f.write(img)

    if not args.keep_source:
        for p in (src, obj, binf):
            try:
                os.unlink(p)
            except OSError:
                pass

    print(f"{args.out}: {len(img)} bytes, complement ${chk:02X}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
