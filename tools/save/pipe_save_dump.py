#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Read the running core's save window over `fpgapipe`, without the SD card.

    tools/save/pipe_save_dump.py --size 32k  out.sav
    tools/save/pipe_save_dump.py --size 128k out.sav --check-canonical

Why this exists.  `gbasave` is the documented way to take a save off the board,
and it is also the command most likely to stop the BL616 console: the console
has died on large SD transfers (`gbasave` twice, `tangput` once) and the only
recovery is removing power, which also erases the FPGA and the cartridge.  The
record of that, and of the route used here, is in `.ai/core-reference.md`
("The console dies on large SD transfers ...").  `fpgapipe` turns the console
into a raw byte pipe to UART1, so a host can send the save engine's own read
frames -- type 0x0e, three address bytes from a base of 0x700000 -- and receive
type 0x10 replies of 128 bytes, with the SD and the shell's frame decoder out of
the circuit.  Nothing is written to the card, which also means a real save on
the card cannot be overwritten by a measurement.

What it deliberately does NOT do.  It sends no stage-3 configuration frame.  A
cartridge loaded with `gbaload` already has its backup type set from its header,
and re-sending one mid-game would change the machine being measured.  The read
therefore returns whatever store the core's current `config_backup_type`
selects, which is the store the running game uses.

Reading is safe while a cartridge runs: the RISC-V port is a separate client of
the SDRAM controller and the save engine, and a dump taken mid-play is valid
evidence (BRD-095).
"""
import argparse
import glob
import hashlib
import os
import sys
import time
from pathlib import Path


MAGIC = 0xAA
CHUNK = 128
BASE = 0x700000
FRAME_READ = 0x0E
FRAME_DATA = 0x10
SIZES = {"8k": 8192, "32k": 32768, "64k": 65536, "128k": 131072}


def tinytang_port():
    """The TinyTang CDC node, found from sysfs by VID:PID without opening a port."""
    for d in sorted(glob.glob("/sys/bus/usb/devices/*/")):
        try:
            vid = open(d + "idVendor").read().strip()
            pid = open(d + "idProduct").read().strip()
        except OSError:
            continue
        if (vid, pid) != ("ffff", "5454"):
            continue
        for pat in (d + "*/tty/tty*", d + "*/tty*/tty*"):
            for p in glob.glob(pat):
                name = os.path.basename(os.path.realpath(p))
                if os.path.exists("/dev/" + name):
                    return "/dev/" + name
    raise SystemExit("no TinyTang console found (VID:PID ffff:5454)")


def frame(cmd, payload=b""):
    n = 1 + len(payload)
    return bytes([MAGIC, (n >> 8) & 0xFF, n & 0xFF, cmd]) + bytes(payload)


def read_reply(s, deadline_s=1.0):
    buf = b""
    end = time.time() + deadline_s
    while time.time() < end:
        b = s.read(1)
        if not b:
            continue
        if not buf and b[0] != MAGIC:
            continue                      # resynchronise on the frame magic
        buf += b
        if len(buf) >= 4 and len(buf) >= 4 + ((buf[1] << 8) | buf[2]) - 1:
            return buf
    return buf


def dump(size, port=None, retries=3):
    import serial
    s = serial.Serial(port or tinytang_port(), 115200, timeout=0.5, write_timeout=20)
    try:
        s.reset_input_buffer()
        s.write(b"fpgapipe\r")
        s.flush()
        buf = b""
        end = time.time() + 15
        while time.time() < end and b"fpgapipe: open" not in buf:
            buf += s.read(256)
        if b"fpgapipe: open" not in buf:
            raise SystemExit("fpgapipe did not open; is the shell at a prompt?")
        time.sleep(0.3)
        s.read(4096)
        out = bytearray()
        for off in range(0, size, CHUNK):
            addr = BASE + off
            req = bytes([(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF])
            for attempt in range(retries):
                s.write(frame(FRAME_READ, req))
                s.flush()
                r = read_reply(s)
                ok = (len(r) >= 7 + CHUNK and r[3] == FRAME_DATA
                      and r[4:7] == req)
                if ok:
                    out += r[7:7 + CHUNK]
                    break
                s.reset_input_buffer()
            else:
                raise SystemExit(f"no valid reply at offset {off:#x} after {retries} tries "
                                 f"(last: {len(r)} bytes, type {r[3] if len(r) > 3 else None})")
        return bytes(out)
    finally:
        s.close()


def canonical(n):
    return bytes(((i * 31) + 7) & 0xFF for i in range(n))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--size", required=True, choices=sorted(SIZES, key=SIZES.get))
    ap.add_argument("output")
    ap.add_argument("--port")
    ap.add_argument("--check-canonical", action="store_true",
                    help="also report whether the dump equals the sav_pattern.py pattern")
    a = ap.parse_args()
    n = SIZES[a.size]
    t = time.time()
    data = dump(n, a.port)
    Path(a.output).write_bytes(data)
    print(f"{a.output}: {len(data)} bytes in {time.time() - t:.1f}s, "
          f"sha256 {hashlib.sha256(data).hexdigest()}")
    if a.check_canonical:
        diff = sum(1 for x, y in zip(data, canonical(n)) if x != y)
        print(f"differs from canonical pattern in {diff} of {n} bytes")


if __name__ == "__main__":
    main()
