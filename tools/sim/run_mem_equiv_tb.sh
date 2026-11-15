#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Do this project's restatements of the Gowin memory wrappers compute the same
# thing as the wrappers they replace, cycle for cycle?
#
#   tools/sim/run_mem_equiv_tb.sh [eeprom|iwram|fb|vram_hi|vram_lo|all]
#
# Exits 0 only when the shipped pair agrees AND every deliberately broken
# variant is rejected.  Needs iverilog; simulation only, never touches the Tang.
#
# Why this exists.  The wrappers in `fpga/gba/src/memory/` were Gowin
# IP-generator output; this project would rather carry its own RTL (TCL-065) and
# now does.  A cell census cannot check that substitution, because the same tree
# moves by hundreds of LUTs between builds with no source change (TCL-068).
# Comparing the wrappers under one shared model of the primitive can, which is
# what this does; the model is `tools/sim/gowin_bram_sim.v` and it is this
# project's approximation of the GW5A block RAM, not a model of silicon.
#
# The injected defects are the point.  A testbench that only ever prints PASS
# proves nothing, so each memory carries deliberate faults that the run must
# reject -- the ones a census is blind to and a restatement is most likely to
# get wrong.  If any injected defect ever passes, the model has lost the ability
# to see that class of fault and the passing run above stops being evidence.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
sim="${IVERILOG:-iverilog}"
run="${VVP:-vvp}"
command -v "$sim" >/dev/null || { echo "missing iverilog" >&2; exit 2; }
command -v "$run" >/dev/null || { echo "missing vvp" >&2; exit 2; }

lib="tools/sim/gowin_bram_sim.v"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
rc=0

# one_mem <name> <old.v> <new.v> <tb.sv> <top> <defect-label:sed-expr>...
one_mem() {
    local name="$1" old="$2" new="$3" tb="$4" top="$5"; shift 5
    echo "--- $name: equivalence, as shipped ---"
    if ! "$sim" -g2012 -o "$out/$name" -s "$top" "$tb" "$lib" "$old" "$new"; then
        echo "elaboration failed for $name" >&2; rc=1; return
    fi
    timeout 900 "$run" "$out/$name" > "$out/$name.log" 2>&1
    tail -2 "$out/$name.log"
    if ! grep -q "RESULT: PASS" "$out/$name.log"; then
        echo "FAIL: the $name wrappers disagree"; rc=1; return
    fi

    echo "--- $name: injected defects (each must NOT pass) ---"
    local spec label expr
    for spec in "$@"; do
        label="${spec%%:*}"; expr="${spec#*:}"
        sed "$expr" "$new" | sed "s/module ${name}_ram/module ${name}_bug/" \
            > "$out/bug_$label.v"
        sed "s/${name}_ram new_m/${name}_bug new_m/" "$tb" \
            | sed "s/module ${top}/module tb_bug/" > "$out/tb_$label.sv"
        if ! "$sim" -g2012 -o "$out/bug_$label" -s tb_bug "$out/tb_$label.sv" \
                "$lib" "$old" "$out/bug_$label.v"; then
            echo "  $label: elaboration failed" >&2; rc=1; continue
        fi
        timeout 900 "$run" "$out/bug_$label" > "$out/bug_$label.log" 2>&1
        if grep -q "RESULT: PASS" "$out/bug_$label.log"; then
            echo "FAIL: injected defect '$label' PASSED -- the model cannot see it"
            rc=1
        else
            echo "  correctly rejected: $label ($(grep -oE 'RESULT: FAIL - [0-9]+ mismatches' "$out/bug_$label.log"))"
        fi
    done
}

which="${1:-all}"

# A converted wrapper's original is deleted from the tree, because the point of
# the work is that the file stops being carried (TCL-065).
# Fetch a deleted original out of git so the comparison stays live rather than
# historical.  A converted wrapper's original is removed from the tree (the
# point of the work), so after a few conversions this script would otherwise
# report every memory as historical and test nothing at all.
original_from_git() {   # original_from_git <path> <dest>; 0 on success
    local path="$1" dest="$2" del
    del=$(git -C "$root" log -1 --diff-filter=D --format=%H -- "$path" 2>/dev/null)
    [[ -n "$del" ]] || return 1
    git -C "$root" show "${del}^:${path}" > "$dest" 2>/dev/null || return 1
    [[ -s "$dest" ]]
}

needs_original() {   # needs_original <label> <old.v> <new.v> <tb> <top> <defects...>
    local label="$1" oldf="$2"; shift 2
    if [[ -f "$oldf" ]]; then
        one_mem "$label" "$oldf" "$@"
        return
    fi
    if original_from_git "$oldf" "$out/$(basename "$oldf")"; then
        echo "--- $label: original recovered from git history ---"
        one_mem "$label" "$out/$(basename "$oldf")" "$@"
        return
    fi
    echo "--- $label: original not in the tree and not recoverable from git ---"
    echo "    the comparison cannot be re-run; see the record for that memory."
}

if [[ "$which" == eeprom || "$which" == all ]]; then
    needs_original eeprom fpga/gba/src/memory/mem_eeprom.v fpga/gba/src/memory/eeprom_ram.v \
        tools/sim/tb_eeprom_equiv.sv tb_eeprom_equiv \
        "bank-select-not-gated-on-write:s/if (cea \& ~wrea) bank_a <= ada\[15:14\];/if (cea) bank_a <= ada[15:14];/" \
        "output-mux-not-registered:s/assign douta = doa_blk\[bank_a\]\[0\];/assign douta = doa_blk[ada[15:14]][0];/"
    echo
fi

if [[ "$which" == iwram || "$which" == all ]]; then
    needs_original iwram fpga/gba/src/memory/mem_iwram.v fpga/gba/src/memory/iwram_ram.v \
        tools/sim/tb_iwram_equiv.sv tb_iwram_equiv \
        "bank-select-not-gated-on-write:s/if (ce \& ~wre) bank <= blksel;/if (ce) bank <= blksel;/" \
        "halfwords-transposed:s/assign dout = {do_hi\[bank\]\[15:0\], do_lo\[bank\]\[15:0\]};/assign dout = {do_lo[bank][15:0], do_hi[bank][15:0]};/" \
        "high-half-strobe-wrong-bits:s/2.b00, byte_en\[3:2\]/2'b00, byte_en[1:0]/"
    echo
fi

if [[ "$which" == fb || "$which" == all ]]; then
    needs_original fb fpga/gba/src/fb.v fpga/gba/src/fb_ram.v \
        tools/sim/tb_fb_equiv.sv tb_fb_equiv \
        "bank-select-not-gated-on-write:s/if (cea \& ~wrea) bank_a_q <= bank_a;/if (cea) bank_a_q <= bank_a;/" \
        "halves-transposed:s/assign douta = {doa_hi\[bank_a_q\]\[8:0\], doa_lo\[bank_a_q\]\[8:0\]};/assign douta = {doa_lo[bank_a_q][8:0], doa_hi[bank_a_q][8:0]};/" \
        "only-eight-banks-distinguishable:s/wire \[4:0\] bank_a = ada\[15:11\];/wire [4:0] bank_a = {2\x27b00, ada[13:11]};/"
    echo
fi

if [[ "$which" == vram_hi || "$which" == all ]]; then
    needs_original vram_hi fpga/gba/src/gpu/vram_hi.v fpga/gba/src/gpu/vram_hi_ram.v \
        tools/sim/tb_vram_hi_equiv.sv tb_vram_hi_equiv \
        "bank-select-not-gated-on-write:s/if (cea \& ~wrea) bank_a_q <= bank_a;/if (cea) bank_a_q <= bank_a;/" \
        "halves-transposed:s/assign douta = {doa_hi\[bank_a_q\], doa_lo\[bank_a_q\]};/assign douta = {doa_lo[bank_a_q], doa_hi[bank_a_q]};/" \
        "high-half-strobe-from-low:s/{ada\[9:0\], 2.b00, byte_ena\[3:2\]}/{ada[9:0], 2\x27b00, byte_ena[1:0]}/"
    echo
fi

if [[ "$which" == vram_lo || "$which" == all ]]; then
    needs_original vram_lo fpga/gba/src/gpu/vram_lo.v fpga/gba/src/gpu/vram_lo_ram.v \
        tools/sim/tb_vram_lo_equiv.sv tb_vram_lo_equiv \
        "bank-select-not-gated-on-write:s/if (cea \& ~wrea) bank_a_q <= bank_a;/if (cea) bank_a_q <= bank_a;/" \
        "halves-transposed:s/assign douta = {doa_hi\[bank_a_q\], doa_lo\[bank_a_q\]};/assign douta = {doa_lo[bank_a_q], doa_hi[bank_a_q]};/" \
        "only-eight-banks-aliased:s/wire \[3:0\] bank_a = ada\[13:10\];/wire [3:0] bank_a = {1\x27b0, ada[12:10]};/"
    echo
fi

if [[ $rc -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit $rc
