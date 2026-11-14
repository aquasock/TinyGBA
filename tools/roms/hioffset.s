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
    .ascii  "HIOFFSET"
    .space  4
    .ascii  "HIOS"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Does the machine execute code that lives far from the start of the image?
@ Every probe so far is 4 KiB and the failing cartridges are 284 KiB and 4 MiB,
@ so instruction fetch past a few kilobytes has never been exercised.
@
@ The program lays a marker in IWRAM, jumps to a routine placed at 0x08070000 -- 448 KiB
@ into the image -- and that routine sets a second marker and returns.  Screen:
@   green   the far routine ran and returned
@   red     it did not
@   blue    the far routine ran but did not return
_start:
    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]

    ldr     r9, =0x06000000
    mov     r4, #0
clr:
    ldr     r0, =0x001F             @ red unless proven otherwise
    mov     r1, r4, lsl #1
    add     r3, r9, r1
    strh    r0, [r3]
    add     r4, r4, #1
    ldr     r1, =38400
    cmp     r4, r1
    bne     clr

    @ markers: 0x03000000 = 0 before the call, 1 after
    ldr     r0, =0x03000000
    mov     r1, #0
    str     r1, [r0]
    ldr     r0, =0x03000004
    mov     r1, #0
    str     r1, [r0]

    @ call the far routine
    ldr     r3, =0x08070000
    mov     lr, pc
    bx      r3

    @ returned: check both markers
    ldr     r0, =0x03000004
    ldr     r6, [r0]                @ set by the far routine
    ldr     r0, =0x03000000
    ldr     r7, [r0]                @ set after return

    @ Only ONE marker is meaningful here.  A first version also checked a marker
    @ that is set after painting, so it read 0 and painted blue unconditionally --
    @ green was unreachable.  Green means the far routine ran and returned, which
    @ is exactly r6 == 1 and the fact that this code is executing at all.
    ldr     r5, =0x001F             @ red: never returned
    cmp     r6, #1
    ldreq   r5, =0x03E0             @ green: far routine ran and we came back
    ldrne   r5, =0x7C00             @ blue: returned but the marker was not set
paint:
    mov     r4, #0
pt:
    mov     r3, #0
ptx:
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    strh    r5, [r2]
    add     r3, r3, #1
    cmp     r3, #240
    bne     ptx
    add     r4, r4, #1
    cmp     r4, #160
    bne     pt

    @ a second marker row: white means the program reached the very end
    ldr     r0, =0x03000000
    mov     r1, #1
    str     r1, [r0]

    ldr     r11, =0x04000000
    ldr     r0, =0x0403
    strh    r0, [r11]
h:  b       h

    .ltorg
    .align  2
    .space  0x70000 - (. - _start)  @ pad up to 0x08070000
FAR:
    ldr     r0, =0x03000004
    mov     r1, #1
    str     r1, [r0]
    bx      lr
