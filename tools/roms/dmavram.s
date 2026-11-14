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
    .ascii  "DMAVRAM"
    .space  5
    .ascii  "DMVR"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Does a 32-bit DMA into VRAM write BOTH halves of every word?
@
@ The diag cartridge's tilemap is drawn correctly but its tile pixel data is
@ garbage, so text appears at the right place and colour with the wrong glyphs
@ and the logo image is missing entirely.  Both of those are tile data; the
@ tilemap is the only part that is right.
@
@ VRAM does not permit 32-bit CPU access, but a 32-bit DMA into VRAM is legal and
@ is how a cartridge copies a font or a logo.  If such a transfer writes only
@ part of each word, every tile is corrupted while everything that indexes it
@ stays correct -- exactly the symptom.  `minidma` could not see this because it
@ compared one halfword against 0x0000, which is also what a mistimed or partial
@ write leaves behind (TCL-047).
@
@ Four 16x16 squares, green pass / red fail:
@   0  32-bit DMA ROM -> VRAM: word 0 low half correct
@   1  32-bit DMA ROM -> VRAM: word 0 HIGH half correct
@   2  32-bit DMA ROM -> VRAM: all 16 words, both halves, correct
@   3  16-bit DMA ROM -> VRAM: all 16 halfwords correct (the control)
@ Yellow: reached the end.

_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]

    ldr     r9, =0x06000000
    mov     r4, #0
clr:
    ldr     r0, =0x7C00
    add     r3, r9, r4, lsl #1
    strh    r0, [r3]
    add     r4, r4, #1
    ldr     r1, =38400
    cmp     r4, r1
    bne     clr

    adr     r12, PAT

    @ ---- 32-bit DMA to VRAM 0x06008000 (unused by the squares)
    ldr     r0, =0x040000D4
    str     r12, [r0]
    ldr     r1, =0x06008000
    str     r1, [r0, #4]
    ldr     r1, =0x84000010         @ enable, 32-bit, inc/inc, 16 words
    @ The count field is a literal unit count, not a count-minus-one: 0x0F
    @ transfers 15 words.  minidma uses 0x3F and calls it 64; it is 63.
    str     r1, [r0, #8]
    ldr     r2, =2048
s1: subs    r2, r2, #1
    bne     s1

    ldr     r8, =0x06008000
    ldrh    r0, [r8]                @ low half of word 0
    ldr     r1, =0x1111
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #0
    mov     r4, #0
    bl      square

    ldrh    r0, [r8, #2]            @ HIGH half of word 0 -- the one minidma never looked at
    ldr     r1, =0x1111
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #16
    mov     r4, #0
    bl      square

    @ ---- all 16 words, both halves.  PAT is 0x11111111 repeated, so any word
    @ whose halves disagree is a partial write.
    mov     r6, #0
    mov     r3, r8                  @ walk a byte pointer; ARM7TDMI ldrh takes no scaled index
    mov     r2, #0
chk32:
    ldrh    r0, [r3]
    ldr     r1, =0x1111
    cmp     r0, r1
    addne   r6, r6, #1
    add     r3, r3, #2
    add     r2, r2, #1
    cmp     r2, #32
    bne     chk32
    ldr     r5, =0x001F
    cmp     r6, #0
    ldreq   r5, =0x03E0
    mov     r0, #32
    mov     r4, #0
    bl      square

    @ ---- control: 16-bit DMA to a different VRAM address
    adr     r12, PAT
    ldr     r0, =0x040000D4
    str     r12, [r0]
    ldr     r1, =0x06009000
    str     r1, [r0, #4]
    ldr     r1, =0x80000020         @ enable, 16-bit, inc/inc, 32 halfwords
    str     r1, [r0, #8]
    ldr     r2, =2048
s2: subs    r2, r2, #1
    bne     s2

    ldr     r8, =0x06009000
    mov     r6, #0
    mov     r3, r8
    mov     r2, #0
chk16:
    ldrh    r0, [r3]
    ldr     r1, =0x1111
    cmp     r0, r1
    addne   r6, r6, #1
    add     r3, r3, #2
    add     r2, r2, #1
    cmp     r2, #32
    bne     chk16
    ldr     r5, =0x001F
    cmp     r6, #0
    ldreq   r5, =0x03E0
    mov     r0, #48
    mov     r4, #0
    bl      square

    ldr     r5, =0x03FF
    mov     r0, #64
    mov     r4, #0
    bl      square
h:  b       h

square:
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
    mov     r1, r10
    sub     r1, r1, r4
    cmp     r1, #16
    bne     sq_y
    bx      lr

    .ltorg

    .align  2
PAT:
    .word   0x11111111, 0x11111111, 0x11111111, 0x11111111
    .word   0x11111111, 0x11111111, 0x11111111, 0x11111111
    .word   0x11111111, 0x11111111, 0x11111111, 0x11111111
    .word   0x11111111, 0x11111111, 0x11111111, 0x11111111
