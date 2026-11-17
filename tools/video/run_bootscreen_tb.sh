#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build and run the boot-screen bench: tools/video/bootscreen_tb.sv.
#
#   tools/video/run_bootscreen_tb.sh [build-dir]
#
# Answers, without the board: does gba2hdmi draw TinySNES's eight colour bars
# until a cartridge is running, stop drawing them once one is, bring them back
# for a reload, and draw black rather than grey either side of the picture?
#
# Only gba2hdmi, its frame-buffer RAM (with the DPX9B model from
# tools/sim/gowin_bram_sim.v), the desk layer and an HDMI stub are compiled, so
# the build takes seconds.  Needs Verilator 5 (--timing).
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/fpga/gba/src"
out="${1:-$root/build/bootscreen_sim}"

command -v verilator >/dev/null || { echo "missing verilator" >&2; exit 2; }
mkdir -p "$out"
cd "$out"

echo "=== building boot-screen bench ==="
verilator --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-UNUSED -Wno-UNDRIVEN \
    -DTINYSNES_DESK_FONT="\"$src/desk_font.hex\"" \
    -I"$src" \
    --top-module bootscreen_tb \
    --Mdir obj_dir \
    -o bootscreen_sim \
    "$root/tools/video/hdmi_stub.sv" \
    "$root/tools/sim/gowin_bram_sim.v" \
    "$src/fb_ram.v" \
    "$src/desk_layer.v" \
    "$src/gba2hdmi.sv" \
    "$root/tools/video/bootscreen_tb.sv" > build.log 2>&1 \
    || { tail -30 build.log >&2; echo "elaboration failed" >&2; exit 2; }

echo "=== running ==="
./obj_dir/bootscreen_sim | tee run.log
grep -q '^PASS' run.log
