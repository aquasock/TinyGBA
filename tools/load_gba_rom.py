#!/usr/bin/env python3
"""Load a GBA ROM into a loaded TinyGBA core, over the core's own UART.

Why this is a separate tool rather than a flag on the SNES one.  The frame
protocol is identical -- both cores are nand2mario's, and `iosys_bl616.v` is
byte-for-byte the same command table in both -- but the *stream* is not.  The
SNES loader parses a 64-byte SNES header out of the image and sends it first,
because `snestang_top.v` refuses to write SDRAM until that header is complete.
The GBA core has no such requirement: `gbatang_top.sv` takes `loader_do` straight
into the memory path and the cartridge header is just the first bytes of the
image, at offset 0x04, inside the stream already.

So this tool sends exactly the image, from offset 0, with no header dance and no
copier-header stripping -- a GBA dump has none.

    tools/load_gba_rom.py game.gba
    tools/load_gba_rom.py game.gba --uart /dev/ttyUSB1 --dry-run

The commands, from fpga/gba/src/iosys/iosys_bl616.v:

    0xAA len[15:0] payload...            len counts the type byte
    0x06 loading_state[7:0]              non-zero holds the core in reset
    0x07 <data>                          ROM bytes into the core's loader
    0x08 x[7:0]                          x[0] is the OSD overlay on/off

Overlay: a production build keeps the OSD and the BL616 menu closes it.  In
one-wire mode nothing drives that menu, so the overlay stays up and its 960-pixel
window hides the framebuffer behind an empty menu's black -- the same trap
TinySNES hit.  This tool therefore always sends overlay-off, and if the build was
made with -DTINYGBA_OVERLAY_OFF the command is simply ignored.
"""

from __future__ import annotations

import argparse
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is required:  pip install pyserial")

CHUNK = 1024                      # len = 1 + 1024 = 1025, below the core's 2048 limit
FRAME_MAGIC = 0xAA


def frame(payload: bytes) -> bytes:
    n = len(payload)
    if n >= 2048:
        raise ValueError(f"frame of {n} bytes exceeds the core's 2047-byte limit")
    return bytes([FRAME_MAGIC, (n >> 8) & 0xFF, n & 0xFF]) + payload


def check_image(image: bytes) -> str:
    """Sanity-check that this looks like a GBA cartridge, and say what it is.

    A GBA header is 192 bytes at offset 0: a 4-byte branch, the Nintendo logo at
    0x04, the fixed value 0x96 at 0xB2, and a complement check at 0xBD.  Checking
    them catches a wrong file, a zipped dump, or a ROM padded with the wrong
    bytes, before anything is streamed at a machine.
    """
    if len(image) < 0xC0:
        raise SystemExit(f"image is only {len(image)} bytes; not a GBA cartridge")
    logo = image[0x04:0xA0]
    fixed = image[0xB2]
    notes = []
    if len(logo) == 0x9C and logo[:4] == b"\x24\xff\xae\x51":
        notes.append("Nintendo logo present")
    else:
        notes.append("NO Nintendo logo -- this may not be a GBA image")
    if fixed == 0x96:
        notes.append("header byte $B2 = $96")
    else:
        notes.append(f"header byte $B2 = ${fixed:02X}, expected $96")
    # Complement check: sum of 0xA0..0xBC, then -(sum+0x19), low byte.
    chk = (-(sum(image[0xA0:0xBD]) + 0x19)) & 0xFF
    if chk == image[0xBD]:
        notes.append(f"complement check correct (${chk:02X})")
    else:
        notes.append(f"complement check WRONG (got ${image[0xBD]:02X}, want ${chk:02X})")
    name = image[0xA0:0xAC].split(b"\0")[0].decode("ascii", "replace")
    return f"{name.strip() or '(unnamed)'}; " + "; ".join(notes)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom")
    ap.add_argument("--uart", default="/dev/ttyUSB1",
                    help="the core's UART (default /dev/ttyUSB1)")
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--dry-run", action="store_true",
                    help="report the plan and the header check, send nothing")
    args = ap.parse_args()

    with open(args.rom, "rb") as f:
        image = f.read()

    print(f"{args.rom}: {len(image)} bytes")
    print(f"  {check_image(image)}")

    frames = (len(image) + CHUNK - 1) // CHUNK
    print(f"plan: {len(image)} image bytes in {frames} frames of {CHUNK}")
    if args.dry_run:
        return 0

    port = serial.Serial(args.uart, args.baud, timeout=1)
    try:
        def send(payload: bytes) -> None:
            port.write(frame(payload))
            port.flush()

        send(b"\x06\x01")                       # hold the core in reset
        time.sleep(0.05)
        sent = 0
        started = time.time()
        for off in range(0, len(image), CHUNK):
            send(b"\x07" + image[off:off + CHUNK])
            sent += min(CHUNK, len(image) - off)
            if sent % (CHUNK * 64) == 0:
                rate = sent / max(time.time() - started, 1e-6)
                print(f"  {sent}/{len(image)} bytes, {rate / 1024:.0f} KB/s", flush=True)
        # The tail is still moving when the host stops writing, so releasing the
        # reset immediately truncates the image at the end of the stream.
        time.sleep(0.5)
        send(b"\x06\x00")                       # release reset: the game starts
        time.sleep(0.1)
        send(b"\x08\x00")                       # overlay off, or the OSD hides the picture
        print(f"sent {sent} image bytes in {time.time() - started:.1f}s")
    finally:
        time.sleep(0.2)
        port.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
