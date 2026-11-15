#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build and run the iosys save-framing test.
#
#   tools/save/run_iosys_tb.sh
#
# Exits 0 when the save read and write frames round-trip correctly through the
# real UART.  Needs iverilog; simulation only, does not touch the Tang.
#
# Why this exists.  The save engine has its own test (tb_save.sv), and the first
# hardware build still failed -- because the bug was in `iosys_bl616`, which
# builds the frames and had no test at all.  This drives the UART pins at the
# real 2 Mbaud with real frames, so a fault in the framing is found here rather
# than after a fifty-minute synthesis and a card swap.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
sim="${IVERILOG:-iverilog}"
command -v "$sim" >/dev/null || { echo "missing iverilog" >&2; exit 2; }

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

set -uo pipefail
rc=0
srcs="tools/save/tb_iosys.sv fpga/gba/src/iosys/uart_fixed.v"

"$sim" -g2012 -o "$out/tb_iosys" $srcs fpga/gba/src/iosys/iosys_bl616.v \
    || { echo "elaboration failed" >&2; exit 2; }

# `$finish` always leaves a zero exit status, so the verdict is read from the
# transcript.  A run that timed out prints neither verdict.
echo "--- iosys save read framing (as shipped) ---"
timeout 900 "$out/tb_iosys" >"$out/good.log" 2>&1 || rc=1
tail -2 "$out/good.log"
grep -q "RESULT: PASS" "$out/good.log" || { echo "FAIL: the save read frame is wrong"; rc=1; }

# The regression that matters.  `save_d_ready` was once gated on "not sending
# data", which is high through SEND_HEADER: it consumed the engine's bytes and
# discarded them before SEND_SAVE_DATA ran, and the board reported "the core
# stopped answering at offset 0".  This rebuilds that exact line and requires the
# test to reject it -- otherwise the pass above proves nothing about the fault.
echo "--- regression check (the shipped-broken save_d_ready; must NOT pass) ---"
sed "s|save_d_ready <= (send_state == SEND_IDLE) \&\& !save_tx_pending \&\&|save_d_ready <= (send_state != SEND_SAVE_DATA) \&\& 1'b1 \&\&|" \
    fpga/gba/src/iosys/iosys_bl616.v > "$out/iosys_broken.v"
if cmp -s fpga/gba/src/iosys/iosys_bl616.v "$out/iosys_broken.v"; then
    echo "FAIL: could not reproduce the broken line; the regression check is not"
    echo "      running, so the pass above proves nothing."
    rc=1
else
    "$sim" -g2012 -o "$out/tb_broken" $srcs "$out/iosys_broken.v" \
        || { echo "elaboration failed for the regression copy" >&2; exit 2; }
    timeout 900 "$out/tb_broken" >"$out/broken.log" 2>&1 || true
    if grep -q "RESULT: PASS" "$out/broken.log"; then
        echo "FAIL: the broken save_d_ready passed; the test has lost the"
        echo "      ability to see the fault it exists to catch."
        rc=1
    else
        echo "  correctly rejected: the read frame never arrives"
    fi
fi

exit $rc
