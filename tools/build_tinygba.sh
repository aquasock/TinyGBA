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
#   TINYGBA_CLOCK_PLANE_STRICT 1 makes the clock-plane gate fail on a clock whose
#                     bridge pip this board has never measured, not only on one
#                     measured dead or left on general routing.  Off by default
#                     because most of this design currently sits on unmeasured
#                     pips; the report is written either way, to
#                     $out/clock-plane.log, so a hardware result can be
#                     attributed to the placement that produced it.
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
# nextpnr is always allowed to finish with violations, so that it writes
# timing.json and the routed netlist for the gate below to judge.  nextpnr must
# not be the judge: it analyses every path as a single cycle and cannot express
# the multicycle paths this design was written to, so its verdict is wrong in
# both directions -- it fails paths that meet the contract and never looks at
# the cross-clock paths at all.  tools/timing_gate.py applies the documented
# allowances and is the gate; TINYGBA_ALLOW_HOLD only downgrades its hold check.
timing_fail="--timing-allow-fail"

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
    "$d/pll/pll_16.v"
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

# --------------------------------------------------------------- 0. probe map
# The diagnostic probe's packing is generated from one declarative field list by
# tools/probe_map.py, and its host decoder is generated from that same list.  A
# stale include would silently pack bars in an order the decoder does not expect,
# which is the failure mode that cost the sibling project four cycles.  Refuse a
# build whose include does not match the list.
echo "=== 0. probe field map ==="
"$suite/py3bin/python3" "$root/tools/probe_map.py" --check \
    || { echo "probe_bits.vh is stale; run tools/probe_map.py --emit-verilog" >&2; exit 1; }
# Record which field map this bitstream was built from, in the build directory
# itself.  A capture is decoded against a map, and the only honest source for
# "which map" is the build that produced the image being flashed -- not whatever
# the tree happens to contain when someone decodes it later.  `tools/cap_tang.sh`
# copies this into the capture's `.map` sidecar and `tools/probe_map.py --decode`
# refuses a capture whose sidecar disagrees, so a stale capture cannot be read
# under a newer map.  Written unconditionally: a build without the probe has a
# map id too, and recording it costs nothing.
"$suite/py3bin/python3" "$root/tools/probe_map.py" --map-id > "$out/probe-map.id" \
    || { echo "could not record the probe field map" >&2; exit 1; }

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

# ---------------------------------------------------- 1b. register-parity gate
# A netlist can lose most of its registers and still build, pass timing and pack:
# on 2026-11-02 an undriven `gb_bus_rst` folded high, deleted every MMIO
# register's write path, and removed about 4,500 flip-flops from a 9,100-register
# design.  Nothing in the flow noticed, and no simulation can, because the
# simulation sees the signal rather than its absence.  This compares the netlist
# against a recorded baseline for the configuration.
#
# It runs only when a netlist has just been synthesised or was already present,
# and only when a baseline entry exists for $cfg -- a configuration with no
# baseline is reported and skipped rather than silently passing.  Record one with:
#   tools/synth_parity.py $out/tinygba.json --key $cfg --update-baseline
# Key on the configuration's TINYGBA_ define NAMES only: a full defines string
# carries absolute paths and would make every baseline entry unique.  The define
# set is what changes the design's structure; a path only changes which BIOS
# bytes are loaded, not how many registers exist.
# TINYGBA_BIOS_HEX is excluded deliberately: it selects which image is loaded
# into the BIOS block RAM and changes no logic, so a different BIOS must not read
# as a different design.
cfg=$(printf '%s' "${TINYGBA_DEFINES:-}" | grep -oE -- '-DTINYGBA_[A-Z0-9_]+' \
      | sed 's/^-D//' | grep -v '^TINYGBA_BIOS_HEX$' | sort -u | paste -sd'+' -)
cfg="${cfg:-default}"
echo "=== 1b. register-parity gate (config: $cfg) ==="
parity=0
"$suite/py3bin/python3" "$root/tools/synth_parity.py" "$out/tinygba.json" \
    --key "$cfg" --synth-log "$out/synth.err" \
    >"$out/parity.log" 2>&1 || parity=$?
sed 's/^/  /' "$out/parity.log"
if [[ $parity -eq 2 ]]; then
    echo "  (no baseline for this configuration; recorded counts are in $out/parity.log)"
    echo "  record one with: tools/synth_parity.py $out/tinygba.json --key $cfg --update-baseline"
elif [[ $parity -ne 0 ]]; then
    echo "register-parity gate failed; see $out/parity.log" >&2
    exit 1
fi

# ------------------------------------------------------ 1c. clock-edge gate
# For GW5A, synth_gowin keeps only a plain negedge flop as a true DFFN and
# legalises every negedge flop with an enable or reset into a posedge DFFRE
# behind a LUT1 inverter of the clock.  When both kinds sit on one clock the
# two halves are a few ns apart on fabric routing with no hold check between
# them.  That stopped the SuperFX on the board in the sibling TinySNES project
# (its core-reference TCL-020), where the symptom looked like a logic deadlock
# and no ideal-clock bench could see it.  TinyGBA had no gate for the class, so
# this build inherits one.  Measured 2026-11-04: this tree has no DFFN at all
# and no flop clock pin on fabric, so the gate is insurance rather than a fix.
echo "=== 1c. clock-edge gate ==="
edge=0
"$suite/py3bin/python3" "$root/tools/clock_edge_check.py" "$out/tinygba.json" \
    >"$out/clock-edge.log" 2>&1 || edge=$?
sed 's/^/  /' "$out/clock-edge.log"
if [[ $edge -ne 0 ]]; then
    echo "clock-edge gate failed; see $out/clock-edge.log" >&2
    exit 1
fi


# --------------------------------------------------------------- 2. place and route
# `pack` means "pack the routed netlist that is already here", not "place and
# route again".  There was no early exit for it, so TINYGBA_STAGE=pack fell
# through and re-ran nextpnr, OVERWRITING tinygba-routed.json, timing.json and
# clock-plane.log before packing.  nextpnr does not reproduce a placement from an
# unchanged netlist and seed, so the bitstream that shipped would have been a
# different placement from the one whose gates had just passed -- and a seed that
# gated clean could fail the re-run.  Every image this project has deployed was
# built with TINYGBA_STAGE=all, so no result on record is affected; the trap is
# that the stage name promises the opposite of what it did.  Reported by the
# sibling SNES project, which hit exactly this on its GSU probe.  The gate logs
# are kept and re-printed so `pack` still reports what the placement passed,
# which is the thing that was lost before: a packed image whose gates were run on
# some other placement.
if [[ "$stage" == pack ]]; then
    for f in tinygba-routed.json timing.json clock-plane.log; do
        [[ -f "$out/$f" ]] || {
            echo "no $f in $out; run TINYGBA_STAGE=pnr first" >&2
            exit 2
        }
    done
    echo "=== 2. placement and routing (reused, not re-run) ==="
    echo "    $out/tinygba-routed.json"
    echo "    gates that passed on THIS placement:"
    sed 's/^/      /' "$out/timing-gate.log" | grep -E 'pass|ALLOWED|hold  :|Meets' || true
else
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

# ------------------------------------------------------- 3. clock-plane gate
# A clock reaches the global network through a bridge pip, and the pips are not
# interchangeable: some clock every flip-flop behind them and some clock none.
# Which one a clock gets is decided by the placer and appears in neither the
# timing report nor the hold check, so it needs its own gate.  TinySNES recorded
# two hold-clean builds of identical source passing Fmax where one booted and the
# other never ran, differing only in the master clock's spine (its BRD-005), and
# this project had no equivalent check.  Dead pips and clocks left on general
# routing fail the build; pips nobody has measured are reported, and only fail
# under TINYGBA_CLOCK_PLANE_STRICT=1, because most of this design currently sits
# on paths this board has not measured either way.
echo "=== 3. clock-plane gate ==="
strict=""
[[ "${TINYGBA_CLOCK_PLANE_STRICT:-0}" == 1 ]] && strict="--strict"
# `set -o pipefail` would abort the script on a failing report before the message
# below could print, so the pipeline's status is captured explicitly instead.
plane=0
# shellcheck disable=SC2086
"$suite/py3bin/python3" "$root/tools/clock_plane_report.py" \
    "$out/tinygba-routed.json" $strict >"$out/clock-plane.log" 2>&1 || plane=$?
cat "$out/clock-plane.log"
if [[ $plane -ne 0 ]]; then
    echo "clock-plane gate failed (exit $plane); see $out/clock-plane.log" >&2
    exit 1
fi

# --------------------------------------------------------------- 4. timing gate
# Judged by tools/timing_gate.py, not by nextpnr.  That tool holds every path to
# a single cycle except the four that upstream GBATang's gbatang.sdc relaxes to
# four, and prints each relaxation it applies with the upstream line it came
# from.  It also gates the hold count and the cross-clock clk16<->clk67 paths,
# neither of which appears in the Fmax report.
echo "=== 4. timing gate ==="
holdflag=""
[[ "${TINYGBA_ALLOW_HOLD:-0}" == 1 ]] && holdflag="--allow-hold"
gate=0
"$suite/py3bin/python3" "$root/tools/timing_gate.py" "$out" $holdflag \
    >"$out/timing-gate.log" 2>&1 || gate=$?
cat "$out/timing-gate.log"
[[ $gate -eq 0 ]] || { echo "timing gate failed; see $out/timing-gate.log" >&2; exit 1; }

fi   # end of the non-pack branch: the gates above ran on the routed netlist

echo "=== 5. bitstream ==="
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
