#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Report which loading mode the TinyTang is in, and which commands can reach it.

Why this exists.  This project spent a cycle bouncing between one-wire and
two-wire because the mode was inferred from `lsusb` or from memory rather than
asked.  Each mode change erases the FPGA, so every wrong inference costs a
reflash and a reload, and a mode that is *believed* rather than checked produces
exactly that churn.  The board itself is the only authority.

Two independent tests, both cheap:

  * `lsusb` name.  Two-wire presents as the TinyTang CDC device; one-wire
    presents the FT2232 as the vendor debugger.  This is a hint, not proof:
    it has disagreed with a working controller, so it never decides on its own.
  * A console probe.  Writing to the TinyTang console only answers in two-wire
    mode, so a shell prompt on a candidate port is direct evidence that
    `tangload` and `fpgapipe` are available.

Exit status: 0 two-wire (TinyTang shell found), 1 one-wire (FT2232 only),
2 neither.

    tools/board_mode.py                 # report
    tools/board_mode.py --port          # print just the console port
"""
import argparse
import glob
import subprocess
import sys

CANDIDATE_PORTS = sorted(glob.glob("/dev/ttyACM*"))


def lsusb_names():
    try:
        out = subprocess.run(["lsusb"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [l.strip() for l in out.splitlines()
            if "tiny" in l.lower() or "0403:6010" in l or "5454" in l]


def probe(port, timeout=6.0):
    """True when the TinyTang shell answers on `port`."""
    try:
        import serial
    except ImportError:
        return False
    try:
        p = serial.Serial(port, 115200, timeout=1, write_timeout=2)
    except Exception:
        return False
    try:
        p.reset_input_buffer()
        p.write(b"\n")
        import time
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            c = p.read(4096)
            if c:
                buf += c
                # tdsh's prompt, or any evidence of the shell
                if b"tinytang" in buf.lower() or b"#" in buf:
                    return True
        return False
    except Exception:
        return False
    finally:
        try:
            p.close()
        except Exception:
            pass


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", action="store_true", help="print only the console port")
    args = ap.parse_args(argv)

    shell_port = None
    for cand in CANDIDATE_PORTS:
        if probe(cand):
            shell_port = cand
            break

    if args.port:
        if shell_port:
            print(shell_port)
            return 0
        return 1

    names = lsusb_names()
    print("usb devices seen:")
    for n in names or ["  (none matching TinyTang or the FT2232)"]:
        print("  " + n)
    print()
    if shell_port:
        print(f"mode: TWO-WIRE   (TinyTang shell answers on {shell_port})")
        print("  tangload / fpgapipe available; the FPGA is configured by tangload,")
        print("  which is the only path a controller works on (TCL-054).")
        return 0
    print("mode: ONE-WIRE   (no TinyTang shell answered)")
    print("  openFPGALoader -b tangconsole <file>.fs configures the FPGA and")
    print("  tools/load_gba_rom.py --uart /dev/ttyUSB1 streams the cartridge.")
    print("  A controller does not respond in this mode; if one must work, the")
    print("  board has to be rebooted into two-wire.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
