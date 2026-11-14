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
    .ascii  "KEYLIVE"
    .space  5
    .ascii  "KEYP"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ KEYINPUT at 0x04000130 is active low: with nothing pressed it reads 0x03FF.
@ A menu that waits for "all keys released" before drawing its list would hang
@ forever if this register read as all-pressed, which is exactly the shape of a
@ cartridge that draws its static text and then stops.
@   green  KEYINPUT == 0x03FF (nothing pressed, as expected)
@   red    anything else
@ plus a bar along the bottom whose length encodes the raw low byte, so a wrong
@ value can still be identified without a second build.
@ Live KEYINPUT readout: one 16x16 square per button, refreshed forever.
@
@ `keyprobe` samples KEYINPUT once at boot, so it cannot answer "does the machine
@ see this button while I am holding it".  This one polls in a loop and repaints,
@ so a capture taken during a hold reports the keypad state at that moment.
@
@ GBA KEYINPUT at 0x04000130 is ACTIVE LOW: a bit is 0 while its button is held.
@ Squares, left to right:
@   0 A   1 B   2 SELECT   3 START   4 RIGHT   5 LEFT   6 UP   7 DOWN   8 R   9 L
@   GREEN = held (bit reads 0)   RED = released (bit reads 1)
@
@ A bottom bar is drawn white if the whole word reads 0x03FF (nothing held), which
@ is the same test keyprobe makes, so the two probes agree by construction.

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

main:
    ldr     r0, =0x04000130
    ldrh    r8, [r0]                @ raw KEYINPUT, active low

    mov     r7, #0                  @ button index
loop:
    @ bit set in KEYINPUT means RELEASED, so green when the bit is clear
    mov     r1, #1
    mov     r1, r1, lsl r7
    tst     r8, r1
    ldr     r5, =0x001F             @ red: released
    ldreq   r5, =0x03E0             @ green: held

    mov     r0, r7, lsl #4          @ x = index * 16
    mov     r4, #8                  @ y = 8
    bl      square

    add     r7, r7, #1
    cmp     r7, #10
    bne     loop

    @ bottom bar: white while nothing is held
    ldr     r0, =0x03FF
    cmp     r8, r0
    bne     nobar
    mov     r4, #40
bar_y:
    mov     r3, #0
bar_x:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    ldr     r5, =0x7FFF
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #240
    bne     bar_x
    add     r4, r4, #1
    cmp     r4, #44
    bne     bar_y
    b       next
nobar:
    @ erase the bar region so a stale bar cannot be read as a current one
    mov     r4, #40
ebar_y:
    mov     r3, #0
ebar_x:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    mov     r5, #0
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #240
    bne     ebar_x
    add     r4, r4, #1
    cmp     r4, #44
    bne     ebar_y
next:
    b       main

square:
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
