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
    .ascii  "THUMBP"
    .space  6
    .ascii  "THMB"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Do Thumb loads from SDRAM return the right data?
@
@ Every probe in this tree before this one is ARM, and every cartridge that fails
@ on the board is Thumb.  The memory FSM treats the two differently: a Thumb
@ instruction fetch from ROM is a 16-bit SDRAM read, and the controller
@ re-accepts a 16-bit CPU request once, so its acknowledgement is two clk16
@ periods wide instead of one.  `REQ2_START` in `gba_memory` can leave on the
@ stale tail of that acknowledgement and complete the second request before its
@ data has arrived, so a Thumb load from SDRAM returns the previous SDRAM
@ access's word.  ARM fetches are 32-bit and acknowledge at exactly one edge,
@ which is why no ARM probe has ever seen it.
@
@ The discriminator is where the Thumb code runs, not that it is Thumb:
@   0  green: Thumb code IN ROM reads a ROM table correctly
@      -- this is the exposed case: fetch and data are both SDRAM
@   1  green: Thumb code IN IWRAM reads the same table correctly
@      -- the control: a BRAM fetch means no 16-bit SDRAM first request, so
@         no stale acknowledgement tail.  A Thumb decoder fault would fail
@         this one too, which is what separates the two explanations.
@   2  green: ARM code reads the same table correctly
@      -- the second control, expected to pass on every image
@   3  yellow: reached the end

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

    @ ---- check 0: Thumb code in ROM reading the ROM table
    ldr     r0, =0x03002000
    mov     r1, #0
    str     r1, [r0]                @ clear the marker first
    ldr     r0, =0x08000000 + tab
    ldr     r1, =0x03002000
    ldr     r2, =0xCAFEBABE
    adr     lr, back0
    ldr     r3, =0x08000000 + thumb_body + 1   @ runtime address, Thumb state
    bx      r3
back0:
    ldr     r0, =0x03002000
    ldr     r0, [r0]
    ldr     r1, =1
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #0
    mov     r4, #0
    bl      square

    @ ---- copy the same Thumb routine into IWRAM
    ldr     r0, =0x08000000 + thumb_body
    ldr     r1, =0x03001000
    adr     r5, thumb_end
    adr     r6, thumb_body
    sub     r5, r5, r6
    mov     r2, #0
cpi:
    ldr     r3, [r0, r2]
    str     r3, [r1, r2]
    add     r2, r2, #4
    cmp     r2, r5
    bne     cpi

    @ ---- check 1: Thumb code in IWRAM reading the ROM table (control)
    ldr     r0, =0x03002004
    mov     r1, #0
    str     r1, [r0]
    ldr     r0, =0x08000000 + tab
    ldr     r1, =0x03002004
    ldr     r2, =0xCAFEBABE
    adr     lr, back1
    ldr     r3, =0x03001000 + 1
    bx      r3
back1:
    ldr     r0, =0x03002004
    ldr     r0, [r0]
    ldr     r1, =1
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #16
    mov     r4, #0
    bl      square

    @ ---- check 2: ARM reading the same table (control)
    ldr     r0, =0x03002008
    mov     r1, #0
    str     r1, [r0]
    ldr     r0, =0x08000000 + tab
    ldr     r0, [r0]
    ldr     r1, =0xCAFEBABE
    ldr     r5, =0x001F
    cmp     r0, r1
    ldreq   r5, =0x03E0
    mov     r0, #32
    mov     r4, #0
    bl      square

    @ ---- check 3: end
    ldr     r5, =0x03FF
    mov     r0, #48
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
tab:
    .word   0xCAFEBABE

@ ---------------------------------------------------------------
@ The Thumb routine.  Position independent and free of literal
@ pools so the same bytes can run from ROM and from IWRAM:
@   r0 = table address, r1 = marker address, r2 = expected word
@ Writes 1 to the marker on a match, 0 otherwise.
@ No literal pools: a pool inside a copied block is one more thing that
@ can go wrong when the block is relocated, and the point of this
@ routine is to test the memory FSM rather than the assembler.
@ ---------------------------------------------------------------
    .thumb
    .align  2
thumb_body:
    ldr     r3, [r0]
    cmp     r3, r2
    bne     tbad
    mov     r3, #1
    b       tdone
tbad:
    mov     r3, #0
tdone:
    str     r3, [r1]
    bx      lr
thumb_end:
    .arm
