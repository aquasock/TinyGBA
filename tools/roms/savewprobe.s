@ Does a store to the cartridge SRAM window land, and if not, where does it go?
@
@ STATUS: NOT VALIDATED -- DO NOT READ RESULTS FROM THIS PROBE YET.
@
@ Under mGBA 0.10.5 it paints all nine squares RED even when the same store and
@ load are performed against EWRAM, where a one-case ROM in `saveprobe.s`'s own
@ idiom goes green.  So something in this file is wrong, and a red square here
@ currently says more about the probe than about the machine.  The project rule
@ is that a probe passes in an emulator before a board result is read from it;
@ this one does not, so it has not been run on the board and no result has been
@ taken from it.  It is committed rather than discarded because the case list
@ and the reasoning below are the work worth keeping, and the bug is one probe
@ away from being found.
@
@ What is already ruled out, so whoever picks this up does not repeat it: the
@ addressing is right (the literal pool in the built image holds 0x020100,
@ 0x020101 and so on, checked byte by byte), the store and load instructions
@ disassemble as intended, the `mul Rd == Rm` fault described at the bottom is
@ fixed, removing the VRAM clear does not change the result, and the same
@ store/load pair in a one-case ROM goes green.  The remaining difference
@ between the working ROM and this one is the `status` call and the sequence of
@ nine cases, which is where to look next.
@
@ `saveprobe.s` answers one question -- does a byte write read back -- and its
@ single red square cannot distinguish the ways a store can fail.  "Nothing was
@ written", "the byte went to the wrong lane", "halfwords and words are broken
@ but bytes are fine" and "the write landed and the read is broken" all look
@ identical there.  This probe separates them.
@
@ Nine cases, one square each, left to right along one row at 24-pixel pitch.
@ Under each square is the value that actually came back, as eight binary cells:
@ light for 1, dark for 0, most significant bit on the left.  So a red square
@ still says what was read, which is the difference between a diagnosis and a
@ failure.
@
@   0  strb 0xA5 -> 0x0E0100, ldrb back
@   1  strb 0x5A -> 0x0E0101
@   2  strb 0x3C -> 0x0E0102
@   3  strb 0xC3 -> 0x0E0103
@   4  strh 0xBEEF -> 0x0E0200
@   5  strh 0x1234 -> 0x0E0202
@   6  str  0xDEADBEEF -> 0x0E0300
@   7  str  0xCAFEBABE -> 0x0E0304
@   8  strb 0xA5 -> 0x0E0104, then ldr the whole word and compare its low byte
@
@ Case 8 exists because 0..3 use `ldrb` to check a `strb`, so a fault in the
@ byte-read path would look exactly like a fault in the write path.  Case 8
@ writes the same way and reads a 32-bit word instead, so if it passes while
@ 0..3 fail the store landed and the byte read is what is broken.
@
@ Each test writes a value that differs from what the window plausibly holds --
@ zeros from a planted save, 0xFF from the loader, and the canonical
@ ((i*31)+7)&0xFF pattern `sav_pattern.py` makes -- so a lost write cannot
@ satisfy the comparison by coincidence.  The byte values 0xA5, 0x5A, 0x3C and
@ 0xC3 are distinct, so a byte landing in the wrong lane reports its
@ neighbour's value in the strip rather than a stale one.
@
@ Written in `saveprobe.s`'s idiom deliberately: no `push`/`pop` and no nested
@ helper calls, helpers keep their return address in r7 and leave through
@ `bx lr`, and every address is reloaded by the caller rather than held across a
@ call.  The first version of this probe used ordinary ARM calling convention
@ with `push {r0-r12}` frames and produced squares and strips that looked right
@ but reported nonsense; rather than debug that, the proven shape was reused.
@ One real bug was found and fixed on the way: `mul r8, r9, r8` has Rd == Rm,
@ which ARM7TDMI leaves UNPREDICTABLE, and `as` encodes it with a warning rather
@ than an error.  `tools/make_probe_bin.py` now assembles with
@ `--fatal-warnings` so that cannot recur.

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
    .ascii  "SAVEWPROB"
    .space  3
    .ascii  "SAVE"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]

    @ clear the visible page, so a stale picture cannot be read as an answer
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

    @ ---- 0..3: one byte in each byte lane of a word ----
    ldr     r8, =0x0E0100
    mov     r1, #0xA5
    strb    r1, [r8]
    ldrb    r2, [r8]
    mov     r0, #0
    bl      status

    ldr     r8, =0x0E0101
    mov     r1, #0x5A
    strb    r1, [r8]
    ldrb    r2, [r8]
    mov     r0, #24
    bl      status

    ldr     r8, =0x0E0102
    mov     r1, #0x3C
    strb    r1, [r8]
    ldrb    r2, [r8]
    mov     r0, #48
    bl      status

    ldr     r8, =0x0E0103
    mvn     r1, #0x3C                 @ 0xC3; no rotated-immediate form exists
    strb    r1, [r8]
    ldrb    r2, [r8]
    mov     r0, #72
    bl      status

    @ ---- 4..5: halfwords, which the RTL forces to a single byte lane ----
    ldr     r8, =0x0E0200
    ldr     r1, =0xBEEF
    strh    r1, [r8]
    ldrh    r2, [r8]
    mov     r0, #96
    bl      status

    ldr     r8, =0x0E0202
    ldr     r1, =0x1234
    strh    r1, [r8]
    ldrh    r2, [r8]
    mov     r0, #120
    bl      status

    @ ---- 6..7: words ----
    ldr     r8, =0x0E0300
    ldr     r1, =0xDEADBEEF
    str     r1, [r8]
    ldr     r2, [r8]
    mov     r0, #144
    bl      status

    ldr     r8, =0x0E0304
    ldr     r1, =0xCAFEBABE
    str     r1, [r8]
    ldr     r2, [r8]
    mov     r0, #168
    bl      status

    @ ---- 8: the same store as case 0, read back with a word load ----
    ldr     r8, =0x0E0104
    mov     r1, #0xA5
    strb    r1, [r8]
    ldr     r3, [r8]
    and     r2, r3, #0xFF             @ keep the byte the store should have set
    mov     r0, #192
    bl      status

h:  b       h

@ ---------------------------------------------------------------------------
@ status: r0 = x, r1 = expected, r2 = actual
@
@ Paints a 16x16 square at (x, 8), green when the two agree and red when they
@ do not, then the actual value as eight 2x8 binary cells at (x, 32), most
@ significant bit on the left.  The bit strip is drawn for both colours, so a
@ red square still reports what came back.
@
@ Clobbers r3-r6 and r9-r12; preserves nothing else worth preserving, and its
@ callers reload every address afterwards for that reason.  No push or pop: the
@ return address lives in r7, as in `saveprobe.s`.
@ ---------------------------------------------------------------------------
status:
    mov     r7, lr
    mov     r8, r0                    @ x

    ldr     r5, =0x001F               @ red
    cmp     r2, r1
    ldreq   r5, =0x03E0               @ green: what was written came back

    mov     r4, #8                    @ rows 8..23
sq_row:
    mov     r6, #0                    @ columns 0..15
sq_col:
    mov     r9, #240
    mul     r10, r9, r4               @ 240 * row  (Rd != Rm, unlike the bug)
    add     r10, r10, r8
    add     r10, r10, r6
    ldr     r11, =0x06000000
    add     r11, r11, r10, lsl #1
    strh    r5, [r11]
    add     r6, r6, #1
    cmp     r6, #16
    bne     sq_col
    add     r4, r4, #1
    cmp     r4, #24
    bne     sq_row

    mov     r6, #0                    @ bit index 0..7
bit_loop:
    mov     r1, #7
    sub     r1, r1, r6                @ shift = 7 - i, so bit 7 is leftmost
    mov     r3, r2, lsr r1
    and     r3, r3, #1
    ldr     r5, =0x0000               @ dark for 0
    cmp     r3, #0
    ldrne   r5, =0x03E0               @ light for 1

    mov     r4, #32                   @ rows 32..39
bit_row:
    mov     r9, #240
    mul     r10, r9, r4
    add     r10, r10, r8
    mov     r11, r6, lsl #1           @ 2 pixels per cell
    add     r10, r10, r11
    ldr     r12, =0x06000000
    add     r12, r12, r10, lsl #1
    strh    r5, [r12]
    add     r10, r10, #1              @ second pixel of the cell
    ldr     r12, =0x06000000
    add     r12, r12, r10, lsl #1
    strh    r5, [r12]
    add     r4, r4, #1
    cmp     r4, #40
    bne     bit_row

    add     r6, r6, #1
    cmp     r6, #8
    blt     bit_loop

    mov     lr, r7
    bx      lr

    .ltorg

@ The marker `gbaload` scans for. It must be in the image for the core's save
@ hardware to be configured at all; the scan covers the whole file, so its
@ position here does not matter.
    .ascii  "SRAM_V"
    .align  2
