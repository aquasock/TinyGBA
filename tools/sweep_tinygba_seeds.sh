#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Place and route one synthetic netlist across a range of placement seeds and
# report, per seed, whether the placement is free of hold violations.
#
#   tools/sweep_tinygba_seeds.sh [first] [last]     (default 1 10)
#
# The hold check is the point: on this device and toolchain the placer is
# seed-sensitive, and a hold violation in the design's own clock domain corrupts
# any hardware measurement taken from it, exactly as TinySNES recorded.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
first="${1:-1}"; last="${2:-10}"
suite="${OSS_CAD_SUITE:-$HOME/oss-cad-suite}"
apycula="${APICULA_FORK:-$(dirname "$root")/apicula-mathieufro}"
pydeps="${PYDEPS:-$HOME/tools/pydeps}"
# nextpnr-himbaechel is a Python-linked binary: without the suite's environment it
# aborts with "failed to get the Python codec of the filesystem encoding".  These
# three lines mirror tools/build_tinygba.sh exactly.
export LC_ALL=C
# shellcheck disable=SC1090
source "$suite/environment"
export PYTHONHOME="$suite"
export PYTHONPATH="$apycula:$pydeps:${PYTHONPATH:-}"
nextpnr="${NEXTPNR_HIMBAECHEL:-$HOME/tools/nextpnr-mathieufro/nextpnr-himbaechel}"
json="${TINYGBA_SWEEP_JSON:-$root/build/tinygba/tinygba.json}"
outdir="${TINYGBA_SWEEP_DIR:-$root/build}"
src="$root/fpga/gba"
[[ -f "$json" ]] || { echo "missing netlist: $json" >&2; exit 2; }

for seed in $(seq "$first" "$last"); do
    out="$outdir/sweep_$seed"
    mkdir -p "$out"
    (
        "$nextpnr" --json "$json" --write "$out/routed.json" \
            --device GW5AST-LV138PG484AC1/I0 --freq 67 \
            --vopt cst="$src/tinygba.cst" --sdc "$src/tinygba.sdc" \
            --report "$out/timing.json" --seed "$seed" \
            >"$out/nextpnr.log" 2>&1
        echo "$seed $?" > "$out/status"
    ) &
done
wait
printf '%-6s %-6s %s\n' seed exit hold
for seed in $(seq "$first" "$last"); do
    out="$outdir/sweep_$seed"
    code=$(cut -d' ' -f2 "$out/status" 2>/dev/null || echo '?')
    hold=$(grep -oE '[0-9]+ Hold/min time violations' "$out/nextpnr.log" 2>/dev/null | head -1 | cut -d' ' -f1)
    printf '%-6s %-6s %s\n' "$seed" "$code" "${hold:-0}"
done
