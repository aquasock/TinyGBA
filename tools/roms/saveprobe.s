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
    .ascii  "SAVEPROBE"
    .space  3
    .ascii  "SAVE"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Does the cartridge save window work, as a game would use it?
@
@ Two questions, one square each, painted 16x16 at the top left.
@   0  (x=0)   the window ALREADY held the canonical pattern before it wrote
@   1  (x=32)  a DIFFERENT pattern written through the window read back intact
@
@ Square 1 deliberately writes a pattern that differs from the canonical one by
@ one, and that detail is the whole test. A first version wrote the canonical
@ pattern and checked it read back, which passes whenever the window already
@ holds that pattern -- so on a board where reads work and writes are silently
@ dropped it went green for the wrong reason, and only the second run after a
@ restore showed both squares green. Writing something different means a
@ dropped write leaves the old contents and the square is red, which is what
@ makes it a test of the write rather than of the contents.
@
@ Why both. The second square says the write path works at all. The first says
@ a save came back from somewhere else -- the card, via `gbaload`'s restore --
@ because the probe has not yet written anything at the moment it is sampled.
@ So the sequence that tests a real save is: run once (square 1 green, square 2
@ red), `gbasave` while that pattern is in the window, power-cycle or reload,
@ `gbaload` with the .sav in place, run again -- and now both are green.
@
@ A caution worth writing down: if the board has NOT been power-cycled between
@ runs, the window still holds what the previous run wrote and square 2 is green
@ for the wrong reason. BRD-094 records that this store decays rather than
@ clears, so the window surviving a reload proves nothing on its own.
@
@ The pattern is ((offset * 31) + 7) & 0xFF, which is byte-for-byte the one
@ `tools/save/sav_pattern.py` produces, so a dump taken while this pattern is in
@ the window can be checked with that tool and no new one.
@
@ The image carries an `SRAM_V` marker below, which is what makes `gbaload`
@ configure the core's save hardware as SRAM; without it the window is read-only
@ and every write is discarded (BRD-070).

_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]

    @ clear the visible page so a stale picture cannot be read as an answer
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

    @ --- square 0: was the pattern already here, before we write? ---
    @ `draw` clobbers r9 and r10, so the window base and length are reloaded
    @ before every routine that needs them rather than held across a call.
    ldr     r8, =0x0E000000          @ SRAM window
    ldr     r10, =32768              @ 32 KiB, the whole of an SRAM cart's save
    bl      scan                     @ sets r5 from whether all bytes matched
    mov     r0, #0
    mov     r4, #0
    bl      draw

    @ --- square 1: write a DIFFERENT pattern, then read it back ---
    ldr     r8, =0x0E000000
    ldr     r10, =32768
    bl      fill_alt
    ldr     r8, =0x0E000000
    ldr     r10, =32768
    bl      verify_alt
    mov     r0, #32
    mov     r4, #0
    bl      draw

    @ Leave the canonical pattern behind, so a `gbasave` taken now can be
    @ checked with `tools/save/sav_pattern.py` and no new tool.
    ldr     r8, =0x0E000000
    ldr     r10, =32768
    bl      fill

h:  b       h

@ r1 = ((r0 * 31) + 7) & 0xFF, the pattern byte for offset r0
pat:
    mov     r1, r0, lsl #5           @ i * 32
    sub     r1, r1, r0               @ i * 32 - i = i * 31
    add     r1, r1, #7
    and     r1, r1, #0xFF
    bx      lr

@ r1 = ((r0 * 31) + 8) & 0xFF -- the canonical pattern plus one, so a dropped
@ write cannot be mistaken for a successful one
pat_alt:
    mov     r1, r0, lsl #5
    sub     r1, r1, r0
    add     r1, r1, #8
    and     r1, r1, #0xFF
    bx      lr

@ writes the pattern to r10 bytes at r8
fill:
    mov     r7, lr
    mov     r6, #0
fw:
    mov     r0, r6
    bl      pat
    strb    r1, [r8, r6]
    add     r6, r6, #1
    cmp     r6, r10
    bne     fw
    mov     lr, r7
    bx      lr

@ counts mismatches reading back, sets r5 green only when none
verify:
    mov     r7, lr
    mov     r6, #0
    mov     r9, #0                   @ mismatch count
vw:
    mov     r0, r6
    bl      pat
    ldrb    r2, [r8, r6]
    cmp     r2, r1
    addne   r9, r9, #1
    add     r6, r6, #1
    cmp     r6, r10
    bne     vw
    mov     r5, #0
    cmp     r9, #0
    ldreq   r5, =0x03E0              @ green
    ldrne   r5, =0x001F              @ red
    mov     lr, r7
    bx      lr

@ counts bytes that ALREADY match, sets r5 green only when every byte does
scan:
    mov     r7, lr
    mov     r6, #0
sw:
    mov     r0, r6
    bl      pat
    ldrb    r2, [r8, r6]
    cmp     r2, r1
    bne     snof                     @ one miss is enough to say "not restored"
    add     r6, r6, #1
    cmp     r6, r10
    bne     sw
    ldr     r5, =0x03E0              @ green: all matched
    mov     lr, r7
    bx      lr
snof:
    ldr     r5, =0x001F              @ red: some byte differed
    mov     lr, r7
    bx      lr

@ as `fill`, with the alternate pattern
fill_alt:
    mov     r7, lr
    mov     r6, #0
faw:
    mov     r0, r6
    bl      pat_alt
    strb    r1, [r8, r6]
    add     r6, r6, #1
    cmp     r6, r10
    bne     faw
    mov     lr, r7
    bx      lr

@ as `verify`, with the alternate pattern
verify_alt:
    mov     r7, lr
    mov     r6, #0
    mov     r9, #0
vaw:
    mov     r0, r6
    bl      pat_alt
    ldrb    r2, [r8, r6]
    cmp     r2, r1
    addne   r9, r9, #1
    add     r6, r6, #1
    cmp     r6, r10
    bne     vaw
    mov     r5, #0
    cmp     r9, #0
    ldreq   r5, =0x03E0
    ldrne   r5, =0x001F
    mov     lr, r7
    bx      lr

@ r0 = x, r4 = y, r5 = colour
draw:
    ldr     r9, =0x06000000
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
    sub     r2, r10, r4
    cmp     r2, #16
    bne     sq_y
    bx      lr

@ The marker `gbaload` scans for. It must be in the image for the core's save
@ hardware to be configured at all; the scan is over the whole file, so its
@ position here does not matter.
    .ascii  "SRAM_V"
    .align  2
