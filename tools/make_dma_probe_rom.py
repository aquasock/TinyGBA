#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a cartridge that tests DMA from ROM to frame memory, the last untested path.

Why this exists.  BRD-054 establishes that the board draws the RetroRegen cartridge's
text at the right position, size and colour but from the wrong glyph data: a
per-pixel comparison against mGBA gives 55 percent agreement, which is two
unrelated patterns rather than one corrupted copy.  That cartridge works in mGBA,
so the cartridge is sound and the board is at fault.

Everything on either side of the copy has been measured good on the board:
cartridge reads to 1 MiB (BRD-053), and frame-memory write, read and display in
mode 3 (BRD-053).  What sits between them and has never been measured on hardware
is DMA, and BRD-045 records a verified DMA defect in `REQ1_START` on channel 3.
So this tests DMA directly, and it tests it the way the display cares about.

What it does, five independent checks, one 16-pixel square each along the top:

    0  DMA3 ROM -> VRAM, 32-bit, 64 words, then read back and compare
    1  same transfer's destination bytes, compared halfword by halfword
    2  DMA3 with immediate (non-incrementing) source, a fill of one word
    3  DMA3 VRAM -> VRAM copy, source and destination both in frame memory
    4  the DMA completed at all: the transfer count reached zero

    green 0x03E0  the check passed
    red   0x001F  it did not

A pattern that is written correctly by CPU stores (verified by `make_vram_probe_rom.py`)
is used as both source and expected value, so a failure here is DMA and not the
pattern.  The source lives in cartridge ROM at a known offset, so the test also
depends on cartridge reads, which are separately known good -- if this probe fails
where those pass, DMA is the difference.

    tools/make_dma_probe_rom.py -o build/test/dmappobe.gba
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
    .ascii  "DMAPROBE\\0\\0\\0\\0"
    .ascii  "DMPB"
    .ascii  "01"
    .byte   0x96
    .space  9
    .space  4
"""

ASM = """\
_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]               @ forced blank
    ldr     r0, =0x0403
    strh    r0, [r11]               @ mode 3, BG2

    ldr     r9, =0x06000000
    @ Clear the screen so an unpainted square is visibly absent.
    mov     r4, #0
clr:
    mov     r0, #0
    add     r3, r9, r4, lsl #1
    strh    r0, [r3]
    add     r4, r4, #1
    ldr     r1, =38400
    cmp     r4, r1
    bne     clr

    @ ============================================= check 0: DMA3 ROM -> VRAM
    @ 64 words from DMASRC in cartridge ROM to 0x06002000, 32-bit, increment.
    ldr     r0, =0x040000D4         @ DMA3 SAD
    ldr     r1, =0x08000000 + DMASRC
    str     r1, [r0]
    ldr     r1, =0x06002000
    str     r1, [r0, #4]            @ DMA3 DAD
    ldr     r1, =0x8400003F         @ enable, 32-bit, source inc, dest inc, 64 words
    str     r1, [r0, #8]            @ DMA3 CNT_L/H: writing the control word starts it

    @ Small settle loop: DMA3 on ROM runs while the CPU is paused, so a few
    @ cycles here is enough and avoids depending on anything else.
    ldr     r2, =64
settle0:
    subs    r2, r2, #1
    bne     settle0

    @ Halfword reads from frame memory: VRAM does not support 32-bit access, so a
    @ 32-bit read here returns garbage on real hardware AND on mGBA, which made a
    @ first version of this probe report five failures in both.  The control run
    @ in mGBA is what caught it (TCL-040).
    ldr     r5, =0x03E0             @ assume pass
    ldr     r3, =0x06002000
    ldr     r4, =0x08000000 + DMASRC
    mov     r2, #128
cmp0:
    ldrh    r0, [r3], #2
    ldrh    r1, [r4], #2
    cmp     r0, r1
    ldrne   r5, =0x001F
    subs    r2, r2, #1
    bne     cmp0
    mov     r0, #0
    mov     r4, #0
    bl      square

    @ ============================================= check 1: same, halfword view
    @ The same destination, compared as halfwords.  A transfer that is right as
    @ words but wrong as halfwords would name a width problem rather than a DMA one.
    ldr     r5, =0x03E0
    ldr     r3, =0x06002000
    ldr     r4, =0x08000000 + DMASRC
    mov     r2, #128
cmp1:
    ldrh    r0, [r3], #2
    ldrh    r1, [r4], #2
    cmp     r0, r1
    ldrne   r5, =0x001F
    subs    r2, r2, #1
    bne     cmp1
    mov     r0, #16
    mov     r4, #0
    bl      square

    @ ============================================= check 2: immediate source
    @ Source increments are off, so every destination word gets one value.
    ldr     r0, =0x040000D4
    ldr     r1, =0x08000000 + DMAFILL
    str     r1, [r0]
    ldr     r1, =0x06003000
    str     r1, [r0, #4]
    ldr     r1, =0x8500001F         @ enable, 32-bit, source FIXED, dest inc, 32 words
    str     r1, [r0, #8]
    ldr     r2, =32
settle2:
    subs    r2, r2, #1
    bne     settle2

    ldr     r5, =0x03E0
    ldr     r6, =0x08000000 + DMAFILL
    ldrh    r6, [r6]                @ low halfword of the word meant to be replicated
    ldr     r3, =0x06003000
    mov     r2, #64
cmp2:
    ldrh    r0, [r3], #2
    cmp     r0, r6
    ldrne   r5, =0x001F
    subs    r2, r2, #1
    bne     cmp2
    mov     r0, #32
    mov     r4, #0
    bl      square

    @ ============================================= check 3: VRAM -> VRAM
    @ Both sides in frame memory, so this isolates the SDRAM side from the
    @ cartridge side.  Copy the block check 0 produced.
    ldr     r0, =0x040000D4
    ldr     r1, =0x06002000
    str     r1, [r0]
    ldr     r1, =0x06004000
    str     r1, [r0, #4]
    ldr     r1, =0x8400003F
    str     r1, [r0, #8]
    ldr     r2, =64
settle3:
    subs    r2, r2, #1
    bne     settle3

    ldr     r5, =0x03E0
    ldr     r3, =0x06004000
    ldr     r4, =0x08000000 + DMASRC
    mov     r2, #128
cmp3:
    ldrh    r0, [r3], #2
    ldrh    r1, [r4], #2
    cmp     r0, r1
    ldrne   r5, =0x001F
    subs    r2, r2, #1
    bne     cmp3
    mov     r0, #48
    mov     r4, #0
    bl      square

    @ ============================================= check 4: did anything move?
    @ If DMA never ran, the destination still holds the cleared zero from boot.
    ldr     r5, =0x001F             @ red unless proven otherwise
    ldr     r3, =0x06002000
    ldrh    r0, [r3]
    cmp     r0, #0
    ldrne   r5, =0x03E0             @ something other than the clear landed
    mov     r0, #64
    mov     r4, #0
    bl      square

    ldr     r11, =0x04000000
    ldr     r0, =0x0403
    strh    r0, [r11]
hang:
    b       hang

@ square: r0 = x0, r4 = y0, r5 = colour.  Clobbers r1,r2,r3,r10.
square:
    mov     r10, r4
sq_y:
    mov     r3, #0
sq_x:
    mov     r1, #240
    mul     r2, r1, r10
    add     r2, r2, r0
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #16
    bne     sq_x
    add     r10, r10, #1
    mov     r1, r10
    sub     r1, r1, r4
    cmp     r1, #16
    bne     sq_y
    bx      lr

    .ltorg

@ ------------------------------------------------------------------ DMA source
@ NOTE: these live in cartridge ROM at 0x08000000 + offset.  `as` resolves the
@ symbol to its offset within .text and objcopy emits .text at 0, so every use
@ must add the cartridge base itself; a first version did not, and the DMA read
@ from 0x00000xxx (the BIOS region) instead of the cartridge.  The mGBA control
@ run is what exposed it, since the board and the emulator then failed together.
@ 64 words of a pattern that is deliberately not constant, so a DMA that
@ replicates one word instead of copying 64 is caught by check 0 rather than
@ passing by luck.  Word n = 0x12340000 + n, which also makes the first failing
@ index readable off the screen if it ever comes to that.
    .align  4
DMASRC:
    .rept   64
    .word   0x12340000 + (. - DMASRC) / 4
    .endr
DMAFILL:
    .word   0x5A5A1234
"""

IMAGE_SIZE = 0x1000
COMPLEMENT_FIXED = 0x19

SQUARES = [
    "DMA3 ROM->VRAM word compare",
    "same, halfword compare",
    "DMA3 immediate source (fill)",
    "DMA3 VRAM->VRAM",
    "something other than the clear landed",
]


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
    ap.add_argument("-o", "--out", default="build/test/dmappobe.gba")
    ap.add_argument("--toolchain", default=None)
    ap.add_argument("--keep-source", action="store_true")
    args = ap.parse_args(argv[1:])

    as_bin, oc_bin = find_toolchain(args.toolchain)
    work = os.path.dirname(os.path.abspath(args.out)) or "."
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "dmappobe.s")
    obj = os.path.join(work, "dmappobe.o")
    binf = os.path.join(work, "dmappobe.bin")

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
    for i, name in enumerate(SQUARES):
        print(f"  square {i} (x={i*16:3d}): {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
