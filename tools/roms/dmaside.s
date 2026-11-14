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
    .ascii  "DMASIDE"
    .space  5
    .ascii  "DMSD"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Which side of a DMA loses the data: the SDRAM source or the BRAM destination?
@
@ BRD-062 measured DMA3 from cartridge ROM into IWRAM writing zeroes.  Both ends
@ of that transfer are suspects: the read data from SDRAM, or the write into the
@ internal RAM.  This probe separates them by varying the source region while
@ keeping the destination and the compare identical.
@
@ Each test pre-fills its destination with 0xF00D, DMAs 16 words from a source
@ that has been filled with pattern word 0 = 0x11111111 by the CPU, waits, then
@ compares the destination halfword.
@
@ Four 16x16 squares, green copied / red not:
@   0  source IWRAM  -> dest EWRAM    (BRAM source, SDRAM destination)
@   1  source IWRAM  -> dest IWRAM    (BRAM source, BRAM destination)
@   2  source EWRAM  -> dest IWRAM    (SDRAM source, BRAM destination)
@   3  source ROM    -> dest IWRAM    (SDRAM source, BRAM destination, the BRD-062 case)
@ Yellow top-right marker: every test returned.

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

    @ fill 16 words at IWRAM 0x03000500 and EWRAM 0x02000500 with the pattern word
    ldr     r0, =0x11111111
    ldr     r1, =0x03000500
    ldr     r2, =0x02000500
    mov     r3, #0
fillp:
    str     r0, [r1, r3, lsl #2]
    str     r0, [r2, r3, lsl #2]
    add     r3, r3, #1
    cmp     r3, #16
    bne     fillp

    @ ---- 0: IWRAM -> EWRAM
    ldr     r8, =0x02001000
    ldr     r0, =0x03000500
    bl      xfer
    mov     r0, #0
    mov     r4, #0
    bl      draw

    @ ---- 1: IWRAM -> IWRAM
    ldr     r8, =0x03002000
    ldr     r0, =0x03000500
    bl      xfer
    mov     r0, #16
    mov     r4, #0
    bl      draw

    @ ---- 2: EWRAM -> IWRAM
    ldr     r8, =0x03003000
    ldr     r0, =0x02000500
    bl      xfer
    mov     r0, #32
    mov     r4, #0
    bl      draw

    @ ---- 3: ROM -> IWRAM
    ldr     r8, =0x03004000
    ldr     r0, =0x08000000 + PAT
    bl      xfer
    mov     r0, #48
    mov     r4, #0
    bl      draw

    @ ---- all returned
    ldr     r9, =0x06000000
    ldr     r5, =0x03FF
    mov     r4, #0
ym:
    mov     r3, #224
yx:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #240
    bne     yx
    add     r4, r4, #1
    cmp     r4, #16
    bne     ym

h:  b       h

@ r0 = source, r8 = destination.  Pre-fills, DMAs 16 words, settles, sets r5.
xfer:
    ldr     r1, =0xF00D
    strh    r1, [r8]

    ldr     r1, =0x040000D4
    str     r0, [r1]
    str     r8, [r1, #4]
    ldr     r0, =0x8400000F
    str     r0, [r1, #8]

    ldr     r2, =2048
st: subs    r2, r2, #1
    bne     st

    ldrh    r0, [r8]
    ldr     r1, =0x1111
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    bx      lr

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

PAT:
    .word   0x11111111, 0x22222222, 0x33333333, 0x44444444
    .word   0x55555555, 0x66666666, 0x77777777, 0x88888888
    .word   0x99999999, 0xAAAAAAAA, 0xBBBBBBBB, 0xCCCCCCCC
    .word   0xDDDDDDDD, 0xEEEEEEEE, 0xFFFFFFFF, 0x00000000
