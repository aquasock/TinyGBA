#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build and run the Wii Classic Controller integration test.
#
#   tools/pad/run_pad_tb.sh
#
# Exits 0 when both the genuine-Classic and the 8BitDo-Receiver paths pass.
# Needs iverilog; it is a simulation-only check and does not touch the Tang.
#
# Why this exists.  The pad path is four parts -- a vendored I2C master, the
# open-drain wiring, a clk16 synchroniser and a button mapping -- and only the
# first is upstream's.  A mapping error would show on the board as the wrong
# button moving, which is easy to misread as a wiring fault, so the mapping and
# the wiring are checked here first, and a future edit to the mapping cannot
# silently break a button.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
sim="${IVERILOG:-iverilog}"
command -v "$sim" >/dev/null || { echo "missing iverilog" >&2; exit 2; }

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

rc=0
for mode in classic receiver; do
    recv=0
    [[ "$mode" == receiver ]] && recv=1
    "$sim" -g2012 -o "$out/tb_$mode" -Ptb_pad.RECEIVER="$recv" \
        tools/pad/tb_pad.sv tools/pad/wii_classic_model.sv \
        fpga/gba/src/peripherals/wii_pad_master.sv \
        || { echo "elaboration failed for $mode" >&2; exit 2; }
    echo "--- $mode ---"
    timeout 300 "$out/tb_$mode" || rc=1
done
exit $rc
