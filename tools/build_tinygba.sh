#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the TinyGBA core with the open flow: yosys with the slang front end, the
# nextpnr-himbaechel fork against the GW5AST-138C database, and the apicula
# fork's gowin_pack.  No Gowin EDA is involved.
#
#   tools/build_tinygba.sh [out-dir]
#
#   TINYGBA_STAGE     synth | pnr | pack | all (default all)
#   TINYGBA_BUILD_DIR output directory (default build/tinygba)
#   TINYGBA_SEED      placement seed (default 1; not proven on hardware)
#   TINYGBA_DEFINES   extra preprocessor defines for a diagnostic build
#   TINYGBA_ALLOW_HOLD 1 passes --timing-allow-fail to nextpnr; the Fmax gate
#                     still runs.  Off by default: nothing about this port is
#                     hardware-proven yet, so an unclean placement should stop
#                     the build rather than ship.
#   NEXTPNR_HIMBAECHEL, APICULA_FORK, OSS_CAD_SUITE, PYDEPS  see TinyNES/TinyTang
#
# Layout follows TinySNES: fpga/gba/ holds every source, no upstream checkout or
# patch is involved in the build, and the vendored tree is GBATang's src/ with
# the deviations marked `TinyGBA:` in place.
set -euo pipefail
export LC_ALL=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/fpga/gba"
out="${TINYGBA_BUILD_DIR:-$root/build/tinygba}"
stage="${TINYGBA_STAGE:-all}"
case "$stage" in synth|pnr|pack|all) ;; *) echo "TINYGBA_STAGE must be synth, pnr, pack or all" >&2; exit 2 ;; esac

suite="${OSS_CAD_SUITE:-$HOME/oss-cad-suite}"
nextpnr="${NEXTPNR_HIMBAECHEL:-$HOME/tools/nextpnr-mathieufro/nextpnr-himbaechel}"
apycula="${APICULA_FORK:-$(dirname "$root")/apicula-mathieufro}"
pydeps="${PYDEPS:-$HOME/tools/pydeps}"
device=GW5AST-LV138PG484AC1/I0
family=GW5AST-138C
seed="${TINYGBA_SEED:-1}"
defines="${TINYGBA_DEFINES:-}"
timing_fail=""
[[ "${TINYGBA_ALLOW_HOLD:-0}" == 1 ]] && timing_fail="--timing-allow-fail"

[[ -f "$suite/environment" ]] || { echo "missing open toolchain: $suite" >&2; exit 2; }
[[ -x "$nextpnr" ]] || { echo "missing nextpnr-himbaechel fork: $nextpnr" >&2; exit 2; }
# shellcheck disable=SC1090
source "$suite/environment"
export PYTHONHOME="$suite"
export PYTHONPATH="$apycula:$pydeps:${PYTHONPATH:-}"
mkdir -p "$out"

# --------------------------------------------------------------- sources
# GBATang's console138k file list (build.tcl), verbatim, with two deviations:
# gowin_pll_hdmi.v replaces the two-output pll_74.v wrapper, and the DDR3
# framebuffer path (fb.v's 60K siblings, ddr3_memory_interface/, pll_ddr3,
# gba2hdmi_ddr3) is not built because this board uses the BRAM framebuffer.
d="$src/src"
sources=(
    "$d/boards/console138k.v"
    "$d/pll/pll_27.v"
    "$d/pll/pll_33.v"
    "$d/pll/pll_12.v"
    "$d/pll/gowin_pll_hdmi.v"
    "$d/usb_hid_host.v"
    "$d/fb.v"
    "$d/gba2hdmi.sv"

    "$d/iosys/iosys_bl616.v"
    "$d/iosys/uart_fixed.v"
    "$d/iosys/textdisp.v"
    "$d/iosys/gowin_dpb_menu.v"

    "$d/common/dpram32_block.v"
    "$d/common/dpram_block.v"
    "$d/common/dual_clk_fifo.v"
    "$d/common/eprocreg_gba.sv"
    "$d/common/gba_bios.sv"

    "$d/cpu/gba_cpu.v"
    "$d/cpu/gba_cpu_thumbdecoder.v"
    "$d/cpu/gba_interrupts.v"

    "$d/gbatang_top.sv"

    "$d/gpu/gba_drawer_merge.v"
    "$d/gpu/gba_drawer_mode0.v"
    "$d/gpu/gba_drawer_mode2.v"
    "$d/gpu/gba_drawer_mode345.v"
    "$d/gpu/gba_drawer_obj.sv"
    "$d/gpu/gba_gpu.v"
    "$d/gpu/gba_gpu_colorshade.sv"
    "$d/gpu/gba_gpu_drawer.v"
    "$d/gpu/gba_gpu_timing.v"
    "$d/gpu/gba_timer.v"
    "$d/gpu/gba_timer_module.v"
    "$d/gpu/vram_hi.v"
    "$d/gpu/vram_lo.v"
    "$d/gpu/linebuffer.v"

    "$d/memory/gba_dma.v"
    "$d/memory/gba_dma_module.sv"
    "$d/memory/gba_eeprom.sv"
    "$d/memory/gba_flash_sram.sv"
    "$d/memory/gba_memory.sv"
    "$d/memory/mem_eeprom.v"
    "$d/memory/mem_iwram.v"
    "$d/memory/rv_sdram_adapter.v"
    "$d/memory/sdram_gba.v"

    "$d/peripherals/controller_ds2.sv"
    "$d/peripherals/dualshock_controller.v"
    "$d/peripherals/gba_joypad.v"

    "$d/sound/gba_sound.v"
    "$d/sound/gba_sound_ch1.v"
    "$d/sound/gba_sound_ch3.v"
    "$d/sound/gba_sound_ch4.v"
    "$d/sound/gba_sound_dma.v"

    # TinyGBA diagnostics.  Compiled always and dropped by yosys whenever
    # nothing instantiates them, so the production netlist is unaffected; the
    # diagnostic builds select them with TINYGBA_DEFINES.
    "$src/diag/sdram_probe.v"
)
hdmi_slang=()
for f in "$d"/hdmi/*.sv; do hdmi_slang+=("$f"); done

for f in "${sources[@]}" "${hdmi_slang[@]}"; do
    [[ -f "$f" ]] || { echo "missing source: $f" >&2; exit 2; }
done

# --------------------------------------------------------------- 1. synthesis
if [[ ! -f "$out/tinygba.json" || "${TINYGBA_FORCE_SYNTH:-0}" == 1 ]]; then
echo "=== 1. synthesis ==="
# The whole design is read as one compilation unit, which is what Gowin's
# build.tcl does and what src/boards/console138k.v relies on: it defines
# CONFIG_H, M138K, USB1 and USB2 and contains no modules at all.  Without
# --single-unit read_slang gives each file its own unit, those defines stop at
# the end of console138k.v, and the build silently drops the USB HID host, the
# 12 MHz PLL and linebuffer.v's M138K block RAM path.
# Primitive visibility: the Gowin cell libraries must be readable (so wrapper
# instances resolve) and every primitive the design instantiates must be
# blackboxed as well, or it is dropped without a word (TinySNES TCL-001).
#
# Three edits are made to the shim copies, all deliberate:
#   * `specify` blocks are removed, which cells_sim.v needs before it parses;
#   * `MUX2` is removed from cells_sim.v;
#   * `LUT5` is removed from cells_xtra_gw5a.v, where it is declared with no body.
# tools/cells_behavioral.v then supplies both, so yosys infers LUT4s instead of
# leaving 2345 unplaceable cells for nextpnr.
shim="$out/shim"
mkdir -p "$shim"
datdir=$(yosys-config --datdir 2>/dev/null || true)
[[ -n "${datdir:-}" && -d "$datdir/gowin" ]] || datdir="$suite/share/yosys"

# Drop specify blocks and the named modules from a library file.
strip_mods() {  # strip_mods <in> <out> <module>...
    local in=$1 out=$2; shift 2
    awk -v names="$(printf '%s\n' "$@" | paste -sd'|')" '
        /^[[:space:]]*specify[[:space:]]*$/ { inspec=1; next }
        inspec && /^[[:space:]]*endspecify[[:space:]]*$/ { inspec=0; next }
        inspec { next }
        $0 ~ "^module (" names ")[ (]" { inmod=1; next }
        inmod && /^endmodule/ { inmod=0; next }
        inmod { next }
        { print }
    ' "$in" > "$out"
}
strip_mods "$datdir/gowin/cells_sim.v"        "$shim/cells_sim_nospecify.v" MUX2
strip_mods "$datdir/gowin/cells_xtra_gw5a.v"   "$shim/cells_xtra_gw5a.v"     LUT5

libmods=$(grep -hoE '^[[:space:]]*module [A-Za-z_][A-Za-z0-9_]*' "$shim"/cells_*.v |
          awk '{print $2}' | sort -u)
dnames=$(grep -rhoE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$src/src" \
              --include=*.v --include=*.sv 2>/dev/null |
         sed 's/^[[:space:]]*//' | sort -u)
bb=$(comm -12 <(echo "$libmods") <(echo "$dnames")) || true
bbflags=$(echo "$bb" | sed 's/^/--blackboxed-module /' | paste -sd' ')

yosys -Q -T -q -l "$out/synth.log" -p "
    read_verilog -lib $shim/cells_xtra_gw5a.v
    read_slang --std 1800-2017 --single-unit -U SYNTHESIS $defines --allow-use-before-declare --allow-lib-module-redef $bbflags -v $shim/cells_sim_nospecify.v -v $shim/cells_xtra_gw5a.v -I $src/src/common -I $src/src/gpu ${sources[*]} ${hdmi_slang[*]} $root/tools/cells_behavioral.v
    synth_gowin -family gw5a -top gbatang_top
    write_json $out/tinygba.json
" 2>&1 | tee "$out/synth.err" | tail -30
[[ -f "$out/tinygba.json" ]] || { echo "synthesis failed; see $out/synth.log" >&2; exit 1; }
echo "netlist: $out/tinygba.json ($(du -h "$out/tinygba.json" | cut -f1))"
else
echo "=== 1. synthesis (cached) ==="
fi

[[ "$stage" == synth ]] && { echo "stopping after synthesis"; exit 0; }

# --------------------------------------------------------------- 2. place and route
echo "=== 2. placement and routing ==="
"$nextpnr" \
    --json "$out/tinygba.json" \
    --write "$out/tinygba-routed.json" \
    --device "$device" \
    --freq 67 \
    --vopt cst="$src/tinygba.cst" \
    --sdc "$src/tinygba.sdc" \
    --report "$out/timing.json" \
    --seed "$seed" \
    ${timing_fail} \
    >"$out/nextpnr.log" 2>&1 || {
        tail -60 "$out/nextpnr.log" >&2
        echo "place and route failed; see $out/nextpnr.log" >&2
        exit 1
    }
echo "routed: $out/tinygba-routed.json"

[[ "$stage" == pnr ]] && { echo "stopping after place and route"; exit 0; }

# --------------------------------------------------------------- 3. timing gate
# Fmax only.  nextpnr's hold violations are reported separately and are not a
# gate here; when the design is proven on hardware this should become a refusal,
# the way TinyNES and TinyTang refuse unclean seeds.
echo "=== 3. timing gate ==="
"$suite/py3bin/python3" - "$out" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
t = json.loads((out / "timing.json").read_text())["fmax"]
for name, v in sorted(t.items()):
    print(f"  {name}: constraint {v['constraint']:.3f} MHz, achieved {v['achieved']:.3f} MHz")
bad = [n for n, v in t.items() if v["achieved"] < v["constraint"]]
if bad:
    raise SystemExit(f"timing not met on: {', '.join(bad)}")
PY

echo "=== 4. bitstream ==="
"$suite/py3bin/python3" -m apycula.gowin_pack \
    -d "$family" \
    -o "$out/tinygba.fs" \
    "$out/tinygba-routed.json" \
    >"$out/pack.log" 2>&1 || {
        tail -40 "$out/pack.log" >&2
        exit 1
    }
"$suite/py3bin/python3" "$root/tools/fs_to_bin.py" "$out/tinygba.fs" -o "$out/tinygba.bin" >/dev/null
sha256sum "$out/tinygba.fs" "$out/tinygba.bin"
echo "Ready to tangload (two-wire): $out/tinygba.bin"
