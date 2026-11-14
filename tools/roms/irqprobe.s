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
    .ascii  "IRQPROBE"
    .space  4
    .ascii  "IQPR"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Three independent checks, one 16x16 square each, green pass red fail:
@   0  VBlank flag in DISPSTAT rises while polling (no interrupts involved)
@   1  HALT wakes when a VBlank interrupt arrives
@   2  the IRQ handler runs at all
@ Then a full-width bar whose length is the interrupt count, so a partial
@ failure is readable rather than just "some red".
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

    @ ---- check 0: does the VBlank flag rise at all?  Poll for up to 200k spins.
    mov     r6, #0                  @ saw-vblank
    mov     r7, #0
poll:
    ldr     r0, =0x04000004
    ldrh    r1, [r0]
    ands    r1, r1, #1
    moveq   r7, r7, lsl #0
    addne   r6, r6, #1
    cmp     r6, #0
    bne     poll_done
    add     r7, r7, #1
    ldr     r2, =200000
    cmp     r7, r2
    bne     poll
poll_done:
    mov     r5, #0
    cmp     r6, #0
    ldreq   r5, =0x001F
    ldrne   r5, =0x03E0
    mov     r0, #0
    mov     r4, #0
    bl      square

    @ ---- install handler, enable VBlank IRQ
    ldr     r0, =0x03000000         @ counter, safely inside IWRAM
    mov     r1, #0
    str     r1, [r0]
    ldr     r0, =0x03007FFC
    ldr     r1, =_irq
    str     r1, [r0]
    ldr     r0, =0x04000004
    mov     r1, #8
    strh    r1, [r0]                @ DISPSTAT VBlank IRQ enable
    ldr     r0, =0x04000200
    mov     r1, #1
    strh    r1, [r0]                @ IE = VBlank
    ldr     r0, =0x04000208
    mov     r1, #1
    strh    r1, [r0]                @ IME

    @ ---- check 1: HALT, then confirm the handler ran
    ldr     r0, =0x04000301
    mov     r1, #0
    strb    r1, [r0]                @ HALTCNT = 0: halt until an enabled IRQ
    @ any instruction after HALT only executes once the IRQ has woken us
    ldr     r0, =0x03000000
    ldr     r6, [r0]                @ how many interrupts arrived
    mov     r5, #0
    cmp     r6, #0
    ldreq   r5, =0x001F
    ldrne   r5, =0x03E0
    mov     r0, #16
    mov     r4, #0
    bl      square

    @ ---- check 2: a second halt proves the wake is repeatable, and the handler
    @ count grows.  If the first halt woke but a later one does not, the screen
    @ shows green in square 1 and red here.
    ldr     r2, =0x03000000
    ldr     r3, [r2]                @ count before
    ldr     r0, =0x04000301
    mov     r1, #0
    strb    r1, [r0]
    ldr     r3, [r2]                @ count after
    mov     r5, #0
    cmp     r3, #2
    ldrlo   r5, =0x001F
    ldrhs   r5, =0x03E0
    mov     r0, #32
    mov     r4, #0
    bl      square

    @ ---- interrupts off before drawing the bar
    ldr     r0, =0x04000208
    mov     r1, #0
    strh    r1, [r0]

    @ ---- bar: white, width = count*8 capped at 240
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

_irq:
    sub     lr, lr, #4
    stmfd   sp!, {r0-r3, lr}
    ldr     r0, =0x04000200         @ IF
    mov     r1, #1
    strh    r1, [r0]                @ acknowledge VBlank
    ldr     r0, =0x03000000
    ldr     r1, [r0]
    add     r1, r1, #1
    str     r1, [r0]
    ldmfd   sp!, {r0-r3, lr}
    bx      lr

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
