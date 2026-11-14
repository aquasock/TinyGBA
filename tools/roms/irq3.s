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
    .ascii  "IRQ3PROBE"
    .space  3
    .ascii  "IQ3P"
    .ascii  "01"
    .byte   0x96
    .space  13
    .align  2

@ Third-generation interrupt probe.  The two predecessors were both broken
@ instruments, and each defect taught something that applies to the board too:
@
@  1  adr is PC-relative, so at runtime it already yields the executing address
@     (0x0800033C), not the link-time offset (0x33C).  Adding the cartridge base
@     on top produced 0x1000033C -- unmapped -- so every interrupt jumped into
@     open bus.  An absolute `ldr =sym` needs the base; an `adr` never does.
@  2  The pointer readback compared the stored value against the same expression
@     it had just stored, so it read green while pointing at open bus.
@  3  lr at handler entry is NOT (return + 4).  The retail BIOS dispatcher at
@     0x128 does `push {r0-r3,ip,lr}`, `mov r0,#0x04000000`,
@     `add lr,pc,#0` (pc = 0x138), `ldr pc,[r0,#-4]` (that is 0x03FFFFFC, the
@     IWRAM mirror of the vector at 0x03007FFC).  So lr arrives exactly equal to
@     0x138, the address of the `pop` that unwinds the dispatch.  A handler must
@     end in a plain `bx lr`; subtracting 4 as the vector-entry idiom does sends
@     it back to `0x134` and re-dispatches forever.
@
@ This probe no longer crosses an interrupt in a busy-wait before proving the
@ main flow survives one, because "handler ran but main flow never resumed" is
@ exactly what both a broken return and an interrupt storm look like.
@
@ Five 16x16 squares across the top, green pass / red fail:
@   0  the VBlank flag in DISPSTAT rises while polling (no interrupts involved)
@   1  the BIOS left IE = 0 and IME = 0 at cartridge entry
@   2  [0x03007FFC] holds the value we stored (a store check, not an address one)
@   3  MAIN FLOW SURVIVED.  Drawn immediately after IME = 1, with no wait in
@      between: if it is missing, the first interrupt never gave the machine
@      back, which is an interrupt storm rather than a slow handler.
@   4  the handler was entered and the dispatch count moved, after a bounded
@      wait with interrupts live
@ Then a white bar at y=24 whose length is count*8, i.e. a number.

_start:
    @ Record what the BIOS handed us before touching anything, then turn
    @ interrupts off.  A cartridge that starts with IE/IME live takes an
    @ interrupt whose handler pointer is still [0x03007FFC] = 0.
    ldr     r0, =0x04000208
    ldrh    r1, [r0]
    ldr     r2, =0x03000100
    str     r1, [r2]                @ initial IME
    ldr     r0, =0x04000200
    ldrh    r1, [r0]
    str     r1, [r2, #4]            @ initial IE
    mov     r1, #0
    strh    r1, [r0]                @ IE = 0
    ldr     r0, =0x04000208
    strh    r1, [r0]                @ IME = 0
    ldr     r0, =0x04000004
    mov     r1, #0
    strh    r1, [r0]                @ DISPSTAT IRQ enables off

    ldr     r11, =0x04000000
    mov     r0, #0
    strh    r0, [r11]               @ forced blank off
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

    @ ---- check 0: does the VBlank flag rise at all?
    mov     r6, #0
    mov     r7, #0
poll:
    ldr     r0, =0x04000004
    ldrh    r1, [r0]
    tst     r1, #1
    addne   r6, r6, #1
    cmp     r6, #0
    bne     poll_done
    add     r7, r7, #1
    ldr     r2, =400000
    cmp     r7, r2
    bne     poll
poll_done:
    mov     r5, #0
    cmp     r6, #0
    ldreq   r5, =0x001F             @ red
    ldrne   r5, =0x03E0             @ green
    mov     r0, #0
    mov     r4, #0
    bl      square

    @ ---- store the handler pointer
    adr     r1, _irq                @ already the runtime address
    mov     r10, r1
    ldr     r0, =0x03007FFC
    str     r1, [r0]
    ldr     r2, [r0]
    mov     r5, #0
    cmp     r2, r10
    ldreq   r5, =0x03E0
    ldrne   r5, =0x001F
    mov     r0, #32
    mov     r4, #0
    bl      square                  @ square 2

    @ ---- zero both counters
    ldr     r0, =0x03000000
    mov     r1, #0
    str     r1, [r0]                @ dispatch count
    ldr     r0, =0x03000004
    mov     r1, #0
    str     r1, [r0]                @ handler-entry count

    @ ---- check 1: what did the BIOS leave in IE and IME?  Both must be 0.
    ldr     r0, =0x03000100
    ldr     r1, [r0]
    ldr     r2, [r0, #4]
    orr     r1, r1, r2
    mov     r5, #0
    cmp     r1, #0
    ldreq   r5, =0x03E0
    ldrne   r5, =0x001F
    mov     r0, #16
    mov     r4, #0
    bl      square                  @ square 1

    @ ---- clear pending VBlank, then enable it.  IF lives at 0x04000202; IE is
    @ the word below it, and acknowledging through IE leaves the source pending,
    @ which starves the main flow instead of breaking anything visibly.
    ldr     r0, =0x04000202
    mov     r1, #1
    strh    r1, [r0]
    ldr     r0, =0x04000004
    mov     r1, #8
    strh    r1, [r0]                @ DISPSTAT VBlank IRQ enable
    ldr     r0, =0x04000200
    mov     r1, #1
    strh    r1, [r0]                @ IE = VBlank
    ldr     r0, =0x04000208
    mov     r1, #1
    strh    r1, [r0]                @ IME = 1 -- from here an interrupt can land

    @ ---- check 3: main flow survived.  No wait at all between IME = 1 and this
    @ square, so its presence is the measurement.  A green square that is simply
    @ absent is the world's clearest "the machine did not come back".
    ldr     r5, =0x7C00             @ blue: visible even if the value is "no"
    mov     r0, #48
    mov     r4, #0
    bl      square                  @ square 3: a value, drawn after IME = 1

    @ ---- bounded wait for a dispatch, interrupts live.  Bounded on purpose:
    @ if the machine never gives the main flow back, this loop still ends and
    @ the absence of square 4 becomes the reading.
    mov     r7, #0
spin:
    ldr     r0, =0x03000000
    ldr     r1, [r0]
    cmp     r1, #0
    bne     spin_done
    add     r7, r7, #1
    ldr     r2, =2000000
    cmp     r7, r2
    bne     spin
spin_done:

    @ ---- check 4: did a dispatch actually complete?
    ldr     r0, =0x03000000
    ldr     r6, [r0]
    mov     r5, #0
    cmp     r6, #0
    ldrne   r5, =0x03E0
    ldreq   r5, =0x001F
    mov     r0, #64
    mov     r4, #0
    bl      square                  @ square 4

    @ ---- interrupts off before drawing the bar
    ldr     r0, =0x04000208
    mov     r1, #0
    strh    r1, [r0]

    @ ---- bar: white, width = count*8 capped at 240, y = 24..31
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

@ Called by the retail BIOS dispatcher with lr = 0x138, the address of its own
@ `pop`.  No lr adjustment: see the header note, this was measured against the
@ disassembly of the shipped BIOS rather than assumed from the vector idiom.
_irq:
    stmfd   sp!, {r0-r3, r12, lr}
    @ Markers in the top right corner say how far the handler got, because a
    @ handler that is entered and then dies looks identical on screen to one
    @ that is never entered at all.
    ldr     r0, =0x060001D8         @ (236, 0)
    ldr     r1, =0x7FFF
    strh    r1, [r0]                @ marker 1: entered
    ldr     r0, =0x03000004
    ldr     r1, [r0]
    add     r1, r1, #1
    str     r1, [r0]                @ entry count
    ldr     r0, =0x04000202         @ IF -- not 0x04000200, that is IE
    mov     r1, #1
    strh    r1, [r0]                @ acknowledge VBlank
    ldr     r0, =0x060001DA         @ (237, 0)
    ldr     r1, =0x7FFF
    strh    r1, [r0]                @ marker 2: acknowledged
    ldr     r0, =0x03000000
    ldr     r1, [r0]
    add     r1, r1, #1
    str     r1, [r0]                @ dispatch count
    ldr     r0, =0x060001DC         @ (238, 0)
    ldr     r1, =0x7FFF
    strh    r1, [r0]                @ marker 3: counted
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
