#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build and run the blank-save-store bench: tools/save/tb_fill.sv.
#
#   tools/save/run_fill_tb.sh [build-dir]
#
# Checks, without the board, that a cartridge loaded with no `.sav` gets an
# all-ones save store (both 64 KB banks) before the machine is released, that a
# restored save is never overwritten, that a reload abandons a fill, and that
# the EEPROM's all-ones walk restarts on every ROM load (BRD-123).
#
# The real gba_memory is compiled under Verilator, so IWRAM is the behavioural
# `sim_spram_be` and the EEPROM's block RAM comes from tools/sim/gowin_bram_sim.v.
# The BIOS image is irrelevant here; a zero image is generated so the mandatory
# TINYGBA_BIOS_HEX is satisfied without the retail file.  Needs Verilator 5.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/fpga/gba/src"
out="${1:-$root/build/fill_sim}"

command -v verilator >/dev/null || { echo "missing verilator" >&2; exit 2; }
mkdir -p "$out"
cd "$out"
python3 -c "print('\n'.join(['00000000']*4096))" > zero_bios.hex

echo "=== building blank-store bench ==="
verilator --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-UNUSED -Wno-UNDRIVEN \
    -Wno-PINMISSING -Wno-MULTIDRIVEN \
    -DTINYGBA_BIOS_HEX="\"$out/zero_bios.hex\"" \
    -I"$src" -I"$src/common" -I"$src/memory" \
    --top-module tb_fill \
    --Mdir obj_dir \
    -o fill_sim \
    "$root/tools/sim/gowin_bram_sim.v" \
    "$src/common/sim_spram_be.sv" \
    "$src/memory/eeprom_ram.v" \
    "$src/memory/gba_eeprom.sv" \
    "$src/memory/gba_memory.sv" \
    "$root/tools/save/tb_fill.sv" > build.log 2>&1 \
    || { tail -40 build.log >&2; echo "elaboration failed" >&2; exit 2; }

echo "=== running ==="
./obj_dir/fill_sim | tee run.log
grep -q '^PASS' run.log
