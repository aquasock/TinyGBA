#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a cartridge that scores CPU arithmetic, one square per test.

Why this exists.  Two probes have now passed on the board: VRAM write, read and
display are correct (`make_vram_probe_rom.py`), and cartridge reads are correct at
every 64 KiB checkpoint across a 1 MiB image (`make_romprobe_rom.py`).  Neither of
those explains the RetroRegen diagnostic cartridge, whose text draws at the
correct position, height, scale and colour with wrong glyph *patterns* and then
stops.

That signature -- right place, wrong content -- is what a cartridge looks like
when its addressing arithmetic is wrong.  A text renderer computes where a glyph
lives as `base + (char - 32) * bytes_per_glyph`, and a wrong multiply or shift
fetches a neighbouring glyph.  Glyphs then appear in the right cells, at the
right size, in the right colour, and read as junk.  So this cartridge scores the
operations such a renderer leans on, and paints one square per test:

    green   the operation produced the value the ARM ARM requires
    red     it did not

Tests, left to right along the top:

    0  mul   7 * 9                = 63
    1  mul   240 * 37             = 8880        (a pointer stride)
    2  mul   0x100 * 0x100        = 0x10000
    3  mul   0xFFFF * 0xFFFF      = 0xFFFE0001  (carries out of the low half)
    4  mul   0x8000 * 2           = 0x10000     (top bit of a multiplicand)
    5  mla   3*4 + 5              = 17
    6  lsl   1 << 16              = 0x10000
    7  lsr   0x80000000 >> 4      = 0x08000000
    8  asr   0x80000000 >> 4      = 0xF8000000  (arithmetic, sign preserved)
    9  add   with carry chain     0xFFFFFFFF + 1 = 0
    10 addc  carry propagated     0x7FFFFFFF + 1 = 0x80000000
    11 sub   0x10000 - 1          = 0xFFFF
    12 ubx   unsigned byte extend 0x80 -> 0x00000080
    13 sbx   signed byte extend   0x80 -> 0xFFFFFF80
    14 shx   signed half extend   0x8000 -> 0xFFFF8000

The signed-extension tests matter because a font lookup that uses `ldrsb` on a
byte would produce exactly the observed glyph scramble if sign extension were
wrong.

    tools/make_alu_probe_rom.py -o build/test/aluprobe.gba
"""
import argparse
import os
import shutil
import struct
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
    .ascii  "ALUPROBE\\0\\0\\0\\0"
    .ascii  "ALPB"
    .ascii  "01"
    .byte   0x96
    .space  9
    .space  4
"""

# Each test is: compute into r4, then compare against an expected value.
# A square is painted green when they match and red when they do not.
TESTS = [
    ("mul 7*9",          "mov r0, #7\n    mov r1, #9\n    mul r4, r1, r0",               63),
    ("mul 240*37",       "mov r0, #240\n    mov r1, #37\n    mul r4, r1, r0",            8880),
    ("mul 0x100*0x100",  "ldr r0, =0x100\n    mul r4, r0, r0",                       0x10000),
    ("mul 0xFFFF^2",     "ldr r0, =0xFFFF\n    mul r4, r0, r0",                   0xFFFE0001),
    ("mul 0x8000*2",     "ldr r0, =0x8000\n    mov r1, #2\n    mul r4, r1, r0",      0x10000),
    ("mla 3*4+5",        "mov r0, #3\n    mov r1, #4\n    mov r2, #5\n    mla r4, r1, r0, r2", 17),
    ("lsl 1<<16",        "mov r0, #1\n    mov r4, r0, lsl #16",                      0x10000),
    ("lsr 0x80000000>>4", "ldr r0, =0x80000000\n    mov r4, r0, lsr #4",          0x08000000),
    ("asr 0x80000000>>4", "ldr r0, =0x80000000\n    mov r4, r0, asr #4",          0xF8000000),
    ("add wrap",         "mvn r0, #0\n    add r4, r0, #1",                                  0),
    ("add carry",        "ldr r0, =0x7FFFFFFF\n    add r4, r0, #1",               0x80000000),
    ("sub borrow",       "ldr r0, =0x10000\n    sub r4, r0, #1",                     0xFFFF),
    # ARM7TDMI has no uxtb/sxtb/sxth; compilers emit the shift pairs below for
    # sign extension, so these are the forms a font loader actually executes.
    ("ubx 0x80",         "mov r0, #0x80\n    mov r4, r0, lsl #24\n    mov r4, r4, lsr #24",  0x80),
    ("sbx 0x80",         "mov r0, #0x80\n    mov r4, r0, lsl #24\n    mov r4, r4, asr #24", 0xFFFFFF80),
    ("shx 0x8000",       "ldr r0, =0x8000\n    mov r4, r0, lsl #16\n    mov r4, r4, asr #16",  0xFFFF8000),
]


def build_asm():
    """Emit the program: clear the screen, then one square per test."""
    out = []
    out.append("_start:")
    out.append("    ldr     r11, =0x04000000")
    out.append("    mov     r0, #0")
    out.append("    strh    r0, [r11]")
    out.append("    ldr     r0, =0x0403")
    out.append("    strh    r0, [r11]")
    out.append("")
    out.append("    ldr     r9, =0x06000000")
    out.append("    mov     r4, #0")
    out.append("clr:")
    out.append("    mov     r0, #0")
    out.append("    add     r3, r9, r4, lsl #1")
    out.append("    strh    r0, [r3]")
    out.append("    add     r4, r4, #1")
    out.append("    ldr     r1, =38400")
    out.append("    cmp     r4, r1")
    out.append("    bne     clr")
    out.append("")
    out.append("    mov     r8, #0                  @ test index t")
    out.append("t_loop:")

    for i, (name, code, expected) in enumerate(TESTS):
        out.append(f"    @ ---- test {i}: {name}")
        out.append(f"    cmp     r8, #{i}")
        out.append(f"    beq     do{i}")
    out.append("    b       paint")
    out.append("")

    for i, (name, code, expected) in enumerate(TESTS):
        out.append(f"do{i}:")
        for line in code.split("\n"):
            out.append("    " + line.strip())
        out.append(f"    ldr     r0, =0x{expected & 0xFFFFFFFF:08X}")
        out.append("    cmp     r4, r0")
        out.append("    ldreq   r5, =0x03E0             @ green: matched")
        out.append("    ldrne   r5, =0x001F             @ red: did not")
        out.append("    b       paint")

    out.append("""
paint:
    @ A 15-pixel-wide, 20-pixel-tall square per test, left to right at y=0.
    @ 16 tests would be 240 pixels; 15 tests leave a margin.
    mov     r0, r8
    mov     r1, #16
    mul     r0, r1, r0              @ x0 = t*16
    mov     r4, #0                  @ y
py:
    mov     r3, #0
px:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r0
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #15
    bne     px
    add     r4, r4, #1
    cmp     r4, #20
    bne     py

    add     r8, r8, #1
    cmp     r8, #16
    bne     t_loop

    @ Second row: a green continuation marks that the program reached the end.
    mov     r4, #30
end_y:
    mov     r3, #0
end_x:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    ldr     r5, =0x7FFF
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #240
    bne     end_x
    add     r4, r4, #1
    cmp     r4, #40
    bne     end_y

    ldr     r11, =0x04000000
    ldr     r0, =0x0403
    strh    r0, [r11]
hang:
    b       hang
    .ltorg
""")
    return "\n".join(out)


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
    ap.add_argument("-o", "--out", default="build/test/aluprobe.gba")
    ap.add_argument("--toolchain", default=None)
    ap.add_argument("--keep-source", action="store_true")
    args = ap.parse_args(argv[1:])

    as_bin, oc_bin = find_toolchain(args.toolchain)
    work = os.path.dirname(os.path.abspath(args.out)) or "."
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "aluprobe.s")
    obj = os.path.join(work, "aluprobe.o")
    binf = os.path.join(work, "aluprobe.bin")

    with open(src, "w") as f:
        f.write(PREAMBLE + build_asm())
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
    for i, (name, _, _) in enumerate(TESTS):
        print(f"  square {i:2d} (x={i*16:3d}): {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
