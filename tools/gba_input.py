#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Send joystick state to a loaded TinyGBA core over its own UART.

Why this exists.  Every board result in this project so far came from a
cartridge that needed no input: the probes draw their answer and stop, and the
BIOS intro runs by itself.  Anything that requires a human to press something --
a menu, a game, a test that waits for START -- could only be driven by hand, and
that makes it unmeasurable here, because the person at the keyboard cannot be
scripted and the capture is taken by a script.  This is the missing link: the
core's own command table already carries an input command, so input can be
synthesised from the host and timed against a capture.

The command, from `fpga/gba/src/iosys/iosys_bl616.v`:

    0x09 hid1[15:0] hid2[15:0]        send USB joystick state to FPGA

The handler stores the four bytes big-endian into `hid1` and `hid2`, and those
registers hold their value until overwritten, so one write is a held button and
the next write is the release.  `gbatang_top.sv` ORs them into the keypad:

    assign joy_btns_gba = overlay ? 0 : joy_btns | joy_usb1 | joy_usb2 | hid1 | hid2;

Two consequences worth knowing.  The overlay must be off or the OR term is
discarded entirely and no input arrives, which is why this tool sends overlay-off
before its first button.  And the bits are the keypad's own bit positions, which
`gba_joypad` maps like this:

    bit 0 B      bit 4 Up     bit 8  A
    bit 2 Select bit 5 Down   bit 10 L
    bit 3 Start  bit 6 Left   bit 11 R
                 bit 7 Right

Usage, one state per invocation so it can be composed in a shell script:

    tools/gba_input.py press START                 # press and release, 120 ms
    tools/gba_input.py hold DOWN --seconds 0.6     # hold, then release
    tools/gba_input.py set UP|RIGHT                # hold until changed
    tools/gba_input.py release                     # all buttons up

    --uart PATH    serial device (default /dev/ttyUSB1)

A note on what a "press" is.  The GBA keypad is polled by the cartridge, and the
BIOS only latches a key transition when it reads the register between the press
and the release.  A press-and-release inside a single frame can therefore be
missed, so the default hold is 120 ms, which is seven frames at 59.7 Hz.  If a
press does not register, raise `--seconds` before suspecting the input path.
"""
import argparse
import sys
import time

try:
    import serial
except ImportError:                                     # pragma: no cover
    sys.exit("pyserial is required: apt install python3-serial")

FRAME_MAGIC = 0xAA
BAUD = 2_000_000

# The keypad bit positions, from gba_joypad's port map in gbatang_top.sv.  Named
# rather than positional so a typo fails here instead of silently pressing the
# wrong thing on a machine someone is watching.
BUTTONS = {
    "B": 0, "SELECT": 2, "START": 3,
    "UP": 4, "DOWN": 5, "LEFT": 6, "RIGHT": 7,
    "A": 8, "L": 10, "R": 11,
}


# 0xAA, not 0xA5.  This is the value `tools/load_gba_rom.py` uses and the one the
# core accepts; a first version of this tool guessed 0xA5 and every frame was
# silently discarded as an unknown command, which read exactly like a dead input
# path.  Read framing from the tool that already works.
FRAME_MAGIC = 0xAA


def frame(payload: bytes) -> bytes:
    n = len(payload)
    if n >= 2048:
        raise ValueError(f"frame of {n} bytes exceeds the core's 2047-byte limit")
    return bytes([FRAME_MAGIC, (n >> 8) & 0xFF, n & 0xFF]) + payload


def hid_word(names) -> int:
    """Build the 16-bit joystick word for a set of button names."""
    word = 0
    for name in names:
        key = name.strip().upper()
        if not key:
            continue
        if key not in BUTTONS:
            raise SystemExit(f"unknown button {name!r}; known: {', '.join(BUTTONS)}")
        word |= 1 << BUTTONS[key]
    return word


def send_state(port, word: int) -> None:
    """Command 0x09, both joysticks, big-endian as the handler stores them."""
    payload = bytes([0x09,
                     (word >> 8) & 0xFF, word & 0xFF,       # hid1
                     0x00, 0x00])                            # hid2 unused
    port.write(frame(payload))
    port.flush()


def parse_names(values) -> list:
    out = []
    for v in values or []:
        out.extend(v.replace(",", " ").split())
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["press", "hold", "set", "release"])
    ap.add_argument("buttons", nargs="*", help="UP DOWN LEFT RIGHT A B L R START SELECT")
    ap.add_argument("--uart", default="/dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=BAUD)
    ap.add_argument("--seconds", type=float, default=0.12,
                    help="hold time for press/hold (default 0.12, about 7 frames)")
    args = ap.parse_args()

    names = parse_names(args.buttons)
    if args.action in ("press", "hold", "set") and not names:
        raise SystemExit(f"{args.action} needs at least one button")
    if args.action == "release":
        names = []

    word = hid_word(names)

    with serial.Serial(args.uart, args.baud, timeout=0.2) as port:
        # Overlay off first: with the overlay up, joy_btns_gba is forced to zero
        # and every press would be discarded upstream of the keypad.
        port.write(frame(b"\x08\x00"))
        port.flush()
        time.sleep(0.02)

        send_state(port, word)
        if args.action in ("press", "hold"):
            time.sleep(max(args.seconds, 0.0))
            send_state(port, 0)
        # `set` and `release` leave the state in place for the caller to follow.

    held = ", ".join(names) if names else "nothing"
    print(f"{args.action}: {held}"
          + (f" for {args.seconds:.2f}s" if args.action in ("press", "hold") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
