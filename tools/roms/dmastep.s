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
    .ascii  "DMASTEP"
    .space  5
    .ascii  "DMST"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Step by step, with no inference: does the CPU store land, and does the DMA run?
@
@ The earlier DMA probes left an ambiguity that matters.  A destination that does
@ not equal the pattern is consistent with either "the DMA did not transfer" or
@ "the CPU pre-fill never happened and the location was zero all along".  This
@ probe reads the destination back immediately after writing it, so the pre-fill
@ is a measurement rather than an assumption.
@
@   0  green: the CPU store of 0xF00D to the destination reads back
@   1  green: the source word 0x11111111 reads back from IWRAM
@   2  green: after the DMA the destination holds 0x11111111
@   3  yellow: reached the end
@ And a magenta bar if the destination still holds 0xF00D after the DMA, which
@ would mean the DMA ran but wrote nothing.

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

    @ source: 16 words of 0x11111111 at IWRAM 0x03000500
    ldr     r0, =0x11111111
    ldr     r1, =0x03000500
    mov     r3, #0
fillp:
    str     r0, [r1, r3, lsl #2]
    add     r3, r3, #1
    cmp     r3, #16
    bne     fillp

    @ destination pre-fill, then read it straight back
    ldr     r8, =0x03004000
    ldr     r0, =0x0000F00D
    str     r0, [r8]
    ldr     r0, [r8]
    ldr     r1, =0x0000F00D
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #0
    mov     r4, #0
    bl      draw                  @ square 0

    @ source read-back
    ldr     r0, =0x03000500
    ldr     r0, [r0]
    ldr     r1, =0x11111111
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #16
    mov     r4, #0
    bl      draw                  @ square 1

    @ the DMA: source IWRAM 0x03000500 -> dest IWRAM 0x03004000, 16 words
    ldr     r0, =0x040000D4
    ldr     r1, =0x03000500
    str     r1, [r0]
    ldr     r1, =0x03004000
    str     r1, [r0, #4]
    ldr     r1, =0x8400000F
    str     r1, [r0, #8]

    ldr     r2, =2048
st: subs    r2, r2, #1
    bne     st

    ldr     r8, =0x03004000
    ldr     r0, [r8]

    @ square 2: did it copy?
    ldr     r1, =0x11111111
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #32
    mov     r4, #0
    bl      draw

    @ magenta bar if the destination still holds 0xF00D: DMA ran, wrote nothing
    ldr     r1, =0x0000F00D
    cmp     r0, r1
    bne     nbar
    ldr     r9, =0x06000000
    ldr     r5, =0x7C1F
    mov     r4, #20
by:
    mov     r3, #0
bx:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #240
    bne     bx
    add     r4, r4, #1
    cmp     r4, #28
    bne     by
nbar:

    @ reached the end
    ldr     r5, =0x03FF
    mov     r0, #48
    mov     r4, #0
    bl      draw

h:  b       h

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
    mov     r1, r10
    sub     r1, r1, r4
    cmp     r1, #16
    bne     sq_y
    bx      lr

    .ltorg
