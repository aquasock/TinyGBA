#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Produce the SD-card pair for a TinyGBA build: `<name>.bin` and `<name>.fs.gz`.

Why this exists.  `.ai/core.md` requires that a generated artifact the operator
is meant to use comes from a committed deterministic script rather than from
commands typed into a shell.  The card's cores are one such artifact, and until
now producing the TinyGBA pair meant copying a `.bin` and running `gzip -9` by
hand -- two steps with no record of the options used, and `gzip -9` is not
reproducible across zlib versions anyway, so "same inputs, same bytes" was an
assumption rather than a property.

What the two files are for, from TinyTang's side:

* `<name>.bin` is what `tangload` writes to the FPGA.  `tools/fs_to_bin.py`
  already packs it during a normal build, so this script only checks that one is
  present and non-empty rather than repacking it -- one converter, one place to
  be wrong.
* `<name>.fs.gz` is the same bitstream kept compressed on the card for the
  desktop's core picker.  It is gzipped here with `mtime=0`, which is what makes
  the output stable: without it gzip stamps the current time into the header and
  every run differs even when the bitstream does not.

Usage:

    tools/ship_core.py build/snd_prod                  # -> build/snd_prod/ship/
    tools/ship_core.py build/snd_prod --name tinygba   # the card's file name
    tools/ship_core.py build/snd_prod --out DIR

The default name is `tinygba`, which is what the card expects in
`/root/cores/console138k/`.  Print the two hashes afterwards and record them:
a card whose contents are not identified by hash cannot be told from one built
from a different tree.
"""
import argparse
import gzip
import hashlib
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("build_dir", help="a directory holding tinygba.fs and tinygba.bin")
    ap.add_argument("--name", default="tinygba", help="card file name stem")
    ap.add_argument("--out", default=None, help="output directory (default <build_dir>/ship)")
    args = ap.parse_args()

    fs = os.path.join(args.build_dir, "tinygba.fs")
    binf = os.path.join(args.build_dir, "tinygba.bin")
    for p, what in ((fs, ".fs"), (binf, ".bin")):
        if not os.path.isfile(p):
            sys.exit(f"missing {p}: build with tools/build_tinygba.sh first, "
                     f"which writes both the {what} and the .bin")

    if os.path.getsize(binf) == 0:
        sys.exit(f"{binf} is empty; the pack step did not finish")

    out = args.out or os.path.join(args.build_dir, "ship")
    os.makedirs(out, exist_ok=True)

    dst_bin = os.path.join(out, args.name + ".bin")
    if os.path.abspath(binf) != os.path.abspath(dst_bin):
        shutil.copyfile(binf, dst_bin)

    dst_gz = os.path.join(out, args.name + ".fs.gz")
    # mtime=0 keeps the gzip header free of the wall clock; without it two runs
    # over the same bitstream produce different bytes and the hash is useless as
    # an identifier.
    with open(fs, "rb") as src, open(dst_gz, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw,
                           compresslevel=9, mtime=0) as gz:
            shutil.copyfileobj(src, gz, 1 << 20)

    for p in (dst_bin, dst_gz):
        print(f"{sha256(p)}  {os.path.getsize(p):>9,}  {p}")
    print()
    print("card layout:")
    print(f"  /root/cores/console138k/{args.name}.bin")
    print(f"  /root/cores/console138k/{args.name}.fs.gz")
    print("write both with TinyTang's tools/tinytang_put.py, and load the .bin")
    print("with `tangload` -- a direct openFPGALoader flash configures no sockets")
    print("(TCL-054), so a controller cannot work on an image loaded that way.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
