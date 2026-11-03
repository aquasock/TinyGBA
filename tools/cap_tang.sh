#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Flash a built bitstream and capture what the board draws, with the capture tied
# to the field map that bitstream was built from.
#
#   tools/cap_tang.sh <build-dir> [output-prefix]
#
#   tools/cap_tang.sh build/tang_status2 /tmp/probe
#
# Why this is a script and not two commands someone remembers.  Two separate
# traps have already produced wrong readings in this project:
#
#   1. The capture card returns solid black at 1280x720 whatever the board is
#      driving.  Asking ffmpeg for a frame with no format pinned picks that mode,
#      silently, and the result is indistinguishable from a machine that draws
#      nothing.  (BRD-012.)  The format is therefore pinned here.
#
#   2. A capture decoded against a field map other than the one it was built from
#      yields plausible field names attached to the wrong bits -- which happened
#      when two probe fields were added and every bar above bit 1 moved.  The
#      build records its map id in `$out/probe-map.id`; this script copies that
#      into `<prefix>.png.map`, and `tools/probe_map.py --decode` refuses a
#      capture whose sidecar disagrees.
#
# A reading must state the negotiated size and the colour histogram beside the
# picture, so both are printed.  Nothing here decides anything: it produces an
# artefact that can be decoded without ambiguity.
set -uo pipefail
export LC_ALL=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build="${1:-}"
prefix="${2:-/tmp/capture}"
device=/dev/video0
loader="${OPENFPGALOADER:-$HOME/oss-cad-suite/bin/openFPGALoader}"

[[ -n "$build" ]] || { echo "usage: tools/cap_tang.sh <build-dir> [output-prefix]" >&2; exit 2; }
[[ -f "$build/tinygba.fs" ]] || { echo "no $build/tinygba.fs" >&2; exit 2; }
[[ -x "$loader" ]] || { echo "missing openFPGALoader: $loader" >&2; exit 2; }

if fuser "$device" >/dev/null 2>&1; then
    echo "capture: $device is in use ($(fuser "$device" 2>/dev/null | tr -s ' '))" >&2
    echo "capture: close whatever holds it, then re-run" >&2
    exit 3
fi

echo "=== flash ==="
"$loader" -b tangconsole "$build/tinygba.fs" 2>&1 | tail -2
sleep 5

echo "=== capture ==="
# MJPEG at 1920x1080, pinned.  See trap 1 above.
timeout 60 ffmpeg -hide_banner -loglevel error \
    -f v4l2 -input_format mjpeg -video_size 1920x1080 -i "$device" \
    -t 3 -y "${prefix}.mp4" 2>/dev/null || { echo "capture failed" >&2; exit 1; }
# Last frame of the clip: the first is often mid-resync after a load.
ffmpeg -hide_banner -loglevel error -sseof -0.2 -i "${prefix}.mp4" \
    -frames:v 1 -y "${prefix}.png" 2>/dev/null || { echo "extract failed" >&2; exit 1; }

# Tie the capture to the map the bitstream was built from.
if [[ -f "$build/probe-map.id" ]]; then
    cp "$build/probe-map.id" "${prefix}.png.map"
    echo "capture: map id $(cat "${prefix}.png.map") (from $build)"
else
    rm -f "${prefix}.png.map"
    echo "capture: WARNING -- $build/probe-map.id missing, so this capture carries" >&2
    echo "capture:   no map id and --decode will mark it UNVERIFIED" >&2
fi

/usr/bin/python3 - "$prefix" <<'PY'
import sys
from PIL import Image
p = sys.argv[1]
im = Image.open(p + ".png").convert("RGB")
w, h = im.size
px = im.load()
cols = im.getcolors(maxcolors=1 << 24) or []
cols.sort(reverse=True)
row = h // 2
runs, prev = [], None
for x in range(w):
    c = px[x, row]
    if c != prev:
        runs.append((x, c)); prev = c
print(f"capture: {w}x{h}  unique colours={len(cols)}")
print("capture: top colours:", cols[:4])
print("capture: midrow runs:", runs[:8])
PY

echo "capture: decode with  tools/probe_map.py --decode ${prefix}.png"
