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
    .ascii  "SWIPROBE"
    .space  4
    .ascii  "SWIP"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ BIOS SWI probe.  Every cartridge waits for the display: `VBlankIntrWait`
@ (SWI 0x05) is called once per frame by essentially all retail software, and it
@ is a BIOS routine, not something the cartridge can check for itself.  A core
@ that runs code, reads ROM, writes frame memory and takes interrupts correctly
@ can still hang on the first frame if SWI dispatch is wrong, which is exactly
@ the shape of the failure under investigation -- a cartridge that runs briefly
@ and then stops.
@
@ Required to pass under mGBA with the retail BIOS before any board result is
@ read, per TCL-041.
@
@ Five 16x16 squares across the top, green pass / red fail:
@   0  SWI 0x06 Div: 1000 / 7 returns quotient 142 and remainder 6
@   1  one SWI 0x05 VBlankIntrWait returned at all
@   2  sixty consecutive VBlankIntrWait calls returned -- the per-frame pattern
@   3  the interrupt handler counted at least sixty wakes
@ Then a white bar at y=24 whose length is count*8, i.e. a number.
@ If squares 1 and 2 are simply absent, the machine is stuck inside the SWI,
@ which is itself the finding.

_start:
    @ A handler must be installed before any wait, because VBlankIntrWait raises
    @ IME and a pending VBlank with [0x03007FFC] = 0 would send the CPU to the
    @ BIOS reset vector.
    ldr     r0, =0x04000208
    mov     r1, #0
    strh    r1, [r0]                @ IME = 0
    ldr     r0, =0x04000200
    strh    r1, [r0]                @ IE = 0
    adr     r1, _irq
    ldr     r0, =0x03007FFC
    str     r1, [r0]

    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]
    ldr     r0, =0x0403
    strh    r0, [r11]               @ mode 3, BG2 on

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

    @ ---- zero the wake counter
    ldr     r0, =0x03000000
    mov     r1, #0
    str     r1, [r0]

    @ ---- progress marker: reached the first SWI at all.  Drawn before any SWI
    @ so that a dead SWI is distinguishable from a dead cartridge.
    ldr     r5, =0x7C00
    mov     r0, #0
    mov     r4, #0
    bl      square                  @ square 0: blue = reached the SWI call

    @ ---- check 1: SWI 0x06 Div.  1000 / 7 = 142 remainder 6.
    mov     r0, #1000
    mov     r1, #7
    swi     0x06
    cmp     r0, #142
    movne   r6, #1                  @ fail
    cmpeq   r1, #6
    movne   r6, #1
    moveq   r6, #0
    mov     r5, #0
    cmp     r6, #0
    ldreq   r5, =0x03E0
    ldrne   r5, =0x001F
    mov     r0, #16
    mov     r4, #0
    bl      square                  @ square 1: Div

    @ ---- check 1: does VBlankIntrWait return at all?
    swi     0x05
    ldr     r5, =0x03E0             @ reaching this line is the pass
    mov     r0, #32
    mov     r4, #0
    bl      square                  @ square 2: one wait returned

    @ ---- check 2: sixty consecutive waits, the per-frame pattern
    mov     r7, #60
wait60:
    swi     0x05
    subs    r7, r7, #1
    bne     wait60
    ldr     r5, =0x03E0
    mov     r0, #48
    mov     r4, #0
    bl      square                  @ square 3: sixty waits returned

    @ ---- check 3: the handler woke at least sixty times
    ldr     r0, =0x03000000
    ldr     r6, [r0]
    mov     r5, #0
    cmp     r6, #60
    ldrhs   r5, =0x03E0
    ldrlo   r5, =0x001F
    mov     r0, #64
    mov     r4, #0
    bl      square                  @ square 4: handler woke >= 60 times

    ldr     r0, =0x04000208
    mov     r1, #0
    strh    r1, [r0]                @ IME = 0 for the bar

    ldr     r0, =0x03000000
    ldr     r6, [r0]
    mov     r7, r6, lsl #3
    cmp     r7, #240
    movhi   r7, #240
    mov     r4, #24
bar_y:
    mov     r3, #0
bar_x:
    cmp     r3, r7
    bhs     bar_next
    mov     r1, #240
    mul     r2, r1, r4
    add     r2, r2, r3
    add     r2, r9, r2, lsl #1
    ldr     r5, =0x7FFF
    strh    r5, [r2]
bar_next:
    add     r3, r3, #1
    cmp     r3, #240
    bne     bar_x
    add     r4, r4, #1
    mov     r1, r4
    sub     r1, r1, #24
    cmp     r1, #8
    bne     bar_y

    ldr     r11, =0x04000000
    ldr     r0, =0x0403
    strh    r0, [r11]
h:  b       h

@ Minimal handler.  It acknowledges VBlank through IF at 0x04000202 -- not IE
@ at 0x04000200, which would leave the source pending and starve every wait
@ (TCL-043) -- and counts the wake.  lr arrives as 0x138 from the dispatcher,
@ so a plain bx lr is the correct return (BRD-057).
_irq:
    stmfd   sp!, {r0-r3, r12, lr}
    ldr     r0, =0x04000202
    mov     r1, #1
    strh    r1, [r0]
    ldr     r0, =0x03000000
    ldr     r1, [r0]
    add     r1, r1, #1
    str     r1, [r0]
    ldmfd   sp!, {r0-r3, r12, lr}
    bx      lr

@ r0 = x, r4 = y, r5 = colour BGR555; clobbers r1,r2,r3,r10
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
