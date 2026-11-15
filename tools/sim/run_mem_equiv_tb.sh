#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Does this project's restatement of the EEPROM memory match the Gowin wrapper
# it replaces, cycle for cycle?
#
#   tools/sim/run_mem_equiv_tb.sh
#
# Exits 0 only when the two wrappers agree AND the deliberately broken variants
# do not.  Needs iverilog; simulation only, never touches the Tang.
#
# Why this exists.  `mem_eeprom.v` is Gowin IP-generator output; this project
# would rather carry its own RTL (TCL-065) and now does, as `eeprom_ram.v`.  A
# cell census cannot check that substitution, because the same tree moves by
# hundreds of LUTs between builds with no source change (TCL-068).  Comparing
# the wrappers under one shared model of the primitive can, which is what this
# does.
#
# The second and third runs are the point of the script.  A testbench that only
# ever prints PASS proves nothing, so two deliberate defects are injected into
# copies of the wrapper and the run must reject each of them:
#
#   * the bank-select register gated by `cea` alone rather than `cea & ~wrea`,
#     which lets a write redirect the output mux at the bytes being written;
#   * the output mux chosen by the live address rather than by the registered
#     one, which is the classic one-cycle read-latency error.
#
# If either injected defect ever passes, the model has lost the ability to see
# that class of fault and the first run stops being evidence of anything.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
sim="${IVERILOG:-iverilog}"
run="${VVP:-vvp}"
command -v "$sim" >/dev/null || { echo "missing iverilog" >&2; exit 2; }
command -v "$run" >/dev/null || { echo "missing vvp" >&2; exit 2; }

lib="tools/sim/gowin_bram_sim.v"
tb="tools/sim/tb_eeprom_equiv.sv"
orig="fpga/gba/src/memory/mem_eeprom.v"
new="fpga/gba/src/memory/eeprom_ram.v"
rc=0
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# 1. The shipped wiring must pass.
echo "--- equivalence (mem_eeprom vs eeprom_ram, as shipped) ---"
if ! "$sim" -g2012 -o "$out/pass" -s tb_eeprom_equiv "$tb" "$lib" "$orig" "$new"; then
    echo "elaboration failed" >&2; exit 2
fi
timeout 600 "$run" "$out/pass" > "$out/pass.log" 2>&1
tail -3 "$out/pass.log"
grep -q "RESULT: PASS" "$out/pass.log" || { echo "FAIL: the wrappers disagree"; rc=1; }

# --- injected defects; each MUST be rejected ---------------------------------
inject() {   # inject <name> <sed-expr> <module-rename>
    local name="$1" expr="$2"
    local src="$out/$name.v" tbn="$out/tb_$name.sv"
    sed "$expr" "$new" | sed "s/module eeprom_ram/module eeprom_bug/" > "$src"
    sed "s/eeprom_ram new_m/eeprom_bug new_m/" "$tb" \
        | sed "s/module tb_eeprom_equiv/module tb_bug/" > "$tbn"
    if ! "$sim" -g2012 -o "$out/$name" -s tb_bug "$tbn" "$lib" "$orig" "$src"; then
        echo "  $name: elaboration failed" >&2; return 1
    fi
    timeout 600 "$run" "$out/$name" > "$out/$name.log" 2>&1
    if grep -q "RESULT: PASS" "$out/$name.log"; then
        echo "FAIL: the injected defect '$name' PASSED, so the model cannot see it"
        return 1
    fi
    echo "  correctly rejected: $name ($(grep -o 'RESULT: FAIL - [0-9]* mismatches' "$out/$name.log"))"
    return 0
}

echo "--- injected defects (each must NOT pass) ---"
inject "bank-select-not-gated-on-write" \
    's/if (cea & ~wrea) bank_a <= ada\[15:14\];/if (cea) bank_a <= ada[15:14];/' || rc=1
inject "output-mux-not-registered" \
    's/assign douta = doa_blk\[bank_a\]\[0\];/assign douta = doa_blk[ada[15:14]][0];/' || rc=1

exit $rc
