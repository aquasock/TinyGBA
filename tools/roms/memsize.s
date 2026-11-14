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
    .ascii  "MEMSIZE"
    .space  5
    .ascii  "MEMS"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ EWRAM integrity at four region sizes, to find where it stops holding.
@ Same fill/read-back scheme as memtest.s, one square per size.
@   0  1024 words (4 KiB)      1  8192 words (32 KiB)
@   2  32768 words (128 KiB)   3  65536 words (256 KiB)
@ A size that fails is red; a size that passes is green.
@ Only EWRAM, so a failure cannot be blamed on another region.

_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]

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

    ldr     r8, =0x02000000

    @ size 1024
    ldr     r10, =1024
    mov     r0, #0
    bl      fill
    bl      check
    mov     r0, #0
    mov     r4, #0
    bl      draw

    @ size 8192
    ldr     r10, =8192
    mov     r0, #0
    bl      fill
    bl      check
    mov     r0, #16
    mov     r4, #0
    bl      draw

    @ size 32768
    ldr     r10, =32768
    mov     r0, #0
    bl      fill
    bl      check
    mov     r0, #32
    mov     r4, #0
    bl      draw

    @ size 65536
    ldr     r10, =65536
    mov     r0, #0
    bl      fill
    bl      check
    mov     r0, #48
    mov     r4, #0
    bl      draw

h:  b       h

@ fills r10 words at r8 with index*257 + 0xA5A5
fill:
    mov     r0, #0
fw:
    mov     r1, r0, lsl #8
    add     r1, r1, r0
    ldr     r2, =0xA5A5
    add     r1, r1, r2
    str     r1, [r8, r0, lsl #2]
    add     r0, r0, #1
    cmp     r0, r10
    bne     fw
    bx      lr

@ reads back r10 words, sets r5 from the mismatch count in r6
check:
    mov     r6, #0
    mov     r0, #0
cr:
    mov     r1, r0, lsl #8
    add     r1, r1, r0
    ldr     r2, =0xA5A5
    add     r1, r1, r2
    ldr     r3, [r8, r0, lsl #2]
    cmp     r3, r1
    addne   r6, r6, #1
    add     r0, r0, #1
    cmp     r0, r10
    bne     cr
    mov     r5, #0
    cmp     r6, #0
    ldreq   r5, =0x03E0
    ldrne   r5, =0x001F
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
    mov     r1, r10
    sub     r1, r1, r4
    cmp     r1, #16
    bne     sq_y
    bx      lr

    .ltorg
