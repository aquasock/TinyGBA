#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a self-checking GBA test cartridge, so the first cartridge is a discriminator.

Why this exists.  The machine has never booted, and a black screen cannot say
which of three quite different things failed: the CPU never fetched a real
instruction, it fetched and ran but the memory behind it returned the wrong
words, or everything worked and the display path is what is missing.  A retail
game answers none of those, because its own first few instructions depend on all
three.  This cartridge is written to separate them in one frame.

What it does, in order, with interrupts never enabled:

  1. Forces the display blank and clears its own result mask.
  2. Fetches three known constants from three distinct cartridge offsets.  These
     are the load-bearing checks: a word read back correctly from `0x08000400`
     proves the CPU fetched through the ROM path the machine runs on.
  3. Writes and reads back IWRAM, EWRAM and VRAM, and reads two individual byte
     lanes so a swapped lane fails on all 32 bits rather than passing on a word
     compare.
  4. Fills the 240x160 mode-3 framebuffer green if every check passed, red if any
     failed, then draws one yellow full-height column for each failed check, at
     x = 20 * bit, so a single capture names the failure.
  5. Enables the display and blinks a 16x16 square forever, which distinguishes a
     CPU that is still executing from one that wedged after the checks.

Read the result off the screen, not off the CPU: green means every check passed
and the machine is running code out of the cartridge; red with yellow columns
means it is running and one of the memory or fetch paths behind it is wrong; a
picture that never changes means the CPU wedged; a black screen at 1080 pixels
means either nothing ran or the framebuffer never reached the video window, and
`TINYGBA_VIDEO_TEST` is the control that separates those two.

Two deliberate non-goals.  It writes no WAITCNT, so it runs at the reset wait
states, which are the slowest the hardware offers -- a pass therefore does not
prove the machine works at a faster setting, and a failure is not explained by
one.  And it enables no interrupt, so a pass is not evidence that the interrupt
path works; that separates "the display never turned on" from "the machine is
waiting for an interrupt that never came", which is what cost the sibling SNES
project several cycles.

Header: this core's BIOS is the open-source Cult-of-GBA image, built with
`NO_LOGO` (see `fpga/gba/src/common/gba_bios.sv`), so it branches straight to
`0x08000000` without drawing or validating the Nintendo logo.  The logo region is
therefore zero-filled rather than borrowed from a retail image -- carrying that
blob would be a trademark question this project has no reason to open.  Every
other header field is filled in and the complement check is correct, so the image
is well formed if a future BIOS does enforce it; pass `--logo-from <retail.gba>`
to splice the logo in when that happens.

    tools/make_gba_test_rom.py                     # build/test.gba
    tools/make_gba_test_rom.py -o build/test.gba
    tools/make_gba_test_rom.py --keep-asm          # keep the .s and .elf too

Deterministic: the same toolchain produces the same bytes, and the script prints
the SHA-256 so a result on the board can be tied to an image.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------- the cartridge
# Assembly, kept in the file that generates it so the two cannot drift.  Written
# for arm7tdmi, ARM state, position dependent, no runtime and no linker script:
# `as` assembles it to one .text section and objcopy emits that section as-is.
ASM = r"""
    .arm
    .section .text

    @ ---------------------------------------------------------- cartridge header
    @ 0x000: ARM branch over the header to the entry point at 0x0C0.
    b       _start

    @ 0x004: Nintendo logo, 156 bytes.  Zero-filled: this core's BIOS is built
    @ with NO_LOGO and branches to 0x08000000 without checking it.  See the
    @ module docstring for why the real blob is not carried here.
    .space  156

    @ 0x0A0: title, 12 bytes.
    .ascii  "TINYGBATEST1"
    @ 0x0AC: game code.
    .ascii  "TGBT"
    @ 0x0B0: maker code.
    .ascii  "01"
    @ 0x0B2: fixed value, then unit code and device type (0 = ROM).
    .byte   0x96
    .byte   0x00
    .byte   0x00
    @ 0x0B5: seven reserved bytes.
    .space  7
    @ 0x0BC: software version.
    .byte   0x00
    @ 0x0BD: header complement check; patched by the generator after assembly.
    .byte   0x00
    @ 0x0BE: two reserved bytes.
    .space  2

    @ ------------------------------------------------------------------- entry
_start:                                 @ 0x0C0, local so `as` resolves the
                                        @ branch above itself; a global symbol
                                        @ would be left as a linker relocation
                                        @ and objcopy would keep the placeholder
    ldr     r11, =0x04000000            @ IO base
    mov     r0, #0
    strh    r0, [r11]                   @ DISPCNT = 0: force blank while VRAM is written
    mov     r10, #0                     @ failure mask, one bit per check

    @ ------------------------------------------------- checks: ROM fetch path
    @ Three distinct constants at three distinct cartridge offsets.  Bit n of the
    @ mask is set when check n fails.  These are the checks that matter: they read
    @ the path the machine executes from.
    ROMCHK  0x08000400, 0xA5A50001, 0
    ROMCHK  0x08000800, 0xA5A50002, 1
    ROMCHK  0x08000C00, 0xA5A50003, 2

    @ ------------------------------------------- checks: work RAM and cart RAM
    @ Word compare plus two individual byte lanes, so a swapped lane fails.
    MEMCHK  0x03000000, 3               @ IWRAM, bottom
    MEMCHK  0x03007E00, 4               @ IWRAM, top
    MEMCHK  0x02000000, 5               @ EWRAM, bottom
    MEMCHK  0x0203FE00, 6               @ EWRAM, top
    @ VRAM is halfword access only, so its check is a halfword rather than a word.
    VRAMCHK 0x0600FF00, 7

    @ ------------------------------------------------------------- draw result
    @ Background: green when every check passed, red when any failed.
    ldr     r9, =0x06000000
    ldr     r5, =0x03E0                 @ green
    cmp     r10, #0
    ldrne   r5, =0x001F                 @ red
    mov     r0, r9
    ldr     r1, =38400                  @ 240 * 160 halfwords
bg_fill:
    strh    r5, [r0], #2
    subs    r1, r1, #1
    bne     bg_fill

    @ One yellow full-height column per failed check, 16 pixels wide, at x = 20*bit.
    @ Counting them names the failing check without needing a probe.
    mov     r8, #0
cols:
    mov     r7, #1
    mov     r7, r7, lsl r8
    tst     r10, r7
    beq     cols_next
    mov     r2, r8, lsl #4              @ 16 * bit
    add     r2, r2, r8, lsl #2          @ + 4 * bit = 20 * bit
    ldr     r0, =0x06000000
    add     r0, r0, r2, lsl #1          @ two bytes per pixel
    ldr     r5, =0xFFE0                 @ yellow
    mov     r1, #160                    @ rows
col_row:
    mov     r3, #16                     @ pixels across
col_px:
    strh    r5, [r0], #2
    subs    r3, r3, #1
    bne     col_px
    add     r0, r0, #448                @ (240 - 16) * 2 to the next row
    subs    r1, r1, #1
    bne     col_row
cols_next:
    add     r8, r8, #1
    cmp     r8, #8
    bne     cols

    @ Mode 3, BG2 on, force blank released.
    ldr     r0, =0x0403
    strh    r0, [r11]

    @ ------------------------------------------------ prove the CPU is alive
    @ A 16x16 square at (8,8) toggles between white and black.  Two captures a
    @ moment apart tell a running CPU from one that wedged after the checks; a
    @ single capture cannot, and that is the mistake the sibling project made.
    mov     r8, #0
blink:
    eor     r8, r8, #1
    ldr     r5, =0x7FFF                 @ white
    cmp     r8, #0
    moveq   r5, #0                      @ black on the alternate phase
    ldr     r0, =0x06000F10             @ pixel (8,8): (8*240 + 8) * 2
    mov     r1, #16
sq_row:
    mov     r3, #16
    mov     r2, r0
sq_px:
    strh    r5, [r2], #2
    subs    r3, r3, #1
    bne     sq_px
    add     r0, r0, #480                @ 240 * 2, one scanline
    subs    r1, r1, #1
    bne     sq_row
    ldr     r4, =2000000                @ about a quarter second at 16.78 MHz
delay:
    subs    r4, r4, #1
    bne     delay
    b       blink

    @ Flush the literal pools here, explicitly and before the constant region.
    @ `ldr Rd, =value` puts its literal where the assembler chooses, and without
    @ this it can land inside the .org'd constants below and shift them off the
    @ addresses the ROM checks read.
    .ltorg

    @ --------------------------------------------------------------- constants
    @ The values the ROM checks read back.  Three different constants at three
    @ different offsets, so a stuck address bit cannot make all three pass.
    .org    0x400
    .word   0xA5A50001
    .org    0x800
    .word   0xA5A50002
    .org    0xC00
    .word   0xA5A50003
"""

# The assembly used above.  GNU as resolves `ldr Rd, =value` to a literal pool
# placed after the code, which would land inside the .org'd constant region, so
# the macros and the pool are kept out of the layout by giving every constant an
# explicit address below and letting the pool sit at the end of the section.
PREAMBLE = r"""
.macro ROMCHK addr, expect, bit
    ldr     r6, =\addr
    ldr     r5, =\expect
    ldr     r4, [r6]
    cmp     r4, r5
    orrne   r10, r10, #(1 << \bit)
.endm

.macro MEMCHK addr, bit
    ldr     r6, =\addr
    ldr     r5, =0x12345678
    str     r5, [r6]
    ldr     r4, [r6]
    cmp     r4, r5
    orrne   r10, r10, #(1 << \bit)
    ldrb    r4, [r6]
    cmp     r4, #0x78
    orrne   r10, r10, #(1 << \bit)
    ldrb    r4, [r6, #3]
    cmp     r4, #0x12
    orrne   r10, r10, #(1 << \bit)
.endm

.macro VRAMCHK addr, bit
    ldr     r6, =\addr
    ldr     r5, =0x7BDE
    strh    r5, [r6]
    ldrh    r4, [r6]
    cmp     r4, r5
    orrne   r10, r10, #(1 << \bit)
.endm
"""

HEADER_TITLE = b"TINYGBATEST1"
HEADER_GAME_CODE = b"TGBT"
HEADER_MAKER = b"01"
IMAGE_SIZE = 0x1000          # 4 KiB: enough to hold the code and the three constants
COMPLEMENT_FIXED = 0x19


def find_toolchain(explicit):
    """Locate arm-none-eabi-as and objcopy, or explain what is missing."""
    if explicit:
        cand = explicit
    else:
        cand = os.path.expanduser(
            "~/tools/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-eabi/bin")
        if not os.path.isdir(cand):
            as_path = shutil.which("arm-none-eabi-as")
            if as_path:
                cand = os.path.dirname(as_path)
            else:
                cand = ""
    as_bin = os.path.join(cand, "arm-none-eabi-as") if cand else ""
    oc_bin = os.path.join(cand, "arm-none-eabi-objcopy") if cand else ""
    if not (os.path.isfile(as_bin) and os.access(as_bin, os.X_OK)):
        raise SystemExit(
            "arm-none-eabi-as not found.  Set ARM_TOOLCHAIN to the bin directory of "
            "an ARM GNU toolchain, or put it on PATH.  Nothing here downloads one.")
    if not (os.path.isfile(oc_bin) and os.access(oc_bin, os.X_OK)):
        raise SystemExit(f"arm-none-eabi-objcopy not found beside {as_bin}")
    return as_bin, oc_bin


def assemble(as_bin, oc_bin, workdir):
    """Assemble ASM to a flat little-endian image, and return its bytes."""
    src = os.path.join(workdir, "tinytest.s")
    obj = os.path.join(workdir, "tinytest.o")
    binpath = os.path.join(workdir, "tinytest.bin")
    with open(src, "w") as f:
        f.write(PREAMBLE + ASM)
    subprocess.run([as_bin, "-mcpu=arm7tdmi", "-EL", "-o", obj, src], check=True)
    subprocess.run([oc_bin, "-O", "binary", "--only-section=.text", obj, binpath],
                   check=True)
    with open(binpath, "rb") as f:
        return f.read(), src, obj


def complement_check(image):
    """The GBA header check: -(0x19 + sum(bytes 0xA0..0xBC)) & 0xFF."""
    return (-(COMPLEMENT_FIXED + sum(image[0xA0:0xBD]))) & 0xFF


def build(as_bin, oc_bin, workdir, logo_from=None):
    raw, src, obj = assemble(as_bin, oc_bin, workdir)
    if len(raw) > IMAGE_SIZE:
        raise SystemExit(f"image is {len(raw)} bytes, over the {IMAGE_SIZE}-byte limit")
    image = bytearray(raw) + bytearray(IMAGE_SIZE - len(raw))

    if logo_from:
        with open(logo_from, "rb") as f:
            retail = f.read()
        logo = retail[0x04:0xA0]
        if len(logo) != 156:
            raise SystemExit(f"{logo_from} is too short to hold a header")
        image[0x04:0xA0] = logo

    image[0xBD] = complement_check(image)
    return bytes(image), src, obj


def verify(image):
    """Assert the invariants this image is supposed to have.  Returns failures."""
    bad = []

    def check(cond, msg):
        if not cond:
            bad.append(msg)

    check(len(image) == IMAGE_SIZE, f"size is {len(image)}, expected {IMAGE_SIZE}")
    # The branch over the header, to the entry point at 0x0C0.
    word0 = int.from_bytes(image[0:4], "little")
    check(word0 == 0xEA00002E,
          f"entry branch is 0x{word0:08X}, expected 0xEA00002E (b 0x0C0)")
    check(image[0xA0:0xAC] == HEADER_TITLE, "title bytes are wrong")
    check(image[0xAC:0xB0] == HEADER_GAME_CODE, "game code bytes are wrong")
    check(image[0xB0:0xB2] == HEADER_MAKER, "maker code bytes are wrong")
    check(image[0xB2] == 0x96, f"header fixed value is 0x{image[0xB2]:02X}, expected 0x96")
    got = image[0xBD]
    want = complement_check(image)
    check(got == want, f"complement check is 0x{got:02X}, computed 0x{want:02X}")
    for off, val in ((0x400, 0xA5A50001), (0x800, 0xA5A50002), (0xC00, 0xA5A50003)):
        got = int.from_bytes(image[off:off + 4], "little")
        check(got == val, f"constant at 0x{off:03X} is 0x{got:08X}, expected 0x{val:08X}")
    # The ROM checks read these three; a check whose constant is missing from the
    # image would fail on real hardware for a reason that is the tool's fault.
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--output", default="test.gba")
    ap.add_argument("--keep-asm", action="store_true",
                    help="keep the generated .s and .o next to the output")
    ap.add_argument("--toolchain", default=os.environ.get("ARM_TOOLCHAIN", ""),
                    help="bin directory holding arm-none-eabi-as/objcopy")
    ap.add_argument("--logo-from", default=None,
                    help="splice the 156-byte logo out of a retail .gba image")
    args = ap.parse_args()

    as_bin, oc_bin = find_toolchain(args.toolchain)

    with tempfile.TemporaryDirectory() as workdir:
        image, src, obj = build(as_bin, oc_bin, workdir, args.logo_from)
        bad = verify(image)
        if bad:
            for msg in bad:
                print(f"FAIL: {msg}", file=sys.stderr)
            raise SystemExit("the generated image failed its own verification")
        os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
        with open(args.output, "wb") as f:
            f.write(image)
        if args.keep_asm:
            base = os.path.splitext(args.output)[0]
            shutil.copy(src, base + ".s")
            shutil.copy(obj, base + ".o")
            print(f"assembly kept: {base}.s, {base}.o")

    digest = hashlib.sha256(image).hexdigest()
    print(f"{args.output}: {len(image)} bytes, header verified, 8 checks")
    print(f"sha256 {digest}")
    print()
    print("Checks, by failure-column index on screen:")
    print("  bit 0  ROM 0x08000400 reads 0xA5A50001")
    print("  bit 1  ROM 0x08000800 reads 0xA5A50002")
    print("  bit 2  ROM 0x08000C00 reads 0xA5A50003")
    print("  bit 3  IWRAM 0x03000000, word and byte lanes 0 and 3")
    print("  bit 4  IWRAM 0x03007E00")
    print("  bit 5  EWRAM 0x02000000")
    print("  bit 6  EWRAM 0x0203FE00")
    print("  bit 7  VRAM  0x0600FF00, halfword")
    print()
    print("Green screen: every check passed.  Red: at least one failed, and the")
    print("yellow columns count off which.  Blinking white square at (8,8): the CPU")
    print("is still executing.  No interrupts are enabled and WAITCNT is left at its")
    print("reset value, so a pass says nothing about either.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
