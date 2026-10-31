#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Run the TinyGBA diagnostic testbenches under iverilog and fail on anything but
# a PASS line.
#
#   tools/run_diag_sim.sh [tb-name ...]      (default: all)
#
# Every testbench prints one `RESULT: PASS|FAIL ...` line and the script reads it.
# A testbench that cannot distinguish the fault it exists to catch is therefore
# a failure here, not a green tick: tb_sdram_probe is required to report opposite
# verdicts against a two-die model and a one-die model.
set -euo pipefail
export LC_ALL=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/sim"
mkdir -p "$out"

run() {  # run <name> <expected-substring> <iverilog-args...>
    local name=$1 expect=$2; shift 2
    local log="$out/$name.log"
    if ! iverilog -g2012 -o "$out/$name.vvp" "$@" >"$log" 2>&1; then
        echo "FAIL $name: build errors, see $log" >&2
        tail -20 "$log" >&2
        return 1
    fi
    if ! vvp "$out/$name.vvp" >>"$log" 2>&1; then
        echo "FAIL $name: simulation errors, see $log" >&2
        return 1
    fi
    local line
    line=$(grep -m1 '^RESULT: ' "$log" || true)
    if [[ "$line" != *"RESULT: $expect"* ]]; then
        echo "FAIL $name: got '$line', wanted 'RESULT: $expect ...'" >&2
        return 1
    fi
    echo "PASS $name: $line"
}

fail=0
for tb in "$@"; do :; done
[[ $# -eq 0 ]] && set -- sdram_probe

for name in "$@"; do
    case "$name" in
    sdram_probe)
        run sdram_probe_two_die PASS \
            "$root/fpga/gba/diag/tb_sdram_probe.sv" \
            "$root/fpga/gba/diag/sdram_probe.v" \
            "$root/fpga/gba/src/memory/sdram_sim.v" || fail=1
        # Same testbench, single-die model: the probe must now report a fault.
        run sdram_probe_one_die PASS \
            -DALIAS \
            "$root/fpga/gba/diag/tb_sdram_probe.sv" \
            "$root/fpga/gba/diag/sdram_probe.v" \
            "$root/fpga/gba/src/memory/sdram_sim.v" || fail=1
        ;;
    *)
        echo "unknown testbench: $name" >&2; fail=1 ;;
    esac
done

exit "$fail"
