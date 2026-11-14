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
    .ascii  "OAMPROBE"
    .space  4
    .ascii  "OAMP"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Object memory at 0x07000000, which no probe has touched, and OBJ rendering.
@ The diagnostic cartridge's menu draws a block cursor beside the selected item,
@ so sprite handling is the largest subsystem still unmeasured here.
@
@ Screen: blue background in mode 3.  Square at top-left is green when an OAM
@ write reads back correctly, red when it does not.  A white 8x8 block at
@ (60,40) is a rendered sprite: OBJ goes to the video output and not back into
@ frame memory, so it can only be checked by looking, and a first version of
@ this probe tried to read it out of VRAM and would have failed anywhere.
_start:
    ldr     r11, =0x04000000

    ldr     r9, =0x06000000
    mov     r4, #0
clr:
    ldr     r0, =0x7C00             @ blue
    mov     r1, r4, lsl #1
    add     r3, r9, r1
    strh    r0, [r3]
    add     r4, r4, #1
    ldr     r1, =38400
    cmp     r4, r1
    bne     clr

    @ ---- write three OAM halfwords and read them back
    ldr     r0, =0x07000000
    mov     r1, #40
    mov     r2, #60
    mov     r3, #0
    strh    r1, [r0]
    strh    r2, [r0, #2]
    strh    r3, [r0, #4]
    ldrh    r4, [r0]
    ldrh    r5, [r0, #2]
    ldrh    r6, [r0, #4]

    mov     r8, #0                  @ 0 = pass
    cmp     r4, r1
    movne   r8, #1
    cmp     r5, r2
    movne   r8, #1
    cmp     r6, r3
    movne   r8, #1

    ldr     r5, =0x03E0
    cmp     r8, #0
    ldrne   r5, =0x001F
    mov     r0, #0
    mov     r4, #0
    bl      sq

    @ ---- OBJ palette entry 1 = white, OBJ tile 0 filled with index 1
    ldr     r0, =0x05000200
    ldr     r1, =0x7FFF
    strh    r1, [r0, #2]

    ldr     r0, =0x06010000
    ldr     r1, =0x11111111
    mov     r2, r0
    mov     r3, #8
otile:
    str     r1, [r2], #4
    subs    r3, r3, #1
    bne     otile

    @ OAM entry 0 already has y=40, x=60, tile 0 from the write above.

    @ ---- mode 3, BG2 and OBJ on
    ldr     r0, =0x1403
    strh    r0, [r11]

    @ settle
    ldr     r2, =300000
st:
    subs    r2, r2, #1
    bne     st
h:  b       h

@ sq: r0=x0, r4=y0, r5=colour, clobbers r1,r2,r3,r10
sq:
    mov     r10, r4
sqy:
    mov     r3, #0
sqx:
    mov     r1, #240
    mul     r2, r1, r10
    add     r2, r2, r0
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #16
    bne     sqx
    add     r10, r10, #1
    mov     r1, r10
    sub     r1, r1, r4
    cmp     r1, #16
    bne     sqy
    bx      lr
