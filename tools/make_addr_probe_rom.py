#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Load three cartridge words by explicit PC-relative offset, one of them at 0xF8.

Why.  BRD-026 records a contradiction: two cartridges returned zero for a literal
load targeting `0x080000F8`, while a data read of that same address returned the
correct constant, and three other cartridges loaded literals correctly at other
addresses.  The lead is recorded as unresolved and the next step named there is a
cartridge that places a word at `0x080000F8` with no code near it, verified by
disassembly before loading.

This cartridge does that, and avoids the failure mode that spoiled the earlier
attempts: it uses `ldr Rd, [pc, #imm]` with an explicit offset instead of
`ldr Rd, =value`, so no literal pool is emitted and the assembler cannot relocate
anything.  The three target addresses are fixed by the instruction encoding and
are printed from a disassembly of the finished image, not from the source.

Layout:

    0x0C0  code, ending at 0x0EB with a self-branch
    0x0F8  0x11112222   <- the address under test
    0x104  0x33334444
    0x110  0x55556666

Results land at IO+0x090, IO+0x0A0 and IO+0x0B0, one ring entry each, so the MMIO
readout captures them without the display path being involved.

If only the 0xF8 load returns zero, the machine has an address-dependent read
fault that every other test this cycle missed.  If all three return their
constants, the earlier pair were defective cartridges and BRD-026 is withdrawn.

Usage:
    tools/make_addr_probe_rom.py -o build/test/addrprobe.gba \
        --logo-from build/test/test_logo.gba
"""

import argparse
import os
import re
import subprocess
import sys

IMAGE_SIZE = 4096
COMPLEMENT_FIXED = 0x19

# Targets and the constants at them.  The offsets in the instructions below are
# tied to this table; verify() re-derives them from the encoding and refuses to
# write an image whose loads do not point here.
TARGETS = [(0x0F8, 0x11112222), (0x104, 0x33334444), (0x110, 0x55556666)]

ASM = r"""
    .arm
    .section .text

    b       _start

    .space  156

    .ascii  "ADDRPROBE001"
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
    @ The IO base is an immediate, so no pool is needed even for setup.
    mov     r11, #0x4000000
    mov     r0, #0
    strh    r0, [r11]

    @ Three loads by explicit PC-relative offset.  pc reads as the instruction
    @ address plus 8 for these encodings, so each offset is target - (addr + 8).
    ldr     r4, [pc, #0x24]         @ 0x0CC + 8 + 0x24 = 0x0F8
    ldr     r5, [pc, #0x2C]         @ 0x0D0 + 8 + 0x2C = 0x104
    ldr     r6, [pc, #0x34]         @ 0x0D4 + 8 + 0x34 = 0x110

    add     r7, r11, #0x90
    str     r4, [r7]                @ IO+0x090
    str     r5, [r7, #0x10]         @ IO+0x0A0
    str     r6, [r7, #0x20]         @ IO+0x0B0

    b       .                       @ park here; code ends before 0x0F8

    .space  0x0C                    @ pad 0x0EC..0x0F7

    .org    0x0F8
    .word   0x11112222
    .org    0x104
    .word   0x33334444
    .org    0x110
    .word   0x55556666
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


def decode_pc_ldr(image, insn_addr):
    """Return (target, rd) for an ARM `ldr Rd,[pc,#imm]`, or None."""
    off = insn_addr - 0x08000000
    if off + 4 > len(image):
        return None
    w = int.from_bytes(image[off:off + 4], "little")
    # cond(4) 010 P U B W L Rn Rd imm12
    if (w >> 26) & 0x3 != 0x01:
        return None
    if not (w >> 28) & 0xF:
        return None
    P = (w >> 24) & 1
    U = (w >> 23) & 1
    B = (w >> 22) & 1
    W = (w >> 21) & 1
    L = (w >> 20) & 1
    Rn = (w >> 16) & 0xF
    Rd = (w >> 12) & 0xF
    imm = w & 0xFFF
    if not (P and not W and L and not B and Rn == 15):
        return None
    target = insn_addr + 8 + (imm if U else -imm)
    return target, Rd


def build(as_bin, oc_bin, workdir, logo_from):
    src = os.path.join(workdir, "addrprobe.s")
    obj = os.path.join(workdir, "addrprobe.o")
    binpath = os.path.join(workdir, "addrprobe.bin")
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
    """Check the image really loads the constants it claims, from the encoding."""
    bad = []
    if len(image) != IMAGE_SIZE:
        bad.append(f"size is {len(image)}")
    if image[0xA0:0xAC] != b"ADDRPROBE001":
        bad.append("title bytes are wrong")
    if image[0xBD] != complement_check(image):
        bad.append("complement check is wrong")

    # The three loads are at 0x0CC, 0x0D0, 0x0D4 and must hit TARGETS in order.
    for i, (insn, (want_addr, want_val)) in enumerate(
            zip((0x0CC, 0x0D0, 0x0D4), TARGETS)):
        got = decode_pc_ldr(image, 0x08000000 + insn)
        if got is None:
            bad.append(f"instruction at 0x{insn:03X} is not the expected "
                       f"`ldr Rd,[pc,#imm]`")
            continue
        target, _rd = got
        if target != 0x08000000 + want_addr:
            bad.append(f"load {i} targets 0x{target:08X}, expected "
                       f"0x{0x08000000 + want_addr:08X}")
        actual = int.from_bytes(image[want_addr:want_addr + 4], "little")
        if actual != want_val:
            bad.append(f"word at 0x{want_addr:03X} is 0x{actual:08X}, expected "
                       f"0x{want_val:08X}")

    # The code must not run past 0x0F8, or the first load target would execute
    # as an instruction.
    code_end = 0x0E8
    for a in range(0xC0, code_end, 4):
        w = int.from_bytes(image[a:a + 4], "little")
        if w == 0xEAFFFFFE:
            code_end = a + 4
            break
    if code_end > 0x0F8:
        bad.append(f"code reaches 0x{code_end:03X}, overlapping the 0x0F8 target")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default="build/test/addrprobe.gba")
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
    for addr, val in TARGETS:
        print(f"  0x080{addr:03X} = 0x{val:08X}  -> IO+0x{0x090 + TARGETS.index((addr, val)) * 16:03X}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
