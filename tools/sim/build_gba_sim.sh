#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Build and run the GBATang core under Verilator.
#
#   tools/sim/build_gba_sim.sh build          # verilate and compile
#   tools/sim/build_gba_sim.sh run ROM.gba    # run with SDL window
#   tools/sim/build_gba_sim.sh run ROM.gba -s 60000000
#
#   TINYGBA_SIM_DEFINES=-DTINYGBA_SDRAM_RTL   simulate the real SDRAM controller
#                                  against a pin-level part instead of the
#                                  behavioural array (see fpga/gba/diag/
#                                  gba_sdram_rtl.v).  Slower, and the only way
#                                  to exercise the controller at all.
#
#   TINYGBA_SIM_BIOS                path to the BIOS image; defaults to
#                                  build/test/official_bios.hex.  There is no
#                                  free-BIOS fallback any more (BRD-107).
#
# The BIOS is REQUIRED and has exactly one source.  Every board result this
# project has recorded was taken with the retail BIOS; a simulation running a
# different image is a different machine and its output cannot be compared with
# the bench.  Measured the hard way twice: on 2026-11-15 a whole series of
# controller traces was taken against the free BIOS because this script never
# set the define, and on 2026-11-16 three bitstreams were blamed on placement
# seed when the free BIOS was the only thing wrong.  The free image in the tree
# has been deleted and `gba_memory.sv` no longer falls back, so a missing define
# is an elaboration error rather than a silently different machine.
#
# Why this exists.  Every hardware result this project has produced came from a
# 16-bit strip on a capture card, one word per flash cycle, with no reference to
# compare against -- the sibling SNES project reached exactly that impasse and
# concluded that the hardware loop had to be replaced by a bench for questions
# about *correctness* rather than *state*.  GBATang ships a full Verilator
# harness (verilator/sim_main.cpp upstream) with SDL video, audio capture and FST
# tracing, and this port never carried it, so nothing here had ever been
# simulated.
#
# The harness needed three repairs before it built at all, which is itself
# evidence it had not been run against this revision:
#
#   1. gba_eeprom.sv has two `ifdef VERILATOR` $display statements that index
#      `mem`, an array whose declaration is commented out in the same file.  They
#      are dead debug code; both are now comments.
#   2. The upstream Makefile's source list omits `gpu/linebuffer.v` and
#      `memory/mem_eeprom.v`, both of which are instantiated unconditionally.
#   3. Under VERILATOR the design substitutes sim_spram_be / sim_dpram_be for the
#      Gowin IP, but mem_eeprom.v still instantiates MUX2, DFFRE and DPB, which
#      only the vendor cell library defines.  tools/sim/gowin_cells_sim.v carries
#      exactly those three, extracted with `specify` blocks removed.
#
# The simulation clocking is the harness's own: six steps per cycle pair, giving
# clk50:clk16 = 3:1, which matches the board's 50.25:16.75 MHz exactly.
set -euo pipefail
export LC_ALL=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
d="$root/fpga/gba/src"
out="${TINYGBA_SIM_DIR:-$root/build/sim_verilator}"
top=gbatang_top

[[ -f "$root/tools/sim/sim_main.cpp" ]] || { echo "missing tools/sim/sim_main.cpp" >&2; exit 2; }
command -v verilator >/dev/null || { echo "verilator not found" >&2; exit 2; }
command -v sdl2-config >/dev/null || { echo "sdl2-config not found (needed for the SDL window)" >&2; exit 2; }

# The Verilator-branch source list.  Deliberately NOT the synthesis list: under
# VERILATOR the Gowin IP wrappers (mem_iwram, vram_hi/lo, fb) are replaced by
# sim_* models inside gba_memory.sv, and the HDMI/OSD path is not built at all.
srcs=(
    "$d/boards/console138k.v"
    "$d/gbatang_top.sv"
    "$d/cpu/gba_cpu.v"
    "$d/cpu/gba_cpu_thumbdecoder.v"
    "$d/cpu/gba_interrupts.v"
    "$d/memory/gba_dma.v"
    "$d/memory/gba_dma_module.sv"
    "$d/memory/gba_memory.sv"
    "$d/memory/gba_flash_sram.sv"
    "$d/memory/gba_eeprom.sv"
    "$d/memory/gba_save.v"
    "$d/memory/eeprom_ram.v"
    "$d/memory/sdram_sim.v"
    "$d/memory/rv_sdram_adapter.v"
    # The real controller and its pin-level model, for TINYGBA_SDRAM_RTL builds.
    # Compiled always; selected at elaboration by the define in gbatang_top.sv.
    "$d/memory/sdram_gba.v"
    "$root/fpga/gba/diag/gba_sdram_rtl.v"
    "$root/fpga/gba/diag/sdram_model.v"
    "$d/gpu/gba_drawer_merge.v"
    "$d/gpu/gba_drawer_mode0.v"
    "$d/gpu/gba_drawer_mode2.v"
    "$d/gpu/gba_drawer_mode345.v"
    "$d/gpu/gba_drawer_obj.sv"
    "$d/gpu/gba_gpu_colorshade.sv"
    "$d/gpu/gba_gpu_drawer.v"
    "$d/gpu/gba_gpu_timing.v"
    "$d/gpu/gba_gpu.v"
    "$d/gpu/gba_timer_module.v"
    "$d/gpu/gba_timer.v"
    "$d/gpu/linebuffer.v"
    "$d/common/sim_dpram_be.sv"
    "$d/common/sim_spram_be.sv"
    "$d/common/eprocreg_gba.sv"
    "$d/common/syncramdual.v"
    "$d/common/syncramdualnotpow2.v"
    "$d/common/dpram32_block.v"
    "$d/common/dpram_block.v"
    "$d/common/dual_clk_fifo.v"
    "$d/peripherals/gba_joypad.v"
    "$d/sound/gba_sound.v"
    "$d/sound/gba_sound_ch1.v"
    "$d/sound/gba_sound_ch3.v"
    "$d/sound/gba_sound_ch4.v"
    "$d/sound/gba_sound_dma.v"
    "$root/tools/sim/gowin_cells_sim.v"
)

for f in "${srcs[@]}"; do
    [[ -f "$f" ]] || { echo "missing source: $f" >&2; exit 2; }
done

cmd="${1:-build}"; shift || true

# Resolve the BIOS before anything is built, because which image is inside the
# model decides whether a result is comparable with the bench.  The retail image
# is Nintendo's copyrighted work and is therefore untracked (`build/` is
# ignored).
#
# There is no free-BIOS opt-out any more.  Until 2026-11-16 this accepted
# `TINYGBA_SIM_BIOS=cultofgba`, and the image it pointed at is deleted for the
# reason BRD-107 records: a build that silently used the free BIOS produced
# bitstreams that passed every gate and drew a black screen, and the same class
# of mistake had already invalidated a whole series of simulation traces on
# 2026-11-15 (TCL-081).  An escape hatch that produces incomparable results is
# not worth keeping, so the harness now has exactly one machine.
retail="${TINYGBA_SIM_BIOS:-$root/build/test/official_bios.hex}"
if [[ ! -f "$retail" ]]; then
    echo "no retail BIOS at $retail" >&2
    echo "  every board result was taken with the retail BIOS, so a simulation" >&2
    echo "  without it is a different machine and its results cannot be compared." >&2
    echo "  put the image there, or point TINYGBA_SIM_BIOS at it.  The free BIOS" >&2
    echo "  has been deleted and there is no fallback (BRD-107)." >&2
    exit 2
fi
retail="$(cd -- "$(dirname -- "$retail")" && pwd)/$(basename -- "$retail")"
bios_define="-DTINYGBA_BIOS_HEX=\"$retail\""
echo "=== BIOS: retail ($retail) ==="

case "$cmd" in
build)
    mkdir -p "$out"
    echo "=== verilate ==="
    verilator --top-module "$top" --trace-fst \
        -Wno-WIDTH -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
        -Wno-LATCH -Wno-IMPLICIT -Wno-REDEFMACRO \
        ${TINYGBA_SIM_DEFINES:-} $bios_define \
        --cc --exe \
        -CFLAGS "$(sdl2-config --cflags) -O2" \
        -LDFLAGS "$(sdl2-config --libs)" \
        -I"$d" -I"$d/common" -I"$d/boards" \
        --Mdir "$out/obj_dir" \
        "${srcs[@]}" "$root/tools/sim/sim_main.cpp"
    echo "=== compile ==="
    make -C "$out/obj_dir" -f "V$top.mk" "V$top" -j"$(nproc)"
    # The BIOS is read with $readmemh when the model is elaborated, which for
    # Verilator happens at process start, so `bios_define` above carries an
    # absolute path and no copy into the run directory is needed or wanted --
    # a copy is how a stale image silently outlived a change to this script.
    echo
    echo "built: $out/obj_dir/V$top"
    ;;
run)
    [[ -x "$out/obj_dir/V$top" ]] || { echo "not built; run '$0 build'" >&2; exit 2; }
    cd "$out/obj_dir"
    exec "./V$top" "$@"
    ;;
clean)
    rm -rf "$out"
    ;;
*)
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
