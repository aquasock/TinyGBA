#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Place one synthesised netlist at many seeds and report which placements are
usable, by the same two criteria the build gates on.

Why this exists.  `tools/sweep_tinygba_seeds.sh` answers a narrower question --
is the placement hold-clean -- and by its own header that is not the whole
deploy criterion.  On this device the placer also decides which clock-plane pip
each clock takes, and a clock that lands on general routing has no skew
guarantee at all; `build/hw3` failed exactly that way while `build/hw2`, the
same RTL at a different seed, put `clk67` on a measured-good spine.  A seed
sweep that only counts hold violations would have called both of them fine.

So this runs the same two gates the build runs, on every seed:

  * `tools/clock_plane_report.py` -- fails on dead pips and on a clock left on
    general routing (the build's non-strict setting, which is what gates a
    deploy);
  * `tools/timing_gate.py` -- Fmax, cross-clock paths and the hold count.

    tools/sweep_build_seeds.py --netlist build/hw3/tinygba.json --first 1 --last 12

Each seed gets its own directory and its own nextpnr log; the table at the end
names, per seed, whether it is deployable and if not, why.  Placement dominates
the wall clock, so seeds run concurrently -- one nextpnr per core, capped.
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUITE = pathlib.Path(os.environ.get("OSS_CAD_SUITE", pathlib.Path.home() / "oss-cad-suite"))
DEVICE = "GW5AST-LV138PG484AC1/I0"


def nextpnr_bin() -> str:
    return os.environ.get("NEXTPNR_HIMBAECHEL",
                          str(pathlib.Path.home() / "tools" / "nextpnr-mathieufro" /
                              "nextpnr-himbaechel"))


def env():
    """The environment nextpnr-himbaechel needs; mirrors build_tinygba.sh."""
    e = dict(os.environ)
    e["LC_ALL"] = "C"
    e["PYTHONHOME"] = str(SUITE)
    apycula = os.environ.get("APICULA_FORK", str(ROOT.parent / "apicula-mathieufro"))
    pydeps = os.environ.get("PYDEPS", str(pathlib.Path.home() / "tools" / "pydeps"))
    e["PYTHONPATH"] = os.pathsep.join(
        [apycula, pydeps] + ([e["PYTHONPATH"]] if e.get("PYTHONPATH") else []))
    return e


def pybin() -> str:
    p = SUITE / "py3bin" / "python3"
    return str(p) if p.exists() else sys.executable


def run_seed(seed: int, netlist: pathlib.Path, outdir: pathlib.Path,
             timeout: int) -> dict:
    out = outdir / f"seed_{seed}"
    out.mkdir(parents=True, exist_ok=True)
    routed = out / "tinygba-routed.json"
    rec = {"seed": seed, "dir": str(out), "routed": False, "plane": None,
           "timing": None, "hold": None, "why": "", "clock": {}}

    cmd = [nextpnr_bin(), "--json", str(netlist), "--write", str(routed),
           "--device", DEVICE, "--freq", "67",
           "--vopt", f"cst={ROOT / 'fpga/gba/tinygba.cst'}",
           "--sdc", str(ROOT / "fpga/gba/tinygba.sdc"),
           "--report", str(out / "timing.json"), "--seed", str(seed)]
    try:
        with open(out / "nextpnr.log", "w") as log:
            r = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                               env=env(), timeout=timeout, cwd=str(ROOT))
    except subprocess.TimeoutExpired:
        rec["why"] = f"nextpnr timed out after {timeout}s"
        return rec
    if r.returncode != 0:
        rec["why"] = "place and route failed"
        return rec
    rec["routed"] = True

    plane_log = out / "clock-plane.log"
    with open(plane_log, "w") as log:
        rp = subprocess.run([pybin(), str(ROOT / "tools/clock_plane_report.py"),
                             str(routed)], stdout=log, stderr=subprocess.STDOUT)
    text = plane_log.read_text()
    rec["plane"] = rp.returncode == 0
    for line in text.splitlines():
        s = line.strip()
        if s and not s.startswith(("NO PLANE", "A clock on", "  ", "TinyGBA")):
            continue
        if s.startswith(("clk", "hclk", "pll")):
            name = s.split()[0]
            good = "good[" in s
            rec["clock"][name] = "good" if good else (
                "general" if "unmeasured" in s or "partial" in s else "?")
    if "NO PLANE PIP" in text:
        m = [l for l in text.splitlines() if "NO PLANE PIP" in l]
        rec["why"] = m[0].strip()[:80] if m else "clock on general routing"

    tlog = out / "timing-gate.log"
    with open(tlog, "w") as log:
        rt = subprocess.run([pybin(), str(ROOT / "tools/timing_gate.py"), str(out)],
                            stdout=log, stderr=subprocess.STDOUT)
    ttext = tlog.read_text()
    rec["timing"] = rt.returncode == 0
    for line in ttext.splitlines():
        if "hold" in line and "violation" in line:
            digits = "".join(c for c in line.split(":")[1].split()[0] if c.isdigit())
            if digits:
                rec["hold"] = int(digits)
    if rec["plane"] and not rec["timing"] and not rec["why"]:
        rec["why"] = "timing gate failed"
    return rec


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--netlist", required=True, help="synthesised tinygba.json")
    ap.add_argument("--out", default=None, help="output dir (default: beside the netlist)")
    ap.add_argument("--first", type=int, default=1)
    ap.add_argument("--last", type=int, default=12)
    ap.add_argument("--jobs", type=int, default=0,
                    help="concurrent placements (default: min(seeds, cores-2))")
    ap.add_argument("--timeout", type=int, default=3600, help="per-seed seconds")
    args = ap.parse_args()

    netlist = pathlib.Path(args.netlist).resolve()
    if not netlist.exists():
        sys.exit(f"no such netlist: {netlist}")
    outdir = pathlib.Path(args.out).resolve() if args.out else netlist.parent / "sweep"

    seeds = list(range(args.first, args.last + 1))
    cores = os.cpu_count() or 4
    jobs = args.jobs or max(1, min(len(seeds), cores - 2))
    print(f"netlist: {netlist}")
    print(f"seeds:   {seeds[0]}..{seeds[-1]}  ({len(seeds)}), {jobs} at a time, "
          f"timeout {args.timeout}s each")
    print(f"out:     {outdir}")
    print()

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(run_seed, s, netlist, outdir, args.timeout): s for s in seeds}
        for fut in concurrent.futures.as_completed(futs):
            rec = fut.result()
            results.append(rec)
            state = ("DEPLOYABLE" if rec["plane"] and rec["timing"]
                     else rec["why"] or "failed")
            print(f"  seed {rec['seed']:2d}: {state}")
            sys.stdout.flush()

    results.sort(key=lambda r: r["seed"])
    good = [r for r in results if r["plane"] and r["timing"]]

    print()
    print(f"{'seed':>5}  {'plane':>6} {'timing':>7} {'hold':>5}  clk67          verdict")
    for r in results:
        c67 = r["clock"].get("clk67", "-")
        verdict = "DEPLOYABLE" if r["plane"] and r["timing"] else (r["why"] or "-")
        print(f"{r['seed']:>5}  {str(r['plane']):>6} {str(r['timing']):>7} "
              f"{str(r['hold']):>5}  {c67:<14} {verdict}")

    (outdir / "sweep.json").write_text(json.dumps(results, indent=1))
    print()
    if good:
        print(f"{len(good)} of {len(results)} seeds deployable: "
              f"{[r['seed'] for r in good]}")
        print(f"best seed to use: {good[0]['seed']}  ({good[0]['dir']})")
    else:
        print(f"NONE of {len(results)} seeds is deployable -- this is not seed luck.")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
