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
    .ascii  "IEXECPR"
    .space  5
    .ascii  "IEXC"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Can the CPU execute code that lives in IWRAM or EWRAM?
@
@ Why this matters and why nothing tested it.  Every probe in this tree so far
@ executes from the cartridge, and every check verifies DATA access.  A retail
@ cartridge does neither of those things in the same way: Super Mario Advance's
@ crt0 copies its own code out of the cartridge into IWRAM and then branches into
@ it, which makes instruction fetch from internal RAM a required path rather than
@ an incidental one.  A machine that reads and writes IWRAM perfectly and cannot
@ fetch instructions from it would boot the BIOS, accept the cartridge, copy the
@ code successfully and then die at the branch -- which is the shape of every
@ failure recorded in BRD-059 and BRD-060.
@
@ The copied routines are position independent and contain no literal pool,
@ because a literal load inside code that has been moved would read the cartridge
@ address rather than the moved copy.  Everything they need arrives in registers.
@
@ Checks, 16x16 squares across the top:
@   0  green: code copied to IWRAM at 0x03001000 ran and wrote its marker
@   1  green: code copied to EWRAM at 0x02001000 ran and wrote its marker
@   2  yellow: reached the end
@ Visible proof independent of the squares: the IWRAM routine fills the top row
@ of the display green and the EWRAM routine fills the second row magenta, so
@ each one draws from where it is running.

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

    @ clear both markers so a stale value cannot pass
    ldr     r0, =0x03002000
    mov     r1, #0
    str     r1, [r0]
    ldr     r0, =0x02002000
    mov     r1, #0
    str     r1, [r0]

    @ ============ copy the routine into IWRAM and run it ============
    adr     r0, body_code
    ldr     r1, =0x03001000
    adr     r5, body_end
    adr     r6, body_code
    sub     r5, r5, r6
    mov     r5, r5, lsr #2
    mov     r2, #0
cp1:
    ldr     r3, [r0, r2, lsl #2]
    str     r3, [r1, r2, lsl #2]
    add     r2, r2, #1
    cmp     r2, r5
    bne     cp1

    ldr     r0, =0x06000000         @ r0 = VRAM
    ldr     r1, =0x03E0             @ r1 = colour, green
    ldr     r2, =0x03002000         @ r2 = marker address
    ldr     r3, =0x1A2B3C4D            @ r3 = marker value
    ldr     r4, =0x03001000         @ r4 = entry point
    adr     lr, back1
    bx      r4
back1:

    @ ============ copy the routine into EWRAM and run it ============
    adr     r0, body_code
    ldr     r1, =0x02001000
    adr     r5, body_end
    adr     r6, body_code
    sub     r5, r5, r6
    mov     r5, r5, lsr #2
    mov     r2, #0
cp2:
    ldr     r3, [r0, r2, lsl #2]
    str     r3, [r1, r2, lsl #2]
    add     r2, r2, #1
    cmp     r2, r5
    bne     cp2

    ldr     r0, =0x06000000
    ldr     r1, =0x7C1F             @ magenta
    ldr     r2, =0x02002000
    ldr     r3, =0x5E6F7081
    ldr     r4, =0x02001000
    adr     lr, back2
    bx      r4
back2:

    @ ============ report ============
    ldr     r0, =0x03002000
    ldr     r0, [r0]
    ldr     r1, =0x1A2B3C4D
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #0
    mov     r4, #0
    bl      square

    ldr     r0, =0x02002000
    ldr     r0, [r0]
    ldr     r1, =0x5E6F7081
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #16
    mov     r4, #0
    bl      square

    ldr     r5, =0x03FF
    mov     r0, #32
    mov     r4, #0
    bl      square
h:  b       h

square:
    ldr     r9, =0x06000000
    mov     r10, r4
    add     r10, r10, #16           @ squares start below the two filled rows
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
    sub     r1, r1, #16
    cmp     r1, #16
    bne     sq_y
    bx      lr

@ ---------------------------------------------------------------
@ The routine that gets copied.  Position independent, no literal
@ pool: r0 = VRAM, r1 = colour, r2 = marker address, r3 = marker
@ value.  Writes the marker, fills one 240-pixel row, returns.
@ ---------------------------------------------------------------
body_code:
    str     r3, [r2]
    mov     r4, #0
    mov     r4, r0
1:
    strh    r1, [r4]
    add     r4, r4, #2
    cmp     r4, r0
    add     r5, r0, #480
    cmp     r4, r5
    bne     1b
    bx      lr
body_end:

    .ltorg
