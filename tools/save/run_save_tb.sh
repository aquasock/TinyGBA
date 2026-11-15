#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build and run the save-persistence engine test.
#
#   tools/save/run_save_tb.sh
#
# Exits 0 when every byte matches the memory model.  Needs iverilog; it is a
# simulation-only check and does not touch the Tang.
#
# Why this exists.  A save dump is one byte stream across two clock domains
# through a FIFO, over a bus handshake written by someone else, into a memory
# window whose bank bit is address bit 16.  Any of those four can be wrong in a
# way that looks like "the save is empty" on the board, and the board cycle is a
# fifty-minute synthesis plus a flash.  So the engine and the adapter it drives
# are checked against a model of the controller before either is built.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
sim="${IVERILOG:-iverilog}"
command -v "$sim" >/dev/null || { echo "missing iverilog" >&2; exit 2; }

rc=0
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

srcs="tools/save/tb_save.sv fpga/gba/src/memory/gba_save.v fpga/gba/src/memory/rv_sdram_adapter.v"

# 1. The shipped wiring: the save adapter and engine both run on clk16, because
#    the RV interface they drive is mclk-timed and the EEPROM behind it is
#    physically a clk16 memory.  This must pass.
"$sim" -g2012 -o "$out/tb_save" $srcs || { echo "elaboration failed" >&2; exit 2; }
# `$finish` always leaves a zero exit status, so the verdict is read from the
# transcript rather than from the shell.  A run that timed out prints neither.
echo "--- save engine (adapter on clk16, as wired) ---"
if timeout 600 "$out/tb_save" >"$out/run16.log" 2>&1; then :; else rc=1; fi
tail -3 "$out/run16.log"
grep -q "RESULT: PASS" "$out/run16.log" || { echo "FAIL: clk16 wiring did not pass"; rc=1; }

# 2. The wiring that shipped first and failed on the board.  This MUST fail; if
#    it ever passes, the model has lost the ability to see the fault and the
#    first run above stops being evidence of anything.
"$sim" -g2012 -o "$out/tb_save_67" -Ptb_save.ADAPTER_CLK67=1 $srcs \
    || { echo "elaboration failed for the clk67 run" >&2; exit 2; }
echo "--- regression check (adapter on clk67; must NOT pass) ---"
timeout 600 "$out/tb_save_67" >"$out/run67.log" 2>&1 || true
if grep -q "RESULT: PASS" "$out/run67.log"; then
    echo "FAIL: the clk67 wiring passed. The model no longer reproduces the"
    echo "      hardware fault it exists to catch, so the run above proves nothing."
    rc=1
else
    echo "  correctly rejected: the clk67 wiring shifts the dump by two bytes"
fi

exit $rc
